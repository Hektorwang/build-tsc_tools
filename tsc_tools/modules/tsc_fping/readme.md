---
category: 网络监控
keywords: [ping, 主机扫描, 连通性, 批量ping, 存活检测, IP段扫描, fping]
---

# fping

## 功能说明

`fping` 是一个主机扫描工具,相比于 `ping` 工具可以批量扫描主机.

## 常用参数介绍

`fping` 的主要参数有以下三个:

- `-a`: 只显示存活主机
- `-u`: 只显示不存活主机
- `-l`: 循环 ping

```bash
  # 目标 IP 地址的输入方式:
  fping IP1 IP2 IP3 ...
  fping -f filename
  fping -g IP1 IP2 <IP1 地址开始范围,IP2 地址结束范围>
```

## 使用方法样例

```bash
# 查看某个 IP 段地址使用情况
fping -g 192.168.1.1/24
fping -g 192.168.1.1 192.168.1.254
# file文件存放系统主机列表,要查看存活主机
fping -a -q -f  file
# file文件存放系统主机列表,要查看死机主机
fping -u -q -f file
```
