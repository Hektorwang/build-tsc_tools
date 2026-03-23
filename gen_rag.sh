#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2046,SC2086,SC2116,SC2154
set -o errexit
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob

WORK_DIR="$(dirname "$(readlink -f "$0")")" && cd "${WORK_DIR}" || exit 99
script_name="$(basename "$0" 2>/dev/null)"
RAG_FILE=${WORK_DIR}/tsc_tools/rag.md

# 获取所有模块 readme
mapfile -t readme_files < <(find ${WORK_DIR}/tsc_tools/modules/ -iname 'readme.md')

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
