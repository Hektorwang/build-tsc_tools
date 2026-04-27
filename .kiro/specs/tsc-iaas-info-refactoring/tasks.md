# tsc_iaas_info 模块分层解耦重构 - 实施任务列表

## 任务说明

按阶段顺序执行，每个阶段完成后验证功能不变再进入下一阶段。

---

- [x] 1. 创建基础结构和公共库
  - [x] 1.1 创建 lib/ 目录结构（lib/collectors/, lib/monitors/, lib/raid/）
  - [x] 1.2 创建 lib/common.sh，迁移 associate_array_to_json(), array_to_json(), LD_KEYWORDS, PD_KEYWORDS, INVALID_SNS 常量
  - [x] 1.3 创建 tests/ 目录

- [x] 2. 提取 RAID 检测模块（消除重复定义）
  - [x] 2.1 创建 lib/raid/detector.sh，将 get_raid_type() 逻辑迁移为 raid_detect()，输出 RAID_TYPE 和 RAID_BIN 两个变量
  - [x] 2.2 更新 tsc_raid_health_check.sh，删除其中的 get_raid_type() 定义，改为 source lib/raid/detector.sh
  - [x] 2.3 验证 tsc_raid_health_check.sh 独立运行结果不变

- [x] 3. 提取静态信息采集器
  - [x] 3.1 创建 lib/collectors/cpu.sh，迁移 get_cpu_info() 为 collect_cpu_info()
  - [x] 3.2 创建 lib/collectors/memory.sh，迁移 get_mem_info() 为 collect_mem_info()
  - [x] 3.3 创建 lib/collectors/system.sh，迁移 get_serial_number(), get_contract_no(), get_location() 为带参数版本（消除全局变量依赖）
  - [x] 3.4 创建 lib/collectors/storage.sh，迁移 get_disk_info() 为 collect_disk_info(machine_type, raid_type, raid_bin)（消除 RAID_INFO 全局数组依赖）

- [x] 4. 提取 RAID 适配器
  - [x] 4.1 创建 lib/raid/lsi.sh，从 run.sh 和 tsc_raid_health_check.sh 提取 LSI 相关逻辑，实现 raid_get_disk_list() 和 raid_check_health()
  - [x] 4.2 创建 lib/raid/adaptec.sh，提取 Adaptec 相关逻辑
  - [x] 4.3 创建 lib/raid/sas3.sh，提取 SAS3 相关逻辑
  - [x] 4.4 创建 lib/raid/sas2.sh，提取 SAS2 相关逻辑
  - [x] 4.5 更新 tsc_raid_health_check.sh 使用新的适配器模块

- [x] 5. 提取运行时监控器
  - [x] 5.1 创建 lib/monitors/cpu.sh，迁移 get_cpu_runtime_info() 为 monitor_cpu()
  - [x] 5.2 创建 lib/monitors/memory.sh，迁移 get_memory_runtime_info() 为 monitor_memory()
  - [x] 5.3 创建 lib/monitors/storage.sh，迁移 test_writability() 和 get_mountpoint_runtime_info() 为 monitor_mountpoints()

- [x] 6. 提取告警生成模块
  - [x] 6.1 创建 lib/alert.sh，迁移 runtime() 中的告警逻辑为独立函数
  - [x] 6.2 实现 generate_threshold_alerts(cpu_json, memory_json, mountpoint_json, cpu_t, mem_t, storage_t)
  - [x] 6.3 实现 generate_disk_change_alerts(current_disk_json, logfile)，封装历史对比逻辑
  - [x] 6.4 实现 generate_raid_alerts(raid_status_json)

- [x] 7. 创建业务逻辑编排层
  - [x] 7.0 创建 lib/monitors/raid.sh，将 RAID 健康检查作为与 cpu/memory/storage 同级的监控器，提供 monitor_raid_health(raid_type, raid_bin) 函数；删除 tsc_raid_health_check.sh
  - [x] 7.1 创建 lib/info_main.sh，实现 collect_all_info()，编排所有静态采集器
  - [x] 7.2 创建 lib/runtime_main.sh，实现 run_runtime_monitor()，编排所有监控器和告警

- [x] 8. 精简 run.sh
  - [x] 8.1 run.sh 只保留: shebang、参数解析、文件版本管理（时间戳+软链接+MD5对比）、调用 lib/info_main.sh 或 lib/runtime_main.sh
  - [x] 8.2 验证 run.sh 行数合理（200 行以内）
  - [x] 8.3 验证所有命令行参数行为与重构前一致

- [x] 9. 新增硬件变化历史对比告警
  - [x] 9.1 在 lib/alert.sh 中扩展 generate_disk_change_alerts() 为 generate_hardware_change_alerts()，新增对比项：CPU 型号变化、CPU 插槽数量变化、内存插槽数量变化、内存总容量变化
  - [x] 9.2 更新 lib/runtime_main.sh，将 generate_disk_change_alerts() 调用替换为 generate_hardware_change_alerts()

- [x] 10. 代码优化
  - [x] 10.1 lib/info_main.sh：将 7 次 jq 管道链合并为一次 jq -n 调用
  - [x] 10.2 lib/alert.sh：提取 _add_mountpoint_warning() 辅助函数消除 storage/inode 告警重复逻辑；磁盘数量对比改用 jq 替代 awk
  - [x] 10.3 lib/runtime_main.sh：将 pm+有RAID、pm+无RAID、vm 三个 jq -n 输出块合并为一次输出
  - [x] 10.4 lib/collectors/storage.sh：提取 _is_direct_disk() 辅助函数，替换嵌套 subshell 条件判断

- [x] 11. 补充代码注释
  - [x] 11.1 所有 lib/ 文件补充函数级注释（功能、参数、输出格式）
  - [x] 11.2 复杂逻辑块补充行内注释（直通盘判断、RAID 检测、MD5 对比机制、awk/sed 表达式）
  - [x] 11.3 告警 key 名称补充触发条件注释

- [ ] 12. 编写测试用例
  - [x] 12.1 设计测试框架：在 tests/ 下建立 fixtures/ 目录，存放各场景的模拟输入文件
    - tests/fixtures/raid/lsi/       — 模拟 storcli 输出的文本文件
    - tests/fixtures/raid/adaptec/   — 模拟 arcconf 输出的文本文件
    - tests/fixtures/raid/sas3/      — 模拟 sas3ircu 输出的文本文件
    - tests/fixtures/lspci/          — 模拟 lspci 输出（不同 RAID 卡场景）
    - tests/fixtures/lsmod/          — 模拟 lsmod 输出
    - tests/fixtures/lsblk/          — 模拟 lsblk 输出（含 RAID 盘、直通盘、虚拟盘场景）
  - [x] 12.2 创建 tests/test_framework.sh：提供 mock 机制，用文本文件替代真实命令输出
    - mock_cmd <cmd_name> <fixture_file>：将命令重定向到 fixture 文件
    - assert_json_eq <actual> <expected>：比较 JSON 输出
    - assert_contains_key <json> <key>：断言 JSON 包含指定告警 key
  - [x] 12.3 创建 tests/test_raid_detector.sh：测试 RAID 类型检测逻辑
    - 场景: LSI/MegaRAID、Adaptec、SAS3、SAS2、无 RAID 卡
    - 验证: RAID_TYPE 和 RAID_BIN 正确设置
  - [x] 12.4 创建 tests/test_direct_disk.sh：测试直通盘判断逻辑
    - 场景: 虚拟磁盘、RAID 厂商盘、逻辑卷、真实直通盘、混合场景
    - 验证: _is_direct_disk() 返回值正确
  - [-] 12.5 创建 tests/test_raid_health.sh：测试各 RAID 适配器健康检查解析
    - 场景: 正常状态、VD 降级、PD 离线、重建中
    - 验证: 输出 JSON 结构和中文状态描述正确
  - [~] 12.6 创建 tests/test_alert.sh：测试告警生成逻辑
    - 场景: 阈值告警、硬件变化告警（CPU/内存/磁盘）、无变化不告警
