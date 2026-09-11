#!/usr/bin/env bash
# compress_upx.sh — 可选部署压缩（UPX -9，不进入默认构建 / CI 交付面）。
#
# 决策-65（ADR-0040）：UPX 仍是 opt-in 手动部署路径。当前实测：
#   4,954,416 B -> 1,718,420 B（-65.32%），冷启动均值 12.1ms -> 31.6ms。
#
# 为什么不是默认产物：
#   1) UPX 会把原 ELF 打包进自解压 stub，`ldd` 输出 "not a dynamic executable"，
#      `readelf` 也不再能看到 INTERP / NEEDED；因此压缩副本不能替代未压缩
#      binary 的 North Star ldd 门禁。
#   2) `--brute` 只比 -9 再省约 191KB，但冷启动均值升到约 95ms；本脚本固定 -9。
#
# 用法（仅当手动部署到磁盘紧张场景）：
#   ./build_single.sh
#   ./compress_upx.sh [--port N] [--no-smoke]
#   ./compress_upx.sh --restore [--no-smoke]
#
# 产物：
#   build/fastapi_mojo          UPX 压缩副本
#   build/fastapi_mojo.pre-upx  未压缩原文件（依赖证明与回滚基准）
#
# 依赖：upx（UPX_BIN=... 可覆盖）、file、ldd；默认 smoke 另需 curl。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/build/fastapi_mojo"
BACKUP="$BIN.pre-upx"
UPX_BIN="${UPX_BIN:-upx}"
SMOKE_PORT="${UPX_SMOKE_PORT:-18971}"
MODE="compress"
SMOKE=1
TMP=""
SERVER_PID=""

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore)
      MODE="restore"
      shift
      ;;
    --no-smoke)
      SMOKE=0
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "ERROR: --port 需要端口号" >&2; exit 2; }
      SMOKE_PORT="$2"
      shift 2
      ;;
    --port=*)
      SMOKE_PORT="${1#--port=}"
      [[ "$SMOKE_PORT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: 非法端口: $SMOKE_PORT" >&2; exit 2; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: 未知参数: $1（支持 --restore / --no-smoke / --port N）" >&2
      exit 2
      ;;
  esac
done

[[ "$SMOKE_PORT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: 非法端口: $SMOKE_PORT" >&2; exit 2; }

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # 不用 rm：异常候选文件保留为 .failed.*，避免掩盖可诊断的打包残片。
  if [[ -n "$TMP" && -e "$TMP" ]]; then
    local failed="$TMP.failed.$$"
    mv "$TMP" "$failed"
    echo "ERROR: UPX 候选文件失败，已保留: $failed" >&2
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: 缺少命令: $1" >&2
    exit 1
  }
}

verify_uncompressed() {
  local out
  [[ -x "$BIN" ]] || { echo "ERROR: $BIN 不存在或不可执行，先跑 ./build_single.sh" >&2; exit 1; }
  require_command file
  require_command ldd
  out="$(file -b "$BIN")"
  [[ "$out" == *"dynamically linked"* && "$out" == *"interpreter"* ]] || {
    echo "ERROR: $BIN 不是未压缩动态链接 PIE；如需回滚请先执行 ./compress_upx.sh --restore" >&2
    exit 1
  }
  out="$(ldd "$BIN")"
  echo "$out"
  echo "$out" | grep -q 'libc\.so' || { echo "ERROR: 未压缩 binary 缺少 libc 依赖证明" >&2; exit 1; }
  if echo "$out" | grep -Eiq 'libstdc\+\+|libgcc_s|libm\.so|python|KGEN|MSupport|AsyncRT|modular'; then
    echo "ERROR: 未压缩 binary 存在禁止依赖；UPX 不能掩盖 North Star 失败" >&2
    exit 1
  fi
}

health_smoke() {
  local exe="$1" log body ok i
  [[ "$SMOKE" == "1" ]] || return 0
  require_command curl
  if curl -fsS --max-time 1 "http://127.0.0.1:$SMOKE_PORT/health" >/dev/null 2>&1; then
    echo "ERROR: 端口 $SMOKE_PORT 已被占用，换用 --port N" >&2
    exit 1
  fi

  log="$(mktemp /tmp/fastapi-mojo-upx-smoke.XXXXXX.log)"
  echo "Smoke: env -i 启动 $exe（port=$SMOKE_PORT）..."
  env -i PATH=/usr/bin:/bin "$exe" --port "$SMOKE_PORT" >"$log" 2>&1 &
  SERVER_PID=$!
  ok=0
  for i in $(seq 1 40); do
    body="$(curl -fsS --max-time 2 "http://127.0.0.1:$SMOKE_PORT/health" 2>/dev/null || true)"
    if [[ "$body" == *'"status": "healthy"'* ]]; then
      ok=1
      break
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.25
  done

  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  if [[ "$ok" != "1" ]]; then
    echo "ERROR: smoke 启动 /health 失败" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "PASS: env -i /health 200"
}

if [[ "$MODE" == "restore" ]]; then
  [[ -f "$BACKUP" ]] || { echo "ERROR: 不存在备份 $BACKUP；当前无需 restore" >&2; exit 1; }
  echo "Restoring $BACKUP -> $BIN"
  mv "$BACKUP" "$BIN"
  verify_uncompressed
  health_smoke "$BIN"
  echo "PASS: 已恢复未压缩 binary，并保留 ldd 依赖证明"
  trap - EXIT
  exit 0
fi

[[ -e "$BACKUP" ]] && {
  echo "ERROR: $BACKUP 已存在；先执行 ./compress_upx.sh --restore，避免丢失原文件" >&2
  exit 1
}
require_command "$UPX_BIN"
verify_uncompressed
TMP="$BIN.upx.$$"
[[ -e "$TMP" ]] && { echo "ERROR: 临时文件已存在: $TMP" >&2; exit 1; }

"$UPX_BIN" -9 -o "$TMP" "$BIN" >/dev/null
[[ -x "$TMP" ]] || { echo "ERROR: UPX 未产出可执行文件" >&2; exit 1; }
"$UPX_BIN" -t "$TMP" >/dev/null
health_smoke "$TMP"

BEFORE=$(stat -c%s "$BIN")
AFTER=$(stat -c%s "$TMP")
[[ "$AFTER" -lt "$BEFORE" ]] || { echo "ERROR: UPX 后体积未变小" >&2; exit 1; }

cp -p "$BIN" "$BACKUP"
mv "$TMP" "$BIN"
TMP=""
trap - EXIT

echo "UPX -9: $BEFORE -> $AFTER B (-$(( (BEFORE - AFTER) * 100 / BEFORE ))%)"
echo "产物: $BIN（未压缩备份: $BACKUP）"
echo "注意: 压缩副本 ldd/readelf 不能证明依赖闭包；North Star 证明只属于未压缩 backup。"
