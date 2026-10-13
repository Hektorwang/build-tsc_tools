#!/bin/bash
#
# tsc_tools RPM ---- %preun (卸载前回收)
#
#   $1 == 0  真卸载 (rpm -e):       执行回收
#   $1 >= 1  升级 (rpm -U / 重装):   直接跳过, 由新包的 %post 重建
#
# 回收范围 (按 .installed_manifest, FILE 类型按 hash 校验防误删被改文件):
#   1. /bin 下由本包部署的二进制与软链 (FILE:校验 hash 一致才删, LINK:直接删)
#   2. /home/tsc/tsc_tools/bin  (packages/install.sh 生成, 不属于 rpm 文件清单)
#   3. /root/.vimrc  (manifest 中 FILE 记录, hash 一致才删; 删后还原 VIMRC_BACKUP)
#   4. 本包 drop-in /home/tsc/tsc_profile.d/00-tsc_tools-profile.sh
#      (旧名 01-tsc_tools-profile.sh 一并回收, 见 STALE_DROPIN)
#
# 保留 (不回收):
#   /home/tsc/tsc_profile        公共入口, 其他工具可能仍在用
#   /home/tsc/tsc_profile.d 目录 其他工具的 drop-in 可能还在
#   /var/log/tsc 及运行期日志
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
TSC_PROFILE_D_DIR="${TSC_HOME_DIR}/tsc_profile.d"
MANIFEST_FILE="${TSC_TOOLS_DIR}/.installed_manifest"
DROPIN_FILE="${TSC_PROFILE_D_DIR}/00-tsc_tools-profile.sh"
# 旧命名 (与 tsc_python 同为 01- 前缀时期), 一并回收避免遗留无主文件
STALE_DROPIN="${TSC_PROFILE_D_DIR}/01-tsc_tools-profile.sh"

# $1 为卸载后剩余的本包实例数: 0=真卸载, >=1=升级
if [ "${1:-0}" != "0" ]; then
    echo "tsc_tools: upgrade detected, skip cleanup (handled by new package %post)"
    exit 0
fi

LOG() {
    printf '%s | %-8s | tsc_tools-preun - %s\n' "$(date "+%F %T")" "$1" "$2" >&2
}

LOG "INFO" "cleanup start"

# ---------- 1. 按 manifest 回收 /bin 下本包部署的二进制 ----------
# manifest 每行: FILE:<path>:<sha256> | LINK:<path> | VIMRC_BACKUP:<path>
vimrc_backup=""
if [ -f "${MANIFEST_FILE}" ]; then
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        kind="${entry%%:*}"
        rest="${entry#*:}"

        if [ "${kind}" = "LINK" ]; then
            if [ -L "${rest}" ]; then
                rm -f "${rest}" && LOG "SUCCESS" "removed symlink ${rest}"
            fi
            continue
        fi

        if [ "${kind}" = "VIMRC_BACKUP" ]; then
            vimrc_backup="${rest}"
            continue
        fi

        if [ "${kind}" = "FILE" ]; then
            # FILE:<path>:<sha256>
            path="${rest%%:*}"
            sum="${rest#*:}"
            [ -f "${path}" ] || continue
            if [ -n "${sum}" ]; then
                cur_sum="$(sha256sum <"${path}" 2>/dev/null | awk '{print $1}')"
                if [ "${cur_sum}" = "${sum}" ]; then
                    rm -f "${path}" && LOG "SUCCESS" "removed ${path}"
                else
                    LOG "WARNING" "${path} modified (hash mismatch), kept"
                fi
            else
                LOG "WARNING" "${path} has no recorded hash, skip"
            fi
        fi
    done <"${MANIFEST_FILE}"
else
    LOG "WARNING" "manifest ${MANIFEST_FILE} not found, skip /bin cleanup"
fi

# ---------- 2. 回收 packages/install.sh 生成的 bin 目录 ----------
if [ -d "${TSC_TOOLS_DIR}/bin" ]; then
    rm -rf "${TSC_TOOLS_DIR}/bin" && LOG "SUCCESS" "removed ${TSC_TOOLS_DIR}/bin"
fi

# ---------- 3. 还原 /root/.vimrc 备份 (若刚才删了本包 vimrc 且有备份) ----------
# 仅当 /root/.vimrc 已被第1步删除 (hash 一致) 且存在安装时备份时还原;
# 用户改过 vimrc (hash 不一致, 未删) 则不还原, 保留用户版本
if [ -n "${vimrc_backup}" ] && [ -f "${vimrc_backup}" ] && [ ! -f /root/.vimrc ]; then
    mv -f "${vimrc_backup}" /root/.vimrc &&
        LOG "SUCCESS" "restored ${vimrc_backup} -> /root/.vimrc"
fi

# ---------- 4. 删除本包 drop-in (公共入口与 tsc_profile.d 目录保留) ----------
for _dropin in "${DROPIN_FILE}" "${STALE_DROPIN}"; do
    if [ -f "${_dropin}" ]; then
        rm -f "${_dropin}" && LOG "SUCCESS" "removed drop-in ${_dropin}"
    fi
done

rm -f "${MANIFEST_FILE}"

LOG "INFO" "cleanup done (tsc_profile, tsc_profile.d, /var/log/tsc are kept)"
exit 0
