##################################################
# 最小运行时库 (供 RPM %pre 使用)
#
# %pre 执行时包内文件尚未落盘, 无法 source /home/tsc/tsc_tools/func,
# 这里提供与 func 同名同签名的 LOG* 与 is_element_in_array, 保证
# env_check.sh 在 %pre / %post 两处行为一致。
#
# 本文件会被 build.sh 内联进 %pre 脚本, 不单独发布。
##################################################

# %pre 阶段统一写 stderr: rpm 会把 scriptlet 输出回显给安装者,
# 写 stdout 会与 rpm 自身的进度输出混淆
__log_min() {
    local level="$1"
    shift || true
    printf '%s | %-8s | tsc_tools-pre - %s\n' \
        "$(date "+%F %T")" "${level}" "$*" >&2
    return 0
}

LOGDEBUG() { __log_min "DEBUG" "$@"; }
LOGINFO() { __log_min "INFO" "$@"; }
LOGSUCCESS() { __log_min "SUCCESS" "$@"; }
LOGWARNING() { __log_min "WARNING" "$@"; }
LOGERROR() { __log_min "ERROR" "$@"; }

##################################################
# 判断元素是否在列表中 (与 tsc_tools/func 同名函数实现一致)
# 参数:
#   $1      - 待查元素
#   $2...$# - 列表元素
# 返回:
#   0 - 命中
#   1 - 未命中
##################################################
is_element_in_array() {
    local element_to_check="$1"
    shift

    local item
    for item in "$@"; do
        if [[ "${element_to_check}" == "${item}" ]]; then
            return 0
        fi
    done
    return 1
}
