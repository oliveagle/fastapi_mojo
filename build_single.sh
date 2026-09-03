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

for tool in mojo gcc objcopy cargo; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not found"; exit 1; }
done

# Locate the Mojo runtime libraries (Track B T3 — shell-only, 无 python3).
# Priority: $MODULAR_LIB env (always wins) > 已知候选目录扫描 (site-packages).
# 替代之前的 python3 import / pip show / python3.X scan 路径; modular pip
# 包安装规则固定 (PEP 370 + distutils), 各用户/系统路径可直接枚举.
#
# 已知 modular 安装形态 (实测):
#   $XDG_DATA_HOME/python3.X/site-packages/modular/lib     (PEP 370 user install)
#   $HOME/.local/lib/python3.X/site-packages/modular/lib  (pip --user default)
#   /usr/local/lib/python3.X/{dist,site}-packages/modular/lib  (system pip)
#   /opt/conda/lib/python3.X/site-packages/modular/lib    (conda)
#   $HOME/.modular/lib  (自解压 portable 安装, 罕见但可能)
# 通用方法: 找名为 libKGENCompilerRTShared.so 的祖先目录 (modular 装包必带此文件).
find_modular_lib() {
    local d found
    # 1) PEP 370 + pip --user site-packages 候选
    for base in \
        "${XDG_DATA_HOME:-$HOME/.local/share}/python3.13/site-packages" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/python3.12/site-packages" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/python3.11/site-packages" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/python3.10/site-packages" \
        "$HOME/.local/lib/python3.13/site-packages" \
        "$HOME/.local/lib/python3.12/site-packages" \
        "$HOME/.local/lib/python3.11/site-packages" \
        "$HOME/.local/lib/python3.10/site-packages" \
        /usr/local/lib/python3.13/dist-packages \
        /usr/local/lib/python3.12/dist-packages \
        /usr/local/lib/python3.11/dist-packages \
        /usr/local/lib/python3.10/dist-packages \
        /usr/local/lib/python3.13/site-packages \
        /usr/local/lib/python3.12/site-packages \
        /usr/local/lib/python3.11/site-packages \
        /usr/local/lib/python3.10/site-packages \
        /usr/lib/python3.13/dist-packages \
        /usr/lib/python3.12/dist-packages \
        /opt/conda/lib/python3.13/site-packages \
        /opt/conda/lib/python3.12/site-packages \
    ; do
        d="$base/modular/lib"
        [[ -d "$d" && -f "$d/libKGENCompilerRTShared.so" ]] && { echo "$d"; return 0; }
    done
    # 2) 通用兜底: 找 libKGENCompilerRTShared.so 定位 (深度局限, 快)
    #    典型地点: site-packages / dist-packages / portable 安装目录
    found="$(find \
        "$HOME/.local" /usr/local /opt 2>/dev/null \
        -maxdepth 8 -type f -name libKGENCompilerRTShared.so -print -quit 2>/dev/null)"
    if [[ -n "$found" ]]; then
        d="$(dirname "$found")"
        [[ -d "$d" && -f "$d/libKGENCompilerRTShared.so" ]] && { echo "$d"; return 0; }
    fi
    return 1
}

if [[ -z "${MODULAR_LIB:-}" ]]; then
    MODULAR_LIB="$(find_modular_lib || true)"
fi
if [[ -z "${MODULAR_LIB:-}" ]]; then
    echo "ERROR: could not auto-locate the Mojo runtime library dir."
    echo "  tried: \$XDG_DATA_HOME/site-packages, ~/.local/lib/python3.X/site-packages,"
    echo "         /usr{,/local}/lib/python3.X/{dist,site}-packages, /opt/conda/lib/python3.X/site-packages,"
    echo "         and a bounded find for libKGENCompilerRTShared.so under ~/.local /usr/local /opt."
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
STATIC_NAMES=()
STATIC_STARTS=()
STATIC_ENDS=()
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
        STATIC_NAMES+=("$name")
        STATIC_STARTS+=("$ss")
        STATIC_ENDS+=("$se")
        echo "  embedded static: $name ($ss)"
        n_static=$((n_static + 1))
    done
fi
STATIC_DEFS+=(-DN_EMBED_STATIC=$n_static)

echo "[3/5] Building Rust bridge (DC1 ws + DC2 http_bridge + DC3 shim; C 清零)..."

# Rust bridge (staticlib): ws (DC1) + HTTP bridge (DC2, 15 子模块 + ffi.rs) + shim (DC3).
# 链接顺序: --whole-archive 拉入全部对象 (含 shim 的 .init_array 构造器); shim
# 早于 Mojo 首次 KGEN_CompilerRT_* 引用 (实测 server.o 无 .init_array, Mojo 在
# main 首次 dispatch 才触发 KGEN 调用, shim 在 .init_array 即可).
RS_DIR="$ROOT/src/fastapi_mojo_rs"
RS_LIB="$RS_DIR/target/release/libfastapi_mojo_rs.a"

# DC1: ws.c -> ws.rs (已删).
# DC2: http_bridge_final.c -> bridge/* 15 子模块 + ffi.rs extern "C" 包装层 (DC2-h).
# DC3: runtime_shim.c -> bridge/shim.rs (embed/stage/dlopen/符号转发/孤儿清理/atexit).

echo "[3.5] Building Rust bridge (fastapi_mojo_rs staticlib) + shim static env..."
# DC3: 嵌入 static 文件的 objcopy 符号经 env 传给 build.rs -> shim_static_gen.rs.
SHIM_STATIC_ENVS=("SHIM_STATIC_N=$n_static")
for (( i=0; i<n_static; i++ )); do
    SHIM_STATIC_ENVS+=("SHIM_STATIC_${i}_NAME=${STATIC_NAMES[$i]}")
    SHIM_STATIC_ENVS+=("SHIM_STATIC_${i}_START=${STATIC_STARTS[$i]}")
    SHIM_STATIC_ENVS+=("SHIM_STATIC_${i}_END=${STATIC_ENDS[$i]}")
done
env "${SHIM_STATIC_ENVS[@]}" cargo build --release --manifest-path "$RS_DIR/Cargo.toml" --quiet

echo "[4/5] Linking single binary (PIE, shim constructor first)..."
# NOTE: objcopy binary objects carry no .note.GNU-stack; suppress the exec-stack warning.
# NOTE: Rust staticlib 引入 libgcc_s (compiler-rt), 必须 -static-libgcc 静态链接
# 否则 ldd 出现 libgcc_s.so.1 违反 North Star (CI libgcc_s 断言).
gcc -fPIE -pie -O2 -static-libgcc \
    "$BUILD/server.o" \
    -Wl,--whole-archive "$RS_LIB" -Wl,--no-whole-archive \
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
