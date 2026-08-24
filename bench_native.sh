#!/usr/bin/env bash
# bench_native.sh — Benchmark the native Mojo HTTP server using curl
#
# Usage:
#   ./bench_native.sh [requests] [concurrency]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src/fastapi_mojo"
REQUESTS="${1:-100}"
CONCURRENCY="${2:-5}"

echo "=== Mojo Native Server Benchmark ==="
echo "Requests:    $REQUESTS"
echo "Concurrency: $CONCURRENCY"
echo ""

# Build and start server
echo "[1/4] Building server..."
gcc -c "$SRC/http_bridge_final.c" -o /tmp/http_bridge_final.o
mojo build "$SRC/http_server_final.mojo" \
    -o /tmp/mojo_bench \
    -Xlinker /tmp/http_bridge_final.o 2>/dev/null

echo "[2/4] Starting server on port 8000..."
/tmp/mojo_bench &
SERVER_PID=$!
sleep 3

# Verify server is up
if ! curl -s http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo "ERROR: Server failed to start"
    kill $SERVER_PID 2>/dev/null
    exit 1
fi

echo "[3/4] Running benchmark..."

# Benchmark function
benchmark() {
    local url="$1"
    local name="$2"
    local start end elapsed rps

    echo ""
    echo "--- $name ---"
    start=$(date +%s%N)
    for i in $(seq 1 $REQUESTS); do
        curl -s "$url" > /dev/null 2>&1
    done
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    rps=$(( REQUESTS * 1000 / elapsed ))
    echo "Time: ${elapsed}ms"
    echo "RPS:  ${rps} req/s"
}

# Run benchmarks
benchmark "http://127.0.0.1:8000/" "GET /"
benchmark "http://127.0.0.1:8000/health" "GET /health"
benchmark "http://127.0.0.1:8000/hello?name=Mojo" "GET /hello?name=Mojo"
benchmark "http://127.0.0.1:8000/items/42" "GET /items/42"

# Cleanup
echo ""
echo "[4/4] Cleaning up..."
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

echo ""
echo "Benchmark complete!"
