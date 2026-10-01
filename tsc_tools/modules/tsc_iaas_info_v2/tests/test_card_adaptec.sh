#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
# =============================================================================
# tests/test_card_adaptec.sh — adaptec 适配器测试 (arcconf, DESIGN §8 步骤5)
# fixture: getconfig_1_combined.txt = 控制器+LD+PD 同一次 GETCONFIG 输出(拼接)
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"

MODULE_LIB="${MODULE_DIR}/lib"
export TSC_SCHEMA_DIR="${MODULE_LIB}/schema"
TSC_DEGRADED_FILE="$(mktemp /tmp/tsc_v2_adaptec_test.XXXXXX)"
declare -ga TSC_DEGRADED=()

source "${MODULE_LIB}/raid/cards/lib.sh"
source "${MODULE_LIB}/raid/extract.sh"
source "${MODULE_LIB}/jsonio.sh"
source "${MODULE_LIB}/raid/detector.sh"
source "${MODULE_LIB}/raid/cards/adaptec.sh"

reset_degraded() {
    TSC_DEGRADED=()
    : >"${TSC_DEGRADED_FILE}"
}

trap 'rm -f "${TSC_DEGRADED_FILE}"' EXIT

test_adaptec_detect_and_parse() {
    reset_degraded
    mock_cmd lspci "${FIXTURE_DIR}/lspci/adaptec.txt"
    mock_cmd arcconf "${FIXTURE_DIR}/raid/adaptec/getconfig_1_combined.txt"

    card_adaptec_detect
    assert_eq "$?" "0" "lspci Adaptec + 工具在位 → 在位"

    local out
    out="$(card_adaptec_parse)"
    assert_json_field "${out}" '.card' "adaptec" "card 名"
    assert_json_field "${out}" '.controller.name' "Adaptec 7805" "Controller Model"
    assert_json_field "${out}" '.controller.health' "Optimal" "Status 原文"
    assert_json_field "${out}" '.controller.health_norm' "online" "归一"
    assert_json_field "${out}" '.sections_failed | length' "0" "全节成功"

    # LD: "Status of Logical Device : Optimal", RAID level 5
    assert_json_field "${out}" '.vds[0].vd' "0" "LD 号"
    assert_json_field "${out}" '.vds[0].state_norm' "online" "Optimal → online"
    assert_json_field "${out}" '.vds[0].raid_level' "5" "RAID level"
    assert_json_field "${out}" '.vds[0].size_gb' "2146" "2197265MB → 2146"

    # PD: enc/slot 取自 Reported Channel,Device; 千分位逗号剥离
    assert_json_field "${out}" '.pds | length' "3" "3 个 Device 块"
    assert_json_field "${out}" '.pds[0].enc' "0" "channel 作 enc"
    assert_json_field "${out}" '.pds[0].slot' "0" "device 作 slot"
    assert_json_field "${out}" '.pds[0].state_norm' "online" "Online,SpunUp → online"
    assert_json_field "${out}" '.pds[0].model' "ST900MM0168" "Model"
    assert_json_field "${out}" '.pds[0].serial' "W1234567" "Serial number"
    assert_json_field "${out}" '.pds[0].size_gb' "837" "857,375MB → 837(逗号剥离)"
}

run_test "adaptec detect+parse" test_adaptec_detect_and_parse

print_summary
