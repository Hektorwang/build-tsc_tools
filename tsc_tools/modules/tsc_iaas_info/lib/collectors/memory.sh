#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/collectors/memory.sh — 内存静态信息采集
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 提供函数:
#   collect_mem_info()
#     采集内存插槽信息（每个已安装内存条的容量和位置）
#     输出 JSON: {memory: [{size: N, locator: "...", unit: "G"}, ...]}
# =============================================================================

# -----------------------------------------------------------------------------
# collect_mem_info
#
# 输出:
#   JSON 对象: {memory: [{size: 容量(G), locator: "插槽位置", unit: "G"}, ...]}
#   只包含已安装内存条（过滤 "No Module Installed"）
#
# 数据来源:
#   dmidecode -t17 — SMBIOS 内存设备信息（Type 17）
#   每个内存条对应一个 Size 行和一个 Locator 行，用 sed 'N' 合并为同一行处理
#
# 单位处理:
#   MB → 转换为 GB（除以 1024）
#   GB → 直接使用
#   其他单位（如空槽）→ 跳过
# -----------------------------------------------------------------------------
collect_mem_info() {
    local mem_info

    # 从 dmidecode 读取内存信息，每两行（Size + Locator）合并为一行
    # grep -vP 过滤空行和注释行；grep -P 只保留 Size 和 Locator 行
    # sed 'N;s/\n/\t/g' 将相邻两行合并（Size 行 + Locator 行 → 一行，tab 分隔）
    mapfile -t mem_info < <(
        dmidecode -t17 | grep -vP "^\s*$|^\s*#" | grep -P '^\s*Size:|^\s*Locator:' |
            sed 'N;s/\n/\t/g' |
            grep -v "No Module Installed"   # 过滤空插槽
    )

    for line in "${mem_info[@]}"; do
        local size_val size_unit locator_val

        # 合并行格式: "  Size: 16 GB\t  Locator: DIMM_A1\t  Bank Locator: ..."
        # awk 按空格分割，$2=数值，$3=单位
        size_val="$(awk '{print $2}' <<<"${line}")"
        size_unit="$(awk '{print $3}' <<<"${line}")"

        # cut 取第3个冒号之后的内容（跳过 "Size: 16 GB\t  Locator:" 前缀）
        locator_val="$(cut -d: -f3- <<<"${line}" | sed 's/^ *//')"

        if [[ "${size_unit}" == "MB" ]]; then
            # MB 转 GB
            size_val="$(awk "BEGIN{printf \"%.2f\", ${size_val} / 1024}")"
        elif [[ "${size_unit}" != "GB" ]]; then
            # 非 MB/GB 单位（空槽等）跳过
            continue
        fi

        jq -n \
            --arg locator "${locator_val}" \
            --argjson size "${size_val}" \
            '{"size": $size, locator: $locator, unit: "G"}'
    done |
        # 将多个 JSON 对象合并为数组，包装在 memory 键下
        jq -rcs '{memory: .}'
}
