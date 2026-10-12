#!/bin/bash
#
# tsc_tools RPM ---- %preun (卸载前回收)
#
#   $1 == 0  真卸载 (rpm -e):       执行回收
#   $1 >= 1  升级 (rpm -U / 重装):   直接跳过, 由新包的 %post 重建, 避免删掉正在启用的文件
#
# 回收范围:
#   1. /bin 下由本包部署的二进制与别名软链 (按 .installed_manifest + 内容指纹双重校验)
#   2. /home/tsc/tsc_tools/bin  (packages/install.sh 生成, 不属于 rpm 文件清单)
#   3. /root/.vimrc             (内容仍与本包 packages/vimrc 一致才删, 用户改过则保留)
#   4. /home/tsc/tsc_profile 中的 TSC_TOOLS 块 (保留用户自定义内容; 删空后文件也删除)
#
# 保留 (不回收):
#   /var/log/tsc 及运行期日志、/home/tsc/tsc_profile.d 下的自定义片段
#
# 本脚本只使用 POSIX 语法且任何情况下都返回 0: %preun 非零会导致 rpm 拒绝卸载,
# 让机器卡在"卸不掉"的状态比留下几个文件更糟。
##################################################

# shellcheck disable=SC1090,SC1091,SC2034,SC2181
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

TSC_HOME_DIR="/home/tsc"
TSC_TOOLS_DIR="${TSC_HOME_DIR}/tsc_tools"
DEST_TSC_PROFILE="${TSC_HOME_DIR}/tsc_profile"
MANIFEST_FILE="${TSC_TOOLS_DIR}/.installed_manifest"

# $1 为卸载后剩余的本包实例数: 0=真卸载, >=1=升级
if [ "${1:-0}" != "0" ]; then
    echo "tsc_tools: upgrade detected, skip cleanup (handled by new package %post)"
    exit 0
fi

LOG() {
    printf '%s | %-8s | tsc_tools-preun - %s\n' "$(date "+%F %T")" "$1" "$2" >&2
}

# 判断两个文件二进制内容是否一致 (无 sha256sum 时退化为 cmp)
files_identical() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        [ "$(sha256sum <"$1" | awk '{print $1}')" = "$(sha256sum <"$2" | awk '{print $1}')" ]
    else
        cmp -s "$1" "$2"
    fi
}

# 取本包自带二进制路径: packages/<tool>/<tool>-$(arch) 优先于 <tool>-noarch
bundled_binary_for() {
    _tool="$1"
    for _suffix in "$(arch)" "noarch"; do
        _candidate="${TSC_TOOLS_DIR}/packages/${_tool}/${_tool}-${_suffix}"
        if [ -f "${_candidate}" ]; then
            printf '%s' "${_candidate}"
            return 0
        fi
    done
    return 1
}

LOG "INFO" "cleanup start"

# ---------- 1. 回收 /bin 下由本包部署的二进制 ----------
vimrc_backup=""
if [ -f "${MANIFEST_FILE}" ]; then
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        kind="${entry%%:*}"
        path="${entry#*:}"

        if [ "${kind}" = "LINK" ]; then
            if [ -L "${path}" ]; then
                rm -f "${path}" && LOG "SUCCESS" "removed symlink ${path}"
            fi
            continue
        fi

        # 安装时备份的原始 /root/.vimrc, 待第 3 步还原
        if [ "${kind}" = "VIMRC_BACKUP" ]; then
            vimrc_backup="${path}"
            continue
        fi

        tool="$(basename "${path}")"
        candidate="$(bundled_binary_for "${tool}")" || {
            LOG "WARNING" "no bundled source for ${path}, skip"
            continue
        }
        if files_identical "${path}" "${candidate}"; then
            rm -f "${path}" && LOG "SUCCESS" "removed ${path}"
        else
            LOG "WARNING" "${path} differs from bundled binary (replaced by system/user), kept"
        fi
    done <"${MANIFEST_FILE}"
else
    LOG "WARNING" "manifest ${MANIFEST_FILE} not found, skip /bin cleanup"
fi

# ---------- 2. 回收 packages/install.sh 生成的 bin 目录 ----------
if [ -d "${TSC_TOOLS_DIR}/bin" ]; then
    rm -rf "${TSC_TOOLS_DIR}/bin" && LOG "SUCCESS" "removed ${TSC_TOOLS_DIR}/bin"
fi

# ---------- 3. 回收 /root/.vimrc (仅当仍为本包版本) 并还原安装时的备份 ----------
if [ -f /root/.vimrc ]; then
    if files_identical /root/.vimrc "${TSC_TOOLS_DIR}/packages/vimrc"; then
        rm -f /root/.vimrc && LOG "SUCCESS" "removed /root/.vimrc"
        if [ -n "${vimrc_backup}" ] && [ -f "${vimrc_backup}" ]; then
            mv -f "${vimrc_backup}" /root/.vimrc &&
                LOG "SUCCESS" "restored ${vimrc_backup} -> /root/.vimrc"
        fi
    else
        LOG "WARNING" "/root/.vimrc has been modified, kept"
    fi
fi

# ---------- 4. 摘除 /home/tsc/tsc_profile 中的 TSC_TOOLS 块 ----------
if [ -f "${DEST_TSC_PROFILE}" ]; then
    if grep -q '# TSC_TOOLS: START' "${DEST_TSC_PROFILE}" 2>/dev/null; then
        sed -i '/# TSC_TOOLS: START/,/# TSC_TOOLS: END/d' "${DEST_TSC_PROFILE}"
        LOG "SUCCESS" "removed TSC_TOOLS block from ${DEST_TSC_PROFILE}"
        # 摘除后若已无实质内容 (仅剩空行), 连文件一起删除
        if [ -z "$(sed '/^[[:space:]]*$/d' "${DEST_TSC_PROFILE}" 2>/dev/null)" ]; then
            rm -f "${DEST_TSC_PROFILE}" && LOG "SUCCESS" "removed empty ${DEST_TSC_PROFILE}"
        fi
    else
        LOG "WARNING" "no TSC_TOOLS block in ${DEST_TSC_PROFILE}, kept as is"
    fi
fi

rm -f "${MANIFEST_FILE}"

LOG "INFO" "cleanup done (/var/log/tsc and ${TSC_HOME_DIR}/tsc_profile.d are kept)"
exit 0
