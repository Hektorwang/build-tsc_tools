# release-note

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
4. feat(`gen_req.sh`): 生成 rag 友好的文档 `rag.md`, 同时更新所有模块的 readme.md, 删除 module.json, 并修改 tsc 遍历模块元数据的方式
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
