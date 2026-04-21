# release-note

## Version=2.0.3.beta10

1. fix: 修复 `tsc_sysinit` 当未指定 sshd 端口时, 会覆盖掉原来修改过的端口的问题

## Version=2.0.3.beta9

1. chore: 将 `jq` 从源码编译版替换为官方 release 二进制版
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
