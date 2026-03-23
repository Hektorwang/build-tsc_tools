#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2046,SC2086,SC2116,SC2154
set -o errexit
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob

PROJECT_DIR="$(dirname "$(readlink -f "$0")")" && cd "${PROJECT_DIR}" || exit 99

# 定义版本和日期变量
version="$(awk -F '=' '/Version=/{print $2;exit}' <"${PROJECT_DIR}"/release-note.md)"
createdate="$(date "+%Y%m%d")"

# 定义文件和目录
RELEASE_DIR="${PROJECT_DIR}/release"
PACKAGE_SOURCE_DIR="${PROJECT_DIR}/stage"
RELEASE_FILE="${RELEASE_DIR}/tsc_tools-${version}-noarch-${createdate}.sh"

# 清理并创建打包源目录
rm -rf "${PACKAGE_SOURCE_DIR}"
mkdir -p "${PACKAGE_SOURCE_DIR}"

# 生成 rag 友好的文档
"${PROJECT_DIR}"/gen_rag.sh
# 将需要打包的文件和目录复制到临时目录
\cp "${PROJECT_DIR}"/README.md "${PROJECT_DIR}"/tsc_tools/
\cp "${PROJECT_DIR}"/release-note.md "${PROJECT_DIR}"/tsc_tools/
# \cp "${PROJECT_DIR}"/LICENSE-GPL.txt "${PROJECT_DIR}"/tsc_tools/
# \cp "${PROJECT_DIR}"/NOTICE.txt "${PROJECT_DIR}"/tsc_tools/
# \cp "${PROJECT_DIR}"/LICENSE-MIT.txt "${PROJECT_DIR}"/tsc_tools/
\cp "${PROJECT_DIR}"/.supported_env.conf "${PROJECT_DIR}"/tsc_tools/
\cp "${PROJECT_DIR}"/install.sh "${PACKAGE_SOURCE_DIR}"/
\cp -r "${PROJECT_DIR}"/tsc_tools "${PACKAGE_SOURCE_DIR}"/
find "${PACKAGE_SOURCE_DIR}" -type f -name "*.sh" -exec chmod +x {} \;
find "${PACKAGE_SOURCE_DIR}" -type f -name "*.sh" -exec dos2unix {} \;

# 打印打包信息
echo "Build Start --> ${RELEASE_FILE}"

# 创建发布目录
mkdir -p "${RELEASE_DIR}"

# 使用 makeself 打包
# --help-header tsc_tools/README.md \
"${PROJECT_DIR}"/makeself.sh --needroot --tar-quietly \
    "${PACKAGE_SOURCE_DIR}" "${RELEASE_FILE}" \
    "TSC Tools" \
    ./install.sh
chmod +x "${RELEASE_FILE}"

# 清理临时目录
rm -rf "${PACKAGE_SOURCE_DIR}"

echo "Build Over --> ${RELEASE_FILE}"
exit 0
