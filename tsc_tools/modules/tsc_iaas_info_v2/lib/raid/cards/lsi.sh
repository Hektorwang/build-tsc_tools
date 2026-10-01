#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016
# =============================================================================
# lib/raid/cards/lsi.sh — LSI/MegaRAID 适配器 (DESIGN.md §4.2/§4.4, 阶段2)
# =============================================================================
# 覆盖: LSI/Avago/Broadcom MegaRAID、Intel Lewisburg 内置 RAID。
# 工具: storcli / storcli64。
# 抓取(§4.4 单抓取): `storcli show`(控制器清单+System Overview 健康)
#                    → 逐控制器 `/cN show all`(全量)。
#
# 二函数契约(§4.2):
#   card_lsi_detect — 管理工具在位 且 lspci 匹配(硬件证据)
#   card_lsi_parse  — 每控制器一行全量模型(§3.4)
#
# show all 分节解析(按节降级, §3.4):
#   Basics            → controller.name(Model); 缺 → sections_failed+=controller
#   VD LIST           → vds[](DG/VD, State, Size, Name); 无 VD 属正常, 不降级
#   PD LIST           → pds[]骨架(EID:Slt, State, DG, Size, Intf, Model); 缺 → +=pds
#   Drive ... Detailed(show all 独有) → Serial Number/WWN 回填 PD
#   PD↔VD 归属        → DG 号关联(vd 字段与 pd_slots)
# =============================================================================

_lsi_storcli_bin() {
    local p
    for p in /bin/storcli /sbin/storcli /opt/MegaRAID/storcli/storcli64 "${TSC_PKG_DIR}/storcli64/storcli64-noarch"; do
        if [[ -x "${p}" ]]; then
            printf '%s\n' "${p}"
            return 0
        fi
    done
    command -v storcli64 2>/dev/null || command -v storcli 2>/dev/null
}

card_lsi_detect() {
    _lsi_storcli_bin >/dev/null || return 1
    lspci 2>/dev/null | grep -qiP "LSI|AVAGO|MegaRAID|(RAID bus controller: Intel Corporation Lewisburg)"
}

# -----------------------------------------------------------------------------
# _lsi_table_fields <输出> <节正则> <列名...>
#
# storcli 表解析器: 按表头 token 定位列。要点:
#   - Size 列在数据行占两个 token(数值+单位), 之后所有列 +1 偏移, 此处自动补偿;
#   - 列名带 @ 后缀 = 多词列(取到表尾倒数第 trail 个 token, trail=表头中该列
#     之后的 token 数, 如 PD 表 Model 后还有 Sp Type);
#   - 伪列 SizeUnit = Size 数值后的单位 token。
# 输出: 每数据行一行, 字段按入参顺序 TAB 分隔(缺落空串)。
# -----------------------------------------------------------------------------
_lsi_table_fields() {
    local output="$1" sec_re="$2"
    shift 2
    local want
    want="$(IFS=,; echo "$*")"
    local ROWSEP
    ROWSEP="$(printf '\001')"
    printf '%s\n' "${output}" | awk -v S="${ROWSEP}" -v sec_re="${sec_re}" -v want="${want}" '
        BEGIN { n = split(want, W, ",") }
        function emit(    i, c, nm, hi, di, v, trail, out) {
            out = ""
            for (i = 1; i <= n; i++) {
                c = W[i]; v = ""; di = 0
                if (c == "SizeUnit") {
                    if (sizepos != "" && sizepos + 1 <= NF) { di = sizepos + 1; v = $di }
                } else {
                    nm = c; sub(/@$/, "", nm)
                    hi = idx[nm]
                    if (hi != "") {
                        di = (sizepos != "" && hi > sizepos) ? hi + 1 : hi
                        if (c ~ /@$/) {
                            trail = k - hi
                            v = $di
                            for (j = di + 1; j <= NF - trail; j++) v = v " " $j
                        } else if (di <= NF) {
                            v = $di
                        }
                    }
                }
                if (c == "SizeUnit" && di == 0) v = ""
                out = out (i > 1 ? S : "") v
            }
            print out
        }
        # sec_re 专用于节匹配, insec 为 0/1 状态(两者混用会让 $0~sec 退化为数字匹配)
        $0 ~ sec_re { insec = 1; havehdr = 0; next }
        insec && /^[[:space:]]*$/ { insec = 0; havehdr = 0; next }
        insec && /^={3,}/ { next }
        insec && /^-{3,}/ { next }
        insec && !havehdr {
            k = 0
            m = split($0, H, /[[:space:]]+/)
            for (i = 1; i <= m; i++) if (H[i] != "") { k++; idx[H[i]] = k }
            sizepos = idx["Size"]
            havehdr = 1
            next
        }
        insec && havehdr { emit() }
    '
}

# -----------------------------------------------------------------------------
# card_lsi_parse
# -----------------------------------------------------------------------------
card_lsi_parse() {
    local storcli
    storcli="$(_lsi_storcli_bin)" || return 1
    local ROWSEP
    ROWSEP="$(printf '\001')"

    local show_out
    show_out="$("${storcli}" show 2>/dev/null)" || return 1
    show_out="${show_out//$'\r'/}"   # 防御: 容忍 CRLF 输出
    local ctl_cnt
    ctl_cnt="$(printf '%s\n' "${show_out}" | awk '/Number of Controllers/{print $NF; exit}')"
    [[ "${ctl_cnt}" =~ ^[0-9]+$ ]] || return 1

    # System Overview → 每控制器 Hlth 原文
    local -a so_rows=()
    mapfile -t so_rows < <(_lsi_table_fields "${show_out}" '^System Overview' 'Ctl' 'Hlth')
    declare -A ctl_health=()
    local row c h
    for row in "${so_rows[@]}"; do
        c="${row%%"${ROWSEP}"*}"
        h="${row#*"${ROWSEP}"}"
        if [[ "${c}" =~ ^[0-9]+$ ]]; then
            ctl_health["${c}"]="${h}"
        fi
    done

    local ctl_no
    for ((ctl_no = 0; ctl_no < ctl_cnt; ctl_no++)); do
        _lsi_parse_controller "${storcli}" "${ctl_no}" "${ctl_health[${ctl_no}]:-}"
    done
    return 0
}

# -----------------------------------------------------------------------------
# _lsi_parse_controller <storcli> <ctl_no> <health_raw>
# 单控制器: /cN show all 分节解析 → 一行全量模型
# -----------------------------------------------------------------------------
_lsi_parse_controller() {
    local storcli="$1" ctl_no="$2" health_raw="${3:-}"
    local detail
    detail="$("${storcli}" "/c${ctl_no}" show all 2>/dev/null)" || {
        json_line -n --argjson c "${ctl_no}" \
            '{card:"lsi",ctl_no:$c,controller:null,vds:null,pds:[],sections_failed:["controller","vds","pds"]}'
        return 0
    }
    detail="${detail//$'\r'/}"

    local -a sf=()

    # --- Basics 节: 控制器型号(首个 "Model =" 行; PD 节是 "Model Number =" 不冲突)
    local model
    model="$(printf '%s\n' "${detail}" | grep -m1 -E '^[[:space:]]*Model[[:space:]]*=' | sed 's/^[^=]*=[[:space:]]*//')"
    if [[ -z "${model}" ]]; then
        sf+=("controller")
        model=""
    fi

    # --- VD LIST: DG/VD Type State Access Consist Cache sCC Size Name
    local -a vd_rows=()
    mapfile -t vd_rows < <(_lsi_table_fields "${detail}" 'VD LIST' 'DG/VD' 'Type' 'State' 'Size' 'SizeUnit' 'Name@')

    # --- PD LIST: EID:Slt DID State DG Size Intf Med SED PI SeSz Model Sp Type
    local -a pd_rows=()
    mapfile -t pd_rows < <(_lsi_table_fields "${detail}" 'PD LIST' 'EID:Slt' 'State' 'DG' 'Size' 'SizeUnit' 'Intf' 'Model@')
    if ! printf '%s\n' "${detail}" | grep -q 'PD LIST'; then
        sf+=("pds")
    fi

    # --- Drive Detailed Information → serial/wwn 映射(key = E:S)
    declare -A pd_serial=() pd_wwn=()
    local cur_key="" t v
    while IFS=$'\t' read -r t v; do
        case "${t}" in
            KEY)
                cur_key="${v}"
                ;;
            SERIAL)
                if [[ -n "${cur_key}" ]]; then pd_serial["${cur_key}"]="${v}"; fi
                ;;
            WWN)
                if [[ -n "${cur_key}" ]]; then pd_wwn["${cur_key}"]="${v}"; fi
                ;;
        esac
    done < <(printf '%s\n' "${detail}" | awk '
        /Drive \/c[0-9]+(\/e[0-9]+)?\/s[0-9]+ - Detailed/ {
            key = ":"
            if (match($0, /\/e[0-9]+\//)) {
                key = substr($0, RSTART + 2, RLENGTH - 3) ":"
            }
            if (match($0, /\/s[0-9]+/)) {
                key = key substr($0, RSTART + 2, RLENGTH - 2)
            }
            printf "KEY\t%s\n", key
            next
        }
        /^[[:space:]]*Serial Number[[:space:]]*=/ {
            v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
            printf "SERIAL\t%s\n", v
            next
        }
        /^[[:space:]]*WWN[[:space:]]*=/ {
            v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
            printf "WWN\t%s\n", v
            next
        }
    ')

    # --- 组装 vds[](并建 DG→VD 映射) ---
    local -a vds_json=()
    declare -A dg_vd=() dg_slots=()
    local dg vd state state_norm size unit vname gbid level
    if (( ${#vd_rows[@]} > 0 )); then
        for row in "${vd_rows[@]}"; do
            IFS="${ROWSEP}" read -r dgvd level state size unit vname <<<"${row}"
            dg="${dgvd%%/*}"
            vd="${dgvd##*/}"
            if [[ -n "${dg}" ]]; then
                dg_vd["${dg}"]="${vd}"
            fi
            state_norm="$(strip_state_parens "${state}" | { read -r s; state_norm "${s}"; })"
            [[ -z "${state_norm}" ]] && state_norm="unknown"
            size_gb_json="null"
            if [[ -n "${size}" && -n "${unit}" ]] && gbid="$(to_gb "${size}" "${unit}" 2>/dev/null)" && [[ -n "${gbid}" ]]; then
                size_gb_json="${gbid}"
            fi
            vds_json+=("$(json_line -n \
                --arg vd "${vd}" --arg state "${state}" --arg sn "${state_norm}" \
                --arg level "${level}" --arg size "${size}" --arg unit "${unit}" \
                --argjson size_gb "${size_gb_json}" --arg name "${vname}" \
                '{vd:$vd,state:$state,state_norm:$sn,raid_level:$level,
                  size:$size,unit:$unit,size_gb:$size_gb,
                  name:(if $name=="" then null else $name end),pd_slots:[]}')" ) || return 1
        done
    fi

    # --- 组装 pds[] ---
    local -a pds_json=()
    local eidslt enc slot pd_dg intfname pname
    if (( ${#pd_rows[@]} > 0 )); then
        for row in "${pd_rows[@]}"; do
            IFS="${ROWSEP}" read -r eidslt state pd_dg size unit intfname pname <<<"${row}"
            enc="${eidslt%%:*}"
            slot="${eidslt##*:}"
            vd="${dg_vd[${pd_dg}]:-}"
            [[ -z "${vd}" ]] && vd=""
            state_norm="$(strip_state_parens "${state}" | { read -r s; state_norm "${s}"; })"
            [[ -z "${state_norm}" ]] && state_norm="unknown"
            size_gb_json="null"
            if [[ -n "${size}" && -n "${unit}" ]] && gbid="$(to_gb "${size}" "${unit}" 2>/dev/null)" && [[ -n "${gbid}" ]]; then
                size_gb_json="${gbid}"
            fi
            pds_json+=("$(json_line -n \
                --arg enc "${enc}" --arg slot "${slot}" --arg vd "${vd}" \
                --arg state "${state}" --arg sn "${state_norm}" \
                --arg size "${size}" --arg unit "${unit}" \
                --argjson size_gb "${size_gb_json}" \
                --arg model "${pname}" \
                --arg serial "${pd_serial[${eidslt}]:-}" \
                --arg wwn "${pd_wwn[${eidslt}]:-}" \
                --arg intf "${intfname}" \
                '{dev:null,type:"raid",ctl_no:0,
                  enc:(if $enc == "" or ($enc | test("^[0-9]+$") | not) then null else ($enc | tonumber) end),
                  slot:(if $slot == "" or ($slot | test("^[0-9]+$") | not) then null else ($slot | tonumber) end),
                  vd:(if $vd=="" then null else $vd end),
                  state:$state,state_norm:$sn,
                  size:$size,unit:(if $unit=="" then null else $unit end),size_gb:$size_gb,
                  model:(if $model=="" then null else $model end),
                  serial:(if $serial=="" then null else $serial end),
                  wwn:(if $wwn=="" then null else $wwn end),
                  interface:(if $intf=="" then null else $intf end)}')" ) || return 1
            # DG→PD 归属记录(填 vds 的 pd_slots)
            if [[ -n "${pd_dg}" && -n "${vd}" ]]; then
                dg_slots["${vd}"]="${dg_slots[${vd}]:-} ${eidslt}"
            fi
        done
    fi

    # --- 回填 vds[].pd_slots ---
    local i vdj slots_arr
    local -a vds_final=()
    for i in "${!vds_json[@]}"; do
        vdj="${vds_json[$i]}"
        vd="$(jq -r '.vd' <<<"${vdj}")"
        slots_arr=()
        # shellcheck disable=SC2206  # 按空格分词是有意行为
        slots_arr=(${dg_slots[${vd}]:-})
        # 槽位串("252:0")非合法 JSON, 须 -R 逐行转字符串再收集
        vdj="$(jq -c --argjson s \
            "$(printf '%s\n' "${slots_arr[@]:-}" | jq -R '. | select(length>0)' | jq -s '.')" \
            '.pd_slots = $s' <<<"${vdj}")"
        vds_final+=("${vdj}")
    done

    # --- 控制器对象 ---
    local health_norm
    health_norm="$(strip_state_parens "${health_raw}" | { read -r s; state_norm "${s}"; })"
    [[ -z "${health_norm}" ]] && health_norm="unknown"

    local vds_arr pds_arr sf_arr
    vds_arr="$(printf '%s\n' "${vds_final[@]:-}" | jq -s 'map(select(length>0))')"
    pds_arr="$(printf '%s\n' "${pds_json[@]:-}" | jq -s 'map(select(length>0))')"
    sf_arr="$(printf '%s\n' "${sf[@]:-}" | jq -s 'map(select(length>0))')"

    json_line -n \
        --argjson c "${ctl_no}" \
        --arg model "${model}" \
        --arg health "${health_raw}" \
        --arg hn "${health_norm}" \
        --argjson vds "${vds_arr}" \
        --argjson pds "${pds_arr}" \
        --argjson sf "${sf_arr}" \
        '{card:"lsi",ctl_no:$c,
          controller:{type:"lsi",ctl_no:$c,name:(if $model=="" then null else $model end),
                      health:(if $health=="" then null else $health end),health_norm:$hn,
                      vd_count:($vds|length),pd_count:($pds|length)},
          vds:$vds,pds:$pds,sections_failed:$sf}'
}

# 自注册(DESIGN.md §4.1)
card_register lsi
