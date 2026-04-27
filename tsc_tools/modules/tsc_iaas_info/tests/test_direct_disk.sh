#!/usr/bin/env bash
# =============================================================================
# tests/test_direct_disk.sh — 直通盘判断逻辑测试
# =============================================================================
# 测试 lib/collectors/storage.sh 中的 _is_direct_disk() 函数。
#
# 测试场景:
#   1. 虚拟磁盘（Virtual disk 关键字）→ 视为直通盘
#   2. VMware 虚拟磁盘 → 视为直通盘
#   3. RAID 厂商盘（LSI vendor）→ 不是直通盘
#   4. RAID 厂商盘（DELL vendor）→ 不是直通盘
#   5. RAID 厂商盘（HP vendor）→ 不是直通盘
#   6. RAID 厂商盘（AVAGO vendor）→ 不是直通盘
#   7. RAID 逻辑卷（model 含 LOGICAL）→ 不是直通盘
#   8. 真实直通盘（ATA/SATA，无 RAID 关键字）→ 是直通盘
#   9. 混合场景：fixture 中的 LSI 逻辑卷 → 不是直通盘
#  10. 混合场景：fixture 中的 SATA 直通盘 → 是直通盘
#  11. 混合场景：fixture 中的 direct_only.txt 所有盘 → 均是直通盘
#  12. 混合场景：fixture 中的 raid_logical.txt 所有盘 → 均不是直通盘
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"
source "${MODULE_DIR}/lib/collectors/storage.sh"

# =============================================================================
# 辅助函数：从 lsblk -P 格式行中提取字段值
# =============================================================================
# _parse_lsblk_field <line> <field>
# 从 lsblk -P 格式行（KEY="VALUE" ...）中提取指定字段的值
_parse_lsblk_field() {
    local line="$1"
    local field="$2"
    echo "${line}" | grep -oP "${field}=\"\K[^\"]*"
}

# =============================================================================
# 场景1: 虚拟磁盘（lsblk_line 含 "Virtual disk"）→ 视为直通盘
# 条件1 命中：云主机/VMware 环境下的虚拟磁盘按直通盘处理
# =============================================================================
test_virtual_disk_is_direct() {
    local lsblk_line='NAME="vda" MODEL="Virtual disk" SERIAL="" SIZE="100G" TYPE="disk" VENDOR="0x1af4" TRAN="virtio" WWN=""'
    local name="vda"
    local vendor="0x1af4"
    local model="Virtual disk"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "0" "Virtual disk 应被视为直通盘（返回 0）"
}

# =============================================================================
# 场景2: VMware 虚拟磁盘（lsblk_line 含 "VMware"）→ 视为直通盘
# 条件1 命中：VMware 环境下的虚拟磁盘按直通盘处理
# =============================================================================
test_vmware_disk_is_direct() {
    local lsblk_line='NAME="sda" MODEL="VMware Virtual S" SERIAL="" SIZE="50G" TYPE="disk" VENDOR="VMware  " TRAN="spi" WWN=""'
    local name="sda"
    local vendor="VMware  "
    local model="VMware Virtual S"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "0" "VMware 虚拟磁盘应被视为直通盘（返回 0）"
}

# =============================================================================
# 场景3: LSI 厂商盘 → 不是直通盘
# 条件2 命中：LSI 是 RAID 卡厂商，其设备通常是 RAID 逻辑卷
# =============================================================================
test_lsi_vendor_not_direct() {
    local lsblk_line='NAME="sda" MODEL="LOGICAL VOLUME  " SERIAL="" SIZE="10.9T" TYPE="disk" VENDOR="LSI     " TRAN="" WWN=""'
    local name="sda"
    local vendor="LSI     "
    local model="LOGICAL VOLUME  "

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "1" "LSI 厂商盘不应是直通盘（返回 1）"
}

# =============================================================================
# 场景4: DELL 厂商盘 → 不是直通盘
# 条件2 命中：DELL 是常见 RAID 卡厂商
# =============================================================================
test_dell_vendor_not_direct() {
    local lsblk_line='NAME="sda" MODEL="PERC H730P" SERIAL="" SIZE="5T" TYPE="disk" VENDOR="DELL    " TRAN="" WWN=""'
    local name="sda"
    local vendor="DELL    "
    local model="PERC H730P"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "1" "DELL 厂商盘不应是直通盘（返回 1）"
}

# =============================================================================
# 场景5: HP 厂商盘 → 不是直通盘
# 条件2 命中：HP 是常见 RAID 卡厂商
# =============================================================================
test_hp_vendor_not_direct() {
    local lsblk_line='NAME="sda" MODEL="LOGICAL VOLUME" SERIAL="" SIZE="2T" TYPE="disk" VENDOR="HP      " TRAN="" WWN=""'
    local name="sda"
    local vendor="HP      "
    local model="LOGICAL VOLUME"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "1" "HP 厂商盘不应是直通盘（返回 1）"
}

# =============================================================================
# 场景6: AVAGO 厂商盘 → 不是直通盘
# 条件2 命中：AVAGO（Broadcom）是常见 RAID 卡厂商
# =============================================================================
test_avago_vendor_not_direct() {
    local lsblk_line='NAME="sda" MODEL="MR9361-8i" SERIAL="" SIZE="8T" TYPE="disk" VENDOR="AVAGO   " TRAN="" WWN=""'
    local name="sda"
    local vendor="AVAGO   "
    local model="MR9361-8i"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "1" "AVAGO 厂商盘不应是直通盘（返回 1）"
}

# =============================================================================
# 场景7: 型号含 LOGICAL（非 RAID 厂商）→ 不是直通盘
# 条件3 命中：型号含 "LOGICAL" 表示 RAID 控制器暴露的逻辑卷
# =============================================================================
test_logical_model_not_direct() {
    local lsblk_line='NAME="sda" MODEL="LOGICAL VOLUME" SERIAL="" SIZE="5T" TYPE="disk" VENDOR="UNKNOWN " TRAN="" WWN=""'
    local name="sda"
    local vendor="UNKNOWN "
    local model="LOGICAL VOLUME"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "1" "型号含 LOGICAL 的设备不应是直通盘（返回 1）"
}

# =============================================================================
# 场景8: 真实直通盘（ATA/SATA，无 RAID 关键字）→ 是直通盘
# 条件1-3 均不命中，条件4 因 readlink 返回空而跳过 → 默认返回 0
# 注意：测试环境中 /sys/block/sda 不存在，readlink 返回空，条件4 被跳过
# =============================================================================
test_real_sata_disk_is_direct() {
    local lsblk_line='NAME="sda" MODEL="SAMSUNG MZ7LH960" SERIAL="S3EVNX0K123456" SIZE="894.3G" TYPE="disk" VENDOR="ATA     " TRAN="sata" WWN="0x5002538e40a1b2c3"'
    local name="nonexistent_test_disk_xyz"  # 不存在的设备，readlink 返回空，跳过条件4
    local vendor="ATA     "
    local model="SAMSUNG MZ7LH960"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "0" "真实 SATA 直通盘应被识别为直通盘（返回 0）"
}

# =============================================================================
# 场景9: 混合场景 - 从 mixed.txt fixture 读取 LSI 逻辑卷行 → 不是直通盘
# =============================================================================
test_mixed_fixture_lsi_not_direct() {
    local fixture_file="${FIXTURE_DIR}/lsblk/mixed.txt"
    # 取第一行：LSI 逻辑卷
    local lsblk_line
    lsblk_line="$(head -n1 "${fixture_file}")"

    local name vendor model
    name="$(_parse_lsblk_field "${lsblk_line}" "NAME")"
    vendor="$(_parse_lsblk_field "${lsblk_line}" "VENDOR")"
    model="$(_parse_lsblk_field "${lsblk_line}" "MODEL")"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "1" "mixed.txt 中的 LSI 逻辑卷不应是直通盘（返回 1）"
}

# =============================================================================
# 场景10: 混合场景 - 从 mixed.txt fixture 读取 SATA 直通盘行 → 是直通盘
# =============================================================================
test_mixed_fixture_sata_is_direct() {
    local fixture_file="${FIXTURE_DIR}/lsblk/mixed.txt"
    # 取第二行：SATA 直通盘
    local lsblk_line
    lsblk_line="$(sed -n '2p' "${fixture_file}")"

    local name vendor model
    name="$(_parse_lsblk_field "${lsblk_line}" "NAME")"
    vendor="$(_parse_lsblk_field "${lsblk_line}" "VENDOR")"
    model="$(_parse_lsblk_field "${lsblk_line}" "MODEL")"

    # 使用不存在的设备名，确保 readlink 返回空，跳过条件4
    _is_direct_disk "nonexistent_${name}_test" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "0" "mixed.txt 中的 SATA 直通盘应被识别为直通盘（返回 0）"
}

# =============================================================================
# 场景11: direct_only.txt — 所有盘均应是直通盘
# =============================================================================
test_direct_only_fixture_all_direct() {
    local fixture_file="${FIXTURE_DIR}/lsblk/direct_only.txt"
    local fail_count=0
    local line_num=0

    while IFS= read -r lsblk_line; do
        # 跳过空行
        [[ -z "${lsblk_line}" ]] && continue
        (( line_num++ ))

        local name vendor model
        name="$(_parse_lsblk_field "${lsblk_line}" "NAME")"
        vendor="$(_parse_lsblk_field "${lsblk_line}" "VENDOR")"
        model="$(_parse_lsblk_field "${lsblk_line}" "MODEL")"

        # 使用不存在的设备名，确保 readlink 返回空，跳过条件4
        _is_direct_disk "nonexistent_${name}_test" "${vendor}" "${model}" "${lsblk_line}"
        local ret=$?
        if [[ "${ret}" -ne 0 ]]; then
            echo "  FAIL: direct_only.txt 第 ${line_num} 行（${name}）应是直通盘，但返回 ${ret}"
            (( fail_count++ ))
        fi
    done < "${fixture_file}"

    if [[ ${fail_count} -gt 0 ]]; then
        return 1
    fi
    assert_eq "${line_num}" "2" "direct_only.txt 应包含 2 个磁盘条目"
}

# =============================================================================
# 场景12: raid_logical.txt — 所有盘均不应是直通盘
# =============================================================================
test_raid_logical_fixture_none_direct() {
    local fixture_file="${FIXTURE_DIR}/lsblk/raid_logical.txt"
    local fail_count=0
    local line_num=0

    while IFS= read -r lsblk_line; do
        # 跳过空行
        [[ -z "${lsblk_line}" ]] && continue
        (( line_num++ ))

        local name vendor model
        name="$(_parse_lsblk_field "${lsblk_line}" "NAME")"
        vendor="$(_parse_lsblk_field "${lsblk_line}" "VENDOR")"
        model="$(_parse_lsblk_field "${lsblk_line}" "MODEL")"

        _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
        local ret=$?
        if [[ "${ret}" -ne 1 ]]; then
            echo "  FAIL: raid_logical.txt 第 ${line_num} 行（${name}）不应是直通盘，但返回 ${ret}"
            (( fail_count++ ))
        fi
    done < "${fixture_file}"

    if [[ ${fail_count} -gt 0 ]]; then
        return 1
    fi
    assert_eq "${line_num}" "2" "raid_logical.txt 应包含 2 个磁盘条目"
}

# =============================================================================
# 场景13: 大小写不敏感 - "virtual disk"（小写）→ 视为直通盘
# grep -qiP 使用 -i 忽略大小写
# =============================================================================
test_virtual_disk_case_insensitive() {
    local lsblk_line='NAME="vda" MODEL="virtual disk" SERIAL="" SIZE="100G" TYPE="disk" VENDOR="virtio  " TRAN="virtio" WWN=""'
    local name="vda"
    local vendor="virtio  "
    local model="virtual disk"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "0" "小写 'virtual disk' 也应被视为直通盘（返回 0）"
}

# =============================================================================
# 场景14: 条件1 优先于条件2 — VMware 关键字在 lsblk_line 中，即使 vendor 含 RAID 关键字
# 条件1 短路，直接返回 0（是直通盘）
# =============================================================================
test_vmware_overrides_vendor_check() {
    # lsblk_line 含 VMware，但 vendor 也含 LSI（实际不会出现，测试短路逻辑）
    local lsblk_line='NAME="sda" MODEL="VMware Virtual S" SERIAL="" SIZE="50G" TYPE="disk" VENDOR="LSI     " TRAN="" WWN=""'
    local name="sda"
    local vendor="LSI     "
    local model="VMware Virtual S"

    _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"
    local ret=$?
    assert_eq "${ret}" "0" "VMware 关键字应优先于 LSI vendor 检查（条件1 短路，返回 0）"
}

# =============================================================================
# 主测试入口
# =============================================================================
echo "=== 直通盘判断逻辑测试 ==="
run_test "虚拟磁盘（Virtual disk）→ 直通盘"          test_virtual_disk_is_direct
run_test "VMware 虚拟磁盘 → 直通盘"                   test_vmware_disk_is_direct
run_test "LSI 厂商盘 → 非直通盘"                      test_lsi_vendor_not_direct
run_test "DELL 厂商盘 → 非直通盘"                     test_dell_vendor_not_direct
run_test "HP 厂商盘 → 非直通盘"                       test_hp_vendor_not_direct
run_test "AVAGO 厂商盘 → 非直通盘"                    test_avago_vendor_not_direct
run_test "型号含 LOGICAL → 非直通盘"                  test_logical_model_not_direct
run_test "真实 SATA 直通盘 → 直通盘"                  test_real_sata_disk_is_direct
run_test "mixed.txt: LSI 逻辑卷 → 非直通盘"           test_mixed_fixture_lsi_not_direct
run_test "mixed.txt: SATA 直通盘 → 直通盘"            test_mixed_fixture_sata_is_direct
run_test "direct_only.txt: 所有盘均为直通盘"           test_direct_only_fixture_all_direct
run_test "raid_logical.txt: 所有盘均非直通盘"          test_raid_logical_fixture_none_direct
run_test "Virtual disk 大小写不敏感"                   test_virtual_disk_case_insensitive
run_test "VMware 关键字优先于 vendor 检查（短路逻辑）" test_vmware_overrides_vendor_check
print_summary
