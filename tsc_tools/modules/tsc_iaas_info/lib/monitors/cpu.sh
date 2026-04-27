#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/monitors/cpu.sh — CPU 运行时使用率监控
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 提供函数:
#   monitor_cpu()
#     通过两次采样 /proc/stat 计算 CPU 使用率（采样间隔 1 秒）
#     输出 JSON: {used_percent: N, iowait_percent: N}
#
# /proc/stat 格式说明:
#   cpu  user nice system idle iowait irq softirq steal guest guest_nice
#   各字段单位为 jiffies（时钟滴答数），通过两次采样的差值计算使用率
# =============================================================================

# -----------------------------------------------------------------------------
# monitor_cpu
#
# 输出:
#   JSON 对象: {used_percent: CPU使用率, iowait_percent: IO等待率}
#   百分比保留两位小数，例如 {"used_percent": 12.34, "iowait_percent": 0.56}
#
# 计算方法:
#   total_jiffies = 所有字段差值之和（两次采样之差）
#   idle_jiffies  = idle 字段差值
#   iowait_jiffies = iowait 字段差值
#   used_percent  = (1 - idle/total) * 100
#   iowait_percent = iowait/total * 100
# -----------------------------------------------------------------------------
monitor_cpu() {
    local user nice system idle iowait irq softirq steal guest guest_nice
    local first_sample=() second_sample=()

    # 第一次采样：读取 /proc/stat 第一行（cpu 汇总行，以 "cpu " 开头）
    # read -r _ 跳过第一个字段（"cpu" 字符串）
    read -r _ user nice system idle iowait irq softirq steal guest guest_nice </proc/stat
    first_sample=(
        "${user}" "${nice}" "${system}" "${idle}" "${iowait}"
        "${irq}" "${softirq}" "${steal}" "${guest}" "${guest_nice}"
    )

    # 等待 1 秒，让 CPU 活动产生可测量的差值
    sleep 1

    # 第二次采样
    read -r _ user nice system idle iowait irq softirq steal guest guest_nice </proc/stat
    second_sample=(
        "${user}" "${nice}" "${system}" "${idle}" "${iowait}"
        "${irq}" "${softirq}" "${steal}" "${guest}" "${guest_nice}"
    )

    # 计算 1 秒内的总 jiffies 差值（所有 CPU 状态的变化量之和）
    local total_jiffies
    total_jiffies="$((
        second_sample[0] - first_sample[0] +   # user
        second_sample[1] - first_sample[1] +   # nice
        second_sample[2] - first_sample[2] +   # system
        second_sample[3] - first_sample[3] +   # idle
        second_sample[4] - first_sample[4] +   # iowait
        second_sample[5] - first_sample[5] +   # irq
        second_sample[6] - first_sample[6] +   # softirq
        second_sample[7] - first_sample[7] +   # steal
        second_sample[8] - first_sample[8] +   # guest
        second_sample[9] - first_sample[9]     # guest_nice
    ))"

    # idle 和 iowait 的差值（用于计算使用率）
    local idle_jiffies iowait_jiffies
    idle_jiffies="$((second_sample[3] - first_sample[3]))"
    iowait_jiffies="$((second_sample[4] - first_sample[4]))"

    local cpu_used_percentage=0 iowait_percentage=0

    # 防止除零（理论上 total_jiffies 不会为 0，但做防御性检查）
    if [[ "${total_jiffies}" -gt 0 ]]; then
        # CPU 使用率 = (1 - idle/total) * 100
        cpu_used_percentage="$(awk "BEGIN {printf \"%.2f\", (100.0 - (${idle_jiffies} / ${total_jiffies}) * 100)}")"
        # IO 等待率 = iowait/total * 100
        iowait_percentage="$(awk "BEGIN {printf \"%.2f\", (${iowait_jiffies} / ${total_jiffies}) * 100}")"
    fi

    jq -n \
        --argjson cpu_used "${cpu_used_percentage}" \
        --argjson iowait "${iowait_percentage}" \
        '{used_percent: $cpu_used, iowait_percent: $iowait}'
}
