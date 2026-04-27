#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/alert.sh — 告警生成模块
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 提供函数:
#   _add_mountpoint_warning()         — 内部辅助函数
#   generate_threshold_alerts()       — 资源使用率阈值告警
#   generate_hardware_change_alerts() — 硬件变化历史对比告警
#   generate_raid_alerts()            — RAID 状态异常告警
#
# 告警 key 命名规范:
#   所有告警 key 均为小写下划线格式，值为英文描述字符串
#   告警对象为空 {} 时表示无告警
# =============================================================================

# -----------------------------------------------------------------------------
# _add_mountpoint_warning <warnings> <warn_key> <jq_filter> <threshold>
#                         <mountpoint_json> <msg_prefix>
#
# 内部辅助函数：对挂载点列表按 jq_filter 筛选，若结果非空则追加告警。
# 用于消除 storage_usage 和 inode_usage 两段重复逻辑。
#
# 参数:
#   warnings       — 当前告警 JSON 对象字符串
#   warn_key       — 告警 key 名称，例如 "storage_usage"
#   jq_filter      — jq 过滤表达式，使用 $threshold 变量，输出目标挂载点列表
#   threshold      — 阈值数值（百分比）
#   mountpoint_json — monitor_mountpoints() 的输出
#   msg_prefix     — 告警消息前缀，例如 "Storage size usage for "
#
# 输出:
#   更新后的 warnings JSON 对象字符串
# -----------------------------------------------------------------------------
_add_mountpoint_warning() {
    local warnings="$1"
    local warn_key="$2"
    local jq_filter="$3"
    local threshold="$4"
    local mountpoint_json="$5"
    local msg_prefix="$6"

    local list pts
    # 用 jq_filter 筛选超阈值的挂载点，得到目标路径列表
    list="$(echo "${mountpoint_json}" | jq --argjson threshold "${threshold}" "${jq_filter}")"
    if [[ "${list}" != "[]" ]]; then
        # 将路径列表转为逗号分隔字符串
        pts="$(echo "${list}" | jq -r 'join(", ")')"
        # 追加告警到 warnings 对象
        warnings="$(echo "${warnings}" | jq \
            --arg k "${warn_key}" \
            --arg v "${msg_prefix}${pts} is above threshold: ${threshold}%." \
            '.[$k] = $v')"
    fi
    echo "${warnings}"
}

# -----------------------------------------------------------------------------
# generate_threshold_alerts <cpu_json> <memory_json> <mountpoint_json>
#                           <cpu_threshold> <memory_threshold> <storage_threshold>
#
# 根据阈值生成资源使用率告警。
#
# 参数:
#   cpu_json        — monitor_cpu() 的输出
#   memory_json     — monitor_memory() 的输出
#   mountpoint_json — monitor_mountpoints() 的输出
#   cpu_threshold   — CPU 使用率告警阈值（百分比）
#   memory_threshold — 内存使用率告警阈值（百分比）
#   storage_threshold — 存储/inode 使用率告警阈值（百分比）
#
# 输出:
#   告警 JSON 对象，可能包含以下 key:
#   cpu_usage         — 触发条件: CPU used_percent > cpu_threshold
#   memory_usage      — 触发条件: 内存 ram.used_percent > memory_threshold
#   storage_usage     — 触发条件: 任意挂载点 size.used_percent > storage_threshold
#   inode_usage       — 触发条件: 任意挂载点 inodes.used_percent > storage_threshold
#   storage_unwritable — 触发条件: 任意挂载点 writable == false
# -----------------------------------------------------------------------------
generate_threshold_alerts() {
    local cpu_json="$1"
    local memory_json="$2"
    local mountpoint_json="$3"
    local cpu_threshold="$4"
    local memory_threshold="$5"
    local storage_threshold="$6"

    local warnings='{}'
    local cpu_used_percent memory_used_percent

    cpu_used_percent="$(echo "${cpu_json}" | jq -r '.used_percent')"
    memory_used_percent="$(echo "${memory_json}" | jq -r '.ram.used_percent')"

    # 告警 key: cpu_usage — 触发条件: CPU used_percent > cpu_threshold（使用率超过阈值百分比）
    # awk 用于浮点数比较（bash 不支持浮点比较）
    if awk -v t="${cpu_threshold}" "BEGIN {exit !(${cpu_used_percent} > t)}"; then
        warnings="$(echo "${warnings}" | jq \
            --arg threshold "${cpu_threshold}" \
            '."cpu_usage" = "CPU usage is above threshold: \($threshold)%."')"
    fi

    # 告警 key: memory_usage — 触发条件: 内存 ram.used_percent > memory_threshold（内存使用率超过阈值百分比）
    if awk -v t="${memory_threshold}" "BEGIN {exit !(${memory_used_percent} > t)}"; then
        warnings="$(echo "${warnings}" | jq \
            --arg threshold "${memory_threshold}" \
            '."memory_usage" = "Memory usage is above threshold: \($threshold)%."')"
    fi

    # 告警 key: storage_usage — 触发条件: 任意挂载点 size.used_percent > storage_threshold（存储容量使用率超过阈值百分比）
    warnings="$(_add_mountpoint_warning \
        "${warnings}" \
        "storage_usage" \
        '[.[] | select(.size.used_percent > $threshold) | .target]' \
        "${storage_threshold}" \
        "${mountpoint_json}" \
        "Storage size usage for ")"

    # 告警 key: inode_usage — 触发条件: 任意挂载点 inodes.used_percent > storage_threshold（inode 使用率超过阈值百分比，与 storage_threshold 共用同一阈值）
    warnings="$(_add_mountpoint_warning \
        "${warnings}" \
        "inode_usage" \
        '[.[] | select(.inodes.used_percent > $threshold) | .target]' \
        "${storage_threshold}" \
        "${mountpoint_json}" \
        "Inode usage for ")"

    # 告警 key: storage_unwritable — 触发条件: 任意挂载点 writable == false（挂载点不可写）
    local storage_unwritable_list
    storage_unwritable_list="$(echo "${mountpoint_json}" | jq '[.[] | select(.writable == false) | .target]')"
    if [[ "${storage_unwritable_list}" != "[]" ]]; then
        local unwritable_mount_points
        unwritable_mount_points="$(echo "${storage_unwritable_list}" | jq -r 'join(", ")')"
        warnings="$(echo "${warnings}" | jq \
            --arg unwritable_mount_points "${unwritable_mount_points}" \
            '."storage_unwritable" = "The following mount points are not writable: \($unwritable_mount_points)."')"
    fi

    echo "${warnings}"
}

# -----------------------------------------------------------------------------
# generate_hardware_change_alerts <current_info_json> <logfile>
#
# 对比当前硬件信息与历史日志，生成硬件变化告警。
# 用于检测服务器硬件被替换或故障的情况。
#
# 参数:
#   current_info_json — 包含 cpu、memory、storage 字段的当前系统信息 JSON
#                       由 collect_cpu_info() + collect_mem_info() + collect_disk_info() 合并而来
#   logfile           — 历史日志文件路径（软链接指向的上次采集结果）
#
# 输出:
#   告警 JSON 对象，可能包含以下 key:
#   pd_cnt_diffrent          — 触发条件: RAID 盘数量与历史不一致
#   direct_disk_cnt_diffrent — 触发条件: 直通盘数量与历史不一致
#   cpu_model_changed        — 触发条件: CPU 型号与历史不一致
#   cpu_cnt_changed          — 触发条件: CPU 插槽数量与历史不一致
#   memory_slot_cnt_changed  — 触发条件: 内存插槽数量与历史不一致
#   memory_total_changed     — 触发条件: 内存总容量与历史不一致
# -----------------------------------------------------------------------------
generate_hardware_change_alerts() {
    local current_json="$1"
    local logfile="$2"
    local warnings='{}'

    # 历史文件不存在则无法对比，直接返回空告警（首次运行时正常）
    [[ ! -f "${logfile}" ]] && echo "${warnings}" && return 0

    # --- 磁盘数量对比 ---
    # 使用 jq 直接计数（比原来的 awk 解析 JSON 更健壮，不依赖格式化输出）

    # 告警 key: pd_cnt_diffrent — 触发条件: 当前 RAID 盘数量（type=="raid"）与历史日志不一致
    local pd_cnt ori_pd_cnt
    pd_cnt="$(echo "${current_json}" | jq '[.storage[]? | select(.type=="raid")] | length')"
    ori_pd_cnt="$(jq '[.storage[]? | select(.type=="raid")] | length' "${logfile}")"
    if [[ "${pd_cnt}" != "${ori_pd_cnt}" ]]; then
        warnings="$(echo "${warnings}" | jq \
            --arg cur "${pd_cnt}" --arg ori "${ori_pd_cnt}" \
            '."pd_cnt_diffrent" = "raid disk count changed from \($ori) to \($cur)."')"
    fi

    # 告警 key: direct_disk_cnt_diffrent — 触发条件: 当前直通盘数量（type=="direct"）与历史日志不一致
    local direct_disk_cnt ori_direct_disk_cnt
    direct_disk_cnt="$(echo "${current_json}" | jq '[.storage[]? | select(.type=="direct")] | length')"
    ori_direct_disk_cnt="$(jq '[.storage[]? | select(.type=="direct")] | length' "${logfile}")"
    if [[ "${direct_disk_cnt}" != "${ori_direct_disk_cnt}" ]]; then
        warnings="$(echo "${warnings}" | jq \
            --arg cur "${direct_disk_cnt}" --arg ori "${ori_direct_disk_cnt}" \
            '."direct_disk_cnt_diffrent" = "direct disk count changed from \($ori) to \($cur)."')"
    fi

    # --- CPU 对比 ---

    # 告警 key: cpu_model_changed — 触发条件: cpu.cpu_model 字段与历史日志不一致（历史值非空时才对比，避免首次运行误报）
    local cpu_model ori_cpu_model
    cpu_model="$(echo "${current_json}" | jq -r '.cpu.cpu_model // ""')"
    ori_cpu_model="$(jq -r '.cpu.cpu_model // ""' "${logfile}")"
    if [[ -n "${ori_cpu_model}" && "${cpu_model}" != "${ori_cpu_model}" ]]; then
        warnings="$(echo "${warnings}" | jq \
            --arg cur "${cpu_model}" --arg ori "${ori_cpu_model}" \
            '."cpu_model_changed" = "CPU model changed from \u0027\($ori)\u0027 to \u0027\($cur)\u0027."')"
    fi

    # 告警 key: cpu_cnt_changed — 触发条件: cpu.cpu_cnt 字段（CPU 插槽数量）与历史日志不一致（历史值非空时才对比）
    local cpu_cnt ori_cpu_cnt
    cpu_cnt="$(echo "${current_json}" | jq -r '.cpu.cpu_cnt // ""')"
    ori_cpu_cnt="$(jq -r '.cpu.cpu_cnt // ""' "${logfile}")"
    if [[ -n "${ori_cpu_cnt}" && "${cpu_cnt}" != "${ori_cpu_cnt}" ]]; then
        warnings="$(echo "${warnings}" | jq \
            --arg cur "${cpu_cnt}" --arg ori "${ori_cpu_cnt}" \
            '."cpu_cnt_changed" = "CPU socket count changed from \($ori) to \($cur)."')"
    fi

    # --- 内存对比 ---

    # 告警 key: memory_slot_cnt_changed — 触发条件: memory 数组长度（内存插槽数量）与历史日志不一致
    local mem_slot_cnt ori_mem_slot_cnt
    mem_slot_cnt="$(echo "${current_json}" | jq '[.memory[]?] | length')"
    ori_mem_slot_cnt="$(jq '[.memory[]?] | length' "${logfile}")"
    if [[ "${mem_slot_cnt}" != "${ori_mem_slot_cnt}" ]]; then
        warnings="$(echo "${warnings}" | jq \
            --arg cur "${mem_slot_cnt}" --arg ori "${ori_mem_slot_cnt}" \
            '."memory_slot_cnt_changed" = "Memory slot count changed from \($ori) to \($cur)."')"
    fi

    # 告警 key: memory_total_changed — 触发条件: memory 各插槽 size 之和（内存总容量，保留两位小数）与历史日志不一致
    # 对 memory 数组所有 size 求和，保留两位小数（round/100 实现四舍五入）
    local mem_total ori_mem_total
    mem_total="$(echo "${current_json}" | jq '[.memory[]?.size // 0] | add // 0 | . * 100 | round / 100')"
    ori_mem_total="$(jq '[.memory[]?.size // 0] | add // 0 | . * 100 | round / 100' "${logfile}")"
    if [[ "${mem_total}" != "${ori_mem_total}" ]]; then
        warnings="$(echo "${warnings}" | jq \
            --arg cur "${mem_total}" --arg ori "${ori_mem_total}" \
            '."memory_total_changed" = "Memory total capacity changed from \($ori)G to \($cur)G."')"
    fi

    echo "${warnings}"
}

# -----------------------------------------------------------------------------
# generate_raid_alerts <raid_status_json>
#
# 从 RAID 状态 JSON 中筛选出异常状态的 VD/PD，生成告警列表。
#
# 参数:
#   raid_status_json — monitor_raid_health() 的输出（JSON 数组）
#
# 输出:
#   JSON 数组，只包含状态异常的条目（中文状态不含"信息"字样的）
#   正常状态（信息(正常)、信息(在线)等）会被过滤掉
#   空数组 [] 表示所有 VD/PD 状态正常
#
# 判断逻辑:
#   中文状态以"信息"开头 → 正常，不告警
#   中文状态以"告警"或"严重"开头 → 异常，加入告警列表
# -----------------------------------------------------------------------------
generate_raid_alerts() {
    local raid_status_json="$1"

    # 筛选条件: VD 或 PD 的中文状态不含"信息"字样
    # index("信息") == null 表示字符串中不包含"信息"子串
    echo "${raid_status_json}" |
        jq '[ .[] | select (
            ( has("虚拟磁盘中文状态") and (.["虚拟磁盘中文状态"]|index("信息")) == null ) or
            ( has("物理磁盘中文状态") and (.["物理磁盘中文状态"]|index("信息")) == null )
        ) ]'
}
