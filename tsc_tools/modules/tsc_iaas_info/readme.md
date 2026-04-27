---
category: 系统监控
keywords: 
  - 系统信息
  - 硬件信息
  - CPU
  - 内存
  - 存储
  - 虚拟机
  - 物理机
  - RAID
  - 运行时
  - 告警
  - IaaS
  - 资产
description: 输出系统基本信息, 包括`处理器`, `内存`, `存储`, `操作系统版本`, `是否虚拟机`等, 并保存到 `/var/log/tsc_iaas_info.json`
usage: tsc --tsc_iaas_info [参数]
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

## 测试说明

### 测试框架设计

本模块的测试框架基于 **fixture 文件模拟**，无需真实硬件即可验证 RAID 检测、直通盘判断等复杂逻辑。

核心原理：将 `lspci`、`lsmod`、`lsblk`、`storcli`、`arcconf` 等命令替换为读取文本文件的 wrapper，从而用预置的文本文件模拟真实硬件输出。

### 目录结构

```
tests/
├── test_framework.sh          # 测试框架：mock 机制 + 断言函数
├── test_raid_detector.sh      # RAID 类型检测测试
├── test_direct_disk.sh        # 直通盘判断逻辑测试
├── test_raid_health.sh        # RAID 健康检查解析测试
├── test_alert.sh              # 告警生成逻辑测试
└── fixtures/                  # 模拟输入文件目录
    ├── lspci/                 # 模拟 lspci 输出
    │   ├── lsi_megraid.txt    # LSI/MegaRAID 场景
    │   ├── adaptec.txt        # Adaptec 场景
    │   ├── sas3008.txt        # SAS3 场景
    │   └── no_raid.txt        # 无 RAID 卡场景
    ├── lsmod/                 # 模拟 lsmod 输出
    │   ├── mpt3sas.txt        # 加载了 mpt3sas 模块
    │   ├── mpt2sas.txt        # 加载了 mpt2sas 模块
    │   └── no_raid.txt        # 无 RAID 相关模块
    ├── lsblk/                 # 模拟 lsblk 输出
    │   ├── direct_only.txt    # 只有直通盘
    │   ├── raid_only.txt      # 只有 RAID 逻辑卷
    │   └── mixed.txt          # 直通盘 + RAID 盘混合
    └── raid/                  # 模拟 RAID 工具输出
        ├── lsi/
        │   ├── storcli_show.txt          # storcli show 输出
        │   ├── storcli_c0_show_ok.txt    # 所有盘正常
        │   ├── storcli_c0_show_degraded.txt  # VD 降级
        │   └── storcli_c0_show_failed.txt    # PD 离线
        ├── adaptec/
        │   ├── arcconf_getconfig_ld.txt  # LD 配置（正常）
        │   ├── arcconf_getconfig_pd.txt  # PD 配置（正常）
        │   └── arcconf_getconfig_pd_failed.txt  # PD 故障
        └── sas3/
            ├── sas3ircu_list.txt         # 控制器列表
            ├── sas3ircu_display_ok.txt   # 所有盘正常
            └── sas3ircu_display_rebuild.txt  # 盘在重建

```

### 如何添加新的测试场景

1. **在对应 fixture 目录下创建文本文件**，内容为真实命令的输出（可在目标机器上运行命令后复制）：

   ```bash
   # 在真实机器上采集 fixture 数据
   lspci > tests/fixtures/lspci/my_server.txt
   lsmod > tests/fixtures/lsmod/my_server.txt
   lsblk -Pdo NAME,MODEL,SERIAL,SIZE,TYPE,VENDOR,TRAN,WWN > tests/fixtures/lsblk/my_server.txt
   storcli show > tests/fixtures/raid/lsi/storcli_show.txt
   storcli /c0 show > tests/fixtures/raid/lsi/storcli_c0_show.txt
   ```

2. **在对应测试脚本中添加测试用例**，使用 `mock_cmd` 指向新 fixture 文件：

   ```bash
   test_my_scenario() {
       mock_cmd lspci "${FIXTURE_DIR}/lspci/my_server.txt"
       mock_cmd lsmod "${FIXTURE_DIR}/lsmod/my_server.txt"
       raid_detect
       assert_eq "${RAID_TYPE}" "lsi" "应检测为 LSI RAID"
   }
   run_test "我的服务器场景" test_my_scenario
   ```

### 运行测试

```bash
# 进入模块目录
cd tsc_tools/modules/tsc_iaas_info

# 运行单个测试文件
bash tests/test_raid_detector.sh

# 运行所有测试
for f in tests/test_*.sh; do
    echo "=== 运行 ${f} ==="
    bash "${f}"
done

# 或者一行命令
bash -c 'cd tsc_tools/modules/tsc_iaas_info && for f in tests/test_*.sh; do bash "$f" || exit 1; done'
```

### 测试输出示例

```
=== RAID 类型检测测试 ===
  TEST: LSI/MegaRAID 检测 ... PASS
  TEST: Adaptec 检测 ... PASS
  TEST: SAS3 (mpt3sas) 检测 ... PASS
  TEST: 无 RAID 卡场景 ... PASS

========================================
测试结果: 4/4 通过
========================================
```

### 注意事项

- 测试脚本需要在模块根目录（`tsc_tools/modules/tsc_iaas_info/`）下运行，或通过 `cd` 切换到该目录
- mock 机制通过临时修改 `PATH` 实现，测试结束后自动清理，不影响系统环境
- fixture 文件应尽量来自真实机器的实际输出，确保测试场景的真实性
- 测试脚本本身不需要 root 权限（mock 替代了需要 root 的命令）
