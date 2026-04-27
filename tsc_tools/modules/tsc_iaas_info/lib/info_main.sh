#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034
# =============================================================================
# lib/info_main.sh — 静态信息采集编排
# =============================================================================
# 被 run.sh source 使用，不可直接执行。
# 对应原 run.sh 中的 main() 函数，将其拆分为独立模块。
#
# 依赖（由调用方 run.sh 负责 source，顺序不可颠倒）:
#   lib/common.sh              — INVALID_SNS 等常量
#   lib/raid/detector.sh       — raid_detect()
#   lib/collectors/cpu.sh      — collect_cpu_info()
#   lib/collectors/memory.sh   — collect_mem_info()
#   lib/collectors/system.sh   — collect_serial_number(), collect_contract_no(),
#                                collect_location(), collect_manufacturer()
#   lib/collectors/storage.sh  — collect_disk_info()
#
# 提供函数:
#   collect_all_info <sn_override> <contract_no_override> <location_override> <logfile>
# =============================================================================

# -----------------------------------------------------------------------------
# collect_all_info <sn_override> <contract_no_override> <location_override> <logfile>
#
# 编排所有静态信息采集器，输出完整系统信息 JSON。
#
# 参数:
#   sn_override           — 命令行 --sn 指定的序列号，为空则自动获取
#   contract_no_override  — 命令行 --contract_no 指定的合同号，为空则从历史日志继承
#   location_override     — 命令行 --location 指定的位置，为空则从历史日志继承
#   logfile               — 历史日志文件路径（软链接 /var/log/tsc/tsc_iaas_info.json）
#                           用于继承 sn/contract_no/location 等字段
#
# 输出:
#   完整系统信息 JSON，字段包括:
#   {
#     machine_type, os_version, ... (来自 detect_system_info),
#     sn, manufacturer,
#     cpu: {cpu_model, cpu_cnt},
#     memory: [{size, locator, unit}],
#     storage: [{type, model, serial, size, unit}],
#     contract_no, location
#   }
#
# 采集流程:
#   1. detect_system_info() — 获取系统基础信息（机器类型、OS版本等）
#   2. raid_detect()        — 检测 RAID 类型，设置 RAID_TYPE 和 RAID_BIN
#   3. 各 collector 函数    — 采集 CPU/内存/磁盘/序列号等信息
#   4. jq -n 一次性合并     — 将所有 JSON 片段合并为完整输出
# -----------------------------------------------------------------------------
collect_all_info() {
    local sn_override="${1:-}"
    local contract_no_override="${2:-}"
    local location_override="${3:-}"
    local logfile="${4:-}"

    # 获取系统基础信息（machine_type: pm=物理机, vm=虚拟机）
    local system_info machine_type
    system_info="$(detect_system_info)"
    machine_type="$(echo "${system_info}" | jq -r .machine_type)"

    # 检测 RAID 类型，设置全局变量 RAID_TYPE 和 RAID_BIN
    # 物理机需要 RAID 信息来区分 RAID 盘和直通盘
    raid_detect

    # 采集各项信息（每个采集器失败时降级为空 JSON 对象，不中断整体流程）
    local sn_json contract_no_json location_json manufacturer
    local cpu_info mem_info disk_info

    sn_json="$(collect_serial_number "${sn_override}" "${logfile}" | jq -c . 2>/dev/null || echo '{}')"
    contract_no_json="$(collect_contract_no "${contract_no_override}" "${logfile}" | jq -c . 2>/dev/null || echo '{}')"
    location_json="$(collect_location "${location_override}" "${logfile}" | jq -c . 2>/dev/null || echo '{}')"
    manufacturer="$(collect_manufacturer)"
    cpu_info="$(collect_cpu_info | jq -c . 2>/dev/null || echo '{}')"
    mem_info="$(collect_mem_info | jq -c . 2>/dev/null || echo '{}')"
    # collect_disk_info 需要 machine_type 和 RAID 信息来区分盘类型
    disk_info="$(collect_disk_info "${machine_type}" "${RAID_TYPE}" "${RAID_BIN}" | jq -c . 2>/dev/null || echo '{}')"

    # 一次性合并所有 JSON 片段（替代原来的 7 次 jq 管道调用，性能更好）
    # + 运算符合并 JSON 对象，后面的字段会覆盖前面同名字段
    jq -n \
        --argjson base "${system_info}" \
        --argjson sn "${sn_json}" \
        --arg manufacturer "${manufacturer}" \
        --argjson cpu "${cpu_info}" \
        --argjson mem "${mem_info}" \
        --argjson disk "${disk_info}" \
        --argjson contract_no "${contract_no_json}" \
        --argjson location "${location_json}" \
        '$base + $sn + {manufacturer: $manufacturer} + $cpu + $mem + $disk + $contract_no + $location'
}
