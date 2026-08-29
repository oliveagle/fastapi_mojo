#!/usr/bin/env bash
# e2e_test.sh — end-to-end integration test for the fastapi_mojo single binary.
#
# Builds (if needed), starts the server, and asserts on real HTTP behavior:
#   - all 9 routes (200 + body content)
#   - error paths: 404 / 400 (malformed line, invalid UTF-8 path/body) /
#     413 / 431 / 408 (Slowloris guard)
#   - HEAD (headers only, no body) / OPTIONS 204
#   - static files: 200, 404, symlink-escape 403, ../-traversal 403
#   - a stalled client must not block the server (probe during hold)
#   - server still alive after all attacks
#
# Usage:
#   ./scripts/e2e_test.sh              # use existing build (build if missing)
#   ./scripts/e2e_test.sh --rebuild    # force ./build_single.sh first
#   ./scripts/e2e_test.sh --port 8123  # run on an alternate port
#
# Exit code: 0 = all checks passed, 1 = at least one failure.
# Designed to run in CI: no network needed beyond loopback.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/fastapi_mojo"
BIN="$ROOT/build/fastapi_mojo"
PORT=8000
REBUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild) REBUILD=1; shift ;;
        --port) PORT="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  FAIL: $1 — $2"; }

# --- helpers ---------------------------------------------------------------

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

# Send a raw (hex-encoded) request and print the response status line.
raw_status() { # hex
    python3 - "$1" "$PORT" <<'PY'
import socket, sys
data = bytes.fromhex(sys.argv[1])
port = int(sys.argv[2])
s = socket.create_connection(("127.0.0.1", port), timeout=8)
s.send(data)
try:
    resp = s.recv(65536)
    print(resp.split(b"\r\n")[0].decode(errors="replace"))
except socket.timeout:
    print("TIMEOUT")
s.close()
PY
}

expect_raw_status() { # name expected-substring hex
    local name=$1 expected=$2
    local got
    got=$(raw_status "$3")
    if [[ "$got" == *"$expected"* ]]; then pass "$name"
    else fail "$name" "expected status containing '$expected', got '$got'"; fi
}

# --- setup -----------------------------------------------------------------

command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }

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
# middleware (P4.3): timing hook adds duration_ms to JSON responses
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

# /echo (ADR-0004 验收路由): 回显全部参数, 注册=数据, 核心零改动
expect_code "GET /echo -> 200" 200 "$BASE/echo?a=1&b=two"
expect_body_contains "GET /echo echoes query" '"query_a": "1"' "$BASE/echo?a=1&b=two"
expect_body_contains "GET /echo echoes query2" '"query_b": "two"' "$BASE/echo?a=1&b=two"
expect_code "POST /echo -> 200" 200 "$BASE/echo" POST '{"x":"9","y":"z"}'
expect_body_contains "POST /echo echoes body" '"x": "9"' "$BASE/echo" POST '{"x":"9","y":"z"}'
ECHO_PATH_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/items/42")
expect_code "GET /items/42 path-echo (ECHO kind) -> 200" 200 "$BASE/items/42"
expect_body_contains "GET /items/42 echoes path param" '"item_id": "42"' "$BASE/items/42"

# --- error paths -------------------------------------------------------------

echo "== error paths =="
expect_code "GET /nope -> 404" 404 "$BASE/nope"

# 405: path exists, method not registered (with Allow header)
expect_code "POST /health -> 405" 405 "$BASE/health" POST
POST_HEALTH_HDRS=$(curl -s -D - -o /dev/null --max-time 10 -X POST "$BASE/health")
if [[ "$POST_HEALTH_HDRS" == *"Allow: GET"* ]]; then pass "405 carries Allow: GET"
else fail "405 carries Allow: GET" "headers: ${POST_HEALTH_HDRS:0:160}"; fi
expect_code "DELETE / -> 405" 405 "$BASE/" DELETE
ROOT_DEL_HDRS=$(curl -s -D - -o /dev/null --max-time 10 -X DELETE "$BASE/")
if [[ "$ROOT_DEL_HDRS" == *"Allow: GET"* ]]; then pass "405 (root) carries Allow: GET"
else fail "405 (root) carries Allow: GET" "headers: ${ROOT_DEL_HDRS:0:160}"; fi
# /items has GET+POST, so DELETE /items -> 405 with both in Allow
expect_code "DELETE /items -> 405" 405 "$BASE/items" DELETE
ITEMS_DEL_HDRS=$(curl -s -D - -o /dev/null --max-time 10 -X DELETE "$BASE/items")
if [[ "$ITEMS_DEL_HDRS" == *"Allow: "* && "$ITEMS_DEL_HDRS" == *"GET"* && "$ITEMS_DEL_HDRS" == *"POST"* ]]; then
    pass "DELETE /items Allow lists GET+POST"
else fail "DELETE /items Allow lists GET+POST" "headers: ${ITEMS_DEL_HDRS:0:160}"; fi

# 413: body over the 1MB limit (--data @file: a 1.1MB argv would hit ARG_MAX)
python3 -c "open('$TMP/big.json','wb').write(b'x' * 1100000)"
BIG_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST --data @"$TMP/big.json" "$BASE/items")
if [[ "$BIG_CODE" == "413" ]]; then pass "POST 1.1MB body -> 413"
else fail "POST 1.1MB body -> 413" "got $BIG_CODE"; fi

# P4.5: large body POST UNDER the limit (900KB) -> 200
python3 -c "open('$TMP/big900.bin','wb').write(b'x' * 900000)"
BIG900_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST --data @"$TMP/big900.bin" "$BASE/items")
if [[ "$BIG900_CODE" == "200" ]]; then pass "POST 900KB body -> 200 (under 1MB limit)"
else fail "POST 900KB body -> 200 (under 1MB limit)" "got $BIG900_CODE"; fi

# 400: malformed request line
expect_raw_status "raw 'BLAH' -> 400" "400 Bad Request" "424c41480d0a0d0a"
# 400: request line without protocol
expect_raw_status "raw no-protocol -> 400" "400 Bad Request" "474554202f0d0d0a504154483a20485454502f312e310d0a0d0a"
# 400: invalid UTF-8 in body
BADBODY_HEX=$(python3 -c "print((b'POST /items HTTP/1.1\r\nContent-Length: 3\r\n\r\n\xff\xfe\x80').hex())")
expect_raw_status "raw bad-utf8 body -> 400" "400 Bad Request" "$BADBODY_HEX"
# 400: invalid UTF-8 in path (generated properly)
BADPATH_HEX=$(python3 -c "print((b'GET /\xff HTTP/1.1\r\n\r\n').hex())")
expect_raw_status "raw bad-utf8 path -> 400" "400 Bad Request" "$BADPATH_HEX"

# 431: oversized headers (17KB)
BIGHDR_HEX=$(python3 -c "print((b'GET / HTTP/1.1\r\n' + b'X-Pad: ' + b'a'*17000 + b'\r\nHost: x\r\n\r\n').hex())")
expect_raw_status "17KB headers -> 431" "431 Request Header Fields Too Large" "$BIGHDR_HEX"

# 100-continue: server must send the interim 100 before the body, then the
# final 200 — total well under the ~1s client stall of the old behavior.
CC_RESULT=$(python3 - "$PORT" <<'PY'
import socket, time, sys
PORT = int(sys.argv[1])
t0 = time.time()
s = socket.create_connection(('127.0.0.1', PORT), timeout=8)
s.send(b'POST /items HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 9\r\n\r\n' + b'{"x":"1"}')
# interim response (exactly "HTTP/1.1 100 Continue\r\n\r\n")
interim = b''
while not interim.endswith(b'\r\n\r\n'):
    interim += s.recv(1)
# final response: headers + Content-Length bytes
data = b''
while b'\r\n\r\n' not in data:
    data += s.recv(65536)
hdr, _, rest = data.partition(b'\r\n\r\n')
cl = 0
for line in hdr.split(b'\r\n'):
    if line.lower().startswith(b'content-length:'):
        cl = int(line.split(b':')[1])
while len(rest) < cl:
    rest += s.recv(65536)
dt = time.time() - t0
s.close()
ok = ('100 Continue' in interim.decode()) and ('200 OK' in hdr.decode()) and dt < 0.9
print(('OK' if ok else 'FAIL') + ' dt=%.3fs' % dt)
PY
)
if [[ "$CC_RESULT" == OK* ]]; then pass "100-continue -> interim 100 then 200, no 1s stall ($CC_RESULT)"
else fail "100-continue -> interim 100 then 200, no 1s stall" "$CC_RESULT"; fi

# keep-alive: several requests on ONE TCP connection; HTTP/1.1 answers
# "Connection: keep-alive"; a client "Connection: close" is honored.
KA_RESULT=$(python3 - "$PORT" <<'PY'
import socket, sys
PORT = int(sys.argv[1])

def read_response(s):
    data = b''
    while b'\r\n\r\n' not in data:
        c = s.recv(65536)
        if not c:
            break
        data += c
    hdr, _, rest = data.partition(b'\r\n\r\n')
    cl = 0
    for line in hdr.split(b'\r\n'):
        if line.lower().startswith(b'content-length:'):
            cl = int(line.split(b':')[1])
    while len(rest) < cl:
        rest += s.recv(65536)
    return hdr.decode(errors='replace')

results = []
# 1) three sequential requests on one connection
s = socket.create_connection(('127.0.0.1', PORT), timeout=5)
try:
    h1 = read_response(s) if False else None
    s.sendall(b'GET /health HTTP/1.1\r\nHost: x\r\n\r\n')
    h1 = read_response(s)
    s.sendall(b'GET / HTTP/1.1\r\nHost: x\r\n\r\n')
    h2 = read_response(s)
    s.sendall(b'GET /items/42 HTTP/1.1\r\nHost: x\r\n\r\n')
    h3 = read_response(s)
    ok1 = '200 OK' in h1 and '200 OK' in h2 and '200 OK' in h3
    ok2 = 'keep-alive' in h1.lower()
    results.append(('3 requests on 1 connection', ok1))
    results.append(('response says Connection: keep-alive', ok2))
finally:
    s.close()
# 2) client Connection: close is honored (server closes after the response)
s = socket.create_connection(('127.0.0.1', PORT), timeout=5)
s.sendall(b'GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
h = read_response(s)
s.settimeout(2)
try:
    extra = s.recv(65536)
    ok3 = (extra == b'') and '200 OK' in h and 'close' in h.lower()
    results.append(('client Connection: close honored', ok3))
except socket.timeout:
    results.append(('client Connection: close honored', False))
s.close()
# 3) idle keep-alive connection: server closes silently on timeout
import time
s = socket.create_connection(('127.0.0.1', PORT), timeout=8)
s.sendall(b'GET /health HTTP/1.1\r\nHost: x\r\n\r\n')
read_response(s)
t0 = time.time()
try:
    s.settimeout(6)
    extra = s.recv(65536)
    idle_closed = (extra == b'')
    results.append(('idle keep-alive closed by server', idle_closed))
except socket.timeout:
    results.append(('idle keep-alive closed by server', False))
s.close()
ok = all(r[1] for r in results)
print(('OK' if ok else 'FAIL') + ' ' + '; '.join('%s=%s' % r for r in results))
PY
)
if [[ "$KA_RESULT" == OK* ]]; then pass "keep-alive: reuse + Connection: close + idle cleanup ($KA_RESULT)"
else fail "keep-alive: reuse + Connection: close + idle cleanup" "$KA_RESULT"; fi

# chunked Transfer-Encoding -> 411 (bodies are read strictly by Content-Length;
# the old behavior silently dropped the body and answered 200)
CHUNKED_HEX=$(python3 -c "print((b'POST /items HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n').hex())")
expect_raw_status "chunked -> 411 Length Required" "411 Length Required" "$CHUNKED_HEX"
CHUNKED_LC_HEX=$(python3 -c "print((b'POST /items HTTP/1.1\r\nHost: x\r\ntransfer-encoding: chunked\r\n\r\n').hex())")
expect_raw_status "chunked (lowercase header) -> 411" "411 Length Required" "$CHUNKED_LC_HEX"

# --- HEAD / OPTIONS ----------------------------------------------------------

echo "== HEAD / OPTIONS =="
# HEAD (P4.5): no body, and Content-Length must equal the GET body length
GET_LEN=$(curl -s --max-time 10 "$BASE/" | wc -c)
HEAD_CL=$(curl -s -I --max-time 10 "$BASE/" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')
HEAD_BODY_BYTES=$(python3 -c "
import socket
s = socket.create_connection(('127.0.0.1', $PORT), timeout=5)
s.send(b'HEAD / HTTP/1.1\r\nHost: x\r\n\r\n')
data = s.recv(65536)
hdr, _, body = data.partition(b'\r\n\r\n')
print(len(body))
s.close()
")
# CL is per-response correct; two separate requests differ by <=1 byte
# only when the request_id crosses a digit boundary (req-99 -> req-100).
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

# symlink escape: static/evil.html -> /etc/hostname must be 403
ln -s /etc/hostname "$SRC/static/evil_e2e.html"
expect_code "symlink escape -> 403" 403 "$BASE/evil_e2e.html"
unlink "$SRC/static/evil_e2e.html"

# ../-traversal to an existing file outside the static dir
printf 'SECRET\n' > "$SRC/secret_e2e.html"
TRAVERSAL_CODE=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/../secret_e2e.html")
if [[ "$TRAVERSAL_CODE" == "403" ]]; then pass "../ traversal -> 403"
else fail "../ traversal -> 403" "got $TRAVERSAL_CODE"; fi
unlink "$SRC/secret_e2e.html"

# --- WebSocket (RFC 6455, ADR-0006) -------------------------------------------

echo "== websocket (RFC 6455) =="
# One Python session (stdlib only) exercises: handshake (RFC 6455 vector),
# text echo, fragmented reassembly, large (64-bit length) binary echo,
# ping/pong, close. Markers M1..M6 print in order; a missing marker = that
# stage failed (the traceback is captured in the failure message).
WS_OUT="$(python3 - "$PORT" 2>&1 <<'PY'
import base64, hashlib, os, socket, struct, sys
port = int(sys.argv[1])
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
KEY = "dGhlIHNhbXBsZSBub25jZQ=="          # RFC 6455 1.3 example

def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c: raise ConnectionError("EOF")
        buf += c
    return buf

def send_frame(s, op, payload, fin=True):
    h = bytearray([(0x80 if fin else 0) | op])
    m = os.urandom(4)
    n = len(payload)
    if n < 126: h.append(0x80 | n)
    elif n <= 0xFFFF: h += bytes([0x80 | 126]) + struct.pack(">H", n)
    else: h += bytes([0x80 | 127]) + struct.pack(">Q", n)
    h += m
    s.sendall(bytes(h) + bytes(b ^ m[i % 4] for i, b in enumerate(payload)))

def recv_frame(s):
    h = recv_exact(s, 2)
    fin, op, n = (h[0] & 0x80) != 0, h[0] & 0x0F, h[1] & 0x7F
    if n == 126: n = struct.unpack(">H", recv_exact(s, 2))[0]
    elif n == 127: n = struct.unpack(">Q", recv_exact(s, 8))[0]
    m = recv_exact(s, 4) if h[1] & 0x80 else None
    p = recv_exact(s, n) if n else b""
    if m: p = bytes(b ^ m[i % 4] for i, b in enumerate(p))
    return fin, op, p

s = socket.create_connection(("127.0.0.1", port), timeout=8)
s.sendall((f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
           f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {KEY}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
resp = b""
while b"\r\n\r\n" not in resp:
    c = s.recv(4096)
    if not c: break
    resp += c
status = resp.split(b"\r\n")[0].decode()
assert status == "HTTP/1.1 101 Switching Protocols", status
hdrs = {}
for line in resp.decode(errors="replace").split("\r\n")[1:]:
    if ": " in line:
        k, v = line.split(": ", 1); hdrs[k.lower()] = v
accept = base64.b64encode(hashlib.sha1((KEY + GUID).encode()).digest()).decode()
assert hdrs.get("sec-websocket-accept") == accept, hdrs.get("sec-websocket-accept")
print("M1")

send_frame(s, 0x1, b"hello mojo")
f, o, p = recv_frame(s)
assert f and o == 0x1 and p == b"hello mojo", (o, p)
print("M2")

send_frame(s, 0x1, b"part1", fin=False)
send_frame(s, 0x0, b" part2", fin=True)
f, o, p = recv_frame(s)
assert f and o == 0x1 and p == b"part1 part2", (o, p)
print("M3")

big = bytes(range(256)) * 300            # 76800 B -> 64-bit length path
send_frame(s, 0x2, big)
f, o, p = recv_frame(s)
assert f and o == 0x2 and p == big, (o, len(p))
print("M4")

send_frame(s, 0x9, b"keepalive")
f, o, p = recv_frame(s)
assert o == 0xA and p == b"keepalive", (o, p)
print("M5")

send_frame(s, 0x8, struct.pack(">H", 1000))
try:
    f, o, p = recv_frame(s)
    assert o == 0x8, o
except ConnectionError:
    pass
print("M6")
s.close()
PY
)"

check_ws() { # marker name
    local m=$1 name=$2
    if echo "$WS_OUT" | grep -q "$m"; then pass "$name"
    else fail "$name" "$(echo "$WS_OUT" | tail -2 | tr '\n' ' ')"; fi
}
check_ws M1 "WS handshake: 101 + Sec-WebSocket-Accept (RFC 6455 vector)"
check_ws M2 "WS text frame echo"
check_ws M3 "WS fragmented message reassembly"
check_ws M4 "WS large binary echo (76800B, 64-bit length)"
check_ws M5 "WS ping -> pong"
check_ws M6 "WS close frame echo"

# ADR-0007 enhancements: multiple endpoints, subprotocol negotiation,
# server keepalive pings, close-code validation (1002/1007). One connection
# at a time (single-threaded dispatch, ADR-0006 known limitation).
WS2_OUT="$(python3 - "$PORT" 2>&1 <<'PY2'
import os, socket, struct, sys, time
port = int(sys.argv[1])
KEY = "dGhlIHNhbXBsZSBub25jZQ=="

def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c: raise ConnectionError("EOF")
        buf += c
    return buf

def send_frame(s, op, payload, fin=True):
    h = bytearray([(0x80 if fin else 0) | op])
    m = os.urandom(4)
    n = len(payload)
    if n < 126: h.append(0x80 | n)
    elif n <= 0xFFFF: h += bytes([0x80 | 126]) + struct.pack(">H", n)
    else: h += bytes([0x80 | 127]) + struct.pack(">Q", n)
    h += m
    s.sendall(bytes(h) + bytes(b ^ m[i % 4] for i, b in enumerate(payload)))

def recv_frame(s):
    h = recv_exact(s, 2)
    fin, op, n = (h[0] & 0x80) != 0, h[0] & 0x0F, h[1] & 0x7F
    if n == 126: n = struct.unpack(">H", recv_exact(s, 2))[0]
    elif n == 127: n = struct.unpack(">Q", recv_exact(s, 8))[0]
    m = recv_exact(s, 4) if h[1] & 0x80 else None
    p = recv_exact(s, n) if n else b""
    if m: p = bytes(b ^ m[i % 4] for i, b in enumerate(p))
    return fin, op, p

def connect(path, extra=""):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
               f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {KEY}\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n").encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        c = s.recv(4096)
        if not c: raise ConnectionError("EOF")
        resp += c
    status = resp.split(b"\r\n")[0].decode()
    hdrs = {}
    for line in resp.decode(errors="replace").split("\r\n")[1:]:
        if ": " in line:
            k, v = line.split(": ", 1); hdrs[k.lower()] = v
    return s, status, hdrs

def close_ws(s):
    try:
        send_frame(s, 0x8, struct.pack(">H", 1000))
        recv_frame(s)
    except Exception:
        pass
    s.close()

# M7: subprotocol negotiation — /ws/chat requires "chat"
s, status, hdrs = connect("/ws/chat", "Sec-WebSocket-Protocol: chat\r\n")
assert status == "HTTP/1.1 101 Switching Protocols", status
assert hdrs.get("sec-websocket-protocol") == "chat", hdrs
send_frame(s, 0x1, b"hi chat")
f, o, p = recv_frame(s)
assert f and o == 0x1 and p == b"hi chat", (o, p)
close_ws(s)
print("M7")

# M8: /ws/chat without the required subprotocol -> 400 (not 101)
s, status, _ = connect("/ws/chat")
assert status == "HTTP/1.1 400 Bad Request", status
s.close()
print("M8")

# M9: stateful endpoint /ws/counter (running sum per connection)
s, status, _ = connect("/ws/counter")
assert status == "HTTP/1.1 101 Switching Protocols", status
for num, expected in (("1", "sum=1"), ("2", "sum=3"), ("3", "sum=6")):
    send_frame(s, 0x1, num.encode())
    f, o, p = recv_frame(s)
    assert f and o == 0x1 and p == expected.encode(), (num, o, p)
close_ws(s)
print("M9")

# M10: server keepalive ping on idle (e2e server runs RECV_TIMEOUT=2s)
s, status, _ = connect("/ws")
assert status.startswith("HTTP/1.1 101"), status
t0 = time.time()
f, o, p = recv_frame(s)
assert o == 0x9 and p == b"", (o, p)          # server ping, empty payload
assert time.time() - t0 >= 1.5, "ping too early"
send_frame(s, 0xA, b"")                       # pong proves liveness, resets counter
t0 = time.time()
f, o, p = recv_frame(s)
assert o == 0x9, o                            # 2nd ping after another idle window
close_ws(s)
print("M10")

# M11: invalid close code (1005 is reserved, must not be in a payload) -> 1002
s, status, _ = connect("/ws")
send_frame(s, 0x8, struct.pack(">H", 1005))
f, o, p = recv_frame(s)
assert o == 0x8 and len(p) >= 2, (o, p)
assert struct.unpack(">H", p[:2])[0] == 1002, p[:2]
s.close()
print("M11")

# M12: invalid UTF-8 in a text frame -> close 1007 (RFC 6455 5.6)
s, status, _ = connect("/ws")
send_frame(s, 0x1, b"\xff\xfe")
f, o, p = recv_frame(s)
assert o == 0x8 and len(p) >= 2, (o, p)
assert struct.unpack(">H", p[:2])[0] == 1007, p[:2]
s.close()
print("M12")

# M13: valid close code + reason is echoed back (4000 "bye")
s, status, _ = connect("/ws")
send_frame(s, 0x8, struct.pack(">H", 4000) + b"bye")
f, o, p = recv_frame(s)
assert o == 0x8 and p[:5] == struct.pack(">H", 4000) + b"bye", p
s.close()
print("M13")
PY2
)"

check_ws2() { # marker name
    local m=$1 name=$2
    if echo "$WS2_OUT" | grep -q "$m"; then pass "$name"
    else fail "$name" "$(echo "$WS2_OUT" | tail -2 | tr '\n' ' ')"; fi
}
check_ws2 M7 "WS subprotocol negotiation (101 + Sec-WebSocket-Protocol: chat)"
check_ws2 M8 "WS missing required subprotocol -> 400"
check_ws2 M9 "WS stateful endpoint /ws/counter (running sum)"
check_ws2 M10 "WS server keepalive ping on idle (+ pong reset)"
check_ws2 M11 "WS invalid close code -> 1002"
check_ws2 M12 "WS invalid UTF-8 text -> close 1007"
check_ws2 M13 "WS close code + reason echo"

# ADR-0008: 高并发 WS — poll 循环驱动, 会话不再阻塞 dispatch。
WS3_OUT="$(python3 - "$PORT" 2>&1 <<'PY3'
import socket, struct, sys, threading, time
port = int(sys.argv[1])
KEY = "dGhlIHNhbXBsZSBub25jZQ=="

def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c: raise ConnectionError("EOF")
        buf += c
    return buf

def send_frame(s, op, payload, fin=True):
    h = bytearray([(0x80 if fin else 0) | op])
    m = __import__("os").urandom(4)
    n = len(payload)
    if n < 126: h.append(0x80 | n)
    elif n <= 0xFFFF: h += bytes([0x80 | 126]) + struct.pack(">H", n)
    else: h += bytes([0x80 | 127]) + struct.pack(">Q", n)
    h += m
    s.sendall(bytes(h) + bytes(b ^ m[i % 4] for i, b in enumerate(payload)))

def recv_frame(s):
    h = recv_exact(s, 2)
    fin, op, n = (h[0] & 0x80) != 0, h[0] & 0x0F, h[1] & 0x7F
    if n == 126: n = struct.unpack(">H", recv_exact(s, 2))[0]
    elif n == 127: n = struct.unpack(">Q", recv_exact(s, 8))[0]
    m = recv_exact(s, 4) if h[1] & 0x80 else None
    p = recv_exact(s, n) if n else b""
    if m: p = bytes(b ^ m[i % 4] for i, b in enumerate(p))
    return fin, op, p

def connect(path):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
               f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {KEY}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        c = s.recv(4096)
        if not c: raise ConnectionError("EOF")
        resp += c
    return s, resp.split(b"\r\n")[0].decode()

def close_ws(s):
    try:
        send_frame(s, 0x8, struct.pack(">H", 1000))
        recv_frame(s)
    except Exception:
        pass
    s.close()

# M14: 10 个并发 WS 会话 (线程), 各自完成 echo 往返
results = []
def worker(i):
    try:
        s, status = connect("/ws")
        assert status.startswith("HTTP/1.1 101"), status
        send_frame(s, 0x1, ("msg-%d" % i).encode())
        f, o, p = recv_frame(s)
        assert o == 0x1 and p == ("msg-%d" % i).encode(), (o, p)
        close_ws(s)
        results.append(1)
    except Exception:
        results.append(0)
threads = [threading.Thread(target=worker, args=(i,)) for i in range(10)]
t0 = time.time()
for t in threads: t.start()
for t in threads: t.join(timeout=30)
assert len([x for x in results if x == 1]) == 10, results
print("M14")

# M15: 3 个 WS 会话空闲时, HTTP 探针必须 <1s 完成 (ADR-0008 核心回归:
# 旧设计中 WS 会话阻塞 dispatch, 探针要等 2s 级空闲超时)
idle = []
for i in range(3):
    s, status = connect("/ws")
    assert status.startswith("HTTP/1.1 101"), status
    idle.append(s)
t0 = time.time()
probe = socket.create_connection(("127.0.0.1", port), timeout=8)
probe.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
resp = b""
while b"\r\n\r\n" not in resp:
    c = probe.recv(4096)
    if not c: break
    resp += c
dt = time.time() - t0
assert resp.startswith(b"HTTP/1.1 200"), resp[:40]
assert dt < 1.0, f"probe took {dt:.2f}s"
probe.close()
for s in idle: close_ws(s)
print("M15")

# M16: 每连接 state 隔离 — 两个 counter 会话交替消息, 累计互不干扰
sa, _ = connect("/ws/counter")
sb, _ = connect("/ws/counter")
send_frame(sa, 0x1, b"1"); f, o, p = recv_frame(sa); assert p == b"sum=1", p
send_frame(sb, 0x1, b"5"); f, o, p = recv_frame(sb); assert p == b"sum=5", p
send_frame(sa, 0x1, b"2"); f, o, p = recv_frame(sa); assert p == b"sum=3", p
send_frame(sb, 0x1, b"7"); f, o, p = recv_frame(sb); assert p == b"sum=12", p
close_ws(sa); close_ws(sb)
print("M16")
PY3
)"

check_ws3() { # marker name
    local m=$1 name=$2
    if echo "$WS3_OUT" | grep -q "$m"; then pass "$name"
    else fail "$name" "$(echo "$WS3_OUT" | tail -2 | tr '\n' ' ')"; fi
}
check_ws3 M14 "WS 10 并发会话 (各自 echo 往返成功)"
check_ws3 M15 "WS 空闲会话下 HTTP 探针 <1s (不阻塞 dispatch)"
check_ws3 M16 "WS 每连接 state 隔离 (两 counter 交替)"
expect_code "GET /ws without Upgrade header -> 404" 404 "$BASE/ws"
expect_code "WS upgrade to non-WS path -> 404" 404 "$BASE/nowhere"


# --- Slowloris guard -----------------------------------------------------------

echo "== slowloris guard =="
python3 - "$PORT" "$TMP" <<'PY' &
import socket, sys, time
port, tmp = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.send(b"GET /")  # half-sent request line, then stall
open(f"{tmp}/holding", "w").write("1")
time.sleep(2.5)
s.settimeout(6)
try:
    data = s.recv(65536)
    open(f"{tmp}/stalled_resp", "w").write(data.split(b"\r\n")[0].decode(errors="replace"))
except socket.timeout:
    open(f"{tmp}/stalled_resp", "w").write("TIMEOUT")
s.close()
PY
HOLDER=$!

# wait until the holder is actually stalling us
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
# P4.5: 50 parallel curls must all get 200 (event loop: no head-of-line
# blocking; a stalled or slow client cannot starve the others).
CONC_DIR="$TMP/conc"
mkdir -p "$CONC_DIR"
CONC_PIDS=()
for i in $(seq 1 50); do
    ( curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/health" > "$CONC_DIR/$i" ) &
    CONC_PIDS+=($!)
done
# wait only for the curl subshells (a bare `wait` would also wait for the
# server process, which runs forever)
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
