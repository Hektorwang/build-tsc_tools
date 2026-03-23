# 运维工具集

## 工具说明

运维工具集, 集成常用基础运维工具, 以方便运维工作

## 模块

- tsc_netspeed  
  网卡速度监测  
  持续监控指定网卡的收发包速率  
  tsc --tsc_netspeed \<interface\>  
- tsc_monitor_run_stat  
  tsc_monitor_run_stat  
  主要用于监听进程的运行状态和服务器的运行环境, 方便获取进程不定时出现问题时的运行环境.  
  tsc --tsc_monitor_run_stat <PID/PNAME> <process_pattern> <delay_interva>  
- tsc_iaas_info  
  检测系统IaaS信息  
  输出系统基本信息, 包括`处理器`, `内存`, `存储`, `操作系统版本`, `是否虚拟机`等, 并保存到 `/var/log/tsc_iaas_info.json`  
  查看 readme.md  
- tsc_sysinit  
  操作系统初始化工具  
  对于新装完操作系统的服务器进行初始化配置. 因为要修改系统配置, 必须用 `root` 权限执行.  
  tsc --tsc_sysinit --help  
- tsc_sysinfo  
  系统运行环境采集检查和基础环境完工检查工具  
  迁移中, 尚未完成  
- tsc_fping  
  fping  
  `fping` 是一个主机连通性扫描工具,相比于 `ping` 工具可以批量扫描主机.  
- tsc_drop_cache  
  释放系统内存缓存  
  通过 `echo 3 > /proc/sys/vm/drop_caches` 手动释放内存缓存, 以缓解系统压力. 效果取决于系统可释放的缓存.  
  --drop_cache [释放阈值] # 可选参数, 释放阈值(int), 默认内存使用率超过 80% 时释放  
- tsc_collectSar  
  系统资源使用情况对比工具  
  对比给定的两个时间点的系统资源使用情况  

## 用法

```bash
tsc --模块名 模块选项 模块选项=选项参数

# 如操作系统初始化

# --tsc_sysinit: 模块名

# --all: 模块定制选项, 执行该模块所有功能

# --no-install_fhmv: 模块定制选项反义, 排除执行某个功能

# --sshd_port=3204: 模块选项参数, 将sshd端口设置为3204

tsc --tsc_sysinit --all --no-install_fhmv --sshd_port=3204

# 查看帮助

tsc --help
tsc --模块名 --help
glow /home/tsc/tsc_tools/modules/模块名/readme.md
```
