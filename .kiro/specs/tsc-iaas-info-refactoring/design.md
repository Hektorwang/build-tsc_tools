# tsc_iaas_info 模块分层解耦重构 - 技术设计文档

## 1. 概述

当前 run.sh 约 835 行，所有逻辑混杂在单一文件中。本次重构目标是将其拆分为分层架构，提升可维护性、可测试性和可扩展性，同时保持命令行接口向后兼容。

## 2. 现状分析

### 2.1 现有问题

1. **单体文件**: run.sh 包含所有逻辑，约 835 行
2. **重复代码**: get_raid_type() 在 run.sh 和 tsc_raid_health_check.sh 中各定义一次
3. **全局状态耦合**: RAID_INFO 关联数组作为全局变量在多处使用
4. **职责混杂**: 静态信息采集、运行时监控、告警生成、文件管理混在一起
5. **难以测试**: 函数依赖全局变量，无法独立测试

### 2.2 现有核心机制（必须保留）

**文件版本管理与对比告警机制:**

1. 每次运行生成带时间戳文件: /var/log/tsc/tsc_iaas_info-{timestamp}.json
2. 软链接 /var/log/tsc/tsc_iaas_info.json 始终指向最新文件
3. MD5 对比逻辑:
   - 相同: 删除旧文件，软链接指向新文件（节省磁盘空间）
   - 不同: 保留旧文件，软链接指向新文件（保留历史用于对比）
4. 运行时告警通过对比 original_logfile（软链接指向的历史文件）实现:
   - RAID 物理磁盘数量变化告警
   - 直通盘数量变化告警
   - RAID 健康状态告警

## 3. 高层设计

### 3.1 分层架构

三层架构: 表示层(run.sh) -> 业务逻辑层(info_main/runtime_main/alert) -> 数据采集层(collectors/monitors/raid)

### 3.2 目录结构

tsc_tools/modules/tsc_iaas_info/
 run.sh
 tsc_raid_health_check.sh
 lib/
│    common.sh
    info_main.sh
    runtime_main.sh
    alert.sh
    collectors/
       cpu.sh
       memory.sh
       storage.sh
       system.sh
    monitors/
       cpu.sh
       memory.sh
       storage.sh
    raid/
        detector.sh
        lsi.sh
        adaptec.sh
        sas3.sh
        sas2.sh
 tests/
     test_collectors.sh
     test_monitors.sh
     test_raid.sh


## 4. 底层设计

### 4.1 lib/common.sh

公共常量和工具函数:
- INVALID_SNS: 无效序列号列表
- LD_KEYWORDS / PD_KEYWORDS: RAID 状态关键字映射表（从 tsc_raid_health_check.sh 迁移）
- associate_array_to_json(): 关联数组转 JSON
- array_to_json(): 数组转 JSON
- normalize_disk_size(): 磁盘大小单位统一转换为 TB


### 4.2 lib/raid/detector.sh

统一的 RAID 检测逻辑，消除 run.sh 和 tsc_raid_health_check.sh 中的重复定义:

函数签名:
- raid_detect(): 检测 RAID 类型，输出两个变量 RAID_TYPE 和 RAID_BIN
  - 返回: RAID_TYPE=none|adaptec|mpt3sas|mpt2sas|lsi
  - 返回: RAID_BIN=工具路径 或 空字符串
  - 查找顺序: /bin/ -> /sbin/ -> 模块 packages/ -> PATH


### 4.3 lib/collectors/

各采集器统一接口规范: 每个采集器函数输出一个 JSON 片段，无副作用，不依赖全局变量。

**cpu.sh**
- collect_cpu_info(): 输出 {cpu: {cpu_model, cpu_cnt}}

**memory.sh**
- collect_mem_info(): 输出 {memory: [{size, locator, unit}]}

**system.sh**
- collect_serial_number(sn_override, logfile): 输出 {sn: ...}
  - 优先级: sn_override > logfile.sn > dmidecode
- collect_contract_no(contract_no_override, logfile): 输出 {contract_no: ...}
- collect_location(location_override, logfile): 输出 {location: ...}
- collect_manufacturer(): 输出厂商字符串

**storage.sh**
- collect_disk_info(machine_type, raid_type, raid_bin): 输出 {storage: [...]}
  - 区分 RAID 盘(type=raid) 和直通盘(type=direct)
  - 直通盘判断逻辑: Virtual disk/VMware OR (非RAID厂商 AND 非LOGICAL AND 总线路径无RAID关键字)


### 4.4 lib/monitors/

**cpu.sh**
- monitor_cpu(): 采样 /proc/stat 两次(间隔1秒)，输出 {used_percent, iowait_percent}

**memory.sh**
- monitor_memory(): 读取 free -b，输出 {ram: {total,used,used_percent,unit}, swap: {...}}

**storage.sh**
- test_writability(mount_point): 测试挂载点可写性，返回 true/false
- monitor_mountpoints(): 遍历 findmnt 输出，采集各挂载点大小/inode/可写性，输出 JSON 数组


### 4.5 lib/alert.sh

告警生成与历史对比:

- generate_threshold_alerts(cpu_json, memory_json, mountpoint_json, cpu_threshold, memory_threshold, storage_threshold): 生成阈值告警
- generate_disk_change_alerts(current_disk_json, logfile): 对比历史文件，生成磁盘数量变化告警
- generate_raid_alerts(raid_status_json): 解析 RAID 状态，生成 VD/PD 异常告警
- merge_alerts(alerts...): 合并多个告警 JSON 对象

**历史对比逻辑:**
1. 读取 logfile（软链接指向的历史文件）
2. 对比当前 RAID 盘数量 vs 历史 RAID 盘数量
3. 对比当前直通盘数量 vs 历史直通盘数量
4. 有差异则生成对应告警项

### 4.6 lib/raid/ 适配器接口规范

每个 RAID 适配器 source lib/common.sh 后提供两个函数:

- raid_get_disk_list(raid_bin): 输出物理磁盘 JSON 数组，用于静态信息采集
  - 输出格式: [{type:raid, model, serial, wwn, size, unit:T}]
- raid_check_health(raid_bin): 输出 VD/PD 健康状态 JSON 数组，用于运行时监控
  - 输出格式: [{阵列卡号, 虚拟磁盘号, 虚拟磁盘状态, 虚拟磁盘中文状态}, ...]

适配器文件:
- lsi.sh: 使用 storcli/storcli64，支持多控制器
- adaptec.sh: 使用 arcconf，单控制器
- sas3.sh: 使用 sas3ircu，支持多控制器
- sas2.sh: 使用 sas2ircu，支持多控制器

### 4.7 lib/info_main.sh

静态信息采集编排，替代原 main() 函数:

- collect_all_info(sn, contract_no, location, logfile): 编排所有采集器，输出完整 JSON
  1. source lib/raid/detector.sh -> raid_detect() 获取 RAID_TYPE, RAID_BIN
  2. 调用 collect_cpu_info()
  3. 调用 collect_mem_info()
  4. 调用 collect_disk_info(machine_type, RAID_TYPE, RAID_BIN)
  5. 调用 collect_serial_number / collect_contract_no / collect_location
  6. 用 jq 合并所有 JSON 片段输出

### 4.8 lib/runtime_main.sh

运行时监控编排，替代原 runtime() 函数:

- run_runtime_monitor(cpu_threshold, memory_threshold, storage_threshold, logfile): 编排所有监控器
  1. 调用 monitor_cpu() / monitor_memory() / monitor_mountpoints()
  2. 调用 generate_threshold_alerts() 生成阈值告警
  3. 若 machine_type=pm: 调用 raid_detect() + raid_check_health()
  4. 若 logfile 存在: 调用 generate_disk_change_alerts() 生成磁盘变化告警
  5. 调用 generate_raid_alerts() 生成 RAID 健康告警
  6. 用 jq 组装最终输出 JSON

## 5. 正确性属性

重构后必须满足以下属性:

P1. **接口兼容性**: run.sh 的所有命令行参数和输出 JSON 结构与重构前完全一致
P2. **文件版本管理**: 每次运行必须生成时间戳文件，软链接必须指向最新文件
P3. **MD5 去重**: 内容相同时旧文件被删除，内容不同时旧文件被保留
P4. **历史对比告警**: 磁盘数量变化必须产生告警，RAID 状态异常必须产生告警
P5. **无重复定义**: get_raid_type 逻辑只在 lib/raid/detector.sh 中存在一份
P6. **无副作用**: 各采集器函数不修改全局状态，可独立调用

## 6. 迁移策略

1. **阶段一**: 创建 lib/ 目录结构和 common.sh
2. **阶段二**: 提取 lib/raid/detector.sh，更新 tsc_raid_health_check.sh 使用它
3. **阶段三**: 逐个提取 collectors/ 模块（cpu, memory, system, storage）
4. **阶段四**: 逐个提取 monitors/ 模块（cpu, memory, storage）
5. **阶段五**: 提取 lib/raid/ 适配器（lsi, adaptec, sas3, sas2）
6. **阶段六**: 提取 lib/alert.sh
7. **阶段七**: 创建 lib/info_main.sh 和 lib/runtime_main.sh
8. **阶段八**: 精简 run.sh，仅保留参数解析、文件版本管理和调用编排
9. **阶段九**: 编写测试用例验证正确性属性
