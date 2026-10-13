# 运维工具集

## 工具说明

运维工具集, 集成常用基础运维工具, 以方便运维工作

## 模块

- tsc_netspeed  
  网卡速度监测  
  持续监控指定网卡的收发包速率  
  tsc --tsc_netspeed \<interface\>  
- tsc_monitor_run_stat  
  tsc_monitor_run_stat  
  主要用于监听进程的运行状态和服务器的运行环境, 方便获取进程不定时出现问题时的运行环境.  
  tsc --tsc_monitor_run_stat <PID/PNAME> <process_pattern> <delay_interva>  
- tsc_iaas_info  
  检测系统IaaS信息  
  输出系统基本信息, 包括`处理器`, `内存`, `存储`, `操作系统版本`, `是否虚拟机`等, 并保存到 `/var/log/tsc_iaas_info.json`  
  查看 README.md  
- tsc_sysinit  
  操作系统初始化工具  
  对于新装完操作系统的服务器进行初始化配置. 因为要修改系统配置, 必须用 `root` 权限执行.  
  tsc --tsc_sysinit --help  
- tsc_sysinfo  
  系统运行环境采集检查和基础环境完工检查工具  
  迁移中, 尚未完成  
- tsc_drop_cache  
  释放系统内存缓存  
  通过 `echo 3 > /proc/sys/vm/drop_caches` 手动释放内存缓存, 以缓解系统压力. 效果取决于系统可释放的缓存.  
  tsc --tsc_drop_cache [释放阈值] # 可选参数, 释放阈值(int), 默认内存使用率超过 80% 时释放  
- tsc_collect_sar  
  系统资源使用情况对比工具  
  对比给定的两个时间点的系统资源使用情况  

## 安装

制成品为单个 `noarch` RPM 包, 包内同时携带 `x86_64` 与 `aarch64` 两架构的自带二进制, 安装期按本机 `arch` 择优部署(架构不在 `.supported_env.conf` 白名单内时, `%pre` 会拒绝安装)。

```bash
# 安装
rpm -ivh tsc_tools-<version>-<release>.noarch.rpm

# 升级 / 重装 (带旧版本时用它, 会走升级路径)
rpm -Uvh tsc_tools-<version>-<release>.noarch.rpm

# 查询
rpm -q tsc_tools
rpm -ql tsc_tools

# 卸载
rpm -e tsc_tools
```

安装前 `%pre` 会校验 `root` 权限、CPU 架构与发行版主版本(见 `.supported_env.conf`), 不通过则直接中止安装, 不留下半成品文件。

`/root/.vimrc` 不会被无条件覆盖: 已存在且内容不同时先备份为 `/root/.vimrc.tsc_tools.bak`(同名备份已存在则另存带时间戳的副本), 备份路径记入 `/home/tsc/tsc_tools/.installed_manifest`, 卸载时自动还原。

卸载时回收:

- `/bin` 下由本包部署的二进制与别名软链(逐文件 sha256 校验, 与本包自带一致才删, 不误删系统同名命令或被用户改过的文件); RAID CLI(`sas3ircu`/`storcli64`/`arcconf`)同理
- `/home/tsc/tsc_tools/bin` 与 `.installed_manifest`
- `/root/.vimrc`(仍与本包版本一致才删, 用户改过则保留)及安装时备份的 `/root/.vimrc.tsc_tools.bak`
- 本包 drop-in `/home/tsc/tsc_profile.d/00-tsc_tools-profile.sh`
- 包内文件由 RPM 文件清单自动删除; 残留空目录壳由 `%postun` `find -empty -delete` 清理(升级时跳过)

卸载时保留: `/home/tsc/tsc_profile`(公共空入口)、`/home/tsc/tsc_profile.d/` 目录(其他工具的 drop-in)、`/var/log/tsc` 及运行期日志。

`rag.md` 以 `%config(noreplace)` 声明: 包内的构建期版本只含本包模块, 升级不会被它覆盖; 安装/升级后由 `%post` 调用 `gen_rag.sh` 在目标机重建, 把已安装的其他工具(如 `tsc_python`)的模块一起纳入。因此 `rpm -V tsc_tools` 把 `rag.md` 报为 `S.5....T. c` 属预期(同 `tsc_python` 的 ansible `base.yml`), 不代表包损坏。

## 用法

先用 `root` `source` 一次 `/home/tsc/tsc_profile`(初始化 PATH 与 `TSC_MODULES_DIR`, 仅当前会话生效; 想持久化可写入 `/root/.bashrc`); 之后方可使用 `tsc`:

```bash
tsc --模块名 模块选项 模块选项=选项参数

# 如操作系统初始化

# --tsc_sysinit: 模块名

# --all: 模块定制选项, 执行该模块所有功能(--install_fhmv 不包含在内, 需显式指定)

# --no-disable_firewall: 模块定制选项反义, 排除执行某个功能

# --sshd_port=3204: 模块选项参数, 将sshd端口设置为3204

tsc --tsc_sysinit --all --no-disable_firewall --sshd_port=3204

# 查看帮助

tsc --help
tsc --模块名 --help  # --help 由模块自行处理: 文档展示型模块显示 README, 功能型模块显示参数说明
glow /home/tsc/tsc_tools/modules/模块名/README.md
```

## 打包

```bash
./build.sh
```

打包机需提供:

- `nfpm`(默认取 `/bin/nfpm`, 亦可在 `PATH` 中提供或用 `NFPM_BIN=/path/to/nfpm ./build.sh` 指定)
- `dos2unix`

版本号取自 `release-note.md` 顶部的 `Version=`, `release` 号取构建时间戳 `YYYYMMDDHHMMSS`(同日多次构建可区分)。RPM scriptlet 源码在 `packaging/rpm/`, 其中 `%pre` 由 `build.sh` 渲染生成(内联 `lib_min.sh`、`.supported_env.conf`、`env_check.sh`, 因其运行时包内文件尚未落盘)。

开发/打包的流程、约定与注意事项见 [README-dev.md](README-dev.md)。
