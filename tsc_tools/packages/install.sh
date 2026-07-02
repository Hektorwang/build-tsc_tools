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
    ["fping"]="-v"
    ["glow"]="-v"
    ["iperf3"]="-v"
    ["jq"]="-V"
    ["qrencode"]="-V"
    ["sshpass"]="-V"
    ["stress-ng"]="-V"
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
    local is_sas3ircu
    is_sas3ircu="$("${BINARY_TOOLS_DIR}/sas3ircu/sas3ircu-$(arch)" list &>/dev/null)"
    if [[ "${is_sas3ircu:-1}" -ne 0 ]]; then
        \cp "${BINARY_TOOLS_DIR}/sas3ircu/sas3ircu-$(arch)" /bin/sas3ircu
        chmod +x /bin/sas3ircu
        LOGSUCCESS "Installed /bin/sas3ircu"
    fi
    local is_storcli
    is_storcli="$(
        "${BINARY_TOOLS_DIR}/storcli64/storcli64-noarch" show 2>&1 |
            grep -oP "(?<=^Number of Controllers = )\d+"
    )"
    if [[ "${is_storcli:-0}" -ne 0 ]]; then
        \cp "${BINARY_TOOLS_DIR}/storcli64/storcli64-noarch" /bin/storcli64
        ln -sf /bin/storcli64 /bin/storcli
        chmod +x /bin/storcli64
        LOGSUCCESS "Installed /bin/storcli64 /bin/storcli"
    fi
    local arcconf_output
    arcconf_output=$("${BINARY_TOOLS_DIR}/arcconf/arcconf-$(arch)" GETCONFIG 1 PD 2>&1)
    exit_code=$?
    if [[ ${exit_code} -eq 0 ]] && ! echo "${arcconf_output}" | grep -q "Controllers found: 0"; then
        \cp "${BINARY_TOOLS_DIR}/arcconf/arcconf-$(arch)" /bin/arcconf
        chmod +x /bin/arcconf
        LOGSUCCESS "Installed /bin/arcconf"
    fi
}

source "${BINARY_TOOLS_DIR}/../func"

machine_type="${1:-vm}"
_install &&
  _install_raid_cli "${machine_type}" &&
  LOGSUCCESS "Installed tsc_tools binary files"
