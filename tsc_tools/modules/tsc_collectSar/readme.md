---
category: 系统监控
keywords:
  - sar
  - 资源对比
  - 性能对比
  - CPU
  - 内存
  - 磁盘IO
  - 网络
  - 历史数据
  - 测试前后对比
description: 对比给定的两个时间点的系统资源使用情况
usage: tsc --tsc_collect_sar [install|compare|uinstall] [参数]
---

# tsc_collectSar

功能说明

对比给定的两个时间点的系统资源使用情况

1. 修改 sar 取值频率,修改为 1 分钟一次;并备份 sa 文件到/home/fox/CollectSar/BackSar/目录下;
2. 以小时为单位,对比指定日期同时间段的 CPU,内存,磁盘 IO,网络(通讯口)的比率;
3. 将对比结果输出到/home/fox/CollectSar 目录下;

用法

1. 实测前,执行 install 脚本

   ```bash
   source /home/tsc/tsc_profile
   tsc --tsc_collect_sar install
   ```

2. 执行对比脚本

   ```bash
   source /home/tsc/tsc_profile
   tsc --tsc_collect_sar compare 20210910 20210914 172.16.40.43
   # 20210910 为测试前日期，20210914 为测试后日期，172.16.40.43 为本机 ip 地址
   ```

   PS: 最大对比跨度为 28 天;  
   生成的 csv 文件在/home/fox/CollectSar 目录下

3. 需要卸载则执行 uinstall 脚本,执行一次即可。卸载会将定时任务恢复,将/home/fox/CollectSar 目录移动至/tmp 目录

   ```bash
   source /home/tsc/tsc_profile
   tsc --tsc_collect_sar uinstall
   ```
