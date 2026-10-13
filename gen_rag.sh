#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2046,SC2086,SC2116,SC2154
set -o errexit
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob

WORK_DIR="$(dirname "$(readlink -f "$0")")" && cd "${WORK_DIR}" || exit 99
script_name="$(basename "$0" 2>/dev/null)"
# 定位 modules 与 rag 输出路径
#   源码树 (gen_rag.sh 在项目根, 同级有 tsc_tools/): 构建期只用源码树 modules,
#     不 source 已安装的 tsc_profile, 避免构建机上的旧安装版污染 rag 内容
#   包内/目标机 (gen_rag.sh 在 tsc_tools/ 下): source tsc_profile 拿 TSC_MODULES_DIR,
#     支持多工具 (tsc_python 等) 扩展 modules
if [[ -d "${WORK_DIR}/tsc_tools" ]]; then
    modules_dirs="${WORK_DIR}/tsc_tools/modules"
    RAG_FILE="${WORK_DIR}/tsc_tools/rag.md"
else
    _tsc_profile="/home/tsc/tsc_profile"
    if [[ -f "${_tsc_profile}" ]]; then
        if ! source "${_tsc_profile}" 2>/tmp/_gen_rag_source.err; then
            echo "WARNING: source ${_tsc_profile} 失败, rag.md 可能只含本包模块: $(cat /tmp/_gen_rag_source.err 2>/dev/null)" >&2
            rm -f /tmp/_gen_rag_source.err
        fi
        rm -f /tmp/_gen_rag_source.err
    fi
    modules_dirs="${TSC_MODULES_DIR:-${WORK_DIR}/modules}"
    RAG_FILE="${WORK_DIR}/rag.md"
fi

##################################################
# 冒号分隔目录列表去重 (保持原顺序, 去掉重复项)
#
# 必要性: TSC_MODULES_DIR 由各工具 drop-in 各自追加, 任一环节被 source 两次
# (嵌套 shell / 脚本重复 source tsc_profile) 就会出现重复目录; 不去重则同一份
# readme 被 find 到多次, rag.md 成倍膨胀 (现场实测: 重复 5 次 -> 4132 行 vs 1026 行)。
# 参数:
#   $1 - 冒号分隔的目录列表
# 输出: 去重后的冒号分隔列表
##################################################
dedup_dirs() {
    local IFS=':' _d _out="" _arr=()
    read -r -a _arr <<<"$1" || true
    for _d in "${_arr[@]}"; do
        [[ -n "${_d}" ]] || continue
        [[ ":${_out}:" == *":${_d}:"* ]] && continue
        _out="${_out:+${_out}:}${_d}"
    done
    printf '%s' "${_out}"
}

if [[ -n "${modules_dirs}" ]]; then
    _deduped="$(dedup_dirs "${modules_dirs}")"
    if [[ "${_deduped}" != "${modules_dirs}" ]]; then
        echo "WARN: 模块目录列表含重复项, 已去重: ${modules_dirs}" >&2
    fi
    modules_dirs="${_deduped}"
fi

if [[ -z "${modules_dirs}" ]]; then
    echo "ERROR: no modules dir found under ${WORK_DIR}" >&2
    exit 1
fi

# 获取所有模块 readme (遍历 TSC_MODULES_DIR 冒号分隔的多目录, 适配多工具扩展)
# 尾部 awk 去重: 兜住多目录互相包含等去重后仍会产出重复路径的情形
mapfile -t readme_files < <(
    IFS=':'
    for _d in ${modules_dirs}; do
        [[ -d "$_d" ]] || continue
        find "$_d" -name 'README.md'
    done | awk '!seen[$0]++'
)

if [[ ${#readme_files[@]} -eq 0 ]]; then
    echo "ERROR: no README.md found under: ${modules_dirs}" >&2
    exit 1
fi

# 处理readme文件, 去掉元数据, 并将其下的标题都下沉一级
parse_readme() {
    local _readme="$1"
    awk '
    BEGIN { in_meta = 0; in_code = 0 }
    # 1. 检测 Front Matter 分隔符 (---)
    /^---$/ {
        in_meta++
        next # 跳过分隔符本身，不打印
    }
    # 2. 如果还在元数据区 (遇到第1个 --- 后，直到第2个 --- 前)，直接跳过所有行
    in_meta < 2 { next }
    # 3. 检测代码块 (``` 开头，允许前后有空格)
    /^[[:space:]]*```/ {
        in_code = !in_code # 逻辑取反：真变假，假变真
        print $0           # 打印代码块标记行 (原样输出)
        next
    }
    # 4. 核心处理逻辑
    {
        if (in_code) {
            # 在代码块内：原样输出，不要修改标题 (防止修改代码注释里的 #)
            print $0
        } else {
            # 不在代码块内：标题下沉一级
            # 只有当行首是 # 时才处理，且只加一个 #
            if ($0 ~ /^#+/) {
                print "#" $0
            } else {
                print $0
            }
        }
    }
    ' "${_readme}"
}

# 提取并生成元数据
echo '---' >"${RAG_FILE}"
for readme in "${readme_files[@]}"; do
    module_name="$(basename "$(dirname $readme)")"
    echo "处理元数据: ${readme}"
    (
        echo "- ${module_name}:"
        awk 'BEGIN{c=0} /^---$/{c++; if(c==1){next}; if(c==2){exit}} c==1' "${readme}" | sed 's/^/  /g'
    ) >>"${RAG_FILE}"
done
echo -e '---\n' >>"${RAG_FILE}"

# 提取并生成正文
echo "处理正文: ${WORK_DIR}/README.md"
cat "${WORK_DIR}"/README.md >>"${RAG_FILE}"

for readme in "${readme_files[@]}"; do
    echo "处理正文: ${readme}"
    parse_readme "${readme}" >>"${RAG_FILE}"
done
