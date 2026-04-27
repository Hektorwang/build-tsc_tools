#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/raid/lsi.sh — LSI/MegaRAID RAID 卡适配器
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 支持的控制器: LSI Logic MegaRAID、Broadcom/Avago MegaRAID、
#               Intel Lewisburg 平台内置 RAID 控制器
# 管理工具: storcli 或 storcli64
#
# 依赖:
#   lib/common.sh — LD_KEYWORDS, PD_KEYWORDS, associate_array_to_json()
#
# 提供函数:
#   raid_check_health_lsi <raid_bin>
#     遍历所有控制器，采集 VD（虚拟磁盘）和 PD（物理磁盘）状态
#     结果追加到全局变量 raid_status_json（调用方需先初始化为 "[]"）
#
# storcli 输出格式说明:
#   storcli show          — 显示控制器数量（Number of Controllers: N）
#   storcli /c0 show      — 显示控制器0的详情，包含 VD LIST 和 PD LIST 段
#   VD LIST 格式: DG/VD  TYPE  State  Access  Consist  Cache  Cac  sCC  Size  Name
#   PD LIST 格式: EID:Slt DID State DG       Size Intf Med SED PI SeSz Model  Sp
# =============================================================================

# -----------------------------------------------------------------------------
# raid_check_health_lsi <raid_bin>
#
# 参数:
#   raid_bin — storcli 或 storcli64 的完整路径
#
# 副作用:
#   追加到全局变量 raid_status_json（JSON 数组）
#   每个 VD 追加: {阵列卡号, 虚拟磁盘号, 虚拟磁盘状态, 虚拟磁盘中文状态}
#   每个 PD 追加: {阵列卡号, 物理磁盘号, 物理磁盘状态, 物理磁盘中文状态}
# -----------------------------------------------------------------------------
raid_check_health_lsi() {
    local RAID_BIN="$1"
    local ctl_cnt ctl_no vd_cnt

    # 获取控制器总数，例如 "Number of Controllers = 1" → 取最后一个字段
    ctl_cnt="$("${RAID_BIN}" show | awk '/Number of Controllers/{print $NF}')"

    # 遍历每个控制器（从 0 开始编号）
    for ((ctl_no = 0; ctl_no < "${ctl_cnt}"; ctl_no++)); do
        local storcli_out
        storcli_out="$("${RAID_BIN}" /c"${ctl_no}" show 2>/dev/null)"

        # --- 处理 VD（虚拟磁盘/逻辑卷）---
        # 从输出中提取 VD 数量，例如 "Virtual Drives = 2" → 取最后字段
        vd_cnt="$(echo "${storcli_out}" | awk '/Virtual Drives/{print $NF}')"
        local vd_no vd_stat vd_keyword vd_stat_cn line
        unset vd_info
        local -A vd_info

        # 从 "VD LIST" 段提取 VD 状态行
        # grep -A N 取 VD LIST 后 N 行，tail -n vd_cnt 取最后 vd_cnt 行（跳过表头）
        while read -r line; do
            # VD 编号格式: "0/0" → 取斜杠前的部分作为 VD 号
            vd_no="$(echo "${line}" | awk -F / '{print $1}')"
            # 第3列是状态，例如 Optl、Dgrd、OfLn
            vd_stat="$(echo "${line}" | awk '{print $3}')"
            vd_stat_cn=""
            # 遍历 LD_KEYWORDS 映射表，找到匹配的中文描述
            for vd_keyword in "${LD_KEYWORDS[@]}"; do
                if echo "${vd_stat}" | grep -iq "${vd_keyword%%|*}"; then
                    vd_stat_cn="${vd_keyword##*|}"
                    break
                fi
            done
            vd_info=(
                [阵列卡号]="${ctl_no}"
                [虚拟磁盘号]="${vd_no}"
                [虚拟磁盘状态]="${vd_stat}"
                [虚拟磁盘中文状态]="${vd_stat_cn}"
            )
            # 将 vd_info 序列化为 JSON 并追加到结果数组
            raid_status_json="$(
                jq -c --argjson new "$(associate_array_to_json vd_info)" '. + [$new]' <<<"$raid_status_json"
            )"
        done < <(echo "${storcli_out}" | grep -A "$((vd_cnt + 5))" "VD LIST" | tail -n "${vd_cnt}")

        # --- 处理 PD（物理磁盘）---
        local pd_cnt pd_no pd_stat pd_keyword pd_stat_cn
        pd_cnt="$(echo "${storcli_out}" | awk '/Physical Drives/{print $NF}')"
        unset pd_info
        local -A pd_info

        # 从 "PD LIST" 段提取 PD 状态行
        while read -r line; do
            # PD 编号格式: "252:0"（EID:Slot），取第1列
            pd_no="$(echo "${line}" | awk '{print $1}')"
            # 第3列是状态，例如 Onln、Offln、Rbld
            pd_stat="$(echo "${line}" | awk '{print $3}')"
            pd_stat_cn=""
            for pd_keyword in "${PD_KEYWORDS[@]}"; do
                if echo "${pd_stat}" | grep -iq "${pd_keyword%%|*}"; then
                    pd_stat_cn="${pd_keyword##*|}"
                    break
                fi
            done
            pd_info=(
                [阵列卡号]="${ctl_no}"
                [物理磁盘号]="${pd_no}"
                [物理磁盘状态]="${pd_stat}"
                [物理磁盘中文状态]="${pd_stat_cn}"
            )
            raid_status_json="$(
                jq -c --argjson new "$(associate_array_to_json pd_info)" '. + [$new]' <<<"$raid_status_json"
            )"
        done < <(echo "${storcli_out}" | grep -A "$((pd_cnt + 5))" "PD LIST" | tail -n "${pd_cnt}")
    done
}
