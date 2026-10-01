#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/monitors/cpu.sh — CPU 运行时使用率监控 (v2)
# =============================================================================
# 复刻自 v1 monitor_cpu, 逻辑不变; 被 source 使用，不可直接执行。
#
# 提供函数:
#   monitor_cpu()
#     两次采样 /proc/stat(间隔 1 秒)计算使用率
#     输出 JSON: {used_percent: N, iowait_percent: N}(两位小数)
# =============================================================================

monitor_cpu() {
    local user nice system idle iowait irq softirq steal guest guest_nice
    local first_sample=() second_sample=()

    read -r _ user nice system idle iowait irq softirq steal guest guest_nice </proc/stat
    first_sample=(
        "${user}" "${nice}" "${system}" "${idle}" "${iowait}"
        "${irq}" "${softirq}" "${steal}" "${guest}" "${guest_nice}"
    )

    sleep 1

    read -r _ user nice system idle iowait irq softirq steal guest guest_nice </proc/stat
    second_sample=(
        "${user}" "${nice}" "${system}" "${idle}" "${iowait}"
        "${irq}" "${softirq}" "${steal}" "${guest}" "${guest_nice}"
    )

    local total_jiffies
    total_jiffies="$((second_sample[0] - first_sample[0] +
        second_sample[1] - first_sample[1] +
        second_sample[2] - first_sample[2] +
        second_sample[3] - first_sample[3] +
        second_sample[4] - first_sample[4] +
        second_sample[5] - first_sample[5] +
        second_sample[6] - first_sample[6] +
        second_sample[7] - first_sample[7] +
        second_sample[8] - first_sample[8] +
        second_sample[9] - first_sample[9]))"

    local idle_jiffies iowait_jiffies
    idle_jiffies="$((second_sample[3] - first_sample[3]))"
    iowait_jiffies="$((second_sample[4] - first_sample[4]))"

    local cpu_used_percentage=0 iowait_percentage=0

    if [[ "${total_jiffies}" -gt 0 ]]; then
        cpu_used_percentage="$(awk "BEGIN {printf \"%.2f\", (100.0 - (${idle_jiffies} / ${total_jiffies}) * 100)}")"
        iowait_percentage="$(awk "BEGIN {printf \"%.2f\", (${iowait_jiffies} / ${total_jiffies}) * 100}")"
    fi

    jq -n \
        --argjson cpu_used "${cpu_used_percentage}" \
        --argjson iowait "${iowait_percentage}" \
        '{used_percent: $cpu_used, iowait_percent: $iowait}'
}
