#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2016
# =============================================================================
# lib/runtime_main.sh — 运行时监控编排 (v2, 含存储块 B/C/D)
# =============================================================================
# 被 run.sh source 使用，不可直接执行。
#
# 依赖(由 run.sh source):
#   func                        — detect_system_info()
#   lib/jsonio.sh               — collect_json/degraded_sync/jsonio_build_runtime
#   lib/collectors/{cpu,memory}.sh     — 硬件变更对比用静态采集
#   lib/monitors/{cpu,memory,storage}.sh — monitor_cpu/memory/mountpoints
#   lib/raid/detector.sh        — raid_topology_json / raid_health_json
#
# 告警四路(DESIGN §8 注):
#   ①阈值告警: cpu/内存/挂载点容量(storage_threshold 真实语义)/inode/可写性
#   ②RAID 状态告警: warning.raid_status = state_norm ∈ {degraded,rebuild,
#     failed,missing} 的健康对象列表(块 C, 消费 extract_health)
#   ③存储硬件变更对比: pd_cnt_diffrent / direct_disk_cnt_diffrent
#     (数量级, 语义与 v1 一致; 历史无 storage 键时不对比——军规 8 升级过渡)
#   ④RAID 状态快照: storage.raid = 全量健康对象数组(v1 顶层 storage.raid 平移)
# =============================================================================

# -----------------------------------------------------------------------------
# _add_mountpoint_warning <warnings> <warn_key> <jq筛选> <阈值> <挂载点JSON> <消息前缀>
# (v1 alert.sh 平移) 筛选超限挂载点列表, 非空则 warnings[$key] = 消息。
# -----------------------------------------------------------------------------
_add_mountpoint_warning() {
    local warnings="$1" warn_key="$2" jq_filter="$3" threshold="$4"
    local mp_json="$5" msg_prefix="$6"

    local list pts
    list="$(jq -c --argjson threshold "${threshold}" "${jq_filter}" <<<"${mp_json}")"
    if [[ "${list}" != "[]" ]]; then
        pts="$(jq -r 'join(", ")' <<<"${list}")"
        warnings="$(jq -c --arg k "${warn_key}" \
            --arg v "${msg_prefix}${pts} is above threshold: ${threshold}%." \
            '.[$k] = $v' <<<"${warnings}")"
    fi
    printf '%s' "${warnings}"
}

# -----------------------------------------------------------------------------
# generate_threshold_alerts <cpu> <memory> <mountpoint> <cpu阈值> <mem阈值> <storage阈值>
# 输出 warning 对象: cpu_usage/memory_usage/storage_usage/inode_usage/storage_unwritable
# (未触发的键不出现在本对象, 由骨架补 null——键恒在)
# -----------------------------------------------------------------------------
generate_threshold_alerts() {
    local cpu_json="$1" memory_json="$2" mp_json="$3"
    local cpu_threshold="$4" memory_threshold="$5" storage_threshold="$6"

    local warnings='{}'
    local cpu_used_percent memory_used_percent

    cpu_used_percent="$(jq -r '.used_percent' <<<"${cpu_json}")"
    memory_used_percent="$(jq -r '.ram.used_percent' <<<"${memory_json}")"

    if awk -v t="${cpu_threshold}" "BEGIN {exit !(${cpu_used_percent} > t)}"; then
        warnings="$(jq -c --arg t "${cpu_threshold}" \
            '."cpu_usage" = "CPU usage is above threshold: \($t)%."' <<<"${warnings}")"
    fi

    if awk -v t="${memory_threshold}" "BEGIN {exit !(${memory_used_percent} > t)}"; then
        warnings="$(jq -c --arg t "${memory_threshold}" \
            '."memory_usage" = "Memory usage is above threshold: \($t)%."' <<<"${warnings}")"
    fi

    # 挂载点三告警(块 B; inode 与 storage 共用同一阈值, v1 语义)
    warnings="$(_add_mountpoint_warning "${warnings}" "storage_usage" \
        '[.[] | select(.size.used_percent > $threshold) | .target]' \
        "${storage_threshold}" "${mp_json}" "Storage size usage for ")"
    warnings="$(_add_mountpoint_warning "${warnings}" "inode_usage" \
        '[.[] | select(.inodes.used_percent > $threshold) | .target]' \
        "${storage_threshold}" "${mp_json}" "Inode usage for ")"

    local unwritable
    unwritable="$(jq -c '[.[] | select(.writable == false) | .target]' <<<"${mp_json}")"
    if [[ "${unwritable}" != "[]" ]]; then
        local pts
        pts="$(jq -r 'join(", ")' <<<"${unwritable}")"
        warnings="$(jq -c --arg v "The following mount points are not writable: ${pts}." \
            '."storage_unwritable" = $v' <<<"${warnings}")"
    fi

    jq -c . <<<"${warnings}"
}

# -----------------------------------------------------------------------------
# generate_hw_change_alerts <current_json> <logfile>
# 对比历史文件: cpu_model/cpu_cnt/memory 插槽数/总容量 + 存储盘数量(块 D)。
# 历史缺失/解析失败 → 视为无历史, 全部不告警(军规 8)。
# 历史无 storage 键(升级过渡/旧 schema) → 存储对比跳过。
# -----------------------------------------------------------------------------
generate_hw_change_alerts() {
    local current_json="$1" logfile="$2"
    local hist="{}"

    if [[ -s "${logfile}" ]]; then
        hist="$(jq -c . "${logfile}" 2>/dev/null)" || hist="{}"
        [[ -z "${hist}" ]] && hist="{}"
    fi

    jq -cn --argjson cur "${current_json}" --argjson hist "${hist}" '
        (($hist.storage | type) == "array") as $has_hist_storage
        | ([$hist.storage[]? | select(.type == "raid")] | length) as $hp
        | ([$cur.storage[]? | select(.type == "raid")] | length) as $cp
        | ([$hist.storage[]? | select(.type == "direct")] | length) as $hd
        | ([$cur.storage[]? | select(.type == "direct")] | length) as $cd
        | {
            cpu_model_changed:
                (if ($hist.cpu.cpu_model // null) != null and
                    ($hist.cpu.cpu_model != $cur.cpu.cpu_model)
                 then "CPU model changed: \($hist.cpu.cpu_model) -> \($cur.cpu.cpu_model)."
                 else null end),
            cpu_cnt_changed:
                (if ($hist.cpu.cpu_cnt // null) != null and
                    ($hist.cpu.cpu_cnt != $cur.cpu.cpu_cnt)
                 then "CPU socket count changed: \($hist.cpu.cpu_cnt) -> \($cur.cpu.cpu_cnt)."
                 else null end),
            memory_slot_cnt_changed:
                (if ($hist.memory | type) == "array" and
                    (($hist.memory | length) != ($cur.memory | length))
                 then "Memory slot count changed: \($hist.memory | length) -> \($cur.memory | length)."
                 else null end),
            memory_total_changed:
                (if ($hist.memory | type) == "array" and ($hist.memory | length) > 0 and
                    (([$hist.memory[].size] | add) != ([$cur.memory[].size] | add))
                 then "Memory total changed: \([$hist.memory[].size] | add)G -> \([$cur.memory[].size] | add)G."
                 else null end),
            pd_cnt_diffrent:
                (if $has_hist_storage and $hp != $cp
                 then "raid disk count changed from \($hp) to \($cp)."
                 else null end),
            direct_disk_cnt_diffrent:
                (if $has_hist_storage and $hd != $cd
                 then "direct disk count changed from \($hd) to \($cd)."
                 else null end)
        } | with_entries(select(.value != null))'
}

# -----------------------------------------------------------------------------
# generate_raid_alerts <健康对象数组>
# 块 C: state_norm ∈ {degraded,rebuild,failed,missing} → 告警列表(块C)。
# online/unknown 不告警(unknown 归一失败属解析问题, 走 degraded 记录不告警)。
# 输出: JSON 数组(空数组=全部正常, 编排层转 null)。
# -----------------------------------------------------------------------------
generate_raid_alerts() {
    jq -c '
      [.[]?
       | select(.state_norm != null
                and .state_norm != "online"
                and .state_norm != "unknown")]
    ' <<<"$1"
}

# -----------------------------------------------------------------------------
# run_runtime_monitor <cpu阈值> <mem阈值> <storage阈值> <logfile>
# -----------------------------------------------------------------------------
run_runtime_monitor() {
    local cpu_threshold="${1:-90}"
    local memory_threshold="${2:-90}"
    local storage_threshold="${3:-90}"
    local logfile="${4:-}"

    local cpu_json mem_json
    cpu_json="$(monitor_cpu)"      # 内部 sleep 1
    mem_json="$(monitor_memory)"

    # 块 B: 挂载点监控(storage_threshold 真实语义)
    local mp_json
    mp_json="$(collect_json "mountpoints" monitor_mountpoints)"

    # ① 阈值告警(cpu/内存/容量/inode/可写)
    local warnings
    warnings="$(generate_threshold_alerts "${cpu_json}" "${mem_json}" "${mp_json}" \
        "${cpu_threshold}" "${memory_threshold}" "${storage_threshold}")"

    # ③ 硬件变更对比(cpu/内存 + 存储盘数量, 块 D)
    # ② RAID 健康(块 C)
    # 两者共用同一次适配器抓取(§4.4: 每轮轮询每卡只抓一次厂商 CLI):
    # 先取全量模型数组, 再分别派生 topology 投影(对比)与 health 投影(快照/告警)
    local cur_cpu cur_mem raid_models current_hw hw_warnings
    cur_cpu="$(collect_json "collect_cpu_info" collect_cpu_info)"
    cur_mem="$(collect_json "collect_mem_info" collect_mem_info)"
    raid_models="$(collect_json "raid_parse" raid_models_json)"
    local raid_topology raid_status="[]"
    raid_topology="$(raid_topology_json "${raid_models}")"
    raid_status="$(raid_health_json "${raid_models}")"
    current_hw="$(jq -cn --argjson cpu "${cur_cpu}" --argjson mem "${cur_mem}" \
        --argjson rt "${raid_topology}" '$cpu * $mem + {storage: ($rt.storage // [])}')"
    hw_warnings="$(generate_hw_change_alerts "${current_hw}" "${logfile}")"
    local raid_warnings="null"
    local abnormal
    abnormal="$(generate_raid_alerts "${raid_status}")"
    if [[ "${abnormal}" != "[]" ]]; then
        raid_warnings="${abnormal}"
    fi

    warnings="$(jq -cn --argjson w "${warnings}" --argjson hw "${hw_warnings}" '$w * $hw')"

    # 收尾: 子 shell 降级记录合并
    degraded_sync

    local now tool_version
    now="$(date -Iseconds 2>/dev/null || date '+%F %T')"
    tool_version="$(awk -F '=' '/Version=/{print $2; exit}' "${WORK_DIR}/../../release-note.md" 2>/dev/null || true)"
    [[ -z "${tool_version}" ]] && tool_version="unknown"

    local degraded_json="[]"
    if [[ ${#TSC_DEGRADED[@]} -gt 0 ]]; then
        degraded_json="$(array_to_json "${TSC_DEGRADED[@]}")"
    fi

    jsonio_build_runtime "${cpu_json}" "${mem_json}" "${mp_json}" \
        "${raid_status}" "${warnings}" "${raid_warnings}" \
        "${tool_version}" "${degraded_json}" "${now}"
}
