#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

# set -o errexit
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob

BINARY_TOOLS_DIR="$(readlink -f "$(dirname "$0")")"

# 目前支持的二进制工具
readonly -A SUPPORTED_BINARY_TOOLS=(
    ["fio"]="-v"
    ["glow"]="-v"
    ["iperf3"]="-v"
    ["jq"]="-V"
    ["qrencode"]="-V"
    ["sshpass"]="-V"
    ["stress-ng"]="-V"
    ["yq_go"]="-V"
)

##################################################
# 安装二进制工具
# 全局变量:
#   BINARY_TOOLS_DIR       (二进制工具所在目录)
#   SUPPORTED_BINARY_TOOLS (array, 支持的二进制工具)
# 参数:
#   None
##################################################
_install() {
    local tool_name failed_tools=() installed_tools=() missing_tools=()
    mkdir -p /home/tsc/tsc_tools/bin/
    for tool_name in "${!SUPPORTED_BINARY_TOOLS[@]}"; do
        if [[ -f "${BINARY_TOOLS_DIR}"/"${tool_name}"/"${tool_name}-noarch" ]]; then
            \cp "${BINARY_TOOLS_DIR}/${tool_name}/${tool_name}-noarch" /home/tsc/tsc_tools/bin/"${tool_name}"
            chmod a+x /home/tsc/tsc_tools/bin/"${tool_name}"
        fi
        if [[ -f "${BINARY_TOOLS_DIR}"/"${tool_name}"/"${tool_name}-$(arch)" ]]; then
            \cp "${BINARY_TOOLS_DIR}/${tool_name}/${tool_name}-$(arch)" /home/tsc/tsc_tools/bin/"${tool_name}"
            chmod a+x /home/tsc/tsc_tools/bin/"${tool_name}"
        fi
        if ! "${tool_name}" "${SUPPORTED_BINARY_TOOLS[${tool_name}]}" &>/dev/null; then
            \cp /home/tsc/tsc_tools/bin/"${tool_name}" /bin/"${tool_name}"
            installed_tools+=("${tool_name}")
        fi
    done
    if [[ ${#installed_tools[@]} -gt 0 ]]; then
        LOGSUCCESS "Installed tools: ${installed_tools[*]}"
    fi
    LOGINFO "Install vimrc"
    \cp "${BINARY_TOOLS_DIR}"/vimrc /root/.vimrc
    LOGSUCCESS "Installed vimrc"
}

_install_raid_cli() {
    if [[ $1 != "pm" ]]; then
        return 0
    fi
    local probe_output probe_rc ctl_count sas3ircu_detected=false

    # sas3ircu: list 成功(检测到 SAS3 控制器)才安装; 原先命令替换内
    # &>/dev/null 把输出连同退出码一并丢弃, 探测恒真变成一律安装
    local sas3ircu_bin="${BINARY_TOOLS_DIR}/sas3ircu/sas3ircu-$(arch)"
    if [[ ! -f "${sas3ircu_bin}" ]]; then
        LOGWARNING "sas3ircu binary not bundled, skip install"
    else
        probe_output="$("${sas3ircu_bin}" list 2>&1)" && probe_rc=0 || probe_rc=$?
        if [[ ${probe_rc} -eq 0 ]]; then
            sas3ircu_detected=true
            if \cp "${sas3ircu_bin}" /bin/sas3ircu && chmod +x /bin/sas3ircu; then
                LOGSUCCESS "Installed /bin/sas3ircu"
            else
                LOGERROR "Failed to install /bin/sas3ircu"
            fi
        fi
    fi

    # storcli: SAS3 卡(mpt3sas/HBA)的 RAID 状态用 storcli 读取不准,
    # 检测到 SAS3 卡后跳过 storcli, 仅在无 SAS3 卡且存在 MegaRAID
    # 控制器时安装。
    # storcli 无控制器时也返回 0, 须从输出中取控制器数; 二进制本身无法
    # 运行(缺失/架构不符)时原先被静默跳过, 现告警
    if "${sas3ircu_detected}"; then
        LOGINFO "SAS3 controller detected, skip storcli (storcli status is inaccurate for SAS3 IR cards)"
    else
        local storcli_bin="${BINARY_TOOLS_DIR}/storcli64/storcli64-noarch"
        if [[ ! -f "${storcli_bin}" ]]; then
            LOGWARNING "storcli64 binary not bundled, skip install"
        else
            probe_output="$("${storcli_bin}" show 2>&1)" && probe_rc=0 || probe_rc=$?
            if [[ ${probe_rc} -ne 0 ]]; then
                LOGWARNING "storcli64 probe failed (rc=${probe_rc}), skip install: $(head -n 1 <<<"${probe_output}")"
            else
                ctl_count="$(grep -oP '(?<=^Number of Controllers = )\d+' <<<"${probe_output}")"
                if [[ -z "${ctl_count}" ]]; then
                    LOGWARNING "cannot determine storcli controller count, skip install"
                elif [[ ${ctl_count} -ne 0 ]]; then
                    if \cp "${storcli_bin}" /bin/storcli64 && ln -sf /bin/storcli64 /bin/storcli && chmod +x /bin/storcli64; then
                        LOGSUCCESS "Installed /bin/storcli64 /bin/storcli"
                    else
                        LOGERROR "Failed to install /bin/storcli64 /bin/storcli"
                    fi
                fi
            fi
        fi
    fi

    # arcconf: 退出码为 0 且控制器数非 0 才安装 (Adaptec, 与 LSI 互不影响)
    local arcconf_bin="${BINARY_TOOLS_DIR}/arcconf/arcconf-$(arch)"
    if [[ ! -f "${arcconf_bin}" ]]; then
        LOGWARNING "arcconf binary not bundled, skip install"
    else
        probe_output="$("${arcconf_bin}" GETCONFIG 1 PD 2>&1)" && probe_rc=0 || probe_rc=$?
        if [[ ${probe_rc} -eq 0 ]] && ! grep -q "Controllers found: 0" <<<"${probe_output}"; then
            if \cp "${arcconf_bin}" /bin/arcconf && chmod +x /bin/arcconf; then
                LOGSUCCESS "Installed /bin/arcconf"
            else
                LOGERROR "Failed to install /bin/arcconf"
            fi
        fi
    fi
}

source "${BINARY_TOOLS_DIR}/../func"

machine_type="${1:-vm}"
_install &&
  _install_raid_cli "${machine_type}" &&
  LOGSUCCESS "Installed tsc_tools binary files"
