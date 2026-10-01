#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
# =============================================================================
# tests/test_card_lsi.sh — lsi 适配器测试 (storcli, DESIGN §8 步骤2)
# =============================================================================
# fixture: show.txt(storcli show: 控制器数+System Overview 健康)
#          c0_show_all_healthy.txt(/c0 show all 全量, 合成样例——
#          现役机器真实 show all 抓取后应替换, 见 DESIGN §8 步骤2 前置)
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"

MODULE_LIB="${MODULE_DIR}/lib"
export TSC_SCHEMA_DIR="${MODULE_LIB}/schema"
TSC_DEGRADED_FILE="$(mktemp /tmp/tsc_v2_lsi_test_degraded.XXXXXX)"
declare -ga TSC_DEGRADED=()

source "${MODULE_LIB}/raid/cards/lib.sh"
source "${MODULE_LIB}/raid/extract.sh"
source "${MODULE_LIB}/jsonio.sh"
source "${MODULE_LIB}/raid/detector.sh"
source "${MODULE_LIB}/raid/cards/lsi.sh"

reset_degraded() {
    TSC_DEGRADED=()
    : >"${TSC_DEGRADED_FILE}"
}

trap 'rm -f "${TSC_DEGRADED_FILE}"' EXIT

mock_storcli() {
    mock_cmd_switch storcli \
        "${FIXTURE_DIR}/raid/lsi/show.txt" \
        "show all=${FIXTURE_DIR}/raid/lsi/c0_show_all_healthy.txt"
}

test_lsi_detect() {
    reset_degraded
    mock_cmd lspci "${FIXTURE_DIR}/lspci/lsi_megraid.txt"
    mock_storcli
    card_lsi_detect
    assert_eq "$?" "0" "lspci 匹配 + 工具在位 → 在位"

    reset_degraded
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"
    mock_storcli
    card_lsi_detect
    assert_eq "$?" "1" "lspci 无 RAID → 不在位"
}

test_lsi_parse_full_model() {
    reset_degraded
    mock_cmd lspci "${FIXTURE_DIR}/lspci/lsi_megraid.txt"
    mock_storcli

    local out
    out="$(card_lsi_parse)"
    assert_json_field "${out}" '.card' "lsi" "card 名"
    assert_json_field "${out}" '.ctl_no' "0" "控制器号(show all 抓取, 非正则抠====)"
    assert_json_field "${out}" '.controller.name' "AVG-9361-8i" "Basics 节 Model"
    assert_json_field "${out}" '.controller.health' "Opt" "System Overview Hlth 原文"
    assert_json_field "${out}" '.controller.health_norm' "online" "health 归一"
    assert_json_field "${out}" '.controller.vd_count' "1" "vd 计数"
    assert_json_field "${out}" '.controller.pd_count' "2" "pd 计数"
    assert_json_field "${out}" '.sections_failed | length' "0" "全节成功"

    # VD: 0/0 RAID1 Optl 744.687 GB, DG0 归属
    assert_json_field "${out}" '.vds[0].vd' "0" "vd 号取 DG/VD 斜杠后段"
    assert_json_field "${out}" '.vds[0].state_norm' "online" "Optl → online"
    assert_json_field "${out}" '.vds[0].size_gb' "745" "744.687G → 745"
    assert_json_field "${out}" '.vds[0].name' "LogicalDrv_0" "多词列 Name"
    assert_json_field "${out}" '.vds[0].pd_slots | length' "2" "DG 关联 2 盘"

    # PD: 252:0 Onln, show all 的 Serial/WWN 回填
    assert_json_field "${out}" '.pds[0].enc' "252" "EID:Slt 拆 enc"
    assert_json_field "${out}" '.pds[0].slot' "0" "拆 slot"
    assert_json_field "${out}" '.pds[0].state_norm' "online" "Onln → online"
    assert_json_field "${out}" '.pds[0].size_gb' "745" "size_gb"
    assert_json_field "${out}" '.pds[0].model' "ST900MM0168" "多词列 Model"
    assert_json_field "${out}" '.pds[0].serial' "Z1Z3ABCD" "show all Serial 回填"
    assert_json_field "${out}" '.pds[0].wwn' "5000c5007e123456" "show all WWN 回填"
    assert_json_field "${out}" '.pds[0].vd' "0" "DG 关联 vd"
    assert_json_field "${out}" '.pds[0].interface' "SAS" "Intf"
    assert_json_field "${out}" '.pds[1].serial' "Z1Z3EFGH" "第二盘 serial"
}

test_lsi_parse_capture_failed() {
    reset_degraded
    mock_cmd lspci "${FIXTURE_DIR}/lspci/lsi_megraid.txt"
    # show all 抓取失败: 指向不存在文件 → 空输出
    mock_cmd_switch storcli \
        "${FIXTURE_DIR}/raid/lsi/show.txt" \
        "show all=/nonexistent_show_all_fixture.txt"

    local out
    out="$(card_lsi_parse)"
    assert_json_field "${out}" '.controller' "null" "抓取失败 → controller null"
    assert_json_field "${out}" '.sections_failed | contains(["controller"])' "true" "降级含 controller"
    assert_json_field "${out}" '.sections_failed | contains(["pds"])' "true" "降级含 pds"
}

test_lsi_extract_and_build() {
    reset_degraded
    mock_cmd lspci "${FIXTURE_DIR}/lspci/lsi_megraid.txt"
    mock_storcli

    local full topo health
    full="$(card_lsi_parse)"

    topo="$(extract_topology <<<"${full}")"
    assert_json_field "${topo}" '.storage | length' "2" "storage 2 条目"
    assert_json_field "${topo}" '.raid_controllers | length' "1" "控制器 1 条目"

    # 组装层: raid_controllers 条目级模板合并 + type/ctl_no 排序
    local doc
    doc="$(jsonio_build_static '{}' '{"sn":"X"}' '{"contract_no":""}' '{"location":""}' \
        '{"memory":[]}' '{"cpu":{}}' "Unknown" "2.1.2" "[]" "2026-09-30T00:00:00+08:00" "${topo}")"
    assert_json_field "${doc}" '.raid_controllers[0].name' "AVG-9361-8i" "控制器入文档"
    assert_json_field "${doc}" '.raid_controllers[0].health_norm' "online" "health_norm"
    assert_json_field "${doc}" '.storage[0].serial' "Z1Z3ABCD" "serial 入文档"
    assert_json_field "${doc}" '.storage[0].state_norm' "online" "state_norm 入文档"
    assert_valid_json "${doc}" "文档整体合法"

    health="$(extract_health <<<"${full}")"
    # 2 PD + 1 VD + 1 CTL = 4 行
    assert_eq "$(wc -l <<<"${health}" | tr -d ' ')" "4" "健康对象 4 行"
    assert_json_field "$(head -n1 <<<"${health}")" '.kind' "pd" "kind=pd"
}

run_test "lsi detect" test_lsi_detect
run_test "lsi parse 全量模型" test_lsi_parse_full_model
run_test "lsi parse 抓取失败降级" test_lsi_parse_capture_failed
run_test "lsi 提取器+组装层" test_lsi_extract_and_build

print_summary
