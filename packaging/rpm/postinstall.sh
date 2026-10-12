#!/bin/bash
#
# tsc_tools RPM ---- %post (安装/升级后配置)
#
# 执行时机: 包文件已落盘至 /home/tsc/tsc_tools 之后
#   $1 == 1  全新安装
#   $1 >= 2  升级 (rpm -U / 重装): 步骤与全新安装一致, 且各步骤均幂等
#
# 职责 (沿用 makeself 时代 install.sh 的 _install 行为):
#   1. 部署自带二进制到 /home/tsc/tsc_tools/bin 与 /bin, 探测式安装 RAID CLI, 写入 /root/.vimrc
#   2. 记录部署清单 .installed_manifest, 供 %preun 精确回收
#   3. 注入/刷新 /home/tsc/tsc_profile 的 TSC_TOOLS 块, 并准备 tsc_profile.d 目录
#   4. 准备 /var/log/tsc 日志目录
##################################################
# shellcheck disable=SC1090,SC1091,SC2034
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "ERROR: /bin/sh is not bash, tsc_tools requires bash >= 4.0." >&2
    exit 1
fi

readonly TSC_HOME_DIR="/home/tsc"
readonly TSC_TOOLS_DIR="${TSC_HOME_DIR}/tsc_tools"
readonly SOURCE_TSC_PROFILE="${TSC_TOOLS_DIR}/tsc_profile"
readonly DEST_TSC_PROFILE="${TSC_HOME_DIR}/tsc_profile"
readonly TSC_PROFILE_D_DIR="${TSC_HOME_DIR}/tsc_profile.d"
readonly LOG_DIR="/var/log/tsc"
readonly MANIFEST_FILE="${TSC_TOOLS_DIR}/.installed_manifest"

if [[ ! -f "${TSC_TOOLS_DIR}/func" ]]; then
    echo "ERROR: ${TSC_TOOLS_DIR}/func is missing, tsc_tools payload is incomplete." >&2
    exit 1
fi

source "${TSC_TOOLS_DIR}/func"
[[ -f "${TSC_TOOLS_DIR}/.supported_env.conf" ]] && source "${TSC_TOOLS_DIR}/.supported_env.conf"
source "${TSC_TOOLS_DIR}/lib/env_check.sh"

declare -A system_info

##################################################
# 判断两个文件二进制内容是否一致
# 用途: 卸载时据此判断系统路径上的文件是否仍为本包部署的版本,
#       防止误删系统自带或被用户改过的同名文件
# 参数:
#   $1 $2 - 两个待比对文件路径
# 返回:
#   0 - 一致
#   1 - 不一致或文件不存在
##################################################
files_identical() {
    local file_a="$1" file_b="$2" sum_a sum_b
    [[ -f "${file_a}" && -f "${file_b}" ]] || return 1
    if command -v sha256sum &>/dev/null; then
        sum_a="$(sha256sum <"${file_a}" | awk '{print $1}')"
        sum_b="$(sha256sum <"${file_b}" | awk '{print $1}')"
        [[ "${sum_a}" == "${sum_b}" ]]
    else
        cmp -s "${file_a}" "${file_b}"
    fi
}

##################################################
# 取本包自带的某个工具的二进制路径 (与 packages/install.sh 的挑选顺序一致:
# <tool>-$(arch) 优先于 <tool>-noarch)
# 参数:
#   $1 - 工具名 (与 packages/<tool>/ 目录名一致)
# 输出:
#   二进制绝对路径
# 返回:
#   0 - 找到
#   1 - 本包未提供该工具
##################################################
bundled_binary_for() {
    local tool="$1" candidate
    for suffix in "$(arch)" "noarch"; do
        candidate="${TSC_TOOLS_DIR}/packages/${tool}/${tool}-${suffix}"
        if [[ -f "${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

##################################################
# 记录实际部署到 /bin 的本包二进制, 供 %preun 精确回收
# 只记录"内容确实与本包自带二进制一致"的条目, 系统自带或已被替换的一律不记
# 注意: 清单由主流程清空后, 本函数与 packages/install.sh 各自追加
# 输出:
#   ${MANIFEST_FILE}, 每行形如 FILE:/bin/jq 或 LINK:/bin/storcli
##################################################
record_manifest() {
    local pkg_dir tool candidate bin_path
    for pkg_dir in "${TSC_TOOLS_DIR}"/packages/*/; do
        [[ -d "${pkg_dir}" ]] || continue
        tool="$(basename "${pkg_dir}")"
        candidate="$(bundled_binary_for "${tool}")" || continue
        bin_path="/bin/${tool}"
        # 只记录"常规文件且内容与本包自带二进制一致"的条目:
        # 系统可能自带同名软链, 而 install.sh 的 \cp 会穿透软链改写其目标(软链本身留存),
        # 若记成 LINK 则 %preun 会无条件 rm -f, 误删系统软链;
        # 本包自己创建的软链只有 /bin/storcli, 在循环外单独处理
        if [[ -f "${bin_path}" && ! -L "${bin_path}" ]] &&
            files_identical "${bin_path}" "${candidate}"; then
            echo "FILE:${bin_path}" >>"${MANIFEST_FILE}"
        fi
    done
    # packages/install.sh 额外创建的别名软链 /bin/storcli -> /bin/storcli64
    if [[ -L /bin/storcli && "$(readlink /bin/storcli)" == "/bin/storcli64" ]]; then
        echo "LINK:/bin/storcli" >>"${MANIFEST_FILE}"
    fi
    LOGINFO "Deployment manifest: ${MANIFEST_FILE} ($(wc -l <"${MANIFEST_FILE}") entries)"
}

##################################################
# 注入/刷新 /home/tsc/tsc_profile 中的 TSC_TOOLS 块
# 幂等: 先摘除旧块再插入, 升级或重复安装不会叠加
##################################################
inject_profile() {
    if [[ ! -s "${DEST_TSC_PROFILE}" ]]; then
        \cp "${SOURCE_TSC_PROFILE}" "${DEST_TSC_PROFILE}"
        LOGSUCCESS "Created ${DEST_TSC_PROFILE}"
        return 0
    fi
    sed -i "/# TSC_TOOLS: START/,/# TSC_TOOLS: END/d" "${DEST_TSC_PROFILE}"
    if [[ ! -s "${DEST_TSC_PROFILE}" ]]; then
        \cp "${SOURCE_TSC_PROFILE}" "${DEST_TSC_PROFILE}"
    else
        sed -i "1r ${SOURCE_TSC_PROFILE}" "${DEST_TSC_PROFILE}"
    fi
    LOGSUCCESS "Refreshed TSC_TOOLS block in ${DEST_TSC_PROFILE}"
}

##################################################
# 主流程
##################################################
LOGINFO "tsc_tools %post start (arg=\$1:${1:-unset})"

# 清空部署清单: 随后 packages/install.sh 追加 VIMRC_BACKUP, record_manifest 追加 FILE/LINK
: >"${MANIFEST_FILE}"

# 1. 部署二进制工具 / RAID CLI / vimrc (沿用 packages/install.sh 的探测逻辑;
#    vimrc 已存在且不同时会先备份再覆盖, 备份路径由 install.sh 记入清单)
while IFS='=' read -r key value; do
    system_info["$key"]="$value"
done < <(detect_system_info)

if [[ -x "${TSC_TOOLS_DIR}/packages/install.sh" ]]; then
    bash "${TSC_TOOLS_DIR}/packages/install.sh" "${system_info[machine_type]:-vm}" ||
        LOGWARNING "packages/install.sh exited non-zero, some bundled tools may be unavailable"
else
    LOGWARNING "${TSC_TOOLS_DIR}/packages/install.sh not found, skip binary deployment"
fi

# 2. 记录部署清单
record_manifest

# 3. profile 注入 + profile.d 目录
mkdir -p "${TSC_PROFILE_D_DIR}"
inject_profile

# 4. 日志目录 (不属于包内容, 卸载时保留运行期日志)
mkdir -p "${LOG_DIR}"
chmod 0755 "${LOG_DIR}"

echo -e '\033[1;33m'
echo "--------------------
usage:
    source /home/tsc/tsc_profile
    tsc
--------------------"
echo -e '\033[0;39m'
"${TSC_TOOLS_DIR}/tsc" || true

LOGSUCCESS "tsc_tools %post done"
exit 0
