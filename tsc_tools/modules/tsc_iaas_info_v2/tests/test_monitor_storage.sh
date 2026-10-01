#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
# =============================================================================
# tests/test_monitor_storage.sh — 挂载点监控测试 (块B, v1 平移 + TODO15 修复)
# =============================================================================
# mock findmnt 输出含 \x20 转义的空格挂载点(v1 会静默丢弃, TODO 15);
# writable 经 mktemp 实写(mock 环境下 /tmp 可写 → true)。
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_framework.sh"

MODULE_LIB="${MODULE_DIR}/lib"
TSC_DEGRADED_FILE="$(mktemp /tmp/tsc_v2_mp_test.XXXXXX)"
declare -ga TSC_DEGRADED=()

source "${MODULE_LIB}/monitors/storage.sh"

reset_degraded() {
    TSC_DEGRADED=()
    : >"${TSC_DEGRADED_FILE}"
}

trap 'rm -rf "${TSC_DEGRADED_FILE}" "${_TEST_MP}" "${_MDIR}"' EXIT

_TEST_MP="$(mktemp -d /tmp/tsc_v2_mp_test_mount.XXXXXX)"
mkdir -p "${_TEST_MP}/with space"   # 挂载点目录须真实存在(防御检查)
_MDIR="$(mktemp -d /tmp/tsc_v2_mp_mock.XXXXXX)"
cat > "${_MDIR}/findmnt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${_TEST_MP}/with\\x20space /dev/sda1 ext4 rw,relatime"
EOF
chmod +x "${_MDIR}/findmnt"

test_mountpoint_space_path() {
    reset_degraded
    # PATH 前插 mock 目录
    local old_path="${PATH}"
    export PATH="${_MDIR}:${PATH}"
    local out
    out="$(monitor_mountpoints)"
    export PATH="${old_path}"

    assert_json_field "${out}" '. | length' "1" "含空格挂载点被采集(TODO15 修复)"
    assert_json_field "${out}" '.[0].target' "${_TEST_MP}/with space" "\\x20 反转义正确"
    assert_json_field "${out}" '.[0].filesystem' "ext4" "fstype"
    assert_json_field "${out}" '.[0].writable' "true" "可写探测"
    assert_json_field "${out}" '.[0].size.unit' "G" "容量单位"
}

run_test "挂载点监控含空格路径" test_mountpoint_space_path

print_summary
