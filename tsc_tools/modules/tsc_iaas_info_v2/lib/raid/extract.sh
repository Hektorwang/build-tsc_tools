#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# =============================================================================
# lib/raid/extract.sh — 通用提取器 (DESIGN.md §4.2)
# =============================================================================
# 被 run.sh / detector.sh source 使用，不可直接执行。
# 与卡型无关: 输入一律是"一行全量模型 JSON"(§3.4), 输出投影条目。
# 只投影不判断(约束5): 状态比对/告警逻辑在 monitors 层。
#
# 提供:
#   extract_topology  — 全量模型 → {"storage":[...],"raid_controllers":[...]}
#                       (资产模式; 组装层再做条目级模板合并与排序)
#   extract_health    — 全量模型 → kind 标记健康对象行
#                       (runtime 模式; kind: pd|vd|ctl)
# =============================================================================

# -----------------------------------------------------------------------------
# extract_topology  (stdin: 一行全量模型; stdout: 一行投影对象)
# -----------------------------------------------------------------------------
extract_topology() {
    jq -c '
      {
        storage: (.pds // []),
        raid_controllers: (
          if .controller == null or .controller == {} then
            []
          else
            [.controller]
          end
        )
      }
    '
}

# -----------------------------------------------------------------------------
# extract_health  (stdin: 一行全量模型; stdout: 每行一个健康对象)
# 形状(DESIGN §4.2 节选示意, 阶段2定稿):
#   {"kind":"pd","card":"lsi","ctl_no":0,"dev":null,"enc":252,"slot":0,
#    "vd":"0","state":"Onln","state_norm":"online"}
#   {"kind":"vd","card":"lsi","ctl_no":0,"vd":"0","state":"Optl","state_norm":"online"}
#   {"kind":"ctl","card":"lsi","ctl_no":0,"name":"...","health":"Opt","health_norm":"online"}
# -----------------------------------------------------------------------------
extract_health() {
    jq -c '
      . as $root
      | (
          [$root.pds[]? | {
              kind: "pd", card: $root.card, ctl_no: $root.ctl_no,
              dev: .dev, enc: .enc, slot: .slot, vd: .vd,
              state: .state, state_norm: .state_norm
          }]
          + [$root.vds[]? | {
              kind: "vd", card: $root.card, ctl_no: $root.ctl_no,
              vd: .vd, state: .state, state_norm: .state_norm
          }]
          + (if $root.controller == null or $root.controller == {} then
              []
            else
              [{
                  kind: "ctl", card: $root.card, ctl_no: $root.ctl_no,
                  name: $root.controller.name,
                  health: $root.controller.health,
                  health_norm: $root.controller.health_norm
              }]
            end)
        )
      | .[]
    '
}
