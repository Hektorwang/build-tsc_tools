#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
# =============================================================================
# tests/test_card_sas3.sh — sas3 适配器测试 (sas3ircu, DESIGN §8 步骤3)
# fixture: list.txt + display_healthy.txt(v1 迁移; Volume State/PHY 归属)
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"

MODULE_LIB="${MODULE_DIR}/lib"
export TSC_SCHEMA_DIR="${MODULE_LIB}/schema"
TSC_DEGRADED_FILE="$(mktemp /tmp/tsc_v2_sas3_test.XXXXXX)"
declare -ga TSC_DEGRADED=()

source "${MODULE_LIB}/raid/cards/lib.sh"
source "${MODULE_LIB}/raid/extract.sh"
source "${MODULE_LIB}/jsonio.sh"
source "${MODULE_LIB}/raid/detector.sh"
source "${MODULE_LIB}/raid/cards/sas3.sh"

reset_degraded() {
    TSC_DEGRADED=()
    : >"${TSC_DEGRADED_FILE}"
}

trap 'rm -f "${TSC_DEGRADED_FILE}"' EXIT

mock_sas3ircu() {
    mock_cmd_switch sas3ircu \
        "${FIXTURE_DIR}/raid/sas3/list.txt" \
        "display=${FIXTURE_DIR}/raid/sas3/display_healthy.txt"
}

test_sas3_detect() {
    reset_degraded
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/mpt3sas.txt"
    mock_sas3ircu
    card_sas3_detect
    assert_eq "$?" "0" "lsmod mpt3sas + 工具在位 → 在位"

    reset_degraded
    mock_cmd lsmod "${FIXTURE_DIR}/lsmod/no_raid.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"
    mock_sas3ircu
    card_sas3_detect
    assert_eq "$?" "1" "无模块无 PCI 证据 → 不在位"
}

test_sas3_parse_full_model() {
    reset_degraded
    mock_sas3ircu

    local out
    out="$(card_sas3_parse)"
    assert_json_field "${out}" '.card' "sas3" "card 名"
    assert_json_field "${out}" '.controller.name' "SAS3008" "Controller type"
    assert_json_field "${out}" '.controller.vd_count' "1" "vd 计数"
    assert_json_field "${out}" '.controller.pd_count' "2" "pd 计数"
    assert_json_field "${out}" '.sections_failed | length' "0" "全节成功"

    # IR Volume: Volume State "Okay (OKY)" → online
    assert_json_field "${out}" '.vds[0].vd' "1" "IR volume 号"
    assert_json_field "${out}" '.vds[0].state_norm' "online" "Okay → online"
    assert_json_field "${out}" '.vds[0].size_gb' "3726" "3815447MB → 3726"
    assert_json_field "${out}" '.vds[0].pd_slots | length' "2" "PHY 归属 2 盘"

    # PD: State "Ready (RDY)" → online; GUID 作 wwn; PHY 映射 vd
    assert_json_field "${out}" '.pds[0].enc' "1" "enc"
    assert_json_field "${out}" '.pds[0].slot' "0" "slot"
    assert_json_field "${out}" '.pds[0].state_norm' "online" "Ready → online"
    assert_json_field "${out}" '.pds[0].size_gb' "3726" "pd size_gb"
    assert_json_field "${out}" '.pds[0].model' "ST4000NM0023" "Model Number"
    assert_json_field "${out}" '.pds[0].serial' "Z1Z3ABCD" "Serial No"
    assert_json_field "${out}" '.pds[0].wwn' "5000c5007e123456" "GUID 作 wwn"
    assert_json_field "${out}" '.pds[0].interface' "SAS" "Protocol"
    assert_json_field "${out}" '.pds[0].vd' "1" "PHY E/S → vd 归属"
}

test_sas3_extract() {
    reset_degraded
    mock_sas3ircu

    local full topo health
    full="$(card_sas3_parse)"

    topo="$(extract_topology <<<"${full}")"
    assert_json_field "${topo}" '.storage | length' "2" "storage 2 条目"
    assert_json_field "${topo}" '.raid_controllers[0].name' "SAS3008" "控制器入投影"

    health="$(extract_health <<<"${full}")"
    assert_eq "$(wc -l <<<"${health}" | tr -d ' ')" "4" "2pd+1vd+1ctl = 4 行"
    assert_json_field "$(tail -n1 <<<"${health}")" '.kind' "ctl" "末行为 ctl"
    assert_json_field "$(tail -n1 <<<"${health}")" '.health_norm' "unknown" "sas3ircu 无控制器健康字段"
}

run_test "sas3 detect" test_sas3_detect
run_test "sas3 parse 全量模型" test_sas3_parse_full_model
run_test "sas3 提取器投影" test_sas3_extract

print_summary
