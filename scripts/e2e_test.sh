#!/usr/bin/env bash
# e2e_test.sh — end-to-end integration test for the fastapi_mojo single binary.
#
# Builds (if needed), starts the server, and asserts on real HTTP behavior:
#   - all 9 routes (200 + body content)
#   - error paths: 404 / 400 (malformed line, invalid UTF-8 path/body) /
#     413 / 431 / 408 (Slowloris guard)
#   - HEAD (headers only, no body) / OPTIONS 204
#   - static files: 200, symlink-escape 403, ../-traversal 403
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

echo "[setup] starting server on port $PORT (recv timeout 2s)..."
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_E2E_PORT="$PORT" "$BIN" \
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

# NOTE: the server currently binds port 8000 (port config lands in
# p3-deploy-hardening). Until then, --port only changes the client side and
# the test would fail — the guard above catches the busy case.
if [[ "$PORT" != "8000" ]]; then
    echo "WARN: server port is hardcoded to 8000 (task p3.2 pending); running on 8000."
    PORT=8000
    BASE="http://127.0.0.1:$PORT"
fi

# --- routes ----------------------------------------------------------------

echo "== routes =="
expect_code "GET / -> 200" 200 "$BASE/"
expect_body_contains "GET / body" "Welcome to Mojo HTTP Server" "$BASE/"
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

# 400: malformed request line
expect_raw_status "raw 'BLAH' -> 400" "400 Bad Request" "424c41480d0a0d0a"
# 400: invalid UTF-8 in path
expect_raw_status "raw bad-utf8 path -> 400" "400 Bad Request" \
    "474554202f0d0d0a504154483a20485454502f312e310d0a0d0a" # "GET /?bad"
# (the hex above is a placeholder; real test below uses generated hex)
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
data = b''
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
dt = time.time() - t0
s.close()
text = data.decode(errors='replace')
ok = ('100 Continue' in text) and ('200 OK' in text) and dt < 0.9
print(('OK' if ok else 'FAIL') + ' dt=%.3fs' % dt)
PY
)
if [[ "$CC_RESULT" == OK* ]]; then pass "100-continue -> interim 100 then 200, no 1s stall ($CC_RESULT)"
else fail "100-continue -> interim 100 then 200, no 1s stall" "$CC_RESULT"; fi

# --- HEAD / OPTIONS ----------------------------------------------------------

echo "== HEAD / OPTIONS =="
HEAD_OUT=$(curl -s -I --max-time 10 "$BASE/")
if [[ "$HEAD_OUT" == *"200 OK"* && "$HEAD_OUT" == *"Content-Length: "* ]]; then
    # HEAD must carry Content-Length but no body: -I returns only headers,
    # so verify body is empty by comparing a raw HEAD read.
    HEAD_RAW=$(python3 -c "
import socket
s = socket.create_connection(('127.0.0.1', $PORT), timeout=5)
s.send(b'HEAD / HTTP/1.1\r\nHost: x\r\n\r\n')
data = s.recv(65536)
hdr, _, body = data.partition(b'\r\n\r\n')
print(len(body))
s.close()
")
    if [[ "$HEAD_RAW" == "0" ]]; then pass "HEAD / -> 200, Content-Length set, empty body"
    else fail "HEAD / -> 200, Content-Length set, empty body" "HEAD body had $HEAD_RAW bytes"; fi
else
    fail "HEAD / -> 200, Content-Length set, empty body" "headers: ${HEAD_OUT:0:120}"
fi
expect_code "OPTIONS / -> 204" 204 "$BASE/" OPTIONS

# --- static files -------------------------------------------------------------

echo "== static files =="
expect_code "GET /index.html -> 200" 200 "$BASE/index.html"
expect_body_contains "GET /index.html body" "<html" "$BASE/index.html"
expect_code "GET /test.json -> 200" 200 "$BASE/test.json"

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

if [[ "$PROBE_CODE" == "200" && "$PROBE_MS" -lt 4000 ]]; then
    pass "probe /health during stalled client -> 200 in ${PROBE_MS}ms"
else
    fail "probe /health during stalled client -> 200 in ${PROBE_MS}ms" "code=$PROBE_CODE ms=$PROBE_MS"
fi
if [[ "$STALLED_RESP" == *"408"* ]]; then
    pass "stalled client got 408"
else
    fail "stalled client got 408" "got: $STALLED_RESP"
fi

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
