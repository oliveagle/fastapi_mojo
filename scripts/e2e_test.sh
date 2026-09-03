#!/usr/bin/env bash
# e2e_test.sh — end-to-end integration test for the fastapi_mojo single binary.
#
# 工具链 (Track B T2): 纯 shell + fmtool (Rust 小工具, 替代原 Python 客户端).
# python3 / .venv 不再需要 — 仓库 `*.py` 计数 = 0 (除文档/历史外).
#
# 构建 (如缺), 启动服务器, 断言真实 HTTP/WS 行为:
#   - 9 个路由 (200 + body 内容)
#   - 错误路径: 404 / 400 (畸形行/非法 UTF-8 path/body) / 413 / 431 / 408 (Slowloris)
#   - HEAD (仅头, 无 body) / OPTIONS 204
#   - 静态文件: 200, 404, symlink-escape 403, ../-traversal 403
#   - 停滞客户端不阻塞服务器 (探针 in <1s)
#   - WebSocket: M1..M21 全 21 项 (ADR-0006~0009 握手/帧/子协议/鉴权/并发/合并帧)
#   - 服务器攻击后仍存活
#
# 用法:
#   ./scripts/e2e_test.sh              # 用既有 build (缺则 build)
#   ./scripts/e2e_test.sh --rebuild    # 先 ./build_single.sh
#   ./scripts/e2e_test.sh --port 8123  # 备用端口
#   ./scripts/e2e_test.sh --fmtool F   # 自定义 fmtool 路径 (默认 ./src/fmtool/target/release/fmtool)
#   ./scripts/e2e_test.sh --rebuild-fmtool  # 强制重建 fmtool
#
# Exit code: 0 = all checks passed, 1 = at least one failure.
# Designed to run in CI: no network beyond loopback.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/fastapi_mojo"
BIN="$ROOT/build/fastapi_mojo"
FMTOOL="$ROOT/src/fmtool/target/release/fmtool"
PORT=8000
REBUILD=0
REBUILD_FMTOOL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild) REBUILD=1; shift ;;
        --rebuild-fmtool) REBUILD_FMTOOL=1; shift ;;
        --port) PORT="$2"; shift 2 ;;
        --fmtool) FMTOOL="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  FAIL: $1 — $2"; }

# --- fmtool 探测/构建 ---------------------------------------------------------

if [[ "$REBUILD_FMTOOL" == 1 || ! -x "$FMTOOL" ]]; then
    echo "[setup] building fmtool (Rust toolchain)..."
    (cd "$ROOT/src/fmtool" && cargo build --release) || { echo "ERROR: fmtool build failed"; exit 1; }
    FMTOOL="$ROOT/src/fmtool/target/release/fmtool"
fi
[[ -x "$FMTOOL" ]] || { echo "ERROR: fmtool not found at $FMTOOL (build with --rebuild-fmtool)"; exit 1; }

# --- helpers ------------------------------------------------------------------

http_code() { # url [method] [data]
    local url=$1 method=${2:-GET} data=${3:-}
    if [[ -n "$data" ]]; then
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" --data "$data" "$url"
    else
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" "$url"
    fi
}

http_body() { # url [method] [data]
    local url=$1 method=${2:-GET} data=${3:-}
    if [[ -n "$data" ]]; then
        curl -s --max-time 10 -X "$method" --data "$data" "$url"
    else
        curl -s --max-time 10 -X "$method" "$url"
    fi
}

expect_code() { # name expected url [method] [data]
    local name=$1 expected=$2
    local got
    got=$(http_code "${@:3}")
    if [[ "$got" == "$expected" ]]; then pass "$name"
    else fail "$name" "expected $expected, got $got"; fi
}

expect_body_contains() { # name pattern url [method] [data]
    local name=$1 pattern=$2
    local body
    body=$(http_body "${@:3}")
    if [[ "$body" == *"$pattern"* ]]; then pass "$name"
    else fail "$name" "body missing '$pattern' (got: ${body:0:120})"; fi
}

# fmtool raw: 发 hex 字节, 打印状态行 (或 TIMEOUT). 用于畸形请求行 / 大头 / 块编码等.
raw_status() { # hex
    "$FMTOOL" raw "$PORT" "$1"
}

expect_raw_status() { # name expected-substring hex
    local name=$1 expected=$2
    local got
    got=$(raw_status "$3")
    if [[ "$got" == *"$expected"* ]]; then pass "$name"
    else fail "$name" "expected status containing '$expected', got '$got'"; fi
}

# 把任意字节拼成 hex (shell-only, 不依赖 python).
# 用法: printf_to_hex '...' 或 printf_to_hex arg1 arg2 ...
# 例如: BADBODY_HEX=$(printf_to_hex $'POST /items HTTP/1.1\r\nContent-Length: 3\r\n\r\n\xff\xfe\x80')
printf_to_hex() {
    # printf 不接受 NUL 字节 (\x00) — 用 perl 一致替代 (perl 是 base 包, 几乎所有
    # Linux 都预装, 不算新增依赖). 若无 perl 则退化到 awk.
    if command -v perl >/dev/null 2>&1; then
        perl -e 'local $/; my $b = <STDIN>; $b =~ s/\\r/\r/g; $b =~ s/\\n/\n/g; $b =~ s/\\t/\t/g; $b =~ s/\\f/\f/g; $b =~ s/\\0/\x00/g; print unpack "H*", $b' <<<"$*"
    else
        # awk fallback: 限制 — 不支持 \xNN 转义; 这里仅用于 ASCII 文本 (CHUNKED_HEX 等)
        od -An -tx1 <<<"$*" | tr -d ' \n'
    fi
}

# --- setup --------------------------------------------------------------------

command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }

if [[ "$REBUILD" == 1 || ! -f "$BIN" ]]; then
    echo "[setup] building single binary..."
    "$ROOT/build_single.sh" || { echo "ERROR: build failed"; exit 1; }
fi

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
    echo "ERROR: port $PORT already in use (stop the other server or use --port)"
    exit 1
fi

TMP="$(mktemp -d /tmp/fm_e2e.XXXXXX)"
SERVER_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null
        for _ in 1 2 3 4 5; do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.3
        done
        kill -9 "$SERVER_PID" 2>/dev/null
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "[setup] starting server on port $PORT (recv timeout 2s, idle timeout 2s)..."
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    "$BIN" --port "$PORT" \
    > "$TMP/server.log" 2>&1 ) &
SERVER_PID=$!

READY=0
for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/health"; then
        READY=1; break
    fi
    sleep 0.3
done
if [[ "$READY" != 1 ]]; then
    echo "ERROR: server did not become ready; log:"
    cat "$TMP/server.log"
    exit 1
fi

BASE="http://127.0.0.1:$PORT"


# --- routes ----------------------------------------------------------------

echo "== routes =="
expect_code "GET / -> 200" 200 "$BASE/"
expect_body_contains "GET / body" "Welcome to Mojo HTTP Server" "$BASE/"
expect_body_contains "GET / has duration_ms (timing middleware)" '"duration_ms"' "$BASE/"
expect_code "GET /health -> 200" 200 "$BASE/health"
expect_body_contains "GET /health body" "healthy" "$BASE/health"
expect_code "GET /status -> 200" 200 "$BASE/status"
expect_body_contains "GET /status body" "running" "$BASE/status"
expect_code "GET /routes -> 200" 200 "$BASE/routes"
expect_body_contains "GET /routes body" "routes_count" "$BASE/routes"
expect_code "GET /hello?name=Mojo -> 200" 200 "$BASE/hello?name=Mojo"
expect_body_contains "GET /hello body" "Hello, Mojo!" "$BASE/hello?name=Mojo"
expect_code "GET /items -> 200" 200 "$BASE/items"
expect_body_contains "GET /items body" "items" "$BASE/items"
expect_code "POST /items -> 200" 200 "$BASE/items" POST '{"name":"e2e","n":42}'
expect_body_contains "POST /items body" "item_name" "$BASE/items" POST '{"name":"e2e","n":42}'
expect_body_contains "POST /items value" "e2e" "$BASE/items" POST '{"name":"e2e","n":42}'
expect_code "GET /items/42 -> 200" 200 "$BASE/items/42"
expect_body_contains "GET /items/42 body" '42' "$BASE/items/42"
expect_code "DELETE /items/42 -> 200" 200 "$BASE/items/42" DELETE

expect_code "GET /echo -> 200" 200 "$BASE/echo?a=1&b=two"
expect_body_contains "GET /echo echoes query" '"query_a": "1"' "$BASE/echo?a=1&b=two"
expect_body_contains "GET /echo echoes query2" '"query_b": "two"' "$BASE/echo?a=1&b=two"
expect_code "POST /echo -> 200" 200 "$BASE/echo" POST '{"x":"9","y":"z"}'
expect_body_contains "POST /echo echoes body" '"x": "9"' "$BASE/echo" POST '{"x":"9","y":"z"}'
expect_code "GET /items/42 path-echo (ECHO kind) -> 200" 200 "$BASE/items/42"
expect_body_contains "GET /items/42 echoes path param" '"item_id": "42"' "$BASE/items/42"

# --- error paths -------------------------------------------------------------

echo "== error paths =="
expect_code "GET /nope -> 404" 404 "$BASE/nope"

expect_code "POST /health -> 405" 405 "$BASE/health" POST
POST_HEALTH_HDRS=$(curl -s -D - -o /dev/null --max-time 10 -X POST "$BASE/health")
if [[ "$POST_HEALTH_HDRS" == *"Allow: GET"* ]]; then pass "405 carries Allow: GET"
else fail "405 carries Allow: GET" "headers: ${POST_HEALTH_HDRS:0:160}"; fi
expect_code "DELETE / -> 405" 405 "$BASE/" DELETE
ROOT_DEL_HDRS=$(curl -s -D - -o /dev/null --max-time 10 -X DELETE "$BASE/")
if [[ "$ROOT_DEL_HDRS" == *"Allow: GET"* ]]; then pass "405 (root) carries Allow: GET"
else fail "405 (root) carries Allow: GET" "headers: ${ROOT_DEL_HDRS:0:160}"; fi
expect_code "DELETE /items -> 405" 405 "$BASE/items" DELETE
ITEMS_DEL_HDRS=$(curl -s -D - -o /dev/null --max-time 10 -X DELETE "$BASE/items")
if [[ "$ITEMS_DEL_HDRS" == *"Allow: "* && "$ITEMS_DEL_HDRS" == *"GET"* && "$ITEMS_DEL_HDRS" == *"POST"* ]]; then
    pass "DELETE /items Allow lists GET+POST"
else fail "DELETE /items Allow lists GET+POST" "headers: ${ITEMS_DEL_HDRS:0:160}"; fi

# 413: body over 1MB limit. 用 shell 生成 1.1MB 'x' 文件 (避免 python).
head -c 1100000 /dev/zero | tr '\0' 'x' > "$TMP/big.json"
BIG_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST --data @"$TMP/big.json" "$BASE/items")
if [[ "$BIG_CODE" == "413" ]]; then pass "POST 1.1MB body -> 413"
else fail "POST 1.1MB body -> 413" "got $BIG_CODE"; fi

# P4.5: 900KB (under limit) -> 200
head -c 900000 /dev/zero | tr '\0' 'x' > "$TMP/big900.bin"
BIG900_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST --data @"$TMP/big900.bin" "$BASE/items")
if [[ "$BIG900_CODE" == "200" ]]; then pass "POST 900KB body -> 200 (under 1MB limit)"
else fail "POST 900KB body -> 200 (under 1MB limit)" "got $BIG900_CODE"; fi

# 400: 畸形请求行
expect_raw_status "raw 'BLAH' -> 400" "400 Bad Request" "424c41480d0a0d0a"
# 400: 请求行缺协议
expect_raw_status "raw no-protocol -> 400" "400 Bad Request" "474554202f0d0d0a504154483a20485454502f312e310d0a0d0a"

# 400: 非法 UTF-8 body. perl 处理 \xNN 转义 + NUL 安全 (printf 不支持 \x00).
BADBODY_HEX=$(printf_to_hex $'POST /items HTTP/1.1\r\nContent-Length: 3\r\n\r\n\xff\xfe\x80')
expect_raw_status "raw bad-utf8 body -> 400" "400 Bad Request" "$BADBODY_HEX"

# 400: 非法 UTF-8 path
BADPATH_HEX=$(printf_to_hex $'GET /\xff HTTP/1.1\r\n\r\n')
expect_raw_status "raw bad-utf8 path -> 400" "400 Bad Request" "$BADPATH_HEX"

# 431: oversized headers (17KB)
BIGHDR_HEX=$({ printf 'GET / HTTP/1.1\r\nX-Pad: '; head -c 17000 /dev/zero | tr '\0' 'a'; printf '\r\nHost: x\r\n\r\n'; } | od -An -tx1 -v | tr -d ' \n')
expect_raw_status "17KB headers -> 431" "431 Request Header Fields Too Large" "$BIGHDR_HEX"

# 100-continue: fmtool cont100
CC_RESULT=$("$FMTOOL" cont100 "$PORT")
if [[ "$CC_RESULT" == OK* ]]; then pass "100-continue -> interim 100 then 200, no 1s stall ($CC_RESULT)"
else fail "100-continue -> interim 100 then 200, no 1s stall" "$CC_RESULT"; fi

# keep-alive: fmtool keepalive
KA_RESULT=$("$FMTOOL" keepalive "$PORT")
if [[ "$KA_RESULT" == OK* ]]; then pass "keep-alive: reuse + Connection: close + idle cleanup ($KA_RESULT)"
else fail "keep-alive: reuse + Connection: close + idle cleanup" "$KA_RESULT"; fi

# chunked Transfer-Encoding -> 411
CHUNKED_HEX=$(printf_to_hex $'POST /items HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n')
expect_raw_status "chunked -> 411 Length Required" "411 Length Required" "$CHUNKED_HEX"
CHUNKED_LC_HEX=$(printf_to_hex $'POST /items HTTP/1.1\r\nHost: x\r\ntransfer-encoding: chunked\r\n\r\n')
expect_raw_status "chunked (lowercase header) -> 411" "411 Length Required" "$CHUNKED_LC_HEX"

# --- HEAD / OPTIONS ----------------------------------------------------------

echo "== HEAD / OPTIONS =="
GET_LEN=$(curl -s --max-time 10 "$BASE/" | wc -c)
HEAD_CL=$(curl -s -I --max-time 10 "$BASE/" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')
HEAD_BODY_BYTES=$("$FMTOOL" headbody "$PORT")
DIFF=$((HEAD_CL - GET_LEN)); [[ $DIFF -lt 0 ]] && DIFF=$((DIFF * -1))
if [[ "$HEAD_BODY_BYTES" == "0" && -n "$HEAD_CL" && "$DIFF" -le 1 ]]; then
    pass "HEAD / -> empty body, Content-Length ($HEAD_CL) ~= GET body length ($GET_LEN)"
else
    fail "HEAD / -> empty body, Content-Length ~= GET body length" \
        "body_bytes=$HEAD_BODY_BYTES cl=$HEAD_CL get_len=$GET_LEN"
fi
expect_code "OPTIONS / -> 204" 204 "$BASE/" OPTIONS

# --- static files -------------------------------------------------------------

echo "== static files =="
expect_code "GET /index.html -> 200" 200 "$BASE/index.html"
expect_body_contains "GET /index.html body" "<html" "$BASE/index.html"
expect_code "GET /test.json -> 200" 200 "$BASE/test.json"
expect_code "static missing file -> 404" 404 "$BASE/missing_e2e.html"

ln -s /etc/hostname "$SRC/static/evil_e2e.html"
expect_code "symlink escape -> 403" 403 "$BASE/evil_e2e.html"
unlink "$SRC/static/evil_e2e.html"

printf 'SECRET\n' > "$SRC/secret_e2e.html"
TRAVERSAL_CODE=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/../secret_e2e.html")
if [[ "$TRAVERSAL_CODE" == "403" ]]; then pass "../ traversal -> 403"
else fail "../ traversal -> 403" "got $TRAVERSAL_CODE"; fi
unlink "$SRC/secret_e2e.html"

# --- WebSocket (RFC 6455, ADR-0006) -------------------------------------------

echo "== websocket (RFC 6455) =="
WS1_OUT=$("$FMTOOL" ws1 "$PORT" 2>&1)
WS1_FAIL=$(echo "$WS1_OUT" | tail -1)
for m in M1 M2 M3 M4 M5 M6; do
    if echo "$WS1_OUT" | grep -q "$m"; then pass "WS $m"
    else fail "WS $m" "$WS1_FAIL"; fi
done

echo "== websocket enhancements (ADR-0007) =="
WS2_OUT=$("$FMTOOL" ws2 "$PORT" 2>&1)
WS2_FAIL=$(echo "$WS2_OUT" | tail -1)
for m in M7 M8 M9 M10 M11 M12 M13; do
    if echo "$WS2_OUT" | grep -q "$m"; then pass "WS $m"
    else fail "WS $m" "$WS2_FAIL"; fi
done

echo "== websocket concurrency (ADR-0008) =="
WS3_OUT=$("$FMTOOL" ws3 "$PORT" 2>&1)
WS3_FAIL=$(echo "$WS3_OUT" | tail -1)
for m in M14 M15 M16; do
    if echo "$WS3_OUT" | grep -q "$m"; then pass "WS $m"
    else fail "WS $m" "$WS3_FAIL"; fi
done

echo "== websocket refinements (ADR-0009) =="
WS4_OUT=$("$FMTOOL" ws4 "$PORT" 2>&1)
WS4_FAIL=$(echo "$WS4_OUT" | tail -1)
for m in M17 M18 M19 M20 M21; do
    if echo "$WS4_OUT" | grep -q "$m"; then pass "WS $m"
    else fail "WS $m" "$WS4_FAIL"; fi
done

expect_code "GET /ws without Upgrade header -> 404" 404 "$BASE/ws"
expect_code "WS upgrade to non-WS path -> 404" 404 "$BASE/nowhere"


# --- Slowloris guard -----------------------------------------------------------

echo "== slowloris guard =="
"$FMTOOL" slowloris "$PORT" "$TMP" &
HOLDER=$!

for _ in $(seq 1 20); do [[ -f "$TMP/holding" ]] && break; sleep 0.1; done

PROBE_START=$(date +%s%N)
PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$BASE/health")
PROBE_MS=$(( ( $(date +%s%N) - PROBE_START ) / 1000000 ))
wait "$HOLDER" 2>/dev/null
STALLED_RESP=$(cat "$TMP/stalled_resp" 2>/dev/null || echo NONE)

if [[ "$PROBE_CODE" == "200" && "$PROBE_MS" -lt 1000 ]]; then
    pass "probe /health during stalled client -> 200 in ${PROBE_MS}ms (<1s)"
else
    fail "probe /health during stalled client -> 200 in ${PROBE_MS}ms (<1s)" "code=$PROBE_CODE ms=$PROBE_MS"
fi
if [[ "$STALLED_RESP" == *"408"* ]]; then
    pass "stalled client got 408"
else
    fail "stalled client got 408" "got: $STALLED_RESP"
fi

# --- concurrency ---------------------------------------------------------------

echo "== concurrency =="
CONC_DIR="$TMP/conc"
mkdir -p "$CONC_DIR"
CONC_PIDS=()
for i in $(seq 1 50); do
    ( curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/health" > "$CONC_DIR/$i" ) &
    CONC_PIDS+=($!)
done
for p in "${CONC_PIDS[@]}"; do wait "$p"; done
CONC_FAILS=0
for i in $(seq 1 50); do
    code=$(cat "$CONC_DIR/$i" 2>/dev/null)
    if [[ "$code" != "200" ]]; then CONC_FAILS=$((CONC_FAILS + 1)); fi
done
if [[ "$CONC_FAILS" == "0" ]]; then pass "50 concurrent curls: all 200"
else fail "50 concurrent curls: all 200" "$CONC_FAILS non-200 responses"; fi

# --- liveness ------------------------------------------------------------------

echo "== liveness =="
expect_code "server alive after attacks -> 200" 200 "$BASE/health"

# --- summary ---------------------------------------------------------------------

echo
echo "=================================================="
echo " e2e result: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo " failed checks:"
    for n in "${FAILED_NAMES[@]}"; do echo "   - $n"; done
    echo " server log: $TMP/server.log"
    exit 1
fi
echo " all checks passed"
