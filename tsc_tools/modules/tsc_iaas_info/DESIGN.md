# tsc_iaas_info 设计说明（DESIGN）

状态：**修订版 v0.2，评审中**——本文档经确认后，代码改造与 bug 修复均以本文为准。
关联：release-note 2.1.2 的 TODO 11/15；外部依赖方：zabbix（runtime stdout）、collectSar 无关。
v0.2 修订内容见 §11 修订记录。

---

## 0. 设计原则（讨论结论）

1. **契约管输出，实现按分层**：最终文档的形状由契约冻结；适配器内部如何解析（awk/列名定位/jq/厂商 JSON 模式）自选，但必须落在 §4.2 的显式分层里——解析器产出**归一的全量模型**（§3.4），消费端经**通用提取器**取数，不接触厂商原始文本。
2. **修 bug = 让实现符合设计**：TODO 11 的缺陷几乎全部位于解析/JSON 管线层，按本设计重写后自然消失；不在旧形状上打补丁。
3. **stdout 纯 JSON**：本模块及 lib/ 禁止调用 `LOG*`，供 zabbix 等机器消费；人类可读信息一律走 stderr（`--raw-dir` 调试留档）。
4. **失败降级不崩溃**：任何单一来源失败只降级该条目并记录，不得让整份 JSON 缺失；降级粒度下探到解析器的**节**（§4.2）。

## 1. 现状问题（一句话版）

- 解析层占全模块近半、四套实现零复用、无测试兜底（TODO 11 的 7 个缺陷全部在此层）；
- JSON 被当字符串拼（mapfile 按行 + `jq -s` 重组、`-c`/pretty 混用），sas3 故障链的根源；
- 采集端↔alert 端、本次↔上次运行之间靠字段名隐式约定，无 schema 无校验；
- 通用解析助手与 func 重复（common.sh），`detect_system_info` 全仓三处两版。

## 2. 外部契约

### 2.1 冻结不变（一个字符都不能变）

| 项 | 内容 |
|---|---|
| CLI | `tsc --tsc_iaas_info [--runtime] [--cpu_threshold N] [--storage_threshold N] [--memory_threshold N] [--sn S] [--contract_no C] [--location L]` |
| 文件 | `/var/log/tsc/tsc_iaas_info.json` 软链 + `tsc_iaas_info-<ts>.json` 时间戳文件 + MD5 去重语义 |
| runtime stdout | 纯 JSON，顶层含 `warning` 对象，阈值语义不变 |
| 安装互斥 | 检测到 SAS3 卡 → 装 sas3ircu、不装 storcli（已在 packages/install.sh 落地） |
| 顶层既有键 | `storage`（数组）、`memory`（数组）、`cpu`、`sn`、`manufacturer`、`contract_no`、`location` 及 detect_system_info 各键——**键名与位置不变** |
| 阈值语义 | `--*_threshold` 为**百分比**（0–100 整数），入口校验（§5 军规 6） |

> zabbix 消费端（模板/触发器）**尚未建设**：将按本 schema 定稿后的形状新建，无存量断言负担。schema v1 定稿即冻结，此后变更走版本化（`meta.schema_version`）。

### 2.2 允许的变更（需 zabbix 侧对照评审）

| 变更 | 性质 | 说明 |
|---|---|---|
| `storage[]` 条目键统一 | 增量 | 缺失键补 `null`；lsi 条目的 `serial/wwn` 改为**填实际值**（v0.2：`show all` 单抓取后可得，见 §4.4） |
| `storage[]` 条目新增 `size_gb/state_norm/dev` | 增量 | 数值化尺寸（GB）、归一化状态枚举、设备名 |
| 新增顶层 `meta` 对象 | 增量 | `schema_version`、`tool_version`、`generated_at`、`degraded[]`（降级来源记录，粒度见军规 5） |
| 新增顶层 `raid_controllers` 数组 | 增量 | 卡级信息（type/ctl_no/vd_count/pd_count），原先混在 storage 条目里 |
| 新增可选参数 `--raw-dir <dir>` | 增量 | 原始 CLI 输出留档目录，缺省关闭；v0.2 起同时留档全量模型（§4.2） |
| 升级过渡 | 行为 | **不做自动兼容**：升级前手工删除旧历史文件（软链+时间戳文件）；runtime 对历史文件缺失/解析失败一律视为"无历史"（与全新安装同路径，军规 8），不得崩溃 |

## 3. 通用模型（与厂商无关）

### 3.0 骨架文件：schema 的载体（唯一真源）

契约不写在文档里，写成**可执行的两份骨架 + 一个校验模块**，存放于 `lib/schema/`：

```
lib/schema/
  static.tmpl.json    # 静态文档骨架: 全部键与位置固定, 值为 null/空数组;
                      # storage/memory 数组内含 1 个全 null 缺省示例条目(即条目级模板)
  runtime.tmpl.json   # 运行时文档骨架: 含空 warning 结构(键恒在, zabbix 侧形状稳定)
  validate.jq         # jq 模块: 必需键/类型/state_norm 枚举校验(不引入 ajv/node)
```

- **填充** = jq 深合并 `$tmpl * $data`：数据胜出、模板补缺；采集器失败时骨架 null 原样保留（降级语义天然成立）；数组整体替换，条目级合并用骨架内的示例条目作模板（`$t.storage[0] * $entry`），单一真源；
- **校验** = `validate.jq` 对填充结果做必需键/类型/枚举/键集合检查——storage、raid_controllers、mountpoint 条目的键集合须与骨架示例条目**完全一致**，多余键视为适配器/采集器缺陷（新增键须同步骨架与本文件，见 README_DEV §6 演进手册）：测试期必须全绿；运行期校验失败记入 `meta.degraded`，不崩溃；
- 本文档 §3.1–§3.4 的 JSON 仅为**节选示意**，完整骨架以 `lib/schema/*.tmpl.json` 为准（实现落地时本文相应改为引用）。

### 3.1 盘条目（`storage[]` 统一形态，缺省键补 null）

```jsonc
{
  "dev": "/dev/sda",          // 直盘必有; RAID 管理下的 PD 为 null
  "type": "raid",             // "raid" | "direct"（现行值，保留）
  "ctl_no": 0, "enc": 0, "slot": 3,
  "vd": "vd0",                // 所属虚拟盘, 无则 null
  "state": "Online",          // 原始状态, 保留厂商原文
  "state_norm": "online",     // 归一化枚举: online|rebuild|degraded|failed|missing|unknown
  "size": "893.156", "unit": "GB",   // 现行字段, 保留
  "size_gb": 893,             // 新增, 数值化, 供比较与排序
  "model": "...", "serial": "...", "wwn": "...",
  "interface": "SAS"          // 可选
}
```

`state_norm` 由解析器映射（厂商状态词表 → 枚举），词表收在各卡解析器内并随 fixture 测试锁定。

### 3.2 控制器条目（新增 `raid_controllers[]`）

```jsonc
{ "type": "lsi", "ctl_no": 0, "name": " MegaRAID 9560-16i", "vd_count": 1, "pd_count": 8, "health": "OK", "health_norm": "online" }
```

`health` 保留厂商原文，`health_norm` 与 `state_norm` 共用归一枚举（v0.2 补）。

### 3.3 排序契约

`storage[]` 输出前固定 `sort_by(.ctl_no, .enc, .slot, .dev)`；`raid_controllers[]` 按 `.type,.ctl_no`。
目的：同机器两次采集输出逐字节稳定，保 MD5 去重语义（顺带治 awk 遍历序不稳）。
MD5 对比**忽略 `meta.generated_at`**（时间戳不参与内容比对），否则骨架引入时间戳后去重永久失效。
排序键 `ctl_no/enc/slot/dev` 同时是跨运行比对的定位键——排序契约、MD5 去重、历史比对三方共用同一组键定义。

### 3.4 全量模型（卡的内部接口，v0.2 新增）

每张卡一次全量抓取（§4.4）后，解析器产出**每控制器一个对象**的归一全量模型。它是"卡解析器"与"通用提取器/消费端"之间唯一的接口：

```jsonc
{
  "card": "lsi",              // 卡型
  "ctl_no": 0,
  "controller": {             // §3.2 形状 + 归一健康; direct 卡无控制器, 为 null
    "type": "lsi", "ctl_no": 0, "name": "AVG-9361-8i",
    "health": "Opt", "health_norm": "online",
    "vd_count": 1, "pd_count": 4
  },
  "pds": [ /* §3.1 盘条目形状, type 恒 "raid" */ ],
  "vds": [                    // VD 级状态(告警主对象之一)
    { "vd": "vd0", "state": "Optl", "state_norm": "online",
      "raid_level": "RAID1", "pd_slots": ["252:0", "252:1"] }
  ],
  "sections_failed": []       // 本控制器内解析失败的节名, 如 ["vds"]; 空数组=全节成功
}
```

性质与约束：

- **归一发生在这一层**：`state_norm`/`health_norm`/`size_gb` 由解析器完成，提取器与消费端不再接触厂商原文；
- **内部接口**：不进 `validate.jq`（外层文档校验不变）；形状由 fixture 断言锁定（§7 验收标准 2）；
- **pds 条目即 §3.1 形状**：`extract_topology` 对 pds 逐条透传（补 `type`），不做二次解析——定位键一致性由构造保证，无需专项测试；
- **按节降级**：解析器内部按 controller/pds/vds 分节独立解析；某节失败记入本对象的 `sections_failed` 并经军规 5 落 `meta.degraded`（来源名 `<card>.<section>`），其余节照常输出。提取器看到的永远是结构完整的模型、某些节为空——失败域不合并；
- direct 卡：`controller`/`vds` 为 null，`pds` 即 lsblk 归一条目（type "direct"）。

## 4. 适配器契约

### 4.1 目录与自注册

```
lib/raid/cards/
  lib.sh        # 公共解析助手(见 §6), 不含任何厂商逻辑
  direct.sh     # 直盘/直通盘(身份走 lsblk//sys 通道)
  lsi.sh        # MegaRAID(storcli)
  sas3.sh       # SAS3 IR(mpt3sas, sas3ircu)
  sas2.sh       # SAS2 IR(mpt2sas, sas2ircu)  ← 补齐现行缺失的采集分支
  adaptec.sh    # Adaptec(arcconf)
lib/raid/
  extract.sh    # 通用提取器(§4.2), 与卡型无关, 全卡共用
  detector.sh   # 注册遍历 + SAS3 互斥规则 + 聚合(§7)
```

每个卡片文件 source 时自注册：`TSC_CARD_TYPES+=(sas3)`。框架遍历注册表逐一 `card_<type>_detect`，取代 detector.sh 中的 if/elif 硬编码链。

### 4.2 分层契约（v0.2 重写，取代 v0.1 三函数契约）

每卡必须实现的函数收敛为两个；"topology/health"从每卡代码降级为通用提取器：

| 函数 | 归属 | 语义 | 输出 |
|---|---|---|---|
| `card_<t>_detect` | 每卡 | 本机是否存在该卡 | 退出码：0=存在 / 非0=不存在；无 stdout |
| `card_<t>_parse` | 每卡 | 抓取（§4.4）+ 序列化为全量模型（§3.4） | 每控制器一行全量模型 JSON（`json_line`） |
| `extract_topology` | 通用 | 全量模型 → 静态投影 | 每行一个 `storage[]` 条目 + 每控制器一个 `raid_controllers[]` 条目（`jq -c`） |
| `extract_health` | 通用 | 全量模型 → runtime 投影 | 每行一个健康对象（`jq -c`），形状见下 |

`extract_health` 输出形状（节选示意，阶段 2 定稿，zabbix 未建无存量负担）：

```jsonc
{ "kind": "pd",  "card": "lsi", "ctl_no": 0, "enc": 252, "slot": 0, "dev": null,
  "vd": "vd0", "state": "Onln", "state_norm": "online" }
{ "kind": "vd",  "card": "lsi", "ctl_no": 0, "vd": "vd0",
  "state": "Optl", "state_norm": "online" }
{ "kind": "ctl", "card": "lsi", "ctl_no": 0, "health": "Opt", "health_norm": "online" }
```

约束：

1. 解析方式自选（默认：文本 + 按表头列名定位，见 §6），但**必须产出 §3.4 归一全量模型**——提取器通用的前提是模型形状统一，每卡自定义形状即分层失效；
2. **按节解析、按节降级**（§3.4）：某节失败不得影响其余节输出；
3. 检测不到卡/命令缺失 → `parse` 输出空，**不得输出报错文本到 stdout**（人类可读报错走 stderr）；
4. 任何厂商状态值必须经 `state_norm`/`health_norm` 词表归一；
5. **提取器只投影，不判断**：跨运行比对、阈值/状态告警判断属于 monitors/runtime_main，提取器不得生长业务逻辑；
6. 调用路径：detector.sh 提供 `raid_models_json`（遍历在位卡型、逐卡 `parse`、聚合为全量模型数组——**每卡只抓一次厂商 CLI**，§4.4）与 `raid_collect <extractor> [models]`（逐模型套提取器输出行流）。资产路径 `raid_topology_json`、runtime `raid_health_json` 均可接受同一份 models 数组派生——runtime 一轮轮询内对比(块D)与健康(块C)共用一次抓取；
7. **通道所有权（防双重上报）**：direct 适配器必须排除 RAID/HBA 管理的设备（v1 `_is_direct_disk` 四条件平移，锁定于 fixture 测试）；一块物理盘在 `storage[]` 中只允许出现一次，归属由 direct 通道的排除法保证。已知残余风险：不在 LSI|DELL|HP|AVAGO 名单且 lspci 行无 RAID 关键词的卡型下挂盘可能被误判直盘（v1 同风险，平移不扩大）。

### 4.3 卡型间规则

- **互斥规则**（与 packages/install.sh 安装规则一致）：检测到 SAS3 卡时，storcli/lsi 通道不参与本机盘采集——storcli 对 SAS3 IR 卡的状态读取不准；
- **已确认限制**（2026-09-29 评审确认）：现役环境不存在"MegaRAID 与 SAS3 HBA 并存"的双卡机型，本规则维持不变。未来若出现此类机型，仅需调整本条规则与 packages/install.sh 的安装规则，不影响契约其他部分。

### 4.4 抓取命令矩阵（v0.2 新增：每卡一次全量抓取）

全量模型的数据源，每卡**一次抓取含全部所需字段**（身份+状态+VD/控制器），多控制器逐控制器执行：

| 卡型 | 命令 | 备注 |
|---|---|---|
| direct | `lsblk -Pdo NAME,MODEL,SERIAL,SIZE,TYPE,VENDOR,TRAN,WWN` | 身份走 lsblk//sys 通道；状态由"可枚举"推定 online |
| lsi | `storcli /c<N> show all` | 含 System Overview（控制器健康）、VD 属性（State/RAID 级别）、每盘 Drive Detailed Information（State/Model/**Serial No**/WWN）；控制器号从 System Overview 表头经 `col_by_header` 定位（根治 v1 抓 `====` 的缺陷） |
| sas3 | `sas3ircu <N> DISPLAY` | 含 IR Volume State、每盘 State/Model/Serial No/GUID |
| sas2 | `sas2ircu <N> DISPLAY` | 同 sas3 家族 |
| adaptec | `arcconf GETCONFIG 1` | LD 与 PD 段同源一次抓取 |

> 成本依据（2026-09-30 评审结论）：一次厂商 CLI 调用的成本在进程启动+控制器通信，文本解析毫秒级可忽略；单抓取不增加调用次数，输出增大不构成负担。runtime 高频轮询与静态采集用**同一抓取**，不做轻量/重量两套。

## 5. JSON 管线军规（全模块强制）

1. JSON 只能由 `jq` 构造（`jq -n --arg/--argjson` 或 common.sh 现有助手），**禁止手拼字符串**；
2. 对象流转一律紧凑单行（`jq -c`）；**禁止**对 JSON 文本做 mapfile/sed/grep 按行拆拼——sas3 崩溃链的根源，一次根治；
3. **文档先立骨架后填数**：输出 = `$tmpl * $data`（§3.0），适配器/采集器输出与骨架合并，不允许绕过骨架直接输出文档；
4. 数组输出前按 §3.3 排序；
5. 单来源失败 → 骨架 null 保留 + `meta.degraded[]` 记一条（来源+原因），整体继续；来源粒度允许下探到解析器的节（`<card>.<section>`，§3.4）；
6. 阈值参数为百分比，入口处校验 0–100 整数，非法值直接 usage 报错退出（防 `jq --argjson` 轰炸 runtime）；
7. `--raw-dir` 开启时，每次探测的厂商 CLI 原始输出按 `<ts>/<tool>-<ctl_no>.txt` 留档；**并落全量模型** `<ts>/<card>-<ctl_no>-full.json`（现场调试与金样例生成共用）；
8. 历史文件缺失或解析失败 → 一律视为"无历史"（硬件变更对比跳过），不得崩溃——全新安装、手工清理后的机器与升级过渡期走同一条路径。

## 6. 公共解析助手（cards/lib.sh，解析器专用）

| 助手 | 作用 | 针对的旧病 |
|---|---|---|
| `col_by_header <输出> <表头行正则> <列名...>` | 从实际输出的表头行里定位列号，替代写死 `$9` | 厂商换版本挪列位导致老解析算错 |
| `to_gb <size> <unit>` | "893.156 GB"/"8388608 MB" → 数值 GB | lsblk 单位非 T/G 时整体崩溃 |
| `state_norm <vendor-state>` | 厂商状态词表 → 归一枚举 | 假告警（如把卷号当状态） |
| `json_line <jq表达式...>` | 强制 `jq -c` 的出口封装 | pretty/compact 混用 |

## 7. 目标结构与测试

```
lib/
  common.sh        # 常量(INVALID_SNS)
  schema/
    static.tmpl.json   # 静态骨架(§3.0)
    runtime.tmpl.json  # 运行时骨架(§3.0)
    validate.jq        # 必需键/类型/枚举/条目键集合严格校验(§3.0)
  jsonio.sh        # §5 军规封装(降级文件背书/collect_json/骨架填充/校验)
  raid/
    cards/         # §4.2: 每卡 detect + parse(公共助手 cards/lib.sh; sas2/sas3 共享 sas_ir.sh)
    extract.sh     # §4.2: extract_topology / extract_health(通用提取器)
    detector.sh    # 注册遍历 + SAS3 互斥 + raid_models_json/raid_collect/两路聚合
  collectors/      # 静态采集(cpu/memory/system), 只产通用模型小 JSON
  monitors/        # runtime(cpu/memory/storage 挂载点), 只消费通用模型
  static_main.sh   # 资产模式编排
  runtime_main.sh  # runtime 编排 + 告警生成(阈值/RAID 状态/硬件变更)
tests/
  test_framework.sh    # mock_cmd/mock_cmd_switch(PATH 前插 wrapper) + 断言(失败即退)
  fixtures/<card>/     # 厂商 CLI 输出样例(当前为合成样例, 真机输出按 §6b/README_DEV 替换)
  test_card_direct.sh  # 卡适配器两层断言: raw→parse(全量模型)字段校验;
  test_card_lsi.sh     #   parse 产物→提取器→投影字段校验; 降级/互斥/排序契约
  test_card_sas3.sh    #
  test_card_sas2.sh    #
  test_card_adaptec.sh #
  test_monitor_storage.sh  # 挂载点监控(含空格路径, TODO15 修复锁定)
  test_schema.sh       # 骨架自洽 + validate.jq 自测(好例通过/坏例拦截/多余键拦截)
  try_card.sh          # 真机文本试跑口子(README_DEV §6b): raw 目录 → 四段输出
```

验收标准（每张卡迁完即验收）：

1. `shellcheck` 通过（全模块纳入 CI，gitea/jenkins 已有）；
2. 两层 fixture 断言测试通过：给定 CLI 输出，`parse` 产物（全量模型）关键字段逐项断言；全量模型经提取器的投影关键字段逐项断言（金样例文件比对为可选演进，当前为断言式实现）；
3. 同机器连续两次静态采集 MD5 相同（排序确定性）；
4. 契约冻结清单（§2.1）逐项 diff 确认未变。

## 8. 迁移顺序与 TODO 11 缺陷归宿

| 步骤 | 内容 | 顺带消失的缺陷 |
|---|---|---|
| 0 | jsonio.sh + cards/lib.sh + test_schema.sh 落地 | — |
| 1 | direct 适配器（最简，验证契约与测试框架） | lsblk SIZE 非 T/G 崩溃 |
| 1b | **direct 按 v0.2 契约重构**：card_direct_parse（lsblk 归一）+ extract.sh 通用提取器接入，两层断言测试建立——以最小卡型验证分层契约后再迁 RAID 卡 | — |
| 2 | lsi（`/cN show all` 单抓取 + 列名定位；fixture 换现役机器 show all 输出；serial/wwn 填真值；`extract_health` 形状随本步定稿）；runtime 骨架补 `storage` 键与 warning 全部存储类告警键（§2.1：v1 runtime 顶层本有 storage，v2 不得缺） | storcli 控制器号抓到 `====` |
| 2.5 | 块 B：挂载点监控 `monitor_mountpoints` 迁移（findmnt+df 容量/inode/可写性，`storage_threshold` 的真实语义），修 TODO 15（findmnt 空格挂载点静默跳过 → `-r` raw 模式 + `\x20` 反转义） | findmnt 空格挂载点 |
| 3 | sas3（DISPLAY 单抓取） | pretty-JSON 崩溃链、VD 解析错误、多控制器覆盖 |
| 4 | sas2（DISPLAY 单抓取） | mpt2sas 无采集分支 |
| 5 | adaptec（GETCONFIG 1 单抓取） | awk `for(a in r)` 遍历序 |
| 6 | run.sh 入口 | 阈值百分比（0–100）校验；`--sn` 补进 usage |
| — | 独立修复（不等迁移） | `--runtime` 采集失败遗留空文件：写入前先落临时文件 |

> runtime 存储告警共四路，块划分见评审记录：①挂载点阈值（块 B，storage_threshold 真实语义）；②RAID 状态告警 warning.raid_status（块 C，消费 extract_health，state_norm ∈ {degraded,rebuild,failed,missing}）；③存储硬件变更对比 pd_cnt_diffrent/direct_disk_cnt_diffrent（块 D，数量级，语义与 v1 一致）；④RAID 状态快照 storage.raid（v1 顶层 storage.raid 平移）。管线（collect_json/骨架/校验）与静态路径共用。

## 9. 开放问题

### 9.1 2026-09-29 评审（全部关闭）

1. ~~双卡机型~~ **已确认**：现役环境不存在"MegaRAID + SAS3 HBA 并存"的机型，SAS3 互斥规则维持不变（§4.3），无需按控制器粒度归属。
2. ~~zabbix 模板核对~~ **已确认**：zabbix 消费端尚未建设，将**按本 schema 定稿后的形状新建**，无存量断言负担；schema v1 定稿即冻结（§2）。
3. ~~阈值语义~~ **已确认**：`--*_threshold` 固定为**百分比**（0–100 整数），写入 usage 与入口校验（§5 军规 6）。
4. ~~旧历史 JSON 的升级过渡~~ **已确认**：**不做自动兼容**。升级前由运维手工删除旧历史文件（软链与时间戳文件）；runtime 对历史文件缺失/解析失败一律视为"无历史"（军规 8），与全新安装同路径。`meta.schema_version` 保留为格式标记（信息性字段）。

### 9.2 2026-09-30 架构评审（本轮讨论，全部关闭，落入 v0.2）

1. **runtime/静态复用边界**：适配器层（cards + 助手 + 探测互斥 + 管线）两条路径全共用；差异只在消费的投影（topology/health），不在代码归属。
2. **"解析开销"论点作废**：厂商 CLI 调用成本主导，文本解析可忽略——分层理由不含性能因素；同时单抓取不增加调用次数。
3. **lsi 单抓取升级**：`/cN show all` 含 VD/PD 全量字段（Serial No/WWN 在内），§2.2 的 lsi serial/wwn 由"补 null"改为"填真值"；fixture 需换现役机器 show all 输出。
4. **全量模型分层**（§3.4/§4.2）：detect+parse 二函数契约 + 通用提取器；取代 v0.1 三函数契约与"解析方式自选"的表述。
5. **故障隔离新位置**：从"两个函数"移到"解析器内按节降级"（§3.4 sections_failed + 军规 5），失败域不合并。
6. **提取器只投影不判断**（§4.2 约束 5）；全量模型为内部接口，fixture 断言锁定，不进 validate.jq。

## 10. 非目标

- 不换语言、不改打包模型（makeself）；
- 不引入新的外部依赖（smartctl 保持可选增强，不作为必需项）；
- 不改变 collectSar 等其他模块；
- 不在本轮解决"加新卡型"以外的扩展（如 NVMe fabric 特有属性），契约已为其留位。

## 11. 修订记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v0.1 | 2026-09-29 | 初稿；四项开放问题评审关闭 |
| v0.2 | 2026-09-30 | 架构修订（§9.2）：①契约从三函数改为 detect+parse + 通用提取器，新增全量模型层（§3.4/§4.2）；②每卡单抓取矩阵（§4.4），lsi 升级 show all，serial/wwn 填真值（§2.2）；③按节降级（军规 5/§3.4）；④--raw-dir 增落全量模型（军规 7）；⑤两层金样例测试（§7）；⑥§0 原则 1 由"契约管输出不管实现"改写为"契约管输出，实现按分层" |
| v0.2.1 | 2026-10-01 | 核查修订：①detector 新增 `raid_models_json` 单次抓取缓存，runtime 一轮轮询内对比/健康共用一次抓取（§4.2 约束6/§4.4）；②validate 升级条目键集合严格校验，多余键拦截（§3.0） |
