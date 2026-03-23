---
category: 系统监控
keywords: [系统信息, 硬件信息, CPU, 内存, 存储, 虚拟机, 物理机, RAID, 运行时, 告警, IaaS]
---

# tsc_iaas_info

## 功能说明

1. 输出系统基本信息, 包括`处理器`, `内存`, `存储`, `操作系统版本`, `是否虚拟机`.  
   支持可使用`Arcconf` 卡和 `storcli` 的 Raid 卡.  
   结果输出 json 并生成到 `/var/log/tsc/tsc_iaas_info.json`
2. 输出系统运行时信息, 包括 `处理器`, `内存`, `存储` 使用率, 以及可根据传入的阈值参数生成告警项

## 运行方法说明

```bash
source /home/tsc/tsc_profile
# 输出系统基本信息
tsc --tsc_iaas_info
# 可选, 添加合同号和机器位置信息功能
tsc --tsc_iaas_info --contract_no 合同号 --location 机器位置
# 输出系统运行时信息
tsc --tsc_iaas_info --runtime
# 输出系统运行时信息并根据传入的阈值参数告警
# --cpu_threshold=[50] 处理器使用率超过 50% 生成告警项
# --storage_threshold=[50] 存储使用率超过 50% 生成告警项, 包括存储使用率和inodes使用率, 取大者
# --memory_threshold=[50] 内存使用率超过 50% 生成告警项
tsc --tsc_iaas_info --runtime --cpu_threshold=50 --storage_threshold=50 --memory_threshold=50
```
