#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# =============================================================================
# lib/jsonio.sh — JSON 管线军规封装 (DESIGN.md §5)
# =============================================================================
# 被 run.sh source 使用，不可直接执行。
#
# 依赖:
#   TSC_SCHEMA_DIR      — schema 目录(由 run.sh 导出)
#   TSC_DEGRADED        — 降级记录数组(由 run.sh declare -g)
#   TSC_DEGRADED_FILE   — 降级记录文件(由 run.sh 创建, 空文件)
#   func                — array_to_json
#
# 提供:
#   degraded_add <来源名>            — 记一条降级(文件背书, 子 shell 内可见)
#   degraded_sync                    — 收尾时把文件记录合并回 TSC_DEGRADED
#   collect_json <来源名> <命令...>  — 运行采集命令, 输出紧凑 JSON;
#                                      失败/空输出降级为 {} 并记入降级
#   jsonio_validate <static|runtime> — 从 stdin 校验文档(骨架自洽语义)
#   jsonio_build_static <...>        — 骨架填充: 静态文档
#   jsonio_build_runtime <...>       — 骨架填充: 运行时文档
# =============================================================================

# -----------------------------------------------------------------------------
# degraded_add <来源名>
#
# 军规 5(单来源失败降级记录)。同时追加数组与文件: collect_json 与
# raid_topology_lines 等会运行在命令替换/进程替换子 shell 中, 数组追加
# 对主流程不可见, 统一落 TSC_DEGRADED_FILE, 由 degraded_sync() 合并回数组。
# -----------------------------------------------------------------------------
degraded_add() {
    TSC_DEGRADED+=("${1}") 2>/dev/null || true
    printf '%s\n' "${1}" >>"${TSC_DEGRADED_FILE}" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# degraded_sync
#
# 编排层收尾调用: 以文件为准重建 TSC_DEGRADED(涵盖子 shell 内的记录)。
# -----------------------------------------------------------------------------
degraded_sync() {
    TSC_DEGRADED=()
    if [[ -s "${TSC_DEGRADED_FILE}" ]]; then
        mapfile -t TSC_DEGRADED <"${TSC_DEGRADED_FILE}"
    fi
}

# -----------------------------------------------------------------------------
# collect_json <来源名> <命令...>
#
# 运行采集命令, stdout 经 jq -c 规范为紧凑 JSON。
# 失败(命令非零/输出非法 JSON/输出为空)时: 降级为 "{}" 并将来源记入
# 降级(军规 4/5: 单来源失败不崩溃)。
# 注意: 本函数可能运行在调用方的命令替换子 shell 内, 降级经 degraded_add
# 落文件, 不依赖当前 shell 的数组可见性。
# -----------------------------------------------------------------------------
collect_json() {
    local source_name="$1"
    shift
    local out rc
    out="$("$@" 2>/dev/null | jq -c . 2>/dev/null)" || rc=$?
    if [[ ${rc:-0} -ne 0 || -z "${out}" ]]; then
        degraded_add "${source_name}"
        printf '{}'
    else
        printf '%s' "${out}"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# jsonio_validate <static|runtime>
#
# 从 stdin 读取文档, 用 lib/schema/validate.jq 校验。
# 校验失败: 非零退出(调用方在 errexit 下终止——校验失败属于实现缺陷,
# 不是采集降级; 采集降级走骨架 null, 不会校验失败)。
# -----------------------------------------------------------------------------
jsonio_validate() {
    local mode="$1"
    if [[ "${mode}" == "static" ]]; then
        jq -e -L "${TSC_SCHEMA_DIR}" 'include "validate"; validate_static' >/dev/null
    else
        jq -e -L "${TSC_SCHEMA_DIR}" 'include "validate"; validate_runtime' >/dev/null
    fi
}

# -----------------------------------------------------------------------------
# jsonio_build_static <sys> <sn> <contract> <location> <mem> <cpu>
#                     <manufacturer> <tool_version> <degraded> <now> <raid>
#
# 骨架填充: static.tmpl.json * 各采集器输出 (军规 3)。
#   - 数据胜出, 骨架补缺(采集失败的键保持骨架 null); 来源降级为 {} 时
#     经 // 兜底不崩溃(军规 5);
#   - memory/storage/raid_controllers 条目与骨架示例条目合并, 缺省键补 null;
#   - memory 按 locator、storage 按 ctl_no/enc/slot/dev、raid_controllers 按
#     type/ctl_no 排序(§3.3 排序契约, 保 MD5 去重确定性);
#   - <raid> = raid_topology_json 的产物 {"storage":[],"raid_controllers":[]}。
# 输出: 紧凑 JSON(单行)。
# -----------------------------------------------------------------------------
jsonio_build_static() {
    local sys_json="$1" sn_json="$2" contract_json="$3" location_json="$4"
    local mem_json="$5" cpu_json="$6" manufacturer="$7" tool_version="$8"
    local degraded_json="$9" now="${10}" raid_json="${11}"

    # -n: 程序自包含(仅用 $t/$args, 不消费输入流), 必须置空输入, 否则 jq 读 stdin,
    #     命令替换场景下 stdin 为空 → filter 一次都不执行 → 静默输出空
    jq -cn \
        --slurpfile t "${TSC_SCHEMA_DIR}/static.tmpl.json" \
        --argjson sys "${sys_json}" \
        --argjson sn "${sn_json}" \
        --argjson cn "${contract_json}" \
        --argjson loc "${location_json}" \
        --argjson mem "${mem_json}" \
        --argjson cpu "${cpu_json}" \
        --arg manufacturer "${manufacturer}" \
        --arg tv "${tool_version}" \
        --arg now "${now}" \
        --argjson dg "${degraded_json}" \
        --argjson rt "${raid_json}" \
        '
        $t[0]
        | .meta.generated_at = $now
        | .meta.tool_version = $tv
        | .meta.degraded = $dg
        | . * ($sys + $sn + $cn + $loc + {manufacturer: $manufacturer})
        | .cpu = ($t[0].cpu * ($cpu.cpu // {}))
        | .memory = [$t[0].memory[0] as $tpl | ($mem.memory // [])[] | $tpl * .]
        | .memory |= sort_by(.locator)
        | .storage = [$t[0].storage[0] as $tpl | ($rt.storage // [])[] | $tpl * .]
        | .storage |= sort_by(.ctl_no, .enc, .slot, .dev)
        | .raid_controllers = [$t[0].raid_controllers[0] as $tpl | ($rt.raid_controllers // [])[] | $tpl * .]
        | .raid_controllers |= sort_by(.type, .ctl_no)
        '
}

# -----------------------------------------------------------------------------
# jsonio_build_runtime <cpu> <mem> <mountpoint> <raid_status> <warning>
#                      <raid_warnings> <tool_version> <degraded> <now>
#
# 骨架填充: runtime.tmpl.json * 监控器输出 (军规 3)。
#   warning 键恒在(骨架 null * 告警数据), 无告警为 null —— zabbix 侧形状稳定;
#   storage = {mountpoint: 挂载点数组, raid: RAID 健康快照数组}(v1 顶层平移);
#   warning.raid_status: 正常为 null, 异常为健康对象数组(块 C)。
# 输出: 紧凑 JSON(单行)。
# -----------------------------------------------------------------------------
jsonio_build_runtime() {
    local cpu_json="$1" mem_json="$2" mp_json="$3" raid_status_json="$4"
    local warn_json="$5" raid_warnings="$6" tool_version="$7"
    local degraded_json="$8" now="$9"

    # -n: 同上, 程序不消费输入流
    jq -cn \
        --slurpfile t "${TSC_SCHEMA_DIR}/runtime.tmpl.json" \
        --argjson cpu "${cpu_json}" \
        --argjson mem "${mem_json}" \
        --argjson mp "${mp_json}" \
        --argjson rs "${raid_status_json}" \
        --argjson warn "${warn_json}" \
        --argjson rw "${raid_warnings}" \
        --arg tv "${tool_version}" \
        --arg now "${now}" \
        --argjson dg "${degraded_json}" \
        '
        $t[0]
        | .meta.generated_at = $now
        | .meta.tool_version = $tv
        | .meta.degraded = $dg
        | .cpu = ($t[0].cpu * $cpu)
        | .memory = ($t[0].memory * $mem)
        | .storage = ($t[0].storage * {mountpoint: ($mp // []), raid: ($rs // [])})
        | .warning = (($t[0].warning * $warn) * {raid_status: $rw})
        '
}
