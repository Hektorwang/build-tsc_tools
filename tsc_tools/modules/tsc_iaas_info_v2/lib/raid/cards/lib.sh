#!/usr/bin/env bash
# shellcheck disable=SC2124
# =============================================================================
# lib/raid/cards/lib.sh — 卡型适配器公共助手 (DESIGN.md §4.2/§6)
# =============================================================================
# 被各 cards/<type>.sh source 使用，不可直接执行。
# 不含任何厂商逻辑，不注册卡型。
#
# 提供:
#   card_find_tool <tool> [候选路径...]  — 管理工具查找(v1 detector 顺序平移)
#   col_by_header <输出> <表头行正则> <列名...>
#   to_gb <size> <unit>
#   state_norm <vendor-state>
#   json_line <jq参数...>
# =============================================================================

# packages/ 目录(工具捆绑二进制的查找基准); WORK_DIR 未设时跳过该候选
# shellcheck disable=SC2034  # 由各卡型文件(card_find_tool 调用处)引用
TSC_PKG_DIR="${WORK_DIR:-}/../packages"

# -----------------------------------------------------------------------------
# card_find_tool <tool> [候选路径...]
#
# 查找顺序(平移自 v1 lib/raid/detector.sh): /bin → /sbin → 候选路径
# (packages/捆绑二进制、厂商安装路径) → command -v。
# 找到输出完整路径(rc=0); 找不到 rc=1 无输出。
# -----------------------------------------------------------------------------
card_find_tool() {
    local tool="$1" p
    shift
    for p in "/bin/${tool}" "/sbin/${tool}" "$@"; do
        if [[ -x "${p}" ]]; then
            printf '%s\n' "${p}"
            return 0
        fi
    done
    command -v "${tool}" 2>/dev/null
}

# -----------------------------------------------------------------------------
# col_by_header <输出文本> <表头行正则> <列名...>
#
# 从实际输出中找到第一条匹配 <表头行正则> 的行, 按空白分词后定位各 <列名>
# 的 1-based 列号, 以空格分隔输出(调用方 read -r a b c <<<"$(...)" 接收,
# 配合 awk -v 或按列取值)。
# 用于替代写死的 $9 等列位 —— 厂商换版本挪列位时旧解析静默算错(DESIGN §6)。
#
# 注意: 列名必须与表头行的单个空白分词完全一致(如 storcli 的 "EID:Slt"
# 是一个分词); 找不到表头行或任一列名 → rc=1, 诊断信息走 stderr。
# -----------------------------------------------------------------------------
col_by_header() {
    local output="$1" header_re="$2"
    shift 2

    local header
    header="$(printf '%s\n' "${output}" | grep -E "${header_re}" | head -n1)"
    if [[ -z "${header}" ]]; then
        echo "col_by_header: header line not found for: ${header_re}" >&2
        return 1
    fi

    local -a tokens=() idx=()
    read -r -a tokens <<<"${header}"

    local want i found
    for want in "$@"; do
        found=""
        for i in "${!tokens[@]}"; do
            if [[ "${tokens[$i]}" == "${want}" ]]; then
                found=$((i + 1))
                break
            fi
        done
        if [[ -z "${found}" ]]; then
            echo "col_by_header: column '${want}' not in header: ${header}" >&2
            return 1
        fi
        idx+=("${found}")
    done

    printf '%s\n' "${idx[*]}"
}

# -----------------------------------------------------------------------------
# to_gb <size> <unit>
#
# 尺寸数值化为 GB(二进制 1024 进制, 与 lsblk/厂商工具的容量单位一致):
#   to_gb 893.156 GB  → 893
#   to_gb 8388608 MB  → 8192
#   to_gb 894.3 G     → 894
# 单位接受单字母(B/K/M/G/T/P)与带 B 后缀形式(KB/MB/GB/TB/PB), 大小写不敏感。
# 结果四舍五入取整; 非法单位 → rc=1, 空输出(调用方落 null, 不得中断采集)。
# 针对旧病: v1 对 lsblk SIZE 只认 T/G, 其余单位整条采集链崩溃(DESIGN §8 步骤1)。
# -----------------------------------------------------------------------------
to_gb() {
    local size="$1" unit="$2"

    unit="$(printf '%s' "${unit}" | tr '[:lower:]' '[:upper:]')"
    unit="${unit%B}"   # GB→G, MB→M, TB→T; 单字母形式不受影响

    local exp
    case "${unit}" in
        B) exp=-30 ;;
        K) exp=-20 ;;
        M) exp=-10 ;;
        G) exp=0 ;;
        T) exp=10 ;;
        P) exp=20 ;;
        *)
            echo "to_gb: unknown unit '${unit}'" >&2
            return 1
            ;;
    esac

    awk -v s="${size}" -v e="${exp}" 'BEGIN { printf "%.0f", s * 2^e }'
}

# -----------------------------------------------------------------------------
# state_norm <vendor-state>
#
# 通用厂商状态词表 → 归一枚举(DESIGN.md §3.1):
#   online | rebuild | degraded | failed | missing | unknown
# 未收录的状态词归 unknown, 恒 rc=0(状态归一不得中断采集)。
# 卡型特有状态词先在卡型内本地映射后再调用本函数(见文件头词表约定)。
# -----------------------------------------------------------------------------
state_norm() {
    # 先整体转小写(bash 4.2 无 ${var,,}), 再匹配单套小写词表
    local s
    s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "${s}" in
        # 全称与厂商缩写态(storcli: onln/optl/rbld/dgrd)均覆盖; 尾部 * 允许
        # "online,spun up" 这类复合值
        online* | onln* | opt* | ok* | good* | ready* | unconfigured\ good*)
            echo "online"
            ;;
        rebuild* | reconstruct* | rbld*)
            echo "rebuild"
            ;;
        degrad* | dgrd* | critical*)
            echo "degraded"
            ;;
        fail* | error* | offlin* | of\ lin* | ofln* | dead | fault* | bad* | block*)
            echo "failed"
            ;;
        miss* | remov* | not\ present* | absent*)
            echo "missing"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# strip_state_parens <raw> — 去掉厂商状态的括号注记: "Ready (RDY)" → "Ready"
strip_state_parens() {
    printf '%s' "${1%%(*}" | sed 's/[[:space:]]*$//'
}

# -----------------------------------------------------------------------------
# json_line <jq参数...>
#
# 适配器 stdout 的唯一出口: 强制 jq -c 紧凑单行输出(DESIGN.md §5 军规 2,
# 针对 v1 pretty/compact 混用导致的 sas3 崩溃链)。参数透传 jq
# (如: json_line -n --arg dev sda '{dev:$dev}')。
# -----------------------------------------------------------------------------
json_line() {
    jq -c "$@"
}
