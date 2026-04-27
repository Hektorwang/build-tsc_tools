#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/common.sh — 公共常量与工具函数库
# =============================================================================
# 本文件被所有 lib/ 模块 source 使用，不可直接执行。
# 不设置 set -o errexit 等 strict mode，由调用方自行决定。
#
# 提供:
#   常量: INVALID_SNS, LD_KEYWORDS, PD_KEYWORDS
#   函数: associate_array_to_json(), array_to_json()
# =============================================================================

# -----------------------------------------------------------------------------
# INVALID_SNS — 无效序列号列表
# dmidecode 在某些主板上会返回这些占位值，需要过滤后再用 baseboard-serial-number 兜底
# -----------------------------------------------------------------------------
readonly INVALID_SNS=('1234567890' '01234567890' '0000000000' 'To be filled by O.E.M.' '')

# -----------------------------------------------------------------------------
# LD_KEYWORDS — VD（虚拟磁盘/逻辑卷）状态关键字映射表
# 格式: "英文状态关键字|中文描述"
# 按严重级别从高到低排列，确保 grep 匹配时优先命中更严重的状态
# 使用方: 遍历数组，用 ${keyword%%|*} 取英文部分做 grep，${keyword##*|} 取中文描述
# -----------------------------------------------------------------------------
readonly LD_KEYWORDS=(
    "Offline|严重(离线)"
    "OfLn|严重(离线)"
    "Impacted|告警(条带化错误)"
    "InterimRecovery|告警(尝试临时恢复)"
    "Rebuild|告警(正在重建)"
    "Degraded|告警(被降级)"
    "Pdgd|告警(部分降级)"
    "Dgrd|告警(被降级)"
    "Optimal|信息(正常)"
    "OK|信息(正常)"
    "Optl|信息(正常)"
    "Online|信息(在线)"
)

# -----------------------------------------------------------------------------
# PD_KEYWORDS — PD（物理磁盘）状态关键字映射表
# 格式同 LD_KEYWORDS，按严重级别从高到低排列
# -----------------------------------------------------------------------------
readonly PD_KEYWORDS=(
    "Offln|严重(离线)"
    "Failed|严重(损坏)"
    "Offline|严重(离线)"
    "Unconfigured(bad)|告警(已坏未使用)"
    "Rebuild|告警(正在重建)"
    "Foreign|告警(含阵列配置的待用盘)"
    "Rbld|告警(正在重建)"
    "UBad|告警(已坏未使用)"
    "DHS|信息(热备盘)"
    "GHS|信息(全局热备盘)"
    "Hot Spare|信息(热备盘)"
    "Hotspare,Spundown|信息(热备盘)"
    "JBOD|信息(正常)"
    "OK|信息(正常)"
    "Online,SpunUp|信息(在线)"
    "Online|信息(在线)"
    "Onln|信息(在线)"
    "Optimal|信息(正常)"
    "Raw|信息(直通盘)"
    "Ready|信息(未配置Raid)"
    "Sntze|信息(清洁状态)"
    "UGood|信息(未格式化待用)"
    "Unconfigured(good)|信息(未格式化待用)"
)

# -----------------------------------------------------------------------------
# associate_array_to_json <array_name>
# 将 Bash 关联数组序列化为紧凑 JSON 对象。
#
# 参数:
#   array_name — 关联数组的变量名（字符串，非引用）
#
# 输出: 紧凑 JSON 对象，例如 {"key1":"val1","key2":"val2"}
#       若数组为空，输出 {}
#
# 实现说明:
#   使用 ASCII 25（$'\x19'，Unit Separator）作为内部分隔符，
#   该字符极少出现在实际值中，避免与磁盘型号、序列号等内容冲突。
#   通过 eval 动态读取数组内容（Bash 不支持数组引用传递）。
# -----------------------------------------------------------------------------
associate_array_to_json() {
    local arr_name="$1"
    local sep=$'\x19'   # ASCII 25，Unit Separator，用作 key/value 间的分隔符
    local out="" key val
    local keys=()

    # 动态获取关联数组的所有 key
    set -f
    eval "keys=(\"\${!${arr_name}[@]}\")" 2>/dev/null || keys=()
    set +f

    if ((${#keys[@]} == 0)); then
        printf '%s\n' '{}'
        return
    fi

    # 将所有 key-value 对拼接为 sep 分隔的字符串
    for key in "${keys[@]}"; do
        set -f
        eval "val=\${${arr_name}[\"\$key\"]-}" 2>/dev/null || val=""
        set +f
        out+="${key}${sep}${val}${sep}"
    done

    # 用 jq 将 sep 分隔的扁平列表转换为 JSON 对象
    # split 后得到 [k1, v1, k2, v2, ...]，每两个元素构成一个 {key: value} 对
    printf '%s' "$out" | jq -R -s --arg sep "$sep" -c '
        (split($sep)[:-1]) as $a |
        [range(0; ($a|length); 2) | { ($a[.]) : $a[. + 1] }] |
        add
    '
}

# -----------------------------------------------------------------------------
# array_to_json <value> [<value> ...]
# 将位置参数列表序列化为 JSON 数组。
#
# 参数:
#   任意数量的字符串值
#
# 输出: JSON 数组，例如 ["val1","val2","val3"]
# -----------------------------------------------------------------------------
array_to_json() {
    local sep=$'\x19'   # 同 associate_array_to_json，使用 ASCII 25 作为分隔符
    {
        for v in "$@"; do
            printf '%s%s' "$v" "$sep"
        done
    } |
        jq -Rrcs --arg sep "$sep" '
            (split($sep)[:-1]) as $a | $a
        '
}
