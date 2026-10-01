# tsc_iaas_info_v2 开发者文档 (README_DEV)

> 本文讲**代码怎么工作、怎么改**。外部契约/适配器契约/迁移计划见 [DESIGN.md](../tsc_iaas_info/DESIGN.md)（v0.4）。
> 模式命名：`--runtime` 为 runtime 模式；不带 `--runtime` 为**资产模式**（原"静态模式"，2026-09-30 定名）。

---

## 1. 两种模式与共用边界

run.sh 解析参数后一个 if 分流：

```
tsc --tsc_iaas_info_v2 [--runtime]
 ├─ 资产模式:  static_main      → 产出文档 → 校验 → 落盘 + MD5 去重 + 软链
 └─ runtime :  run_runtime_monitor → stdout 纯 JSON（zabbix 消费）
```

| 共用（一份代码两条路径） | 资产模式独有 | runtime 独有 |
|---|---|---|
| 采集器 collectors/{cpu,memory,system}.sh | raid 适配器（topology 投影） | monitors/{cpu,memory}.sh（/proc 差值） |
| jsonio 管线（collect_json/降级/骨架填充/validate） | sn/contract/location 历史继承 | 阈值告警 + 硬件变更对比 |
| schema 骨架 + validate.jq | 落盘/MD5/软链 | stdout 输出 |

runtime 存储监控已全部接通（阶段 2.5 完成）：挂载点监控消费 `storage_threshold`（块 B），RAID health 投影已接入（块 C/D），详见 lib/runtime_main.sh。

## 2. 资产模式数据流（四层职责，每层只干一件事）

```
run.sh
 └─ static_main 编排: 每个来源经 collect_json 包装
 │    采集器(标量→小JSON) × 7 + 适配器链(storage)
 ├─ degraded_sync + generated_at + tool_version
 └─ jsonio_build_static: 骨架 × 数据 合并 + 排序        ← 字段在这里"填入"骨架
run.sh: jsonio_validate(static) → tee 落盘 → MD5 去重 → ln -sf
```

| 层 | 文件 | 职责 | 禁止 |
|---|---|---|---|
| 采集器 | lib/collectors/*.sh | bash 标量 → 键齐全的小 JSON；`jq -rcn --arg/--argjson` 直构 | 接触骨架、调用 LOG* |
| 包装 | lib/jsonio.sh `collect_json` | 跑采集器 → `jq -c` 规范化 → 失败/空/非法输出降级 `{}` 并记降级 | 业务逻辑 |
| 编排 | lib/static_main.sh, lib/runtime_main.sh | 顺序调用、收尾（degraded_sync/时间戳/版本号）、传参组装 | 解析细节 |
| 组装 | lib/jsonio.sh `jsonio_build_static/runtime` | 骨架 × 数据 深合并 + 条目级模板 + 排序契约 | 手写文档形状 |
| 校验 | lib/schema/validate.jq | 必需键/类型/state_norm 枚举；失败=实现缺陷直接退出 | — |

## 3. 关键机制

### 3.1 collect_json 与降级文件背书

```bash
out="$("$@" 2>/dev/null | jq -c . 2>/dev/null)" || rc=$?
```

- `|| rc=$?` 吸收失败（errexit 不中断），`pipefail` 让采集器自身的失败也能被探测（没有 pipefail 只看 jq 的 rc）；
- 判降级三条件：rc≠0 / 输出空 / 输出非法 JSON（`jq -c .` 解析失败）；
- **为什么降级写文件**（`degraded_add` → `TSC_DEGRADED_FILE`）：collect_json 运行在编排层的命令替换子 shell 里，数组追加传不回父进程；文件是唯一穿透子 shell 的通道。编排收尾 `degraded_sync` 把文件读回数组再进 `meta.degraded`。适配器链（收集器→提取器→聚合）嵌套更深，同样依赖这条通道。

### 3.2 存储链路的单次抓取

detector.sh 三个入口：`raid_models_json`（逐在位卡 `parse`，聚合为全量模型
数组——**每卡只抓一次厂商 CLI**）、`raid_topology_json [models]`、
`raid_health_json [models]`。runtime 编排先取 models 数组一次，再派生两个
投影（topology 喂硬件变更对比、health 喂快照与状态告警），保证一轮轮询内
不重复抓取；资产路径不带参数调用（自行抓取一次）。

### 3.3 骨架填充：为什么不用 `--arg` 手写直构

采集器层输入是 bash 标量，用 `jq -rcn --arg` 直构（如 collect_cpu_info）；组装层输入是**多份 JSON 文档 + 可变长条目数组**，手写直构会退化成 35 个字段逐个 `// null` 人肉兜底。骨架 `*` 合并把以下四件事变成结构保证：

1. **键位契约单一真源**：文档形状只定义在 `static.tmpl.json`（validate.jq 与测试校验同一套）；
2. **降级不缺键**（军规5）：来源降级 `{}` → 该组键保持骨架 null，零兜底代码；
3. **条目级模板**：数组条目缺键自动补 null（§3.3）；
4. **排序契约集中**：sort_by 在组装层一处执行（§3.4）。

v1 的教训（无骨架的扁平 `+` 拼接）：键存在性靠采集器自觉、下游 alert.sh 踩缺键报错（2.0.5 修的层级问题）、遍历序不定破坏 MD5（TODO 15）。

### 3.4 条目级模板合并

```jq
[$t[0].memory[0] as $tpl | $mem.memory[] | $tpl * .]
```

- `$tpl` = 骨架里的全 null 示例条目；`$tpl * .` 对每个数据条目：条目值胜出、模板补齐缺键 → 每条键位齐全；
- 数据数组为空 → 结果 `[]`，**示例条目不泄漏**进输出（迭代的是数据，模板只做合并底版）；
- 数据整体降级 `{}` → 空数组（注意：cpu/mem 来源降级时组装层会崩，见 §5 已知缺陷 #1；storage 来源天然安全）。

### 3.5 排序契约与 MD5

- `memory` 按 `.locator`；`storage` 按 `.ctl_no,.enc,.slot,.dev`（jq 全序中 null 排在数字/字符串前 → direct 盘按 dev 成组、RAID 盘按槽位在后，混合机器输出同样确定）；
- MD5 去重对比前 `del(.meta.generated_at)`——时间戳不参与内容比对；
- 排序键同时是跨运行比对的定位键，三方（排序/去重/比对）共用同一组键定义（DESIGN §3.3）。

### 3.6 jq 使用约定（踩过的坑）

- **`jq -n` 必须**：组装类调用不消费 stdin；无 `-n` 时命令替换场景 stdin 为空 → filter 一次不执行 → **静默输出空且 rc=0**；
- `--argjson` 对非法 JSON 直接报错退出（闸口：坏数据在这里爆，不会静默混入）；`--arg` 保留字符串语义；
- 采集器输出一律 `jq -rcn`（或经 collect_json 的 `jq -c .` 二次兜底）保证紧凑单行（军规2）。

## 4. 实例：cpu 字段从命令到 JSON 的完整链路

```
run.sh: doc="$(static_main ...)"
 ├─ static_main: cpu_json="$(collect_json "cpu" collect_cpu_info)"
 │   └─ collectors/cpu.sh collect_cpu_info:
 │        cpu_model = /proc/cpuinfo "model name" → sort -u 去重 → 去前导空格
 │        cpu_cnt   = lscpu "Socket(s)"          (物理插槽数, 非逻辑核)
 │        产出 {"cpu":{"cpu_model":"...","cpu_cnt":N}}
 ├─ jsonio_build_static(cpu_json 作第6参):
 │    --argjson cpu → jq 程序内: .cpu = ($t[0].cpu * $cpu.cpu)
 │    骨架 {"cpu_model":null,"cpu_cnt":null} 被数据两键覆盖(数据胜出)
 └─ validate.jq: .cpu 必须是对象、两键必须存在、类型正确 → tee 落盘 → MD5
```

memory/storage/sn 走同一条路，只是采集器与合并方式不同（数组走条目级模板，标量组走主合并）。

## 5. 已知缺陷与边角（评审记录，2026-09-30）

| # | 现象 | 定性 | 处置 |
|---|---|---|---|
| 1 | ~~cpu/memory 来源降级为 `{}` 时组装层崩溃~~ | **已修** | 组装层 `($cpu.cpu // {})`、`($mem.memory // [])` 兜底 |
| 2 | 采集器输出空串（如 /proc/cpuinfo 缺失 → cpu_model=""）会覆盖骨架 null——"空串"与"采集失败(null)"是两种失败形态 | 语义边角 | 暂保留（与 v1 一致），如需区分在采集器内归 null |
| 3 | dmidecode 缺失时 memory=[] 且**不记** degraded——"成功但空"与"失败"不区分 | 语义边角 | 待定 |
| 4 | 同机两种 CPU 型号时 cpu_model 为含换行字符串（sort -u 多行） | 与 v1 一致 | 保留 |
| 5 | ~~采集器多吐的键会经 `*` 合并混入文档~~ | **已修** | validate 升级键集合严格校验：storage/raid_controllers/mountpoint 条目键集合须与骨架示例条目完全一致，多余键拦截（test_schema 3 例锁定） |
| 6 | ~~`--storage_threshold` 已解析校验但 runtime 存储监控未接~~ | **已修** | 阶段2.5 已实现（monitor_mountpoints + raid_health_json 全部接通） |
| 7 | lsi/sas_ir/adaptec 的 PD 条目 `ctl_no` 恒 0（硬编码），多控制器机器 `storage[].ctl_no` 失真 | 一机多卡不支持（DESIGN §10，2026-10-01 决策） | 关闭，不改代码 |

## 6. schema 演进操作手册（加项/改项照单执行）

**总原则**：条目级加键 → 组装层零改动；顶层加项 → 组装层加一行；机制层（collect_json/降级/去重/软链/run.sh 参数）永不动。

### 6.1 修改已有项（例：memory 条目加 `manufacturer`）

1. **骨架** `static.tmpl.json`：memory 示例条目加 `"manufacturer": null`
2. **校验** `validate.jq`：memory 的 `all(...)` 加 `has("manufacturer")` + 类型检查
3. **采集** `collectors/memory.sh`：改 grep 模式（Size/Locator/Manufacturer 三行一组）与配对逻辑——**工作量最大的一步**；dmidecode 无厂商输出 "Unknown"，是否归 null 自定
4. **组装**：不用动（`$tpl * .` 自动吸收新键）
5. **测试**：test_schema.sh 填充样例补键
6. **影响确认**：新键改变内容 → 下次采集 MD5 变 → 落新文件（预期）；旧历史文件无该键 → 读为 null → 对比不告警（军规8 路径天然兼容）；schema 未冻结直接加，冻结后需 bump `meta.schema_version`

### 6.2 新增顶层项（例：`display_cards` 条目数组）

1. **骨架**：加 `"display_cards": [ {全null示例条目} ]`
2. **校验**：validate_static 加 `(.display_cards | _arr) and all(...)`
3. **采集**：新建 `lib/collectors/display_card.sh`（纯 JSON stdout），产出 `{display_cards:[...]}`
4. **接线**：run.sh 加 source 一行
5. **编排**：static_main 加 `gpu_json="$(collect_json "display_card" collect_display_card_info)"`——自动获得降级+degraded
6. **组装**：jsonio_build_static 加 `--argjson gpu` 参数 + jq 程序一行
   `.display_cards = [$t[0].display_cards[0] as $tpl | $gpu.display_cards[] | $tpl * .]`
   （需要确定性再加一行 sort_by）——**顶层项比条目级键多的就是这一行**
7. 测试/影响确认同 6.1 第 5-6 步

标量型顶层项（如只需数量）：第 6 步改为在主合并追加 `+ $gpu`。

## 6b. 真机文本测试口子（try_card.sh）

**给每张 RAID 卡留的文本测试入口**：不改任何代码，把现役机器抓取的厂商 CLI
原始文本喂给对应适配器，直接看全量模型/投影/schema 校验结果。

```bash
# 1. 在现役机器上抓取(以 lsi 为例)
storcli show > show.txt
storcli /c0 show all > c0_show_all.txt      # 每控制器一份: c0_..., c1_...

# 2. 按命名约定放进一个目录, 传给 try_card.sh
mkdir -p /tmp/real_lsi && mv show.txt c0_show_all.txt /tmp/real_lsi/
bash tests/try_card.sh lsi /tmp/real_lsi
```

命名约定(缺哪个文件, 对应节即按设计降级——正好验证容错):

| 卡型 | 文件 | 对应命令 |
|---|---|---|
| direct | `lsblk.txt` | `lsblk -Pdo NAME,MODEL,SERIAL,SIZE,TYPE,VENDOR,TRAN,WWN` |
| lsi | `show.txt` + `c<N>_show_all.txt` | `storcli show` + `storcli /c<N> show all` |
| sas3 | `list.txt` + `display<N>.txt` | `sas3ircu list` + `sas3ircu <N> display` |
| sas2 | `list.txt` + `display<N>.txt` | `sas2ircu list` + `sas2ircu <N> display` |
| adaptec | `getconfig<N>.txt` | `arcconf GETCONFIG <N>` |

输出四段：**detect 结果 → 全量模型 → 两个提取器投影 → 组装+schema 校验**；
末尾显示降级记录（`sections_failed` 或适配器失败的节一目了然）。
原始文件允许 CRLF（脚本自动转 LF 副本，源文件不动）；
真机抓取需 root（dmidecode/dmidecode 类工具同理）。

**确认无误后**：将原始文本复制为 fixture 替换 `tests/fixtures/raid/<卡>/` 下
合成样例（按 test_card_<卡>.sh 里 mock_cmd_switch 的文件名约定），复跑
`bash tests/test_card_<卡>.sh` 锁定。这就是 DESIGN §8 步骤 2/3/4 的
"现役机器输出替换 fixture" 前置要求的操作入口。

`--no-validate` 可跳过第 4 段；direct 卡的 `_is_direct_disk` 条件 4 会读
试跑机器的真实 sysfs/lspci（fixture 文件名不参与该判定），跨机器试跑时留意。

## 6c. 真机测试清单（建议按序执行）

1. **单卡口子试跑**：每张在位卡按 §6b 抓取原始文本 → `try_card.sh <卡> <目录>`；
   核对四段输出——全量模型的盘数/型号/serial 与真机一致、schema 校验通过、
   降级记录为空（或仅为预期的缺节）；
2. **fixture 替换转正**：按各 `test_card_<卡>.sh` 里 mock 的文件名约定复制到
   `tests/fixtures/raid/<卡>/`，复跑 `bash tests/test_card_<卡>.sh`；
3. **资产模式 e2e**：`tsc --tsc_iaas_info_v2` → 检查
   `jq . /var/log/tsc/tsc_iaas_info_v2.json` 的 storage/raid_controllers 与
   真机硬件一致；连续跑两次，确认第二次只更新软链（MD5 去重）；
4. **runtime e2e**：`tsc --tsc_iaas_info_v2 --runtime`（可加
   `--storage_threshold 0` 验证挂载点告警必触发）→ stdout JSON 的
   storage.mountpoint/raid、warning 8 键恒在；对比历史文件触发盘数量告警；
5. **故障注入抽查**（可选）：临时坏 fixture（截断输出/乱码）喂 try_card，
   确认走 sections_failed 降级而非崩溃（军规 5）；
6. 全部通过后：提交 v2 目录与 DESIGN.md。

## 7. 测试

```bash
bash tests/test_schema.sh           # 骨架自洽 + validate 自测(25 例, 含多余键拦截)
bash tests/test_card_direct.sh      # direct(parse 形态) + 助手 + 降级管线(18 例)
bash tests/test_card_lsi.sh         # lsi 适配器(4 例)
bash tests/test_card_sas3.sh        # sas3 适配器(3 例)
bash tests/test_card_sas2.sh        # sas2 适配器(1 例)
bash tests/test_card_adaptec.sh     # adaptec 适配器(1 例)
bash tests/test_monitor_storage.sh  # 挂载点监控(含空格路径 TODO15, 1 例)
bash tests/try_card.sh <卡型> <raw目录>  # 真机文本试跑口子(见 §6b/§6c)
```

- 厂商命令经 `tests/test_framework.sh` 的 `mock_cmd`（整输出）/
  `mock_cmd_switch`（按参数分发, 如 `storcli show` 与 `/c0 show all`）注入
  fixture——PATH 前插 wrapper；fixture 在 `tests/fixtures/`；
- 卡适配器为**两层断言测试**（DESIGN §7 验收标准 2）：raw → `parse` 产物
  （全量模型）关键字段逐项断言；全量模型 → 提取器 → 投影关键字段逐项断言；
  断言失败立即退出子 shell 判 FAIL（无"仅末条断言生效"的吞失败问题）；
  金样例文件比对为可选演进；
- 全模块 shellcheck 纳入 CI（gitea/jenkins 已有）；
- 真机测试流程见 §6c。

## 8. 已知差距与待办

- v0.2 分层契约已全量实施：五张卡均为 `detect` + `parse`(单抓取→全量模型)，通用提取器 `lib/raid/extract.sh`（extract_topology/extract_health），detector 提供 `raid_collect`/`raid_topology_json`/`raid_health_json`；
- **lsi show all、sas2/sas3 DISPLAY、arcconf GETCONFIG 的 fixture 为合成样例**（基于 v1 fixture 与厂商文档），上真机前应以现役机器实际输出替换并复跑对应 `tests/test_card_*.sh`；
- `--raw-dir` 留档（军规 7）尚未实现。
