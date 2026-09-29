#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -o errexit    # Exit immediately if a command exits with a non-zero status
set -o nounset    # Treat unset variables and parameters as an error
set -o pipefail   # If any command in a pipeline fails, the pipeline returns an error code
set +o posix      # Disable POSIX mode, allowing Bash-specific extensions (less portable)
shopt -s nullglob # When no files match a glob pattern, expand to nothing instead of the pattern itself

MEM_USED_THRESHOLD="${1:-80}"

WORK_DIR="$(dirname "$(readlink -f "$0")")"
# 始终 source func, 不设 TSC_FUNC 守卫: 经 tsc 分发器调用时本脚本是子进程,
# TSC_FUNC=true 只代表父进程加载过 func, 子进程仅继承被 export -f 的函数
# (LOG* 有而 __log 无), 跳过 source 会在首次打日志时报 __log: command not found
source "${WORK_DIR}/../../func"

get_mem() {
    mem_total="$(free -m | awk '/^Mem:/{print $2}')"
    mem_used="$(free -m | awk '/^Mem:/{print $3}')"
    mem_used_percentage="$(
        awk -v used="$mem_used" -v total="$mem_total" '
    BEGIN {
        if (total == 0)
            printf "%d", 0
        else
            printf "%d", (used / total) * 100
    }'
    )"

    LOGINFO "Memory usage: ${mem_used_percentage}% (used: ${mem_used}MB, total: ${mem_total}MB)"
}
get_mem

if [ "${mem_used_percentage}" -gt "${MEM_USED_THRESHOLD}" ]; then
    LOGINFO "Memory usage is above ${MEM_USED_THRESHOLD}%: ${mem_used_percentage}%"
    if sync; then
        echo 3 >/proc/sys/vm/drop_caches
        LOGSUCCESS "Caches dropped successfully."
    else
        LOGERROR "Failed to sync before dropping caches." >&2
        exit 1
    fi
else
    LOGINFO "Memory usage is below or equal to ${MEM_USED_THRESHOLD}%: ${mem_used_percentage}%"
fi
