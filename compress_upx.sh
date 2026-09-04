#!/usr/bin/env bash
# compress_upx.sh — 可选部署压缩：用 UPX 把 build/fastapi_mojo 从 ~2.8M 压到 ~1.0M。
#
# ⚠️ 这不是默认构建路径！两个原因：
#   1) UPX 压缩后 `ldd` 输出 "not a dynamic executable"，会破坏 CI 的 North Star
#      ldd 门禁（CI 需要看到 libc.so 行）。
#   2) 启动时间 +10ms（13-16ms -> 22-29ms，UPX 解压一次性成本，服务器无感）。
#
# 用法：仅当手动部署到磁盘紧张的场景：
#   ./build_single.sh && ./compress_upx.sh
# 产物：build/fastapi_mojo（原文件备份到 build/fastapi_mojo.pre-upx）
#
# 依赖：upx（https://github.com/upx/upx/releases，放 PATH 或用 UPX_BIN 指定）

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/build/fastapi_mojo"
UPX_BIN="${UPX_BIN:-upx}"

[[ -f "$BIN" ]] || { echo "ERROR: $BIN 不存在，先跑 ./build_single.sh"; exit 1; }
command -v "$UPX_BIN" >/dev/null || { echo "ERROR: upx 未安装（UPX_BIN=... ./compress_upx.sh）"; exit 1; }

cp "$BIN" "$BIN.pre-upx"
"$UPX_BIN" -9 -k "$BIN" >/dev/null
BEFORE=$(stat -c%s "$BIN.pre-upx")
AFTER=$(stat -c%s "$BIN")
echo "UPX: $BEFORE -> $AFTER B (-$(( (BEFORE - AFTER) * 100 / BEFORE ))%)"
echo "产物: $BIN（原文件备份: $BIN.pre-upx）"
echo "注意: ldd 将显示 'not a dynamic executable'（CI 门禁不跑本脚本）"
