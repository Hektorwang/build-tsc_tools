#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/collectors/system.sh — 系统元数据采集 (v2)
# =============================================================================
# 复刻自 v1 collect_serial_number/collect_contract_no/collect_location/
# collect_manufacturer, 逻辑不变; 被 source 使用，不可直接执行。
#
# 依赖:
#   lib/common.sh — INVALID_SNS 常量
#
# 提供函数:
#   collect_serial_number <sn_override> <logfile>
#   collect_contract_no   <contract_no_override> <logfile>
#   collect_location      <location_override> <logfile>
#   collect_manufacturer
# =============================================================================

# -----------------------------------------------------------------------------
# collect_serial_number <sn_override> <logfile>
# 三级优先级: 命令行 --sn > 历史日志继承 > dmidecode(无效回退主板序列号)
# 输出: {sn: "..."}(全部来源无效时为 {sn: "None"})
# -----------------------------------------------------------------------------
collect_serial_number() {
    local sn_override="${1:-}"
    local logfile="${2:-}"
    local serial=""

    if [[ -n "${sn_override}" ]]; then
        serial="${sn_override}"
    else
        if [[ -f "${logfile}" ]]; then
            serial="$(jq -r .sn "${logfile}" 2>/dev/null || echo "")"
        fi

        if [[ -z "${serial}" ]]; then
            serial="$(dmidecode -s system-serial-number 2>/dev/null | grep -v '#' | head -n1 || echo "")"

            local invalid_sn
            for invalid_sn in "${INVALID_SNS[@]}"; do
                if [[ "${serial}" == "${invalid_sn}" ]]; then
                    serial="$(dmidecode -s baseboard-serial-number 2>/dev/null | head -n1 || echo "")"
                    break
                fi
            done

            for invalid_sn in "${INVALID_SNS[@]}"; do
                if [[ "${serial}" == "${invalid_sn}" ]]; then
                    serial="None"
                    break
                fi
            done
        fi
    fi

    [[ -z "${serial}" ]] && serial="None"

    jq -rcn --arg sn "${serial}" '{sn: $sn}'
}

# -----------------------------------------------------------------------------
# collect_contract_no <contract_no_override> <logfile>
# 两级优先级: 命令行 --contract_no > 历史日志继承
# 输出: {contract_no: "..."}(可能为空字符串)
# -----------------------------------------------------------------------------
collect_contract_no() {
    local contract_no_override="${1:-}"
    local logfile="${2:-}"
    local val=""

    if [[ -n "${contract_no_override}" ]]; then
        val="${contract_no_override}"
    elif [[ -f "${logfile}" ]]; then
        val="$(jq -r '.contract_no // ""' "${logfile}" 2>/dev/null || echo "")"
    fi

    jq -rcn --arg contract_no "${val}" '{contract_no: $contract_no}'
}

# -----------------------------------------------------------------------------
# collect_location <location_override> <logfile>
# 两级优先级: 命令行 --location > 历史日志继承
# 输出: {location: "..."}(可能为空字符串)
# -----------------------------------------------------------------------------
collect_location() {
    local location_override="${1:-}"
    local logfile="${2:-}"
    local val=""

    if [[ -n "${location_override}" ]]; then
        val="${location_override}"
    elif [[ -f "${logfile}" ]]; then
        val="$(jq -r '.location // ""' "${logfile}" 2>/dev/null || echo "")"
    fi

    jq -rcn --arg location "${val}" '{location: $location}'
}

# -----------------------------------------------------------------------------
# collect_manufacturer
# 输出: 厂商字符串(非 JSON), dmidecode 失败时 "Unknown"
# -----------------------------------------------------------------------------
collect_manufacturer() {
    dmidecode -s system-manufacturer 2>/dev/null | grep -vP "^\s*$|^\s*#" || echo "Unknown"
}
