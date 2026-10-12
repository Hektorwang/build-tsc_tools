##################################################
# 运行环境检测与准入校验
#
# 本文件是单一事实源, 被两处复用:
#   1. build.sh 将其内联进 RPM %pre 脚本 (彼时包文件未落盘, 必须自包含)
#   2. 随包发布为 /home/tsc/tsc_tools/lib/env_check.sh, 供 %post 复用
#
# 前置条件 (调用方保证):
#   - 已提供 LOGDEBUG/LOGINFO/LOGSUCCESS/LOGWARNING/LOGERROR
#     (%pre 用 lib_min.sh, %post 用 tsc_tools/func)
#   - 已 source .supported_env.conf (提供 SUPPORTED_* 变量)
#   - 已声明 declare -A system_info
##################################################

##################################################
# 检测系统信息，包括发行版、版本、内核、架构等
# 并判断该机器是虚拟机 (VM) 还是物理机 (PM)
# 全局变量:
#   None
# 参数:
#   None
# 输出:
#   简要文本格式的系统信息 (输出到 stdout，每行一个 key=value 对)
# 返回:
#   0 - 成功
#   1 - Bash 版本过低
##################################################
detect_system_info() {
    if ((BASH_VERSINFO[0] < 4)); then
        LOGERROR "Bash version too low, requires at least 4.0" >&2
        return 1
    fi

    local -A DISTRO_VARIETY_MAP=(
        [ubuntu]="Debian"
        [debian]="Debian"
        [linuxmint]="Debian"
        [centos]="RedHat"
        [rhel]="RedHat"
        [fedora]="RedHat"
        [rocky]="RedHat"
        [almalinux]="RedHat"
        [kylin]="RedHat"
        [neokylin]="RedHat"
        [arch]="Arch"
        [manjaro]="Arch"
        [alpine]="Alpine"
        [suse]="Suse"
        [opensuse]="Suse"
        [fitserveros]="Euler"
        [fitstarryskyos]="Euler"
        [openeuler]="Euler"
        [hce]="Euler"
        [ningos]="Euler"
    )

    [[ -f /etc/os-release ]] && source /etc/os-release

    local distribution_version machine_architecture distribution_major_version
    distribution_version="${VERSION_ID:-unknown}"
    machine_architecture="$(uname -m)"
    distribution_major_version="$(echo "$distribution_version" | cut -d. -f1)"

    local ids=()
    [[ -n "$ID" ]] && ids+=("$ID")
    IFS=' ' read -ra id_likes <<<"${ID_LIKE:-}"
    ids+=("${id_likes[@]}")

    local distribution_file_variety="unknown" id_lc
    for id in "${ids[@]}"; do
        id_lc="$(echo "$id" | tr '[:upper:]' '[:lower:]')"
        if [[ -n "${DISTRO_VARIETY_MAP[$id_lc]}" ]]; then
            distribution_file_variety="${DISTRO_VARIETY_MAP[$id_lc]}"
            break
        fi
    done

    local service_mgr="unknown"
    if pidof systemd &>/dev/null; then
        service_mgr="systemd"
    elif command -v rc-service &>/dev/null; then
        service_mgr="openrc"
    elif command -v sv &>/dev/null; then
        service_mgr="runit"
    fi

    local machine_type="pm"
    local vm_product_name_patterns="${VM_PRODUCT_NAME_PATTERNS:-virtualbox|vmware|kvm|qemu|openstack|xen|bochs|bhyve|parallels|xen|hyper-v|cloud|google|amazon|digital|huawei|nutanix|oracle|aliyun|tencent|ucloud|aws|azure|gcp}"
    local product_name="unknown" product_name_lc

    if [[ -f /sys/class/dmi/id/product_name ]]; then
        product_name="$(</sys/class/dmi/id/product_name)"
        product_name_lc="$(echo "$product_name" | tr '[:upper:]' '[:lower:]')"
        if [[ "$product_name_lc" =~ $vm_product_name_patterns ]]; then
            machine_type="vm"
        fi
    elif [[ -f /proc/cpuinfo ]]; then
        if grep -qiE "hypervisor|vmware|kvm" /proc/cpuinfo; then
            machine_type="vm"
        fi
    fi

    echo "os_distribution_file_variety=$distribution_file_variety"
    echo "machine_architecture=$machine_architecture"
    echo "os_distribution_major_version=$distribution_major_version"
    echo "os_service_mgr=$service_mgr"
    echo "machine_type=$machine_type"
    return 0
}

##################################################
# Checks if the current system environment meets the installation requirements
# Reads the configuration file for supported environment information and compares it with data collected by system_info
# Global Variables:
#   system_info (associative array, must be populated before calling)
#   SUPPORTED_ARCHITECTURES, SUPPORTED_SERVICE_MANAGER, DISTRO_VERSION_RULES_*
# Parameters:
#   None (config file path implicitly included via global variable SUPPORTED_ENV_FILE)
# Output:
#   Detailed check result logs
# Returns:
#   0 - Environment check passed
#   127 - Environment check failed
##################################################
check_env() {
    LOGINFO "${FUNCNAME[0]}"
    local ret=0
    if [[ "$EUID" != "0" ]]; then
        LOGERROR "Insufficient privileges: Script must be run with root privilege."
        ret=127
    fi
    LOGINFO "detect_system_info"
    while IFS='=' read -r key value; do
        system_info["$key"]="$value"
    done < <(detect_system_info)

    local current_arch="${system_info[machine_architecture]:-unknown}"
    local current_distro_variety="${system_info[os_distribution_file_variety]:-unknown}"
    local current_major_version="${system_info[os_distribution_major_version]:-unknown}"
    local current_service_mgr="${system_info[os_service_mgr]:-unknown}"

    IFS=',' read -r -a supported_archs_array <<<"$SUPPORTED_ARCHITECTURES"
    if ! is_element_in_array "$current_arch" "${supported_archs_array[@]}"; then
        LOGERROR "Architecture incompatible: Current system architecture '${current_arch}' is not in the supported list '${SUPPORTED_ARCHITECTURES}'."
        ret=127
    fi

    local distro_version_check_passed=false
    local distro_rule_var_name="DISTRO_VERSION_RULES_${current_distro_variety}"
    local supported_versions_for_distro="${!distro_rule_var_name:-}"
    if [[ -z "$supported_versions_for_distro" ]]; then
        # If no rule found for the current distribution family, consider it incompatible
        LOGERROR "Distribution/Version not supported: No version rules found for distribution family '${current_distro_variety}' in the configuration file."
        ret=127
    elif [[ "$supported_versions_for_distro" == "*" ]]; then
        # If the rule is "*", it means all versions are supported
        distro_version_check_passed=true
    else
        # Check specific versions
        local current_version_found_in_rule=false
        IFS=',' read -r -a allowed_versions_array <<<"$supported_versions_for_distro"
        for allowed_ver in "${allowed_versions_array[@]}"; do
            if [[ "$current_major_version" == "$allowed_ver" ]]; then
                current_version_found_in_rule=true
                break
            fi
        done
        if "$current_version_found_in_rule"; then
            distro_version_check_passed=true
            LOGINFO "Distribution/Version compatible: Major version '${current_major_version}' of distribution family '${current_distro_variety}' is supported."
        else
            LOGERROR "Distribution/Version incompatible: Major version '${current_major_version}' of distribution family '${current_distro_variety}' is not in the supported list '${supported_versions_for_distro}'."
            ret=127
        fi
    fi
    if ! "$distro_version_check_passed"; then
        ret=127
    fi

    if [[ "${ret}" -ne 0 ]]; then
        LOGERROR "${FUNCNAME[0]}"
    else
        LOGSUCCESS "${FUNCNAME[0]}"
    fi
    return "${ret}"
}
