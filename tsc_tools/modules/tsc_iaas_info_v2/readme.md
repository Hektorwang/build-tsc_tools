---
category: 系统监控
keywords:
  - 系统信息
  - IaaS
  - schema
  - v2
  - JSON
description: 系统IaaS信息采集 v2(schema驱动重构, 与tsc_iaas_info平行开发; 阶段1: 非存储部分 + direct存储适配器)
usage: tsc --tsc_iaas_info_v2 [--runtime] [--cpu_threshold 0-100] [--sn S]
---

# tsc_iaas_info_v2

## 定位

与 `tsc_iaas_info`(v1)**平行开发、互不影响**的重构版, 按 `DESIGN.md`(本目录)实施:
骨架驱动的 JSON 输出、适配器契约、fixture 测试。

开发者文档（代码怎么工作/怎么改、schema 演进操作手册、已知缺陷）见 [README_DEV.md](./README_DEV.md)。

## 阶段状态

| 阶段(DESIGN.md §8) | 状态 |
|---|---|
| 0: schema 骨架 + jsonio + 校验 | ✅ |
| 1: direct 适配器 | ✅ |
| 1b: direct 重构为 parse+通用提取器(v0.2 分层) | ✅ |
| 2: lsi(storcli show all 单抓取) | ✅* |
| 2.5: 挂载点监控迁移 + TODO15 修复 | ✅ |
| 3: sas3(DISPLAY 单抓取) | ✅* |
| 4: sas2(DISPLAY 单抓取, 补齐 v1 缺失分支) | ✅* |
| 5: adaptec(GETCONFIG 单抓取) | ✅* |
| 6: run.sh 入口(阈值校验/--sn/usage) | ✅ |

runtime 告警四路已全部接通: 阈值(cpu/内存/挂载点容量/inode/可写)、
RAID 状态告警(warning.raid_status)、存储硬件变更对比(pd/direct 盘数量)、
RAID 快照(storage.raid)。runtime 骨架含 storage 键与全部 8 个 warning 键(恒在)。

带 * 卡型已按 fixture 测试锁定; **lsi 的 show all、sas2/sas3 的 DISPLAY、
adaptec 的 GETCONFIG 为合成 fixture, 上真机前请以现役机器实际输出替换并复跑
对应 tests/test_card_*.sh**(DESIGN §8 步骤 2/3/4 前置)。

## 用法

```bash
source /home/tsc/tsc_profile
tsc --tsc_iaas_info_v2                     # 静态采集
tsc --tsc_iaas_info_v2 --runtime           # 运行时监控
tsc --tsc_iaas_info_v2 --cpu_threshold 80  # 阈值为百分比 0-100
```

## 输出

- 静态: `/var/log/tsc/tsc_iaas_info_v2.json` 软链 + `tsc_iaas_info_v2-<ts>.json`, MD5 去重
- 运行时: stdout 纯 JSON, `warning` 键恒在(未触发为 null)
- 结构以 `lib/schema/*.tmpl.json` 骨架为准; 校验规则见 `lib/schema/validate.jq`

## 与 v1 的行为差异

- 顶层新增 `meta`(schema_version/tool_version/generated_at/degraded)
- `warning` 键恒在(未触发为 null), 不再"触发才出现"
- `memory` 按 locator、`storage` 按 ctl_no/enc/slot/dev 排序, 输出确定性(保 MD5 去重)
- storage 条目键统一补 null, 新增 `dev/state_norm/size_gb/interface`(§2.2)
- lsblk SIZE 任意单位(B/K/M/G/T/P)均数值化, 不再整体采集失败(v1 缺陷)
- 阈值入口校验 0-100

## 测试

```bash
bash tests/test_schema.sh        # 骨架/校验自测(21 例)
bash tests/test_card_direct.sh   # direct(parse 形态) + 助手 + 降级管线(18 例)
bash tests/test_card_lsi.sh      # lsi 适配器(4 例)
bash tests/test_card_sas3.sh     # sas3 适配器(3 例)
bash tests/test_card_sas2.sh     # sas2 适配器(1 例)
bash tests/test_card_adaptec.sh  # adaptec 适配器(1 例)
bash tests/test_monitor_storage.sh  # 挂载点监控(1 例)

# 真机文本试跑口子(不改代码, 按 raw 目录喂真实厂商 CLI 输出):
bash tests/try_card.sh lsi /tmp/real_lsi   # 卡型: direct|lsi|sas3|sas2|adaptec
```
