#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034
# =============================================================================
# lib/raid/detector.sh — RAID 控制器类型检测
# =============================================================================
# 被 source 使用，不可直接执行。
# 消除了原 run.sh 和 tsc_raid_health_check.sh 中重复定义的 get_raid_type() 函数。
#
# 提供函数:
#   raid_detect [work_dir]
#     检测当前系统的 RAID 控制器类型，设置全局变量:
#       RAID_TYPE: none | adaptec | mpt3sas | mpt2sas | lsi
#       RAID_BIN:  对应管理工具的完整路径，若未找到则为空字符串
#
# 检测优先级（RAID 类型）:
#   1. Adaptec  — lspci 含 "Adaptec"
#   2. mpt3sas  — lsmod 含 "mpt3sas" 或 lspci 含 "SAS3008"
#   3. mpt2sas  — lsmod 含 "mpt2sas" 或 lspci 含 "LSI2308"
#   4. LSI/MegaRAID — lspci 含 LSI|AVAGO|MegaRAID 等关键字
#
# 工具查找顺序（每种类型）:
#   /bin/<tool> → /sbin/<tool> → packages/<tool>-<arch> → PATH
# =============================================================================

# -----------------------------------------------------------------------------
# raid_detect [work_dir]
#
# 参数:
#   work_dir (可选) — 用于定位 packages/ 目录的基准路径
#                     默认优先使用调用方的 WORK_DIR 变量，
#                     其次使用本文件所在目录的上两级
#
# 输出（设置全局变量）:
#   RAID_TYPE — RAID 控制器类型字符串
#   RAID_BIN  — 管理工具完整路径（找不到时为空字符串）
# -----------------------------------------------------------------------------
raid_detect() {
    local work_dir="${1:-}"

    # 确定 work_dir：优先使用参数，其次使用调用方的 WORK_DIR，最后用相对路径推算
    if [[ -z "${work_dir}" ]]; then
        work_dir="${WORK_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../..}"
    fi

    # packages/ 目录相对于模块根目录的路径
    local pkg_dir="${work_dir}/../packages"

    # 初始化输出变量
    RAID_TYPE="none"
    RAID_BIN=""

    # 采集硬件信息（lspci/lsmod 失败时静默忽略）
    local lspci_info lsmod_info
    lspci_info="$(lspci 2>/dev/null || true)"
    lsmod_info="$(lsmod 2>/dev/null || true)"

    # --- Adaptec RAID 卡检测 ---
    if echo "${lspci_info}" | grep -qiP "Adaptec"; then
        RAID_TYPE="adaptec"
        # 工具名: arcconf，按优先级查找
        if [[ -f /bin/arcconf ]]; then
            RAID_BIN="/bin/arcconf"
        elif [[ -f /sbin/arcconf ]]; then
            RAID_BIN="/sbin/arcconf"
        elif [[ -f "${pkg_dir}/arcconf/arcconf-$(arch)" ]]; then
            RAID_BIN="${pkg_dir}/arcconf/arcconf-$(arch)"
        else
            RAID_BIN="$(command -v arcconf 2>/dev/null || true)"
        fi

    # --- LSI SAS3 (mpt3sas) 检测 ---
    # 通过内核模块名或 PCIe 设备 ID 识别
    elif echo "${lsmod_info}" | grep -qE "^mpt3sas" || echo "${lspci_info}" | grep -q "SAS3008"; then
        RAID_TYPE="mpt3sas"
        # 工具名: sas3ircu
        if [[ -f /bin/sas3ircu ]]; then
            RAID_BIN="/bin/sas3ircu"
        elif [[ -f /sbin/sas3ircu ]]; then
            RAID_BIN="/sbin/sas3ircu"
        elif [[ -f "${pkg_dir}/sas3ircu/sas3ircu-$(arch)" ]]; then
            RAID_BIN="${pkg_dir}/sas3ircu/sas3ircu-$(arch)"
        else
            RAID_BIN="$(command -v sas3ircu 2>/dev/null || true)"
        fi

    # --- LSI SAS2 (mpt2sas) 检测 ---
    elif echo "${lsmod_info}" | grep -qE "^mpt2sas" || echo "${lspci_info}" | grep -q "LSI2308"; then
        RAID_TYPE="mpt2sas"
        # 工具名: sas2ircu
        if [[ -f /bin/sas2ircu ]]; then
            RAID_BIN="/bin/sas2ircu"
        elif [[ -f /sbin/sas2ircu ]]; then
            RAID_BIN="/sbin/sas2ircu"
        elif [[ -f "${pkg_dir}/sas2ircu/sas2ircu-$(arch)" ]]; then
            RAID_BIN="${pkg_dir}/sas2ircu/sas2ircu-$(arch)"
        else
            RAID_BIN="$(command -v sas2ircu 2>/dev/null || true)"
        fi

    # --- LSI/MegaRAID/AVAGO 检测 ---
    # 包含 Intel Lewisburg 平台内置 RAID 控制器
    elif echo "${lspci_info}" | grep -qiP "LSI|AVAGO|MegaRAID|(RAID bus controller: Intel Corporation Lewisburg)"; then
        RAID_TYPE="lsi"
        # 工具名: storcli 或 storcli64，按优先级查找
        if [[ -f /bin/storcli ]]; then
            RAID_BIN="/bin/storcli"
        elif [[ -f /opt/MegaRAID/storcli/storcli64 ]]; then
            # MegaRAID 官方安装路径
            RAID_BIN="/opt/MegaRAID/storcli/storcli64"
        elif [[ -f "${pkg_dir}/storcli64/storcli64-noarch" ]]; then
            RAID_BIN="${pkg_dir}/storcli64/storcli64-noarch"
        elif command -v storcli64 &>/dev/null; then
            RAID_BIN="$(command -v storcli64 2>/dev/null)"
        else
            RAID_BIN="$(command -v storcli 2>/dev/null || true)"
        fi
    fi
    # 若以上均不匹配，RAID_TYPE 保持 "none"，RAID_BIN 保持空字符串
}
