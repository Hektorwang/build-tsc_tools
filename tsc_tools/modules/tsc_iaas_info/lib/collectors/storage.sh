#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# lib/collectors/storage.sh — 磁盘/存储静态信息采集
# 被 source 使用，不可直接执行。
#
# 提供函数:
#   collect_disk_info <machine_type> <raid_type> <raid_bin>
#     machine_type: pm | vm
#     raid_type:    none | adaptec | mpt3sas | mpt2sas | lsi
#     raid_bin:     RAID 管理工具路径（machine_type=pm 时使用）
#     输出 JSON: {storage: [{type, model, serial, size, unit}, ...]}
#     若无磁盘信息则无输出

# -----------------------------------------------------------------------------
# _is_direct_disk <name> <vendor> <model> <lsblk_line>
#
# 判断块设备是否为直通盘（非 RAID 逻辑卷）。
# 直通盘定义: 直接挂在主板/HBA 上、未被 RAID 控制器管理的物理磁盘。
#
# 判断逻辑（短路求值，按优先级依次检查）:
#   1. 含 "Virtual disk" 或 "VMware" 关键字 → 虚拟化直通盘，视为直通盘
#   2. 厂商为 LSI/DELL/HP/AVAGO → RAID 卡厂商设备，不是直通盘
#   3. 型号含 "LOGICAL" → RAID 逻辑卷，不是直通盘
#   4. sysfs 总线路径对应的 PCIe 设备是 RAID 控制器 → 不是直通盘
#   5. 以上均不满足 → 视为直通盘
#
# 参数:
#   name       — 块设备名称（如 sda），用于读取 sysfs 路径
#   vendor     — lsblk 报告的厂商字符串
#   model      — lsblk 报告的型号字符串
#   lsblk_line — lsblk -P 输出的完整行，用于关键字匹配
#
# 返回值:
#   0 — 是直通盘
#   1 — 不是直通盘
# -----------------------------------------------------------------------------
_is_direct_disk() {
    local name="$1"
    local vendor="$2"
    local model="$3"
    local lsblk_line="$4"

    # 条件1: 虚拟磁盘/VMware 视为直通盘
    # 云主机或 VMware 环境下的虚拟磁盘也按直通盘处理
    echo "${lsblk_line}" | grep -qiP "Virtual disk|VMware" && return 0

    # 条件2: RAID 卡厂商的设备不是直通盘
    # LSI/DELL/HP/AVAGO 是常见 RAID 卡厂商，其设备通常是 RAID 逻辑卷
    echo "${vendor}" | grep -qP "LSI|DELL|HP|AVAGO" && return 1

    # 条件3: 逻辑卷不是直通盘
    # 型号含 "LOGICAL" 表示这是 RAID 控制器暴露的逻辑卷设备
    echo "${model}" | grep -q 'LOGICAL' && return 1

    # 条件4: 通过 sysfs 总线路径检查是否挂在 RAID 控制器下
    # readlink -f 解析 /sys/block/<name> 的真实路径，例如:
    #   /sys/devices/pci0000:00/0000:00:1f.2/ata1/host0/target0:0:0/0:0:0:0/block/sda
    # awk -F/ '{print $5"|"$6}' 取第5、6段（PCI 域:总线:设备.功能 格式），用 | 连接
    # sed 's/\b0000://g' 去掉 PCI 域前缀 "0000:"，得到如 "00:1f.2|ata1" 的路径片段
    # 再用 lspci 查找该 PCIe 设备是否是 RAID 控制器
    local bus_path
    bus_path="$(readlink -f "/sys/block/${name}" 2>/dev/null | awk -F/ '{print $5"|"$6}' | sed 's/\b0000://g')"
    if [[ -n "${bus_path}" ]] && lspci | grep -E "${bus_path}" | grep -qiE "raid|Adaptec|Avago|LSI|MegaRAID|RAID bus controller"; then
        return 1
    fi

    return 0
}

collect_disk_info() {
    local machine_type="$1"
    local raid_type="${2:-none}"
    local raid_bin="${3:-}"
    local line ctl_no
    local lsblk_line model size type
    local disk_detail=()
    local da_disk_detail

    if [[ "${machine_type}" == "pm" ]]; then
        if [[ "${raid_type}" == "adaptec" && -n "${raid_bin}" ]]; then
            # Adaptec: 从 arcconf 获取物理磁盘列表
            local raid_detail=()
            mapfile -t raid_detail < <(
                "${raid_bin}" GETCONFIG 1 PD |
                    awk -F ':' '
                        BEGIN { i=0 }
                        /^\s*Device #/{ i+=1 }                          # 每遇到 "Device #N" 行，设备计数器加1
                        /^\s*Device is a Hard drive/{ r[i]["flag"]=1 }  # 标记为硬盘（排除 SSD/CD-ROM 等）
                        /^\s*Model/{ gsub(/^\s+|\s+$/,"",$2); r[i]["model"]=$2 }          # 提取型号，去除首尾空格
                        /^\s*Serial number/{ gsub(/^\s+|\s+$/,"",$2); r[i]["serial"]=$2 } # 提取序列号
                        /^\s*World-wide name/{ gsub(/^\s+|\s+$/,"",$2); r[i]["wwn"]=$2 }  # 提取 WWN（全球唯一名称）
                        /^\s*Total Size/{
                            gsub(/^\s+|\s+$/,"",$2)
                            # 将各种单位统一换算为 TB
                            if ($2~"M") size=$2/1024/1024  # MB → TB
                            if ($2~"G") size=$2/1024        # GB → TB
                            if ($2~"T") size=$2             # TB 直接使用
                            if ($2~"P") size=$2*1024        # PB → TB
                            r[i]["size"]=size
                        }
                        END {
                            for (a in r) {
                                # 只输出标记为硬盘的设备（flag==1）
                                if (r[a]["flag"]==1) {
                                    printf "{\"type\":\"raid\",\"model\":\"%s\",\"serial\":\"%s\",\"wwn\":\"%s\",\"size\":\"%.2f\",\"unit\":\"T\"}\n", \
                                        r[a]["model"], r[a]["serial"], r[a]["wwn"], r[a]["size"]
                                }
                            }
                        }
                    '
            )
            [[ "${#raid_detail[@]}" -gt 0 ]] && disk_detail+=("${raid_detail[@]}")

        elif [[ "${raid_type}" == "lsi" && -n "${raid_bin}" ]]; then
            # LSI/MegaRAID: 从 storcli 获取物理磁盘列表
            # grep -PA2 "Ctl\s+Model" 找到控制器列表表头后取2行，tail -n1 取最后一行（第一个控制器）
            # awk '{print $1}' 取控制器编号（第1列）
            ctl_no=$(
                "${raid_bin}" show |
                    grep -PA2 "Ctl\s+Model" |
                    tail -n1 | awk '{print $1}'
            )
            local raid_detail=()
            mapfile -t raid_detail < <(
                "${raid_bin}" /c"${ctl_no}" show |
                    # sed -nr 提取 "PD LIST :" 到 "EID=Enclosure Device ID" 之间的 PD 列表段
                    sed -nr '/^PD LIST :/,/EID=Enclosure Device ID/p' |
                    awk '
                        # 匹配 PD 数据行: 以 "EID:Slot" 格式开头（如 "252:0" 或 " :0"）
                        /^(([0-9]+)?|\s*?):[0-9]/{
                            model=""
                            # 第12列到倒数第2列为型号（跳过 EID:Slt DID State DG Size Unit Intf Med SED PI SeSz）
                            for (i=12;i<=NF-2;i++) model=model" "$i
                            gsub(/^\s+/,"",model)  # 去除型号首部空格
                            # 第5列是大小数值，第6列是单位，统一换算为 TB（保留2位小数）
                            if ($6~/T/) size=int($5*10^2+0.5)/10^2          # TB，四舍五入保留2位
                            if ($6~/G/) size=int($5*10^2/1024+0.5)/10^2     # GB → TB
                            if ($6~/M/) size=int($5*10^2/1024/1024+0.5)/10^2 # MB → TB
                            print "{\"type\":\"raid\",\"size\":"size",\"model\":\""model"\"}"
                        }'
            )
            disk_detail+=("${raid_detail[@]}")
        fi
    fi

    # 通过 lsblk 枚举所有块设备，逐一判断是否为直通盘
    # -P 输出 key=value 格式，-d 只列出磁盘本身（不含分区），-o 指定输出列
    # grep disk 过滤出 TYPE="disk" 的行（排除 loop、rom 等）
    local lsblk_info=()
    mapfile -t lsblk_info < <(lsblk -Pdo NAME,MODEL,SERIAL,SIZE,TYPE,VENDOR,TRAN,WWN | grep disk)

    for lsblk_line in "${lsblk_info[@]}"; do
        declare -A disk_info=()
        line="${lsblk_line}"
        # 解析 lsblk -P 输出的 KEY="VALUE" 格式，逐个提取字段到关联数组
        # BASH_REMATCH[1] 是 KEY，BASH_REMATCH[2] 是 VALUE
        # key_lc 将 KEY 转为小写，作为关联数组下标
        while [[ $line =~ ([A-Z]+)=\"([^\"]*)\" ]]; do
            local key val key_lc
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            key_lc="${key,,}"
            disk_info["${key_lc}"]="$val"
            line=${line#*"$key=\"$val\""}  # 消费已匹配的部分，继续解析剩余字段
        done

        local name serial_num size_val vendor tran wwn
        name="${disk_info[name]:-}"
        model="${disk_info[model]:-}"
        serial_num="${disk_info[serial]:-}"
        size="${disk_info[size]:-}"
        type="${disk_info[type]:-}"
        vendor="${disk_info[vendor]:-}"
        tran="${disk_info[tran]:-}"
        wwn="${disk_info[wwn]:-}"

        # 跳过无名称、无大小或非磁盘类型的设备
        if [[ -z "${name}" ]] || [[ -z "${size}" ]] || [[ "${type}" != disk ]]; then
            continue
        fi

        # 将 lsblk 报告的大小统一换算为 TB（浮点数）
        if [[ "${size}" == *T ]]; then
            # 已是 TB，提取数字部分（去掉单位字母）
            size="$(echo "${size}" | grep -oP '\d+(\.\d+)?')"
        elif [[ "${size}" == *G ]]; then
            # GB → TB: 除以 1024，保留2位小数
            local size_num
            size_num="$(echo "${size}" | grep -oP '\d+(\.\d+)?')"
            size="$(awk -v val="${size_num}" 'BEGIN{printf "%.2f", val / 1024}')"
        fi

        # 判断是不是主板直通盘
        if _is_direct_disk "${name}" "${vendor}" "${model}" "${lsblk_line}"; then
            da_disk_detail="$(
                jq -n \
                    --arg serial "${serial_num}" \
                    --arg model "${model}" \
                    --argjson size "${size}" \
                    --arg type "direct" \
                    '{serial: $serial, model: $model, "size": $size, type: $type, unit: "T"}'
            )"
            disk_detail+=("${da_disk_detail}")
        fi
    done

    # 将所有磁盘条目合并为 JSON 数组，包装在 storage 键下输出
    [[ "${#disk_detail[@]}" -ge 1 ]] &&
        printf '%s\n' "${disk_detail[@]}" | jq -s '{storage: .}'
}
