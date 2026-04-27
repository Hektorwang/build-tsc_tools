#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2046,SC2086,SC2116,SC2154
# =============================================================================
# run.sh — tsc_iaas_info 模块主入口
# =============================================================================
# 功能:
#   1. 静态信息模式（默认）: 采集系统硬件信息，保存到带时间戳的 JSON 文件，
#      通过软链接管理版本，MD5 对比去重
#   2. 运行时模式（--runtime）: 采集资源使用率，对比历史数据生成告警
#
# 文件版本管理机制:
#   每次运行生成: /var/log/tsc/tsc_iaas_info-{timestamp}.json
#   软链接:       /var/log/tsc/tsc_iaas_info.json → 最新文件
#   MD5 对比:     内容相同则删除旧文件（节省空间）
#                 内容不同则保留旧文件（供运行时模式做历史对比告警）
#
# 用法:
#   source /home/tsc/tsc_profile
#   tsc --tsc_iaas_info [OPTIONS]
# =============================================================================
set -o errexit    # 命令失败时立即退出
set -o nounset    # 使用未定义变量时报错
set -o pipefail   # 管道中任意命令失败时返回非零
set +o posix      # 关闭 POSIX 模式，允许使用 Bash 扩展语法
shopt -s nullglob # glob 无匹配时返回空字符串而非原始模式

# 获取脚本所在目录的绝对路径，并切换到该目录
# readlink -f 解析符号链接，确保 WORK_DIR 是真实路径
WORK_DIR="$(dirname "$(readlink -f "$0")")" && cd "${WORK_DIR}" || exit 99

# 加载 tsc 公共函数库（提供 detect_system_info 等函数）
# TSC_FUNC 为 true 时表示已由外部加载，跳过重复 source
if ! "${TSC_FUNC:-false}"; then
    source "${WORK_DIR}/../../func"
fi

# =============================================================================
# 加载所有 lib 模块（顺序重要：被依赖的模块先加载）
# =============================================================================
source "${WORK_DIR}/lib/common.sh"          # 公共常量和工具函数（最先加载）
source "${WORK_DIR}/lib/raid/detector.sh"   # RAID 类型检测
source "${WORK_DIR}/lib/raid/lsi.sh"        # LSI/MegaRAID 适配器
source "${WORK_DIR}/lib/raid/adaptec.sh"    # Adaptec 适配器
source "${WORK_DIR}/lib/raid/sas3.sh"       # SAS3 适配器
source "${WORK_DIR}/lib/raid/sas2.sh"       # SAS2 适配器
source "${WORK_DIR}/lib/collectors/cpu.sh"      # CPU 静态信息采集
source "${WORK_DIR}/lib/collectors/memory.sh"   # 内存静态信息采集
source "${WORK_DIR}/lib/collectors/system.sh"   # 系统元数据采集（SN/厂商等）
source "${WORK_DIR}/lib/collectors/storage.sh"  # 磁盘/存储信息采集
source "${WORK_DIR}/lib/monitors/cpu.sh"        # CPU 运行时监控
source "${WORK_DIR}/lib/monitors/memory.sh"     # 内存运行时监控
source "${WORK_DIR}/lib/monitors/storage.sh"    # 挂载点运行时监控
source "${WORK_DIR}/lib/monitors/raid.sh"       # RAID 健康状态监控
source "${WORK_DIR}/lib/alert.sh"               # 告警生成
source "${WORK_DIR}/lib/info_main.sh"           # 静态信息采集编排
source "${WORK_DIR}/lib/runtime_main.sh"        # 运行时监控编排

# =============================================================================
# 命令行帮助
# =============================================================================
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --contract_no <contract_no>   Specify the contract number (optional, requires a parameter)
  --location <location>         Specify the location (optional, requires a parameter)
  --runtime                     Gather runtime information (optional, no parameter)
  --cpu_threshold <value>       Set CPU usage threshold (used with --runtime, requires a parameter, default: 90)
  --storage_threshold <value>   Set storage usage threshold (used with --runtime, requires a parameter, default: 90)
  --memory_threshold <value>    Set memory usage threshold (used with --runtime, requires a parameter, default: 90)
  --help                        Show this help message and exit
EOF
}

# =============================================================================
# 参数解析
# =============================================================================
OPTIONS=$(
    getopt \
        --options="" \
        --longoptions=contract_no:,location:,sn:,help,runtime,cpu_threshold:,storage_threshold:,memory_threshold: \
        --name "$0" \
        -- "$@"
) || {
    usage
    exit 1
}
eval set -- "$OPTIONS"

# 参数默认值
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

# =============================================================================
# 日志目录和软链接路径
# =============================================================================
mkdir -p /var/log/tsc/

# original_logfile 是软链接，始终指向最新的时间戳文件
# 运行时模式用它读取历史数据做对比告警
# 静态信息模式用它确定上次结果的 MD5
original_logfile="/var/log/tsc/tsc_iaas_info.json"

# =============================================================================
# 运行时模式：直接输出，不做文件版本管理
# =============================================================================
if "${runtime_flag}"; then
    run_runtime_monitor "${cpu_threshold}" "${memory_threshold}" "${storage_threshold}" "${original_logfile}"
    exit $?
fi

# =============================================================================
# 静态信息模式：采集 → 保存时间戳文件 → MD5 对比 → 更新软链接
# =============================================================================

# 生成带时间戳的文件名，确保每次运行产生唯一文件
timestamp="$(date +%Y%m%d%H%M%S)"
new_file="/var/log/tsc/tsc_iaas_info-${timestamp}.json"

# 采集信息并保存（jq -S 对 key 排序，确保 MD5 对比时字段顺序一致）
collect_all_info "${sn}" "${contract_no}" "${location}" "${original_logfile}" | jq -S . | tee "${new_file}"

# --- MD5 对比机制 ---
# 目的: 若本次采集结果与上次完全相同，删除旧文件节省磁盘空间
#       若不同，保留旧文件供运行时模式做历史对比告警

# 计算新文件的 MD5（jq -Src 规范化 JSON 后计算，消除格式差异）
md5_new="$(jq -Src . "${new_file}" | md5sum | awk '{print $1}')"

# 获取软链接当前指向的真实文件路径（可能是上次的时间戳文件）
orig_target="$(readlink -f "${original_logfile}" 2>/dev/null || true)"
md5_orig=""

if [[ -n "${orig_target}" && -f "${orig_target}" ]]; then
    # 软链接指向的目标文件存在，计算其 MD5
    md5_orig="$(jq -Src . "${orig_target}" | md5sum | awk '{print $1}')"
elif [[ -f "${original_logfile}" ]]; then
    # 软链接不存在但文件本身存在（普通文件情况），直接计算
    md5_orig="$(jq -Src . "${original_logfile}" | md5sum | awk '{print $1}')"
fi

if [[ -n "${md5_new}" && "${md5_new}" == "${md5_orig}" ]]; then
    # 内容相同：删除旧的时间戳文件，只保留新文件
    # 这样磁盘上始终只有一个文件（最新的），节省空间
    if [[ -n "${orig_target}" && -f "${orig_target}" ]]; then
        rm -f "${orig_target}" || true
    fi
fi

# 更新软链接指向新文件（无论内容是否相同，软链接始终指向最新文件）
ln -sf "${new_file}" "${original_logfile}"
