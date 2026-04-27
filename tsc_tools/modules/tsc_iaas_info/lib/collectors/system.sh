#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/collectors/system.sh — 系统元数据采集
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 依赖:
#   lib/common.sh — INVALID_SNS 常量（无效序列号过滤列表）
#
# 提供函数:
#   collect_serial_number <sn_override> <logfile>
#   collect_contract_no   <contract_no_override> <logfile>
#   collect_location      <location_override> <logfile>
#   collect_manufacturer
# =============================================================================

# -----------------------------------------------------------------------------
# collect_serial_number <sn_override> <logfile>
#
# 采集系统序列号，三级优先级:
#   1. sn_override 参数（命令行 --sn 传入）
#   2. logfile 中已记录的 sn（历史日志继承，避免重复采集）
#   3. dmidecode 自动获取（system-serial-number，无效则尝试 baseboard-serial-number）
#
# 参数:
#   sn_override — 命令行指定的序列号，为空则跳过此优先级
#   logfile     — 历史日志文件路径（软链接指向的上次结果），不存在则跳过
#
# 输出:
#   JSON 对象: {sn: "序列号字符串"}
#   若所有来源均无效，输出 {sn: "None"}
# -----------------------------------------------------------------------------
collect_serial_number() {
    local sn_override="${1:-}"
    local logfile="${2:-}"
    local serial=""

    if [[ -n "${sn_override}" ]]; then
        # 优先级1: 命令行参数直接使用
        serial="${sn_override}"
    else
        # 优先级2: 从历史日志继承（避免每次重新采集）
        if [[ -f "${logfile}" ]]; then
            serial="$(jq -r .sn "${logfile}" 2>/dev/null || echo "")"
        fi

        # 优先级3: dmidecode 自动获取
        if [[ -z "${serial}" ]]; then
            serial="$(dmidecode -s system-serial-number 2>/dev/null | grep -v '#' | head -n1 || echo "")"

            # 检查是否为无效占位值，若是则尝试主板序列号
            local invalid_sn
            for invalid_sn in "${INVALID_SNS[@]}"; do
                if [[ "${serial}" == "${invalid_sn}" ]]; then
                    serial="$(dmidecode -s baseboard-serial-number 2>/dev/null | head -n1 || echo "")"
                    break
                fi
            done

            # 再次检查主板序列号是否有效
            for invalid_sn in "${INVALID_SNS[@]}"; do
                if [[ "${serial}" == "${invalid_sn}" ]]; then
                    serial="None"
                    break
                fi
            done
        fi
    fi

    # 最终兜底：空字符串统一替换为 "None"
    [[ -z "${serial}" ]] && serial="None"

    jq -rcn --arg sn "${serial}" '{sn: $sn}'
}

# -----------------------------------------------------------------------------
# collect_contract_no <contract_no_override> <logfile>
#
# 采集合同号，两级优先级:
#   1. contract_no_override 参数（命令行 --contract_no 传入）
#   2. logfile 中已记录的 contract_no（历史日志继承）
#
# 参数:
#   contract_no_override — 命令行指定的合同号，为空则跳过
#   logfile              — 历史日志文件路径
#
# 输出:
#   JSON 对象: {contract_no: "合同号字符串"}（可能为空字符串）
# -----------------------------------------------------------------------------
collect_contract_no() {
    local contract_no_override="${1:-}"
    local logfile="${2:-}"
    local val=""

    if [[ -n "${contract_no_override}" ]]; then
        val="${contract_no_override}"
    elif [[ -f "${logfile}" ]]; then
        # 从历史日志继承，// "" 确保 null 值转为空字符串
        val="$(jq -r '.contract_no // ""' "${logfile}" 2>/dev/null || echo "")"
    fi

    jq -rcn --arg contract_no "${val}" '{contract_no: $contract_no}'
}

# -----------------------------------------------------------------------------
# collect_location <location_override> <logfile>
#
# 采集机器位置信息，两级优先级:
#   1. location_override 参数（命令行 --location 传入）
#   2. logfile 中已记录的 location（历史日志继承）
#
# 参数:
#   location_override — 命令行指定的位置，为空则跳过
#   logfile           — 历史日志文件路径
#
# 输出:
#   JSON 对象: {location: "位置字符串"}（可能为空字符串）
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
#
# 采集系统厂商信息（主板/整机厂商）
#
# 输出:
#   厂商字符串（非 JSON），例如 "Dell Inc." 或 "Inspur"
#   若 dmidecode 失败，输出 "Unknown"
# -----------------------------------------------------------------------------
collect_manufacturer() {
    # grep -vP 过滤空行和 dmidecode 注释行（以 # 开头）
    dmidecode -s system-manufacturer 2>/dev/null | grep -vP "^\s*$|^\s*#" || echo "Unknown"
}
