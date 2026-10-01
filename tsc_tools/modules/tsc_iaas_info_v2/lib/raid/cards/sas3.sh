#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016
# =============================================================================
# lib/raid/cards/sas3.sh — SAS3 (mpt3sas) 适配器 (DESIGN.md §4.2/§4.4, 阶段3)
# =============================================================================
# 覆盖: LSI SAS3008/SAS3108 等 mpt3sas 驱动的 HBA/IR 卡; 工具: sas3ircu。
# 解析与 sas2 同构, 共享 cards/sas_ir.sh(§4.2: 解析框架通用)。
# =============================================================================

# shellcheck source=sas_ir.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sas_ir.sh"

card_sas3_detect() {
    _sas_ir_detect sas3ircu mpt3sas "SAS3008"
}

card_sas3_parse() {
    local bin
    bin="$(card_find_tool sas3ircu "${TSC_PKG_DIR}/sas3ircu/sas3ircu-$(arch)")" || return 1
    # 控制器清单: sas3ircu list → 首列为索引号的行
    local -a ctls=()
    mapfile -t ctls < <("${bin}" list 2>/dev/null | grep -E '^[[:space:]]*[0-9]+.*SAS' | awk '{print $1}')
    if (( ${#ctls[@]} == 0 )); then
        return 1
    fi
    local ctl_no
    for ctl_no in "${ctls[@]}"; do
        _sas_ir_parse sas3ircu "${ctl_no}" sas3
    done
    return 0
}

# 自注册(DESIGN.md §4.1)
card_register sas3
