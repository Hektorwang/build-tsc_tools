#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034
# =============================================================================
# lib/static_main.sh — 静态信息采集编排 (v2, 阶段1: 非存储 + direct 存储)
# =============================================================================
# 被 run.sh source 使用，不可直接执行。
#
# 依赖(由 run.sh source):
#   func                       — detect_system_info()
#   lib/common.sh              — INVALID_SNS
#   lib/jsonio.sh              — collect_json()/degraded_sync()/jsonio_build_static()
#   lib/collectors/{cpu,memory,system}.sh
#   lib/raid/{cards/lib.sh,cards/direct.sh,detector.sh}
#
# 提供函数:
#   static_main <sn_override> <contract_no_override> <location_override> <logfile>
#
# 与 v1 的差异(DESIGN.md):
#   - 输出带 meta(schema_version/tool_version/generated_at/degraded);
#   - 文档由骨架填充生成(军规 3), 采集失败的键保持骨架 null 并记入 degraded;
#   - memory 按 locator、storage 按 ctl_no/enc/slot/dev 排序(排序契约,
#     保 MD5 去重确定性);
#   - 存储走适配器注册表(阶段1: direct; lsi/sas3/sas2/adaptec 随迁移加入),
#     采集失败的卡型记入 degraded, 不中断(军规 5)。
# =============================================================================

# -----------------------------------------------------------------------------
# collect_json 的降级记录由 jsonio.sh 提供; 此处编排各采集器并构建文档。
# -----------------------------------------------------------------------------
static_main() {
    local sn_override="${1:-}"
    local contract_no_override="${2:-}"
    local location_override="${3:-}"
    local logfile="${4:-}"

    # 各采集器经 collect_json 包装: 失败降级为 {} 并记入降级(文件背书)
    local sys_json sn_json contract_json location_json cpu_json mem_json
    sys_json="$(collect_json "detect_system_info" detect_system_info)"
    sn_json="$(collect_json "sn" collect_serial_number "${sn_override}" "${logfile}")"
    contract_json="$(collect_json "contract_no" collect_contract_no "${contract_no_override}" "${logfile}")"
    location_json="$(collect_json "location" collect_location "${location_override}" "${logfile}")"
    cpu_json="$(collect_json "cpu" collect_cpu_info)"
    mem_json="$(collect_json "memory" collect_mem_info)"

    # 存储适配器(注册表遍历; 产出 {"storage":[],"raid_controllers":[]})
    local raid_json
    raid_json="$(collect_json "raid_topology" raid_topology_json)"

    # 厂商字符串(内置 Unknown 兜底, 不走降级)
    local manufacturer
    manufacturer="$(collect_manufacturer 2>/dev/null || echo "Unknown")"

    # 收尾: 把子 shell 经文件记录的降级项合并回数组(jsonio.sh)
    degraded_sync

    local now tool_version
    now="$(date -Iseconds 2>/dev/null || date '+%F %T')"
    tool_version="$(awk -F '=' '/Version=/{print $2; exit}' "${WORK_DIR}/../../release-note.md" 2>/dev/null || true)"
    [[ -z "${tool_version}" ]] && tool_version="unknown"

    local degraded_json="[]"
    if [[ ${#TSC_DEGRADED[@]} -gt 0 ]]; then
        degraded_json="$(array_to_json "${TSC_DEGRADED[@]}")"
    fi

    jsonio_build_static \
        "${sys_json}" "${sn_json}" "${contract_json}" "${location_json}" \
        "${mem_json}" "${cpu_json}" "${manufacturer}" \
        "${tool_version}" "${degraded_json}" "${now}" "${raid_json}"
}
