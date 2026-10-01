#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# =============================================================================
# lib/raid/detector.sh — 卡型注册表与聚合 (DESIGN.md §4.1/§4.2/§4.3)
# =============================================================================
# 被 run.sh source 使用，不可直接执行。
#
# 依赖:
#   cards/*.sh           — source 时经 card_register 自注册
#   extract.sh           — extract_topology / extract_health(通用提取器)
#   jsonio.sh            — degraded_add()(降级记录, 文件背书, 子 shell 可见)
#
# 提供:
#   card_register <type...>   — 卡型自注册入口(cards/*.sh source 末尾调用)
#   raid_detect_cards         — 遍历注册表探测, 结果写入 TSC_DETECTED_CARDS
#   raid_models_json          — 单次抓取缓存: 全量模型数组(§4.4 每卡一次)
#   raid_collect <extractor> [models] — 逐模型套提取器 → 行流
#   raid_topology_json [models]       — 资产模式入口: {"storage":[],"raid_controllers":[]}
#   raid_health_json [models]         — runtime 入口: 健康对象数组
#
# 卡型注册表由各 cards/<type>.sh 在 source 时自注册; 探测只看硬件证据,
# machine_type 不参与闸门(DESIGN §4.3)。
#
# 降级记录经 degraded_add() 写 TSC_DEGRADED_FILE(军规 5): 本文件函数会被
# collect_json 的命令替换与内部 mapfile 的进程替换包进子 shell,
# 数组追加对主流程不可见, 故统一走文件, 由编排层收尾时 degraded_sync() 合并。
# =============================================================================

declare -ga TSC_CARD_TYPES=()
declare -ga TSC_DETECTED_CARDS=()

# -----------------------------------------------------------------------------
# card_register <type...>
# 卡型自注册; 幂等(重复注册忽略)。
# -----------------------------------------------------------------------------
card_register() {
    local t
    for t in "$@"; do
        if [[ " ${TSC_CARD_TYPES[*]} " != *" ${t} "* ]]; then
            TSC_CARD_TYPES+=("${t}")
        fi
    done
}

# -----------------------------------------------------------------------------
# raid_detect_cards
#
# 遍历注册表逐一 card_<t>_detect, 在位卡型写入 TSC_DETECTED_CARDS(覆盖语义)。
# 含 §4.3 互斥规则: 检测到 SAS3 IR 卡时, lsi(storcli)通道不参与本机盘采集
# —— storcli 对 SAS3 IR 卡的状态读取不准(与 packages/install.sh 安装规则一致)。
# -----------------------------------------------------------------------------
raid_detect_cards() {
    TSC_DETECTED_CARDS=()
    local t
    for t in "${TSC_CARD_TYPES[@]}"; do
        if "card_${t}_detect"; then
            TSC_DETECTED_CARDS+=("${t}")
        fi
    done

    if [[ " ${TSC_DETECTED_CARDS[*]} " == *" sas3 "* ]]; then
        local -a keep=()
        for t in "${TSC_DETECTED_CARDS[@]}"; do
            if [[ "${t}" != "lsi" ]]; then
                keep+=("${t}")
            fi
        done
        TSC_DETECTED_CARDS=("${keep[@]}")
    fi
}

# -----------------------------------------------------------------------------
# raid_models_json — 单次抓取缓存(§4.4: 每卡一次抓取)
# 逐在位卡 parse, 全量模型行聚合为 JSON 数组输出。
# runtime 编排先取本数组一次, 再分别派生 topology/health 投影,
# 保证一轮轮询内每卡只抓一次厂商 CLI。
# -----------------------------------------------------------------------------
raid_models_json() {
    local -a models=()
    raid_detect_cards
    local t out rc
    for t in "${TSC_DETECTED_CARDS[@]}"; do
        out=""
        rc=0
        out="$("card_${t}_parse" 2>/dev/null)" || rc=$?
        if (( rc != 0 )); then
            degraded_add "card_${t}_parse"
            continue
        fi
        if [[ -z "${out}" ]]; then
            continue
        fi
        while IFS= read -r full; do
            [[ -n "${full}" ]] && models+=("${full}")
        done <<<"${out}"
    done
    if (( ${#models[@]} == 0 )); then
        printf '[]'
        return 0
    fi
    printf '%s\n' "${models[@]}" | jq -s -c 'map(select(length > 0))'
}

# -----------------------------------------------------------------------------
# raid_collect <extractor> [models数组JSON]
# 逐全量模型套 <extractor> 输出行流; models 缺省时自行抓取(raid_models_json)。
# -----------------------------------------------------------------------------
raid_collect() {
    local extractor="$1"
    local models_json="${2:-}"
    if [[ -z "${models_json}" ]]; then
        models_json="$(raid_models_json)"
    fi
    local full
    while IFS= read -r full; do
        if [[ -z "${full}" ]]; then
            continue
        fi
        if ! "${extractor}" <<<"${full}" 2>/dev/null; then
            degraded_add "${extractor}"
        fi
    done < <(jq -cr '.[]' <<<"${models_json}")
    return 0
}

# -----------------------------------------------------------------------------
# raid_topology_json [models] — 资产模式聚合入口
# 输出: {"storage":[...],"raid_controllers":[...]}(紧凑单行)。
# 条目级模板合并与排序契约(§3.3)由 jsonio_build_static 执行, 此处不排。
# -----------------------------------------------------------------------------
raid_topology_json() {
    local models_json="${1:-}"
    local -a lines=()
    mapfile -t lines < <(raid_collect extract_topology "${models_json}")
    if (( ${#lines[@]} == 0 )); then
        printf '{"storage":[],"raid_controllers":[]}'
        return 0
    fi
    printf '%s\n' "${lines[@]}" \
        | jq -s -c '{storage: [.[] | .storage[]?], raid_controllers: [.[] | .raid_controllers[]?]}'
}

# -----------------------------------------------------------------------------
# raid_health_json [models] — runtime 聚合入口
# 输出: 健康对象数组(紧凑单行), 无数据为 []。
# -----------------------------------------------------------------------------
raid_health_json() {
    local models_json="${1:-}"
    local -a lines=()
    mapfile -t lines < <(raid_collect extract_health "${models_json}")
    if (( ${#lines[@]} == 0 )); then
        printf '[]'
        return 0
    fi
    printf '%s\n' "${lines[@]}" | jq -s -c '.'
}
