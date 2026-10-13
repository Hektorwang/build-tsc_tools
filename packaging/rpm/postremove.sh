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

# 无论卸载还是升级都先回收 modules/ 下的空目录壳:
# 升级时旧包的文件是在新包 %post 之后才被 rpm 删除的, 旧命名模块 (如 tsc_collectSar)
# 的空壳刚好在此刻出现, %post 那次清理抓不到, 必须在这里补一刀。
# 只删 modules/ 下**空**的一级子目录, 新包已就位的内容不受影响。
find /home/tsc/tsc_tools/modules -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null

if [ "${1:-0}" != "0" ]; then
    # 升级: 整树不清, 新包已就位且 %post 会重建需要的东西
    exit 0
fi

# 自底向上清理 /home/tsc/tsc_tools 下的空目录壳
# -depth: 先处理子目录再处理父目录; -empty: 只删空目录
find /home/tsc/tsc_tools -depth -type d -empty -delete 2>/dev/null

exit 0
