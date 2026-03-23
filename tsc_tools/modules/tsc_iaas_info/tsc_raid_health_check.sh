#!/usr/bin/env bash
# RAID健康检查独立脚本，输出JSON格式
set -o errexit
set -o nounset
set -o pipefail
set +o posix
shopt -s nullglob

# 故障关键字, 按严重级别从高到低写, 确保匹配顺序
LD_KEYWORDS=(
    "Offline|严重(离线)"
    "OfLn|严重(离线)"
    "Impacted|告警(条带化错误)"
    "InterimRecovery|告警(尝试临时恢复)"
    "Rebuild|告警(正在重建)"
    "Degraded|告警(被降级)"
    "Pdgd|告警(部分降级)"
    "Dgrd|告警(被降级)"
    "Optimal|信息(正常)"
    "OK|信息(正常)"
    "Optl|信息(正常)"
    "Online|信息(在线)"
)
PD_KEYWORDS=(
    "Offln|严重(离线)"
    "Failed|严重(损坏)"
    "Offline|严重(离线)"
    "Unconfigured(bad)|告警(已坏未使用)"
    "Rebuild|告警(正在重建)"
    "Foreign|告警(含阵列配置的待用盘)"
    "Rbld|告警(正在重建)"
    "UBad|告警(已坏未使用)"
    "DHS|信息(热备盘)"
    "GHS|信息(全局热备盘)"
    "Hot Spare|信息(热备盘)"
    "Hotspare,Spundown|信息(热备盘)"
    "JBOD|信息(正常)"
    "OK|信息(正常)"
    "Online,SpunUp|信息(在线)"
    "Online|信息(在线)"
    "Onln|信息(在线)"
    "Optimal|信息(正常)"
    "Raw|信息(直通盘)"
    "Ready|信息(未配置Raid)"
    "Sntze|信息(清洁状态)"
    "UGood|信息(未格式化待用)"
    "Unconfigured(good)|信息(未格式化待用)"
)
# 最终结果 [{vd_info_obj},{vd_info_obj},{pd_info_obj},{pd_info_obj}]
raid_status_json="[]"

declare -A RAID_INFO

associate_array_to_json() {
    local arr_name="$1"
    local sep=$'\u0019'
    local out="" key val

    # 获取 keys（按 keys 顺序取值）
    set -f
    eval "keys=(\"\${!${arr_name}[@]}\")" 2>/dev/null || keys=()
    set +f
    if ((${#keys[@]} == 0)); then
        printf '%s\n' '{}'
        return
    fi

    for key in "${keys[@]}"; do
        # 按 key 顺序安全读取 value（若未定义则为空）
        set -f
        eval "val=\${${arr_name}[\"\$key\"]-}" 2>/dev/null || val=""
        set +f
        out+="${key}${sep}${val}${sep}"
    done

    # 用 jq 将 NUL 分隔流转换为紧凑 JSON 输出
    printf '%s' "$out" | jq -R -s --arg sep "$sep" -c '
        (split($sep)[:-1]) as $a |
        [range(0; ($a|length); 2) | { ($a[.]) : $a[. + 1] }] |
        add
    '
}
array_to_json() {
    local sep=$'\u0019'
    {
        for v in "$@"; do
            printf '%s%s' "$v" "$sep"
        done
    } |
        jq -Rrcs --arg sep "$sep" '
            (split($sep)[:-1]) as $a | $a
        '
}

get_raid_type() {
    RAID_INFO[type]="none"
    RAID_INFO[bin]=""
    local lspci_info lsmod_info
    lspci_info="$(lspci)"
    lsmod_info="$(lsmod)"
    if echo "${lspci_info}" | grep -qiP "Adaptec"; then
        RAID_INFO[type]="adaptec"
        if [[ -f /bin/arcconf ]]; then
            RAID_INFO[bin]="/bin/arcconf"
        elif [[ -f /sbin/arcconf ]]; then
            RAID_INFO[bin]="/sbin/arcconf"
        elif [[ -f "${WORK_DIR}/../packages/arcconf/arcconf-$(arch)" ]]; then
            RAID_INFO[bin]="${WORK_DIR}/../packages/arcconf/arcconf-$(arch)"
        else
            RAID_INFO[bin]="$(command -v arcconf 2>/dev/null || echo false)"
        fi
    elif echo "${lsmod_info}" | grep -qE "^mpt3sas" || echo "${lspci_info}" | grep -q "SAS3008"; then
        RAID_INFO[type]="mpt3sas"
        if [[ -f /bin/sas3ircu ]]; then
            RAID_INFO[bin]="/bin/sas3ircu"
        elif [[ -f /sbin/sas3ircu ]]; then
            RAID_INFO[bin]="/sbin/sas3ircu"
        elif [[ -f "${WORK_DIR}/../packages/sas3ircu/sas3ircu-$(arch)" ]]; then
            RAID_INFO[bin]="${WORK_DIR}/../packages/sas3ircu/sas3ircu-$(arch)"
        else
            RAID_INFO[bin]="$(command -v sas3ircu 2>/dev/null || echo false)"
        fi
    elif echo "${lsmod_info}" | grep -qE "^mpt2sas" ||
        echo "${lspci_info}" | grep -q "LSI2308"; then
        RAID_INFO[type]="mpt2sas"
        if [[ -f /bin/sas2ircu ]]; then
            RAID_INFO[bin]="/bin/sas2ircu"
        elif [[ -f /sbin/sas2ircu ]]; then
            RAID_INFO[bin]="/sbin/sas2ircu"
        elif [[ -f "${WORK_DIR}/../packages/sas2ircu/sas2ircu-$(arch)" ]]; then
            RAID_INFO[bin]="${WORK_DIR}/../packages/sas2ircu/sas2ircu-$(arch)"
        else
            RAID_INFO[bin]="$(command -v sas2ircu 2>/dev/null || echo false)"
        fi
    elif echo "${lspci_info}" |
        grep -qiP "LSI|AVAGO|MegaRAID|(RAID bus controller: Intel Corporation Lewisburg)"; then
        RAID_INFO[type]="lsi"
        if [[ -f /bin/storcli ]]; then
            RAID_INFO[bin]="/bin/storcli"
        elif [[ -f /opt/MegaRAID/storcli/storcli64 ]]; then
            RAID_INFO[bin]="/opt/MegaRAID/storcli/storcli64"
        elif [[ -f "${WORK_DIR}/../packages/storcli64/storcli64-noarch" ]]; then
            RAID_INFO[bin]="${WORK_DIR}/../packages/storcli64/storcli64-noarch"
        elif command -v storcli64 &>/dev/null; then
            RAID_INFO[bin]="$(command -v storcli64 2>/dev/null)"
        else
            RAID_INFO[bin]="$(command -v storcli 2>/dev/null || echo false)"
        fi
    fi
}

check_lsi() {
    # 获取 ctl 数量
    local RAID_BIN=$1
    local ctl_cnt ctl_no vd_cnt
    ctl_cnt="$("${RAID_BIN}" show | awk '/Number of Controllers/{print $NF}')"
    # 遍历 ctl
    for ((ctl_no = 0; ctl_no < "${ctl_cnt}"; ctl_no++)); do
        storcli_out="$("${RAID_BIN}" /c"${ctl_no}" show 2>/dev/null)"
        # 获取 vd 数量, 遍历各 vd 状态
        # {"阵列卡号":"0", "虚拟磁盘号": "2", "虚拟磁盘状态":"OfLn","虚拟磁盘中文状态":"严重(离线)"}
        vd_cnt="$(echo "${storcli_out}" | awk '/Virtual Drives/{print $NF}')"
        local vd_no vd_stat vd_keyword vd_stat_cn line
        unset vd_info
        local -A vd_info
        # 摘出 vd list 这一段, 逐行对比 vd 状态, 并追加到总结果 raid_status_json
        while read -r line; do
            vd_no="$(echo "${line}" | awk -F / '{print $1}')"
            vd_stat="$(echo "${line}" | awk '{print $3}')"
            for vd_keyword in "${LD_KEYWORDS[@]}"; do
                if echo "${vd_stat}" | grep -iq "${vd_keyword%%|*}"; then
                    vd_stat_cn="${vd_keyword##*|}"
                    break
                fi
            done
            vd_info=(
                [阵列卡号]="${ctl_no}"
                [虚拟磁盘号]="${vd_no}"
                [虚拟磁盘状态]="${vd_stat}"g+
                [虚拟磁盘中文状态]="${vd_stat_cn}"
            )
            # 将 vd_info append 到 raid_status_json 中
            raid_status_json="$(
                jq -c --argjson new "$(associate_array_to_json vd_info)" '. + [$new]' <<<"$raid_status_json"
            )"
        done < <(echo "${storcli_out}" | grep -A "$((vd_cnt + 5))" "VD LIST" | tail -n "${vd_cnt}")

        # 获取 pd 数量, 遍历各 pd 状态, 对比状态表, 将结果追加到总结果 raid_status_json
        local pd_cnt pd_no pd_stat pd_keyword pd_stat_cn
        pd_cnt="$(echo "${storcli_out}" | awk '/Physical Drives/{print $NF}')"
        unset pd_info
        local -A pd_info line
        # 摘出 vd list 这一段, 逐行对比 vd 状态, 并追加到总结果 raid_status_json
        while read -r line; do
            pd_no="$(echo "${line}" | awk '{print $1}')"
            pd_stat="$(echo "${line}" | awk '{print $3}')"
            for pd_keyword in "${PD_KEYWORDS[@]}"; do
                if echo "${pd_stat}" | grep -iq "${pd_keyword%%|*}"; then
                    pd_stat_cn="${pd_keyword##*|}"
                    break
                fi
            done
            pd_info=(
                [阵列卡号]="${ctl_no}"
                [物理磁盘号]="${pd_no}"
                [物理磁盘状态]="${pd_stat}"
                [物理磁盘中文状态]="${pd_stat_cn}"
            )
            # 将 pd_info append 到 raid_status_json 中
            raid_status_json="$(
                jq -c --argjson new "$(associate_array_to_json pd_info)" '. + [$new]' <<<"$raid_status_json"
            )"
        done < <(echo "${storcli_out}" | grep -A "$((pd_cnt + 5))" "PD LIST" | tail -n "${pd_cnt}")
    done
}

check_sas3() {
    # 获取 ctl 数量
    local RAID_BIN=$1
    local ctls ctl_no vd_cnt pd_output vd_output pd_line vd_line

    mapfile -t ctls < <("${RAID_BIN}" list | grep -P "^\s*\d.*?SAS" | awk '{print $1}')
    # for ((i = 0; i < $array_num; i++)); do
    #     /etc/zabbix/script/$command $i display | awk '/IR Volume information/,/Physical device information/{print}' | grep -E "IR volume|Status of volume" | sed 'N;s/\n/;/g' | sed 's/ //g' | sed 's/^/Raid卡'${array[i]}'&;/g' >>/tmp/lsi_array_info.txt 2>/dev/null
    #     /etc/zabbix/script/$command $i display | awk '/Physical device information/,/Enclosure information/{print}' | grep -A 13 "Device is a Hard disk" | grep -E "Slot|State" | sed 'N;s/\n/;/g' | sed 's/ //g' | sed 's/^/Raid卡'${array[i]}'&;/g' >>/tmp/lsi_array_info.txt 2>/dev/null
    # done
    # 遍历 ctl
    for ctl_no in "${ctls[@]}"; do
        # vd这一段, 现场没有用这个卡做vd的, 所以是从老代码改造来的, 没有实际测过
        unset vd_output
        mapfile -t vd_output < <(
            "${RAID_BIN}" "${ctl_no}" display |
                awk '/IR Volume information/,/Physical device information/{print}' |
                grep -E "IR volume|Status of volume" |
                sed 'N;s/\n/;/g' |
                sed 's/ //g'
        )
        for vd_line in "${vd_output[@]}"; do
            vd_no="$(echo "${vd_line}" | awk -F '[;:]' '{print $2}')"
            vd_stat="$(echo "${pd_line}" | awk -F ":" '{print $NF}')"
            for vd_keyword in "${LD_KEYWORDS[@]}"; do
                if echo "${vd_stat}" | grep -iq "${vd_keyword%%|*}"; then
                    vd_stat_cn="${vd_keyword##*|}"
                    break
                fi
            done
            unset vd_info
            local -A vd_info
            vd_info=(
                [阵列卡号]="${ctl_no}"
                [虚拟磁盘号]="${vd_no}"
                [虚拟磁盘状态]="${vd_stat}"
                [虚拟磁盘中文状态]="${vd_stat_cn}"
            )
            # 将 pd_info append 到 raid_status_json 中
            raid_status_json="$(
                jq -c --argjson new "$(associate_array_to_json vd_info)" '. + [$new]' <<<"$raid_status_json"
            )"
        done

        unset pd_output
        mapfile -t pd_output < <(
            "${RAID_BIN}" "${ctl_no}" display |
                awk '/Physical device information/,/Enclosure information/{print}' |
                grep -A 13 "Device is a Hard disk" |
                grep -E "Slot|State" |
                sed 'N;s/\n/;/g' | sed 's/ //g'
        )
        # Enclosure#:2;Slot#:12;State:Ready(RDY)
        for pd_line in "${pd_output[@]}"; do
            pd_no="$(echo "${pd_line}" | awk -F '[;:]' '{print $2}')"
            pd_stat="$(echo "${pd_line}" | awk -F '[;:]' '{print $4}')"
            for pd_keyword in "${PD_KEYWORDS[@]}"; do
                if echo "${pd_stat}" | grep -iq "${pd_keyword%%|*}"; then
                    pd_stat_cn="${pd_keyword##*|}"
                    break
                fi
            done
            unset pd_info
            local -A pd_info
            pd_info=(
                [阵列卡号]="${ctl_no}"
                [物理磁盘号]="${pd_no}"
                [物理磁盘状态]="${pd_stat}"
                [物理磁盘中文状态]="${pd_stat_cn}"
            )
            # 将 pd_info append 到 raid_status_json 中
            raid_status_json="$(
                jq -c --argjson new "$(associate_array_to_json pd_info)" '. + [$new]' <<<"$raid_status_json"
            )"
        done
    done
}

check_adaptec() {
    local RAID_BIN=$1
    local ctl_no="0" # 这个未见到有多个阵列卡的可能只会有一个
    local vd_output vd_line
    mapfile -t vd_output < <(
        "${RAID_BIN}" GETCONFIG 1 LD |
            grep -E "Logical Device number|Status of Logical Device" |
            sed -E 'N; s/\n/;/; s/(Logical Device number)/\1:/g; s/[[:space:]]+//g'
    )
    local vd_no vd_stat vd_stat_cn vd_keyword
    for vd_line in "${vd_output[@]}"; do
        vd_no="$(echo "${vd_line}" | awk -F '[;:]' '{print $2}')"
        vd_stat="$(echo "${vd_line}" | awk -F ":" '{print $NF}')"
        for vd_keyword in "${LD_KEYWORDS[@]}"; do
            if echo "${vd_stat}" | grep -iq "${vd_keyword%%|*}"; then
                vd_stat_cn="${vd_keyword##*|}"
                break
            fi
        done
        unset vd_info
        local -A vd_info
        vd_info=(
            [阵列卡号]="${ctl_no}"
            [虚拟磁盘号]="${vd_no}"
            [虚拟磁盘状态]="${vd_stat}"
            [虚拟磁盘中文状态]="${vd_stat_cn}"
        )
        # 将 pd_info append 到 raid_status_json 中
        raid_status_json="$(
            jq -c --argjson new "$(associate_array_to_json vd_info)" '. + [$new]' <<<"$raid_status_json"
        )"
    done

    local pd_output pd_line
    mapfile -t pd_output < <(
        "${RAID_BIN}" GETCONFIG 1 PD |
            grep -Ew "Device |State" |
            grep -v "Power State" |
            sed -E ' N; s/\n/;/g; s/[[:space:]]+//g' |
            grep State
    )
    local pd_no pd_stat pd_keyword pd_stat_cn
    for pd_line in "${pd_output[@]}"; do
        pd_no="$(echo "${pd_line}" | awk -F '[#;:]' '{print $2}')"
        pd_stat="$(echo "${pd_line}" | awk -F '[#;:]' '{print $NF}')"
        for pd_keyword in "${PD_KEYWORDS[@]}"; do
            if echo "${pd_stat}" | grep -iq "${pd_keyword%%|*}"; then
                pd_stat_cn="${pd_keyword##*|}"
                break
            fi
        done
        unset pd_info
        local -A pd_info
        pd_info=(
            [阵列卡号]="${ctl_no}"
            [物理磁盘号]="${pd_no}"
            [物理磁盘状态]="${pd_stat}"
            [物理磁盘中文状态]="${pd_stat_cn}"
        )
        # 将 pd_info append 到 raid_status_json 中
        raid_status_json="$(
            jq -c --argjson new "$(associate_array_to_json pd_info)" '. + [$new]' <<<"$raid_status_json"
        )"
    done
}

get_raid_type

case "${RAID_INFO[type]}" in
none)
    exit 0
    ;;
mpt3sas)
    check_sas3 "${RAID_INFO[bin]}"
    ;;
lsi)
    check_lsi "${RAID_INFO[bin]}"
    ;;
adaptec)
    check_adaptec "${RAID_INFO[bin]}"
    ;;
*)
    exit 255
    ;;
esac

echo "${raid_status_json}" | jq -rc .
