# tsc_iaas_info 模块分层解耦重构 - 需求文档

## 1. 背景

tsc_iaas_info 是 tsc_tools 中用于采集和监控 IaaS 基础设施信息的核心模块。当前实现为单体脚本（run.sh 约 835 行），所有功能混杂在一起，难以维护和扩展。本次重构目标是在保持功能完全不变的前提下，对模块进行分层解耦。

## 2. 功能需求

### FR-1 静态信息采集

- FR-1.1 采集 CPU 型号和插槽数量
- FR-1.2 采集内存插槽信息（大小、位置），支持 MB/GB 单位转换
- FR-1.3 采集系统序列号，优先级: --sn 参数 > 历史日志 > dmidecode 自动获取
- FR-1.4 采集系统厂商信息
- FR-1.5 采集磁盘信息，区分 RAID 盘（type=raid）和直通盘（type=direct）
- FR-1.6 支持合同号（--contract_no）和位置（--location）参数，可从历史日志继承
- FR-1.7 支持 Adaptec（arcconf）和 LSI/MegaRAID（storcli）RAID 卡的磁盘信息采集

### FR-2 运行时监控

- FR-2.1 采集 CPU 使用率和 iowait 百分比（1秒采样）
- FR-2.2 采集内存和 swap 使用率
- FR-2.3 采集各挂载点的容量使用率、inode 使用率和可写性
- FR-2.4 支持 CPU/内存/存储使用率阈值告警（默认 90%）
- FR-2.5 支持 inode 使用率阈值告警
- FR-2.6 支持挂载点不可写告警

### FR-3 RAID 健康监控

- FR-3.1 支持 LSI/MegaRAID（storcli）RAID 卡健康检查
- FR-3.2 支持 Adaptec（arcconf）RAID 卡健康检查
- FR-3.3 支持 SAS3（sas3ircu）RAID 卡健康检查
- FR-3.4 支持 SAS2（sas2ircu）RAID 卡健康检查
- FR-3.5 输出 VD（虚拟磁盘）和 PD（物理磁盘）状态，含中文状态描述
- FR-3.6 VD/PD 状态异常时生成告警

### FR-4 历史对比告警

- FR-4.1 每次运行生成带时间戳的 JSON 文件: /var/log/tsc/tsc_iaas_info-{timestamp}.json
- FR-4.2 软链接 /var/log/tsc/tsc_iaas_info.json 始终指向最新文件
- FR-4.3 MD5 对比: 内容相同则删除旧文件节省空间，内容不同则保留旧文件
- FR-4.4 运行时模式下，对比历史文件检测 RAID 盘数量变化并告警
- FR-4.5 运行时模式下，对比历史文件检测直通盘数量变化并告警
- FR-4.6 运行时模式下，对比历史文件检测 CPU 型号变化并告警（cpu.cpu_model 字段）
- FR-4.7 运行时模式下，对比历史文件检测 CPU 插槽数量变化并告警（cpu.cpu_cnt 字段）
- FR-4.8 运行时模式下，对比历史文件检测内存插槽数量变化并告警（memory 数组长度）
- FR-4.9 运行时模式下，对比历史文件检测内存总容量变化并告警（memory 各插槽 size 之和）

## 3. 非功能需求

### NFR-1 向后兼容性

- NFR-1.1 run.sh 的命令行接口完全不变（所有参数、默认值、退出码）
- NFR-1.2 输出 JSON 结构与重构前完全一致
- NFR-1.3 tsc_raid_health_check.sh 的调用方式和输出格式不变

### NFR-2 可维护性

- NFR-2.1 每个文件单一职责，不超过 200 行
- NFR-2.2 消除重复代码（get_raid_type 只定义一次）
- NFR-2.3 函数无副作用，不依赖全局变量

### NFR-3 可扩展性

- NFR-3.1 新增 RAID 卡支持只需添加一个适配器文件
- NFR-3.2 新增采集项只需添加一个 collector 文件

### NFR-4 可测试性

- NFR-4.1 每个采集器可独立 source 并调用
- NFR-4.2 提供基础测试脚本验证各模块输出格式
- NFR-4.3 RAID 检测和直通盘判断逻辑支持文本文件模拟输入，无需真实硬件即可测试
  - RAID 检测：可通过文本文件模拟 lspci 和 lsmod 输出
  - 直通盘判断：可通过文本文件模拟 lsblk 输出和 sysfs 路径
  - RAID 健康检查：可通过文本文件模拟 storcli/arcconf/sas3ircu 命令输出
- NFR-4.4 测试用例目录结构清晰，每类测试场景对应独立的 fixture 文件夹

### NFR-5 代码注释

- NFR-5.1 每个脚本文件顶部必须有文件级注释，说明文件用途、依赖和提供的函数列表
- NFR-5.2 每个函数必须有注释，说明功能、参数含义、返回值/输出格式
- NFR-5.3 复杂逻辑块（如直通盘判断、RAID 类型检测、MD5 对比机制）必须有行内注释解释判断依据
- NFR-5.4 所有 awk/sed/grep 复杂表达式必须有注释说明匹配目标
- NFR-5.5 告警 key 名称必须有注释说明触发条件

## 4. 约束条件

- C-1 使用 Bash 4.x+（需要关联数组支持）
- C-2 依赖工具: jq, dmidecode, lscpu, lsblk, findmnt, df, free
- C-3 RAID 工具为可选依赖: storcli/storcli64, arcconf, sas3ircu, sas2ircu
- C-4 需要 root 权限（dmidecode, lspci, lsmod）
- C-5 支持 x86_64 和 aarch64 架构

## 5. 验收标准

- AC-1 重构后 run.sh 行数不超过 100 行
- AC-2 在有 RAID 卡的物理机上，输出 JSON 与重构前完全一致
- AC-3 在虚拟机上，输出 JSON 与重构前完全一致
- AC-4 运行时模式下，磁盘数量变化能正确触发告警
- AC-5 软链接和时间戳文件机制正常工作
- AC-6 tsc_raid_health_check.sh 独立运行结果不变
