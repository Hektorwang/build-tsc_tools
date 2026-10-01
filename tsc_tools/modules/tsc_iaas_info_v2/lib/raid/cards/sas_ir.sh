#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016
# =============================================================================
# lib/raid/cards/sas_ir.sh — SAS2/SAS3 IR 共享解析 (DESIGN.md §4.4, 阶段3/4)
# =============================================================================
# 被 cards/sas3.sh 与 cards/sas2.sh source; 两代 sasXircu 的 DISPLAY 输出
# 同构(key-value 块), 解析逻辑只有一份(§4.2: 解析框架通用)。
#
# _sas_ir_detect <ircu> <模块名> <PCI关键字>  — 工具在位 且 (lsmod 或 lspci 证据)
# _sas_ir_parse  <ircu> <ctl_no> <card>       — 每控制器一行全量模型
#   抓取: `<ircu> <ctl_no> display` 单次全量(§4.4)
#   分节: Controller type → controller.name; IR Volume → vds[];
#         Physical device → pds[](State/Size/Model/Serial No/GUID/Protocol);
#   无 IR Volume 属正常(直通模式), 不降级。
# =============================================================================

_sas_ir_detect() {
    local ircu="$1" module="$2" pci_kw="$3"
    local bin
    bin="$(card_find_tool "${ircu}" "${TSC_PKG_DIR}/${ircu}/${ircu}-$(arch)")" || return 1
    if lsmod 2>/dev/null | grep -qE "^${module}"; then
        return 0
    fi
    lspci 2>/dev/null | grep -q "${pci_kw}"
}

_sas_ir_parse() {
    local ircu="$1" ctl_no="$2" card="$3"
    local bin display
    bin="$(card_find_tool "${ircu}" "${TSC_PKG_DIR}/${ircu}/${ircu}-$(arch)")" || return 1
    display="$("${bin}" "${ctl_no}" display 2>/dev/null)" || {
        json_line -n --argjson c "${ctl_no}" --arg card "${card}" \
            '{card:$card,ctl_no:$c,controller:null,vds:null,pds:[],sections_failed:["controller","vds","pds"]}'
        return 0
    }
    display="${display//$'\r'/}"

    # --- DISPLAY 分节解析(awk 单遍) ---
    local -a rows=()
    # 行内字段用 \001(非空白)分隔: read 的 IFS 含空白时连续分隔符会折叠空字段
    local ROWSEP
    ROWSEP="$(printf '\001')"
    mapfile -t rows < <(printf '%s\n' "${display}" | awk -v S="${ROWSEP}" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function val(    s) { s = $0; sub(/^[^:]*:[[:space:]]*/, "", s); return trim(s) }
        function flushir() {
            if (irno != "") {
                printf "VD%s%s%s%s%s%s%s%s%s%s\n", S, irno, S, irstate, S, irlevel, S, irsize, S, irslots
                irno = ""; irstate = ""; irlevel = ""; irsize = ""; irslots = ""
            }
        }
        function flushpd() {
            if (pdslot != "" || pdenc != "") {
                printf "PD%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", S, pdenc, S, pdslot, S, pdstate, S, pdsize, S, pdmodel, S, pdserial, S, pdwwn, S, pdproto
                pdenc = ""; pdslot = ""; pdstate = ""; pdsize = ""; pdmodel = ""; pdserial = ""; pdwwn = ""; pdproto = ""
            }
        }
        /^[[:space:]]*Controller type/ { ctrltype = val(); next }
        /^[[:space:]]*IR Volume information/       { sec = "ir"; next }
        /^[[:space:]]*Physical device information/ { flushir(); sec = "pd"; next }
        /^[[:space:]]*Enclosure information/       { flushpd(); sec = ""; next }
        /^[[:space:]]*(Command completed|.*IRCU: Utility)/ { flushir(); flushpd(); sec = ""; next }
        sec == "ir" && /^[[:space:]]*IR volume [0-9]+/ { flushir(); irno = $NF; next }
        sec == "ir" && /RAID level/  { irlevel = val(); next }
        # sas2ircu 用 "Status of volume", sas3ircu 用 "Volume State"
        sec == "ir" && (/Volume State/ || /Status of volume/) { irstate = val(); next }
        sec == "ir" && /Volume Size \(in MB\)/      { irsize = val(); next }
        sec == "ir" && /Enclosure#\/Slot#/ {
            v = val()
            irslots = irslots (irslots == "" ? "" : ",") v
            next
        }
        sec == "pd" && /^[[:space:]]*Device is a /  { flushpd(); pdstarted = 1; next }
        sec == "pd" && /^[[:space:]]*Initiator at ID/  { next }
        sec == "pd" && pdstarted && /^[[:space:]]*Enclosure #/       { pdenc = val(); next }
        sec == "pd" && pdstarted && /^[[:space:]]*Slot #/            { pdslot = val(); next }
        sec == "pd" && pdstarted && /^[[:space:]]*State/             { pdstate = val(); next }
        sec == "pd" && pdstarted && /^[[:space:]]*Size \(in MB\)/ {
            v = val(); split(v, a, "/"); pdsize = a[1]; next
        }
        sec == "pd" && pdstarted && /^[[:space:]]*Model Number/      { pdmodel = val(); next }
        sec == "pd" && pdstarted && /^[[:space:]]*Serial No/         { pdserial = val(); next }
        sec == "pd" && pdstarted && /^[[:space:]]*GUID/              { pdwwn = val(); next }
        sec == "pd" && pdstarted && /^[[:space:]]*Protocol/          { pdproto = val(); next }
        END { flushir(); flushpd(); if (ctrltype != "") printf "CTRL%s%s\n", S, ctrltype }
        BEGIN { irno = ""; pdslot = ""; pdenc = "" }
    ')

    # --- bash 侧组装 ---
    local -a vds_json=() pds_json=()
    declare -A es_vd=()
    local t irno irstate irlevel irsize irslots ctrltype=""
    for row in "${rows[@]}"; do
        IFS="${ROWSEP}" read -r t irno irstate irlevel irsize irslots <<<"${row}"
        if [[ "${t}" == "CTRL" ]]; then
            ctrltype="${irno}"
            continue
        fi
        if [[ "${t}" == "VD" ]]; then
            local snorm gbid size_gb_json="null"
            snorm="$(state_norm "$(strip_state_parens "${irstate}")")"
            if [[ -n "${irsize}" ]] && gbid="$(to_gb "${irsize}" "MB" 2>/dev/null)" && [[ -n "${gbid}" ]]; then
                size_gb_json="${gbid}"
            fi
            # pd_slots: "1/0,1/1" → ["1/0","1/1"]; 记录 E/S→VD 映射
            # 槽位串非合法 JSON, -R 逐行转字符串
            local -a slot_arr=()
            IFS=',' read -r -a slot_arr <<<"${irslots}"
            local s
            for s in "${slot_arr[@]}"; do
                [[ -n "${s}" ]] || continue
                es_vd["${s}"]="${irno}"
            done
            vds_json+=("$(json_line -n \
                --arg vd "${irno}" --arg state "${irstate}" --arg sn "${snorm}" \
                --arg level "${irlevel}" --arg size "${irsize}" --argjson size_gb "${size_gb_json}" \
                --argjson slots "$(printf '%s\n' "${slot_arr[@]:-}" | jq -R '. | select(length>0)' | jq -s '.')" \
                '{vd:$vd,state:$state,state_norm:$sn,raid_level:(if $level=="" then null else $level end),
                  size:(if $size=="" then null else $size end),unit:(if $size=="" then null else "MB" end),
                  size_gb:$size_gb,pd_slots:$slots}')" ) || return 1
        fi
    done
    # 重读 rows 处理 PD(第二次遍历, 独立变量)
    local enc slot state size model serial wwn proto sn2 gbid2 size_gb2 vd
    for row in "${rows[@]}"; do
        IFS="${ROWSEP}" read -r t enc slot state size model serial wwn proto <<<"${row}"
        if [[ "${t}" == "PD" ]]; then
            sn2="$(state_norm "$(strip_state_parens "${state}")")"
            size_gb2="null"
            if [[ -n "${size}" && "${size}" != "0" ]] && gbid2="$(to_gb "${size}" "MB" 2>/dev/null)" && [[ -n "${gbid2}" ]]; then
                size_gb2="${gbid2}"
            fi
            vd="${es_vd[${enc}/${slot}]:-}"
            pds_json+=("$(json_line -n \
                --arg enc "${enc}" --arg slot "${slot}" --arg vd "${vd}" \
                --arg state "${state}" --arg sn "${sn2}" \
                --arg size "${size}" --argjson size_gb "${size_gb2}" \
                --arg model "${model}" --arg serial "${serial}" --arg wwn "${wwn}" \
                --arg intf "${proto}" \
                '{dev:null,type:"raid",ctl_no:0,
                  enc:(if ($enc == "" or $enc == "N/A" or ($enc | test("^[0-9]+$") | not)) then null else ($enc | tonumber) end),
                  slot:(if ($slot == "" or ($slot | test("^[0-9]+$") | not)) then null else ($slot | tonumber) end),
                  vd:(if $vd=="" then null else $vd end),
                  state:(if $state=="" then null else $state end),
                  state_norm:(if $sn=="" then null else $sn end),
                  size:(if $size=="" then null else $size end),
                  unit:(if $size=="" then null else "MB" end),
                  size_gb:$size_gb,
                  model:(if $model=="" then null else $model end),
                  serial:(if $serial=="" then null else $serial end),
                  wwn:(if $wwn=="" then null else $wwn end),
                  interface:(if $intf=="" then null else $intf end)}')" ) || return 1
        fi
    done

    local vds_arr pds_arr
    vds_arr="$(printf '%s\n' "${vds_json[@]:-}" | jq -s 'map(select(length>0))')"
    pds_arr="$(printf '%s\n' "${pds_json[@]:-}" | jq -s 'map(select(length>0))')"

    json_line -n \
        --argjson c "${ctl_no}" --arg card "${card}" --arg name "${ctrltype:-}" \
        --argjson vds "${vds_arr}" --argjson pds "${pds_arr}" \
        '{card:$card,ctl_no:$c,
          controller:{type:$card,ctl_no:$c,name:(if $name=="" then null else $name end),
                      health:null,health_norm:"unknown",
                      vd_count:($vds|length),pd_count:($pds|length)},
          vds:$vds,pds:$pds,sections_failed:[]}'
}
