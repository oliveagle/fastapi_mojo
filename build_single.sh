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
# Priority: $MODULAR_LIB env (always wins) > python3 import > pip/pip3 show
# > python3.10..3.13 import scan. No hardcoded version-specific path.
find_modular_lib() {
    local d py
    # 1) default python3
    d="$(python3 -c 'import modular, os; d = os.path.dirname(modular.__file__) if getattr(modular, "__file__", None) else modular.__path__[0]; print(os.path.join(d, "lib"))' 2>/dev/null || true)"
    [[ -n "$d" && -d "$d" ]] && { echo "$d"; return 0; }
    # 2) pip show (Location -> site-packages/modular/lib)
    for pipcmd in "python3 -m pip" "pip" "pip3"; do
        d="$($pipcmd show modular 2>/dev/null | awk -F': *' '/^Location:/{print $2}' || true)"
        if [[ -n "$d" && -d "$d/modular/lib" ]]; then echo "$d/modular/lib"; return 0; fi
    done
    # 3) scan other interpreter versions
    for py in python3.13 python3.12 python3.11 python3.10; do
        command -v "$py" >/dev/null 2>&1 || continue
        d="$("$py" -c 'import modular, os; d = os.path.dirname(modular.__file__) if getattr(modular, "__file__", None) else modular.__path__[0]; print(os.path.join(d, "lib"))' 2>/dev/null || true)"
        [[ -n "$d" && -d "$d" ]] && { echo "$d"; return 0; }
    done
    return 1
}

if [[ -z "${MODULAR_LIB:-}" ]]; then
    MODULAR_LIB="$(find_modular_lib || true)"
fi
if [[ -z "${MODULAR_LIB:-}" ]]; then
    echo "ERROR: could not auto-locate the Mojo runtime library dir."
    echo "  tried: python3 import / pip show / python3.10..3.13"
    echo "  fix:   MODULAR_LIB=/path/to/site-packages/modular/lib ./build_single.sh"
    exit 1
fi
for so in libKGENCompilerRTShared.so libMSupportGlobals.so libAsyncRTRuntimeGlobals.so; do
    [[ -f "$MODULAR_LIB/$so" ]] || {
        echo "ERROR: $MODULAR_LIB/$so not found (point MODULAR_LIB at the right modular/lib)"
        exit 1
    }
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

# Embed static assets (single binary: static files travel with the binary).
# Each regular file under $SRC/static becomes an objcopy payload object; the
# shim stages them to <stage_dir>/static/ at startup and tells the bridge
# (set_embedded_static_dir). Max 5 files (EMBED_STATIC_0..4 in runtime_shim.c).
STATIC_PAYLOAD_OBJS=()
STATIC_DEFS=()
n_static=0
if [[ -d "$SRC/static" ]]; then
    for f in "$SRC/static"/*; do
        [[ -f "$f" ]] || continue
        if (( n_static >= 5 )); then
            echo "WARNING: static/ has more than 5 files; embedding only the first 5"
            break
        fi
        name="$(basename "$f")"
        safe="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9_' '_')"
        cp "$f" "$BUILD/static_$safe.bin"
        ( cd "$BUILD" && objcopy -I binary -O elf64-x86-64 "static_$safe.bin" "static_$safe.o" )
        ss=$(nm "$BUILD/static_$safe.o" | awk '$3 ~ /_start$/ {print $3; exit}')
        se=$(nm "$BUILD/static_$safe.o" | awk '$3 ~ /_end$/   {print $3; exit}')
        [[ -n "$ss" && -n "$se" ]] || { echo "ERROR: could not extract symbols for static_$safe.o"; exit 1; }
        STATIC_PAYLOAD_OBJS+=("$BUILD/static_$safe.o")
        STATIC_DEFS+=(-DEMBED_STATIC_${n_static}_NAME="\"$name\"" -DEMBED_STATIC_${n_static}_START="$ss" -DEMBED_STATIC_${n_static}_END="$se")
        echo "  embedded static: $name ($ss)"
        n_static=$((n_static + 1))
    done
fi
STATIC_DEFS+=(-DN_EMBED_STATIC=$n_static)

echo "[3/5] Compiling C bridge + runtime shim..."
gcc -fPIC -O2 -Wall -c "$SRC/http_bridge_final.c" -o "$BUILD/bridge.o"
gcc -fPIC -O2 -Wall -c "$SRC/runtime_shim.c" -o "$BUILD/shim.o" \
    -DKGEN_PAYLOAD_START="${SYM_START[payload_kgen]}"   -DKGEN_PAYLOAD_END="${SYM_END[payload_kgen]}" \
    -DMSUPP_PAYLOAD_START="${SYM_START[payload_msupp]}" -DMSUPP_PAYLOAD_END="${SYM_END[payload_msupp]}" \
    -DASYNCRT_PAYLOAD_START="${SYM_START[payload_asyncrt]}" -DASYNCRT_PAYLOAD_END="${SYM_END[payload_asyncrt]}" \
    "${STATIC_DEFS[@]}"

echo "[4/5] Linking single binary (PIE, shim constructor first)..."
# NOTE: objcopy binary objects carry no .note.GNU-stack; suppress the exec-stack warning.
gcc -fPIE -pie -O2 \
    "$BUILD/shim.o" \
    "$BUILD/server.o" \
    "$BUILD/bridge.o" \
    "$BUILD/payload_kgen.o" \
    "$BUILD/payload_msupp.o" \
    "$BUILD/payload_asyncrt.o" \
    ${STATIC_PAYLOAD_OBJS[@]+"${STATIC_PAYLOAD_OBJS[@]}"} \
    -Wl,--no-warn-mismatch -Wl,-z,noexecstack \
    -o "$OUT" \
    -ldl -lm

echo "[5/5] Verifying dynamic dependencies..."
echo "--- ldd $OUT ---"
ldd "$OUT"
echo
echo "Built: $OUT ($(du -h "$OUT" | cut -f1))"
