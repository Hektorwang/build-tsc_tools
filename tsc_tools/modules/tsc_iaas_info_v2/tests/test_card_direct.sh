#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
# =============================================================================
# tests/test_card_direct.sh — direct 适配器(v0.2 parse 形态)与公共助手测试
# =============================================================================
# 覆盖:
#   cards/lib.sh     — to_gb / col_by_header / state_norm / json_line / strip_state_parens
#   cards/direct.sh  — _is_direct_disk / card_direct_detect / card_direct_parse(全量模型)
#   extract.sh       — extract_topology / extract_health(通用提取器)
#   raid/detector.sh — 注册遍历 / SAS3 互斥 / raid_topology_json / 降级记录
#   jsonio.sh        — degraded 文件背书 / 骨架条目级合并与排序契约(§3.3)
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"

MODULE_LIB="${MODULE_DIR}/lib"
export TSC_SCHEMA_DIR="${MODULE_LIB}/schema"
TSC_DEGRADED_FILE="$(mktemp /tmp/tsc_v2_card_test_degraded.XXXXXX)"
declare -ga TSC_DEGRADED=()

source "${MODULE_LIB}/raid/cards/lib.sh"
source "${MODULE_LIB}/raid/extract.sh"
source "${MODULE_LIB}/jsonio.sh"
source "${MODULE_LIB}/raid/detector.sh"
source "${MODULE_LIB}/raid/cards/direct.sh"
source "${MODULE_LIB}/raid/cards/lsi.sh"

reset_degraded() {
    TSC_DEGRADED=()
    : >"${TSC_DEGRADED_FILE}"
}

trap 'rm -f "${TSC_DEGRADED_FILE}"' EXIT

# =============================================================================
# 1. cards/lib.sh 助手
# =============================================================================
test_to_gb_gb() {
    reset_degraded
    assert_eq "$(to_gb 893.156 G)" "893" "893.156G → 893"
    assert_eq "$(to_gb 894.3 G)" "894" "894.3G → 894(四舍五入)"
    assert_eq "$(to_gb 893.156 GB)" "893" "GB 后缀形式等价"
}

test_to_gb_larger_units() {
    reset_degraded
    assert_eq "$(to_gb 1 T)" "1024" "1T → 1024"
    assert_eq "$(to_gb 2.5 T)" "2560" "2.5T → 2560"
    assert_eq "$(to_gb 2 P)" "2097152" "2P → 2097152"
}

test_to_gb_smaller_units() {
    reset_degraded
    assert_eq "$(to_gb 8388608 MB)" "8192" "8388608M → 8192"
    assert_eq "$(to_gb 1907729 MB)" "1863" "1907729M(sas 盘) → 1863"
    assert_eq "$(to_gb 1048576 K)" "1" "1048576K → 1"
}

test_to_gb_bad_unit() {
    reset_degraded
    if to_gb 3 X >/dev/null 2>&1; then
        assert_eq "rc=0" "rc!=0" "非法单位应返回非零"
    fi
    assert_eq "$(to_gb 3 X 2>/dev/null)" "" "非法单位无 stdout 输出"
}

test_col_by_header() {
    reset_degraded
    local out='
EID:Slt DID State DG Size Intf Med SED PI SeSz Model Sp Type
252:0 4 Onln 0 744.687 GB SAS HDD N N 512B SEAGATE U -'
    assert_eq "$(col_by_header "${out}" 'EID:Slt DID State' EID:Slt State Size)" "1 3 5" "定位列号"
    if col_by_header "${out}" 'EID:Slt DID State' Nope >/dev/null 2>&1; then
        assert_eq "rc=0" "rc!=0" "不存在的列名应返回非零"
    fi
    if col_by_header "${out}" 'PD LIST :' State >/dev/null 2>&1; then
        assert_eq "rc=0" "rc!=0" "找不到表头行应返回非零"
    fi
}

test_state_norm() {
    reset_degraded
    assert_eq "$(state_norm Optimal)" "online" "Optimal → online"
    assert_eq "$(state_norm ONLINE)" "online" "ONLINE → online"
    assert_eq "$(state_norm Okay)" "online" "Okay → online"
    assert_eq "$(state_norm Ready)" "online" "Ready → online"
    assert_eq "$(state_norm Onln)" "online" "storcli 缩写 Onln → online"
    assert_eq "$(state_norm Optl)" "online" "storcli 缩写 Optl → online"
    assert_eq "$(state_norm Rebuilding)" "rebuild" "Rebuilding → rebuild"
    assert_eq "$(state_norm Rbld)" "rebuild" "storcli 缩写 Rbld → rebuild"
    assert_eq "$(state_norm Degraded)" "degraded" "Degraded → degraded"
    assert_eq "$(state_norm Dgrd)" "degraded" "storcli 缩写 Dgrd → degraded"
    assert_eq "$(state_norm Failed)" "failed" "Failed → failed"
    assert_eq "$(state_norm Offline)" "failed" "Offline → failed"
    assert_eq "$(state_norm Online,Spun Up)" "online" "复合状态 Online,Spun Up → online"
    assert_eq "$(state_norm Missing)" "missing" "Missing → missing"
    assert_eq "$(state_norm UBad)" "unknown" "UBad → unknown"
    assert_eq "$(state_norm '')" "unknown" "空串 → unknown"
}

test_strip_state_parens() {
    reset_degraded
    assert_eq "$(strip_state_parens "Ready (RDY)")" "Ready" "去括号注记"
    assert_eq "$(strip_state_parens "Okay (OKY)")" "Okay" "去括号注记 2"
    assert_eq "$(strip_state_parens "Online")" "Online" "无括号原样"
}

test_json_line_compact() {
    reset_degraded
    assert_eq "$(json_line -n '{a: 1, b: "x"}')" '{"a":1,"b":"x"}' "输出为紧凑单行"
}

# =============================================================================
# 2. _is_direct_disk / detect / parse
# =============================================================================
test_is_direct_disk_semantics() {
    reset_degraded
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"

    local virt='NAME="vda" MODEL="Virtual disk" SERIAL="" SIZE="100G" TYPE="disk" VENDOR="0x1af4" TRAN="virtio" WWN=""'
    local lsilog='NAME="sda" MODEL="LOGICAL VOLUME  " SERIAL="" SIZE="10.9T" TYPE="disk" VENDOR="LSI     " TRAN="" WWN=""'
    local sata='NAME="sdb" MODEL="SAMSUNG MZ7LH960" SERIAL="S3EVNX0K1" SIZE="894.3G" TYPE="disk" VENDOR="ATA     " TRAN="sata" WWN=""'

    _is_direct_disk vda "0x1af4" "Virtual disk" "${virt}"
    assert_eq "$?" "0" "Virtual disk → 直通盘"
    _is_direct_disk sda "LSI     " "LOGICAL VOLUME  " "${lsilog}"
    assert_eq "$?" "1" "LSI 逻辑卷 → 非直通盘"
    _is_direct_disk sdb "ATA     " "SAMSUNG MZ7LH960" "${sata}"
    assert_eq "$?" "0" "SATA 物理盘 → 直通盘"
}

test_direct_detect() {
    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/direct_only.txt"
    card_direct_detect
    assert_eq "$?" "0" "存在 TYPE=disk → 在位"

    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/no_disk.txt"
    card_direct_detect
    assert_eq "$?" "1" "无 TYPE=disk → 不在位"
}

test_direct_parse_full_model() {
    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/direct_only.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"

    local out
    out="$(card_direct_parse)"
    assert_json_field "${out}" '.card' "direct" "card 名"
    assert_json_field "${out}" '.controller' "null" "direct 无控制器"
    assert_json_field "${out}" '.vds' "null" "direct 无 vds"
    assert_json_field "${out}" '.pds | length' "2" "2 个直盘条目"
    assert_json_field "${out}" '.sections_failed | length' "0" "无失败节"
    assert_json_field "${out}" '.pds[0].dev' "/dev/sda" "dev 值"
    assert_json_field "${out}" '.pds[0].type' "direct" "type 恒 direct"
    assert_json_field "${out}" '.pds[0].size_gb' "894" "size_gb 数值化"
    assert_json_field "${out}" '.pds[0].state_norm' "online" "可枚举到即 online"
    assert_json_field "${out}" '.pds[0].interface' "sata" "interface 取 TRAN"
}

test_direct_parse_unit_variants() {
    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/small_units.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"
    local out
    out="$(card_direct_parse)"
    assert_json_field "${out}" '.pds | length' "1" "M 单位盘仍产出条目(v1 在此整体失败)"
    assert_json_field "${out}" '.pds[0].size_gb' "1" "966.4M → size_gb 1"

    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/raid_logical.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"
    out="$(card_direct_parse)"
    assert_json_field "${out}" '.pds | length' "0" "纯 RAID 卷机器 → 直盘为空"
}

# =============================================================================
# 3. extract_topology / extract_health
# =============================================================================
test_extract_topology() {
    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/direct_only.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"

    local full out
    full="$(card_direct_parse)"
    out="$(extract_topology <<<"${full}")"
    assert_json_field "${out}" '.storage | length' "2" "storage 条目数"
    assert_json_field "${out}" '.raid_controllers | length' "0" "direct 无控制器条目"
}

test_extract_health_direct() {
    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/direct_only.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"

    local full lines
    full="$(card_direct_parse)"
    mapfile -t lines < <(extract_health <<<"${full}")
    assert_eq "${#lines[@]}" "2" "2 个 pd 健康对象"
    assert_json_field "${lines[0]}" '.kind' "pd" "kind=pd"
    assert_json_field "${lines[0]}" '.card' "direct" "card 透传"
    assert_json_field "${lines[0]}" '.state_norm' "online" "state_norm"
}

# =============================================================================
# 4. detector: 聚合 / SAS3 互斥 / 降级记录
# =============================================================================
test_raid_topology_json() {
    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/reverse_order.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"

    local out doc
    out="$(raid_topology_json)"
    assert_json_field "${out}" '.storage | length' "2" "聚合 storage 数组"
    assert_json_field "${out}" '.raid_controllers | length' "0" "无控制器"

    # §3.3: 适配器透传枚举序, 组装层排序
    doc="$(jsonio_build_static '{}' '{"sn":"X"}' '{"contract_no":""}' '{"location":""}' \
        '{"memory":[]}' '{"cpu":{}}' "Unknown" "2.1.2" "[]" "2026-09-30T00:00:00+08:00" "${out}")"
    assert_json_field "${doc}" '.storage[0].dev' "/dev/sda" "骨架填充后按 dev 排序"
    assert_json_field "${doc}" '.storage[0].ctl_no' "null" "直盘 ctl_no 由骨架/适配器补 null"
}

test_sas3_mutex() {
    reset_degraded
    # 注册表已含 direct(source 时注册); 注册 sas3(假 detect)与 lsi(真 detect 但无工具)
    card_bad_sas3_detect() { return 0; }
    card_sas3_detect() { card_bad_sas3_detect "$@"; }
    card_register sas3
    card_register lsi   # lsi detect 因 storcli 不在位应失败

    raid_detect_cards
    # sas3 在位 → lsi 必须被剔除(direct/sas3 保留)
    local found_lsi=0
    local t
    for t in "${TSC_DETECTED_CARDS[@]}"; do
        [[ "${t}" == "lsi" ]] && found_lsi=1
    done
    assert_eq "${found_lsi}" "0" "SAS3 互斥: lsi 被剔除"

    TSC_CARD_TYPES=("direct")
}

test_parse_failure_degraded() {
    reset_degraded
    mock_cmd lsblk "${FIXTURE_DIR}/lsblk/direct_only.txt"
    mock_cmd lspci "${FIXTURE_DIR}/lspci/no_raid.txt"

    card_bad_detect() { return 0; }
    card_bad_parse() { return 1; }
    card_register bad

    local out
    out="$(raid_topology_json)"
    assert_json_field "${out}" '.storage | length' "2" "坏卡不影响 direct 条目"
    grep -q "card_bad_parse" "${TSC_DEGRADED_FILE}"
    assert_eq "$?" "0" "parse 失败记入降级文件(子 shell 可见)"

    TSC_CARD_TYPES=("direct")
}

test_degraded_sync_merges_file() {
    reset_degraded
    degraded_add "fake_source"
    degraded_sync
    assert_eq "${TSC_DEGRADED[*]}" "fake_source" "degraded_sync 将文件记录合并回数组"
}

run_test "to_gb G/GB 单位" test_to_gb_gb
run_test "to_gb 大单位 T/P" test_to_gb_larger_units
run_test "to_gb 小单位 M/MB/K" test_to_gb_smaller_units
run_test "to_gb 非法单位" test_to_gb_bad_unit
run_test "col_by_header 列定位" test_col_by_header
run_test "state_norm 归一词表" test_state_norm
run_test "strip_state_parens 去括号" test_strip_state_parens
run_test "json_line 紧凑单行" test_json_line_compact
run_test "_is_direct_disk 判定语义" test_is_direct_disk_semantics
run_test "card_direct_detect" test_direct_detect
run_test "card_direct_parse 全量模型" test_direct_parse_full_model
run_test "card_direct_parse 单位变体" test_direct_parse_unit_variants
run_test "extract_topology 投影" test_extract_topology
run_test "extract_health 投影(direct)" test_extract_health_direct
run_test "raid_topology_json 聚合+排序契约" test_raid_topology_json
run_test "SAS3 互斥规则" test_sas3_mutex
run_test "parse 失败降级记录" test_parse_failure_degraded
run_test "degraded_sync 文件合并" test_degraded_sync_merges_file

print_summary
