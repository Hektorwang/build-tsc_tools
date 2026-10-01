#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/collectors/cpu.sh — CPU 静态信息采集 (v2)
# =============================================================================
# 复刻自 v1 collect_cpu_info, 采集逻辑不变; 被 source 使用，不可直接执行。
#
# 提供函数:
#   collect_cpu_info()
#     输出 JSON: {cpu: {cpu_model: "...", cpu_cnt: N}}
#     cpu_model — /proc/cpuinfo "model name" 去重取一
#     cpu_cnt   — lscpu "Socket(s)"(物理插槽数, 非逻辑核心数)
# =============================================================================

collect_cpu_info() {
    local cpu_model cpu_cnt

    cpu_model="$(awk -F : '/model name/{print $2}' /proc/cpuinfo | sort -u | sed 's/^\s*//')"
    cpu_cnt="$(lscpu | awk '/^Socket\(s\):/{print $2}')"

    jq -rcn \
        --arg model "${cpu_model}" \
        --argjson cnt "${cpu_cnt}" \
        '{cpu: {cpu_model: $model, cpu_cnt: $cnt}}'
}
