#!/usr/bin/env bash
# benchmark.sh — 固定姿势的 Benchmark 入口（唯一入口，反复跑同一套流程）。
#
# 每次运行：
#   1. 用固定场景 benchmark-scenarios.json 跑 bench.py
#   2. 自动写入 SQLite（docs/reports/auto/benchmark.db）长期跟踪
#   3. 更新 JSON 快照 + Markdown 报告
#
# 用法：
#   ./benchmark.sh            # 完整跑一遍（默认场景，约 1 分钟）
#   ./benchmark.sh --no-server   # 服务器已在运行时
#   ./benchmark.sh --history     # 查看历史记录
#
# 依赖：python3、hey（PATH 中）、mojo（PATH 中）

set -euo pipefail

# 仓库根目录（脚本所在目录）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# 固定输出路径
JSON_OUT="docs/reports/auto/benchmark-results.json"
REPORT_OUT="docs/reports/auto/Benchmark-Baseline.md"
SCENARIOS="benchmark-scenarios.json"

# 前置检查
command -v python3 >/dev/null || { echo "缺少 python3"; exit 1; }
command -v hey >/dev/null || { echo "缺少 hey（go install github.com/rakyll/hey@latest）"; exit 1; }
command -v mojo >/dev/null || { echo "缺少 mojo"; exit 1; }

# --history 直接透传
if [[ "${1:-}" == "--history" ]]; then
    python3 bench.py --history "${@:2}"
    exit 0
fi

echo "=============================================="
echo " FastAPI-Mojo Benchmark（固定姿势）"
echo " 场景配置 : $SCENARIOS"
echo " SQLite   : docs/reports/auto/benchmark.db"
echo " 报告     : $REPORT_OUT"
echo "=============================================="

python3 bench.py \
    --scenarios "$SCENARIOS" \
    --json "$JSON_OUT" \
    --report "$REPORT_OUT" \
    "$@"

echo "=============================================="
echo " 完成。查看历史：./benchmark.sh --history"
echo "=============================================="
