---
category: 系统管理
keywords:
  - 初始化
  - SSH
  - 防火墙
  - 时区
  - NTP
  - 服务裁剪
  - SELinux
  - 系统参数
  - 新服务器
  - 安全加固
description: 对于新装完操作系统的服务器进行初始化配置. 因为要修改系统配置, 必须用 `root` 权限执行.
usage: tsc --tsc_sysinit --help
---

# tsc_sysinit

## 简介

此工具专为新安装的服务器提供一键式初始化配置, 旨在优化系统性能, 提升安全性并简化日常管理. 由于涉及到系统底层配置, 脚本必须以 `root` 权限执行.

## 功能模块

本工具集成了多个初始化配置模块, 你可以选择性地启用, 也可以使用 `--all` 选项一次性完成所有无需参数的配置.

### 1. SSH 配置优化

选项和参数: `--config_ssh`, `--sshd_port=<修改本机ssh服务端口>`

该模块用于增强 SSH 客户端与服务器的连接体验和安全性.

- **客户端**:
  - **[默认] 取消公钥摘要验证**: 登录时跳过 `StrictHostKeyChecking`, 方便快捷连接.
  - **[默认] 连接超时**: 设置连接超时时间为 **30 秒**, 超时后自动断开.
- **服务端**:
  - **[默认] 加速登录**: 禁用 `UseDNS`, 避免因 DNS 解析延迟导致的登录缓慢.
  - **[默认] 登录超时**: 客户端必须在 **60 秒**内完成登录, 否则自动断开.
  - **[可选] 修改端口**: 支持自定义 ssh 服务端口, 例如 `--sshd_port 2222`.

### 2. 系统服务裁剪与优化

选项和参数: `--config_services`

此模块将精简系统启动服务, 仅保留核心功能, 以减少资源占用和潜在安全风险.

**服务禁用**: 默认禁用所有非核心服务和 `tmp.mount`, 并确保以下服务若已经安装则保持指定配置状态:

| 服务名称                             | 指定配置 | 功能简述                                                  |
| :----------------------------------- | -------- | :-------------------------------------------------------- |
| `auditd.service`                     | 启用     | 审计守护进程, 用于记录系统上的安全相关信息.               |
| `crond.service`                      | 启用     | 周期性命令调度程序, 负责执行预定的任务(如 Cron 作业).     |
| `getty@.service`                     | 启用     | 管理虚拟控制台(TTY)登录, 允许用户在终端登录系统.          |
| `ipmi.service`                       | 启用     | 智能平台管理接口, 用于远程监控和管理服务器硬件.           |
| `irqbalance.service`                 | 启用     | 均衡中断请求(IRQ)到多核 CPU, 以优化系统性能.              |
| `lm_sensors.service`                 | 启用     | 硬件传感器监控工具, 用于显示 CPU 温度, 风扇速度等信息.    |
| `NetworkManager.service`             | 启用     | 网络连接管理, 负责配置和管理网络接口.                     |
| `NetworkManager-dispatcher.service`  | 启用     | NetworkManager 的调度服务, 用于在网络状态变化时执行脚本.  |
| `NetworkManager-wait-online.service` | 启用     | 在系统启动时等待网络连接变为“在线”状态.                   |
| `rngd.service`                       | 启用     | 随机数生成器守护进程, 为系统提供高质量的随机数.           |
| `rsyslog.service`                    | 启用     | 系统日志记录器, 用于收集, 处理和转发系统日志.             |
| `sshd.service`                       | 启用     | SSH 守护进程, 提供安全的远程登录和文件传输服务.           |
| `sssd.service`                       | 启用     | 系统安全服务守护进程, 用于集中管理身份验证和访问控制.     |
| `sysstat.service`                    | 启用     | 系统性能统计工具, 用于收集和报告 CPU, 内存等系统活动数据. |
| `systemd-network-generator.service`  | 启用     | 根据内核和硬件信息生成 `.network` 文件.                   |
| `tuned.service`                      | 启用     | 动态调整系统设置, 根据预设配置文件优化性能和功耗.         |
| `tmp.mount`                          | 禁用     | 临时文件系统的挂载点                                      |

### 3. 防火墙管理

选项和参数: `--disable_firewall`

关闭并禁用所有防火墙服务, 并清空所有防火墙规则, 以确保网络连接畅通.

**操作**: 禁用 `firewalld`, `iptables`, `ufw` 和 `nftables` 服务, 并清除所有防火墙表链的规则.

### 4. 系统时间管理

确保系统时间准确性, 这对于日志记录和分布式系统至关重要.

- **时区设置**
  `--config_timezone`, `--timezone=时区`  
  默认将系统时区和 JVM 时区配置为 `Asia/Shanghai`. 也可通过 `--timezone="Asia/Tokyo"` 指定其他时区.
- **时间同步**
  `--ntp_server=授时服务器`  
  可选择使用 `--ntp_server=ntp服务器` 参数指定 NTP 服务器进行时间同步, 并创建 `cron` 任务以实现周期性对时.

### 5. 系统终端环境

选项和参数: `--config_user_env`

此模块为 `root` 用户和全局环境配置了更友好和安全的终端体验.

- **语言环境**: 统一设置为 `en_US.UTF-8`.
- **别名与功能**:
  - `grep` 默认显示彩色高亮.
  - `history` 记录增加时间戳, 并增加记录条目数.
  - 设置终端超时时间为 **600 秒**, 超时自动退出.

### 6. 系统参数调优

选项和参数: `--config_system_parameter`

通过修改系统内核, 进程和文件描述符等参数, 提升系统在处理高并发, 大文件等场景下的性能.

- **配置范围**: 针对`操作系统`, `systemd` 和`用户`级配置.
- **参数值**: 最大进程数和最大打开文件数均设置为 **1048576**.

### 7. 其他配置

- **SELinux**: `--config_selinux`, 默认永久禁用 SELinux.
- **启动级别**: `--config_runlevel` 设置系统默认启动级别为 `multi-user.target`.
- **工具安装**: `--install_fhmv`, 安装烽火回收站工具 `fh-data-recovery`
- **启动脚本**: **无控制开关**, 全量执行必选, 使能 `rc.local`.
- **配置系统字符集**: **无控制开关**, 全量执行必选, 配置系统字符集为: `en_US.UTF-8`.
- **日志配置**: `sar` **无控制开关**, 全量执行必选, 数据保存天数修改为 **28 天**.

## 使用方法

```bash
# 激活工具环境
source /home/tsc/tsc_profile
# 查看具体参数
tsc --tsc_sysinit --help
# 完全配置所有功能, 包括设置对时和修改 sshd 端口
tsc --tsc_sysinit --all --ntp_server=time.windows.com --sshd_port=12345
# 仅使用部分功能
tsc --tsc_sysinit --config_services --disable_firewall
# 在所有功能上排除部分功能(disable_firewall)
tsc --tsc_sysinit --all --ntp_server=time.windows.com --sshd_port=12345 --no-disable_firewall
```

## 参数列表

| 选项/参数                   | 类型 | 描述                                                                |
| :-------------------------- | :--- | :------------------------------------------------------------------ |
| `--help`                    | 开关 | 显示帮助信息并退出.                                                 |
| `--all`                     | 开关 | 启用所有功能模块.                                                   |
| `--check_env`               | 开关 | 检查运行环境(例如 `root` 权限和 `systemd`).                         |
| `--config_selinux`          | 开关 | 永久禁用 SELinux.                                                   |
| `--config_runlevel`         | 开关 | 设置系统默认启动级别为 `multi-user.target`.                         |
| `--config_services`         | 开关 | 禁用非核心服务并优化服务列表.                                       |
| `--config_timezone`         | 开关 | 配置系统时区.                                                       |
| `--timezone=<时区>`         | 参数 | 指定要设置的时区(例如 `--timezone="Asia/Tokyo"`).                   |
| `--disable_firewall`        | 开关 | 禁用防火墙服务并清空所有规则.                                       |
| `--config_ssh`              | 开关 | 配置 ssh 客户端和服务端.                                            |
| `--sshd_port=<端口>`        | 参数 | 自定义 ssh 服务监听端口(例如 `--sshd_port=2222`).                   |
| `--ntp_server=<服务器>`     | 参数 | 配置向授时服务器进行时间同步(例如 `--ntp_server=time.windows.com`). |
| `--config_user_env`         | 开关 | 配置终端环境(`bashrc` 和 `profile`).                                |
| `--config_system_parameter` | 开关 | 调优系统内核, 进程和文件描述符参数.                                 |
| `--install_fhmv`            | 开关 | 安装烽火回收站工具 `fh-data-recovery`.                              |
| `--no-选项名`               | 开关 | 排除指定的选项.                                                     |
