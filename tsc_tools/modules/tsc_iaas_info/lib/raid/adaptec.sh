#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/raid/adaptec.sh — Adaptec RAID 卡适配器
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 支持的控制器: Adaptec Series 5/6/7/8 SAS/SATA RAID 控制器
# 管理工具: arcconf
#
# 依赖:
#   lib/common.sh — LD_KEYWORDS, PD_KEYWORDS, associate_array_to_json()
#
# 提供函数:
#   raid_check_health_adaptec <raid_bin>
#     采集 LD（逻辑设备）和 PD（物理设备）状态
#     结果追加到全局变量 raid_status_json（调用方需先初始化为 "[]"）
#
# arcconf 输出格式说明:
#   arcconf GETCONFIG 1 LD  — 获取控制器1的逻辑设备配置
#     包含 "Logical Device number N" 和 "Status of Logical Device: Optimal" 等行
#   arcconf GETCONFIG 1 PD  — 获取控制器1的物理设备配置
#     包含 "Device #N" 和 "State: Online" 等行
#
# 注意: Adaptec 通常只有一个控制器（ctl_no 固定为 "0"），
#       实际使用中未见多控制器场景
# =============================================================================

# -----------------------------------------------------------------------------
# raid_check_health_adaptec <raid_bin>
#
# 参数:
#   raid_bin — arcconf 的完整路径
#
# 副作用:
#   追加到全局变量 raid_status_json（JSON 数组）
#   每个 LD 追加: {阵列卡号, 虚拟磁盘号, 虚拟磁盘状态, 虚拟磁盘中文状态}
#   每个 PD 追加: {阵列卡号, 物理磁盘号, 物理磁盘状态, 物理磁盘中文状态}
# -----------------------------------------------------------------------------
raid_check_health_adaptec() {
    local RAID_BIN="$1"
    local ctl_no="0"   # Adaptec 通常只有一个控制器
    local vd_output=() vd_line

    # 获取逻辑设备列表
    # grep 提取 "Logical Device number" 和 "Status of Logical Device" 行
    # sed 'N; s/\n/;/' 将相邻两行合并（设备号行 + 状态行 → 一行，分号分隔）
    # sed 's/(Logical Device number)/\1:/' 在 "Logical Device number" 后加冒号便于解析
    # s/[[:space:]]+//g 去除所有空格
    mapfile -t vd_output < <(
        "${RAID_BIN}" GETCONFIG 1 LD |
            grep -E "Logical Device number|Status of Logical Device" |
            sed -E 'N; s/\n/;/; s/(Logical Device number)/\1:/g; s/[[:space:]]+//g'
    )

    local vd_no vd_stat vd_stat_cn vd_keyword
    for vd_line in "${vd_output[@]}"; do
        # 合并行格式: "LogicalDevicenumber:0;StatusofLogicalDevice:Optimal"
        # awk -F '[;:]' 按分号或冒号分割，$2 是设备号，$NF 是状态值
        vd_no="$(echo "${vd_line}" | awk -F '[;:]' '{print $2}')"
        vd_stat="$(echo "${vd_line}" | awk -F ":" '{print $NF}')"
        vd_stat_cn=""
        for vd_keyword in "${LD_KEYWORDS[@]}"; do
            if echo "${vd_stat}" | grep -iq "${vd_keyword%%|*}"; then
                vd_stat_cn="${vd_keyword##*|}"
                break
            fi
        done
        unset vd_info
        local -A vd_info
        vd_info=(
            [阵列卡号]="${ctl_no}"
            [虚拟磁盘号]="${vd_no}"
            [虚拟磁盘状态]="${vd_stat}"
            [虚拟磁盘中文状态]="${vd_stat_cn}"
        )
        raid_status_json="$(
            jq -c --argjson new "$(associate_array_to_json vd_info)" '. + [$new]' <<<"$raid_status_json"
        )"
    done

    local pd_output=() pd_line
    # 获取物理设备列表
    # grep -Ew "Device |State" 提取设备行和状态行（-w 全词匹配避免误匹配）
    # grep -v "Power State" 过滤掉电源状态行（不是磁盘状态）
    # sed 'N; s/\n/;/g' 合并相邻两行
    # grep State 只保留含 State 的合并行（过滤掉只有 Device 行的情况）
    mapfile -t pd_output < <(
        "${RAID_BIN}" GETCONFIG 1 PD |
            grep -Ew "Device |State" |
            grep -v "Power State" |
            sed -E ' N; s/\n/;/g; s/[[:space:]]+//g' |
            grep State
    )

    local pd_no pd_stat pd_keyword pd_stat_cn
    for pd_line in "${pd_output[@]}"; do
        # 合并行格式: "Device#3;State:Online,SpunUp"
        # awk -F '[#;:]' 按 #、; 或 : 分割，$2 是设备号，$NF 是状态值
        pd_no="$(echo "${pd_line}" | awk -F '[#;:]' '{print $2}')"
        pd_stat="$(echo "${pd_line}" | awk -F '[#;:]' '{print $NF}')"
        pd_stat_cn=""
        for pd_keyword in "${PD_KEYWORDS[@]}"; do
            if echo "${pd_stat}" | grep -iq "${pd_keyword%%|*}"; then
                pd_stat_cn="${pd_keyword##*|}"
                break
            fi
        done
        unset pd_info
        local -A pd_info
        pd_info=(
            [阵列卡号]="${ctl_no}"
            [物理磁盘号]="${pd_no}"
            [物理磁盘状态]="${pd_stat}"
            [物理磁盘中文状态]="${pd_stat_cn}"
        )
        raid_status_json="$(
            jq -c --argjson new "$(associate_array_to_json pd_info)" '. + [$new]' <<<"$raid_status_json"
        )"
    done
}
