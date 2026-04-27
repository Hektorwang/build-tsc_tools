#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/monitors/memory.sh — 内存运行时使用率监控
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 提供函数:
#   monitor_memory()
#     读取 free -b 输出，计算物理内存和 swap 的使用率
#     输出 JSON: {ram: {total, used, used_percent, unit}, swap: {...}}
#
# free -b 输出格式:
#   第2行: Mem:   total  used  free  shared  buff/cache  available
#   第3行: Swap:  total  used  free
#   -b 参数表示以字节为单位输出
# =============================================================================

# -----------------------------------------------------------------------------
# monitor_memory
#
# 输出:
#   JSON 对象:
#   {
#     ram:  {total: GB, used: GB, used_percent: %, unit: "G"},
#     swap: {total: GB, used: GB, used_percent: %, unit: "G"}
#   }
#   容量保留两位小数（GB），百分比保留两位小数
# -----------------------------------------------------------------------------
monitor_memory() {
    local mem_line swap_line

    # free -b 输出以字节为单位，NR==2 取内存行，NR==3 取 swap 行
    # 只取 total($2) 和 used($3) 两列
    mem_line="$(free -b | awk 'NR==2{print $2, $3}')"
    swap_line="$(free -b | awk 'NR==3{print $2, $3}')"

    local mem_total_bytes mem_used_bytes swap_total_bytes swap_used_bytes
    read -r mem_total_bytes mem_used_bytes <<<"$mem_line"
    read -r swap_total_bytes swap_used_bytes <<<"$swap_line"

    # 字节转 GB（1 GB = 1024^3 字节）
    local mem_total_g mem_used_g swap_total_g swap_used_g
    mem_total_g="$(awk -v m="${mem_total_bytes}" 'BEGIN {printf "%.2f", m / (1024^3)}')"
    mem_used_g="$(awk -v m="${mem_used_bytes}" 'BEGIN {printf "%.2f", m / (1024^3)}')"
    swap_total_g="$(awk -v m="${swap_total_bytes}" 'BEGIN {printf "%.2f", m / (1024^3)}')"
    swap_used_g="$(awk -v m="${swap_used_bytes}" 'BEGIN {printf "%.2f", m / (1024^3)}')"

    local mem_used_percent=0 swap_used_percent=0

    # 防止除零（total 为 0 时保持 0%）
    if ((mem_total_bytes > 0)); then
        mem_used_percent="$(awk "BEGIN {printf \"%.2f\", (${mem_used_bytes} / ${mem_total_bytes}) * 100}")"
    fi
    if ((swap_total_bytes > 0)); then
        swap_used_percent="$(awk "BEGIN {printf \"%.2f\", (${swap_used_bytes} / ${swap_total_bytes}) * 100}")"
    fi

    jq -n \
        --argjson mem_total "${mem_total_g}" \
        --argjson mem_used "${mem_used_g}" \
        --argjson mem_used_percent "${mem_used_percent}" \
        --argjson swap_total "${swap_total_g}" \
        --argjson swap_used "${swap_used_g}" \
        --argjson swap_used_percent "${swap_used_percent}" \
        '{
            ram: {
                total: $mem_total,
                used: $mem_used,
                used_percent: $mem_used_percent,
                unit: "G"
            },
            swap: {
                total: $swap_total,
                used: $swap_used,
                used_percent: $swap_used_percent,
                unit: "G"
            }
        }'
}
