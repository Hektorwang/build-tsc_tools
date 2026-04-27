#!/usr/bin/env bash
# =============================================================================
# tests/test_framework.sh — 测试框架公共函数库
# =============================================================================
# 被各测试脚本 source 使用，提供:
#   - mock 机制：用 fixture 文本文件替代真实命令输出
#   - 断言函数：验证测试结果
#   - 测试报告：统计通过/失败数量
#
# 使用方式:
#   source "$(dirname "$0")/test_framework.sh"
#   mock_cmd lspci tests/fixtures/lspci/lsi_megraid.txt
#   run_test "LSI RAID 检测" test_lsi_detection
# =============================================================================

# 测试统计
_TEST_PASS=0
_TEST_FAIL=0
_TEST_ERRORS=()

# fixture 根目录（相对于模块根目录）
FIXTURE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fixtures"

# -----------------------------------------------------------------------------
# mock_cmd <cmd_name> <fixture_file>
#
# 将指定命令重定向到 fixture 文件输出，在当前 shell 环境中生效。
# 原理：在 PATH 最前面插入一个临时目录，其中放置同名的 wrapper 脚本。
#
# 参数:
#   cmd_name     — 要 mock 的命令名，例如 lspci、lsmod、lsblk
#   fixture_file — fixture 文本文件路径，命令执行时输出此文件内容
#
# 示例:
#   mock_cmd lspci "${FIXTURE_DIR}/lspci/lsi_megraid.txt"
#   mock_cmd lsmod "${FIXTURE_DIR}/lsmod/no_raid.txt"
# -----------------------------------------------------------------------------
mock_cmd() {
    local cmd_name="$1"
    local fixture_file="$2"

    # 创建临时 mock 目录（每次测试共用同一个目录）
    if [[ -z "${_MOCK_DIR:-}" ]]; then
        _MOCK_DIR="$(mktemp -d /tmp/tsc_test_mock.XXXXXX)"
        # 注册清理函数
        trap '_cleanup_mocks' EXIT
    fi

    # 写入 wrapper 脚本：执行时输出 fixture 文件内容
    cat > "${_MOCK_DIR}/${cmd_name}" <<EOF
#!/usr/bin/env bash
cat "${fixture_file}"
EOF
    chmod +x "${_MOCK_DIR}/${cmd_name}"

    # 将 mock 目录插入 PATH 最前面，优先于系统命令
    export PATH="${_MOCK_DIR}:${PATH}"
}

# -----------------------------------------------------------------------------
# mock_cmd_with_args <cmd_name> <fixture_file> [arg_pattern]
#
# 带参数匹配的 mock：根据命令参数返回不同的 fixture 文件。
# 用于模拟 storcli /c0 show、arcconf GETCONFIG 1 PD 等带参数的命令。
#
# 参数:
#   cmd_name     — 要 mock 的命令名
#   fixture_file — 默认 fixture 文件（参数不匹配时使用）
#   arg_pattern  — 可选，参数匹配模式（grep -E 格式）
#
# 示例:
#   mock_cmd_with_args storcli "${FIXTURE_DIR}/raid/lsi/storcli_show.txt"
# -----------------------------------------------------------------------------
mock_cmd_with_args() {
    local cmd_name="$1"
    local fixture_file="$2"

    if [[ -z "${_MOCK_DIR:-}" ]]; then
        _MOCK_DIR="$(mktemp -d /tmp/tsc_test_mock.XXXXXX)"
        trap '_cleanup_mocks' EXIT
    fi

    # wrapper 脚本：忽略所有参数，直接输出 fixture 内容
    cat > "${_MOCK_DIR}/${cmd_name}" <<EOF
#!/usr/bin/env bash
# mock: ${cmd_name} -> ${fixture_file}
cat "${fixture_file}"
EOF
    chmod +x "${_MOCK_DIR}/${cmd_name}"
    export PATH="${_MOCK_DIR}:${PATH}"
}

# -----------------------------------------------------------------------------
# reset_mocks
# 清除所有 mock，恢复真实命令
# -----------------------------------------------------------------------------
reset_mocks() {
    if [[ -n "${_MOCK_DIR:-}" ]]; then
        rm -rf "${_MOCK_DIR}"
        unset _MOCK_DIR
        # 从 PATH 中移除 mock 目录（重新设置 PATH）
        export PATH="$(echo "${PATH}" | tr ':' '\n' | grep -v "tsc_test_mock" | tr '\n' ':' | sed 's/:$//')"
    fi
}

_cleanup_mocks() {
    reset_mocks
}

# -----------------------------------------------------------------------------
# assert_eq <actual> <expected> <message>
# 断言两个字符串相等
# -----------------------------------------------------------------------------
assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="${3:-assertion failed}"

    if [[ "${actual}" == "${expected}" ]]; then
        return 0
    else
        echo "  FAIL: ${message}"
        echo "    expected: ${expected}"
        echo "    actual:   ${actual}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# assert_json_field <json> <jq_path> <expected_value> <message>
# 断言 JSON 中指定路径的值等于期望值
#
# 示例:
#   assert_json_field "${result}" '.cpu.cpu_cnt' '2' "CPU 插槽数应为 2"
# -----------------------------------------------------------------------------
assert_json_field() {
    local json="$1"
    local jq_path="$2"
    local expected="$3"
    local message="${4:-json field assertion}"

    local actual
    actual="$(echo "${json}" | jq -r "${jq_path}" 2>/dev/null || echo "JQ_ERROR")"
    assert_eq "${actual}" "${expected}" "${message}"
}

# -----------------------------------------------------------------------------
# assert_json_has_key <json> <key> <message>
# 断言 JSON 对象包含指定 key（值非 null）
# -----------------------------------------------------------------------------
assert_json_has_key() {
    local json="$1"
    local key="$2"
    local message="${3:-key should exist}"

    local val
    val="$(echo "${json}" | jq -r --arg k "${key}" '.[$k] // "NULL"' 2>/dev/null)"
    if [[ "${val}" == "NULL" ]]; then
        echo "  FAIL: ${message} (key '${key}' not found)"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# assert_json_no_key <json> <key> <message>
# 断言 JSON 对象不包含指定 key
# -----------------------------------------------------------------------------
assert_json_no_key() {
    local json="$1"
    local key="$2"
    local message="${3:-key should not exist}"

    local val
    val="$(echo "${json}" | jq -r --arg k "${key}" '.[$k] // "NULL"' 2>/dev/null)"
    if [[ "${val}" != "NULL" ]]; then
        echo "  FAIL: ${message} (key '${key}' unexpectedly found: ${val})"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# assert_valid_json <json> <message>
# 断言字符串是合法的 JSON
# -----------------------------------------------------------------------------
assert_valid_json() {
    local json="$1"
    local message="${2:-should be valid JSON}"

    if echo "${json}" | jq . >/dev/null 2>&1; then
        return 0
    else
        echo "  FAIL: ${message} (invalid JSON: ${json})"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# run_test <test_name> <test_function>
# 运行单个测试，捕获结果并更新统计
# -----------------------------------------------------------------------------
run_test() {
    local test_name="$1"
    local test_fn="$2"

    echo -n "  TEST: ${test_name} ... "

    local output
    if output="$("${test_fn}" 2>&1)"; then
        echo "PASS"
        ((_TEST_PASS++)) || true
    else
        echo "FAIL"
        ((_TEST_FAIL++)) || true
        _TEST_ERRORS+=("${test_name}")
        if [[ -n "${output}" ]]; then
            echo "${output}" | sed 's/^/    /'
        fi
    fi

    # 每次测试后重置 mock
    reset_mocks
}

# -----------------------------------------------------------------------------
# print_summary
# 打印测试汇总结果
# -----------------------------------------------------------------------------
print_summary() {
    local total=$((_TEST_PASS + _TEST_FAIL))
    echo ""
    echo "========================================"
    echo "测试结果: ${_TEST_PASS}/${total} 通过"
    if [[ ${_TEST_FAIL} -gt 0 ]]; then
        echo "失败用例:"
        for err in "${_TEST_ERRORS[@]}"; do
            echo "  - ${err}"
        done
        echo "========================================"
        return 1
    fi
    echo "========================================"
    return 0
}
