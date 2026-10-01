#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
# =============================================================================
# tests/test_card_sas2.sh — sas2 适配器测试 (sas2ircu, DESIGN §8 步骤4)
# 补齐 v1 缺失的采集分支(release-note TODO 11)。
# fixture: display_healthy.txt(sas2ircu 用 "Status of volume", 与 sas3 不同名)
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"

MODULE_LIB="${MODULE_DIR}/lib"
export TSC_SCHEMA_DIR="${MODULE_LIB}/schema"
TSC_DEGRADED_FILE="$(mktemp /tmp/tsc_v2_sas2_test.XXXXXX)"
declare -ga TSC_DEGRADED=()

source "${MODULE_LIB}/raid/cards/lib.sh"
source "${MODULE_LIB}/raid/extract.sh"
source "${MODULE_LIB}/jsonio.sh"
source "${MODULE_LIB}/raid/detector.sh"
source "${MODULE_LIB}/raid/cards/sas2.sh"

reset_degraded() {
    TSC_DEGRADED=()
    : >"${TSC_DEGRADED_FILE}"
}

trap 'rm -f "${TSC_DEGRADED_FILE}"' EXIT

test_sas2_detect_and_parse() {
    reset_degraded
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/mpt2sas.txt"
    mock_cmd_switch sas2ircu \
        "${FIXTURE_DIR}/raid/sas2/list.txt" \
        "display=${FIXTURE_DIR}/raid/sas2/display_healthy.txt"

    card_sas2_detect
    assert_eq "$?" "0" "lsmod mpt2sas + 工具在位 → 在位"

    local out
    out="$(card_sas2_parse)"
    assert_json_field "${out}" '.card' "sas2" "card 名"
    assert_json_field "${out}" '.controller.name' "SAS2008" "Controller type"
    assert_json_field "${out}" '.controller.vd_count' "1" "vd 计数"
    assert_json_field "${out}" '.controller.pd_count' "2" "pd 计数"
    assert_json_field "${out}" '.sections_failed | length' "0" "全节成功"

    # sas2ircu 卷状态字段 "Status of volume" → 与 sas3 的 "Volume State" 兼容
    assert_json_field "${out}" '.vds[0].state' "Optimal (OPT)" "状态原文"
    assert_json_field "${out}" '.vds[0].state_norm' "online" "Optimal → online"
    assert_json_field "${out}" '.vds[0].pd_slots | length' "2" "PHY 归属"

    assert_json_field "${out}" '.pds[0].state_norm' "online" "Ready → online"
    assert_json_field "${out}" '.pds[0].size_gb' "1863" "1907729MB → 1863"
    assert_json_field "${out}" '.pds[0].serial' "Z1X2ABCD" "Serial No"
    assert_json_field "${out}" '.pds[0].vd' "1" "PHY 归属映射"
}

run_test "sas2 detect+parse" test_sas2_detect_and_parse

print_summary
