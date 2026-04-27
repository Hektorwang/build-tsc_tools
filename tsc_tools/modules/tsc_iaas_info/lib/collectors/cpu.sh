#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/collectors/cpu.sh — CPU 静态信息采集
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 提供函数:
#   collect_cpu_info()
#     采集 CPU 型号和物理插槽数量
#     输出 JSON: {cpu: {cpu_model: "...", cpu_cnt: N}}
# =============================================================================

# -----------------------------------------------------------------------------
# collect_cpu_info
#
# 输出:
#   JSON 对象: {cpu: {cpu_model: "型号字符串", cpu_cnt: 插槽数量}}
#
# 数据来源:
#   cpu_model — /proc/cpuinfo 中 "model name" 字段，去重后取第一个
#   cpu_cnt   — lscpu 中 "Socket(s)" 字段（物理 CPU 插槽数，非逻辑核心数）
# -----------------------------------------------------------------------------
collect_cpu_info() {
    local cpu_model cpu_cnt

    # 从 /proc/cpuinfo 读取 CPU 型号
    # awk 匹配 "model name" 行，取冒号后的值；sort -u 去重；sed 去除前导空格
    cpu_model="$(awk -F : '/model name/{print $2}' /proc/cpuinfo | sort -u | sed 's/^\s*//')"

    # 从 lscpu 读取物理插槽数（Socket 数量，不是逻辑 CPU 数）
    cpu_cnt="$(lscpu | awk '/^Socket\(s\):/{print $2}')"

    jq -rcn \
        --arg model "$cpu_model" \
        --argjson cnt "$cpu_cnt" \
        '{cpu: {cpu_model: $model, cpu_cnt: $cnt}}'
}
