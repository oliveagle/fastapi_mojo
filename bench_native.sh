#!/usr/bin/env bash
# bench_native.sh — Benchmark the single-binary Mojo HTTP server using curl
#
# Usage:
#   ./bench_native.sh [requests] [concurrency]
#
# Builds the single binary via ./build_single.sh if it does not exist,
# then runs the curl-based benchmark (quick sanity; full fixed-posture
# benchmarks go through ./benchmark.sh per AGENTS.md §4).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/build/fastapi_mojo"
REQUESTS="${1:-100}"
CONCURRENCY="${2:-5}"

echo "=== Mojo Single-Binary Server Benchmark ==="
echo "Requests:    $REQUESTS"
echo "Concurrency: $CONCURRENCY (unused by sequential curl loop)"
echo ""

if [[ ! -f "$BIN" ]]; then
    echo "[1/4] Building single binary..."
    "$ROOT/build_single.sh"
else
    echo "[1/4] Using existing $BIN"
fi

# Start server (static dir = src/fastapi_mojo/static)
echo "[2/4] Starting server on port 8000..."
(
    cd "$ROOT/src/fastapi_mojo"
    exec env -i FASTAPI_MOJO_STATIC_DIR="$ROOT/src/fastapi_mojo/static" "$BIN"
) > /tmp/mojo_bench_server.log 2>&1 &
SERVER_PID=$!
sleep 4

if ! curl -s http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo "ERROR: Server failed to start"; tail -10 /tmp/mojo_bench_server.log
    kill -9 "$SERVER_PID" 2>/dev/null || true
    exit 1
fi

echo "[3/4] Running benchmark..."
benchmark() {
    local url="$1" name="$2" start end elapsed rps
    echo ""
    echo "--- $name ---"
    start=$(date +%s%N)
    for i in $(seq 1 "$REQUESTS"); do
        curl -s "$url" > /dev/null 2>&1
    done
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    [[ $elapsed -lt 1 ]] && elapsed=1
    rps=$(( REQUESTS * 1000 / elapsed ))
    echo "Time: ${elapsed}ms"
    echo "RPS:  ${rps} req/s"
}

benchmark "http://127.0.0.1:8000/" "GET /"
benchmark "http://127.0.0.1:8000/health" "GET /health"
benchmark "http://127.0.0.1:8000/hello?name=Mojo" "GET /hello?name=Mojo"
benchmark "http://127.0.0.1:8000/items/42" "GET /items/42"

echo ""
echo "[4/4] Cleaning up..."
kill -TERM "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
echo "Benchmark complete!"
