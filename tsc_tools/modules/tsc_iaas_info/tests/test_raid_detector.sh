#!/usr/bin/env bash
# tests/test_raid_detector.sh — RAID 类型检测逻辑测试

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"
source "${MODULE_DIR}/lib/raid/detector.sh"

# 使用一个不含真实 RAID 工具的临时目录，避免 RAID_BIN 被系统工具填充
_TEST_WORK_DIR="$(mktemp -d /tmp/tsc_test_work.XXXXXX)"
trap 'rm -rf "${_TEST_WORK_DIR}"' EXIT

# -----------------------------------------------------------------------------
# test_lsi_detection
# 场景: lspci 输出含 LSI/MegaRAID 关键字，lsmod 无 RAID 模块
# 期望: RAID_TYPE=lsi
# -----------------------------------------------------------------------------
test_lsi_detection() {
    mock_cmd lspci "${FIXTURE_DIR}/lspci/lsi_megraid.txt"
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/no_raid.txt"

    RAID_TYPE=""
    RAID_BIN=""
    WORK_DIR="${_TEST_WORK_DIR}" raid_detect

    assert_eq "${RAID_TYPE}" "lsi" "RAID_TYPE 应为 lsi"
}

# -----------------------------------------------------------------------------
# test_adaptec_detection
# 场景: lspci 输出含 Adaptec 关键字，lsmod 无 RAID 模块
# 期望: RAID_TYPE=adaptec
# -----------------------------------------------------------------------------
test_adaptec_detection() {
    mock_cmd lspci "${FIXTURE_DIR}/lspci/adaptec.txt"
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/no_raid.txt"

    RAID_TYPE=""
    RAID_BIN=""
    WORK_DIR="${_TEST_WORK_DIR}" raid_detect

    assert_eq "${RAID_TYPE}" "adaptec" "RAID_TYPE 应为 adaptec"
}

# -----------------------------------------------------------------------------
# test_sas3_lspci_detection
# 场景: lspci 输出含 SAS3008，lsmod 无 RAID 模块
# 期望: RAID_TYPE=mpt3sas
# -----------------------------------------------------------------------------
test_sas3_lspci_detection() {
    mock_cmd lspci "${FIXTURE_DIR}/lspci/sas3008.txt"
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/no_raid.txt"

    RAID_TYPE=""
    RAID_BIN=""
    WORK_DIR="${_TEST_WORK_DIR}" raid_detect

    assert_eq "${RAID_TYPE}" "mpt3sas" "RAID_TYPE 应为 mpt3sas（通过 lspci SAS3008）"
}

# -----------------------------------------------------------------------------
# test_sas3_lsmod_detection
# 场景: lsmod 输出含 mpt3sas 模块，lspci 无 RAID 设备
# 期望: RAID_TYPE=mpt3sas
# -----------------------------------------------------------------------------
test_sas3_lsmod_detection() {
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/mpt3sas.txt"

    RAID_TYPE=""
    RAID_BIN=""
    WORK_DIR="${_TEST_WORK_DIR}" raid_detect

    assert_eq "${RAID_TYPE}" "mpt3sas" "RAID_TYPE 应为 mpt3sas（通过 lsmod mpt3sas）"
}

# -----------------------------------------------------------------------------
# test_sas2_lsmod_detection
# 场景: lsmod 输出含 mpt2sas 模块，lspci 无 RAID 设备
# 期望: RAID_TYPE=mpt2sas
# -----------------------------------------------------------------------------
test_sas2_lsmod_detection() {
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/mpt2sas.txt"

    RAID_TYPE=""
    RAID_BIN=""
    WORK_DIR="${_TEST_WORK_DIR}" raid_detect

    assert_eq "${RAID_TYPE}" "mpt2sas" "RAID_TYPE 应为 mpt2sas（通过 lsmod mpt2sas）"
}

# -----------------------------------------------------------------------------
# test_no_raid_detection
# 场景: lspci 和 lsmod 均无 RAID 相关内容
# 期望: RAID_TYPE=none，RAID_BIN 为空字符串
# -----------------------------------------------------------------------------
test_no_raid_detection() {
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/no_raid.txt"

    RAID_TYPE=""
    RAID_BIN="something"
    WORK_DIR="${_TEST_WORK_DIR}" raid_detect

    assert_eq "${RAID_TYPE}" "none" "RAID_TYPE 应为 none" || return 1
    assert_eq "${RAID_BIN}" "" "RAID_BIN 应为空字符串" || return 1
}

# =============================================================================
echo "=== RAID 类型检测测试 ==="
run_test "LSI/MegaRAID 检测"   test_lsi_detection
run_test "Adaptec 检测"        test_adaptec_detection
run_test "SAS3 (lspci) 检测"   test_sas3_lspci_detection
run_test "SAS3 (lsmod) 检测"   test_sas3_lsmod_detection
run_test "SAS2 (lsmod) 检测"   test_sas2_lsmod_detection
run_test "无 RAID 卡"          test_no_raid_detection
print_summary
