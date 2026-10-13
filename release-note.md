# release-note

## Version=2.1.9

Date=20261013

1. fix(func): `__log` 补 `export -f`——`LOG*` 函数通过 `export -f` 导出后子进程可调用, 但其内部依赖的 `__log` 未同步导出, 子进程直接调用 `LOGINFO` 等会报 `__log: command not found`; 现将 `__log` 与 `LOG*` 一并导出
2. fix(modules): `tsc_drop_cache` 收到 `--help`/`-h` 时原先把参数当阈值传入, 触发"释放阈值必须为整数"报错; 现在 `--help`/`-h` 优先拦截, 展示 README 后退出。`tsc_monitor_run_stat` 收到 `--help`/`-h` 时原先走 mode 校验报错; 现在同样拦截并显示 usage
3. fix(packages/install.sh): 二进制不存在时从静默跳过改为 `LOGWARNING` 并 continue(缺失列表在末尾汇总输出); 部署权限从 `chmod a+x`(umask 收紧时 other 执行位可能被清掉) 改为 `chmod 0755`; 逻辑调整为 arch 优先 noarch、一次 cp, 不再两个 `if` 各自拷一遍
4. fix(tsc_collect_sar/install.sh): 移除 OS 门禁(uname -r 匹配 el6/el7/fos/ky10)——准入校验由 RPM `%pre` 的 `env_check.sh` 统一处理, 子模块自行检测与主流程不同步且已滞后; 备份目录 `rm -rf` 失败时从静默继续改为报错退出(避免新旧文件混入备份)
5. fix(tsc_collect_sar/compare.sh): `sar -n DEV` 网络列(rxkB/s / txkB/s, 最大值与平均值共 8 处)从硬编码列号 `$6`/`$7` 改为 awk 先从表头行按列名定位列号再取值, 兼容新旧 sysstat 版本(新版在前面插入额外列导致列号偏移)
6. fix(build.sh): 打包失败时 `stage/` 不再残留——在 `rm -rf stage/` 前注册 `trap 'rm -rf "${STAGE_DIR}"' EXIT`, 成功/失败路径统一回收(与 `tsc_python/build.sh` 保持一致)
7. fix(gen_rag.sh): 目标机执行时区分 `tsc_profile` 不存在与 source 失败两种情况——文件不存在时静默用 fallback 目录(原有行为); 文件存在但 source 失败时打印 WARNING 到 stderr, 提示用户 rag.md 可能不完整
8. refactor(build): `.supported_env.conf` 只保留项目根为单一事实源——打包时拷进 `stage/` 供 `%post` source; 删除源码树 `tsc_tools/` 下副本, 并清除 `.gitignore` 中三条构建副本忽略行(`/tsc_tools/README.md`、`/tsc_tools/release-note.md`、`/tsc_tools/.supported_env.conf`)——`build.sh` 已不再写回源码树, 留着会误导后人以为还要维护两份
9. chore(build): `release` 号由构建日期 `YYYYMMDD` 改为构建时间戳 `YYYYMMDDHHMMSS`, 与 `tsc_python` 对齐, 同日多次构建 NVR 可区分
10. chore(rpm): stage 剔除 `**/tests/**`、`DESIGN.md`、`README_DEV.md`, 不再打进 RPM(全树范围, 不限 `modules/`; 运行期无依赖, 源码树仍保留供开发自测)
11. chore(docs): 修正过期注释与文档——`postinstall.sh` 头职责第 3 条由 2.1.6 时代"注入 `TSC_TOOLS` 块"改述为 drop-in 模型(2.1.7 起实际行为); `env_check.sh` 去掉不存在的 `SUPPORTED_ENV_FILE` 表述; README-dev §4.8 去掉从未存在的 `cmp` 描述并将剪裁范围同步为全树; 顺手清理上次旧 `build.sh` 留在源码树的 `tsc_tools/{README.md,release-note.md,rag.md}` 残留副本
12. fix(rpm): 支持矩阵补麒麟 V10——`kylin`/`neokylin` 在 `env_check.sh` 的 `DISTRO_VARIETY_MAP` 中归入 RedHat 家族, 而 `DISTRO_VERSION_RULES_RedHat` 只到 9, V10 (主版本 10) 会被 `%pre` 拒绝安装; `.supported_env.conf` 的 RedHat 规则增加 `10` (覆盖 `VERSION_ID` 为 `10`/`10.x` 的形态; 若现场 os-release 用 `V10` 字面量, 需另加规则)
13. fix(func): `detect_system_info` 的 `$ID` 补默认值——`/etc/os-release` 缺 `ID` 字段时 `set -o nounset` 下会以 unbound variable 中断 (模块运行期与 `%post` 复用同一函数, `packaging/rpm/env_check.sh` 同修); 与 `VERSION_ID`/`ID_LIKE` 的防御写法对齐

## Version=2.1.8

Date=20261013

1. fix(rag): 修复 `rag.md` 成倍膨胀——`01-tsc_tools-profile.sh` 追加 `TSC_MODULES_DIR` 时无判重, 重复 `source tsc_profile`(嵌套 shell / 脚本已 source 过再调 `gen_rag.sh` / 在已 source 的终端里跑 `rpm -U`)会让同一模块目录在变量里重复出现, `gen_rag.sh` 遍历时把同一份 readme 收录多次(现场实测: 干净 1026 行 vs 膨胀后 4132 行, 元数据块重复 5 份)。三处同时收口: 本包 drop-in 增加判重守卫(与 `tsc_python` 侧同一写法)、`gen_rag.sh` 对目录列表与 readme 路径各做一次去重(保留原顺序)、readme 为空时报错而非静默产出空 rag
2. fix(rag): 升级 tsc_tools 不再把其他工具的模块从 `rag.md` 里抹掉——包内 rag.md 是构建期生成的、只含本包模块, 原先 `%post` 不重建, 升级会用 tools-only 版本覆盖已合并的 rag, 直到下次装/升 `tsc_python` 才恢复。现 `rag.md` 改以 `%config(noreplace)` 单独声明(升级不被包内版本覆盖), 并由 `%post` 调用 `gen_rag.sh` 在目标机重建; 因此 `rpm -V tsc_tools` 报 `rag.md` 为 `S.5....T. c` 属预期(同 `tsc_python` 的 ansible `base.yml`)
3. refactor(rpm): 本包 drop-in 改名 `01-tsc_tools-profile.sh` -> `00-tsc_tools-profile.sh`, 与 `01-tsc_python-profile.sh` 以数字前缀明确保序(不再依赖 `p` < `t` 的字母序巧合); `%post` 与 `%preun` 均清理旧名残留(衍生文件不在 rpm 文件清单里, 升级不会被自动带走)
4. fix(rpm): `%post` 与 `%postun` 清理 `modules/` 下的无主空目录壳——模块改名(`tsc_collectSar` -> `tsc_collect_sar`)与旧布局(`tsc_python` 模块曾装在 `tsc_tools/modules/` 下)遗留的空目录既不属任何包也不会被回收; 只删**空**的一级子目录, 有内容的一律不动
5. fix(rpm): `/var/log/tsc` 权限 0755 -> 0750, 与 `tsc_python` 统一(日志可能含主机清单/凭据片段等敏感信息, 不放行 other 读)
6. fix(modules): tsc_tools 自带文档模块 (`tsc_sysinit`/`tsc_collect_sar`/`tsc_netspeed`) 的 run.sh 同样用 `glow <readme>` 展示说明, glow 传文件路径时进 TUI, 非 TTY (管道/重定向/输出被上层接管) 下静默空输出; 改为按 TTY 分流, 非交互式直接 `cat` 原文 (与 `tsc_python` 三个文档模块同款修法)。`tsc_sysinit` 的生成源 `run.m4` 一并修正

## Version=2.1.7

1. refactor(rpm): `/home/tsc/tsc_profile` 拆为公共空入口(仅 `source tsc_profile.d/*.sh`), 本包配置移到 drop-in `tsc_tools/profile`(`%post` 部署到 `/home/tsc/tsc_profile.d/01-tsc_tools-profile.sh`, 含 PATH 与 `TSC_MODULES_DIR` 追加声明); 卸载只删本包 drop-in, 保留空入口与 `tsc_profile.d/` 目录, 为 `tsc_python` 等后续工具提供 drop-in 扩展点
2. feat(tsc): 模块目录抽成 `TSC_MODULES_DIR` 变量(冒号分隔多目录), `tsc` 与 `gen_rag.sh` 按 `:` 顺序遍历; 用户须 `source /home/tsc/tsc_profile` 后方可使用 `tsc`, 未 source 直接调用会报错提示; `tsc_python` 等后续工具只需往 `tsc_profile.d/` 放一个 `02-tsc_python-profile` 即可让自身 modules 被 `tsc`/`gen_rag` 自动纳入
3. refactor(rpm): 卸载回收改三分类——包内文件仍交 RPM 文件清单; 包外衍生文件(`/bin/*`、RAID CLI、`/root/.vimrc`、drop-in)进 `.installed_manifest` 并带 sha256(`FILE:<path>:<sha256>` 格式), `%preun` 按 hash 校验一致才删(防误删被用户/系统改过的同名文件); 目录壳由新增 `%postun` `find -empty -delete` 清理(升级 `$1>=1` 跳过)
4. fix(rpm): `record_manifest` 补全此前漏记的 RAID CLI(`sas3ircu`/`storcli64`/`arcconf`)与 `/root/.vimrc`, 统一 hash 字段; 系统自带同名文件不覆盖、不记、不卸的判断不变
5. feat(rpm): `gen_rag.sh` 打进包内 `/home/tsc/tsc_tools/gen_rag.sh`, 目标机 `source tsc_profile` 后可直接运行生成多工具合并 rag; 构建期仍由 `build.sh` 调用生成 `tsc_tools/rag.md`
6. fix(rpm): 新增 `%postun` scriptlet(`postremove.sh`), `nfpm.yaml` 挂接; 产物自检扩展为四段 scriptlet 完整性校验
7. refactor: 模块与运行期目录命名统一为 `tsc_collect_sar`(模块目录 `tsc_tools/modules/tsc_collect_sar`, 报告目录 `/var/log/tsc/tsc_collect_sar`, 备份子目录 `back_sar`, 卸载暂存 `/tmp/tsc_collect_sar`); 对外用法 `tsc --tsc_collect_sar`, `tsc`/`gen_rag.sh` 按目录名自动纳入

## Version=2.1.6

1. refactor(build): 制成品由 makeself 自解压包改为 RPM, 产出 `release/tsc_tools-<version>-<release>.noarch.rpm`(`version` 取自本文件 `Version=`, `release` 为构建日期); 删除 `makeself.sh`/`makeself-header.sh`/`lib/makeself-2.5.0.run` 与自解压入口 `install.sh`, 打包脚本集中到 `packaging/rpm/`
2. feat(build): 打包前检查打包机是否提供 `nfpm`(默认 `/bin/nfpm`, 可用 `NFPM_BIN` 覆盖), 缺失时明确报错退出; 产物自检包含包信息/依赖/文件数/`tsc` 可执行位/x86_64 与 aarch64 两套自带二进制是否齐全与三段 scriptlet 是否写入
3. feat(rpm): `%pre` 做环境准入校验(root 权限、CPU 架构、发行版家族与主版本), 不通过则中止安装, 不留下半成品文件——原先自解压包是先解包再校验
4. feat(rpm): `%post` 沿用 `packages/install.sh` 的探测式部署逻辑(二进制、`/bin` 工具、RAID CLI、`/root/.vimrc`), 并记录 `.installed_manifest` 供卸载回收; `%preun` 仅在真卸载(`$1==0`)时回收, 升级(`rpm -U`)交由新包 `%post` 重建, 不再出现"升级过程中工具被删空"的窗口
5. fix(rpm): `%preun` 回收 `/bin/<tool>` 前逐一比对内容指纹, 与包内二进制不一致(系统自带或已被替换)的一律跳过, 不再误删系统同名命令; `/root/.vimrc` 同理, 用户改过则保留
6. feat(tsc_profile): `TSC_TOOLS` 块增加 `/home/tsc/tsc_profile.d/*.sh` 片段加载, 便于现场自定义或其他工具 drop-in; 注入逻辑保持幂等(先摘旧块再插入)
7. docs: README 补充 RPM 安装/升级/卸载/重装说明与卸载回收范围
8. fix(packages/install.sh): `/root/.vimrc` 不再无条件覆盖——已存在且内容不同时先备份为 `/root/.vimrc.tsc_tools.bak`(该备份已存在则另存带时间戳副本, 保留最初那份), 备份路径以 `VIMRC_BACKUP:` 记入 `.installed_manifest`; `%preun` 删除本包 vimrc 后自动还原该备份, vimrc 已被用户改动则保留不动; 内容已是本包版本时不覆盖也不备份, 保证重复安装幂等
9. refactor: `packages/install.sh` 与 `%post`/`%preun` 约定同一份部署清单路径 (`<TSC_TOOLS_DIR>/.installed_manifest`), 由 `%post` 清空后各自追加
10. fix(rpm): 补上此前漏声明的硬件检查依赖 `pciutils`(lspci, RAID 卡探测)、`sysstat`(sar, `tsc_collect_sar` 与 `tsc_sysinit` HISTORY 配置)、`dmidecode`(序列号/内存条/厂商采集), 按硬依赖 `Requires` 声明——本工具核心功能即硬件检查, 三者缺失会让采集结论不完整, 装不上时应显式暴露而非静默降级; 特殊场景可用 `rpm -ivh --nodeps` 绕过。`smartctl` 代码里无引用故不声明, `dos2unix` 仅打包期使用不该进运行期依赖
11. fix(rpm): `%post` 的部署清单不再把 `/bin/<tool>` 上的系统软链记为 `LINK`(系统自带软链会被 `install.sh` 的 `\cp` 穿透改写目标, 软链本身却留存), 改为只记录"常规文件且指纹与本包自带二进制一致"的条目, 消除 `%preun` 误删系统同名软链的路径

## Version=2.1.5

1. fix(func): `__log` 恢复行尾换行——2.1.4 分离终端彩色与日志纯文本两路时, 格式化结果经 `$(printf ...)` 命令替换赋值, 行尾 `\n` 被命令替换剥掉, 两路 `printf '%s'` 均无换行, 终端输出与日志文件里所有日志行连成一片; 改用 `printf -v` 直接赋值保留换行(install.sh 与各模块均 source 公共 func, 一处修复全覆盖)

## Version=2.1.4

1. fix(tsc_sysinit): `run.m4` 重新对齐 `run.sh` 并经 argbash 2.11.0 再生成校验一致——m4 补入 `--no-` 排除机制(`all_mode`)与硬化版 `install_fhmv`(找不到 rpm 前置校验 + 同版本跳过)、"Reloading" 日志文案, 恢复 m4 为生成源
2. change(tsc_sysinit): `--install_fhmv` 不再包含在 `--all` 内, 仅显式指定时安装(与 `--all` 同用亦生效); README/readme 同步说明, `--no-install_fhmv` 用法示例随之失效并更替
3. docs(tsc_sysinit): readme 注明 `--install_fhmv` 的 OS 支持范围——该 rpm `%post` 仅支持 RHEL/CentOS 6/7 (x86_64), StarrySky (x86_64) 与 aarch64; RHEL8/9 x86 上显式安装会失败并残留对 `/etc/profile`、`/etc/crontab` 的修改
4. fix(tsc_sysinit): `ntp_server` 中未定义的 `LOGWARN` 更正为 `LOGWARNING`——crond/cron 均不活跃时原会 command not found, 在 errexit 下中断脚本
5. fix(tsc_sysinit): `config_selinux` 改为整行替换 `^SELINUX=`, `permissive` 状态同样能永久禁用(原只匹配 `enforcing`); 注释行与 `SELINUXTYPE` 不受影响(fixture 已验证)
6. fix(tsc_sysinit): `config_chrony`(placeholder) 修复 sed 追加 server 行携带前导空格的问题
7. docs(tsc_sysinit): readme 注明 `--disable_firewall` 不保留原始防火墙规则备份(工作环境规范如此)
8. docs(tsc_sysinit): `install_fhmv` 的 `rm -v` 探针补充意图注释(fhmv 安装后以包装器替换系统 rm, 对无操作数 `-v` 返回 0, GNU rm 返回 1, 以此验证包装器就位)
9. TODO(tsc_sysinit): 引入 [argc](https://github.com/sigoden/argc) 替代 argbash——参数定义改为 run.sh 内注释声明(`# @flag`/`# @option`), 解析/帮助/校验由其单二进制完成, 删除 `run.m4` 与生成块; release 资产含 x86_64/aarch64 musl 静态二进制, 与本工具支持架构一致. 落地顺序: 先 spike(两架构二进制入 packages/ 并验证静态链接, 以 tsc_sysinit 为样例实测 `--all --no-disable_firewall` 路径), 后全量切换. 注意 argc 无内建 `--no-` 反义, 各排除项需显式声明 `# @flag --no-<功能名>`

## Version=2.1.3

1. fix(tsc_iaas_info_v2): memory 采集器未知单位不再静默跳过, 记入降级(`memory.unit_<单位>`)
2. feat(tsc_iaas_info_v2): validate memory 条目键集合严格校验(与 storage/raid_controllers/mountpoint 同构), 配套 test 25 例
3. fix(tsc_iaas_info_v2): adaptec flushpd printf 末尾多余参数(笔误, awk 忽略多余实参, 无行为变化)
4. fix(tsc_iaas_info_v2): 测试框架 assert_json_has_key/assert_json_no_key/assert_valid_json 失败由 return 1 改 exit 1, 消除无 errexit 子 shell 下的吞失败
5. docs(tsc_iaas_info_v2): 一机多卡不支持决策落 DESIGN §10(v0.3/v0.4); 文档同步(测试计数/DESIGN 指针/资产模式命名/存储监控现状); 新增开放问题 §9.3(runtime monitor 未包降级)

## Version=2.1.2

1. refactor: 移除 fping 相关内容（tsc_fping 模块、二进制及安装清单条目）
2. fix(func): 重写 `str_strip`: 修复 sed 不支持 `\u` 转义导致误剥首尾 `u`/`3`/`0` 字符的问题; 改为优先使用 perl 以覆盖全部 Unicode 空白字符, 无 perl 时自动退化为新增的纯 bash 实现 `str_strip_alternative`(不依赖 locale, 覆盖 NBSP(U+00A0) 与全角空格(U+3000))
3. fix(tsc_sysinit): `install_fhmv` 增加找不到 rpm 的前置校验与同版本跳过, 保持卸旧装新方式(该包 %post 会 `chattr +i` 且 %postun 无升级守卫, 不适用 `rpm -Uvh`); `--all` 模式纳入 `install_fhmv`, 并支持 `--no-` 在 `--all` 下按功能排除
4. fix(build): build.sh 打包前检查 dos2unix 是否可用, 缺失时明确报错退出
5. fix(tsc_netspeed): 修复无参数时 `IFNAME="$1"` 在 nounset 下报 unbound variable 的问题, 现可正常进入 usage 帮助; 接口不存在时前置校验并列出可用接口(原先进循环后才失败且报错双份); 8 段重复的统计读取收拢为 `read_stat`(网卡中途消失的保护不变)
6. fix(tsc_sysinit): 日志变量修正为 `log_file` 并更正文件名拼写 `tsc_sysinit.log`; 原变量名 `logfile` 与 func `__log` 读取的 `log_file` 不匹配, 日志从未写入文件
7. fix(tsc_drop_cache): 删除复制的 `__log/LOG*`, 改为 source 公共 `func`(与其他模块一致); 去除重复的 `script_name` 定义与多余的 `SETCOLOR_*` 导出; `set -o posix` 修正为 `set +o posix`; 不设 `TSC_FUNC` 守卫(经 tsc 分发器调用时子进程仅继承被 `export -f` 的函数, `__log` 不在其中, 跳过 source 会在首次打日志时报 `__log: command not found`)
8. docs(tsc_iaas_info): 在 run.sh 与 lib/common.sh 注明设计约束——本模块 stdout 为纯 JSON(供 zabbix 等读取), 本模块及 lib/ 禁止调用 `LOG*` 污染输出; 模块实际使用的 func 函数均已可正常获得, `TSC_FUNC` 守卫维持现状

## Version=2.1.1

1. 回滚 `2.0.5` 的错误修改

## Version=2.1.0

1. feat(yq_go): 增加 `yq_go`<https://github.com/mikefarah/yq> 工具, 以提供解析`YAML`, `JSON`, `INI` `XML` 和 `TOML` 的能力

## Version=2.0.5

1. fix(tsc_tools/modules/tsc_iaas_info/lib/alert.sh): 修复了读取数据中 storage 存储层级问题

## Version=2.0.4

1. fix:(tsc_iaas_info/lib/monitors/cpu.sh): 修复 bash-4.2 的 `$(())` 中不能包含注释的问题(删掉了注释)
2. fix:(packages/install.sh): 修复 `sas3ircu` 的 raid 卡驱动安装判断错误问题
3. fix:(packages/install.sh): 将本工具自带的二进制工具如 `jq` `sshpass` 等安装到 `/home/tsc/tsc_tools/bin/` 并在 `tsc_profile` 中优先指定本路径, 防止系统自带命令与本工具所用不同导致工作异常
4. fix:(modules/tsc_iaas_info/lib/raid/sas3.sh): 修复当没有做 vd 时报错的问题
5. fix:(modules/tsc_iaas_info/lib/monitors/storage.sh): 修复 `mktemp` 参数问题
6. fix: 之前 AI 重构 tsc_iaas_info 后, 丢失了采集 mpt3sas raid 信息的功能, 补回此功能
7. TODO: 将采集 raid 信息功能(lsi, arcconf卡)的部分都剥离到 lib/raid/, 与 lib/collectors/storage.sh 解耦

## Version=2.0.3.rc3

1. fix: 修改 sshd 配置后 reload 而非 restart 服务

## Version=2.0.3.rc2

1. fix: 修复当 `arcconf` 无法执行时强制退出导致无法安装的问题
2. fix: 不再禁用 `dbus` 服务

## Version=2.0.3.rc1

## Version=2.0.3.beta10

1. fix: 修复 `tsc_sysinit` 当未指定 `sshd_port` 时会覆盖掉原来修改过的端口配置问题

## Version=2.0.3.beta9

1. chore: 将 `jq` 从源码编译版替换为官方 release-1.8.1 二进制版
2. fix: 修复安装 `arcconf` 时判断错误问题
3. fix: 修复 `arcconf` 的raid卡的vd状态为 `InterimRecovery` 无法识别的问题, 将该状态识别为 `尝试临时恢复`
4. feat(`gen_req.sh`): 生成 rag 友好的文档 `rag.md`, 同时更新所有模块的 README.md, 删除 module.json, 并修改 tsc 遍历模块元数据的方式
5. feat(`install.sh`): 增加 `ningos` 支持
6. TODO: 将 `func` 替换为 `tsc_utils`
7. TODO: 将 `tsc_iaas_info` 模块拆分, 以方便开发维护, 并增加处理器和内存变动告警

## Version=2.0.3.beta8

1. fix(tsc_iaas_info): findmnt 在 el7 下不支持 `-U` 参数, 删除该参数
2. fix(tsc_iaas_info): grep -c 在找不到 pattern 时返回 false, 影响计数, 修改为用 awk 计数
3. fix(tsc_iaas_info): 修复了 runtime 函数在不带 raid 的 pm 上运行的很多问题
4. fix(tsc_iaas_info): 修复了在 `MegaRaid 9560-16i` 下运行问题
5. fix(tsc_iaas_info): 修复了在 `UN Adaptec RAID P460-M2` 下运行问题
6. fix(tsc_iaas_info): 修复在 el7 下计算磁盘数量变更问题

## Version=2.0.3.beta7

1. fix(tsc_sysinit): 解决 ssh 注入配置时定制化配置文件不存在时报错退出问题, 因EL7自带的sshd不支持 Include, 直接改成将参数写入主配置.
2. fix(tsc_sysinit): 解决 sar 配置时未消除默认 stdout 问题
3. fix(tsc_sysinit): 解决配置 rc-local.service 时未注入启动级问题
4. fix(func): 解决了 backup_dir_with_rotation 函数使用了 bash 4.3不支持语法问题
5. fix(build.sh): 集成包去掉将 README.md 作为帮助的功能, 因为其中带了 markdown 语法影响集成包运行

## Version=2.0.3.beta6

1. feat(`tsc_iaas_info`): 增加读取旧日志文件, 若磁盘数量不一致则告警功能
2. fix(`tsc_iaas_info`): 修复 `lsi` 卡下的一堆执行问题.
3. TODO: 补充 `README.md`
4. TODO: 在 `arcconf` 和 `mpt3sas` 的 raid 卡下进行测试

## Version=2.0.3.beta5

1. fix(`tsc_iaas_info`): 修复了在 lsi 卡上取 pd 错误的问题.
2. TODO(`tsc_iaas_info`): pd 数量对比告警功能.
3. TODO: 补充 `README.md`

## Version=2.0.3.beta4

1. fix(tsc_tools/packages/install.sh)
2. TODO: 补充 `README.md`

## Version=2.0.3.beta3

1. feat: 给 `tsc_iaas_info` 增加告警功能. 当执行 `--runtime` 时会生成结果告警对象 `warning`, 提供处理器, 内存, 存储使用率告警及存储健康状态告警, 并可额外指定告警阈值. 如此当 `zabbix` 调用时可直接读取该对象, 减轻在服务端计算压力;
2. feat: 给 `tsc_iaas_info` 增加手工设置序列号功能. 当执行 `--sn` 时会用手工配置的序列号覆盖原保存的序列号, 否则会优先读取原配置中序列号. 如既未手工配置序列号, 原配置序列号也为空, 则尝试从硬件中读取序列号;
3. fix: 修复因 raid 判断方法问题导致的重复安装失败问题
4. fix: 修复 tsc_iaas_info 采集 raid 卡重复问题
5. fix: 调整 tsc_iaas_info --runtime 输出数据结构, 以及判断 `warning` 方法.
6. TODO: 补充 `README.md`

## Version=2.0.2.beta

1. feat: 给 `tsc_iaas_info` 增加 `runtime` 选项, 收集系统运行时资源状态, 参考 `zabbix` 上原生的多个监控项内容;

## Version=2.0.1.dev

X4068

1. fix: 修改了两个 raid 卡工具的安装方式和调用方式, 优先调用系统已安装好的工具;
2. fix: 修复了 `tsc_sysinit` 的几个问题;
3. feat: 依赖 python 的工具已经全部剥离;
4. TODO: 给 `tsc_iaas_info` 增加 `runtime` 选项, 收集系统运行时资源状态, 参考 `zabbix` 上原生的多个监控项内容;

## Version=2.0.0.dev

X4068

1. feat: 剥离依赖 `python` 的工具，将相关工具移到 `tsc_python` 中. 可通过加装 `tsc_python` 将剥离的工具集成回来.
2. feat: 不再支持 `el6` 操作系统, 并后续不再对 `el7` 操作系统进行兼容测试, 仅对 `fhos/euler` 操作系统进行测试.
3. feat: 删除一些工具, 并新增一些工具.
4. refactor(tsc): 修改入口脚本, 后续工具调用方式都由此入口进入.
5. refactor: 每个工具都进行检查确认, 有需要的都修改调度方式, 原有工具改好确认过的才加回本工具集.
6. chore: 更改安装目录到 `/home/tsc/tsc_tools`.
7. chore: 修改为使用 `makeself` 打包, 并使用 `gitea/jenkins` 自动集成.
8. TODO: 逐步将原有工具添加回来.
