#!/usr/bin/env bash
# deploy.sh — Build + bundle Mojo runtime .so for zero-dependency deployment
#
# Usage:
#   ./deploy.sh [output_dir]
#
# Produces:
#   <output_dir>/
#     fastapi_mojo          (binary)
#     libKGENCompilerRTShared.so
#     libMSupportGlobals.so
#     libAsyncRTRuntimeGlobals.so
#
# The binary uses RPATH=$ORIGIN to find .so files in the same directory.
# Deployment: scp -r <output_dir>/ user@host:/opt/fastapi_mojo/

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$ROOT/build/deploy}"
MOJO_LIB_DIR="${MODULAR_LIB:-$HOME/.local/lib/python3.12/site-packages/modular/lib}"

echo "=== Mojo Deployment Builder ==="
echo "Source:  $ROOT/src/fastapi_mojo"
echo "Output:  $OUTPUT_DIR"
echo "Mojo lib: $MOJO_LIB_DIR"

# Check prerequisites
command -v mojo >/dev/null || { echo "ERROR: mojo not found"; exit 1; }
command -v patchelf >/dev/null || { echo "ERROR: patchelf not found (apt install patchelf)"; exit 1; }

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Step 1: Build the binary
echo "[1/3] Building http_server_v2.mojo..."
mojo build "$ROOT/src/fastapi_mojo/http_server_v2.mojo" \
    -o "$OUTPUT_DIR/fastapi_mojo" \
    -Xlinker -L"$ROOT/src/fastapi_mojo" \
    -Xlinker -lhttp_bridge_v3

# Step 2: Copy Mojo runtime .so files
echo "[2/3] Copying Mojo runtime .so files..."
for lib in libKGENCompilerRTShared.so libMSupportGlobals.so libAsyncRTRuntimeGlobals.so; do
    if [[ -f "$MOJO_LIB_DIR/$lib" ]]; then
        cp "$MOJO_LIB_DIR/$lib" "$OUTPUT_DIR/"
        echo "  Copied $lib"
    else
        echo "  WARNING: $lib not found in $MOJO_LIB_DIR"
    fi
done

# Copy C helper .so from source directory
if [[ -f "$ROOT/src/fastapi_mojo/libhttp_bridge_v3.so" ]]; then
    cp "$ROOT/src/fastapi_mojo/libhttp_bridge_v3.so" "$OUTPUT_DIR/"
    echo "  Copied libhttp_bridge_v3.so"
fi

# Step 3: Set RPATH to $ORIGIN (find .so in same directory as binary)
echo "[3/3] Setting RPATH to \$ORIGIN..."
patchelf --set-rpath '$ORIGIN' --force-rpath "$OUTPUT_DIR/fastapi_mojo"

# Verify
echo ""
echo "=== Verification ==="
readelf -d "$OUTPUT_DIR/fastapi_mojo" 2>/dev/null | grep -E "RPATH|RUNPATH"
echo ""
echo "=== Deployment Directory ==="
ls -lh "$OUTPUT_DIR/"
echo ""
echo "=== Test Run ==="
cd "$OUTPUT_DIR" && timeout 3 ./fastapi_mojo &
sleep 1
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/ 2>/dev/null || echo "000")
kill %1 2>/dev/null; wait 2>/dev/null
if [[ "$HTTP_CODE" == "200" ]]; then
    echo "OK: HTTP server responds with 200 (no Python needed)"
else
    echo "WARNING: HTTP code=$HTTP_CODE (may need Python for full server)"
fi

echo ""
echo "Deploy with: scp -r $OUTPUT_DIR/ user@host:/opt/fastapi_mojo/"
