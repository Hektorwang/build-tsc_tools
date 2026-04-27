#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034
# =============================================================================
# lib/runtime_main.sh — 运行时监控编排
# =============================================================================
# 被 run.sh source 使用，不可直接执行。
# 对应原 run.sh 中的 runtime() 函数，将其拆分为独立模块。
#
# 依赖（由调用方 run.sh 负责 source）:
#   lib/common.sh              — 公共常量
#   lib/raid/detector.sh       — raid_detect()
#   lib/raid/lsi.sh, adaptec.sh, sas3.sh, sas2.sh — RAID 适配器
#   lib/monitors/cpu.sh        — monitor_cpu()
#   lib/monitors/memory.sh     — monitor_memory()
#   lib/monitors/storage.sh    — monitor_mountpoints()
#   lib/monitors/raid.sh       — monitor_raid_health()
#   lib/collectors/cpu.sh      — collect_cpu_info()（用于硬件变化对比）
#   lib/collectors/memory.sh   — collect_mem_info()（用于硬件变化对比）
#   lib/collectors/storage.sh  — collect_disk_info()（用于磁盘数量对比）
#   lib/alert.sh               — generate_threshold_alerts(),
#                                generate_hardware_change_alerts(),
#                                generate_raid_alerts()
#
# 提供函数:
#   run_runtime_monitor <cpu_threshold> <memory_threshold> <storage_threshold> <logfile>
# =============================================================================

# -----------------------------------------------------------------------------
# run_runtime_monitor <cpu_threshold> <memory_threshold> <storage_threshold> <logfile>
#
# 编排所有运行时监控器，生成告警，输出完整运行时状态 JSON。
#
# 参数:
#   cpu_threshold     — CPU 使用率告警阈值（百分比，默认 90）
#   memory_threshold  — 内存使用率告警阈值（百分比，默认 90）
#   storage_threshold — 存储使用率告警阈值（百分比，默认 90）
#   logfile           — 历史日志文件路径，用于硬件变化对比告警
#
# 输出:
#   运行时状态 JSON:
#   {
#     storage: {
#       mountpoint: [...],   # 挂载点信息
#       raid: [...]          # RAID 状态（仅物理机且有 RAID 卡时存在）
#     },
#     memory: {ram: {...}, swap: {...}},
#     cpu: {used_percent, iowait_percent},
#     warning: {
#       cpu_usage: "...",           # CPU 超阈值告警
#       memory_usage: "...",        # 内存超阈值告警
#       storage_usage: "...",       # 存储容量超阈值告警
#       inode_usage: "...",         # inode 超阈值告警
#       storage_unwritable: "...",  # 挂载点不可写告警
#       pd_cnt_diffrent: "...",     # RAID 盘数量变化告警
#       direct_disk_cnt_diffrent: "...", # 直通盘数量变化告警
#       cpu_model_changed: "...",   # CPU 型号变化告警
#       cpu_cnt_changed: "...",     # CPU 插槽数量变化告警
#       memory_slot_cnt_changed: "...", # 内存插槽数量变化告警
#       memory_total_changed: "...", # 内存总容量变化告警
#       raid_status: [...]          # RAID 异常状态告警（仅物理机）
#     }
#   }
# -----------------------------------------------------------------------------
run_runtime_monitor() {
    local cpu_threshold="${1:-90}"
    local memory_threshold="${2:-90}"
    local storage_threshold="${3:-90}"
    local logfile="${4:-}"

    # 获取系统类型（pm=物理机, vm=虚拟机）
    local system_info machine_type
    system_info="$(detect_system_info)"
    machine_type="$(echo "${system_info}" | jq -r .machine_type)"

    # 并行采集运行时数据（三个监控器相互独立）
    local mountpoint_json memory_json cpu_json
    mountpoint_json="$(monitor_mountpoints)"
    memory_json="$(monitor_memory)"
    cpu_json="$(monitor_cpu)"   # 注意: 此调用会 sleep 1 秒

    # findmnt 无输出时 mountpoint_json 可能为空，确保是合法 JSON 数组
    [[ -z "${mountpoint_json}" ]] && mountpoint_json="[]"

    # 生成阈值告警（CPU/内存/存储使用率超阈值）
    local warnings
    warnings="$(generate_threshold_alerts \
        "${cpu_json}" "${memory_json}" "${mountpoint_json}" \
        "${cpu_threshold}" "${memory_threshold}" "${storage_threshold}")"

    # 物理机专属逻辑：RAID 检测 + 硬件变化对比 + RAID 健康检查
    local raid_status="[]"   # 初始化为空数组，虚拟机分支不会修改它
    if [[ "${machine_type}" == "pm" ]]; then
        # 检测 RAID 类型，设置 RAID_TYPE 和 RAID_BIN
        raid_detect

        # 硬件变化对比告警（需要历史文件存在）
        if [[ -f "${logfile}" ]]; then
            local current_hw_json disk_info hw_change_warnings

            # 采集当前磁盘信息
            disk_info="$(collect_disk_info "${machine_type}" "${RAID_TYPE}" "${RAID_BIN}" | jq -c . 2>/dev/null || echo '{}')"

            # 构建包含 cpu、memory、storage 的对比 JSON
            # generate_hardware_change_alerts 需要完整的硬件信息来对比 CPU/内存/磁盘
            current_hw_json="$(jq -n \
                --argjson cpu "$(collect_cpu_info | jq -c . 2>/dev/null || echo '{}')" \
                --argjson mem "$(collect_mem_info | jq -c . 2>/dev/null || echo '{}')" \
                --argjson disk "${disk_info}" \
                '$cpu + $mem + $disk')"

            hw_change_warnings="$(generate_hardware_change_alerts "${current_hw_json}" "${logfile}")"
            # 将硬件变化告警合并到总告警对象
            warnings="$(echo "${warnings}" | jq --argjson extra "${hw_change_warnings}" '. + $extra')"
        fi

        # RAID 健康检查（无 RAID 卡时返回 "[]"）
        raid_status="$(monitor_raid_health "${RAID_TYPE}" "${RAID_BIN}")"

        if [[ "${raid_status}" != "[]" ]]; then
            # 有 RAID 卡且有状态数据时，生成 RAID 异常告警
            local raid_warning
            raid_warning="$(generate_raid_alerts "${raid_status}")"
            # raid_status 键存放异常状态列表（非空时表示有告警）
            warnings="$(echo "${warnings}" | jq --argjson rw "${raid_warning}" '. + {raid_status: $rw}')"
        fi
    fi

    # 构建 storage 字段
    # mountpoint 始终存在；raid 字段仅在物理机且有 RAID 数据时追加
    local storage_json
    storage_json="$(jq -n --argjson mp "${mountpoint_json}" '{mountpoint: $mp}')"
    if [[ "${machine_type}" == "pm" ]] && [[ "${raid_status}" != "[]" ]]; then
        storage_json="$(echo "${storage_json}" | jq --argjson r "${raid_status}" '. + {raid: $r}')"
    fi

    # 统一输出（所有分支共用同一个 jq 调用，替代原来三个重复的 jq -n 块）
    jq -n \
        --argjson storage "${storage_json}" \
        --argjson memory "${memory_json}" \
        --argjson cpu "${cpu_json}" \
        --argjson warning "${warnings}" \
        '{storage: $storage, memory: $memory, cpu: $cpu, warning: $warning}'
}
