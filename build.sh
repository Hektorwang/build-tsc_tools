#!/usr/bin/env bash
#
# tsc_tools RPM 打包器
#
# 产出: release/tsc_tools-<version>-<release>.noarch.rpm
#   version 取自 release-note.md 的 Version=
#   release 取构建时间戳 YYYYMMDDHHMMSS (同日多次构建 NVR 可区分)
#
# 打包机依赖:
#   nfpm      RPM 打包工具 (默认 /bin/nfpm, 可用 NFPM_BIN 覆盖)
#   dos2unix  统一换行符
#
# 用法:
#   ./build.sh
#   NFPM_BIN=/usr/local/bin/nfpm ./build.sh
##################################################
# shellcheck disable=SC1090,SC1091,SC2034,SC2046,SC2086,SC2116,SC2154
set -o errexit
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob
# 固定 umask: 产物文件权限 = 源文件 mode & umask, 收紧的构建机 umask(如 0077)
# 会静默削掉权限, 这里统一保证常规权限可预期
umask 022

PROJECT_DIR="$(dirname "$(readlink -f "$0")")" && cd "${PROJECT_DIR}" || exit 99

readonly PACKAGING_DIR="${PROJECT_DIR}/packaging/rpm"

##################################################
# 打包依赖检查
##################################################
# nfpm: 由打包机提供, 优先取 /bin/nfpm
NFPM_BIN="${NFPM_BIN:-}"
if [[ -z "${NFPM_BIN}" && -x /bin/nfpm ]]; then
    NFPM_BIN="/bin/nfpm"
elif [[ -z "${NFPM_BIN}" ]] && command -v nfpm &>/dev/null; then
    NFPM_BIN="$(command -v nfpm)"
fi
if [[ -z "${NFPM_BIN}" || ! -x "${NFPM_BIN}" ]]; then
    echo "ERROR: nfpm not found on this build host." >&2
    echo "       tsc_tools 使用 nfpm 打 RPM 包, 请先在打包机安装 nfpm (期望路径 /bin/nfpm):" >&2
    echo "         https://nfpm.goreleaser.com/install/" >&2
    echo "       也可放入 PATH, 或用 NFPM_BIN=/path/to/nfpm ./build.sh 显式指定。" >&2
    exit 1
fi

if ! command -v dos2unix &>/dev/null; then
    echo "ERROR: dos2unix command not found, please install dos2unix first." >&2
    exit 1
fi

readonly NFPM_VERSION="$("${NFPM_BIN}" --version 2>&1 | awk '/GitVersion:/{print $2; exit}')"
echo "Using packager: ${NFPM_BIN} (nfpm ${NFPM_VERSION:-unknown})"

##################################################
# 定义版本和日期变量
##################################################
version="$(awk -F '=' '/Version=/{print $2;exit}' <"${PROJECT_DIR}"/release-note.md)"
release="$(date "+%Y%m%d%H%M%S")"

# RPM 的 Version 不允许出现 '-', 提前拦下非法版本号
if [[ -z "${version}" ]]; then
    echo "ERROR: 未能从 release-note.md 解析出 Version=" >&2
    exit 1
fi
if [[ "${version}" == *"-"* ]]; then
    echo "ERROR: 版本号 '${version}' 含 '-', RPM Version 不允许该字符。" >&2
    exit 1
fi

##################################################
# 定义文件和目录
##################################################
readonly RELEASE_DIR="${PROJECT_DIR}/release"
readonly STAGE_DIR="${PROJECT_DIR}/stage"
# noarch 单包: 包内同时携带 x86_64 与 aarch64 的自带二进制, 安装期由
# packages/install.sh 按 `arch` 择优部署, 架构白名单由 %pre 校验
readonly RELEASE_FILE="${RELEASE_DIR}/tsc_tools-${version}-${release}.noarch.rpm"

##################################################
# 将 `# >>> INJECT <file>` 标记替换为对应文件的内容
# (%pre 运行时包内文件尚未落盘, 脚本必须自包含)
# 参数:
#   $1 - 模板文件
#   $2 - 输出文件
##################################################
render_template() {
    local tmpl="$1" out="$2"
    awk '
    /^# >>> INJECT / {
        f = substr($0, index($0, "INJECT ") + 7)
        while ((getline line < f) > 0) print line
        close(f)
        next
    }
    { print }
    ' "${tmpl}" >"${out}"
}

##################################################
# 清理并创建打包源目录
##################################################
# EXIT trap: 成功/失败路径均清理 stage/, 与 tsc_python/build.sh 保持一致
trap 'rm -rf "${STAGE_DIR}"' EXIT
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/rpm-scripts" "${STAGE_DIR}/tsc_tools/lib"

# 生成 rag 友好的文档
"${PROJECT_DIR}"/gen_rag.sh

# 将需要打包的文件和目录复制到临时目录
# README.md / release-note.md / .supported_env.conf 只拷进 stage, 不写回 tsc_tools/ 源码树
# (.supported_env.conf 唯一事实源在项目根: %pre 内联读这里, 同时覆盖进 stage 供 %post source)
\cp -r "${PROJECT_DIR}"/tsc_tools/. "${STAGE_DIR}"/tsc_tools/
\cp "${PROJECT_DIR}"/README.md "${STAGE_DIR}"/tsc_tools/
\cp "${PROJECT_DIR}"/release-note.md "${STAGE_DIR}"/tsc_tools/
\cp "${PROJECT_DIR}"/.supported_env.conf "${STAGE_DIR}"/tsc_tools/
# gen_rag.sh 随包发布, 供目标机生成多工具合并 rag (source tsc_profile 后读 TSC_MODULES_DIR)
\cp "${PROJECT_DIR}"/gen_rag.sh "${STAGE_DIR}"/tsc_tools/gen_rag.sh
# rag.md 移出批量安装树: 它以 %config(noreplace) 单独声明, 留在 tsc_tools/ 下会和
# 独立条目指向同一目标路径, 触发 nfpm content collision (同 tsc_python 的 base.yml)
if [[ -f "${STAGE_DIR}/tsc_tools/rag.md" ]]; then
    \mv "${STAGE_DIR}/tsc_tools/rag.md" "${STAGE_DIR}"/rag.md
else
    echo "ERROR: 未生成 ${STAGE_DIR}/tsc_tools/rag.md, gen_rag.sh 可能执行失败。" >&2
    exit 1
fi
# 开发期产物不进 RPM: 自测目录、设计/开发文档 (运行期无依赖)
# 全树范围 (**/tests/** 等), 不限 modules/: 将来任何部位新增都不会漏进包
find "${STAGE_DIR}/tsc_tools" -type d -name tests -prune -exec rm -rf {} +
find "${STAGE_DIR}/tsc_tools" -type f \( -name 'DESIGN.md' -o -name 'README_DEV.md' \) -delete
# env_check.sh 随包发布, 供 %post 复用同一份环境检测逻辑
\cp "${PACKAGING_DIR}"/env_check.sh "${STAGE_DIR}"/tsc_tools/lib/env_check.sh

find "${STAGE_DIR}"/tsc_tools -type f -name "*.sh" -exec chmod +x {} \;
find "${STAGE_DIR}"/tsc_tools -type f -name "*.sh" -exec dos2unix {} \;
# 无扩展名脚本(tsc/func/profile/tsc_profile)不在上面的 *.sh 通配内, 单独规范换行;
# tsc 需可执行位(模块调度入口, 产物自检也会断言)
for _f in tsc func profile tsc_profile; do
    [[ -f "${STAGE_DIR}/tsc_tools/${_f}" ]] || continue
    dos2unix "${STAGE_DIR}/tsc_tools/${_f}"
done
unset _f
chmod +x "${STAGE_DIR}/tsc_tools/tsc"

##################################################
# 生成 RPM scriptlet
##################################################
render_template "${PACKAGING_DIR}/preinstall.sh.tmpl" "${STAGE_DIR}/rpm-scripts/preinstall"
# 注入断言: render_template 对被注入文件缺失是静默输出空, 会导致目标机安装期
# 才以 unbound 变量报错(%pre 在 set -u 下), 这里在打包期硬校验关键串
for _needle in 'SUPPORTED_ARCHITECTURES=' 'is_element_in_array' 'check_env'; do
    if ! grep -q -- "${_needle}" "${STAGE_DIR}/rpm-scripts/preinstall"; then
        echo "ERROR: %pre 缺少注入内容标记 '${_needle}', 注入源文件可能缺失。" >&2
        exit 1
    fi
done
unset _needle
\cp "${PACKAGING_DIR}"/postinstall.sh "${STAGE_DIR}/rpm-scripts/postinstall"
\cp "${PACKAGING_DIR}"/preremove.sh "${STAGE_DIR}"/rpm-scripts/preremove
\cp "${PACKAGING_DIR}"/postremove.sh "${STAGE_DIR}"/rpm-scripts/postremove
chmod 0755 "${STAGE_DIR}"/rpm-scripts/*

# scriptlet 语法自检: 装到目标机上才发现语法错误代价太高
for scriptlet in "${STAGE_DIR}"/rpm-scripts/*; do
    bash -n "${scriptlet}" || {
        echo "ERROR: scriptlet 语法检查未通过: ${scriptlet}" >&2
        exit 1
    }
done

##################################################
# 生成 nfpm 配置
##################################################
readonly NFPm_CONFIG="${STAGE_DIR}/nfpm.yaml"
sed -e "s|@VERSION@|${version}|g" \
    -e "s|@RELEASE@|${release}|g" \
    -e "s|@STAGE_DIR@|${STAGE_DIR}|g" \
    "${PACKAGING_DIR}"/nfpm.yaml.tmpl >"${NFPm_CONFIG}"

##################################################
# 打包
##################################################
mkdir -p "${RELEASE_DIR}"
rm -f "${RELEASE_DIR}"/tsc_tools-*.rpm

echo "Build Start --> ${RELEASE_FILE}"
"${NFPM_BIN}" package --packager rpm --config "${NFPm_CONFIG}" --target "${RELEASE_DIR}/"

if [[ ! -f "${RELEASE_FILE}" ]]; then
    echo "ERROR: 未生成预期的产物 ${RELEASE_FILE}, release 目录现状:" >&2
    ls -l "${RELEASE_DIR}" >&2
    exit 1
fi

##################################################
# 产物自检
##################################################
if command -v rpm &>/dev/null; then
    payload_files="$(rpm -qlp "${RELEASE_FILE}")"
    echo "Package info: $(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}' "${RELEASE_FILE}")"
    echo "Requires: $(rpm -qp --qf '[%{REQUIRENAME} ]' "${RELEASE_FILE}")"
    echo "Payload:  $(wc -l <<<"${payload_files}") files"
    # 单包应同时带上两个架构的自带二进制, 缺一即打包源不完整
    for arch in x86_64 aarch64; do
        if ! grep -q -- "-${arch}\$" <<<"${payload_files}"; then
            echo "ERROR: 产物缺少 ${arch} 的自带二进制。" >&2
            exit 1
        fi
    done
    # 关键可执行文件必须带可执行位, 否则模块无法调度
    if ! rpm -qlpv "${RELEASE_FILE}" |
        awk '$9 == "/home/tsc/tsc_tools/tsc" && $1 == "-rwxr-xr-x" { found = 1 } END { exit !found }'; then
        echo "ERROR: /home/tsc/tsc_tools/tsc 缺少可执行权限。" >&2
        exit 1
    fi
    # scriptlet 必须都写进包里 (nfpm 的 preremove 对应 rpm 的 %preun)
    scripts_dump="$(rpm -qp --scripts "${RELEASE_FILE}")"
    for needle in "preinstall scriptlet" "postinstall scriptlet" "preuninstall scriptlet" "postuninstall scriptlet"; do
        if ! grep -q "^${needle}" <<<"${scripts_dump}"; then
            echo "ERROR: 产物缺少 ${needle} 段。" >&2
            exit 1
        fi
    done
else
    echo "WARNING: 打包机无 rpm 命令, 跳过产物自检。" >&2
fi

##################################################
# 清理临时目录
##################################################
rm -rf "${STAGE_DIR}"

echo "Size:    $(du -h "${RELEASE_FILE}" | cut -f1)"
echo "SHA256:  $(sha256sum "${RELEASE_FILE}" | cut -d' ' -f1)"
echo "Build Over --> ${RELEASE_FILE}"
exit 0
