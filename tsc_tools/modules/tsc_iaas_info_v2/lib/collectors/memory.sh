#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/collectors/memory.sh — 内存静态信息采集 (v2)
# =============================================================================
# 复刻自 v1 collect_mem_info, 采集逻辑不变; 被 source 使用，不可直接执行。
#
# 提供函数:
#   collect_mem_info()
#     数据来源: dmidecode -t17, Size+Locator 两行合并处理, 过滤空插槽
#     单位处理: MB → GB; 其他单位跳过
#     输出 JSON: {memory: [{size: N, locator: "...", unit: "G"}, ...]}
# =============================================================================

collect_mem_info() {
    local mem_info

    mapfile -t mem_info < <(
        dmidecode -t17 | grep -vP "^\s*$|^\s*#" | grep -P '^\s*Size:|^\s*Locator:' |
            sed 'N;s/\n/\t/g' |
            grep -v "No Module Installed"
    )

    for line in "${mem_info[@]}"; do
        local size_val size_unit locator_val

        size_val="$(awk '{print $2}' <<<"${line}")"
        size_unit="$(awk '{print $3}' <<<"${line}")"
        locator_val="$(cut -d: -f3- <<<"${line}" | sed 's/^ *//')"

        if [[ "${size_unit}" == "MB" ]]; then
            size_val="$(awk "BEGIN{printf \"%.2f\", ${size_val} / 1024}")"
        elif [[ "${size_unit}" != "GB" ]]; then
            continue
        fi

        jq -n \
            --arg locator "${locator_val}" \
            --argjson size "${size_val}" \
            '{"size": $size, locator: $locator, unit: "G"}'
    done |
        jq -rcs '{memory: .}'
}
