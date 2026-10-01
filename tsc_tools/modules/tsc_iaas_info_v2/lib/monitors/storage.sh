#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/monitors/storage.sh — 存储挂载点运行时监控 (块B, v1 平移)
# =============================================================================
# 被 source 使用，不可直接执行。
# `--storage_threshold` 的真实语义 = 本监控的容量/inode 使用率阈值
# (DESIGN §2.1: 阈值语义冻结)。
#
# 提供:
#   _test_writability <mount_point>  (内部)
#   monitor_mountpoints
#
# TODO 15 修复(本轮): v1 用 findmnt 普通输出 + awk 按空格切列, 含空格的
# 挂载点被切坏而静默跳过; 改用 `findmnt -r`(raw: 空格转义 \x20)后先按列
# 切分再反转义, 字段边界与字段内容解耦。
# =============================================================================

# -----------------------------------------------------------------------------
# _test_writability <mount_point>
# mktemp 实写探测(v1 语义保留): mount options 含 rw 不代表实际可写。
# -----------------------------------------------------------------------------
_test_writability() {
    local mount_point="$1"
    local temp_file

    temp_file="$(mktemp "${mount_point}/test_rw_tsc_XXXXXX" 2>/dev/null)" || return 1
    unlink "${temp_file}" &>/dev/null
    return 0
}

# _unescape_findmnt <field> — findmnt -r 的 \xNN 转义还原(\x20 空格; 其余罕见)
_unescape_findmnt() {
    printf '%b' "${1//\\x/\\x}"
}

# -----------------------------------------------------------------------------
# monitor_mountpoints
# 遍历已挂载的常见文件系统, 每挂载点采集:
#   容量(df)/inode(df -i)/可写性(options 含 rw 且 mktemp 实写成功)
# 输出: JSON 数组, 元素:
#   {target, source, filesystem,
#    size: {total, used, used_percent, unit:"G"},
#    inodes: {total, used, used_percent},
#    writable: true|false}
# -----------------------------------------------------------------------------
monitor_mountpoints() {
    local json_array="[]"
    local mount_info=()

    local -a FILESYSTEMS=(ext2 ext3 ext4 btrfs xfs vfat ntfs jfs reiserfs zfs)
    local FS_TYPES
    FS_TYPES="$(IFS=,; echo "${FILESYSTEMS[*]}")"

    # -r: raw 输出, 字段内空格转义为 \x20(EL7 util-linux 无 --json, raw 为兼容解法)
    # -n 无表头; -l 列表; -D 去重复; -t 限定文件系统
    mapfile -t mount_info < <(
        findmnt -r -n -o TARGET,SOURCE,FSTYPE,OPTIONS -l -D -t "${FS_TYPES}" 2>/dev/null
    )

    local line
    for line in "${mount_info[@]}"; do
        # 先按空白切列(转义保证了字段内无真实空格), 再逐字段反转义
        local mount_point source_device fstype options
        mount_point="$(_unescape_findmnt "$(awk '{print $1}' <<<"${line}")")"
        source_device="$(_unescape_findmnt "$(awk '{print $2}' <<<"${line}")")"
        fstype="$(_unescape_findmnt "$(awk '{print $3}' <<<"${line}")")"
        options="$(_unescape_findmnt "$(awk '{print $4}' <<<"${line}")")"

        [[ ! -d "${mount_point}" ]] && continue

        local df_size_output size_total_bytes size_used_bytes
        df_size_output="$(df -B1 --portability "${mount_point}" 2>/dev/null || echo "0 0")"
        size_total_bytes="$(tail -n 1 <<<"${df_size_output}" | awk '{print $2}')"
        size_used_bytes="$(tail -n 1 <<<"${df_size_output}" | awk '{print $3}')"

        local df_inode_output inode_total inode_used
        df_inode_output="$(df -i --portability "${mount_point}" 2>/dev/null || echo "0 0")"
        inode_total="$(tail -n 1 <<<"${df_inode_output}" | awk '{print $2}')"
        inode_used="$(tail -n 1 <<<"${df_inode_output}" | awk '{print $3}')"

        local size_total_gb=0 size_used_gb=0 size_used_percent=0 inode_used_percent=0
        if [[ "${size_total_bytes}" -gt 0 ]] 2>/dev/null; then
            size_total_gb="$(awk "BEGIN {printf \"%.2f\", ${size_total_bytes} / (1024^3)}")"
            size_used_gb="$(awk "BEGIN {printf \"%.2f\", ${size_used_bytes} / (1024^3)}")"
            size_used_percent="$(awk "BEGIN {printf \"%.2f\", (${size_used_bytes} / ${size_total_bytes}) * 100}")"
        fi
        if [[ "${inode_total}" -gt 0 ]] 2>/dev/null; then
            inode_used_percent="$(awk "BEGIN {printf \"%.2f\", (${inode_used} / ${inode_total}) * 100}")"
        fi

        local writable=false
        if [[ "${options}" =~ rw ]]; then
            if _test_writability "${mount_point}"; then
                writable=true
            fi
        fi

        json_array="$(jq -c \
            --arg target "${mount_point}" \
            --arg source "${source_device}" \
            --arg fs "${fstype}" \
            --argjson size_total "${size_total_gb}" \
            --argjson size_used "${size_used_gb}" \
            --argjson inode_total "${inode_total}" \
            --argjson inode_used "${inode_used}" \
            --argjson size_used_percent "${size_used_percent}" \
            --argjson inode_used_percent "${inode_used_percent}" \
            --argjson rw "${writable}" \
            '. + [{
                target: $target,
                source: $source,
                filesystem: $fs,
                size: {total: $size_total, used: $size_used,
                       used_percent: $size_used_percent, unit: "G"},
                inodes: {total: $inode_total, used: $inode_used,
                         used_percent: $inode_used_percent},
                writable: $rw
            }]' <<<"${json_array}")"
    done
    printf '%s\n' "${json_array}"
}
