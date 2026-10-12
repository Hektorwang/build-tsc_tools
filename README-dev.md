# 开发者说明

面向维护/改动 **tsc_tools 打包与部署**的人。终端用户视角的安装、升级、卸载与用法见 [README.md](README.md)。

- 打包模型: 单个 `noarch` RPM, 包内同时携带 `x86_64` 与 `aarch64` 的自带二进制, 安装期按本机架构择优部署。
- scriptlet 语言: RPM 忽略脚本首行 shebang, 一律用 `/bin/sh` 执行(本包要求该 `/bin/sh` 是 bash), 因此 `%pre`/`%post` 里显式 `set +o posix` 退出 POSIX 模式。

---

## 1. 仓库结构(打包相关)

```
build.sh                            唯一打包入口: 解析版本 → stage → 渲染 → nfpm → 产物自检
packaging/rpm/
  nfpm.yaml.tmpl                    nfpm 包定义模板(占位符 @VERSION@ @RELEASE@ @STAGE_DIR@)
  preinstall.sh.tmpl                %pre 模板, 内含 `# >>> INJECT <file>` 注入标记
  postinstall.sh                    %post  (部署二进制 + 写部署清单 + 注入 profile)
  preremove.sh                      %preun (按 hash 清单回收 + 还原 vimrc)
  postremove.sh                     %postun (清理残留空目录壳, 升级跳过)
  env_check.sh                      环境检测与准入校验(单一事实源, %pre 内联 + 随包发布双用)
  lib_min.sh                        最小日志库(只供 %pre 内联, 不随包发布)
.supported_env.conf                 支持矩阵(架构白名单 / 发行版家族 + 主版本)
release-note.md                     版本号来源(文件内第一个 `Version=`)
tsc_tools/                          包内容(payload 源)
  func                              运行期公共库(LOG* 等)
  tsc_profile                       公共空入口(仅 source tsc_profile.d/*.sh, 卸载不删)
  profile                           本包 drop-in(部署到 0-tsc_tools-profile.sh, 含 PATH / TSC_MODULES_DIR)
  lib/env_check.sh                  env_check.sh 的随包副本(构建时放入)
  packages/install.sh               安装期部署逻辑, 由 %post 调用
  packages/<tool>/<tool>-<arch>     自带二进制, <arch> ∈ {x86_64, aarch64, noarch}
  gen_rag.sh                         多工具 rag 生成器(构建期由 build.sh 调, 亦随包发布供目标机运行)
```

---

## 2. 打包工作流程(`./build.sh` 逐步)

| 步骤 | 动作 |
|---|---|
| 1 | 依赖检查: `nfpm`(默认 `/bin/nfpm`, 可用 `NFPM_BIN` 覆盖) 与 `dos2unix`, 缺失即报错退出 |
| 2 | 版本解析: 取 `release-note.md` 第一个 `Version=`; 含 `-` 直接报错(RPM Version 不允许) |
| 3 | 运行 `gen_rag.sh` 生成 `tsc_tools/rag.md` |
| 4 | 把 `README.md` / `release-note.md` / `.supported_env.conf` 拷进 `tsc_tools/`(见 §4.8) |
| 5 | 复制 `tsc_tools/` → `stage/tsc_tools/`, 并把 `packaging/rpm/env_check.sh` 放到 `stage/tsc_tools/lib/` |
| 6 | `stage` 内所有 `*.sh` 统一 `chmod +x` 并 `dos2unix` |
| 7 | 渲染 `%pre`(`render_template` 把 `# >>> INJECT <file>` 换为该文件内容), 复制 `%post` / `%preun` / `%postun` |
| 8 | 对四个 scriptlet 逐个 `bash -n` 语法自检 |
| 9 | 用 `sed` 渲染 `nfpm.yaml` 模板 |
| 10 | `nfpm package --packager rpm` |
| 11 | 产物自检: 包信息 / `Requires` / 文件数 / **两架构自带二进制是否齐全** / `tsc` 可执行位 / 四段 scriptlet 是否写入 |
| 12 | 清理 `stage/`, 打印 `Size` 与 `SHA256` |

产物: `release/tsc_tools-<version>-<release>.noarch.rpm`(`release` 取构建日期 `YYYYMMDD`)。

---

## 3. 四段 scriptlet 语义(改之前必须知道)

| 段 | 文件 | 执行时机 | `$1` |
|---|---|---|---|
| `%pre` | `preinstall.sh.tmpl` | 包文件落盘**之前** | 安装 `1` / 升级 `2+`(本脚本不使用) |
| `%post` | `postinstall.sh` | 包文件落盘**之后** | 安装 `1` / 升级 `2+`(两者步骤相同且幂等) |
| `%preun` | `preremove.sh` | 卸载**之前** | `0` = 真卸载(执行回收) / `>=1` = 升级(直接跳过) |
| `%postun` | `postremove.sh` | 卸载**之后**(RPM 删完包文件后) | `0` = 真卸载(清理空目录壳) / `>=1` = 升级(跳过) |

四个必须理解的设计:

1. **`%pre` 必须自包含**。此刻包内文件尚未落盘, 不能 `source /home/tsc/tsc_tools/func`, 所以 `lib_min.sh` / `.supported_env.conf` / `env_check.sh` 是**内联**进 `%pre` 的文本, 而不是从磁盘读取。
2. **`lib_min.sh` 是 `func` 的 shim**。它只提供 5 个 `LOG*` 与 `is_element_in_array`, 与 `func` 里的同名函数**同名同签名**——`env_check.sh` 因此能在 `%pre`(用 `lib_min.sh`)与 `%post`(用 `func`)两处不改一行地复用。改任一侧的签名或行为, 必须同步另一侧。
3. **`%preun` 在升级时全部跳过**。回收工作交给新包的 `%post` 重建, 避免出现"升级过程中工具被删空"的窗口。
4. **`%preun` 只用 POSIX 语法, 且任何分支都 `exit 0`**。`%preun` 返回非零会让 rpm 拒绝卸载, 让机器卡在"卸不掉"的状态比留下几个文件更糟。
5. **`%postun` 只做目录壳清理**。RPM 删完包文件后, 用 `find <TSC_TOOLS_DIR> -type d -empty -delete` 清掉空目录壳; 升级(`$1>=1`)跳过(新包目录已重建)。`%postun` 也永远 `exit 0`。

---

## 4. 改动本组件时的注意点

### 4.1 新增/删除自带工具

- 目录名 = 工具名, 文件名为 `<tool>-<arch>` 或 `<tool>-noarch`(两种命名混用时 `-<arch>` 优先)。
- 普通工具: 登记到 `tsc_tools/packages/install.sh` 的 `SUPPORTED_BINARY_TOOLS`(值为版本探测参数, 如 `-V`), 部署到 `/bin` 的判定依赖它。
- RAID CLI(`sas3ircu`/`storcli64`/`arcconf`)**不走**该数组, 由 `_install_raid_cli` 按探测结果部署; 清单记录由 `%post` 的 `record_manifest` 按"内容与本包自带二进制一致"补录(此前漏记, 已修正)。
- 删除工具后注意 `build.sh` 的"两架构齐全"断言(§4.2)与 `%preun` 的回收清单。

### 4.2 架构

包是**单个 `noarch`**, 内含两套二进制; 运行期由 `install.sh` 按 `$(arch)` 择优部署, 架构白名单在 `.supported_env.conf` 的 `SUPPORTED_ARCHITECTURES`, 由 `%pre` 校验(`noarch` 无法阻止"任何架构都能装上", %pre 是唯一的架构闸门)。

新增架构需三处同步:
1. `tsc_tools/packages/*/<tool>-<newarch>` 补齐二进制;
2. `.supported_env.conf` 的 `SUPPORTED_ARCHITECTURES`;
3. `build.sh` 产物自检里 `for arch in x86_64 aarch64` 那处断言。

### 4.3 改 `func` 或日志函数

`%pre` **不**内联 `func`(只内联 `lib_min.sh`), 所以改 `func` 不影响安装准入。但 `func` 与 `lib_min.sh` 的 `LOG*` 必须保持同名同签名, 否则 `env_check.sh` 在 `%pre` / `%post` 下行为会分叉。

### 4.4 版本号

只改 `release-note.md` 顶部的 `Version=`, `release` 号自动取构建日期。**不能在版本号里用 `-`**。

### 4.5 部署清单契约 `.installed_manifest`

路径固定为 `<TSC_TOOLS_DIR>/.installed_manifest`, 由 `%post` 先清空, 再各自追加:

| 行格式 | 写入方 | 含义 |
|---|---|---|
| `FILE:<path>:<sha256>` | `%post` 的 `record_manifest` | 包外衍生文件(`/bin/*`、RAID CLI、drop-in、vimrc 等), 卸载时按 sha256 校验一致才删 |
| `LINK:<path>` | `%post` 的 `record_manifest` | 本包创建的别名软链(目前仅 `/bin/storcli`) |
| `VIMRC_BACKUP:<path>` | `packages/install.sh` | 安装时备份的原始 `/root/.vimrc`, 卸载时还原 |

`%preun` 按此清单回收并还原。**改任一侧必须同步这个格式**, 否则卸载会漏回收或误删。

`record_manifest` 只记录"常规文件 + 内容与本包自带二进制一致"的条目(并写其 sha256): 系统自带同名文件/软链一律不记(`install.sh` 的 `\cp` 会穿透软链改写其目标, 若把软链记成 `LINK`, 卸载时会误删系统软链)。`%preun` 回收时按 hash 校验, 不一致(用户/系统改过)则跳过保留。

### 4.6 文件权限

`build.sh` 只对 `*.sh` 做 `chmod +x`; `tsc`、`func`、`tsc_profile`、`profile`、`vimrc` 及各类配置的最终权限 = **源文件 mode & 打包机 umask**。产物自检只断言 `/home/tsc/tsc_tools/tsc` 一个文件可执行。

> 打包机 umask 收紧(如 `0077`)会削掉其余文件权限且不报错。脚本内**未**固定 umask, 需要确定性时可在 `build.sh` 开头加 `umask 022`。

### 4.7 `%pre` 的注入是静默的

`render_template` 用 `awk ... getline` 读被注入文件, **文件不存在时静默输出空**。后果: 产出缺 `SUPPORTED_*` 的 `%pre`, 目标机在 `set -u` 下以 unbound 变量报错, 安装失败, 而**打包期毫无感知**(`bash -n` 查不出运行期错误)。

改动 `packaging/rpm/` 后请确认注入目标文件都存在; 想要硬保证, 可在渲染后加一段断言(检查 `%pre` 里出现 `SUPPORTED_ARCHITECTURES=`、`check_env()` 等关键串)。

### 4.8 打包会写回源码树

`build.sh` 会把 `README.md` / `release-note.md` / `.supported_env.conf` 复制进 `tsc_tools/`。前两个在 `.gitignore` 里, 第三个**是被 git 跟踪的文件**——两份 `.supported_env.conf` 内容不一致时, 每次打包都会把工作树弄脏。

### 4.9 产物不签名

当前不做 GPG 签名, 产物 `SIGPGP=(none)`。裸 `rpm -ivh` 不受影响; 但走 dnf 仓库时 `gpgcheck=1`(默认)会**拒装未签名包**——上制品库前需要先补签名, 或在仓库配置里关掉 `gpgcheck`。

---

## 5. 本地验证手段

```bash
# 语法
bash -n build.sh

# 构建 + 内置产物自检
./build.sh

# 核对产物
rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' release/*.rpm
rpm -qp --requires release/*.rpm
rpm -qp --scripts  release/*.rpm          # 看四段 scriptlet 是否齐全
rpm -qlpv          release/*.rpm | head   # 文件与权限

# 手工跑 %pre(不改本机, 抽取后直接执行)
rpm -qp --scripts release/*.rpm |
  awk 'NR>1 && /^(postinstall|preuninstall) scriptlet/{exit} NR>1{print}' > /tmp/pre.sh
bash -n /tmp/pre.sh && bash /tmp/pre.sh

# 真实安装/卸载(破坏性, 仅在测试机执行)
rpm -ivh release/*.rpm && rpm -q tsc_tools && rpm -ql tsc_tools
rpm -e tsc_tools
```

---

## 6. 提交约定

- 提交信息用中文, 形如 `type(scope): 摘要——细节; ...`, 细节可较长(沿用仓库既有风格)。
- 改动影响用户可见行为时, 同步更新 `release-note.md` 对应 `Version=` 段落的条目。
