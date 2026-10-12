#!/bin/bash
#
# tsc_tools RPM ---- %postun (卸载后清理目录壳)
#
#   $1 == 0  真卸载 (rpm -e):       清理空目录壳
#   $1 >= 1  升级 (rpm -U / 重装):   跳过, 新包 %post 会重建
#
# 执行时机: RPM 已删除包内文件清单的所有文件之后
#   /home/tsc/tsc_tools 下的包内文件已被 RPM 删, 衍生文件 (bin/,
#   .installed_manifest, drop-in) 已被 %preun 删, 此时仅剩空目录壳
# 本步自底向上清理空目录; 非空目录 (有意外残留) 不会被删, 安全
#
# 不清理 (保留):
#   /home/tsc/tsc_profile        公共入口
#   /home/tsc/tsc_profile.d 目录 drop-in 目录 (其他工具可能仍在用)
#   /var/log/tsc                 运行期日志
##################################################
# shellcheck disable=SC2034
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

if [ "${1:-0}" != "0" ]; then
    # 升级: 不清理, 新包 %post 会重建
    exit 0
fi

# 自底向上清理 /home/tsc/tsc_tools 下的空目录壳
# -depth: 先处理子目录再处理父目录; -empty: 只删空目录
find /home/tsc/tsc_tools -depth -type d -empty -delete 2>/dev/null

exit 0
