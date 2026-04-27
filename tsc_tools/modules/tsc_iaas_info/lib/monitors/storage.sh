#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/monitors/storage.sh — 存储挂载点运行时监控
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 提供函数:
#   _test_writability <mount_point>  （内部辅助函数）
#   monitor_mountpoints()
#
# 支持的文件系统类型: ext2/3/4, btrfs, xfs, vfat, ntfs, jfs, reiserfs, zfs
# =============================================================================

# -----------------------------------------------------------------------------
# _test_writability <mount_point>
#
# 通过创建临时文件测试挂载点是否实际可写（不仅仅是 mount options 中有 rw）。
# 某些挂载点虽然 options 含 rw，但实际可能因磁盘故障等原因无法写入。
#
# 参数:
#   mount_point — 要测试的挂载点路径
#
# 返回:
#   0 — 可写
#   1 — 不可写（mktemp 失败）
# -----------------------------------------------------------------------------
_test_writability() {
    local mount_point="$1"
    local temp_file

    # 尝试在挂载点创建临时文件，文件名前缀 test_rw_tsc 便于识别
    temp_file=$(mktemp "${mount_point}/test_rw_tsc" 2>/dev/null) || return 1

    # 立即删除临时文件，不留痕迹
    unlink "$temp_file" &>/dev/null
    return 0
}

# -----------------------------------------------------------------------------
# monitor_mountpoints
#
# 遍历所有已挂载的常见文件系统，采集每个挂载点的:
#   - 容量使用情况（总量、已用、使用率，单位 GB）
#   - inode 使用情况（总量、已用、使用率）
#   - 可写性（mount options 含 rw 且实际可写）
#
# 输出:
#   JSON 数组，每个元素格式:
#   {
#     target: "挂载点路径",
#     source: "设备路径",
#     filesystem: "文件系统类型",
#     size: {total: GB, used: GB, used_percent: %, unit: "G"},
#     inodes: {total: N, used: N, used_percent: %},
#     writable: true/false
#   }
# -----------------------------------------------------------------------------
monitor_mountpoints() {
    local json_array="[]"
    local mount_info=()

    # 支持的文件系统类型列表
    local -a FILESYSTEMS=(ext2 ext3 ext4 btrfs xfs vfat ntfs jfs reiserfs zfs)
    local FS_TYPES
    # 将数组转为逗号分隔字符串，用于 findmnt -t 参数
    FS_TYPES="$(IFS=,; echo "${FILESYSTEMS[*]}")"

    # findmnt 获取挂载信息
    # -n 不显示表头；-o 指定输出列；-l 列表格式；-D 不显示重复挂载；-t 过滤文件系统类型
    # 注意: EL7 的 findmnt 不支持 -U 参数（不显示 umount 的挂载点），已注释掉
    mapfile -t mount_info < <(
        findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS -l -D -t "${FS_TYPES}"
    )

    local line
    for line in "${mount_info[@]}"; do
        local mount_point source_device fstype options

        # 按列解析 findmnt 输出（空格分隔）
        mount_point="$(echo "$line" | awk '{print $1}')"
        source_device="$(echo "$line" | awk '{print $2}')"
        fstype="$(echo "$line" | awk '{print $3}')"
        options="$(echo "$line" | awk '{print $4}')"

        # 跳过不存在的挂载点目录（防御性检查）
        [[ ! -d "${mount_point}" ]] && continue

        # --- 采集容量信息 ---
        # df -B1 以字节为单位输出，--portability 使用 POSIX 格式（兼容性更好）
        local df_size_output size_total_bytes size_used_bytes
        df_size_output="$(df -B1 --portability "${mount_point}" 2>/dev/null || echo "0 0")"
        # tail -n 1 跳过表头，取数据行；$2=总量，$3=已用
        size_total_bytes="$(echo "${df_size_output}" | tail -n 1 | awk '{print $2}')"
        size_used_bytes="$(echo "${df_size_output}" | tail -n 1 | awk '{print $3}')"

        # --- 采集 inode 信息 ---
        # df -i 显示 inode 使用情况
        local df_inode_output inode_total inode_used
        df_inode_output="$(df -i --portability "${mount_point}" 2>/dev/null || echo "0 0")"
        inode_total="$(echo "${df_inode_output}" | tail -n 1 | awk '{print $2}')"
        inode_used="$(echo "${df_inode_output}" | tail -n 1 | awk '{print $3}')"

        # 字节转 GB，计算使用率（防止除零）
        local size_total_gb=0 size_used_gb=0 size_used_percent=0 inode_used_percent=0
        if [[ "${size_total_bytes}" -gt 0 ]]; then
            size_total_gb="$(awk "BEGIN {printf \"%.2f\", ${size_total_bytes} / (1024^3)}")"
            size_used_gb="$(awk "BEGIN {printf \"%.2f\", ${size_used_bytes} / (1024^3)}")"
            size_used_percent="$(awk "BEGIN {printf \"%.2f\", (${size_used_bytes} / ${size_total_bytes}) * 100}")"
        fi
        if [[ "${inode_total}" -gt 0 ]]; then
            inode_used_percent="$(awk "BEGIN {printf \"%.2f\", (${inode_used} / ${inode_total}) * 100}")"
        fi

        # --- 检测可写性 ---
        # 先检查 mount options 是否含 rw，再实际测试写入
        local writable=false
        if [[ "${options}" =~ rw ]]; then
            if _test_writability "${mount_point}"; then
                writable=true
            fi
        fi

        # 将当前挂载点信息追加到 JSON 数组
        json_array="$(echo "${json_array}" | jq \
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
                size: {
                    total: $size_total,
                    used: $size_used,
                    used_percent: $size_used_percent,
                    unit: "G"
                },
                inodes: {
                    total: $inode_total,
                    used: $inode_used,
                    used_percent: $inode_used_percent
                },
                writable: $rw
            }]')"
    done
    echo "${json_array}"
}
