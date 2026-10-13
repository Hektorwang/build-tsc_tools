---
category: 系统监控
keywords:
  - 进程
  - 监控
  - CPU
  - 内存
  - swap
  - fd
  - iowait
  - 进程状态
  - 运行环境
  - 故障排查
description: 主要用于监听进程的运行状态和服务器的运行环境, 方便获取进程不定时出现问题时的运行环境.
usage: tsc --tsc_monitor_run_stat <PID/PNAME> <process_pattern> <delay_interva>
---

# tsc_monitor_run_stat

## 功能说明

进程运行状态监测

1. 主要用于监听进程的运行状态和服务器的运行环境, 方便获取进程不定时出现问题时的运行环境.
2. 主要监听参数有: 服务器 CPU 总数, 内存大小, 空闲状态, iowait 状态, 进程 ID, 进程 CPU 消耗, 进程内存消耗, 进程 swap 消耗, 进程 fd 消耗.

## 使用方法

```bash
source /home/tsc/tsc_profile
tsc --tsc_monitor_run_stat PID/PNAME <process_pattern> delay_interval

# 分为两种工作模式
# 1. PID 模式
tsc --tsc_monitor_run_stat PID 某进程PID 输出间隔时间
tsc --tsc_monitor_run_stat PID 1573 2

# 2. 进程名模式
# 注意在该模式下, 进程名请尽量写精确, 确保使用 pgrep -f "进程名" 仅能获取到一个 PID
# 若获取到多个 PID 的情况下本工具无法工作
tsc --tsc_monitor_run_stat PNAME 某进程名 输出间隔时间
tsc --tsc_monitor_run_stat PNAME zabbix_agent 输出间隔时间
```

## 输出样例如下

```text
DateTime            |cpu(cnt) |mem(GB) |idle(%) |iowait(%) |pid       |cpu(%)   |mem(MB)     |swap(MB) |fd(cnt)
2025-07-18 19:44:55 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:44:57 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:45:00 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:45:02 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:45:04 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:45:06 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:45:08 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:45:10 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
2025-07-18 19:45:12 |16       |31.0    |99      |0         |907685    |0        |84.0        |0        |28
```
