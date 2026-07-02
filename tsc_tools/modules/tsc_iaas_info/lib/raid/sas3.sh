#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2148
# =============================================================================
# lib/raid/sas3.sh - SAS3 (mpt3sas) RAID 卡适配器
# =============================================================================
# 被 source 使用，不可直接执行。
#
# 支持的控制器: LSI SAS3008、SAS3108 等 mpt3sas 驱动的 HBA/RAID 卡
# 管理工具: sas3ircu
#
# 依赖:
#   lib/common.sh - LD_KEYWORDS, PD_KEYWORDS, associate_array_to_json()
#
# 提供函数:
#   raid_sas3 <raid_bin> <run_mode>
#     遍历所有 SAS3 控制器，采集 IR Volume（虚拟卷）和物理磁盘状态
#     结果追加到全局变量 raid_status_json（调用方需先初始化为 "[]"）
#
# sas3ircu 输出格式说明:
#   sas3ircu list         - 列出所有控制器，格式: "  0  SAS3008  ..."
#   sas3ircu N display    - 显示控制器N的详情
#     IR Volume 段: "IR Volume information" 到 "Physical device information"
#     PD 段: "Physical device information" 到 "Enclosure information"
#     PD 行格式: "Enclosure#:2;Slot#:12;State:Ready(RDY)"（去空格后）
#
# 注意: 现场通常不用 SAS3 卡做 RAID Volume，VD 解析逻辑来自老代码改造，
#       未经实际 IR Volume 场景验证
# =============================================================================

# -----------------------------------------------------------------------------
# raid_sas3 <raid_bin> <run_mode>
#
# 参数:
#   raid_bin - sas3ircu 的完整路径
#   run_mode - 运行模式 runtime/collect
# 副作用:
#   追加到全局变量 raid_status_json（JSON 数组）
# -----------------------------------------------------------------------------
raid_sas3() {
  local RAID_BIN="$1"
  local run_mode="$2" # runtime/collect
  local ctls=() ctl_no

  # 获取所有控制器编号
  # grep -P 匹配以数字开头且含 "SAS" 的行（控制器列表行）
  # awk 取第1列（控制器编号）
  mapfile -t ctls < <("${RAID_BIN}" list | grep -P "^\s*\d.*?SAS" | awk '{print $1}')

  for ctl_no in "${ctls[@]}"; do
    # --- 处理物理磁盘 ---
    # raid_status_json
    local raid_status_json_all
    raid_status_json_all="$(
      "${RAID_BIN}" "${ctl_no}" display |
        awk '/Physical device information/,/Enclosure information/{print}' |
        grep -A 13 "Device is a Hard disk" |
        awk -v ctl_no="${ctl_no}" -v map="$PD_KEYWORDS_MAP" '
        BEGIN {
          RS="--"; FS="\n"
          n = split(map, lines, "\n")
          for (i=1; i<=n; i++) {
            if (lines[i] == "") continue
            split(lines[i], pair, "|")
            if (pair[1] != "") { patterns[++pcount] = pair[1]; chinese[pcount] = pair[2] }
          }
        }
        {
          slot=""; model=""; serial=""; size_mb="0"; pd_stat=""; pd_stat_cn="未知(未识别状态)"
          for (i=1; i<=NF; i++) {
            line = $i
            if (match(line, /^[[:space:]]*Slot #[[:space:]]*:[[:space:]]*(.*)$/, m))     slot = trim(m[1])
            else if (match(line, /^[[:space:]]*Model Number[[:space:]]*:[[:space:]]*(.*)$/, m))   model = trim(m[1])
            else if (match(line, /^[[:space:]]*Serial No[[:space:]]*:[[:space:]]*(.*)$/, m))    serial = trim(m[1])
            else if (match(line, /^[[:space:]]*Size \(in MB\)\/\(in sectors\)[[:space:]]*:[[:space:]]*(.*)$/, m)) {
              split(trim(m[1]), sz, "/"); size_mb = trim(sz[1])
            }
            else if (match(line, /^[[:space:]]*State[[:space:]]*:[[:space:]]*(.*)$/, m)) {
              pd_stat = trim(m[1])
              for (j=1; j<=pcount; j++) {
                if (index(tolower(pd_stat), tolower(patterns[j])) > 0) {
                  pd_stat_cn = chinese[j]; break
                }
              }
            }
          }
          if (slot == "") next
          size_tb = (size_mb + 0) / 1024 / 1024
          size_tb = int(size_tb * 100 + 0.5) / 100
          out =  "{"
          out = out "\"ctl_no\":\""  esc(ctl_no)  "\","
          out = out "\"slot\":\""  esc(slot)  "\","
          out = out "\"model\":\""   esc(model)   "\","
          out = out "\"serial\":\""  esc(serial)  "\","
          out = out "\"size\":"   size_tb    ","
          out = out "\"pd_stat\":\"" esc(pd_stat) "\","
          out = out "\"阵列卡号\":\"" esc(ctl_no) "\","
          out = out "\"物理磁盘号\":\"" esc(slot) "\","
          out = out "\"物理磁盘状态\":\"" esc(pd_stat) "\","
          out = out "\"物理磁盘中文状态\":\"" esc(pd_stat_cn) "\","
          out = out "\"type\":\"raid\","
          out = out "\"unit\":\"T\""
          out = out "}"
          print out
        }
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function esc(s)  { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
      ' | jq -s '.'
    )"
    case "${run_mode}" in
    collect)
      echo "${raid_status_json_all}" |
        jq 'map({ctl_no, slot, model, serial, type, size, unit})'
      ;;
    runtime)
      # 仅当 runtime 模式才关心 vd 状态
      # --- 处理 IR Volume（虚拟卷）---
      local vd_output=() vd_line
      # awk 提取 "IR Volume information" 到 "Physical device information" 之间的内容
      # grep 过滤出 IR volume 编号行和状态行
      # sed 合并相邻两行，去除空格
      mapfile -t vd_output < <(
        "${RAID_BIN}" "${ctl_no}" display |
          awk '/IR Volume information/,/Physical device information/{print}' |
          grep -E "IR volume|Status of volume" |
          sed 'N;s/\n/;/g' |
          sed 's/ //g'
      )
      local vd_no vd_stat vd_stat_cn vd_keyword raid_status_json_vd="[]"
      # 如果有 vd 才取 vd 信息
      if [[ ${vd_output:-novd} != novd ]]; then
        for vd_line in "${vd_output[@]}"; do
          # 合并行格式: "IRvolume1;Statusofvolume:Okay(OKY)"
          vd_no="$(echo "${vd_line}" | awk -F '[;:]' '{print $2}')"
          vd_stat="$(echo "${vd_line}" | awk -F ":" '{print $NF}')"
          vd_stat_cn=""
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
          raid_status_json_vd="$(
            jq -c --argjson new "$(associate_array_to_json vd_info)" '. + [$new]' <<<"$raid_status_json"
          )"
        done
      fi
      local raid_status_json_pd
      raid_status_json_pd="$(
        echo "${raid_status_json_all}" |
          jq 'map({"阵列卡号", "物理磁盘号", "物理磁盘状态", "物理磁盘中文状态"})'
      )"
      raid_status_json=$(
        jq -s '.[0] + .[1]' <(echo "$raid_status_json_vd") <(echo "$raid_status_json_pd")
      )
      ;;
    *)
      return
      ;;
    esac
  done
}
