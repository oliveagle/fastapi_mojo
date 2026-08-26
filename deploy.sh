#!/usr/bin/env bash
# deploy.sh — build + verify the SINGLE-BINARY fastapi_mojo for deployment.
#
# The deliverable is ONE self-contained executable:
#   <output_dir>/fastapi_mojo
#
# It embeds the three Mojo runtime shared libraries as data and, at startup,
# stages them to a private temp dir (/dev/shm or /tmp) and dlopens them.
# Dynamic dependencies: libc / libm / libstdc++ / libgcc_s only (base system
# runtimes, per AGENTS.md §1 North Star). No Python, no pip, no .venv, no
# sidecar .so files.
#
# Usage:
#   ./deploy.sh                 # build + verify, output build/deploy/fastapi_mojo
#   ./deploy.sh <output_dir>
#
# Verification performed:
#   1. ldd shows no Mojo runtime .so as a direct dependency
#   2. the binary runs in a clean env (env -i) and answers /health
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$ROOT/build/deploy}"

command -v mojo >/dev/null || { echo "ERROR: mojo not found"; exit 1; }
command -v gcc >/dev/null || { echo "ERROR: gcc not found"; exit 1; }

echo "=== fastapi_mojo Single-Binary Deployment ==="

# Step 1: build the single binary
echo "[1/3] Building single binary (./build_single.sh)..."
"$ROOT/build_single.sh"

BIN="$ROOT/build/fastapi_mojo"
[[ -f "$BIN" ]] || { echo "ERROR: $BIN not produced"; exit 1; }

# Step 2: copy to output dir (single file)
echo "[2/3] Installing to $OUTPUT_DIR ..."
mkdir -p "$OUTPUT_DIR"
cp "$BIN" "$OUTPUT_DIR/fastapi_mojo"
chmod +x "$OUTPUT_DIR/fastapi_mojo"

# Step 3: verify self-containment
echo "[3/3] Verifying single binary..."
echo "--- direct dynamic dependencies (must be libc/libm/ld-linux only) ---"
NEEDED=$(ldd "$OUTPUT_DIR/fastapi_mojo" | awk -F' => ' '/=>/ {print $2}' | awk '{print $1}' | sort -u)
echo "$NEEDED"
for lib in libKGENCompilerRTShared.so libMSupportGlobals.so libAsyncRTRuntimeGlobals.so; do
    if echo "$NEEDED" | grep -qx "$lib"; then
        echo "ERROR: $lib is a direct dependency — not a single binary"; exit 1
    fi
done

# Clean-env smoke test (no LD_LIBRARY_PATH, no Python)
cd "$ROOT/src/fastapi_mojo"
env -i "$OUTPUT_DIR/fastapi_mojo" > /tmp/fastapi_mojo_deploy_smoke.log 2>&1 &
PID=$!
sleep 4
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health 2>/dev/null || echo "000")
kill -TERM "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
if [[ "$CODE" == "200" ]]; then
    echo "OK: clean-env /health returned 200 (self-contained)"
else
    echo "ERROR: clean-env /health returned '$CODE'"; tail -5 /tmp/fastapi_mojo_deploy_smoke.log; exit 1
fi

echo
echo "=== Deployment complete ==="
ls -lh "$OUTPUT_DIR/"
echo
echo "Deploy:  scp $OUTPUT_DIR/fastapi_mojo user@host:/opt/fastapi_mojo/"
echo "Run:     /opt/fastapi_mojo          # listens on http://127.0.0.1:8000"
echo "Static:  set FASTAPI_MOJO_STATIC_DIR=/opt/static (optional)"
