#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/monitors/raid.sh — RAID 健康状态监控
# =============================================================================
# 被 source 使用，不可直接执行。
# 与 lib/monitors/cpu.sh、memory.sh、storage.sh 处于同一层级。
#
# 依赖（由调用方 run.sh 负责 source）:
#   lib/common.sh        — LD_KEYWORDS, PD_KEYWORDS, associate_array_to_json()
#   lib/raid/lsi.sh      — raid_check_health_lsi()
#   lib/raid/adaptec.sh  — raid_check_health_adaptec()
#   lib/raid/sas3.sh     — raid_check_health_sas3()
#   lib/raid/sas2.sh     — raid_check_health_sas2()
#
# 提供函数:
#   monitor_raid_health <raid_type> <raid_bin>
#     根据 RAID 类型调用对应适配器，采集所有 VD/PD 状态
#     输出 JSON 数组: [{阵列卡号, 虚拟/物理磁盘号, 状态, 中文状态}, ...]
#     若无 RAID 卡或 raid_type=none，输出 "[]"
# =============================================================================

# -----------------------------------------------------------------------------
# monitor_raid_health <raid_type> <raid_bin>
#
# 参数:
#   raid_type — RAID 控制器类型: none | lsi | adaptec | mpt3sas | mpt2sas
#               由 lib/raid/detector.sh 的 raid_detect() 函数设置
#   raid_bin  — 对应管理工具的完整路径（raid_type=none 时可为空）
#
# 输出:
#   JSON 数组，每个元素为一个 VD 或 PD 的状态对象
#   VD 元素: {阵列卡号: "N", 虚拟磁盘号: "N/N", 虚拟磁盘状态: "Optl", 虚拟磁盘中文状态: "信息(正常)"}
#   PD 元素: {阵列卡号: "N", 物理磁盘号: "252:0", 物理磁盘状态: "Onln", 物理磁盘中文状态: "信息(在线)"}
#   无 RAID 时输出: []
# -----------------------------------------------------------------------------
monitor_raid_health() {
    local raid_type="${1:-none}"
    local raid_bin="${2:-}"

    # 初始化结果累积变量（各适配器函数通过追加方式填充此变量）
    # 注意: 这是全局变量，各适配器函数直接修改它
    raid_status_json="[]"

    # 无 RAID 卡或工具路径为空时直接返回空数组
    if [[ "${raid_type}" == "none" ]] || [[ -z "${raid_bin}" ]]; then
        echo "[]"
        return 0
    fi

    # 根据 RAID 类型分发到对应适配器
    case "${raid_type}" in
    lsi)
        # LSI/MegaRAID/Broadcom，使用 storcli
        raid_check_health_lsi "${raid_bin}"
        ;;
    adaptec)
        # Adaptec，使用 arcconf
        raid_check_health_adaptec "${raid_bin}"
        ;;
    mpt3sas)
        # LSI SAS3 HBA，使用 sas3ircu
        raid_sas3 "${raid_bin}" runtime
        ;;
    mpt2sas)
        # LSI SAS2 HBA，使用 sas2ircu
        raid_check_health_sas2 "${raid_bin}"
        ;;
    *)
        # 未知类型，返回空数组
        echo "[]"
        return 0
        ;;
    esac

    # 输出最终结果（各适配器已将数据追加到 raid_status_json）
    echo "${raid_status_json}" | jq -rc .
}
