#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/raid/sas3.sh — SAS3 (mpt3sas) RAID 卡适配器
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 支持的控制器: LSI SAS3008、SAS3108 等 mpt3sas 驱动的 HBA/RAID 卡
# 管理工具: sas3ircu
#
# 依赖:
#   lib/common.sh — LD_KEYWORDS, PD_KEYWORDS, associate_array_to_json()
#
# 提供函数:
#   raid_check_health_sas3 <raid_bin>
#     遍历所有 SAS3 控制器，采集 IR Volume（虚拟卷）和物理磁盘状态
#     结果追加到全局变量 raid_status_json（调用方需先初始化为 "[]"）
#
# sas3ircu 输出格式说明:
#   sas3ircu list         — 列出所有控制器，格式: "  0  SAS3008  ..."
#   sas3ircu N display    — 显示控制器N的详情
#     IR Volume 段: "IR Volume information" 到 "Physical device information"
#     PD 段: "Physical device information" 到 "Enclosure information"
#     PD 行格式: "Enclosure#:2;Slot#:12;State:Ready(RDY)"（去空格后）
#
# 注意: 现场通常不用 SAS3 卡做 RAID Volume，VD 解析逻辑来自老代码改造，
#       未经实际 IR Volume 场景验证
# =============================================================================

# -----------------------------------------------------------------------------
# raid_check_health_sas3 <raid_bin>
#
# 参数:
#   raid_bin — sas3ircu 的完整路径
#
# 副作用:
#   追加到全局变量 raid_status_json（JSON 数组）
# -----------------------------------------------------------------------------
raid_check_health_sas3() {
    local RAID_BIN="$1"
    local ctls=() ctl_no

    # 获取所有控制器编号
    # grep -P 匹配以数字开头且含 "SAS" 的行（控制器列表行）
    # awk 取第1列（控制器编号）
    mapfile -t ctls < <("${RAID_BIN}" list | grep -P "^\s*\d.*?SAS" | awk '{print $1}')

    for ctl_no in "${ctls[@]}"; do
        # --- 处理 IR Volume（虚拟卷）---
        local vd_output=() vd_line
        # awk 提取 "IR Volume information" 到 "Physical device information" 之间的内容
        # grep 过滤出 IR volume 编号行和状态行
        # sed 合并相邻两行，去除空格
        mapfile -t vd_output < <(
            "${RAID_BIN}" "${ctl_no}" display |
                awk '/IR Volume information/,/Physical device information/{print}' |
                grep -E "IR volume|Status of volume" |
                sed 'N;s/\n/;/g' |
                sed 's/ //g'
        )
        local vd_no vd_stat vd_stat_cn vd_keyword
        for vd_line in "${vd_output[@]}"; do
            # 合并行格式: "IRvolume1;Statusofvolume:Okay(OKY)"
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

        # --- 处理物理磁盘 ---
        local pd_output=() pd_line
        # awk 提取 "Physical device information" 到 "Enclosure information" 之间的内容
        # grep -A 13 "Device is a Hard disk" 取每个硬盘设备后13行
        # grep -E "Slot|State" 只保留 Slot 和 State 行
        # sed 合并相邻两行（Slot 行 + State 行），去除空格
        mapfile -t pd_output < <(
            "${RAID_BIN}" "${ctl_no}" display |
                awk '/Physical device information/,/Enclosure information/{print}' |
                grep -A 13 "Device is a Hard disk" |
                grep -E "Slot|State" |
                sed 'N;s/\n/;/g' | sed 's/ //g'
        )
        # 合并行格式: "Enclosure#:2;Slot#:12;State:Ready(RDY)"
        local pd_no pd_stat pd_keyword pd_stat_cn
        for pd_line in "${pd_output[@]}"; do
            # awk -F '[;:]' 按分号或冒号分割
            # $2 是 Enclosure 编号，$4 是 State 值（跳过 Slot# 和 Slot 编号）
            pd_no="$(echo "${pd_line}" | awk -F '[;:]' '{print $2}')"
            pd_stat="$(echo "${pd_line}" | awk -F '[;:]' '{print $4}')"
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
    done
}
