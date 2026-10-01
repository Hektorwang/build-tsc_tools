# validate.jq — tsc_iaas_info_v2 输出校验模块 (DESIGN.md §3.0)
# 用法: jq -e -L <本文件所在目录> 'include "validate"; validate_static' <file>
#       jq -e -L <本文件所在目录> 'include "validate"; validate_runtime' <file>
# 约定: 所有叶子字段允许 null(采集降级语义), 但键必须存在且非空时类型正确。
# 退出: 校验通过输出 true(-e 下 rc=0), 失败输出 false(rc=1)。

def _num: type == "number";
def _str: type == "string";
def _nul: type == "null";
def _arr: type == "array";
def _obj: type == "object";
def _num_or_null: _num or _nul;
def _str_or_null: _str or _nul;
def _arr_or_null: _arr or _nul;

# --- meta: 所有文档共有 ---
def valid_meta:
  (_obj) and
  (.schema_version | _num) and
  (.tool_version | _str_or_null) and
  (.generated_at | _str_or_null) and
  (.degraded | _arr) and
  (all(.degraded[]; _str));

# --- 静态文档 ---
# 归一状态枚举(§3.1/§3.2 共用)
def valid_state_norm:
  . == "online" or . == "rebuild" or . == "degraded"
  or . == "failed" or . == "missing" or . == "unknown";

# storage[] 条目(DESIGN.md §3.1): 键齐全, state_norm 受枚举约束
def valid_storage_entry:
  _obj
  and ((keys_unsorted | sort) == ["ctl_no","dev","enc","interface","model","serial",
                                  "size","size_gb","slot","state","state_norm",
                                  "type","unit","vd","wwn"])
  and (has("dev") and has("type") and has("ctl_no") and has("enc") and has("slot")
       and has("vd") and has("state") and has("state_norm") and has("size")
       and has("unit") and has("size_gb") and has("model") and has("serial")
       and has("wwn") and has("interface"))
  and (.dev | _str_or_null)
  and (.type | _str_or_null)
  and (.ctl_no | _num_or_null)
  and (.enc | _num_or_null)
  and (.slot | _num_or_null)
  and (.vd | _str_or_null)
  and (.state | _str_or_null)
  and (.state_norm | _nul or valid_state_norm)
  and (.size | _str_or_null)
  and (.unit | _str_or_null)
  and (.size_gb | _num_or_null)
  and (.model | _str_or_null)
  and (.serial | _str_or_null)
  and (.wwn | _str_or_null)
  and (.interface | _str_or_null);

# raid_controllers[] 条目(DESIGN.md §3.2)
def valid_controller_entry:
  _obj
  and ((keys_unsorted | sort) == ["ctl_no","health","health_norm","name","pd_count","type","vd_count"])
  and (has("type") and has("ctl_no") and has("name") and has("health")
       and has("health_norm") and has("vd_count") and has("pd_count"))
  and (.type | _str_or_null)
  and (.ctl_no | _num_or_null)
  and (.name | _str_or_null)
  and (.health | _str_or_null)
  and (.health_norm | _nul or valid_state_norm)
  and (.vd_count | _num_or_null)
  and (.pd_count | _num_or_null);

def validate_static:
  (.meta | valid_meta)
  and (.machine_type | _str_or_null)
  and (.os_distribution | _str_or_null)
  and (.os_pkg_mgr | _str_or_null)
  and (.os_distribution_file_path | _str_or_null)
  and (.os_distribution_file_variety | _str_or_null)
  and (.os_kernel | _str_or_null)
  and (.machine_architecture | _str_or_null)
  and (.os_distribution_major_version | _str_or_null)
  and (.os_distribution_version | _str_or_null)
  and (.os_distribution_release | _str_or_null)
  and (.os_service_mgr | _str_or_null)
  and (.product_name | _str_or_null)
  and (.sn | _str_or_null)
  and (.manufacturer | _str_or_null)
  and (.contract_no | _str_or_null)
  and (.location | _str_or_null)
  and (.cpu | _obj) and (.cpu | has("cpu_model") and has("cpu_cnt"))
  and (.cpu.cpu_model | _str_or_null)
  and (.cpu.cpu_cnt | _num_or_null)
  and (.memory | _arr)
  and all(.memory[];
        _obj
        and ((keys_unsorted | sort) == ["locator","size","unit"])
        and has("size") and has("locator") and has("unit")
        and (.size | _num_or_null) and (.locator | _str_or_null) and (.unit | _str_or_null))
  and (.storage | _arr)
  and all(.storage[]; valid_storage_entry)
  and (.raid_controllers | _arr)
  and all(.raid_controllers[]; valid_controller_entry);

# --- 运行时文档 ---
# storage.mountpoint[] 条目(monitor_mountpoints 产物)
def valid_mountpoint_entry:
  _obj
  and ((keys_unsorted | sort) == ["filesystem","inodes","size","source","target","writable"])
  and (has("target") and has("source") and has("filesystem") and has("size")
       and has("inodes") and has("writable"))
  and (.target | _str_or_null)
  and (.source | _str_or_null)
  and (.filesystem | _str_or_null)
  and (.size | _obj) and (.size | has("total") and has("used") and has("used_percent") and has("unit"))
  and (.size.total | _num_or_null)
  and (.size.used | _num_or_null)
  and (.size.used_percent | _num_or_null)
  and (.size.unit | _str_or_null)
  and (.inodes | _obj) and (.inodes | has("total") and has("used") and has("used_percent"))
  and (.inodes.total | _num_or_null)
  and (.inodes.used | _num_or_null)
  and (.inodes.used_percent | _num_or_null)
  and (.writable | type == "boolean");

# --- 运行时文档 ---
def validate_runtime:
  (.meta | valid_meta)
  and (.cpu | _obj) and (.cpu | has("used_percent") and has("iowait_percent"))
  and (.cpu.used_percent | _num_or_null)
  and (.cpu.iowait_percent | _num_or_null)
  and (.memory | _obj)
  and (.memory.ram | _obj) and (.memory.ram | has("total") and has("used") and has("used_percent") and has("unit"))
  and (.memory.ram.total | _num_or_null)
  and (.memory.ram.used | _num_or_null)
  and (.memory.ram.used_percent | _num_or_null)
  and (.memory.ram.unit | _str_or_null)
  and (.memory.swap | _obj) and (.memory.swap | has("total") and has("used") and has("used_percent") and has("unit"))
  and (.memory.swap.total | _num_or_null)
  and (.memory.swap.used | _num_or_null)
  and (.memory.swap.used_percent | _num_or_null)
  and (.memory.swap.unit | _str_or_null)
  and (.storage | _obj) and (.storage | has("mountpoint") and has("raid"))
  and (.storage.mountpoint | _arr)
  and all(.storage.mountpoint[]; valid_mountpoint_entry)
  and (.storage.raid | _arr)
  and all(.storage.raid[]; _obj)
  and (.warning | _obj)
  and (.warning | has("cpu_usage") and has("memory_usage")
       and has("storage_usage") and has("inode_usage") and has("storage_unwritable")
       and has("pd_cnt_diffrent") and has("direct_disk_cnt_diffrent") and has("raid_status"))
  and (.warning.cpu_usage | _str_or_null)
  and (.warning.memory_usage | _str_or_null)
  and (.warning.storage_usage | _str_or_null)
  and (.warning.inode_usage | _str_or_null)
  and (.warning.storage_unwritable | _str_or_null)
  and (.warning.pd_cnt_diffrent | _str_or_null)
  and (.warning.direct_disk_cnt_diffrent | _str_or_null)
  and (.warning.raid_status | _arr_or_null);
