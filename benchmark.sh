#!/usr/bin/env bash
# benchmark.sh — 固定姿势的 Benchmark 入口 (Track B T1: 零 Python).
#
# 每次运行:
#   1. (可选) 构建单一 binary 与 fmtool
#   2. 用固定场景 benchmark-scenarios.json 跑 fmtool bench
#   3. 自动写入 JSONL 历史 (docs/reports/auto/benchmark.jsonl) 长期跟踪
#      (替代原 SQLite benchmark.db — 零第三方依赖, Rust 原生)
#   4. 更新 JSON 快照 + Markdown 报告
#
# 用法:
#   ./benchmark.sh                  # 完整跑一遍 (默认场景, ~1 分钟)
#   ./benchmark.sh --no-server      # 服务器已在运行
#   ./benchmark.sh --history        # 查看历史记录
#
# 依赖: hey (PATH), mojo (PATH); fmtool (./src/fmtool/target/release/fmtool, 缺则自动 build).
# Python 环境: 不再需要 (Track B 达成).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

JSON_OUT="docs/reports/auto/benchmark-results.json"
REPORT_OUT="docs/reports/auto/Benchmark-Baseline.md"
SCENARIOS="benchmark-scenarios.json"
FMTOOL="$ROOT/src/fmtool/target/release/fmtool"

# 前置检查
command -v hey >/dev/null || { echo "缺少 hey（go install github.com/rakyll/hey@latest）"; exit 1; }
command -v mojo >/dev/null || { echo "缺少 mojo"; exit 1; }

# fmtool (自动构建)
if [[ ! -x "$FMTOOL" ]]; then
    echo "fmtool 不存在，自动构建 (Rust toolchain)..."
    (cd "$ROOT/src/fmtool" && cargo build --release) || { echo "fmtool 构建失败"; exit 1; }
    FMTOOL="$ROOT/src/fmtool/target/release/fmtool"
fi

# 单一二进制 (若不存在则自动构建 — benchmark 目标是最终交付物)
if [[ ! -f "$ROOT/build/fastapi_mojo" ]]; then
    echo "build/fastapi_mojo 不存在，自动构建单一二进制..."
    "$ROOT/build_single.sh" || { echo "构建失败"; exit 1; }
fi

# --history 直接透传
if [[ "${1:-}" == "--history" ]]; then
    "$FMTOOL" bench --db "$ROOT/docs/reports/auto/benchmark.jsonl" --history "${@:2}"
    exit 0
fi

echo "=============================================="
echo " FastAPI-Mojo Benchmark (固定姿势, fmtool)"
echo " 场景配置 : $SCENARIOS"
echo " JSONL    : docs/reports/auto/benchmark.jsonl"
echo " 报告     : $REPORT_OUT"
echo " fmtool   : $FMTOOL"
echo "=============================================="

"$FMTOOL" bench \
    --scenarios "$SCENARIOS" \
    --json "$JSON_OUT" \
    --report "$REPORT_OUT" \
    --db "$ROOT/docs/reports/auto/benchmark.jsonl" \
    "$@"

echo "=============================================="
echo " 完成。查看历史：./benchmark.sh --history"
echo "=============================================="
