#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# =============================================================================
# tests/test_schema.sh — schema 三件套自测 (DESIGN.md §7)
# 用例: 骨架自洽 / 填充后合法 / 结构破坏被拦截
# =============================================================================
set -o errexit
set -o nounset
set -o pipefail

HERE="$(dirname "$(readlink -f "$0")")"
SCHEMA_DIR="$(dirname "${HERE}")/lib/schema"

PASS=0; FAIL=0
chk() {
	if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"
	else FAIL=$((FAIL + 1)); printf '  FAIL %s (期望[%s] 实际[%s])\n' "$1" "$2" "$3"; fi
}
# 校验辅助: validate_static/runtime, 文件路径入参, 输出 true/false
vstatic() { jq -e -L "${SCHEMA_DIR}" 'include "validate"; validate_static' "$1" >/dev/null 2>&1 && echo true || echo false; }
vruntime() { jq -e -L "${SCHEMA_DIR}" 'include "validate"; validate_runtime' "$1" >/dev/null 2>&1 && echo true || echo false; }

T=/tmp/v2_schema_test
rm -rf "${T}"; mkdir -p "${T}"

echo "=== 1. 骨架自洽 ==="
chk "static.tmpl 自身通过校验" true "$(vstatic "${SCHEMA_DIR}/static.tmpl.json")"
chk "runtime.tmpl 自身通过校验" true "$(vruntime "${SCHEMA_DIR}/runtime.tmpl.json")"

echo "=== 2. 填充后合法 ==="
jq -c '
  .meta.tool_version = "2.1.2"
  | .meta.generated_at = "2026-09-29T00:00:00+08:00"
  | .machine_type = "vm" | .sn = "TESTSN"
  | .cpu = {cpu_model: "Test CPU", cpu_cnt: 2}
  | .memory = [{size: 16, locator: "DIMM_A1", unit: "G"}]
  | .storage = [{dev: "/dev/sda", type: "direct", ctl_no: null, enc: null, slot: null,
                 vd: null, state: null, state_norm: "online", size: "894.3", unit: "G",
                 size_gb: 894, model: "SAMSUNG MZ7LH960", serial: "S3EVNX0K1",
                 wwn: "0x5002538e", interface: "sata"}]
  | .raid_controllers = [{type: "lsi", ctl_no: 0, name: "AVG-9361-8i",
                          health: "Opt", health_norm: "online", vd_count: 1, pd_count: 2}]
' "${SCHEMA_DIR}/static.tmpl.json" > "${T}/static_filled.json"
chk "静态填充样例通过校验" true "$(vstatic "${T}/static_filled.json")"

jq -c '
  .meta.generated_at = "2026-09-29T00:00:00+08:00"
  | .cpu = {used_percent: 3.5, iowait_percent: 0.1}
  | .memory = {ram: {total: 32.0, used: 5.1, used_percent: 15.9, unit: "G"},
               swap: {total: 0, used: 0, used_percent: 0, unit: "G"}}
  | .storage = {mountpoint: [{target: "/", source: "/dev/sda1", filesystem: "xfs",
                              size: {total: 100.0, used: 40.0, used_percent: 40.0, unit: "G"},
                              inodes: {total: 1000, used: 100, used_percent: 10.0},
                              writable: true}], raid: []}
  | .warning = {cpu_usage: null, memory_usage: null, storage_usage: null,
                inode_usage: null, storage_unwritable: null,
                pd_cnt_diffrent: null, direct_disk_cnt_diffrent: null, raid_status: null}
' "${SCHEMA_DIR}/runtime.tmpl.json" > "${T}/runtime_filled.json"
chk "运行时填充样例通过校验" true "$(vruntime "${T}/runtime_filled.json")"

echo "=== 3. 结构破坏被拦截 ==="
jq 'del(.cpu)' "${T}/static_filled.json" > "${T}/bad1.json"
chk "缺 cpu 对象被拦截" false "$(vstatic "${T}/bad1.json")"

jq '.cpu.cpu_cnt = "2"' "${T}/static_filled.json" > "${T}/bad2.json"
chk "cpu_cnt 为字符串被拦截" false "$(vstatic "${T}/bad2.json")"

jq '.meta.degraded = "oops"' "${T}/static_filled.json" > "${T}/bad3.json"
chk "degraded 非数组被拦截" false "$(vstatic "${T}/bad3.json")"

jq '.memory[0] |= del(.locator)' "${T}/static_filled.json" > "${T}/bad4.json"
chk "memory 条目缺 locator 被拦截" false "$(vstatic "${T}/bad4.json")"

jq '.storage[0] |= del(.interface)' "${T}/static_filled.json" > "${T}/bad7.json"
chk "storage 条目缺 interface 被拦截" false "$(vstatic "${T}/bad7.json")"

jq '.storage[0].state_norm = "bogus"' "${T}/static_filled.json" > "${T}/bad8.json"
chk "state_norm 越界枚举被拦截" false "$(vstatic "${T}/bad8.json")"

jq '.storage[0].size_gb = "894"' "${T}/static_filled.json" > "${T}/bad9.json"
chk "size_gb 为字符串被拦截" false "$(vstatic "${T}/bad9.json")"

jq '.storage = "none"' "${T}/static_filled.json" > "${T}/bad10.json"
chk "storage 非数组被拦截" false "$(vstatic "${T}/bad10.json")"

jq '.raid_controllers[0] |= del(.health_norm)' "${T}/static_filled.json" > "${T}/bad11.json"
chk "raid_controllers 条目缺 health_norm 被拦截" false "$(vstatic "${T}/bad11.json")"

jq '.raid_controllers[0].health_norm = "bogus"' "${T}/static_filled.json" > "${T}/bad12.json"
chk "health_norm 越界枚举被拦截" false "$(vstatic "${T}/bad12.json")"

jq '.storage.mountpoint = "x"' "${T}/runtime_filled.json" > "${T}/bad13.json"
chk "runtime mountpoint 非数组被拦截" false "$(vruntime "${T}/bad13.json")"

jq '.warning.raid_status = "degraded"' "${T}/runtime_filled.json" > "${T}/bad14.json"
chk "raid_status 非数组被拦截" false "$(vruntime "${T}/bad14.json")"

jq '.storage.mountpoint[0].writable = "yes"' "${T}/runtime_filled.json" > "${T}/bad15.json"
chk "writable 非布尔被拦截" false "$(vruntime "${T}/bad15.json")"

echo "=== 3b. 多余键拦截(键集合严格校验) ==="
jq '.storage[0].extra = 1' "${T}/static_filled.json" > "${T}/bad16.json"
chk "storage 条目多余键被拦截" false "$(vstatic "${T}/bad16.json")"

jq '.raid_controllers[0].extra = 1' "${T}/static_filled.json" > "${T}/bad17.json"
chk "raid_controllers 条目多余键被拦截" false "$(vstatic "${T}/bad17.json")"

jq '.storage.mountpoint[0].extra = 1' "${T}/runtime_filled.json" > "${T}/bad18.json"
chk "mountpoint 条目多余键被拦截" false "$(vruntime "${T}/bad18.json")"

jq 'del(.warning)' "${T}/runtime_filled.json" > "${T}/bad5.json"
chk "运行时缺 warning 被拦截" false "$(vruntime "${T}/bad5.json")"

jq '.warning.cpu_usage = 1' "${T}/runtime_filled.json" > "${T}/bad6.json"
chk "告警值为数字被拦截" false "$(vruntime "${T}/bad6.json")"

echo "=== 4. 校验模块覆盖静态/运行时互不越界 ==="
chk "静态样例不通过 runtime 校验" false "$(vruntime "${T}/static_filled.json")"
chk "运行时样例不通过 static 校验" false "$(vstatic "${T}/runtime_filled.json")"

echo ""
echo "通过 $PASS / $((PASS + FAIL))"
[[ ${FAIL} -eq 0 ]]
