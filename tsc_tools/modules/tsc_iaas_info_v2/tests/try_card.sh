#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2094
# =============================================================================
# tests/try_card.sh — 真机原始输出试跑口子 (DESIGN.md §8 步骤2/3/4 前置)
# =============================================================================
# 用途: 把现役机器抓取的厂商 CLI 原始文本喂给对应卡适配器, 不改代码直接查看
# 解析产物; 确认无误后将文件复制为 fixture 替换 tests/fixtures/raid/<卡>/ 下
# 合成样例, 并复跑 tests/test_card_<卡>.sh 锁定。
#
# 用法:
#   try_card.sh <卡型> <raw目录> [--no-validate]
#
# raw目录内文件命名约定(缺哪个文件, 对应节即按设计降级——正好验证容错):
#   direct : lsblk.txt                 (lsblk -Pdo NAME,MODEL,... 输出)
#   lsi    : show.txt                  (storcli show; 控制器清单+System Overview)
#            c<N>_show_all.txt            (/c<N> show all, N=控制器号, 从0)
#   sas3   : list.txt                  (sas3ircu list)
#            display<N>.txt              (sas3ircu <N> display)
#   sas2   : list.txt / display<N>.txt (sas2ircu, 与 sas3 同构)
#   adaptec: getconfig<N>.txt          (arcconf GETCONFIG <N>, N 从 1)
#
# 输出四段: detect 结果 / 全量模型 / 两个提取器投影 / 组装+schema 校验。
# 原始文件允许 CRLF(脚本自动转 LF 副本, 源文件不动)。
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail
set +o posix

CARD="${1:-}"
RAWDIR="${2:-}"
NO_VALIDATE="${3:-}"
[[ -n "${CARD}" && -n "${RAWDIR}" ]] || {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

HERE="$(dirname "$(readlink -f "$0")")"
MODULE_LIB="$(dirname "${HERE}")/lib"
export TSC_SCHEMA_DIR="${MODULE_LIB}/schema"
WORK_DIR="$(dirname "$(dirname "${MODULE_LIB}")")"   # 供 TSC_PKG_DIR 查捆绑工具
export WORK_DIR

TSC_DEGRADED_FILE="$(mktemp /tmp/try_card_degraded.XXXXXX)"
declare -ga TSC_DEGRADED=()  # 由 degraded_add/degraded_sync 读写
trap 'rm -rf "${TSC_DEGRADED_FILE}" "${MOCK}" "${CLEAN}"' EXIT

source "${MODULE_LIB}/raid/cards/lib.sh"
source "${MODULE_LIB}/raid/extract.sh"
source "${MODULE_LIB}/jsonio.sh"
source "${MODULE_LIB}/raid/detector.sh"
case "${CARD}" in
    direct)  source "${MODULE_LIB}/raid/cards/direct.sh"  ;;
    lsi)     source "${MODULE_LIB}/raid/cards/lsi.sh"     ;;
    sas3)    source "${MODULE_LIB}/raid/cards/sas3.sh"    ;;
    sas2)    source "${MODULE_LIB}/raid/cards/sas2.sh"    ;;
    adaptec) source "${MODULE_LIB}/raid/cards/adaptec.sh" ;;
    *) echo "未知卡型: ${CARD}(可选 direct|lsi|sas3|sas2|adaptec)" >&2; exit 1 ;;
esac

RAWDIR="$(readlink -f "${RAWDIR}")"
[[ -d "${RAWDIR}" ]] || { echo "raw 目录不存在: ${RAWDIR}" >&2; exit 1; }

# 原始文本统一转 LF 副本(源文件不动)
CLEAN="$(mktemp -d /tmp/try_card_raw.XXXXXX)"
MOCK="$(mktemp -d /tmp/try_card_mock.XXXXXX)"
for f in "${RAWDIR}"/*; do
    [[ -f "${f}" ]] || continue
    tr -d '\r' <"${f}" >"${CLEAN}/$(basename "${f}")"  # 源/目的不同目录, 非同文件读写
done

# --- 按卡型构造厂商命令 mock(参数感知) ---
case "${CARD}" in
    direct)
        cat >"${MOCK}/lsblk" <<EOF
#!/usr/bin/env bash
cat "${CLEAN}/lsblk.txt"
EOF
        ;;
    lsi)
        cat >"${MOCK}/storcli" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *" show all"*)
    ctl="\$1"; ctl="\${ctl#/c}"
    f="${CLEAN}/c\${ctl}_show_all.txt"
    [[ -f "\$f" ]] || f="${CLEAN}/c0_show_all.txt"
    cat "\$f" ;;
  *) cat "${CLEAN}/show.txt" ;;
esac
EOF
        ;;
    sas3 | sas2)
        tool="${CARD}ircu"
        cat >"${MOCK}/${tool}" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *list*) cat "${CLEAN}/list.txt" ;;
  *display*)
    n="\$1"; n="\${n//[^0-9]/}"
    f="${CLEAN}/display\${n}.txt"
    [[ -f "\$f" ]] || f="${CLEAN}/display0.txt"
    cat "\$f" ;;
esac
EOF
        ;;
    adaptec)
        cat >"${MOCK}/arcconf" <<EOF
#!/usr/bin/env bash
if [[ "\$*" =~ GETCONFIG[[:space:]]+([0-9]+) ]]; then
  n="\${BASH_REMATCH[1]}"
  f="${CLEAN}/getconfig\${n}.txt"
  [[ -f "\$f" ]] || f="${CLEAN}/getconfig1.txt"
  cat "\$f"
fi
EOF
        ;;
esac
chmod +x "${MOCK}"/*
export PATH="${MOCK}:${PATH}"

# 强制卡适配器使用 mock: 显式路径(/bin /sbin /opt)优先于 PATH, 仅靠前置 PATH
# 会被真工具劫持 —— 直接覆盖工具查找函数
case "${CARD}" in
    lsi)     _lsi_storcli_bin() { printf '%s\n' "${MOCK}/storcli"; } ;;
    sas3 | sas2 | adaptec) card_find_tool() { printf '%s\n' "${MOCK}/${1}"; } ;;
esac

hr() { printf '%s\n' "------------------------------------------------------------"; }

# --- 1. detect ---
hr
echo "== 1. card_${CARD}_detect =="
detect_rc=0
"card_${CARD}_detect" || detect_rc=$?
if (( detect_rc == 0 )); then
    echo "在位(通道参与采集)"
else
    echo "不在位(检查: 工具是否随 mock 在 PATH / lspci/lsmod 硬件证据)"
fi

# --- 2. parse 全量模型 ---
hr
echo "== 2. card_${CARD}_parse → 全量模型 =="
FULL="$(card_"${CARD}"_parse)"
jq . <<<"${FULL}"

# --- 3. 提取器投影 ---
hr
echo "== 3. extract_topology(资产投影) =="
TOPO="$(extract_topology <<<"${FULL}")"
jq . <<<"${TOPO}"
hr
echo "== 3. extract_health(runtime 投影) =="
extract_health <<<"${FULL}" | jq .

# --- 4. 组装 + schema 校验 ---
if [[ "${NO_VALIDATE}" != "--no-validate" ]]; then
    hr
    echo "== 4. 组装进静态骨架 + schema 校验 =="
    DOC="$(jsonio_build_static '{}' '{"sn":null}' '{"contract_no":null}' '{"location":null}' \
        '{"memory":[]}' '{"cpu":{}}' "Unknown" "unknown" "[]" "$(date -Iseconds)" "${TOPO}")"
    if jsonio_validate static <<<"${DOC}" 2>&1; then
        echo "schema 校验: 通过"
    else
        echo "schema 校验: 未通过(检查上方 jq 报错)"
    fi
    echo "降级记录: $([[ -s "${TSC_DEGRADED_FILE}" ]] && tr '\n' ' ' <"${TSC_DEGRADED_FILE}" || echo 无)"
    echo "(组装文档可用: echo 上方 DOC | jq -S . 查看; 或重定向保存)"
fi
hr
