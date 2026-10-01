#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016
# =============================================================================
# lib/raid/cards/sas2.sh — SAS2 (mpt2sas) 适配器 (DESIGN.md §4.2/§4.4, 阶段4)
# =============================================================================
# 覆盖: LSI SAS2008/2308 等 mpt2sas 驱动的 HBA/IR 卡; 工具: sas2ircu。
# 补齐 v1 缺失的采集分支(release-note TODO 11); 解析共享 cards/sas_ir.sh。
# =============================================================================

# shellcheck source=sas_ir.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sas_ir.sh"

card_sas2_detect() {
    _sas_ir_detect sas2ircu mpt2sas "LSI2308"
}

card_sas2_parse() {
    local bin
    bin="$(card_find_tool sas2ircu "${TSC_PKG_DIR}/sas2ircu/sas2ircu-$(arch)")" || return 1
    local -a ctls=()
    mapfile -t ctls < <("${bin}" list 2>/dev/null | grep -E '^[[:space:]]*[0-9]+.*SAS' | awk '{print $1}')
    if (( ${#ctls[@]} == 0 )); then
        return 1
    fi
    local ctl_no
    for ctl_no in "${ctls[@]}"; do
        _sas_ir_parse sas2ircu "${ctl_no}" sas2
    done
    return 0
}

# 自注册(DESIGN.md §4.1)
card_register sas2
