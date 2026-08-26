#!/usr/bin/env bash
# build_single.sh — build the fastapi_mojo SINGLE BINARY.
#
# Produces build/fastapi_mojo: one self-contained executable that embeds the
# three Mojo runtime shared libraries (as data) and stages + dlopens them at
# start. Runtime dependencies: libc / libm / libstdc++ / libgcc_s only
# (base system runtimes, per AGENTS.md §1 North Star).
#
# Usage:
#   ./build_single.sh            # build to build/fastapi_mojo
#   ./build_single.sh --clean    # wipe build/ first
#
# Env:
#   MODULAR_LIB  dir containing the Mojo runtime .so files
#                (default: <python site-packages>/modular/lib)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src/fastapi_mojo"
BUILD="$ROOT/build"
OUT="$BUILD/fastapi_mojo"

for tool in mojo gcc objcopy; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not found"; exit 1; }
done

# Locate the Mojo runtime libraries.
if [[ -z "${MODULAR_LIB:-}" ]]; then
    MODULAR_LIB="$(python3 -c 'import modular, os; print(os.path.join(os.path.dirname(modular.__file__), "lib"))' 2>/dev/null || true)"
    [[ -z "$MODULAR_LIB" ]] && MODULAR_LIB="$HOME/.local/lib/python3.12/site-packages/modular/lib"
fi
for so in libKGENCompilerRTShared.so libMSupportGlobals.so libAsyncRTRuntimeGlobals.so; do
    [[ -f "$MODULAR_LIB/$so" ]] || { echo "ERROR: $MODULAR_LIB/$so not found (set MODULAR_LIB)"; exit 1; }
done

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD"

echo "[1/5] Compiling Mojo server -> object (mojo build --emit object)..."
mojo build "$SRC/http_server_final.mojo" --emit object -o "$BUILD/server.o"

echo "[2/5] Embedding Mojo runtime libraries as payload objects..."
declare -A PAYLOAD=(
    [libKGENCompilerRTShared.so]=payload_kgen
    [libMSupportGlobals.so]=payload_msupp
    [libAsyncRTRuntimeGlobals.so]=payload_asyncrt
)
(
    cd "$BUILD"
    for so in "${!PAYLOAD[@]}"; do
        name="${PAYLOAD[$so]}"
        cp "$MODULAR_LIB/$so" "$name.bin"
        # objcopy -I binary derives the section symbol names from the input
        # filename; using a stable basename makes the symbols deterministic.
        objcopy -I binary -O elf64-x86-64 "$name.bin" "$name.o"
    done
)
# Extract the generated <...>_start / <...>_end symbol names per payload.
declare -A SYM_START=() SYM_END=()
for name in payload_kgen payload_msupp payload_asyncrt; do
    s=$(nm "$BUILD/$name.o" | awk '$3 ~ /_start$/ {print $3; exit}')
    e=$(nm "$BUILD/$name.o" | awk '$3 ~ /_end$/   {print $3; exit}')
    [[ -n "$s" && -n "$e" ]] || { echo "ERROR: could not extract payload symbols for $name"; exit 1; }
    SYM_START[$name]="$s"; SYM_END[$name]="$e"
done

echo "[3/5] Compiling C bridge + runtime shim..."
gcc -fPIC -O2 -Wall -c "$SRC/http_bridge_final.c" -o "$BUILD/bridge.o"
gcc -fPIC -O2 -Wall -c "$SRC/runtime_shim.c" -o "$BUILD/shim.o" \
    -DKGEN_PAYLOAD_START="${SYM_START[payload_kgen]}"   -DKGEN_PAYLOAD_END="${SYM_END[payload_kgen]}" \
    -DMSUPP_PAYLOAD_START="${SYM_START[payload_msupp]}" -DMSUPP_PAYLOAD_END="${SYM_END[payload_msupp]}" \
    -DASYNCRT_PAYLOAD_START="${SYM_START[payload_asyncrt]}" -DASYNCRT_PAYLOAD_END="${SYM_END[payload_asyncrt]}"

echo "[4/5] Linking single binary (PIE, shim constructor first)..."
# NOTE: objcopy binary objects carry no .note.GNU-stack; suppress the exec-stack warning.
gcc -fPIE -pie -O2 \
    "$BUILD/shim.o" \
    "$BUILD/server.o" \
    "$BUILD/bridge.o" \
    "$BUILD/payload_kgen.o" \
    "$BUILD/payload_msupp.o" \
    "$BUILD/payload_asyncrt.o" \
    -Wl,--no-warn-mismatch -Wl,-z,noexecstack \
    -o "$OUT" \
    -ldl -lm

echo "[5/5] Verifying dynamic dependencies..."
echo "--- ldd $OUT ---"
ldd "$OUT"
echo
echo "Built: $OUT ($(du -h "$OUT" | cut -f1))"
