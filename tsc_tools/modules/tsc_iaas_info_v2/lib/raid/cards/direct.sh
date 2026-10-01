#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016
# =============================================================================
# lib/raid/cards/direct.sh — 直盘/直通盘适配器 (DESIGN.md §4.2, 阶段1b)
# =============================================================================
# 覆盖对象: 直接挂在主板/HBA 上、未被 RAID 控制器管理的物理磁盘, 以及
# 云主机/VMware 虚拟磁盘(v1 语义保留)。身份与拓扑走 lsblk//sys 通道,
# 不接触任何厂商 CLI(DESIGN.md §4.1)。
#
# 二函数契约(DESIGN.md §4.2):
#   card_direct_detect — 退出码 0=lsblk 可用且有磁盘 / 非0=通道不可用
#   card_direct_parse  — 一行全量模型: controller/vds 为 null,
#                        pds = 直盘条目数组(§3.1 形状, type="direct")
#
# 通道所有权(§4.2 约束7): _is_direct_disk 四条件排除 RAID/HBA 管理的设备,
# 保证一块盘不与 RAID CLI 通道双重上报。
# =============================================================================

# -----------------------------------------------------------------------------
# _is_direct_disk <name> <vendor> <model> <lsblk_line>
#
# 判断块设备是否为直通盘(非 RAID 逻辑卷)。短路求值, 按优先级:
#   1. 含 "Virtual disk"/"VMware" 关键字 → 虚拟化直通盘, 是直通盘
#   2. 厂商为 LSI/DELL/HP/AVAGO → RAID 卡厂商设备, 不是直通盘
#   3. 型号含 "LOGICAL" → RAID 逻辑卷, 不是直通盘
#   4. sysfs 总线路径对应的 PCIe 设备是 RAID 控制器 → 不是直通盘
#   5. 以上均不满足 → 视为直通盘
# 迁移自 v1 lib/collectors/storage.sh, 判断语义不变。
# -----------------------------------------------------------------------------
_is_direct_disk() {
    local name="$1" vendor="$2" model="$3" lsblk_line="$4"

    # 条件1: 云主机/VMware 虚拟磁盘按直通盘处理
    echo "${lsblk_line}" | grep -qiP "Virtual disk|VMware" && return 0

    # 条件2: RAID 卡厂商的设备通常是 RAID 逻辑卷
    echo "${vendor}" | grep -qP "LSI|DELL|HP|AVAGO" && return 1

    # 条件3: 逻辑卷不是直通盘
    echo "${model}" | grep -q 'LOGICAL' && return 1

    # 条件4: sysfs 总线路径 → PCIe 设备是否 RAID 控制器
    # 例: /sys/devices/pci0000:00/0000:00:1f.2/ata1/... 取 "00:1f.2|ata1"
    # 片段后到 lspci 比对; 系统无 sysfs 路径/无 lspci 时该条件自然跳过
    local bus_path
    bus_path="$(readlink -f "/sys/block/${name}" 2>/dev/null | awk -F/ '{print $5"|"$6}' | sed 's/\b0000://g')"
    if [[ -n "${bus_path}" ]] && lspci 2>/dev/null | grep -E "${bus_path}" | grep -qiE "raid|Adaptec|Avago|LSI|MegaRAID|RAID bus controller"; then
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# card_direct_detect
# lsblk 可用且存在 TYPE=disk 的块设备 → 0; 否则非 0。
# -----------------------------------------------------------------------------
card_direct_detect() {
    command -v lsblk >/dev/null 2>&1 || return 1
    lsblk -Pdo NAME,TYPE 2>/dev/null | grep -q 'TYPE="disk"'
}

# -----------------------------------------------------------------------------
# card_direct_parse
#
# lsblk 单抓取(§4.4) → 逐盘归一 → 一行全量模型。
# 条目字段: dev 必有; ctl_no/enc/slot/vd/state 恒 null(type="direct");
# lsblk 不报告盘状态, 可枚举到即视为在线(state_norm="online");
# size/unit 保留 lsblk 原始值, size_gb 由 to_gb 数值化(失败落 null);
# interface 取 lsblk TRAN。空串字段统一落 null。
# -----------------------------------------------------------------------------
card_direct_parse() {
    local -a lsblk_info=()
    mapfile -t lsblk_info < <(lsblk -Pdo NAME,MODEL,SERIAL,SIZE,TYPE,VENDOR,TRAN,WWN 2>/dev/null | grep 'TYPE="disk"')

    local -a pds=()
    local line name model serial_num size type vendor tran wwn
    local num unit size_gb_json gbid entry

    for line in "${lsblk_info[@]}"; do
        # KEY="VALUE" 解析到关联数组(键小写); bash 4.2 兼容, 不用 nameref
        declare -A disk_info=()
        local rest="${line}" kv_key kv_val
        while [[ ${rest} =~ ([A-Z]+)=\"([^\"]*)\" ]]; do
            kv_key="${BASH_REMATCH[1]}"
            kv_val="${BASH_REMATCH[2]}"
            disk_info["${kv_key,,}"]="${kv_val}"
            rest=${rest#*"${kv_key}=\"${kv_val}\""}
        done

        name="${disk_info[name]:-}"
        model="${disk_info[model]:-}"
        serial_num="${disk_info[serial]:-}"
        size="${disk_info[size]:-}"
        type="${disk_info[type]:-}"
        vendor="${disk_info[vendor]:-}"
        tran="${disk_info[tran]:-}"
        wwn="${disk_info[wwn]:-}"

        if [[ -z "${name}" ]] || [[ -z "${size}" ]] || [[ "${type}" != "disk" ]]; then
            continue
        fi

        if ! _is_direct_disk "${name}" "${vendor}" "${model}" "${line}"; then
            continue
        fi

        # SIZE 拆数值+单字母后缀: "894.3G" → 894.3 / G; 无后缀视为字节
        num="${size%%[!0-9.]*}"
        unit="${size##*[0-9.]}"
        [[ -z "${unit}" ]] && unit="B"
        if [[ -z "${num}" ]] || ! [[ "${num}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            # 非常规 SIZE 值: 保留原文, 数值化落 null, 不中断(军规 5)
            num="${size}"
            size_gb_json="null"
        else
            size_gb_json="null"
            if gbid="$(to_gb "${num}" "${unit}" 2>/dev/null)" && [[ -n "${gbid}" ]]; then
                size_gb_json="${gbid}"
            fi
        fi

        entry="$(json_line -n \
            --arg dev "/dev/${name}" \
            --arg model "${model}" \
            --arg serial "${serial_num}" \
            --arg wwn "${wwn}" \
            --arg size "${num}" \
            --arg unit "${unit}" \
            --argjson size_gb "${size_gb_json}" \
            --arg interface "${tran}" \
            '{
               dev: (if $dev == "" then null else $dev end),
               type: "direct",
               ctl_no: null, enc: null, slot: null, vd: null,
               state: null, state_norm: "online",
               size: (if $size == "" then null else $size end),
               unit: (if $unit == "" then null else $unit end),
               size_gb: $size_gb,
               model: (if $model == "" then null else $model end),
               serial: (if $serial == "" then null else $serial end),
               wwn: (if $wwn == "" then null else $wwn end),
               interface: (if $interface == "" then null else $interface end)
             }')" || continue
        pds+=("${entry}")
    done

    if (( ${#pds[@]} == 0 )); then
        json_line -n '{card:"direct",ctl_no:null,controller:null,vds:null,pds:[],sections_failed:[]}'
        return 0
    fi
    printf '%s\n' "${pds[@]}" \
        | jq -s -c '{card:"direct",ctl_no:null,controller:null,vds:null,pds:.,sections_failed:[]}'
}

# 自注册(DESIGN.md §4.1)
card_register direct
