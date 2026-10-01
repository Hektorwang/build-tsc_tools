#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016
# =============================================================================
# lib/raid/cards/adaptec.sh — Adaptec/microsemi 适配器 (DESIGN.md §4.2/§4.4, 阶段5)
# =============================================================================
# 工具: arcconf。抓取(§4.4 单抓取): `arcconf GETCONFIG <n>`(控制器/LD/PD 同源)。
# 二函数契约: card_adaptec_detect / card_adaptec_parse(每控制器一行全量模型)。
# 治 v1 缺陷: awk for(a in r) 遍历序不稳(改有序构造); 旧采集无 enc/slot
# (现从 "Reported Channel,Device(T:L)" 取 channel/device 作 enc/slot)。
# =============================================================================

card_adaptec_detect() {
    local bin
    bin="$(card_find_tool arcconf "${TSC_PKG_DIR}/arcconf/arcconf-$(arch)")" || return 1
    lspci 2>/dev/null | grep -qi "Adaptec"
}

card_adaptec_parse() {
    local bin
    bin="$(card_find_tool arcconf "${TSC_PKG_DIR}/arcconf/arcconf-$(arch)")" || return 1

    local found
    found="$("${bin}" GETCONFIG 1 2>/dev/null | awk '/^Controllers found:/{print $NF; exit}')"
    [[ "${found}" =~ ^[0-9]+$ ]] || return 1

    local i
    for ((i = 1; i <= found; i++)); do
        _adaptec_parse_controller "${bin}" "$((i - 1))" "${i}"
    done
    return 0
}

# -----------------------------------------------------------------------------
# _adaptec_parse_controller <bin> <ctl_no(0基)> <getconfig索引(1基)>
# GETCONFIG 分节(按节降级 §3.4):
#   Controller information     → Controller ID/Model/Status
#   Logical device information → Logical Device number N 块
#   Physical Device information → Device #N 块
# awk 输出行格式(TAB 分隔):
#   CTL\t<id>\t<model>\t<status>
#   LD\t<no>\t<name>\t<state>\t<level>\t<size>" "<unit>
#   PD\t<devno>\t<enc>\t<slot>\t<state>\t<model>\t<serial>\t<wwn>\t<size>" "<unit>
# -----------------------------------------------------------------------------
_adaptec_parse_controller() {
    local bin="$1" ctl_no="$2" idx="$3"
    local detail
    detail="$("${bin}" GETCONFIG "${idx}" 2>/dev/null)" || {
        json_line -n --argjson c "${ctl_no}" \
            '{card:"adaptec",ctl_no:$c,controller:null,vds:null,pds:[],sections_failed:["controller","vds","pds"]}'
        return 0
    }
    detail="${detail//$'\r'/}"

    local -a rows=()
    local ROWSEP
    ROWSEP="$(printf '\001')"
    mapfile -t rows < <(printf '%s\n' "${detail}" | awk -v S="${ROWSEP}" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function val(    s) { s = $0; sub(/^[^:]*:[[:space:]]*/, "", s); return trim(s) }
        function flushld() {
            if (ldno != "") {
                printf "LD%s%s%s%s%s%s%s%s%s%s\n", S, ldno, S, ldname, S, ldstate, S, ldlevel, S, ldsize
                ldno = ""; ldname = ""; ldstate = ""; ldlevel = ""; ldsize = ""
            }
        }
        function flushpd() {
            if (pddev != "") {
                printf "PD%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", S, pddev, S, pdenc, S, pdslot, S, pdstate, S, pdmodel, S, pdserial, S, pdwwn, S, pdsize, pdsize
                pddev = ""; pdenc = ""; pdslot = ""; pdstate = ""; pdmodel = ""; pdserial = ""; pdwwn = ""; pdsize = ""
            }
        }
        /^Controllers found:/         { next }
        /^Controller information/     { sec = "ctl"; next }
        /^Logical device information/ { sec = "ld";  next }
        /^Physical Device information/{ sec = "pd";  next }
        /^(Command completed successfully|Arrays information)/ { flushld(); flushpd(); sec = ""; next }
        sec == "ctl" && /^[[:space:]]*Controller ID/       { ctlid = val(); next }
        sec == "ctl" && /^[[:space:]]*Controller Model/    { ctlmodel = val(); next }
        sec == "ctl" && /^[[:space:]]*Status[[:space:]]*:/ { ctlstatus = val(); next }
        sec == "ld" && /^Logical Device number [0-9]+/ { flushld(); ldno = $NF; next }
        sec == "ld" && /^[[:space:]]*Logical Device name/      { ldname = val(); next }
        sec == "ld" && /^[[:space:]]*Status of Logical Device/ { ldstate = val(); next }
        sec == "ld" && /^[[:space:]]*RAID level/               { ldlevel = val(); next }
        sec == "ld" && /^[[:space:]]*Size[[:space:]]*:/        { ldsize = val(); next }
        sec == "pd" && /^[[:space:]]*Device #[0-9]+/ { flushpd(); pddev = $NF; next }
        sec == "pd" && /^[[:space:]]*Reported Channel,Device/ {
            # 行内 "(T:L)" 自带冒号, 不能用 val() 的首冒号切割
            v = $0
            sub(/^[^(]*\(T:L\)[[:space:]]*:[[:space:]]*/, "", v)
            v = trim(v)   # "0,0(0:0)" → channel,device
            split(v, cd, ",")
            pdenc = trim(cd[1]); pdslot = trim(cd[2]); sub(/\(.*/, "", pdslot)
            next
        }
        sec == "pd" && /^[[:space:]]*State[[:space:]]*:/ { pdstate = val(); next }
        sec == "pd" && /^[[:space:]]*Model[[:space:]]*:/ { pdmodel = val(); next }
        sec == "pd" && /^[[:space:]]*Serial number/      { pdserial = val(); next }
        sec == "pd" && /^[[:space:]]*World-wide name/    { pdwwn = val(); next }
        sec == "pd" && /^[[:space:]]*(Total )?Size[[:space:]]*:/ { pdsize = val(); next }
        END { flushld(); flushpd(); printf "CTL%s%s%s%s%s%s\n", S, ctlid, S, ctlmodel, S, ctlstatus }
        BEGIN { ldno = ""; pddev = ""; ctlid = ""; ctlmodel = ""; ctlstatus = "" }
    ')

    local -a vds_json=() pds_json=()
    local t a b c d e f g h
    local snorm sz un gbid sg sn2 sz2 un2 gbid2 sg2
    local ctl_model="" ctl_status=""

    for row in "${rows[@]}"; do
        IFS="${ROWSEP}" read -r t a b c d e f g h <<<"${row}"
        if [[ "${t}" == "LD" ]]; then
            # LD 行: a=no b=name c=state d=level e=size
            snorm="$(state_norm "$(strip_state_parens "${c}")")"
            sz="${e%% *}"
            un="${e#* }"
            [[ "${sz}" == "${e}" ]] && un=""
            sg="null"
            if [[ -n "${sz}" && -n "${un}" ]] && gbid="$(to_gb "${sz}" "${un}" 2>/dev/null)" && [[ -n "${gbid}" ]]; then
                sg="${gbid}"
            fi
            vds_json+=("$(json_line -n \
                --arg vd "${a}" --arg name "${b}" --arg state "${c}" --arg sn "${snorm}" \
                --arg level "${d}" --arg size "${sz}" --arg unit "${un}" --argjson size_gb "${sg}" \
                '{vd:$vd,name:(if $name=="" then null else $name end),
                  state:$state,state_norm:$sn,
                  raid_level:(if $level=="" then null else $level end),
                  size:(if $size=="" then null else $size end),
                  unit:(if $unit=="" then null else $unit end),
                  size_gb:$size_gb,pd_slots:[]}')" ) || return 1
        elif [[ "${t}" == "PD" ]]; then
            # PD 行: a=devno b=enc c=slot d=state e=model f=serial g=wwn h=size
            sn2="$(state_norm "$(strip_state_parens "${d}")")"
            sz2="${h%% *}"
            un2="${h#* }"
            [[ "${sz2}" == "${h}" ]] && un2=""
            sz2="${sz2//,/}"   # arcconf 千分位逗号: "857,375" → 857375
            sg2="null"
            if [[ -n "${sz2}" && -n "${un2}" ]] && gbid2="$(to_gb "${sz2}" "${un2}" 2>/dev/null)" && [[ -n "${gbid2}" ]]; then
                sg2="${gbid2}"
            fi
            pds_json+=("$(json_line -n \
                --arg enc "${b}" --arg slot "${c}" --arg state "${d}" --arg sn "${sn2}" \
                --arg size "${sz2}" --arg unit "${un2}" --argjson size_gb "${sg2}" \
                --arg model "${e}" --arg serial "${f}" --arg wwn "${g}" \
                '{dev:null,type:"raid",ctl_no:0,
                  enc:(if $enc == "" or ($enc | test("^[0-9]+$") | not) then null else ($enc | tonumber) end),
                  slot:(if $slot == "" or ($slot | test("^[0-9]+$") | not) then null else ($slot | tonumber) end),
                  vd:null,
                  state:(if $state=="" then null else $state end),
                  state_norm:(if $sn=="" then "unknown" else $sn end),
                  size:(if $size=="" then null else $size end),
                  unit:(if $unit=="" then null else $unit end),
                  size_gb:$size_gb,
                  model:(if $model=="" then null else $model end),
                  serial:(if $serial=="" then null else $serial end),
                  wwn:(if $wwn=="" then null else $wwn end),
                  interface:null}')" ) || return 1
        elif [[ "${t}" == "CTL" ]]; then
            ctl_model="${b}"
            ctl_status="${c}"
        fi
    done

    local vds_arr pds_arr
    vds_arr="$(printf '%s\n' "${vds_json[@]:-}" | jq -s 'map(select(length>0))')"
    pds_arr="$(printf '%s\n' "${pds_json[@]:-}" | jq -s 'map(select(length>0))')"

    local hn
    hn="$(state_norm "$(strip_state_parens "${ctl_status}")")"

    json_line -n \
        --argjson c "${ctl_no}" \
        --arg model "${ctl_model}" --arg health "${ctl_status}" --arg hn "${hn}" \
        --argjson vds "${vds_arr}" --argjson pds "${pds_arr}" \
        '{card:"adaptec",ctl_no:$c,
          controller:{type:"adaptec",ctl_no:$c,name:(if $model=="" then null else $model end),
                      health:(if $health=="" then null else $health end),health_norm:$hn,
                      vd_count:($vds|length),pd_count:($pds|length)},
          vds:$vds,pds:$pds,sections_failed:[]}'
}

# 自注册(DESIGN.md §4.1)
card_register adaptec
