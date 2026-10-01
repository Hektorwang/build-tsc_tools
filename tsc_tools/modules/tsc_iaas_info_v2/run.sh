#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# =============================================================================
# run.sh — tsc_iaas_info_v2 主入口
# =============================================================================
# 与 v1(tsc_iaas_info)平行开发, 互不影响; 设计见本目录 DESIGN.md。
# 调用: tsc --tsc_iaas_info_v2 [OPTIONS]
# 阶段1(非存储部分, DESIGN.md §8): 静态采集 + runtime(cpu/内存监控与告警)
# =============================================================================
set -o errexit
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob

WORK_DIR="$(dirname "$(readlink -f "$0")")"

# func 提供 detect_system_info/array_to_json; 始终加载, 不设 TSC_FUNC 守卫
# (经 tsc 分发器调用时本脚本是子进程, 仅继承被 export -f 的函数, 必须自行加载)
source "${WORK_DIR}/../../func"
source "${WORK_DIR}/lib/common.sh"
source "${WORK_DIR}/lib/jsonio.sh"
source "${WORK_DIR}/lib/collectors/cpu.sh"
source "${WORK_DIR}/lib/collectors/memory.sh"
source "${WORK_DIR}/lib/collectors/system.sh"
source "${WORK_DIR}/lib/monitors/cpu.sh"
source "${WORK_DIR}/lib/monitors/memory.sh"
source "${WORK_DIR}/lib/monitors/storage.sh"
# 存储适配器(detector 先于卡型加载: 卡型 source 时即调用 card_register 自注册;
# extract.sh 为通用提取器, 卡型文件仅依赖 cards/lib.sh)
source "${WORK_DIR}/lib/raid/cards/lib.sh"
source "${WORK_DIR}/lib/raid/extract.sh"
source "${WORK_DIR}/lib/raid/detector.sh"
source "${WORK_DIR}/lib/raid/cards/direct.sh"
source "${WORK_DIR}/lib/raid/cards/lsi.sh"
source "${WORK_DIR}/lib/raid/cards/sas3.sh"
source "${WORK_DIR}/lib/raid/cards/sas2.sh"
source "${WORK_DIR}/lib/raid/cards/adaptec.sh"
source "${WORK_DIR}/lib/static_main.sh"
source "${WORK_DIR}/lib/runtime_main.sh"

TSC_SCHEMA_DIR="${WORK_DIR}/lib/schema"
declare -ga TSC_DEGRADED=()
# 降级记录文件背书(子 shell 内的 degraded_add 对主流程可见, 见 jsonio.sh)
TSC_DEGRADED_FILE="$(mktemp "${TMPDIR:-/tmp}/tsc_iaas_info_v2_degraded.XXXXXX")"
trap 'rm -f "${TSC_DEGRADED_FILE}"' EXIT

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --contract_no <v>            Specify the contract number (optional)
  --location <v>               Specify the location (optional)
  --sn <v>                     Override the serial number (optional)
  --runtime                    Gather runtime information (no argument)
  --cpu_threshold <0-100>      CPU usage alert threshold, percent (default: 90)
  --memory_threshold <0-100>   Memory usage alert threshold, percent (default: 90)
  --storage_threshold <0-100>  Mountpoint size/inode usage alert threshold, percent (default: 90)
  --help                       Show this help message and exit

资产模式: 静态采集(os/cpu/memory/sn/storage/raid_controllers) + 落盘去重。
runtime: cpu/内存/挂载点监控 + 阈值告警 + RAID 状态告警 + 硬件变更对比。
输出由 lib/schema 骨架驱动(DESIGN.md); 适配器契约见 DESIGN §4。
EOF
}

OPTIONS="$(getopt \
    --options="" \
    --longoptions=contract_no:,location:,sn:,help,runtime,cpu_threshold:,storage_threshold:,memory_threshold: \
    --name "$0" \
    -- "$@")" || {
    usage
    exit 1
}
eval set -- "$OPTIONS"

contract_no=""
location=""
sn=""
runtime_flag=false
cpu_threshold=90
memory_threshold=90
storage_threshold=90

while true; do
    case "$1" in
    --runtime)
        runtime_flag=true
        shift
        ;;
    --cpu_threshold)
        cpu_threshold="$2"
        shift 2
        ;;
    --storage_threshold)
        storage_threshold="$2"
        shift 2
        ;;
    --memory_threshold)
        memory_threshold="$2"
        shift 2
        ;;
    --sn)
        sn="$2"
        shift 2
        ;;
    --contract_no)
        contract_no="$2"
        shift 2
        ;;
    --location)
        location="$2"
        shift 2
        ;;
    --help)
        usage
        exit 0
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
done

# 阈值: 百分比 0-100 整数(DESIGN.md §9.3)
for t in "${cpu_threshold}" "${memory_threshold}" "${storage_threshold}"; do
    if ! [[ "${t}" =~ ^[0-9]+$ ]] || ((t < 0 || t > 100)); then
        echo "ERROR: thresholds must be integers in 0-100, got '${t}'" >&2
        usage
        exit 1
    fi
done

mkdir -p /var/log/tsc/
original_logfile="/var/log/tsc/tsc_iaas_info_v2.json"

if "${runtime_flag}"; then
    run_runtime_monitor "${cpu_threshold}" "${memory_threshold}" "${storage_threshold}" "${original_logfile}"
    exit 0
fi

# ===== 静态模式: 骨架填充 → 校验 → 落盘 → MD5 去重 → 软链 =====
timestamp="$(date +%Y%m%d%H%M%S)"
new_file="/var/log/tsc/tsc_iaas_info_v2-${timestamp}.json"

doc="$(static_main "${sn}" "${contract_no}" "${location}" "${original_logfile}")"
jsonio_validate static <<<"${doc}"

printf '%s\n' "${doc}" | jq -S . | tee "${new_file}"

# MD5 对比去重(语义与 v1 一致; 忽略 meta.generated_at——时间戳不参与内容比对)
md5_new="$(jq -Src 'del(.meta.generated_at)' "${new_file}" | md5sum | awk '{print $1}')"
orig_target="$(readlink -f "${original_logfile}" 2>/dev/null || true)"
md5_orig=""
if [[ -n "${orig_target}" && -f "${orig_target}" ]]; then
    md5_orig="$(jq -Src 'del(.meta.generated_at)' "${orig_target}" | md5sum | awk '{print $1}')"
elif [[ -f "${original_logfile}" ]]; then
    md5_orig="$(jq -Src 'del(.meta.generated_at)' "${original_logfile}" | md5sum | awk '{print $1}')"
fi
if [[ -n "${md5_new}" && "${md5_new}" == "${md5_orig}" ]]; then
    if [[ -n "${orig_target}" && -f "${orig_target}" ]]; then
        rm -f "${orig_target}" || true
    fi
fi
ln -sf "${new_file}" "${original_logfile}"
