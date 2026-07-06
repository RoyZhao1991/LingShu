#!/usr/bin/env bash
# 灵枢短程回归基线入口。
#
# 用法:
#   bash Scripts/regression-baseline.sh unit
#   bash Scripts/regression-baseline.sh live
#   bash Scripts/regression-baseline.sh full-live
#
# unit:     只跑离线单测中的核心链路守卫。
# live:     连接当前运行的灵枢,跑 quick 产品化 MCP 基线。
# full-live:连接当前运行的灵枢,追加演示/队列探针。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-unit}"

run_unit() {
  echo "==> 离线核心链路单测"
  swift test --package-path "$ROOT" --filter StructuredRoutingEndToEndTests
  swift test --package-path "$ROOT" --filter DispatchQueueTests
  swift test --package-path "$ROOT" --filter ContextAssemblyTraceTests
  swift test --package-path "$ROOT" --filter TaskThreadLedgerTests
  swift test --package-path "$ROOT" --filter TaskCompletionGateTests
  swift test --package-path "$ROOT" --filter ToolDispatchTests
  swift test --package-path "$ROOT" --filter WriteFilePathResolveTests
  swift test --package-path "$ROOT" --filter ArchitectureGuardTests
}

run_live() {
  local live_mode="$1"
  echo "==> 当前运行实例 MCP 产品化基线($live_mode)"
  python3 "$ROOT/Scripts/lingshu-product-baseline.py" "--$live_mode" --report-to-chat
}

case "$MODE" in
  unit)
    run_unit
    ;;
  live)
    run_live quick
    ;;
  full-live)
    run_live full
    ;;
  all)
    run_unit
    run_live quick
    ;;
  *)
    echo "未知模式: $MODE (unit|live|full-live|all)" >&2
    exit 2
    ;;
esac
