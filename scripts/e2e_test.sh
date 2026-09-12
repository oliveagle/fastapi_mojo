#!/usr/bin/env bash
# e2e_test.sh — end-to-end integration test for the fastapi_mojo single binary.
#
# 工具链 (Track B T2): 纯 shell + fmtool (Rust 小工具, 替代原 Python 客户端).
# python3 / .venv 不再需要 — 仓库 `*.py` 计数 = 0 (除文档/历史外).
#
# 构建 (如缺), 启动服务器, 断言真实 HTTP/WS 行为:
#   - 9 个路由 (200 + body 内容)
#   - F1 类型化参数: int/bool/422 + detail 字段 (Goal-0002)
#   - F2 声明式异常映射: _error_map + 统一 detail 错误体 (Goal-0002)
#   - F3 Request/Response + 嵌套 JSON (__nested__: 前缀直通, 修复 405 body hang)
#   - F4 OpenAPI 3.0 (/openapi.json + /docs Swagger UI)
#   - F5 Streaming/SSE (KIND_SSE 一次性推送 + format_sse_event 行切分合规)
#   - SSE ServerSentEvent 字段 event/id/retry/comment (决策-72, SF-1..SF-5)
#   - F6 /metrics 端点 (Prometheus 文本, requests_total/active_conns/uptime)
#   - 错误路径: 404 / 400 (畸形行/非法 UTF-8 path/body) / 413 / 431 / 408 (Slowloris)
#   - HTTP/2: prior-knowledge h2c H2-1..H2-7（HPACK/CONTINUATION/DATA/PING/HEAD/
#     buffered multiplex, ADR-0038）
#   - TLS/HTTPS: opt-in rustls transport TLS-0..TLS-9（TLS1.3/ALPN/keep-alive/
#     plaintext rejection/fail-closed config, ADR-0039）
#   - HEAD (仅头, 无 body) / OPTIONS 204
#   - 静态文件: 200, 404, symlink-escape 403, ../-traversal 403
#   - 停滞客户端不阻塞服务器 (探针 in <1s)
#   - WebSocket: M1..M21 全 21 项 (ADR-0006~0009 握手/帧/子协议/鉴权/并发/合并帧)
#   - WebSocket 精化: W1..W8 + 2 log 检查 (ADR-0026 决策-51 close/exception/binary/json + close-wait)
#   - 服务器攻击后仍存活
#   - Lifespan: 声明式 startup/shutdown 命令 (决策-36, LS-1..LS-4)
#   - APIRouter: prefix/tags/base_deps + include_router (决策-37, AR-1..AR-8)
#   - Body validation: _body_schema + Field 约束 + Enum + FastAPI 422 detail (决策-38, BS-1..BS-12)
#   - GZip 中间件: FASTAPI_MOJO_GZIP env 声明式 (决策-40, GZ-1..GZ-5)
#   - Rust JSON serializer opt-in: FASTAPI_MOJO_JSON_SERIALIZER=rust (决策-66, JR-1..JR-6)
#   - OAuth2 scopes: _auth_scopes gate + oauth2 flows OpenAPI (决策-67, OT-24..OT-33)
#   - HTTPDigest runtime + OpenAPI securitySchemes (basic/bearer/digest/apiKey) (决策-69, DG-1..6 / SO-1..5)
#   - OpenIdConnect + OAuth2AuthorizationCodeBearer (runtime + OpenAPI) (决策-70, OI-1..4 / AC-1..7)
#   - RedirectResponse: _redirect_url + _redirect_status 307/303/301/308 + URL quote (决策-68, RD-1..RD-10)
#   - redirect_slashes (Starlette 默认尾斜杠 307) (决策-71, SL-1..SL-10)
#   - CORS 完整配置: FASTAPI_MOJO_CORS_* env 声明式 (决策-42, CRS-1..CRS-8)
#   - response_model exclude/exclude_none (决策-41, RM-5..RM-7)
#   - Form 多值/alias/desc + 422 parity: input/"Field required"/collect-all
#     (决策-45, FM-1..FM-20; OpenAPI JSON 合法性 jsoncheck 门禁)
#   - UploadFile 对象 API: _file_types file/bytes + 422 (U2 value_error / U3 string_type /
#     U4 last-wins / U5 全缺失) + _file_ops (head/range/sha256/save) + multipart OpenAPI
#     (决策-46, MP8..MP23b; size = 实际字节 U1; MP1..MP7 决策-32 存量)
#   - Depends use_cache: 每请求 memo 表 (默认 cached 菱形 1 次 / _depends_nocache =
#     use_cache=False 重派发 / 嵌套 nocache 结果入库供 cached 引用复用, 上游 P9-1/2/3)
#     (决策-47, DC-1..DC-7; _dep_calls 观测超集)
#   - FileResponse/StreamingResponse: 200/206 (单段/multipart/merge/suffix/open/clamp) /
#     400×4 精确消息 / 416 / 500 / If-Range / INM·IMS 忽略 / HEAD 仅头 / CD (attachment·inline
#     RFC5987) / etag = md5(f64(mtime)-size) (fmtool f64repr × md5sum 交叉验证) / chunked
#     streaming (no-CT quirk / 自定义 status / extra 头 / raw-socket 帧级证明)
#     (决策-48, FR-1..FR-32; ADR-0023)
#   - TestClient 声明式等价: fmtool testclient http/ws/run (决策-56, TC-1..TC-9; ADR-0031)
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
command -v openssl >/dev/null || { echo "ERROR: openssl not found (TLS e2e fixture)"; exit 1; }

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
TLS_PID=""
TLS_INVALID_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null
        for _ in 1 2 3 4 5; do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.3
        done
        kill -9 "$SERVER_PID" 2>/dev/null
    fi
    for pid in "$TLS_INVALID_PID" "$TLS_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 0.2
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "[setup] starting server on port $PORT (recv timeout 2s, idle timeout 2s)..."
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_WS_CLOSE_WAIT=2000 \
    FASTAPI_MOJO_JSON_SERIALIZER=rust FASTAPI_MOJO_JSON_RUST_MIN_BYTES=1 \
    FASTAPI_MOJO_OPENAPI_DESCRIPTION="e2e description" \
    FASTAPI_MOJO_OPENAPI_TERMS="https://tos.example" \
    FASTAPI_MOJO_OPENAPI_CONTACT="E2E Support|https://support.example|s@example.com" \
    FASTAPI_MOJO_OPENAPI_LICENSE="MIT|https://opensource.org/licenses/MIT" \
    FASTAPI_MOJO_OPENAPI_SERVERS="https://api.example/v1:Prod" \
    FASTAPI_MOJO_OPENAPI_TAGS="items:Item ops;users:User mgmt" \
    FASTAPI_MOJO_OPENAPI_EXTERNAL_DOCS="https://docs.example/guide|Ext docs" \
    "$BIN" --port "$PORT" \
    > "$TMP/server.log" 2>&1 ) &
SERVER_PID=$!

# 决策-50 (ADR-0025 §3.5-7): 新 bind 后 ~2s 内的首连接可能被本机透明代理
# 劫持 (Caddy :80 假空 200, 真 server 收不到) — 就绪探针前先等端口稳定,
# 且用 body 校验 (含 'healthy'; Caddy 假响应 body 为空) 防假 ready.
# 干净环境 (CI) 无害: 仅多等 5s.
sleep 5
READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null)" == *healthy* ]]; then
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

# --- Rust JSON serializer (decision-66) -----------------------------------------

echo "== Rust JSON serializer (decision-66; main e2e server opt-in, threshold=1) =="
JR_HEALTH="$TMP/json_rust_health.body"
if curl -sS --max-time 5 "$BASE/health" -o "$JR_HEALTH" && "$FMTOOL" jsoncheck "$JR_HEALTH" >/dev/null; then
    pass "JR-1 opt-in Rust JSON /health valid"
else fail "JR-1 opt-in Rust JSON /health valid" "$(head -c 160 "$JR_HEALTH" 2>/dev/null)"; fi

JR_ESCAPE_BODY="$TMP/json_rust_escape.body"
if curl -sS --max-time 5 -H "Content-Type: application/json" \
    --data-binary '{"s":"a\"b\\c\\nd\\te","nested":{"x":1}}' \
    "$BASE/echo" -o "$JR_ESCAPE_BODY" && \
   grep -Fq -- '{"s": "a\"b\\c\\nd\\te", "nested": "{\"x\":1}"' "$JR_ESCAPE_BODY"; then
    pass "JR-2 escaping and nested string parity"
else fail "JR-2 escaping and nested string parity" "$(head -c 220 "$JR_ESCAPE_BODY" 2>/dev/null)"; fi

{ printf '{"payload":"'; head -c 1000000 /dev/zero | tr '\0' 'x'; printf '"}'; } > "$TMP/json_rust_request.json"
{ printf '{"payload": "'; head -c 1000000 /dev/zero | tr '\0' 'x'; printf '"}'; } > "$TMP/json_rust_expected.json"
JR_CODE=$(curl -sS --max-time 15 -D "$TMP/json_rust_headers" -o "$TMP/json_rust_response.json" \
    -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data-binary @"$TMP/json_rust_request.json" "$BASE/echo")
if [[ "$JR_CODE" == "200" ]]; then pass "JR-3 1MB object POST -> 200"
else fail "JR-3 1MB object POST -> 200" "got $JR_CODE"; fi
JR_CL=$(tr -d '\r' < "$TMP/json_rust_headers" | grep -i '^Content-Length:' | tail -1 | awk '{print $2}')
JR_SIZE=$(stat -c '%s' "$TMP/json_rust_response.json")
if [[ "$JR_CL" == "$JR_SIZE" ]]; then pass "JR-4 1MB response Content-Length exact"
else fail "JR-4 1MB response Content-Length exact" "header=$JR_CL body=$JR_SIZE"; fi
JR_PAYLOAD_SIZE=$(($(stat -c '%s' "$TMP/json_rust_expected.json") - 1))
head -c "$JR_PAYLOAD_SIZE" "$TMP/json_rust_response.json" > "$TMP/json_rust_response.prefix"
head -c "$JR_PAYLOAD_SIZE" "$TMP/json_rust_expected.json" > "$TMP/json_rust_expected.prefix"
if cmp -s "$TMP/json_rust_response.prefix" "$TMP/json_rust_expected.prefix"; then
    pass "JR-5 1MB response payload bytes exact"
else fail "JR-5 1MB response payload bytes exact" "expected payload $(stat -c %s "$TMP/json_rust_expected.prefix") B, got $JR_SIZE B response"; fi
if "$FMTOOL" jsoncheck "$TMP/json_rust_response.json" >/dev/null; then
    pass "JR-6 1MB response valid JSON"
else fail "JR-6 1MB response valid JSON" "$(head -c 160 "$TMP/json_rust_response.json")"; fi

# --- error paths -------------------------------------------------------------

echo "== typed params (Goal-0002 F1) =="
# /calc/{a}/{b}: a,b 必填 int (path).
expect_code "typed path int ok" "200" "http://127.0.0.1:$PORT/calc/3/4"
expect_code "typed path int bad -> 422" "422" "http://127.0.0.1:$PORT/calc/abc/4"
expect_body_contains "typed 422 detail mentions int" "valid integer" "http://127.0.0.1:$PORT/calc/abc/4"
expect_body_contains "typed 422 has detail field" "\"detail\"" "http://127.0.0.1:$PORT/calc/abc/4"

# /typed: count int=5 (query default), verbose bool 必填.
expect_code "typed query with bool ok" "200" "http://127.0.0.1:$PORT/typed?verbose=true"
expect_code "typed query default count ok" "200" "http://127.0.0.1:$PORT/typed?verbose=false&count=20"
expect_code "typed query int bad -> 422" "422" "http://127.0.0.1:$PORT/typed?count=abc&verbose=true"
expect_code "typed query missing required -> 422" "422" "http://127.0.0.1:$PORT/typed"

echo "== unified error body + error_map (Goal-0002 F2) =="
# 声明式异常映射: _error_map = "item_id=99:404:Item not found;item_id=*:422:Invalid ID"
expect_code "error_map item_id=99 -> 404" "404" "$BASE/errors/99"
expect_body_contains "error_map 404 detail" "\"detail\": \"Item not found\"" "$BASE/errors/99"
expect_body_contains "error_map 404 status field" "\"status\": \"404\"" "$BASE/errors/99"
expect_code "error_map wildcard -> 422" "422" "$BASE/errors/42"
expect_body_contains "error_map wildcard detail" "\"detail\": \"Invalid ID\"" "$BASE/errors/42"
# 404 统一格式 (FastAPI 语义: detail 字段, 替换 error 字段)
expect_body_contains "404 unified detail field" "\"detail\": \"Route not found\"" "$BASE/nope"

echo "== request/response + nested JSON (Goal-0002 F3) =="
# F3a: Request 读 header. /ctx 声明 _reads_headers="X-Custom,User-Agent".
# helper 不支持 -H, 直接用 curl 取 body 判字段.
CTX_WITH_HDR=$(curl -sS -m 5 -H "X-Custom: hello-world" "$BASE/ctx")
if [[ "$CTX_WITH_HDR" == *"header_X-Custom"* && "$CTX_WITH_HDR" == *"hello-world"* ]]; then
    pass "F3a read X-Custom header"
else fail "F3a read X-Custom header" "body: ${CTX_WITH_HDR:0:200}"; fi
if [[ "$CTX_WITH_HDR" == *"header_User-Agent"* ]]; then pass "F3a read User-Agent"
else fail "F3a read User-Agent" "body: ${CTX_WITH_HDR:0:200}"; fi

# F3b: 自定义响应头. /ctx 声明 _response_headers="X-Handler:ctx;X-Server:fastapi_mojo".
RESP_HDRS=$(curl -sS -D - -o /dev/null -m 5 "$BASE/ctx")
if [[ "$RESP_HDRS" == *"X-Handler: ctx"* ]]; then pass "F3b custom resp X-Handler present"
else fail "F3b custom resp X-Handler present" "headers: ${RESP_HDRS}"; fi
if [[ "$RESP_HDRS" == *"X-Server: fastapi_mojo"* ]]; then pass "F3b custom resp X-Server present"
else fail "F3b custom resp X-Server present" "headers: ${RESP_HDRS}"; fi

# F3c: 嵌套 JSON. /tags 用 nest_list / nest_dict 构造.
expect_code "F3c nested -> 200" "200" "$BASE/tags"
TAGS_BODY=$(http_body "$BASE/tags")
if [[ "$TAGS_BODY" == *"\"tags\": [\"a\", \"b\", \"c\"]"* ]]; then pass "F3c nested list"
else fail "F3c nested list" "body: ${TAGS_BODY:0:200}"; fi
if [[ "$TAGS_BODY" == *"\"meta\": {"* && "$TAGS_BODY" == *"\"role\": \"admin\""* ]]; then pass "F3c nested dict"
else fail "F3c nested dict" "body: ${TAGS_BODY:0:200}"; fi

# 405 body 现在能完整送达 (pre-existing bug 修复). 405 路径走 expect_code 只查状态码.
expect_code "F2 405 body delivered -> 405" "405" "$BASE/health" POST

# F10 (v0.5.1): Cookie 参数注入. /cookies 声明 _reads_cookies="session_id,user_id".
# dispatch 从 Cookie 头解析 (RFC 6265: ';' 分隔) 注入 params["cookie_<name>"].
CK_FULL=$(curl -sS -m 5 -H "Cookie: session_id=abc123; user_id=42" "$BASE/cookies")
if [[ "$CK_FULL" == *"cookie_session_id"* && "$CK_FULL" == *"abc123"* ]]; then pass "F10 cookie session_id read"
else fail "F10 cookie session_id read" "body: ${CK_FULL:0:200}"; fi
if [[ "$CK_FULL" == *"cookie_user_id"* && "$CK_FULL" == *"\"42\""* ]]; then pass "F10 cookie user_id read"
else fail "F10 cookie user_id read" "body: ${CK_FULL:0:200}"; fi
CK_PARTIAL=$(curl -sS -m 5 -H "Cookie: session_id=xyz" "$BASE/cookies")
if [[ "$CK_PARTIAL" == *"cookie_session_id"* && "$CK_PARTIAL" == *"xyz"* ]]; then pass "F10 cookie partial (only session_id)"
else fail "F10 cookie partial (only session_id)" "body: ${CK_PARTIAL:0:200}"; fi
if [[ "$CK_PARTIAL" == *cookie_user_id* ]]; then pass "F10 cookie missing still emits key"
else fail "F10 cookie missing -> empty string" "body: ${CK_PARTIAL:0:200}"; fi
CK_NONE=$(curl -sS -m 5 "$BASE/cookies")
if [[ "$CK_NONE" != *"cookie_"* ]]; then pass "F10 cookie absent when no Cookie header"
else fail "F10 cookie absent when no Cookie header" "body: ${CK_NONE:0:200}"; fi

# F10b (v0.5.1): Form 参数注入. /login 声明 _form_fields="username,password,remember".
# dispatch 检测 POST body 是 x-www-form-urlencoded 时解析并注入 params["form_<name>"].
FORM_RESP=$(curl -sS -m 5 -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=alice&password=secret123&remember=on" "$BASE/login")
if [[ "$FORM_RESP" == *"form_username"* && "$FORM_RESP" == *"alice"* ]]; then pass "F10b form username read"
else fail "F10b form username read" "body: ${FORM_RESP:0:200}"; fi
if [[ "$FORM_RESP" == *"form_password"* && "$FORM_RESP" == *"secret123"* ]]; then pass "F10b form password read"
else fail "F10b form password read" "body: ${FORM_RESP:0:200}"; fi
FORM_ENCODED=$(curl -sS -m 5 -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=bob&password=pass%40word&remember=" "$BASE/login")
if [[ "$FORM_ENCODED" == *"pass@word"* ]]; then pass "F10b form URL-decode (%40 -> @)"
else fail "F10b form URL-decode (%40 -> @)" "body: ${FORM_ENCODED:0:200}"; fi
if [[ "$FORM_ENCODED" == *"form_remember"* ]]; then pass "F10b form empty value key present"
else fail "F10b form empty value key present" "body: ${FORM_ENCODED:0:200}"; fi

# F11 (v0.5.1): BackgroundTasks - 响应已 flush 后同步执行声明的命令.
# /bg-write 声明 _background = "date -u ... >> /tmp/bg_test.log".
# 1) 响应立即返回 (HTTP_TIME < 1s).
BG_RESP=$(curl -sS -m 5 -w "\nHTTP_TIME: %{time_total}\n" "$BASE/bg-write")
BG_TIME=$(echo "$BG_RESP" | grep "HTTP_TIME:" | awk "{print \$2}")
BG_BODY=$(echo "$BG_RESP" | head -1)
if [[ "$BG_BODY" == *"bg demo"* ]]; then pass "F11 background response immediate"
else fail "F11 background response immediate" "body: ${BG_BODY:0:200}"; fi
# 2) 等后台命令完成, 文件应被写入.
sleep 0.3
if [[ -s /tmp/bg_test.log ]]; then pass "F11 background cmd ran after response"
else fail "F11 background cmd ran after response" "/tmp/bg_test.log empty or missing"; fi
# 3) server log 含 [bg] 行.
BG_SRVLOG=$(cat "$TMP/server.log" 2>/dev/null)
if [[ "$BG_SRVLOG" == *"[bg]"* ]]; then pass "F11 background cmd logged in server log"
else fail "F11 background cmd logged in server log" "no [bg] line"; fi



echo "== openapi + swagger (Goal-0002 F4) =="
# /openapi.json: 有效 OpenAPI 3.0 文档 + 路由覆盖 + 类型标注.
expect_code "openapi.json -> 200" "200" "$BASE/openapi.json"
expect_body_contains "openapi.json openapi 3.0.3" '"openapi":"3.0.3"' "$BASE/openapi.json"
expect_body_contains "openapi.json has /calc path" ""/calc/{a}/{b}"" "$BASE/openapi.json"
expect_body_contains "openapi.json /calc typed int" '"type":"integer"' "$BASE/openapi.json"
# /docs: Swagger UI 引导页.
expect_code "docs -> 200" "200" "$BASE/docs"
expect_body_contains "docs contains SwaggerUIBundle" "SwaggerUIBundle" "$BASE/docs"

echo "== streaming / SSE (Goal-0002 F5) =="
# /sse: 一次性推送 + text/event-stream content-type + SSE 行切分合规 (FastAPI 0.140.12 修复参考).
SSE_HDRS=$(curl -sS -D - -o /dev/null -m 5 "$BASE/sse")
if [[ "$SSE_HDRS" == *"Content-Type: text/event-stream"* ]]; then pass "F5 SSE content-type"
else fail "F5 SSE content-type" "headers: ${SSE_HDRS:0:200}"; fi
expect_code "F5 SSE -> 200" "200" "$BASE/sse"
SSE_BODY=$(http_body "$BASE/sse")
if [[ "$SSE_BODY" == *"data: hello"* && "$SSE_BODY" == *"data: world"* ]]; then pass "F5 SSE multi-line event split"
else fail "F5 SSE multi-line event split" "body: ${SSE_BODY:0:200}"; fi
if [[ "$SSE_BODY" == *"data: second event"* && "$SSE_BODY" == *"data: multi"* ]]; then pass "F5 SSE multiple events"
else fail "F5 SSE multiple events" "body: ${SSE_BODY:0:200}"; fi
# SSE 终止符 \n\n (双换行) 存在
if [[ "$SSE_BODY" == *"data: event"* && "$SSE_BODY" == *"event"* ]]; then pass "F5 SSE event terminator present"
else fail "F5 SSE event terminator present" "body: ${SSE_BODY:0:200}"; fi

# F9 (v0.5.1): SSE 自定义 status_code + extra 头 (对齐上游 FastAPI 0.140.13 PR #15937).
# /sse/created 声明 _stream_status=201 + Cache-Control/X-Accel-Buffering 头.
SSE201_HDRS=$(curl -sS -D - -o /dev/null -m 5 -X POST "$BASE/sse/created")
if [[ "$SSE201_HDRS" == *"HTTP/1.1 201 Created"* ]]; then pass "F9 SSE honors custom status_code (201)"
else fail "F9 SSE honors custom status_code (201)" "headers: ${SSE201_HDRS:0:200}"; fi
if [[ "$SSE201_HDRS" == *"Content-Type: text/event-stream"* ]]; then pass "F9 SSE 201 keeps event-stream content-type"
else fail "F9 SSE 201 keeps event-stream content-type" "headers: ${SSE201_HDRS:0:200}"; fi
if [[ "$SSE201_HDRS" == *"Cache-Control: no-cache"* ]]; then pass "F9 SSE extra header Cache-Control sent"
else fail "F9 SSE extra header Cache-Control sent" "headers: ${SSE201_HDRS:0:200}"; fi
if [[ "$SSE201_HDRS" == *"X-Accel-Buffering: no"* ]]; then pass "F9 SSE extra header X-Accel-Buffering sent"
else fail "F9 SSE extra header X-Accel-Buffering sent" "headers: ${SSE201_HDRS:0:200}"; fi
SSE201_BODY=$(curl -sS -m 5 -X POST "$BASE/sse/created")
if [[ "$SSE201_BODY" == *"data: created"* ]]; then pass "F9 SSE 201 body intact"
else fail "F9 SSE 201 body intact" "body: ${SSE201_BODY:0:200}"; fi
# 回归: 未声明 _stream_status 的路由仍默认 200.
if [[ "$SSE_HDRS" == *"HTTP/1.1 200 OK"* ]]; then pass "F9 SSE default remains 200"
else fail "F9 SSE default remains 200" "headers: ${SSE_HDRS:0:200}"; fi

# --- SF-1..SF-5: SSE ServerSentEvent 字段 (决策-72, ADR-0047) -------------------------
# 上游 fastapi.sse.format_sse_event: 字段序 comment(`: `) -> event -> data(逐行) -> id ->
# retry, 末尾 `\n\n`; 行切分保留尾空串; data = raw_data(原样, 不 JSON 编码).
echo "== SSE ServerSentEvent fields (决策-72) =="
SF_HDRS=$(curl -sS -D - -o /dev/null -m 5 "$BASE/sse/fields")
if [[ "$SF_HDRS" == *"Content-Type: text/event-stream"* ]]; then pass "SF-1 /sse/fields content-type event-stream"
else fail "SF-1 /sse/fields content-type" "headers: ${SF_HDRS:0:200}"; fi
SF_EXPECT=$(printf ': ping
event: msg
data: alpha
id: 42
retry: 3000

: ping
event: msg
data: beta
id: 42
retry: 3000

')
SF_BODY=$(curl -sS -m 5 "$BASE/sse/fields")
if [[ "$SF_BODY" == "$SF_EXPECT" ]]; then pass "SF-2 field order comment/event/data/id/retry + terminator (2 events)"
else fail "SF-2 SSE field wire" "body=[$(printf '%s' "$SF_BODY" | od -c | head -8)]"; fi
SF_PING=$(printf '%s' "$SF_BODY" | grep -c '^: ping$')
if [[ "$SF_PING" == "2" ]]; then pass "SF-3 comment line per event (: ping x2)"
else fail "SF-3 comment per event" "count=$SF_PING"; fi
SF_TAIL=$(curl -sS -m 5 "$BASE/sse/tail")
if [[ "$SF_TAIL" == "$(printf 'data: t
data: 

')" ]]; then pass "SF-4 trailing newline keeps empty data line (upstream _split_sse_lines)"
else fail "SF-4 trailing newline" "body=[$(printf '%s' "$SF_TAIL" | od -c)]"; fi
if [[ "$SF_BODY" != *'"alpha"'* && "$SF_BODY" == *'data: alpha'* ]]; then pass "SF-5 data raw (no JSON quoting; raw_data semantics)"
else fail "SF-5 data raw" "body: ${SF_BODY:0:200}"; fi

echo "== metrics (Goal-0002 F6) =="
# /metrics: Prometheus 文本, 关键 metric 存在, requests_total 非负.
expect_code "F6 metrics -> 200" "200" "$BASE/metrics"
METRICS_HDRS=$(curl -sS -D - -o /dev/null -m 5 "$BASE/metrics")
if [[ "$METRICS_HDRS" == *"text/plain"* ]]; then pass "F6 metrics content-type text/plain"
else fail "F6 metrics content-type text/plain" "headers: ${METRICS_HDRS:0:200}"; fi
expect_body_contains "F6 metrics requests_total present" "fastapi_mojo_requests_total" "$BASE/metrics"
expect_body_contains "F6 metrics active_connections present" "fastapi_mojo_active_connections" "$BASE/metrics"
expect_body_contains "F6 metrics uptime present" "fastapi_mojo_uptime_seconds" "$BASE/metrics"

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

# --- access log ---------------------------------------------------------------
# F7: structured JSON access log via FASTAPI_MOJO_ACCESS_LOG=json.
# Spins up a second server on a second port (since the main server is text-mode)
# and verifies a single request produces a JSON line on stderr/stdout.
echo "== access log (F7) =="
ACL_PORT=$((PORT + 100))
ACL_LOG="$TMP/access_json.log"
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_ACCESS_LOG=json \
    "$BIN" --port "$ACL_PORT" \
    > "$ACL_LOG" 2>&1 ) &
ACL_PID=$!
# 决策-50 (ADR-0025 §3.5-7): 新 bind 后 ~2s 内的首连接可能被本机透明代理
# 劫持 (Caddy :80 假空 200, 真 server 收不到) — 就绪探针前先等端口稳定,
# 且用 body 校验 (含 'healthy'; Caddy 假响应 body 为空) 防假 ready.
# 干净环境 (CI) 无害: 仅多等 5s.
sleep 5
ACL_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$ACL_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        ACL_READY=1; break
    fi
    sleep 0.3
done
if [[ "$ACL_READY" == 1 ]]; then
    curl -s -o /dev/null "http://127.0.0.1:$ACL_PORT/health"
    sleep 0.2
    if grep -qE '\{"req_id":".+","method":"GET","path":"/health","status":"200 OK"' "$ACL_LOG"; then
        pass "F7 JSON access log line emitted"
    else
        fail "F7 JSON access log line emitted" "log: $(tail -3 "$ACL_LOG")"
    fi
else
    fail "F7 access log: second server did not start" "see $ACL_LOG"
fi
kill -TERM "$ACL_PID" 2>/dev/null
sleep 0.3
kill -9 "$ACL_PID" 2>/dev/null

# --- multipart / UploadFile (G3-v0.7, Rust bridge, 决策-32) --------------------
# /upload 声明 _multipart="true": 文本字段 -> form_<name>; 文件字段 ->
# file_<name>_filename/_size/_content_type/_body_b64. body 任意二进制 (NUL/0xFF)
# 经 Rust &[u8] 解析 + base64 注入 Mojo, 中文文本字段走 decode_utf8_bytes.
echo "== multipart (G3-v0.7) =="
MP_DIR="$TMP/mp"
mkdir -p "$MP_DIR"

# MP1: 文本字段 + 小文件 (text/plain). b64 动态计算, 逐字节比对.
printf 'Hello e2e multipart!\n' > "$MP_DIR/a.txt"
EXP_A=$(base64 -w0 "$MP_DIR/a.txt")
MP1=$(curl -sS -m 5 -X POST -F 'title=Doc Title' -F 'file=@'"$MP_DIR/a.txt"';type=text/plain' "$BASE/upload")
if [[ "$MP1" == *'"form_title": "Doc Title"'* ]]; then pass "MP1 form text field read"
else fail "MP1 form text field read" "body: ${MP1:0:160}"; fi
if [[ "$MP1" == *'"file_file_filename": "a.txt"'* ]]; then pass "MP1 file filename read"
else fail "MP1 file filename read" "body: ${MP1:0:160}"; fi
if [[ "$MP1" == *'"file_file_body_b64": "'"$EXP_A"'"'* ]]; then pass "MP1 file body base64 roundtrip"
else fail "MP1 file body base64 roundtrip" "want=$EXP_A body: ${MP1:0:160}"; fi

# MP2: 中文 UTF-8 文本字段 (decode_utf8_bytes 路径, 非 append_byte).
MP2=$(curl -sS -m 5 -X POST -F 'desc=多字段混合' -F 'title=x' "$BASE/upload")
if [[ "$MP2" == *'多字段混合'* ]]; then pass "MP2 Chinese UTF-8 text field preserved"
else fail "MP2 Chinese UTF-8 text field preserved" "body: ${MP2:0:160}"; fi

# MP3: 多文件 + 多文本字段同请求.
printf 'file-one-body' > "$MP_DIR/one.bin"
printf 'file-two-body' > "$MP_DIR/two.bin"
MP3=$(curl -sS -m 5 -X POST -F 'k1=v1' -F 'k2=v2' \
  -F 'f1=@'"$MP_DIR/one.bin"';type=application/octet-stream' \
  -F 'f2=@'"$MP_DIR/two.bin"';type=application/octet-stream' "$BASE/upload")
if [[ "$MP3" == *'"form_k1": "v1"'* && "$MP3" == *'"form_k2": "v2"'* ]]; then pass "MP3 two text fields"
else fail "MP3 two text fields" "body: ${MP3:0:200}"; fi
if [[ "$MP3" == *'"file_f1_filename": "one.bin"'* && "$MP3" == *'"file_f2_filename": "two.bin"'* ]]; then pass "MP3 two files parsed"
else fail "MP3 two files parsed" "body: ${MP3:0:200}"; fi

# MP4: 二进制 body 逐字节保真 (NUL + 0xFF + 全 0..255).
perl -e 'print pack("C*", 0..255)' > "$MP_DIR/raw.bin"
EXP_RAW=$(base64 -w0 "$MP_DIR/raw.bin")
MP4=$(curl -sS -m 5 -X POST -F 'raw=@'"$MP_DIR/raw.bin"';type=application/octet-stream' "$BASE/upload")
if [[ "$MP4" == *'"file_raw_body_b64": "'"$EXP_RAW"'"'* ]]; then pass "MP4 binary 0..255 body preserved via base64"
else fail "MP4 binary 0..255 body preserved via base64" "want_len=${#EXP_RAW} body: ${MP4:0:120}"; fi
if [[ "$MP4" == *'"file_raw_size": "256"'* ]]; then pass "MP4 file_size = actual raw bytes (256, U1; not b64 len 344)"
else fail "MP4 file_size = actual raw bytes (256)" "body: ${MP4:0:120}"; fi

# MP5: 大文件 (300KB, 内存阈值内) -> 200 + size 正确.
perl -e 'srand(42); print pack("C*", map { int(rand(256)) } 1..(300*1024))' > "$MP_DIR/large.bin"
MP5=$(curl -sS -m 10 -X POST -F 'big=@'"$MP_DIR/large.bin"';type=application/octet-stream' "$BASE/upload")
EXP5=$(base64 -w0 "$MP_DIR/large.bin")
if [[ "$MP5" == *'"file_big_body_b64": "'"$EXP5"'"'* ]]; then pass "MP5 large 300KB file body roundtrip"
else fail "MP5 large 300KB file body roundtrip" "b64_len_want=${#EXP5} body: ${MP5:0:120}"; fi

# MP6: 中文文件名 (UTF-8 filename 经 decode_utf8_bytes).
printf 'cn-content' > "$MP_DIR/cn.txt"
MP6=$(curl -sS -m 5 -X POST -F 'doc=@'"$MP_DIR/cn.txt"';filename=测试文件.txt;type=text/plain' "$BASE/upload")
if [[ "$MP6" == *'测试文件.txt'* ]]; then pass "MP6 Chinese filename preserved"
else fail "MP6 Chinese filename preserved" "body: ${MP6:0:160}"; fi

# MP7: multipart Content-Type 但 body 非 multipart (坏 boundary) -> 不崩, 200 + 无 file_* 字段.
MP7=$(curl -sS -m 5 -X POST -H 'Content-Type: multipart/form-data; boundary=none' --data-binary 'not a multipart body' "$BASE/upload")
if [[ "$MP7" == *'"message": "multipart upload demo"'* && "$MP7" != *'"file_'* ]]; then pass "MP7 malformed multipart -> 200 no file fields (no crash)"
else fail "MP7 malformed multipart -> 200 no file fields (no crash)" "body: ${MP7:0:160}"; fi

# --- UploadFile object API (决策-46, ADR-0021) -----------------------------------
# /upload-file: _file_types="doc:file;opt:file=;docs:file[]" + _file_aliases
#   doc=docfile + _form_types="note:str" (required) + _file_ops="doc:sha256".
# /upload-bytes: _file_types="raw:bytes=;small:bytes=" (all optional) +
#   _file_ops="raw:head:4;raw:range:1:3;raw:save:/tmp/fm_upload/raw.bin".
# U1 size=实际字节 / U2 value_error / U3 string_type / U4 last-wins / U5 全缺失 /
# U8 文本 part 供给 form / U9 bytes 接受文本 / alias = wire key.
echo "== UploadFile object API (决策-46, ADR-0021) =="
UP_DIR="$TMP/up46"
mkdir -p "$UP_DIR"
printf 'doc-content-46' > "$UP_DIR/doc.txt"
printf 'abcdefghij' > "$UP_DIR/b10.bin"
printf 's1-content' > "$UP_DIR/s1.txt"
printf 's2-content' > "$UP_DIR/s2.txt"

# MP8: _file_ops sha256 == sha256sum; alias docfile -> 声明名 key file_doc_*; U1 size.
MP8=$(curl -sS -m 5 -X POST -F 'docfile=@'"$UP_DIR/doc.txt"';type=text/plain' -F 'note=n8' -F 'docs=@'"$UP_DIR/doc.txt" "$BASE/upload-file")
SHA8=$(sha256sum "$UP_DIR/doc.txt" | awk '{print $1}')
if [[ "$MP8" == *'"file_doc_sha256": "'"$SHA8"'"'* && "$MP8" == *'"file_doc_size": "14"'* && "$MP8" == *'"uploadfile demo"'* ]]; then pass "MP8 _file_ops sha256 == sha256sum (alias->declared key, size=raw bytes U1)"
else fail "MP8 _file_ops sha256" "want sha=$SHA8 size=14 body: ${MP8:0:240}"; fi

# MP9: _file_ops head:4 / range:1:3 -> b64 (动态计算, python-free).
H9=$(head -c 4 "$UP_DIR/b10.bin" | base64 -w0)
R9=$(tail -c +2 "$UP_DIR/b10.bin" | head -c 3 | base64 -w0)
MP9=$(curl -sS -m 5 -X POST -F 'raw=@'"$UP_DIR/b10.bin"';type=application/octet-stream' "$BASE/upload-bytes")
if [[ "$MP9" == *'"file_raw_head_b64": "'"$H9"'"'* && "$MP9" == *'"file_raw_range_b64": "'"$R9"'"'* ]]; then pass "MP9 _file_ops head:4 + range:1:3 -> b64 (abcd / bcd)"
else fail "MP9 _file_ops head/range" "want head=$H9 range=$R9 body: ${MP9:0:240}"; fi

# MP10: _file_ops save:PATH 原子写 (.tmp->rename) + saved_ok/saved_path.
find /tmp/fm_upload -delete 2>/dev/null
mkdir -p /tmp/fm_upload
MP10=$(curl -sS -m 5 -X POST -F 'raw=@'"$UP_DIR/b10.bin"';type=application/octet-stream' "$BASE/upload-bytes")
if [[ "$MP10" == *'"file_raw_saved_ok": "true"'* && "$MP10" == *'"file_raw_saved_path": "/tmp/fm_upload/raw.bin"'* ]]; then pass "MP10 _file_ops save -> saved_ok true + path"
else fail "MP10 _file_ops save" "body: ${MP10:0:240}"; fi
if cmp -s "$UP_DIR/b10.bin" /tmp/fm_upload/raw.bin; then pass "MP10b save roundtrip byte-identical (cmp)"
else fail "MP10b save roundtrip" "ls: $(ls -la /tmp/fm_upload 2>&1 | head -3)"; fi

# MP11: all-optional (bytes) + 非 multipart CT -> U5 空 parts -> 200 无 file_*.
MP11=$(curl -sS -m 5 -X POST -H 'Content-Type: application/json' --data '{}' "$BASE/upload-bytes")
if [[ "$MP11" == *'"uploadbytes demo"'* && "$MP11" != *'"file_raw"'* ]]; then pass "MP11 all-optional non-multipart CT -> 200 no file_* (U5)"
else fail "MP11 all-optional non-multipart" "body: ${MP11:0:200}"; fi

# MP12: required 缺失 (doc + docs) -> 422 ×2 missing (note 提供).
MP12_CODE=$(curl -sS -m 5 -o "$TMP/mp12_body" -w '%{http_code}' -X POST -F 'note=n12' "$BASE/upload-file")
MP12=$(cat "$TMP/mp12_body")
N12=$(printf '%s' "$MP12" | grep -o '"type":"missing"' | wc -l | tr -d ' ')
if [[ "$MP12_CODE" == "422" && "$N12" == "2" && "$MP12" == *'"loc":["body","doc"],"'* && "$MP12" == *'"loc":["body","docs"],"'* ]]; then pass "MP12 required missing (doc+docs) -> 422 ×2 missing"
else fail "MP12 required missing" "code=$MP12_CODE n=$N12 body: ${MP12:0:240}"; fi

# MP13: 文本 part -> 声明 file 字段 (alias docfile) -> U2 value_error (上游完整措辞).
MP13_CODE=$(curl -sS -m 5 -o "$TMP/mp13_body" -w '%{http_code}' -X POST -F 'docfile=txtval' -F 'note=n13' -F 'docs=@'"$UP_DIR/doc.txt" "$BASE/upload-file")
MP13=$(cat "$TMP/mp13_body")
if [[ "$MP13_CODE" == "422" && "$MP13" == *'"type":"value_error"'* && "$MP13" == *'Expected UploadFile, received'* && "$MP13" == *'"loc":["body","doc"],"'* && "$MP13" == *'"input":"txtval"'* ]]; then pass "MP13 text part -> file field (alias) -> 422 value_error (U2)"
else fail "MP13 value_error" "code=$MP13_CODE body: ${MP13:0:240}"; fi

# MP14: 文件 part -> 声明 form 字段 (note:str) -> U3 string_type, input =
# 稳定子集 {filename,size,headers{content-disposition}}.
MP14_CODE=$(curl -sS -m 5 -o "$TMP/mp14_body" -w '%{http_code}' -X POST -F 'note=@'"$UP_DIR/doc.txt" -F 'docfile=@'"$UP_DIR/doc.txt" -F 'docs=@'"$UP_DIR/doc.txt" "$BASE/upload-file")
MP14=$(cat "$TMP/mp14_body")
if [[ "$MP14_CODE" == "422" && "$MP14" == *'"type":"string_type"'* && "$MP14" == *'"loc":["body","note"],"'* && "$MP14" == *'"filename":"doc.txt","size":14'* && "$MP14" == *'name=\"note\"; filename=\"doc.txt\"'* ]]; then pass "MP14 file part -> form field -> 422 string_type (U3, input=stable subset)"
else fail "MP14 string_type" "code=$MP14_CODE body: ${MP14:0:280}"; fi

# MP15: list 声明 (docs:file[]) -> count + list_json 顺序 (s1 先 s2) + 标量 last-wins.
MP15=$(curl -sS -m 5 -X POST -F 'docs=@'"$UP_DIR/s1.txt" -F 'docs=@'"$UP_DIR/s2.txt" -F 'docfile=@'"$UP_DIR/doc.txt" -F 'note=n15' "$BASE/upload-file")
LJ15=$(printf '%s' "$MP15" | awk '{i=index($0,"file_docs_list_json"); if(i>0) print substr($0,i)}')
if [[ "$MP15" == *'"file_docs_count": "2"'* && "$MP15" == *'"file_docs_filename": "s2.txt"'* && "$LJ15" == *s1.txt*s2.txt* ]]; then pass "MP15 list file[] -> count=2 + list_json order (s1,s2) + scalar last-wins (U4)"
else fail "MP15 list" "body: ${MP15:0:280}"; fi

# MP16: bytes 字段接受文本 part (U9): raw=abcdef -> size 6 + head/range/body b64.
MP16=$(curl -sS -m 5 -X POST -F 'raw=abcdef' "$BASE/upload-bytes")
if [[ "$MP16" == *'"file_raw_size": "6"'* && "$MP16" == *'"file_raw_body_b64": "YWJjZGVm"'* && "$MP16" == *'"file_raw_head_b64": "YWJjZA=="'* && "$MP16" == *'"file_raw_range_b64": "YmNk"'* ]]; then pass "MP16 bytes field accepts text part (U9) -> size 6 + head/range b64"
else fail "MP16 bytes-with-text" "body: ${MP16:0:240}"; fi

# MP17: bytes 字段接受文件 part (U9) -> size 10 + body b64 逐字节.
EXP17=$(base64 -w0 "$UP_DIR/b10.bin")
MP17=$(curl -sS -m 5 -X POST -F 'raw=@'"$UP_DIR/b10.bin"';type=application/octet-stream' "$BASE/upload-bytes")
if [[ "$MP17" == *'"file_raw_size": "10"'* && "$MP17" == *'"file_raw_body_b64": "'"$EXP17"'"'* && "$MP17" == *'"file_raw_saved_ok": "true"'* ]]; then pass "MP17 bytes field accepts file part (U9) -> size 10 + body b64 + save"
else fail "MP17 bytes-with-file" "body: ${MP17:0:240}"; fi

# MP18: 无 CT (非 multipart, U5) -> /upload-file 三必填 (doc/docs/note) 全缺失 422 ×3.
MP18_CODE=$(curl -sS -m 5 -o "$TMP/mp18_body" -w '%{http_code}' -X POST "$BASE/upload-file")
MP18=$(cat "$TMP/mp18_body")
N18=$(printf '%s' "$MP18" | grep -o '"type":"missing"' | wc -l | tr -d ' ')
if [[ "$MP18_CODE" == "422" && "$N18" == "3" && "$MP18" == *'"loc":["body","note"],"'* ]]; then pass "MP18 no Content-Type -> 422 ×3 missing (U5)"
else fail "MP18 no CT" "code=$MP18_CODE n=$N18 body: ${MP18:0:240}"; fi

# MP19: urlencoded CT (非 multipart, U5) + note 提供 -> 仅 doc/docs 缺失 422 ×2.
MP19_CODE=$(curl -sS -m 5 -o "$TMP/mp19_body" -w '%{http_code}' -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data 'note=n19' "$BASE/upload-file")
MP19=$(cat "$TMP/mp19_body")
N19F=$(printf '%s' "$MP19" | grep -o '"type":"missing"' | wc -l | tr -d ' ')
if [[ "$MP19_CODE" == "422" && "$N19F" == "2" && "$MP19" != *'"loc":["body","note"],"'* ]]; then pass "MP19 urlencoded CT -> 422 ×2 missing (doc+docs), note present (U5)"
else fail "MP19 urlencoded CT" "code=$MP19_CODE n=$N19F body: ${MP19:0:240}"; fi

# MP20: /openapi.json multipart body schema (U7) 关键子串.
MP20=$(curl -sS -m 5 "$BASE/openapi.json")
if [[ "$MP20" == *'"contentMediaType":"application/octet-stream"'* && "$MP20" == *'"Body_upload_file_post"'* && "$MP20" == *'"required":["docfile","docs","note"]'* && "$MP20" == *'"multipart/form-data"'* ]]; then pass "MP20 openapi.json: contentMediaType + Body_upload_file_post + required + multipart/form-data"
else fail "MP20 openapi substrings" "body: ${MP20:0:200}"; fi

# MP21: /openapi.json 完整文档 JSON 合法 (fmtool jsoncheck, python-free).
curl -sS -m 5 "$BASE/openapi.json" > "$TMP/oapi46.json"
if "$FMTOOL" jsoncheck "$TMP/oapi46.json" >/dev/null; then pass "MP21 openapi.json full doc valid JSON (fmtool jsoncheck)"
else fail "MP21 openapi jsoncheck" "$(head -c 200 "$TMP/oapi46.json")"; fi

# MP22: 文本 part 供给声明 form 字段 (U8): note=hello.
MP22=$(curl -sS -m 5 -X POST -F 'note=hello' -F 'docfile=@'"$UP_DIR/doc.txt" -F 'docs=@'"$UP_DIR/doc.txt" "$BASE/upload-file")
if [[ "$MP22" == *'"form_note": "hello"'* && "$MP22" == *'"file_doc_filename": "doc.txt"'* ]]; then pass "MP22 multipart text part feeds declared form field (U8) -> form_note=hello"
else fail "MP22 text->form" "body: ${MP22:0:240}"; fi

# MP23: alias = wire key: docfile -> 200 (声明名 key); doc (声明名做 wire) -> 无效力 -> 422 doc missing.
MP23A=$(curl -sS -m 5 -X POST -F 'docfile=@'"$UP_DIR/doc.txt" -F 'note=n23' -F 'docs=@'"$UP_DIR/doc.txt" "$BASE/upload-file")
if [[ "$MP23A" == *'"file_doc_filename": "doc.txt"'* && "$MP23A" == *'"uploadfile demo"'* ]]; then pass "MP23a alias wire key (docfile) -> 200 + declared-name key"
else fail "MP23a alias 200" "body: ${MP23A:0:240}"; fi
MP23B_CODE=$(curl -sS -m 5 -o "$TMP/mp23b_body" -w '%{http_code}' -X POST -F 'doc=@'"$UP_DIR/doc.txt" -F 'note=n23' -F 'docs=@'"$UP_DIR/doc.txt" "$BASE/upload-file")
MP23B=$(cat "$TMP/mp23b_body")
if [[ "$MP23B_CODE" == "422" && "$MP23B" == *'"type":"missing"'* && "$MP23B" == *'"loc":["body","doc"],"'* ]]; then pass "MP23b declared-name as wire (doc) has no binding -> 422 missing"
else fail "MP23b declared-name no binding" "code=$MP23B_CODE body: ${MP23B:0:240}"; fi

# --- Security (决策-34, Goal-0003 P0): HTTPBasic / HTTPBearer / APIKey --------------
# /basic: HTTPBasic (_auth=basic, _auth_users="admin:secret;user:pass123", realm=MyApp).
# /secure: HTTPBearer (_auth=bearer, _auth_tokens="tok123;abcd456", realm=MyApp).
# /api: APIKey header (_auth=apikey:header:X-Api-Key, _auth_tokens="key_abc;key_def").
# /api-q: APIKey query (_auth=apikey:query:key, _auth_tokens="key_abc").
echo "== security (决策-34) =="

# HTTPBasic: 无凭据 -> 401 + WWW-Authenticate: Basic realm="MyApp"
BASIC_NO=$(curl -sS -m 5 -D - -o /tmp/fm_e2e_basic_body "$BASE/basic")
if [[ "$BASIC_NO" == *"401 Unauthorized"* && "$BASIC_NO" == *'WWW-Authenticate: Basic realm="MyApp"'* ]]; then pass "SEC-B1 basic no creds -> 401 + WWW-Authenticate"
else fail "SEC-B1 basic no creds -> 401 + WWW-Authenticate" "hdr: ${BASIC_NO:0:200}"; fi
if [[ "$(cat /tmp/fm_e2e_basic_body)" == *'"Not authenticated"'* ]]; then pass "SEC-B2 basic no creds -> detail Not authenticated"
else fail "SEC-B2 basic no creds -> detail Not authenticated" "body: $(cat /tmp/fm_e2e_basic_body | head -c 120)"; fi

# HTTPBasic: 错误凭据 -> 401 + WWW-Authenticate
BASIC_BAD=$(curl -sS -m 5 -D - -o /tmp/fm_e2e_basic_bad -u admin:wrong "$BASE/basic")
if [[ "$BASIC_BAD" == *"401 Unauthorized"* && "$BASIC_BAD" == *'WWW-Authenticate: Basic realm="MyApp"'* && "$(cat /tmp/fm_e2e_basic_bad)" == *'"Invalid credentials"'* ]]; then pass "SEC-B3 basic wrong creds -> 401 + WWW-Authenticate + Invalid credentials"
else fail "SEC-B3 basic wrong creds -> 401" "hdr: ${BASIC_BAD:0:200}"; fi

# HTTPBasic: 正确凭据 (admin:secret) -> 200 + auth_user=admin
BASIC_OK=$(curl -sS -m 5 -u admin:secret "$BASE/basic")
if [[ "$BASIC_OK" == *'"auth_user": "admin"'* && "$BASIC_OK" == *'"basic auth demo"'* ]]; then pass "SEC-B4 basic correct (admin:secret) -> 200 + auth_user"
else fail "SEC-B4 basic correct -> 200 + auth_user" "body: ${BASIC_OK:0:200}"; fi

# HTTPBasic: 第二个用户 (user:pass123) -> 200 + auth_user=user
BASIC_OK2=$(curl -sS -m 5 -u user:pass123 "$BASE/basic")
if [[ "$BASIC_OK2" == *'"auth_user": "user"'* ]]; then pass "SEC-B5 basic second user (user:pass123) -> auth_user=user"
else fail "SEC-B5 basic second user -> auth_user=user" "body: ${BASIC_OK2:0:200}"; fi

# HTTPBearer: 无 token -> 401 + WWW-Authenticate: Bearer realm="MyApp"
BEARER_NO=$(curl -sS -m 5 -D - -o /dev/null "$BASE/secure")
if [[ "$BEARER_NO" == *"401 Unauthorized"* && "$BEARER_NO" == *'WWW-Authenticate: Bearer realm="MyApp"'* ]]; then pass "SEC-N1 bearer no token -> 401 + WWW-Authenticate"
else fail "SEC-N1 bearer no token -> 401 + WWW-Authenticate" "hdr: ${BEARER_NO:0:200}"; fi

# HTTPBearer: 错误 token -> 401 + Invalid token
BEARER_BAD=$(curl -sS -m 5 -D - -o /tmp/fm_e2e_bearer_bad -H "Authorization: Bearer badtoken" "$BASE/secure")
if [[ "$BEARER_BAD" == *"401 Unauthorized"* && "$(cat /tmp/fm_e2e_bearer_bad)" == *'"Invalid token"'* ]]; then pass "SEC-N2 bearer wrong token -> 401 + Invalid token"
else fail "SEC-N2 bearer wrong token -> 401" "hdr: ${BEARER_BAD:0:200}"; fi

# HTTPBearer: 正确 token (tok123) -> 200 + auth_token=tok123
BEARER_OK=$(curl -sS -m 5 -H "Authorization: Bearer tok123" "$BASE/secure")
if [[ "$BEARER_OK" == *'"auth_token": "tok123"'* && "$BEARER_OK" == *'"bearer auth demo"'* ]]; then pass "SEC-N3 bearer correct (tok123) -> 200 + auth_token"
else fail "SEC-N3 bearer correct -> 200 + auth_token" "body: ${BEARER_OK:0:200}"; fi

# APIKey header: 无 key -> 401
API_NO=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" "$BASE/api")
if [[ "$API_NO" == "401" ]]; then pass "SEC-K1 apikey header no key -> 401"
else fail "SEC-K1 apikey header no key -> 401" "got $API_NO"; fi

# APIKey header: 错误 key -> 401
API_BAD=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" -H "X-Api-Key: badkey" "$BASE/api")
if [[ "$API_BAD" == "401" ]]; then pass "SEC-K2 apikey header wrong key -> 401"
else fail "SEC-K2 apikey header wrong key -> 401" "got $API_BAD"; fi

# APIKey header: 正确 key (key_abc) -> 200 + auth_apikey=key_abc
API_OK=$(curl -sS -m 5 -H "X-Api-Key: key_abc" "$BASE/api")
if [[ "$API_OK" == *'"auth_apikey": "key_abc"'* && "$API_OK" == *'"apikey header demo"'* ]]; then pass "SEC-K3 apikey header correct -> 200 + auth_apikey"
else fail "SEC-K3 apikey header correct -> 200 + auth_apikey" "body: ${API_OK:0:200}"; fi

# APIKey query: 正确 (?key=key_abc) -> 200 + auth_apikey
APIQ_OK=$(curl -sS -m 5 "$BASE/api-q?key=key_abc")
if [[ "$APIQ_OK" == *'"auth_apikey": "key_abc"'* && "$APIQ_OK" == *'"apikey query demo"'* ]]; then pass "SEC-Q1 apikey query correct -> 200 + auth_apikey"
else fail "SEC-Q1 apikey query correct -> 200 + auth_apikey" "body: ${APIQ_OK:0:200}"; fi

# APIKey query: 错误 (?key=bad) -> 401
APIQ_BAD=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" "$BASE/api-q?key=bad")
if [[ "$APIQ_BAD" == "401" ]]; then pass "SEC-Q2 apikey query wrong -> 401"
else fail "SEC-Q2 apikey query wrong -> 401" "got $APIQ_BAD"; fi

# --- 决策-69 (ADR-0044): HTTPDigest runtime + OpenAPI securitySchemes ----------------
echo "== HTTPDigest + securitySchemes (决策-69) =="
DG_NO=$(curl -sS -m 5 -D - -o "$TMP/dg_no.json" "$BASE/digest")
if [[ "$DG_NO" == *'HTTP/1.1 401'* && "$DG_NO" == *'WWW-Authenticate: Digest'* ]]; then pass "DG-1 digest no auth -> 401 + WWW-Authenticate: Digest"
else fail "DG-1 digest no auth -> 401 + WWW-Authenticate: Digest" "hdr: ${DG_NO:0:200}"; fi
if "$FMTOOL" jsoncheck "$TMP/dg_no.json" >/dev/null && [[ "$(cat "$TMP/dg_no.json")" == *'"detail": "Not authenticated"'* ]]; then pass "DG-2 digest 401 detail Not authenticated"
else fail "DG-2 digest 401 detail" "body: $(head -c 120 "$TMP/dg_no.json")"; fi
DG_OK=$(curl -sS -m 5 -H "Authorization: Digest abc123" "$BASE/digest")
if [[ "$DG_OK" == *'"auth_scheme": "Digest"'* && "$DG_OK" == *'"auth_credentials": "abc123"'* ]]; then pass "DG-3 digest ok -> 200 + auth_scheme/auth_credentials"
else fail "DG-3 digest ok" "body: ${DG_OK:0:200}"; fi
DG_LC=$(curl -sS -m 5 -H "Authorization: digest xyz" "$BASE/digest")
if [[ "$DG_LC" == *'"auth_scheme": "digest"'* && "$DG_LC" == *'"auth_credentials": "xyz"'* ]]; then pass "DG-4 digest scheme case-insensitive (lowercase ok)"
else fail "DG-4 digest lowercase" "body: ${DG_LC:0:200}"; fi
DG_B=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer tok" "$BASE/digest")
if [[ "$DG_B" == "401" ]]; then pass "DG-5 wrong scheme (Bearer) -> 401"
else fail "DG-5 wrong scheme (Bearer) -> 401" "got $DG_B"; fi
EB2_HEX=$(printf 'GET /digest HTTP/1.1\r\nAuthorization: Digest \r\nConnection: close\r\n\r\n' | od -An -tx1 -v | tr -d ' \n')
expect_raw_status "DG-6 empty credentials -> 401" "401 Unauthorized" "$EB2_HEX"

SO_API=$(http_body "$BASE/openapi.json")
if [[ "$SO_API" == *'"HTTPBasic":{"type":"http","scheme":"basic"}'* && "$SO_API" == *'"HTTPBearer":{"type":"http","scheme":"bearer"}'* && "$SO_API" == *'"HTTPDigest":{"type":"http","scheme":"digest"}'* ]]; then
    pass "SO-1 securitySchemes http basic/bearer/digest"
else fail "SO-1 securitySchemes http basic/bearer/digest" "missing in: ${SO_API:0:200}"; fi
if [[ "$SO_API" == *'"APIKeyHeader":{"type":"apiKey","in":"header","name":"X-Api-Key"}'* && "$SO_API" == *'"APIKeyQuery":{"type":"apiKey","in":"query","name":"key"}'* ]]; then
    pass "SO-2 securitySchemes apiKey header/query (in,name)"
else fail "SO-2 securitySchemes apiKey" "missing in: ${SO_API:0:200}"; fi
if [[ "$SO_API" == *'"/basic":{"get":{"summary":"Secure Basic"'* && "$SO_API" == *'"security":[{"HTTPBasic":[]}]'* ]]; then
    pass "SO-3 operation security HTTPBasic + lowercase method key"
else fail "SO-3 operation security HTTPBasic" "missing in: ${SO_API:0:400}"; fi
if [[ "$SO_API" == *'"MyBasicAuth":{"type":"http","scheme":"basic"}'* && "$SO_API" == *'"security":[{"MyBasicAuth":[]}]'* ]]; then
    pass "SO-4 _auth_scheme_name override (MyBasicAuth)"
else fail "SO-4 _auth_scheme_name override" "missing in: ${SO_API:0:400}"; fi
if [[ "$SO_API" != *'{"GET":'* && "$SO_API" != *'{"POST":'* && "$SO_API" != *'{"DELETE":'* && "$SO_API" != *'{"PATCH":'* ]]; then
    pass "SO-5 OpenAPI method keys lowercase (no uppercase method keys)"
else fail "SO-5 method keys lowercase" "found uppercase method key"; fi

# --- 决策-70 (ADR-0045): OpenIdConnect + OAuth2AuthorizationCodeBearer ---------------
echo "== OpenIdConnect + OAuth2AuthorizationCodeBearer (决策-70) =="
OI_NO=$(curl -sS -m 5 -D - -o "$TMP/oi_no.json" "$BASE/openid")
if [[ "$OI_NO" == *'HTTP/1.1 401'* && "$OI_NO" == *'WWW-Authenticate: Bearer'* ]]; then pass "OI-1 openid no auth -> 401 + WWW-Authenticate: Bearer"
else fail "OI-1 openid no auth -> 401 + WWW-Authenticate: Bearer" "hdr: ${OI_NO:0:200}"; fi
if [[ "$(cat "$TMP/oi_no.json")" == *'"detail": "Not authenticated"'* ]]; then pass "OI-2 openid 401 detail Not authenticated"
else fail "OI-2 openid 401 detail" "body: $(head -c 120 "$TMP/oi_no.json")"; fi
OI_BR=$(curl -sS -m 5 -H "Authorization: Bearer tok" "$BASE/openid")
if [[ "$OI_BR" == *'"auth_credentials": "Bearer tok"'* ]]; then pass "OI-3 openid Bearer -> 200 + auth_credentials (raw header)"
else fail "OI-3 openid Bearer" "body: ${OI_BR:0:200}"; fi
OI_BS=$(curl -sS -m 5 -H "Authorization: Basic x" "$BASE/openid")
if [[ "$OI_BS" == *'"auth_credentials": "Basic x"'* ]]; then pass "OI-4 openid presence-only (any scheme -> 200)"
else fail "OI-4 openid presence-only" "body: ${OI_BS:0:200}"; fi

AC_NO=$(curl -sS -m 5 -D - -o "$TMP/ac_no.json" "$BASE/authcode")
if [[ "$AC_NO" == *'HTTP/1.1 401'* && "$AC_NO" == *'WWW-Authenticate: Bearer'* ]]; then pass "AC-1 authcode no auth -> 401 + WWW-Authenticate: Bearer"
else fail "AC-1 authcode no auth -> 401 + WWW-Authenticate: Bearer" "hdr: ${AC_NO:0:200}"; fi
AC_OK=$(curl -sS -m 5 -H "Authorization: Bearer tok" "$BASE/authcode")
if [[ "$AC_OK" == *'"auth_token": "tok"'* ]]; then pass "AC-2 authcode Bearer -> 200 + auth_token"
else fail "AC-2 authcode Bearer" "body: ${AC_OK:0:200}"; fi
AC_LC=$(curl -sS -m 5 -H "Authorization: bearer tok" "$BASE/authcode")
if [[ "$AC_LC" == *'"auth_token": "tok"'* ]]; then pass "AC-3 authcode scheme case-insensitive (lowercase bearer ok)"
else fail "AC-3 authcode lowercase bearer" "body: ${AC_LC:0:200}"; fi
AC_BAD=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" -H "Authorization: digest x" "$BASE/authcode")
if [[ "$AC_BAD" == "401" ]]; then pass "AC-4 authcode wrong scheme (digest) -> 401"
else fail "AC-4 authcode wrong scheme -> 401" "got $AC_BAD"; fi

SO2_API=$(http_body "$BASE/openapi.json")
if [[ "$SO2_API" == *'"OpenIdConnect":{"type":"openIdConnect","openIdConnectUrl":"/.well-known/openid-configuration"}'* && "$SO2_API" == *'"security":[{"OpenIdConnect":[]}]'* ]]; then
    pass "AC-5 securityScheme openIdConnect + operation security"
else fail "AC-5 openIdConnect scheme" "missing in: ${SO2_API:0:400}"; fi
if [[ "$SO2_API" == *'"OAuth2AuthorizationCodeBearer":{"type":"oauth2","flows":{"authorizationCode":{"scopes":{"items:read":"Read items"},"authorizationUrl":"/authorize","tokenUrl":"/token"}}}'* && "$SO2_API" == *'"security":[{"OAuth2AuthorizationCodeBearer":[]}]'* ]]; then
    pass "AC-6 securityScheme authorizationCode flow + operation security"
else fail "AC-6 authorizationCode flow" "missing in: ${SO2_API:0:500}"; fi
if [[ "$SO2_API" == *'"OAuth2PasswordBearer":{"type":"oauth2","flows":{"password":{'* && "$SO2_API" == *'"tokenUrl":"token"'* ]]; then
    pass "AC-7 password-flow scheme uncontaminated (tokenUrl=token)"
else fail "AC-7 password scheme uncontaminated" "missing in: ${SO2_API:0:500}"; fi

# --- response_model (决策-35, Goal-0003 P1): 响应字段过滤 ---------------------------------
# /profile 返回 name/age/email/secret, 但 _response_model="name;age" 只返回 name/age.
echo "== response_model (决策-35) =="

# /profile: 模型 name/age/email/secret + exclude secret -> 返回 name/age/email
PROFILE=$(curl -sS -m 5 "$BASE/profile")
if [[ "$PROFILE" == *'"name": "Alice"'* && "$PROFILE" == *'"age": "30"'* && "$PROFILE" == *'"email": "alice@example.com"'* ]]; then pass "RM-1 response_model returns model fields (name, age, email)"
else fail "RM-1 response_model returns model fields" "body: ${PROFILE:0:200}"; fi
if [[ "$PROFILE" != *'"secret"'* && "$PROFILE" != *"do_not_expose"* ]]; then pass "RM-2 response_model_exclude removes secret from model"
else fail "RM-2 response_model_exclude removes secret" "body: ${PROFILE:0:200}"; fi
if [[ "$PROFILE" != *'"method"'* && "$PROFILE" != *'"request_id"'* && "$PROFILE" != *'"handler"'* ]]; then pass "RM-3 response_model excludes meta fields (method, request_id, handler)"
else fail "RM-3 response_model excludes meta fields" "body: ${PROFILE:0:200}"; fi

# 回归: 未声明 _response_model 的路线保持原样 (含 meta 字段)
ITEMS=$(curl -sS -m 5 "$BASE/items")
if [[ "$ITEMS" == *'"method"'* && "$ITEMS" == *'"request_id"'* ]]; then pass "RM-4 no _response_model -> meta fields preserved (regression)"
else fail "RM-4 no _response_model -> meta fields preserved" "body: ${ITEMS:0:200}"; fi

# RM-5: exclude_none=true -> 空值字段 (note) 剔除
PNONE=$(curl -sS -m 5 "$BASE/profile-none")
if [[ "$PNONE" == *'"name": "Bob"'* && "$PNONE" != *'"note"'* ]]; then pass "RM-5 exclude_none drops empty field"
else fail "RM-5 exclude_none drops empty field" "body: ${PNONE:0:200}"; fi

# RM-6: 对照: exclude_none 缺省 -> note:"" 保留
PKEEP=$(curl -sS -m 5 "$BASE/profile-keep")
if [[ "$PKEEP" == *'"name": "Bob"'* && "$PKEEP" == *'"note": ""'* ]]; then pass "RM-6 exclude_none default keeps empty field"
else fail "RM-6 exclude_none default keeps empty field" "body: ${PKEEP:0:200}"; fi

# RM-7: 无 _response_model 时 exclude/exclude_none 是 no-op (FastAPI 对齐)
RNOOP=$(curl -sS -m 5 "$BASE/rm-noop")
if [[ "$RNOOP" == *'"message": "noop"'* && "$RNOOP" == *'"method"'* ]]; then pass "RM-7 exclude without response_model is no-op (FastAPI parity)"
else fail "RM-7 exclude without response_model is no-op" "body: ${RNOOP:0:200}"; fi

# --- lifespan (决策-36, Goal-0003 P1) -------------------------------------------------
# FastAPI `lifespan` 上下文管理器: yield 前 = startup, yield 后 = shutdown;
# 每进程一次; startup 失败 -> 服务不启动 (进程退出).
# Mojo 1.0.0 无闭包 -> 声明式 env 命令 (换行分隔), 经 run_command_json FFI 执行;
# 多 worker (re-exec) 时仅主进程 (worker 0) 执行, 对齐 nginx master init.
echo "== lifespan (决策-36) =="
LS_PORT=$((PORT + 110))
LS_DIR="$TMP/lifespan"
mkdir -p "$LS_DIR"
LS_STARTUP=$(printf 'touch %s/startup_1.log\ntouch %s/startup_2.log' "$LS_DIR" "$LS_DIR")
LS_SHUTDOWN=$(printf 'touch %s/shutdown_1.log' "$LS_DIR")
( cd "$SRC" && exec env \
    FASTAPI_MOJO_LIFESPAN_STARTUP="$LS_STARTUP" \
    FASTAPI_MOJO_LIFESPAN_SHUTDOWN="$LS_SHUTDOWN" \
    "$BIN" --port "$LS_PORT" \
    > "$LS_DIR/server.log" 2>&1 ) &
LS_PID=$!
# 决策-50 (ADR-0025 §3.5-7): 新 bind 后 ~2s 内的首连接可能被本机透明代理
# 劫持 (Caddy :80 假空 200, 真 server 收不到) — 就绪探针前先等端口稳定,
# 且用 body 校验 (含 'healthy'; Caddy 假响应 body 为空) 防假 ready.
# 干净环境 (CI) 无害: 仅多等 5s.
sleep 5
LS_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$LS_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        LS_READY=1; break
    fi
    sleep 0.3
done
if [[ "$LS_READY" == 1 ]]; then
    if [[ -f "$LS_DIR/startup_1.log" && -f "$LS_DIR/startup_2.log" ]]; then
        pass "LS-1 startup: 2 newline-separated commands ran before serving"
    else
        fail "LS-1 startup: 2 newline-separated commands ran before serving" "files missing; log: $(tail -3 "$LS_DIR/server.log")"
    fi
    expect_code "LS-2 server serving after lifespan startup" 200 "http://127.0.0.1:$LS_PORT/health"
else
    fail "LS-2 server serving after lifespan startup" "second server did not start; log: $(tail -3 "$LS_DIR/server.log")"
fi
# 优雅停止 (SIGTERM) -> shutdown 命令执行
kill -TERM "$LS_PID" 2>/dev/null
for _ in $(seq 1 20); do
    if ! kill -0 "$LS_PID" 2>/dev/null; then break; fi
    sleep 0.3
done
kill -9 "$LS_PID" 2>/dev/null
sleep 0.2
if [[ -f "$LS_DIR/shutdown_1.log" ]]; then
    pass "LS-3 shutdown command ran after graceful stop"
else
    fail "LS-3 shutdown command ran after graceful stop" "no shutdown file; log: $(tail -5 "$LS_DIR/server.log")"
fi
# startup 失败 (rc!=0) -> 进程退出且永不服务 (FastAPI: lifespan 异常 -> 启动失败)
LS2_PORT=$((PORT + 111))
( cd "$SRC" && exec env FASTAPI_MOJO_LIFESPAN_STARTUP="exit 3" \
    "$BIN" --port "$LS2_PORT" > "$LS_DIR/fail.log" 2>&1 ) &
LS2_PID=$!
LS2_GONE=0
for _ in $(seq 1 20); do
    if ! kill -0 "$LS2_PID" 2>/dev/null; then LS2_GONE=1; break; fi
    sleep 0.3
done
LS2_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$LS2_PORT/health")
if [[ "$LS2_GONE" == 1 && "$LS2_CODE" == "000" ]] && grep -q "refusing to serve" "$LS_DIR/fail.log"; then
    pass "LS-4 failing startup (rc!=0) -> process exits, never serves"
else
    fail "LS-4 failing startup (rc!=0) -> process exits, never serves" "gone=$LS2_GONE code=$LS2_CODE; log: $(tail -3 "$LS_DIR/fail.log")"
fi

# --- APIRouter (决策-37) ---------------------------------------------------------

echo "== APIRouter (prefix/tags/base_deps/include_router, 决策-37) =="
# AR-1: /api/items/{item_id} — router 级 prefix + pattern 参数
expect_code "AR-1a /api/items/42 -> 200" 200 "$BASE/api/items/42"
expect_body_contains "AR-1b /api/items/42 body item_id=42" '"item_id": "42"' "$BASE/api/items/42"
# AR-3: 基础依赖注入 (APIRouter dependencies=[api_env] -> 决策-33 机制)
expect_body_contains "AR-3a base dep api_env env=api" '"api_env_env": "api"' "$BASE/api/items/42"
expect_body_contains "AR-3b base dep api_env ver=v1" '"api_env_ver": "v1"' "$BASE/api/items/42"
# AR-2: 路由 '/' 归一到 prefix (/ -> /api/items)
expect_code "AR-2 /api/items (root via prefix) -> 200" 200 "$BASE/api/items"
# AR-4: include 级 prefix (app.include_router(r, prefix="/v1"))
expect_code "AR-4a /v1/ping -> 200" 200 "$BASE/v1/ping"
expect_body_contains "AR-4b /v1/ping body pong=v1" '"pong": "v1"' "$BASE/v1/ping"
# AR-5: 无前缀回归 (原 /items 不受 APIRouter 影响)
expect_code "AR-5 /items no regression" 200 "$BASE/items"
# AR-6: OpenAPI tags (APIRouter tags=[items] -> 操作级 "tags":["items"])
API_JSON=$(http_body "$BASE/openapi.json")
if [[ "$API_JSON" == *'"tags":["items"]'* ]]; then pass "AR-6a openapi tags [items]"
else fail "AR-6a openapi tags [items]" "missing tags in openapi: ${API_JSON:0:120}"; fi
if [[ "$API_JSON" == *'"tags":["v1"]'* ]]; then pass "AR-6b openapi tags [v1] (include 级)"
else fail "AR-6b openapi tags [v1] (include 级)" "missing tags v1 in openapi: ${API_JSON:0:120}"; fi
# AR-7: OpenAPI path 分组 — /items 仅一个 key (GET+POST 合并, 修复重复 key 非法 JSON)
ITEMS_KEY_COUNT=$(printf '%s' "$API_JSON" | grep -o '"/items":' | wc -l)
if [[ "$ITEMS_KEY_COUNT" == "1" ]]; then pass "AR-7 openapi /items grouped under one key"
else fail "AR-7 openapi /items grouped under one key" "key count=$ITEMS_KEY_COUNT (expected 1)"; fi
# AR-8: WS prefix (/api/ws/echo 端到端 echo, fmtool wsbench)
WS_API_OUT=$("$FMTOOL" wsbench "$PORT" /api/ws/echo 2 1 2>&1)
WS_API_OK=$(printf '%s' "$WS_API_OUT" | grep -c ',200$')
if [[ "$WS_API_OK" == "2" ]]; then pass "AR-8 WS prefix /api/ws/echo echo OK"
else fail "AR-8 WS prefix /api/ws/echo echo OK" "wsbench output: $WS_API_OUT"; fi

# --- Depends use_cache (决策-47, ADR-0022) -------------------------------------
# /di-cache: _depends=dc_auth;dc_tick (菱形, 默认 cached) -> P9-1: dc_tick 1 次.
# /di-nocache: _depends_nocache=dc_auth;dc_tick (直接 nocache) -> P9-2: 2 次.
# /di-mix: _depends=dc_auth2;dc_tick, dc_auth2._depends_nocache=dc_tick
#   (嵌套 nocache) -> P9-3: cached 引用复用 nocache 入库结果 = 1 次.
# _dep_calls=true -> <dep>_calls 注入 (observability 超集); /di 与 /api/items
# 未声明 -> 零输出 (回归: 无 _calls 泄漏).
echo "== Depends use_cache (决策-47, ADR-0022) =="
DCC=$(curl -sS -m 5 "$BASE/di-cache")
if [[ "$DCC" == *'"dc_tick_calls": "1"'* && "$DCC" == *'"dc_auth_calls": "1"'* ]]; then pass "DC-1 diamond default cached -> dc_tick dispatched once (P9-1)"
else fail "DC-1 diamond cached" "body: ${DCC:0:240}"; fi
if [[ "$DCC" == *'"dc_tick_tick": "TICK"'* && "$DCC" == *'"dc_auth_dc_tick_tick": "TICK"'* ]]; then pass "DC-2 diamond both refs see same memo value (P9-1 value identity)"
else fail "DC-2 memo value identity" "body: ${DCC:0:240}"; fi
DCN=$(curl -sS -m 5 "$BASE/di-nocache")
if [[ "$DCN" == *'"dc_tick_calls": "2"'* && "$DCN" == *'"dc_auth_calls": "1"'* ]]; then pass "DC-3 route nocache refs -> dc_tick dispatched twice (P9-2)"
else fail "DC-3 route nocache" "body: ${DCN:0:240}"; fi
DCM=$(curl -sS -m 5 "$BASE/di-mix")
if [[ "$DCM" == *'"dc_tick_calls": "1"'* && "$DCM" == *'"dc_auth2_calls": "1"'* ]]; then pass "DC-4 nested nocache + direct cached -> cached reuses memo, 1 dispatch (P9-3)"
else fail "DC-4 nested nocache" "body: ${DCM:0:240}"; fi
DCM2=$(curl -sS -m 5 "$BASE/di-mix")
if [[ "$DCM2" == *'"dc_tick_calls": "1"'* ]]; then pass "DC-5 per-request cache scope (second request independent, still 1)"
else fail "DC-5 per-request scope" "body: ${DCM2:0:240}"; fi
DCD=$(curl -sS -m 5 "$BASE/di")
if [[ "$DCD" == *'"get_auth_user": "demo_user"'* && "$DCD" != *'_calls"'* ]]; then pass "DC-6 /di (决策-33) regression: no _dep_calls -> zero _calls leak"
else fail "DC-6 /di regression" "body: ${DCD:0:240}"; fi
APIR=$(curl -sS -m 5 "$BASE/api/items/42")
if [[ "$APIR" == *'"api_env_env": "api"'* && "$APIR" != *'_calls"'* ]]; then pass "DC-7 APIRouter base deps (AR-3) regression: no _calls leak"
else fail "DC-7 APIRouter base deps regression" "body: ${APIR:0:240}"; fi

# --- body validation / Field constraints / Enum (决策-38) ---------------------------
# /validate (POST, _body_schema): name:str;price:float|gt=0;quantity:int=10;
#   mode:str[fast,slow]=fast;tags:str[]|items=0-5;meta:obj{city:str|len=2-6;zip:int=0}
# /enum (GET, _param_types): level:str[low,medium,high]=high
# 422 detail = FastAPI/Pydantic v2 数组 (loc/msg/type, 全错误收集).
echo "== body validation / Field constraints / Enum (决策-38) =="
BV_VALID='{"name":"widget","price":9.99,"tags":["a","b"],"meta":{"city":"sh"}}'
expect_code "BS-1a valid body -> 200" 200 "$BASE/validate" POST "$BV_VALID"
expect_body_contains "BS-1b body_name" '"body_name": "widget"' "$BASE/validate" POST "$BV_VALID"
expect_body_contains "BS-1c default quantity=10" '"body_quantity": "10"' "$BASE/validate" POST '{"name":"widget","price":9.99,"tags":[],"meta":{"city":"sh"}}'
expect_body_contains "BS-1d default mode=fast" '"body_mode": "fast"' "$BASE/validate" POST '{"name":"widget","price":9.99,"tags":[],"meta":{"city":"sh"}}'
expect_body_contains "BS-1e nested default meta_zip=0" '"body_meta_zip": "0"' "$BASE/validate" POST '{"name":"widget","price":9.99,"tags":[],"meta":{"city":"sh"}}'
expect_body_contains "BS-1f nested meta_city" '"body_meta_city": "sh"' "$BASE/validate" POST "$BV_VALID"
expect_body_contains "BS-1g tags array" '"body_tags": "[\"' "$BASE/validate" POST "$BV_VALID"
expect_code "BS-2a missing required -> 422" 422 "$BASE/validate" POST '{"price":1}'
expect_body_contains "BS-2b loc body.name" '["body","name"]' "$BASE/validate" POST '{"price":1}'
expect_body_contains "BS-2c msg Field required" '"msg":"Field required"' "$BASE/validate" POST '{"price":1}'
expect_body_contains "BS-3a float_parsing" '"type":"float_parsing"' "$BASE/validate" POST '{"name":"x","price":"abc"}'
expect_body_contains "BS-4a gt constraint" "Input should be greater than 0" "$BASE/validate" POST '{"name":"x","price":-5}'
expect_body_contains "BS-5a enum type" '"type":"enum"' "$BASE/validate" POST '{"name":"x","price":1,"mode":"turbo"}'
expect_body_contains "BS-5b enum msg" "Input should be 'fast' or 'slow'" "$BASE/validate" POST '{"name":"x","price":1,"mode":"turbo"}'
expect_body_contains "BS-6a nested loc" '["body","meta","city"]' "$BASE/validate" POST '{"name":"x","price":1,"tags":[],"meta":{"city":"s"}}'
expect_body_contains "BS-7a items max" "at most 5 item" "$BASE/validate" POST '{"name":"x","price":1,"tags":["a","b","c","d","e","f"],"meta":{"city":"ab"}}'
expect_body_contains "BS-8a json_invalid" '"type":"json_invalid"' "$BASE/validate" POST '{not json'
expect_body_contains "BS-9a elem loc" '["body","tags",0]' "$BASE/validate" POST '{"name":"x","price":1,"tags":[1,2],"meta":{"city":"ab"}}'
BV_MULTI=$(http_body "$BASE/validate" POST '{"price":-1,"mode":"turbo"}')
BV_MULTI_N=$(printf '%s' "$BV_MULTI" | grep -o '"msg":' | wc -l | tr -d ' ')
if [[ "$BV_MULTI_N" -ge 3 ]]; then pass "BS-10a multi-error collect ($BV_MULTI_N >= 3)"
else fail "BS-10a multi-error collect" "got $BV_MULTI_N: $BV_MULTI"; fi
expect_code "BS-11a enum param ok" 200 "$BASE/enum?level=low"
expect_code "BS-11b enum param bad -> 422" 422 "$BASE/enum?level=wrong"
expect_body_contains "BS-11c enum param loc" '["query","level"]' "$BASE/enum?level=wrong"
expect_body_contains "BS-12a openapi components" '"components"' "$BASE/openapi.json"
expect_body_contains "BS-12b openapi requestBody ref" '"$ref":"#/components/schemas/validate_item"' "$BASE/openapi.json"
expect_body_contains "BS-12c openapi enum array" '"enum":["low","medium","high"]' "$BASE/openapi.json"

# 决策-57: body pat=REGEX 约束 (bridge/regex.rs) + PATCH+body 解析 (ADR-0014 偏差闭环)
expect_code "BP-1a body pat valid -> 200" 200 "$BASE/bs/pat" POST '{"code":"abc123"}'
expect_body_contains "BP-1b body pat echo code" '"body_code": "abc123"' "$BASE/bs/pat" POST '{"code":"abc123"}'
expect_code "BP-1c body pat invalid (upper/sym) -> 422" 422 "$BASE/bs/pat" POST '{"code":"ABC!"}'
expect_body_contains "BP-1d body pat 422 type" "string_pattern_mismatch" "$BASE/bs/pat" POST '{"code":"ABC!"}'
expect_body_contains "BP-1e openapi body pattern" '"pattern":"^[a-z0-9]+$"' "$BASE/openapi.json"
expect_code "PATCH-B1a PATCH + body -> 200" 200 "$BASE/bs/patch" PATCH '{"note":"hello"}'
expect_body_contains "PATCH-B1b PATCH body echo note" '"body_note": "hello"' "$BASE/bs/patch" PATCH '{"note":"hello"}'

# Decision-58: array elem-level constraints (pat/len per str elem; ge per int elem; OpenAPI into items)
expect_code "BP-2a elem constraints valid -> 200" 200 "$BASE/validate/elems" POST '{"items":["abc"],"nums":[1,2]}'
expect_body_contains "BP-2b elem valid echo items" '"body_items": "[\"abc\"]"' "$BASE/validate/elems" POST '{"items":["abc"],"nums":[1,2]}'
expect_code "BP-2c elem pat fail (upper) -> 422" 422 "$BASE/validate/elems" POST '{"items":["ABC"],"nums":[0]}'
expect_body_contains "BP-2d elem pat 422 type" "string_pattern_mismatch" "$BASE/validate/elems" POST '{"items":["ABC"],"nums":[0]}'
expect_body_contains "BP-2e elem 422 loc index" '["body","items",0]' "$BASE/validate/elems" POST '{"items":["ABC"],"nums":[0]}'
expect_code "BP-2f elem len fail (too long) -> 422" 422 "$BASE/validate/elems" POST '{"items":["abcd"],"nums":[0]}'
expect_body_contains "BP-2g elem len 422 type" "string_too_long" "$BASE/validate/elems" POST '{"items":["abcd"],"nums":[0]}'
expect_code "BP-2h elem ge fail (negative) -> 422" 422 "$BASE/validate/elems" POST '{"items":["a"],"nums":[-1]}'
expect_body_contains "BP-2i elem ge 422 type" "greater_than_equal" "$BASE/validate/elems" POST '{"items":["a"],"nums":[-1]}'
expect_body_contains "BP-2j openapi items minLength+pattern" '"items":{"type":"string","minLength":1,"maxLength":3,"pattern":"^[a-z0-9]+$"}' "$BASE/openapi.json"
expect_body_contains "BP-2k openapi items minimum" '"minimum":0' "$BASE/openapi.json"

# Decision-61: recursive body schemas, including every element of obj[]{...}.
JS_VALID='{"root":"nest","models":[{"id":7,"tag":"ab"},{"id":9,"tag":"xyz"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_code "JS-1a nested schema valid -> 200" 200 "$BASE/validate/nested" POST "$JS_VALID"
expect_body_contains "JS-1b object-array element value" '"body_models_0_id": "7"' "$BASE/validate/nested" POST "$JS_VALID"
expect_body_contains "JS-1c deep nested object value" '"body_profile_address_city": "Shanghai"' "$BASE/validate/nested" POST "$JS_VALID"
expect_code "JS-2a nested array missing field -> 422" 422 "$BASE/validate/nested" POST '{"root":"nest","models":[{"tag":"ab"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_body_contains "JS-2b nested array field loc" '["body","models",0,"id"]' "$BASE/validate/nested" POST '{"root":"nest","models":[{"tag":"ab"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_body_contains "JS-2c nested array input is element" '"input":{"tag":"ab"}' "$BASE/validate/nested" POST '{"root":"nest","models":[{"tag":"ab"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_code "JS-3a nested array wrong type -> 422" 422 "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":"7","tag":"ab"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_body_contains "JS-3b nested array int_parsing" '"type":"int_parsing"' "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":"7","tag":"ab"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_code "JS-4a nested array constraint -> 422" 422 "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":0,"tag":"ab"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_body_contains "JS-4b nested array greater_than_equal" '"type":"greater_than_equal"' "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":0,"tag":"ab"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_code "JS-5a object-array max items -> 422" 422 "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":1,"tag":"ab"},{"id":2,"tag":"cd"},{"id":3,"tag":"ef"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_body_contains "JS-5b object-array too_long" '"type":"too_long"' "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":1,"tag":"ab"},{"id":2,"tag":"cd"},{"id":3,"tag":"ef"}],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_code "JS-6a non-object array element -> 422" 422 "$BASE/validate/nested" POST '{"root":"nest","models":[7],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_body_contains "JS-6b object-array model_type" '"type":"model_type"' "$BASE/validate/nested" POST '{"root":"nest","models":[7],"profile":{"email":"a@b.co","address":{"city":"Shanghai"}}}'
expect_code "JS-7a deep object missing -> 422" 422 "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":1,"tag":"ab"}],"profile":{"email":"a@b.co","address":{}}}'
expect_body_contains "JS-7b deep object loc" '["body","profile","address","city"]' "$BASE/validate/nested" POST '{"root":"nest","models":[{"id":1,"tag":"ab"}],"profile":{"email":"a@b.co","address":{}}}'
expect_body_contains "JS-8a OpenAPI obj[] recursive item schema" '"items":{"type":"object","properties":{"id":{"type":"integer","format":"int32","minimum":1}' "$BASE/openapi.json"
expect_body_contains "JS-8b OpenAPI object-array sizes" '"minItems":1,"maxItems":2' "$BASE/openapi.json"

# --- GZip 中间件 (决策-40, ADR-0015, Goal-0003 P2 矩阵 #24) -----------------------
# FastAPI/Starlette GZipMiddleware 声明式 env 等价形态: FASTAPI_MOJO_GZIP=1 启用
# (默认关 = FastAPI 默认) + MIN_SIZE (默认 500, 对齐 Starlette) + MAX_SIZE (1MiB).
# 条件: client Accept-Encoding 含裸 token gzip/x-gzip (不支持 q, 上游 quirk 对齐)
#   + body >= min_size + 非 304 + extra 无 Content-Encoding.
# 压缩后: Content-Encoding: gzip + Content-Length = 压缩后长度; Content-Type 不变.
# flate2 = 纯 Rust miniz_oxide 后端 (无 C 路径, 静态, ldd 仅 libc).
# 零 python3 (Track B 决策-22): roundtrip 用 curl --compressed 自动 gunzip + cmp.
echo "== GZip middleware (决策-40) =="
GZ_PORT=$((PORT + 101))
GZ_LOG="$TMP/gzip.log"
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_GZIP=1 \
    "$BIN" --port "$GZ_PORT" \
    > "$GZ_LOG" 2>&1 ) &
GZ_PID=$!
# 决策-50 (ADR-0025 §3.5-7): 新 bind 后 ~2s 内的首连接可能被本机透明代理
# 劫持 (Caddy :80 假空 200, 真 server 收不到) — 就绪探针前先等端口稳定,
# 且用 body 校验 (含 'healthy'; Caddy 假响应 body 为空) 防假 ready.
# 干净环境 (CI) 无害: 仅多等 5s.
sleep 5
GZ_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$GZ_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        GZ_READY=1; break
    fi
    sleep 0.3
done
if [[ "$GZ_READY" == 1 ]]; then
    GZ_BASE="http://127.0.0.1:$GZ_PORT"
    # GZ-1: 默认关 (主 server 无 env): Accept-Encoding: gzip 也不压缩 (FastAPI 默认对齐)
    if curl -s -D - -o /dev/null -H 'Accept-Encoding: gzip' "$BASE/openapi.json" | grep -qi 'content-encoding'; then
        fail "GZ-1 default off: no Content-Encoding" "default server returned gzip header"
    else
        pass "GZ-1 default off: no Content-Encoding"
    fi
    # GZ-2: 启用 + Accept-Encoding: gzip + /openapi.json (>500B) → Content-Encoding: gzip
    if curl -s -D - -o /dev/null -H 'Accept-Encoding: gzip' "$GZ_BASE/openapi.json" | grep -qi 'content-encoding: *gzip'; then
        pass "GZ-2 gzip on: Content-Encoding: gzip"
    else
        fail "GZ-2 gzip on: Content-Encoding: gzip"
    fi
    # GZ-3: 启用 + 无 Accept-Encoding → identity
    if curl -s -D - -o /dev/null "$GZ_BASE/openapi.json" | grep -qi 'content-encoding'; then
        fail "GZ-3 no accept-encoding: identity"
    else
        pass "GZ-3 no accept-encoding: identity"
    fi
    # GZ-4: 启用 + 小 body (/health <500B min_size) → identity
    if curl -s -D - -o /dev/null -H 'Accept-Encoding: gzip' "$GZ_BASE/health" | grep -qi 'content-encoding'; then
        fail "GZ-4 small body below min_size: identity"
    else
        pass "GZ-4 small body below min_size: identity"
    fi
    # GZ-5: roundtrip 逐字节一致 (curl --compressed 自动 gunzip) + JSON 完整性
    curl -s "$GZ_BASE/openapi.json" > "$TMP/gz_plain.json"
    curl -s --compressed -H 'Accept-Encoding: gzip' "$GZ_BASE/openapi.json" > "$TMP/gz_gz.json"
    if cmp -s "$TMP/gz_plain.json" "$TMP/gz_gz.json" && grep -q '"openapi"' "$TMP/gz_gz.json"; then
        pass "GZ-5 gunzip roundtrip identical"
    else
        fail "GZ-5 gunzip roundtrip identical"
    fi
else
    fail "GZ side server did not start" "see $GZ_LOG"
fi
kill -TERM "$GZ_PID" 2>/dev/null
sleep 0.3
kill -9 "$GZ_PID" 2>/dev/null

# --- CORS 完整配置 (决策-42, ADR-0017, Goal-0003 P2 矩阵 #15) -------------------
# Starlette CORSMiddleware 声明式 env 等价形态:
#   FASTAPI_MOJO_CORS_ORIGINS (CSV 或 *, 默认 * = 通配) / _METHODS (默认 7 方法) /
#   _HEADERS (CSV 或 *, 默认 Content-Type, Authorization) / _CREDENTIALS (默认 false) /
#   _MAX_AGE (默认 600 = Starlette; C 时代 86400 已对齐上游).
# 普通响应: 仅请求带被允许 Origin 时输出 (通配 → *, 白名单/credentials → 回显;
#   credentials → + Allow-Credentials: true; 不被允许 → 不带任何 CORS 头).
# 预检 (OPTIONS): origin 不允许 / ACRM 越界 / ACHR 越界 → 400 JSON; 通过 → 204 +
#   动态头集; 裸 OPTIONS (无 Origin) → 204 通配超集 (C 时代行为, 浏览器无差异).
# 零 python3 (Track B 决策-22): curl -D 抓头 + grep.
echo "== CORS (决策-42) =="
CRS_PORT=$((PORT + 102))
CRS_LOG="$TMP/cors.log"
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_CORS_ORIGINS="http://a.com,http://b.com" \
    FASTAPI_MOJO_CORS_CREDENTIALS=true \
    FASTAPI_MOJO_CORS_MAX_AGE=120 \
    "$BIN" --port "$CRS_PORT" \
    > "$CRS_LOG" 2>&1 ) &
CRS_PID=$!
# 决策-50 (ADR-0025 §3.5-7): 新 bind 后 ~2s 内的首连接可能被本机透明代理
# 劫持 (Caddy :80 假空 200, 真 server 收不到) — 就绪探针前先等端口稳定,
# 且用 body 校验 (含 'healthy'; Caddy 假响应 body 为空) 防假 ready.
# 干净环境 (CI) 无害: 仅多等 5s.
sleep 5
CRS_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$CRS_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        CRS_READY=1; break
    fi
    sleep 0.3
done
# 发一次请求, 头/体分别落盘, 打印 http code (\r 已剥, grep 大小写不敏感)
crs_req() { # [curl args...]
    curl -s --max-time 5 -D "$TMP/crs_hdr" -o "$TMP/crs_body" "$@" >/dev/null 2>&1
    tr -d '\r' < "$TMP/crs_hdr" > "$TMP/crs_hdr_c"
    head -1 "$TMP/crs_hdr_c" | awk '{print $2}'
}
crs_has_hdr() { # pattern (grep -Ei 对 crs_hdr_c)
    grep -Eiq "$1" "$TMP/crs_hdr_c"
}
if [[ "$CRS_READY" == 1 ]]; then
    CRS_BASE="http://127.0.0.1:$CRS_PORT"
    # CRS-1: 裸 OPTIONS / (主 server 默认通配, 无 Origin) → 204 + ACAO * (C 时代回归)
    code=$(crs_req -X OPTIONS "$BASE/")
    if [[ "$code" == "204" ]] && crs_has_hdr '^access-control-allow-origin: *\*$'; then
        pass "CRS-1 bare OPTIONS → 204 + ACAO *"
    else
        fail "CRS-1 bare OPTIONS → 204 + ACAO *" "code=$code"
    fi
    # CRS-2: 主 server 默认通配: GET + Origin → ACAO *
    crs_req -H 'Origin: http://example.com' "$BASE" >/dev/null
    if crs_has_hdr '^access-control-allow-origin: *\*$'; then
        pass "CRS-2 wildcard config + Origin → ACAO *"
    else
        fail "CRS-2 wildcard config + Origin → ACAO *"
    fi
    # CRS-3: 白名单命中 + credentials → 回显 origin + Allow-Credentials: true
    crs_req -H 'Origin: http://a.com' "$CRS_BASE/health" >/dev/null
    if crs_has_hdr '^access-control-allow-origin: *http://a\.com$' && crs_has_hdr '^access-control-allow-credentials: *true$'; then
        pass "CRS-3 allowed origin → echo + credentials"
    else
        fail "CRS-3 allowed origin → echo + credentials"
    fi
    # CRS-4: 白名单未命中 → 不带任何 CORS 头
    crs_req -H 'Origin: http://evil.com' "$CRS_BASE/health"
    if crs_has_hdr 'access-control'; then
        fail "CRS-4 disallowed origin → no CORS headers" "server emitted CORS for evil.com"
    else
        pass "CRS-4 disallowed origin → no CORS headers"
    fi
    # CRS-5: 预检通过 → 204 + 回显 + credentials + methods + headers + Max-Age 120
    code=$(crs_req -X OPTIONS -H 'Origin: http://a.com' \
        -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: Content-Type' "$CRS_BASE/health")
    if [[ "$code" == "204" ]] \
        && crs_has_hdr '^access-control-allow-origin: *http://a\.com$' \
        && crs_has_hdr '^access-control-allow-credentials: *true$' \
        && crs_has_hdr '^access-control-allow-methods: *GET, POST, PUT, DELETE, HEAD, OPTIONS$' \
        && crs_has_hdr '^access-control-allow-headers: *Content-Type, Authorization$' \
        && crs_has_hdr '^access-control-max-age: *120$'; then
        pass "CRS-5 preflight allowed → 204 + full header set (Max-Age 120)"
    else
        fail "CRS-5 preflight allowed → 204 + full header set" "code=$code"
    fi
    # CRS-6: ACRM 越界 (PATCH 不在默认 7 方法) → 400 JSON
    code=$(crs_req -X OPTIONS -H 'Origin: http://a.com' \
        -H 'Access-Control-Request-Method: PATCH' "$CRS_BASE/health")
    if [[ "$code" == "400" ]] && grep -q '"error":"method not allowed"' "$TMP/crs_body"; then
        pass "CRS-6 preflight ACRM out of allow_methods → 400"
    else
        fail "CRS-6 preflight ACRM out of allow_methods → 400" "code=$code body=$(cat "$TMP/crs_body")"
    fi
    # CRS-7: origin 不在白名单 → 400 JSON
    code=$(crs_req -X OPTIONS -H 'Origin: http://evil.com' \
        -H 'Access-Control-Request-Method: GET' "$CRS_BASE/health")
    if [[ "$code" == "400" ]] && grep -q '"error":"origin not allowed"' "$TMP/crs_body"; then
        pass "CRS-7 preflight origin not allowed → 400"
    else
        fail "CRS-7 preflight origin not allowed → 400" "code=$code body=$(cat "$TMP/crs_body")"
    fi
    # CRS-8: ACHR 越界 (X-Nope 不在默认头集) → 400 JSON
    code=$(crs_req -X OPTIONS -H 'Origin: http://a.com' \
        -H 'Access-Control-Request-Method: GET' \
        -H 'Access-Control-Request-Headers: X-Nope' "$CRS_BASE/health")
    if [[ "$code" == "400" ]] && grep -q '"error":"requested header not allowed"' "$TMP/crs_body"; then
        pass "CRS-8 preflight ACHR out of allow_headers → 400"
    else
        fail "CRS-8 preflight ACHR out of allow_headers → 400" "code=$code body=$(cat "$TMP/crs_body")"
    fi
else
    fail "CRS side server did not start" "see $CRS_LOG"
fi
kill -TERM "$CRS_PID" 2>/dev/null
sleep 0.3
kill -9 "$CRS_PID" 2>/dev/null

# --- Query 精化 (决策-43, ADR-0018, Goal-0003 P2 矩阵 #3) -----------------------
# /query-extra: tag:str[]= / nums:int[]= / level alias=lvl / limit alias=lmt.
#   list 多值 = 全部 occurrence 的 CSV; alias: 只按 alias key 绑定, 原始 name
#   无绑定效力 (响应 query_<name> = 绑定值 = alias 值或默认值).
# /query-req: n:int[] 必填 (无默认) -> 缺失 422.
echo "== Query extras (决策-43) =="
expect_code "QS-1 list multi 200" 200 "$BASE/query-extra?tag=a&tag=b"
expect_body_contains "QS-1 list csv" '"query_tag": "a,b"' "$BASE/query-extra?tag=a&tag=b"
expect_body_contains "QS-2 list single wrap" '"query_tag": "only"' "$BASE/query-extra?tag=only"
expect_code "QS-3 list defaults empty" 200 "$BASE/query-extra"
expect_body_contains "QS-3 tag default empty" '"query_tag": ""' "$BASE/query-extra"
expect_body_contains "QS-3 nums default empty" '"query_nums": ""' "$BASE/query-extra"
expect_body_contains "QS-4 int list" '"query_nums": "1,2"' "$BASE/query-extra?nums=1&nums=2"
expect_code "QS-5 list bad elem 422" 422 "$BASE/query-extra?nums=1&nums=zz"
expect_body_contains "QS-5 elem loc idx 1" '["query","nums",1]' "$BASE/query-extra?nums=1&nums=zz"
expect_body_contains "QS-5 int_parsing" '"type":"int_parsing"' "$BASE/query-extra?nums=1&nums=zz"
expect_code "QS-6 list bad elem idx 0" 422 "$BASE/query-extra?nums=zz"
expect_body_contains "QS-6 loc idx 0" '["query","nums",0]' "$BASE/query-extra?nums=zz"
expect_body_contains "QS-7 alias value" '"query_level": "low"' "$BASE/query-extra?lvl=low"
expect_body_contains "QS-8 raw name ignored (default)" '"query_level": "high"' "$BASE/query-extra?level=low"
expect_body_contains "QS-9 alias limit" '"query_limit": "5"' "$BASE/query-extra?lmt=5"
expect_body_contains "QS-10 raw limit ignored (default)" '"query_limit": "10"' "$BASE/query-extra?limit=9"
expect_code "QS-11 required list missing" 422 "$BASE/query-req"
expect_body_contains "QS-11 missing loc" '["query","n"]' "$BASE/query-req"
expect_body_contains "QS-11 Field required" '"msg":"Field required"' "$BASE/query-req"
expect_code "QS-12 required list ok" 200 "$BASE/query-req?n=1&n=2"
expect_body_contains "QS-12 n csv" '"query_n": "1,2"' "$BASE/query-req?n=1&n=2"
# QS-13: OpenAPI — alias name / array+items / 空 list 默认 / description
QS_API=$(http_body "$BASE/openapi.json")
if [[ "$QS_API" == *'"name":"lmt"'* ]]; then pass "QS-13a openapi alias name"
else fail "QS-13a openapi alias name" "missing parameter name lmt"; fi
if [[ "$QS_API" == *'"type":"array"'* && "$QS_API" == *'"items":{"type":"string"}'* ]]; then pass "QS-13b openapi array items"
else fail "QS-13b openapi array items" "missing array schema"; fi
if [[ "$QS_API" == *'"default":[]'* ]]; then pass "QS-13c openapi empty list default"
else fail "QS-13c openapi empty list default" "missing default []"; fi
if [[ "$QS_API" == *'"description":"Page size"'* ]]; then pass "QS-13d openapi description"
else fail "QS-13d openapi description" "missing description"; fi
# 回归: /typed 标量多值 last-wins (Starlette)
expect_code "QS-R1 scalar last-wins 200" 200 "$BASE/typed?count=1&count=2&verbose=true"
expect_body_contains "QS-R1 count last-wins" '"query_count": "2"' "$BASE/typed?count=1&count=2&verbose=true"

# --- OAuth2/JWT (决策-44, Goal-0003 P2 #17; 对标 FastAPI 0.141.1) -------------------

echo "== OAuth2/JWT (决策-44) =="

# OT-1..3: /token 正常签发 (200 + 3-part JWT + token_type)
expect_code "OT-1 /token valid 200" 200 "$BASE/token" POST "grant_type=password&username=admin&password=s3cret"
OT1_BODY=$(http_body "$BASE/token" POST "grant_type=password&username=admin&password=s3cret")
OT_TOK=$(printf '%s' "$OT1_BODY" | sed -n 's/.*"access_token": "\([^"]*\)".*/\1/p')
if [[ "$OT_TOK" == eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.* && "$OT_TOK" == *.*.* && "$OT_TOK" != *.*.*.* ]]; then
    pass "OT-2 access_token 3-part HS256 JWT"
else
    fail "OT-2 access_token 3-part HS256 JWT" "got: ${OT_TOK:0:80}"
fi
expect_body_contains "OT-3 token_type bearer" '"token_type": "bearer"' "$BASE/token" POST "grant_type=password&username=admin&password=s3cret"

# OT-4/5: 服务端签发的 token 可用于 /secure-jwt (auth_user = sub)
# (Authorization header 需 curl -H; expect_code 不支持 header, 用原始 curl)
OT4_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $OT_TOK" "$BASE/secure-jwt")
if [[ "$OT4_CODE" == "200" ]]; then pass "OT-4 server token on /secure-jwt 200"
else fail "OT-4 server token on /secure-jwt 200" "got $OT4_CODE"; fi
OT4_BODY=$(curl -s --max-time 5 -H "Authorization: Bearer $OT_TOK" "$BASE/secure-jwt")
if [[ "$OT4_BODY" == *'"auth_user": "admin"'* ]]; then pass "OT-5 auth_user = sub (admin)"
else fail "OT-5 auth_user = sub (admin)" "body: ${OT4_BODY:0:120}"; fi

# OT-6..8: /token 凭据错 -> 401 + WWW-Authenticate: Bearer (0.141.1 教程 "Incorrect email or password")
expect_code "OT-6 /token bad creds 401" 401 "$BASE/token" POST "grant_type=password&username=admin&password=wrong"
expect_body_contains "OT-7 detail Incorrect email or password" '"detail": "Incorrect email or password"' "$BASE/token" POST "grant_type=password&username=admin&password=wrong"
OT8_HDR=$(curl -s -D - -o /dev/null --max-time 5 -X POST --data "grant_type=password&username=admin&password=wrong" "$BASE/token")
if [[ "$OT8_HDR" == *'WWW-Authenticate: Bearer'* ]]; then pass "OT-8 401 WWW-Authenticate: Bearer"
else fail "OT-8 401 WWW-Authenticate: Bearer" "hdr: ${OT8_HDR:0:200}"; fi

# OT-9..12: form 校验 (0.141.1 OAuth2PasswordRequestForm 宽松模型 + Pydantic v2 detail)
expect_code "OT-9 grant=refresh 422" 422 "$BASE/token" POST "grant_type=refresh&username=admin&password=s3cret"
OT10_BODY=$(http_body "$BASE/token" POST "grant_type=refresh&username=admin&password=s3cret")
if [[ "$OT10_BODY" == *'"type":"string_pattern_mismatch"'* && "$OT10_BODY" == *'["body","grant_type"]'* && "$OT10_BODY" == *"'^password$'"* && "$OT10_BODY" == *'"input":"refresh"'* ]]; then
    pass "OT-10 pattern mismatch detail (compact pydantic)"
else
    fail "OT-10 pattern mismatch detail (compact pydantic)" "body: ${OT10_BODY:0:200}"
fi
expect_code "OT-11 missing username+password 422" 422 "$BASE/token" POST "grant_type=password"
OT12_BODY=$(http_body "$BASE/token" POST "grant_type=password")
OT12_OK=0
if [[ "$OT12_BODY" == *'"loc":["body","username"]'* && "$OT12_BODY" == *'"loc":["body","password"]'* && "$OT12_BODY" == *'"msg":"Field required"'* ]]; then
    OT12_OK=1
fi
if [[ "$OT12_OK" == "1" ]]; then pass "OT-12 both missing (collected)"
else fail "OT-12 both missing (collected)" "body: ${OT12_BODY:0:200}"; fi
expect_code "OT-13 grant missing ok (0.141.1 permissive)" 200 "$BASE/token" POST "username=admin&password=s3cret"

# OT-14..17: /secure-jwt gate (OAuth2PasswordBearer 等价)
expect_code "OT-14 no Authorization 401" 401 "$BASE/secure-jwt"
expect_body_contains "OT-14b Not authenticated" '"detail": "Not authenticated"' "$BASE/secure-jwt"
OT15_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/secure-jwt")
if [[ "$OT15_HDR" == *'WWW-Authenticate: Bearer'* ]]; then pass "OT-15 401 WWW-Authenticate: Bearer"
else fail "OT-15 401 WWW-Authenticate: Bearer" "hdr: ${OT15_HDR:0:200}"; fi
OT16_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Basic abc" "$BASE/secure-jwt")
if [[ "$OT16_CODE" == "401" ]]; then pass "OT-16 wrong scheme (Basic) 401"
else fail "OT-16 wrong scheme (Basic) 401" "got $OT16_CODE"; fi
# 空 Bearer: curl 会吃掉尾随空格 -> fmtool raw 精确字节 "Authorization: Bearer "
EB_HEX=$(printf 'GET /secure-jwt HTTP/1.1\r\nAuthorization: Bearer \r\nConnection: close\r\n\r\n' | od -An -tx1 -v | tr -d ' \n')
expect_raw_status "OT-17 empty bearer -> 401" "401 Unauthorized" "$EB_HEX"

# OT-18..22: pyjwt-2.13 独立签发 fixture (key = probe-secret-key-42, 与 demo _jwt_secret 一致)
OT_T1="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZG1pbiIsInVzZXJuYW1lIjoiYWRtaW4iLCJpYXQiOjE3ODg5NzkyMDAsImV4cCI6OTk5OTk5OTk5OX0.k9rThWezzPx3d1B6pLUl_6yLHTsmfjxXKnDCo1fDPqw"
OT_T2="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZG1pbiIsImlhdCI6MTAwMDAwMDAwMCwiZXhwIjoxMDAwMDAzNjAwfQ.cR6qjt1cKSFDGLJ7pX8UlaLCJwzi-bu1mfD7bLjbFEA"
OT_T3="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZG1pbiIsInVzZXJuYW1lIjoiYWRtaW4iLCJpYXQiOjE3ODg5NzkyMDAsImV4cCI6OTk5OTk5OTk5OX0.gySF8Qyh8XDJoe4OTixIRyCFjcHvngkYCfSd8AWF9QU"
OT_T4="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6ImFkbWluIiwiZXhwIjo5OTk5OTk5OTk5fQ.893k0xg9h4jLRQAXQulmAPKX4B0Ah8HSmElFHrZPw14"
OT_T5="eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJhZG1pbiIsInVzZXJuYW1lIjoiYWRtaW4iLCJpYXQiOjE3ODg5NzkyMDAsImV4cCI6OTk5OTk5OTk5OX0."
ot_probe() { # name expected token
    local got
    got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $3" "$BASE/secure-jwt")
    if [[ "$got" == "$2" ]]; then pass "$1"
    else fail "$1" "expected $2, got $got"; fi
}
ot_probe "OT-18 fixture T1 valid 200" 200 "$OT_T1"
ot_probe "OT-19 fixture T2 expired 401" 401 "$OT_T2"
ot_probe "OT-20 fixture T3 bad sig 401" 401 "$OT_T3"
ot_probe "OT-21 fixture T4 no sub 401" 401 "$OT_T4"
ot_probe "OT-22 fixture T5 alg=none 401" 401 "$OT_T5"

# OT-23: /token-exp (ttl=-1) 签发即过期 -> /secure-jwt 拒
OT23_TOK=$(http_body "$BASE/token-exp" POST "grant_type=password&username=admin&password=s3cret" | sed -n 's/.*"access_token": "\([^"]*\)".*/\1/p')
ot_probe "OT-23 issued-expired token 401" 401 "$OT23_TOK"

# OT-24/25: OpenAPI securitySchemes + operation-level security
OT_API=$(http_body "$BASE/openapi.json")
if [[ "$OT_API" == *'"OAuth2PasswordBearer":{"type":"oauth2","flows":{"password":{"scopes":{"items:read":"Read items","items:write":"Write items","admin":"Admin only"},"tokenUrl":"token"}}}}'* ]]; then
    pass "OT-24 openapi securitySchemes OAuth2 oauth2 (scopes+tokenUrl)"
else
    fail "OT-24 openapi securitySchemes OAuth2 oauth2 (scopes+tokenUrl)" "missing in: ${OT_API:0:200}"
fi
if [[ "$OT_API" == *'"security":[{"OAuth2PasswordBearer":[]}'* && "$OT_API" == *'"security":[{"OAuth2PasswordBearer":["items:read"]}]'* ]]; then
    pass "OT-25 openapi operation security (empty + scoped)"
else
    fail "OT-25 openapi operation security (empty + scoped)" "missing in: ${OT_API:0:200}"
fi

# OT-26..33: OAuth2 作用域 (决策-67, SecurityScopes / Security(scopes=[...]) 等价)
OT26_BODY=$(curl -s --max-time 5 -H "Authorization: Bearer $OT_TOK" "$BASE/secure-jwt/items")
if [[ "$OT26_BODY" == *'"auth_user": "admin"'* ]]; then pass "OT-26 scoped route + scoped token -> 200"
else fail "OT-26 scoped route + scoped token -> 200" "body: ${OT26_BODY:0:120}"; fi
expect_code "OT-27 scoped route no auth -> 401" 401 "$BASE/secure-jwt/items"
OT28_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/secure-jwt/items")
if [[ "$OT28_HDR" == *'WWW-Authenticate: Bearer'* && "$OT28_HDR" != *'scope='* ]]; then
    pass "OT-28 no-auth www = Bearer (no scope, framework parity)"
else
    fail "OT-28 no-auth www = Bearer (no scope, framework parity)" "hdr: ${OT28_HDR:0:200}"
fi
OT29_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $OT_TOK" "$BASE/secure-jwt/admin")
if [[ "$OT29_CODE" == "403" ]]; then pass "OT-29 missing scope -> 403"
else fail "OT-29 missing scope -> 403" "got $OT29_CODE"; fi
OT30_BODY=$(curl -s --max-time 5 -H "Authorization: Bearer $OT_TOK" "$BASE/secure-jwt/admin")
if [[ "$OT30_BODY" == *'"detail": "Not enough permissions"'* ]]; then pass "OT-30 403 detail Not enough permissions"
else fail "OT-30 403 detail Not enough permissions" "body: ${OT30_BODY:0:160}"; fi
OT31_HDR=$(curl -s -D - -o /dev/null --max-time 5 -H "Authorization: Bearer $OT_TOK" "$BASE/secure-jwt/admin")
if [[ "$OT31_HDR" == *'WWW-Authenticate: Bearer scope="admin"'* ]]; then pass "OT-31 403 www Bearer scope=\"admin\""
else fail "OT-31 403 www Bearer scope=\"admin\"" "hdr: ${OT31_HDR:0:200}"; fi
OT32_HDR=$(curl -s -D - -o /dev/null --max-time 5 -H "Authorization: Bearer bad" "$BASE/secure-jwt/admin")
if [[ "$OT32_HDR" == *'HTTP/1.1 401'* && "$OT32_HDR" == *'WWW-Authenticate: Bearer scope="admin"'* ]]; then
    pass "OT-32 bad token www includes scope (401)"
else
    fail "OT-32 bad token www includes scope (401)" "hdr: ${OT32_HDR:0:200}"
fi
# OT_T1 = 有效 HS256 token (sub=admin, 无 scope claim, 与 demo 同 secret) -> 缺 scope 403
OT33_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $OT_T1" "$BASE/secure-jwt/items")
if [[ "$OT33_CODE" == "403" ]]; then pass "OT-33 valid token without scope claim -> 403"
else fail "OT-33 valid token without scope claim -> 403" "got $OT33_CODE"; fi

# RD-1..RD-10: RedirectResponse (决策-68, ADR-0043; 上游 Starlette 等价) ---------------
# 上游: media_type=None -> 无 Content-Type; content-length: 0; Location 经
# quote(url, safe=":/%#?=@[]!$&'()*+,;"); 默认 status 307; 303/301/308 同型.
RD1_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/redirect")
if [[ "$RD1_HDR" == *'HTTP/1.1 307 Temporary Redirect'* ]]; then pass "RD-1 /redirect default 307 Temporary Redirect"
else fail "RD-1 /redirect default 307 Temporary Redirect" "hdr: ${RD1_HDR:0:200}"; fi
if [[ "$RD1_HDR" == *$'Location: /target'* ]]; then pass "RD-2 Location: /target"
else fail "RD-2 Location: /target" "hdr: ${RD1_HDR:0:200}"; fi
if [[ "$RD1_HDR" != *'Content-Type'* ]]; then pass "RD-3 no Content-Type (media_type=None quirk)"
else fail "RD-3 no Content-Type (media_type=None quirk)" "hdr: ${RD1_HDR:0:200}"; fi
RD4_LEN=$(http_body "$BASE/redirect" | wc -c | tr -d ' ')
if [[ "$RD1_HDR" == *'Content-Length: 0'* && "$RD4_LEN" == "0" ]]; then pass "RD-4 Content-Length: 0 + empty body"
else fail "RD-4 Content-Length: 0 + empty body" "hdr=${RD1_HDR:0:120} body_len=$RD4_LEN"; fi
RD5_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/redirect/303")
if [[ "$RD5_HDR" == *'HTTP/1.1 303 See Other'* && "$RD5_HDR" == *'Location: https://ex.com/x'* ]]; then
    pass "RD-5 /redirect/303 -> 303 See Other + absolute Location"
else fail "RD-5 /redirect/303 -> 303 See Other + absolute Location" "hdr: ${RD5_HDR:0:200}"; fi
RD6_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/redirect/301")
if [[ "$RD6_HDR" == *'HTTP/1.1 301 Moved Permanently'* ]]; then pass "RD-6 /redirect/301 -> 301 Moved Permanently"
else fail "RD-6 /redirect/301 -> 301 Moved Permanently" "hdr: ${RD6_HDR:0:200}"; fi
RD7_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/redirect/308")
if [[ "$RD7_HDR" == *'HTTP/1.1 308 Permanent Redirect'* ]]; then pass "RD-7 /redirect/308 -> 308 Permanent Redirect"
else fail "RD-7 /redirect/308 -> 308 Permanent Redirect" "hdr: ${RD7_HDR:0:200}"; fi
RD8_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/redirect/quote")
if [[ "$RD8_HDR" == *'Location: /p%20a%20th?x=1&y=2#frag'* ]]; then pass "RD-8 URL quote space -> %20 (safe set preserved)"
else fail "RD-8 URL quote space -> %20 (safe set preserved)" "hdr: ${RD8_HDR:0:200}"; fi
# RD-9/10: fmtool testclient follow 语义 (307 保留 method; --no-follow 见原始 307).
RD9_OUT=$("$FMTOOL" testclient http GET "$BASE/redirect" --no-follow --json-out 2>&1); RD9_RC=$?
if [[ "$RD9_RC" == "0" && "$RD9_OUT" == *'"status_code":307'* && "$RD9_OUT" == *'/target'* ]]; then
    pass "RD-9 testclient --no-follow 307 + location"
else fail "RD-9 testclient --no-follow 307 + location" "rc=$RD9_RC out=$RD9_OUT"; fi
RD10_OUT=$("$FMTOOL" testclient http GET "$BASE/redirect/health" --json-out 2>&1); RD10_RC=$?
if [[ "$RD10_RC" == "0" && "$RD10_OUT" == *'"status_code":200'* && "$RD10_OUT" == *'healthy'* ]]; then
    pass "RD-10 testclient follow 307 -> 200 /health"
else fail "RD-10 testclient follow 307 -> 200 /health" "rc=$RD10_RC out=$RD10_OUT"; fi

# --- SL-1..SL-10: Starlette redirect_slashes (决策-71, ADR-0046) ----------------------
# 上游默认 redirect_slashes=True: 无匹配时, 尾部斜杠取反的 alt 路径若存在 (method
# 无关) -> 307 绝对 URL (scheme://host<alt>?<query>); rstrip 去掉全部尾斜杠; 否则 404.
echo "== redirect_slashes (决策-71) =="
SL1_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/slash")
if [[ "$SL1_HDR" == *'HTTP/1.1 307 Temporary Redirect'* && "$SL1_HDR" == *"Location: $BASE/slash/"* ]]; then
    pass "SL-1 GET /slash -> 307 absolute Location /slash/"
else fail "SL-1 GET /slash -> 307 absolute Location" "hdr: ${SL1_HDR:0:240}"; fi
SL2_LEN=$(http_body "$BASE/slash" | wc -c | tr -d ' ')
if [[ "$SL1_HDR" != *'Content-Type'* && "$SL1_HDR" == *'Content-Length: 0'* && "$SL2_LEN" == "0" ]]; then
    pass "SL-2 slash-redirect no Content-Type + CL:0 + empty body"
else fail "SL-2 slash-redirect headers" "hdr=${SL1_HDR:0:160} len=$SL2_LEN"; fi
SL3_HDR=$(curl -s -D - -o /dev/null --max-time 5 "$BASE/slash?x=1&y=2")
if [[ "$SL3_HDR" == *"Location: $BASE/slash/?x=1&y=2"* ]]; then pass "SL-3 query string preserved in Location"
else fail "SL-3 query preserved" "hdr: ${SL3_HDR:0:240}"; fi
SL4_HDR=$(curl -s -D - -o /dev/null --max-time 5 -X POST "$BASE/slashpost/")
if [[ "$SL4_HDR" == *'HTTP/1.1 307 Temporary Redirect'* && "$SL4_HDR" == *"Location: $BASE/slashpost"* ]]; then
    pass "SL-4 POST /slashpost/ -> 307 Location /slashpost"
else fail "SL-4 POST /slashpost/ -> 307" "hdr: ${SL4_HDR:0:240}"; fi
SL5_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE/slashpost/")
if [[ "$SL5_CODE" == "307" ]]; then pass "SL-5 GET /slashpost/ -> 307 (method-independent, upstream PARTIAL)"
else fail "SL-5 GET /slashpost/ -> 307" "got $SL5_CODE"; fi
SL6_BODY=$(http_body "$BASE/slash/")
if [[ "$SL6_BODY" == *'"message": "slash demo"'* ]]; then pass "SL-6 GET /slash/ -> 200 (direct match)"
else fail "SL-6 GET /slash/ -> 200" "body: ${SL6_BODY:0:120}"; fi
SL7_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE/slash//")
if [[ "$SL7_CODE" == "404" ]]; then pass "SL-7 GET /slash// -> 404 (rstrip removes all trailing)"
else fail "SL-7 GET /slash// -> 404" "got $SL7_CODE"; fi
SL8_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE/nope/")
if [[ "$SL8_CODE" == "404" ]]; then pass "SL-8 GET /nope/ -> 404 (no alt route)"
else fail "SL-8 GET /nope/ -> 404" "got $SL8_CODE"; fi
SL9_HDR=$(curl -s -I --max-time 5 "$BASE/slash")
if [[ "$SL9_HDR" == *'HTTP/1.1 307 Temporary Redirect'* && "$SL9_HDR" == *"Location: $BASE/slash/"* ]]; then
    pass "SL-9 HEAD /slash -> 307 (HEAD maps to GET)"
else fail "SL-9 HEAD /slash -> 307" "hdr: ${SL9_HDR:0:240}"; fi
SL10_OUT=$("$FMTOOL" testclient http GET "$BASE/slash" --json-out 2>&1); SL10_RC=$?
if [[ "$SL10_RC" == "0" && "$SL10_OUT" == *'"status_code":200'* && "$SL10_OUT" == *'slash demo'* ]]; then
    pass "SL-10 testclient follow 307 -> 200 /slash/"
else fail "SL-10 testclient follow 307 -> 200" "rc=$SL10_RC out=$SL10_OUT"; fi

# --- Form 多值 + 422 parity (决策-45, ADR-0020, P2 矩阵 #5) -------------------------
# FastAPI 0.141.1 实测: list 多值 (全部 occurrence) / 标量 last-wins / alias (wire
# key) / 422 detail ("Field required" F 大写 + input 字段 + list collect-all).
FM_FULL='items=1&items=2&items=3&tags=a&count=5&fx=1.5&fb=true'
expect_body_contains "FM-1 list 3-occ csv" '"form_items": "1,2,3"' "$BASE/form-multi" POST "$FM_FULL"
expect_body_contains "FM-2 list single wrap" '"form_items": "1"' "$BASE/form-multi" POST 'items=1&tags=a'
expect_body_contains "FM-3 missing 422 F+input null" '"loc":["body","items"],"msg":"Field required","type":"missing","input":null' "$BASE/form-multi" POST 'tags=x'
expect_body_contains "FM-4 scalar default 0" '"form_count": "0"' "$BASE/form-multi" POST 'items=1&tags=a'
expect_body_contains "FM-5 list default empty (fx)" '"form_fx": ""' "$BASE/form-multi" POST 'items=1&tags=a'
expect_body_contains "FM-6 list default empty (fb)" '"form_fb": ""' "$BASE/form-multi" POST 'items=1&tags=a'
expect_body_contains "FM-7 float value" '"form_fx": "1.5"' "$BASE/form-multi" POST 'items=1&tags=a&fx=1.5'
FM8=$(http_body "$BASE/form-multi" POST 'items=1&items=zz&items=yy&tags=a')
N8=$(printf '%s' "$FM8" | grep -o '"type":"int_parsing"' | wc -l | tr -d ' ')
if [[ "$N8" == "2" ]]; then pass "FM-8 collect-all 2 int_parsing"
else fail "FM-8 collect-all 2 int_parsing" "got $N8: ${FM8:0:160}"; fi
expect_body_contains "FM-9 float_parsing input" '"type":"float_parsing","input":"abc"' "$BASE/form-multi" POST 'items=1&tags=a&fx=abc'
expect_body_contains "FM-10 bool_parsing input" '"type":"bool_parsing","input":"xyz"' "$BASE/form-multi" POST 'items=1&tags=a&fb=xyz'
expect_body_contains "FM-11 alias wire key" '"form_labels": "x,y"' "$BASE/form-alias" POST 'tags=x&tags=y'
expect_body_contains "FM-12 alias raw -> default" '"form_labels": ""' "$BASE/form-alias" POST 'labels=zz'
expect_body_contains "FM-13 scalar default (size)" '"form_size": "2"' "$BASE/form-alias" POST 'tags=x'
expect_body_contains "FM-14 login last-wins" '"form_username": "bob"' "$BASE/login" POST 'username=alice&username=bob&remember=1'
expect_body_contains "FM-15 login missing -> empty" '"form_password": ""' "$BASE/login" POST 'username=alice'
expect_body_contains "FM-16 url-encoded multi" '"form_tags": "a b,c"' "$BASE/form-multi" POST 'items=1&tags=a%20b&tags=c'
FM_OAPI=$(http_body "$BASE/openapi.json")
FM_OAPI_F="$TMP/oapi_form.json"
printf '%s' "$FM_OAPI" > "$FM_OAPI_F"
if "$FMTOOL" jsoncheck "$FM_OAPI_F" >/dev/null; then
    pass "FM-17 openapi.json valid JSON (jsoncheck)"
else
    fail "FM-17 openapi.json valid JSON (jsoncheck)" "$(head -c 200 "$FM_OAPI_F")"
fi
expect_body_contains "FM-18 form-multi requestBody+required" '"requestBody":{"required":true,"content":{"application/x-www-form-urlencoded":{"schema":{"$ref":"#/components/schemas/Body_form_multi_post"}}}}' "$BASE/openapi.json"
if [[ "$FM_OAPI" == *'"requestBody":{"content":{"application/x-www-form-urlencoded":{"schema":{"$ref":"#/components/schemas/Body_form_demo_post"}}}}'* ]]; then
    pass "FM-19 login requestBody no required"
else
    fail "FM-19 login requestBody no required" "unexpected: ${FM_OAPI:0:120}"
fi
FM19Q=$(http_body "$BASE/query-req?n=1&n=zz&n=yy")
N19=$(printf '%s' "$FM19Q" | grep -o '"type":"int_parsing"' | wc -l | tr -d ' ')
if [[ "$N19" == "2" ]]; then pass "FM-20 query collect-all 2 int_parsing (P1 fix)"
else fail "FM-20 query collect-all 2 int_parsing (P1 fix)" "got $N19: ${FM19Q:0:160}"; fi


# --- File/Streaming responses (决策-48, ADR-0023, Goal-0003 P1 矩阵 #10) --------
# Rust bridge file_serve/file_protocol: FileResponse 200/206(单段/multipart/merge/
# suffix/open/clamp)/400×4 精确消息/416/500/If-Range/INM·IMS 忽略/HEAD 仅头/
# CD(attachment/inline RFC5987)/etag = md5(f64(mtime)-size)(fmtool f64repr ×
# md5sum 独立交叉验证) + StreamingResponse chunked(no-CT quirk/自定义 status/
# extra 头/raw-socket 帧级证明). filedemo.bin = 30B "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123".
SRCFILE="$SRC/static/filedemo.bin"
F_SZ=$(stat -c '%s' "$SRCFILE")
F_MTIME_FULL=$(stat -c '%.Y' "$SRCFILE")
F_SEC="${F_MTIME_FULL%%.*}"
F_NSEC="${F_MTIME_FULL#*.}"
F_NSEC="${F_NSEC:0:9}"
while [[ ${#F_NSEC} -lt 9 ]]; do F_NSEC="${F_NSEC}0"; done
# f64repr <sec> <nsec> = 与 bridge stat_file 逐位相同 (sec + nsec*1e-9 → 最短 Display).
F_F64=$("$FMTOOL" f64repr "$F_SEC" "$F_NSEC")
F_ETAG=$(printf '%s-%s' "$F_F64" "$F_SZ" | md5sum | cut -d' ' -f1)
F_LM=$(date -u -R -d "@$F_SEC" | sed 's/ +0000$/ GMT/')

# fr_get: curl → 头 $TMP/fr_h + body $TMP/fr_b, stdout = 状态码. [额外 curl 参数...]
fr_get() { # url [curl args...]
    curl -s -w '%{http_code}' -D "$TMP/fr_h" -o "$TMP/fr_b" "${@:2}" "$1"
}
# fr_hv: 从 $TMP/fr_h 取首个匹配头值 (CRLF 剥离, 头名大小写不敏感).
fr_hv() {
    tr -d '\r' < "$TMP/fr_h" | grep -i "^$1:" | head -1 | cut -d: -f2- | sed 's/^ *//'
}

# --- FileResponse 200 全量 ---
F1B=$(cat "$SRCFILE")
code=$(fr_get "$BASE/file")
if [[ "$code" == "200" && "$(cat "$TMP/fr_b")" == "$F1B" ]]; then pass "FR-1 /file 200 exact 30B body"
else fail "FR-1 /file 200 exact 30B body" "code=$code body=$(head -c 40 "$TMP/fr_b")"; fi
fr_get "$BASE/file" >/dev/null
if [[ "$(fr_hv Content-Type)" == "application/octet-stream" && "$(fr_hv Accept-Ranges)" == "bytes" \
      && "$(fr_hv Content-Length)" == "$F_SZ" && "$(fr_hv Last-Modified)" == "$F_LM" ]]; then
    pass "FR-2 200 headers (CT/AR/CL/LM)"
else
    fail "FR-2 200 headers (CT/AR/CL/LM)" "CT=[$(fr_hv Content-Type)] AR=[$(fr_hv Accept-Ranges)] CL=[$(fr_hv Content-Length)] LM=[$(fr_hv Last-Modified)] exp-LM=[$F_LM]"
fi
fr_get "$BASE/file" >/dev/null
if [[ "$(fr_hv ETag)" == "\"$F_ETAG\"" ]]; then pass "FR-3 etag = md5(f64(mtime)-size) 交叉验证 (f64repr×md5sum)"
else fail "FR-3 etag 交叉验证" "got=[$(fr_hv ETag)] exp=[\"$F_ETAG\"] f64=$F_F64"; fi

# --- 自定义 status / CD / 500 ---
code=$(fr_get "$BASE/file-201")
if [[ "$code" == "201" ]]; then pass "FR-4 /file-201 自定义 201"
else fail "FR-4 /file-201 自定义 201" "code=$code"; fi
fr_get "$BASE/file-name" >/dev/null
if [[ "$(fr_hv Content-Disposition)" == 'attachment; filename="report.txt"' \
      && "$(fr_hv Content-Type)" == "text/plain; charset=utf-8" ]]; then
    pass "FR-5 /file-name CD attachment + filename CT charset 规则"
else
    fail "FR-5 /file-name CD" "CD=[$(fr_hv Content-Disposition)] CT=[$(fr_hv Content-Type)]"
fi
fr_get "$BASE/file-inline" >/dev/null
if [[ "$(fr_hv Content-Disposition)" == "inline; filename*=utf-8''a%20b.txt" \
      && "$(fr_hv Content-Type)" == "text/plain; charset=utf-8" ]]; then
    pass "FR-6 /file-inline CD RFC5987 filename* (空格 → %20)"
else
    fail "FR-6 /file-inline CD RFC5987" "CD=[$(fr_hv Content-Disposition)] CT=[$(fr_hv Content-Type)]"
fi
code=$(fr_get "$BASE/file-missing")
FR7FILEHDRS=$(tr -d '\r' < "$TMP/fr_h" | grep -ciE '^(etag|accept-ranges|last-modified|content-range|content-disposition):')
if [[ "$code" == "500" && "$(cat "$TMP/fr_b")" == "Internal Server Error" && "$FR7FILEHDRS" == "0" ]]; then
    pass "FR-7 /file-missing 500 (21B, 无文件头)"
else
    fail "FR-7 /file-missing 500" "code=$code body=[$(cat "$TMP/fr_b")] file-hdrs=$FR7FILEHDRS hdr=[$(tr -d '\r' < "$TMP/fr_h" | tr '\n' '|')]"
fi

# --- Range 206: 单段 / suffix / open / clamp ---
code=$(fr_get "$BASE/file" -H 'Range: bytes=0-3')
if [[ "$code" == "206" && "$(fr_hv Content-Range)" == "bytes 0-3/30" && "$(fr_hv Content-Length)" == "4" \
      && "$(cat "$TMP/fr_b")" == "ABCD" ]]; then pass "FR-8 Range 0-3 → 206 (ABCD)"
else fail "FR-8 Range 0-3" "code=$code CR=[$(fr_hv Content-Range)] body=[$(cat "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: bytes=-4')
if [[ "$code" == "206" && "$(fr_hv Content-Range)" == "bytes 26-29/30" && "$(cat "$TMP/fr_b")" == "0123" ]]; then pass "FR-9 Range -4 suffix → 206 (0123)"
else fail "FR-9 Range -4 suffix" "code=$code CR=[$(fr_hv Content-Range)] body=[$(cat "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: bytes=28-')
if [[ "$code" == "206" && "$(fr_hv Content-Range)" == "bytes 28-29/30" && "$(cat "$TMP/fr_b")" == "23" ]]; then pass "FR-10 Range 28- open → 206 (23)"
else fail "FR-10 Range 28- open" "code=$code CR=[$(fr_hv Content-Range)] body=[$(cat "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: bytes=0-30')
if [[ "$code" == "206" && "$(fr_hv Content-Range)" == "bytes 0-29/30" && "$(fr_hv Content-Length)" == "30" \
      && "$(cat "$TMP/fr_b")" == "$F1B" ]]; then pass "FR-11 Range 0-30 end>size clamp → 206 全量"
else fail "FR-11 Range clamp" "code=$code CR=[$(fr_hv Content-Range)] body=[$(cat "$TMP/fr_b")]"; fi

# --- 416 / 400×4 ---
code=$(fr_get "$BASE/file" -H 'Range: bytes=31-')
if [[ "$code" == "416" && "$(fr_hv Content-Range)" == "bytes */30" && "$(fr_hv Content-Length)" == "0" \
      && ! -s "$TMP/fr_b" ]]; then pass "FR-12 416 start>size (CR bytes */30, CL 0, 空体)"
else fail "FR-12 416" "code=$code CR=[$(fr_hv Content-Range)] CL=[$(fr_hv Content-Length)] body=[$(cat "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: bytesfoo')
if [[ "$code" == "400" && "$(cat "$TMP/fr_b")" == "Malformed range header." ]]; then pass "FR-13 400 无 '=' (Malformed range header.)"
else fail "FR-13 400 无 '='" "code=$code body=[$(cat "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: items=1-2')
if [[ "$code" == "400" && "$(cat "$TMP/fr_b")" == "Only support bytes range" ]]; then pass "FR-14 400 单位≠bytes (Only support bytes range)"
else fail "FR-14 400 单位" "code=$code body=[$(cat "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: bytes=-')
if [[ "$code" == "400" && "$(cat "$TMP/fr_b")" == "Range header: range must be requested" ]]; then pass "FR-15 400 0 有效段 (range must be requested)"
else fail "FR-15 400 0 有效段" "code=$code body=[$(cat "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: bytes=5-2')
if [[ "$code" == "400" && "$(cat "$TMP/fr_b")" == "Range header: start must be less than end" ]]; then pass "FR-16 400 start≥end (start must be less than end)"
else fail "FR-16 400 start≥end" "code=$code body=[$(cat "$TMP/fr_b")]"; fi
fr_get "$BASE/file" -H 'Range: bytesfoo' >/dev/null
if [[ "$(fr_hv Content-Type)" == "text/plain; charset=utf-8" ]]; then pass "FR-17 400 body CT = text/plain; charset=utf-8"
else fail "FR-17 400 CT" "CT=[$(fr_hv Content-Type)]"; fi

# --- 101+ 段 quirk → 200 / merge 重叠 ---
R101=""
for i in $(seq 0 100); do R101="${R101:+$R101,}$i-$i"; done
code=$(fr_get "$BASE/file" -H "Range: bytes=$R101")
if [[ "$code" == "200" && "$(fr_hv Content-Length)" == "30" && "$(cat "$TMP/fr_b")" == "$F1B" ]]; then
    pass "FR-18 101 段 quirk → 200 全量 (starlette _parse_ranges 溢出)"
else fail "FR-18 101 段 quirk" "code=$code CL=[$(fr_hv Content-Length)] body=[$(head -c 20 "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H 'Range: bytes=0-1,1-3')
if [[ "$code" == "206" && "$(fr_hv Content-Range)" == "bytes 0-3/30" && "$(fr_hv Content-Length)" == "4" \
      && "$(cat "$TMP/fr_b")" == "ABCD" ]]; then pass "FR-19 merge 重叠 0-1,1-3 → 206 bytes 0-3/30"
else fail "FR-19 merge 重叠" "code=$code CR=[$(fr_hv Content-Range)] body=[$(cat "$TMP/fr_b")]"; fi

# --- multi-range 206: 精确 body (boundary 抽取 + printf 期望 + cmp) ---
code=$(fr_get "$BASE/file" -H 'Range: bytes=0-3,10-13')
FR20CT=$(fr_hv Content-Type)
BD="${FR20CT#multipart/byteranges; boundary=}"
EXP20=$TMP/fr20_exp
printf -- "--${BD}\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes 0-3/30\r\n\r\nABCD\r\n--${BD}\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes 10-13/30\r\n\r\nKLMN\r\n--${BD}--" > "$EXP20"
# CL 公式: 4+26 + (49+26+24+2+1+1+4) + (49+26+24+2+2+2+4) = 246 (26 = boundary 长度)
FR20CRHDR=$(tr -d '\r' < "$TMP/fr_h" | grep -ci '^content-range:')
FR20CMP=1
cmp -s "$TMP/fr_b" "$EXP20" && FR20CMP=0
if [[ "$code" == "206" && ${#BD} == 26 && "$BD" =~ ^[0-9a-f]+$ && "$FR20CRHDR" == "0" \
      && "$(fr_hv Content-Length)" == "246" && "$FR20CMP" == "0" ]]; then
    pass "FR-20 multi-range 206 精确 body (CL 246, 26-hex boundary, 头无 CR)"
else
    fail "FR-20 multi-range 206" "code=$code BD=[$BD] CR-hdr=$FR20CRHDR CL=[$(fr_hv Content-Length)] exp-size=$(stat -c '%s' "$EXP20") got-size=$(stat -c '%s' "$TMP/fr_b")"
fi

# --- If-Range / If-None-Match / If-Modified-Since ---
code=$(fr_get "$BASE/file" -H "If-Range: \"$F_ETAG\"" -H 'Range: bytes=0-3')
if [[ "$code" == "206" && "$(fr_hv Content-Range)" == "bytes 0-3/30" ]]; then pass "FR-21 If-Range = ETag (match) → 206"
else fail "FR-21 If-Range etag" "code=$code CR=[$(fr_hv Content-Range)]"; fi
code=$(fr_get "$BASE/file" -H "If-Range: $F_LM" -H 'Range: bytes=0-3')
if [[ "$code" == "206" && "$(fr_hv Content-Range)" == "bytes 0-3/30" ]]; then pass "FR-22 If-Range = Last-Modified (match) → 206"
else fail "FR-22 If-Range LM" "code=$code CR=[$(fr_hv Content-Range)]"; fi
code=$(fr_get "$BASE/file" -H 'If-Range: "stale"' -H 'Range: bytes=0-3')
if [[ "$code" == "200" && "$(fr_hv Content-Length)" == "30" && "$(cat "$TMP/fr_b")" == "$F1B" ]]; then pass "FR-23 If-Range stale → 200 全量"
else fail "FR-23 If-Range stale" "code=$code body=[$(head -c 20 "$TMP/fr_b")]"; fi
code=$(fr_get "$BASE/file" -H "If-None-Match: \"$F_ETAG\"")
if [[ "$code" == "200" && "$(fr_hv Content-Length)" == "30" ]]; then pass "FR-24 If-None-Match 忽略 (200 全量, parity)"
else fail "FR-24 If-None-Match" "code=$code CL=[$(fr_hv Content-Length)]"; fi
code=$(fr_get "$BASE/file" -H 'If-Modified-Since: Fri, 31 Dec 2099 00:00:00 GMT')
if [[ "$code" == "200" && "$(fr_hv Content-Length)" == "30" ]]; then pass "FR-25 If-Modified-Since 忽略 (200 全量, parity)"
else fail "FR-25 If-Modified-Since" "code=$code CL=[$(fr_hv Content-Length)]"; fi

# --- HEAD (仅头; 上游 HEAD→405 quirk 的文档化偏差: 我们更优) ---
# raw-socket HEAD (curl -I -o 会把头 dump 进 -o 文件: curl quirk; 线级证明无 body).
# head_raw: url [extra-header] → 文件 $TMP/frh_raw (Connection: close 即关).
head_raw() {
    local extra=""
    [[ $# -gt 1 && -n "${2:-}" ]] && extra="$2
"
    timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT || exit 1; printf 'HEAD $1 HTTP/1.1\r\nHost: fm\r\n${extra}Connection: close\r\n\r\n' >&3; cat <&3" > "$TMP/frh_raw" 2>/dev/null
}
frh_hdr() { tr -d '\r' < "$TMP/frh_raw" | grep -i "^$1:" | head -1 | cut -d: -f2- | sed 's/^ *//'; }
frh_bodylen() { awk 'BEGIN{RS="\r\n\r\n"} NR==2' "$TMP/frh_raw" | wc -c | tr -d ' '; }

head_raw "/file"
if [[ "$(head -1 "$TMP/frh_raw" | tr -d '\r')" == "HTTP/1.1 200 OK" && "$(frh_hdr Content-Length)" == "30"       && "$(frh_hdr Accept-Ranges)" == "bytes" && -n "$(frh_hdr ETag)" && "$(frh_bodylen)" == "0" ]]; then
    pass "FR-26 HEAD /file → 200 仅头 (CL 30, AR, ETag, 线级空体)"
else
    fail "FR-26 HEAD 200" "line1=[$(head -1 "$TMP/frh_raw" | tr -d '\r')] CL=[$(frh_hdr Content-Length)] AR=[$(frh_hdr Accept-Ranges)] body-len=$(frh_bodylen)"
fi
head_raw "/file" "Range: bytes=2-4"
if [[ "$(head -1 "$TMP/frh_raw" | tr -d '\r')" == "HTTP/1.1 206 Partial Content" && "$(frh_hdr Content-Range)" == "bytes 2-4/30"       && "$(frh_hdr Content-Length)" == "3" && "$(frh_bodylen)" == "0" ]]; then
    pass "FR-27 HEAD + Range → 206 仅头 (CR 2-4, CL 3, 线级空体)"
else
    fail "FR-27 HEAD+Range" "line1=[$(head -1 "$TMP/frh_raw" | tr -d '\r')] CR=[$(frh_hdr Content-Range)] CL=[$(frh_hdr Content-Length)] body-len=$(frh_bodylen)"
fi

# --- StreamingResponse (chunked) ---
code=$(fr_get "$BASE/stream")
if [[ "$code" == "200" && "$(fr_hv Transfer-Encoding)" == "chunked" && -z "$(fr_hv Content-Type)" \
      && -z "$(fr_hv Content-Length)" && "$(cat "$TMP/fr_b")" == "hello world中" ]]; then
    pass "FR-28 /stream chunked (no-CT quirk, 3 段含 UTF-8)"
else
    fail "FR-28 /stream chunked" "code=$code TE=[$(fr_hv Transfer-Encoding)] CT=[$(fr_hv Content-Type)] body=[$(head -c 30 "$TMP/fr_b")]"
fi
code=$(fr_get "$BASE/stream-json")
if [[ "$code" == "202" && "$(fr_hv Content-Type)" == "application/json" && "$(fr_hv Transfer-Encoding)" == "chunked" \
      && "$(fr_hv X-Custom)" == "cv" && "$(cat "$TMP/fr_b")" == '{"a":0}{"a":1}{"a":2}' ]]; then
    pass "FR-29 /stream-json 202 + CT + X-Custom extra 头透传"
else
    fail "FR-29 /stream-json" "code=$code CT=[$(fr_hv Content-Type)] XC=[$(fr_hv X-Custom)] body=[$(head -c 30 "$TMP/fr_b")]"
fi
code=$(fr_get "$BASE/stream-empty")
if [[ "$code" == "200" && "$(fr_hv Transfer-Encoding)" == "chunked" && -z "$(fr_hv Content-Type)" \
      && -z "$(cat "$TMP/fr_b")" ]]; then pass "FR-30 /stream-empty 200 chunked 空体 (键存在语义)"
else fail "FR-30 /stream-empty" "code=$code TE=[$(fr_hv Transfer-Encoding)] body-size=$(stat -c '%s' "$TMP/fr_b")"; fi

# --- raw-socket 帧级证明 (chunked 线格式, 不依赖客户端解码; Connection: close 即关) ---
timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT || exit 1; printf 'GET /stream HTTP/1.1\r\nHost: fm\r\nConnection: close\r\n\r\n' >&3; cat <&3" > "$TMP/fr31" 2>/dev/null
if grep -aqF $'6\r\nhello \r\n' "$TMP/fr31" && grep -aqF $'5\r\nworld\r\n' "$TMP/fr31" \
   && grep -aqF $'3\r\n\xe4\xb8\xad\r\n' "$TMP/fr31" && grep -aqF $'0\r\n\r\n' "$TMP/fr31"; then
    pass "FR-31 raw-socket chunked 帧 (6:hello /5:world/3:中/0 终止)"
else
    fail "FR-31 raw-socket chunked 帧" "raw=[$(head -c 200 "$TMP/fr31" | tr -d '\r')]"
fi

# --- 重复请求稳定性 (无连接泄漏/无状态漂移) ---
STAB_OK=1
for i in $(seq 1 10); do
    code=$(fr_get "$BASE/file")
    [[ "$code" == "200" && "$(fr_hv Content-Length)" == "30" ]] || STAB_OK=0
done
if [[ "$STAB_OK" == 1 ]]; then pass "FR-32 /file ×10 稳定 (200 + CL 30)"
else fail "FR-32 /file ×10 稳定" "不稳定 (见上面各行)"; fi
# =====================================================================
# XH: 任意异常类型 handler (决策-49, ADR-0024, Goal-0003 矩阵 #13)
#
# XH-1..6: 主 server (无 FASTAPI_MOJO_EXCEPTION_HANDLERS) —
#   未处理异常 -> 默认 500 "Internal Server Error" (text/plain, P13-10
#   parity); 正常路由与声明式 _error_map 路径不受影响 (回归).
# XH-7..13: 副 server (env 表) — 精确 tag / Exception catch-all /
#   json 条目 / 路由级 _exc_handlers 覆盖 / 同 tag 后者胜 / 无 tag 消息
#   落 catch-all / 正常路由不受表影响.
# =====================================================================
echo "== exception handlers (XH, 决策-49) =="

# --- 主 server: 无表 -> 默认 500 (P13-10) ---
for t in "XH-1 /exc/ve:500" "XH-2 /exc/unicorn:500" "XH-3 /exc/unhandled:500" "XH-4 /exc/raise-plain:500"; do
    name="${t%% *}"
    path=$(echo "$t" | cut -d: -f1 | cut -d' ' -f2)
    want=$(echo "$t" | cut -d: -f2)
    code=$(http_code "$BASE$path")
    body=$(http_body "$BASE$path")
    if [[ "$code" == "$want" && "$body" == "Internal Server Error" ]]; then
        pass "$name $path -> 500 'Internal Server Error' (text/plain, P13-10)"
    else
        fail "$name $path -> 500 'Internal Server Error'" "code=$code body=[$body]"
    fi
done
ct=$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 "$BASE/exc/ve")
if [[ "$ct" == "text/plain; charset=utf-8" ]]; then
    pass "XH-1b /exc/ve Content-Type = text/plain; charset=utf-8"
else
    fail "XH-1b /exc/ve Content-Type" "ct=[$ct]"
fi
if [[ "$(http_code "$BASE/health")" == "200" ]]; then
    pass "XH-5 /health 200 (正常路由不受影响)"
else
    fail "XH-5 /health 200" "code=$(http_code "$BASE/health")"
fi
if [[ "$(http_code "$BASE/errors/99")" == "404" ]]; then
    pass "XH-6 /errors/99 404 (声明式 _error_map 路径不受影响, F2 回归)"
else
    fail "XH-6 /errors/99 404" "code=$(http_code "$BASE/errors/99")"
fi

# --- 副 server: env 表 ---
EXC_PORT=$((PORT + 110))
EXC_LOG="$TMP/exc_server.log"
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_EXCEPTION_HANDLERS='ValueError:418:oops {exc};UnicornException:418:rainbow {exc};Exception:503:server down {exc};JsonExc:422:{"detail":"bad {exc}"}:json;Dup:400:first;Dup:404:second {exc}' \
    "$BIN" --port "$EXC_PORT" \
    > "$EXC_LOG" 2>&1 ) &
EXC_PID=$!
# 决策-50 (ADR-0025 §3.5-7): 新 bind 后 ~2s 内的首连接可能被本机透明代理
# 劫持 (Caddy :80 假空 200, 真 server 收不到) — 就绪探针前先等端口稳定,
# 且用 body 校验 (含 'healthy'; Caddy 假响应 body 为空) 防假 ready.
# 干净环境 (CI) 无害: 仅多等 5s.
sleep 5
EXC_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$EXC_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        EXC_READY=1; break
    fi
    sleep 0.3
done
if [[ "$EXC_READY" == 1 ]]; then
    EB="http://127.0.0.1:$EXC_PORT"
    # XH-7: 精确 tag -> 418 text
    code=$(http_code "$EB/exc/ve"); body=$(http_body "$EB/exc/ve")
    if [[ "$code" == "418" && "$body" == "oops bad value from handler" ]]; then
        pass "XH-7 /exc/ve -> 418 'oops bad value from handler' (精确 tag)"
    else
        fail "XH-7 /exc/ve -> 418" "code=$code body=[$body]"
    fi
    # XH-8: 自定义"异常类" tag
    code=$(http_code "$EB/exc/unicorn"); body=$(http_body "$EB/exc/unicorn")
    if [[ "$code" == "418" && "$body" == "rainbow rainbow lost" ]]; then
        pass "XH-8 /exc/unicorn -> 418 'rainbow rainbow lost' (自定义 tag)"
    else
        fail "XH-8 /exc/unicorn -> 418" "code=$code body=[$body]"
    fi
    # XH-9: 无匹配 -> Exception catch-all -> 503
    code=$(http_code "$EB/exc/unhandled"); body=$(http_body "$EB/exc/unhandled")
    if [[ "$code" == "503" && "$body" == "server down no entry for this" ]]; then
        pass "XH-9 /exc/unhandled -> 503 catch-all (Exception 键)"
    else
        fail "XH-9 /exc/unhandled -> 503 catch-all" "code=$code body=[$body]"
    fi
    # XH-10: json 条目 -> application/json + 转义安全 body
    code=$(http_code "$EB/exc/ve2"); body=$(http_body "$EB/exc/ve2")
    ct=$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 "$EB/exc/ve2")
    if [[ "$code" == "422" && "$body" == '{"detail":"bad boom"}' && "$ct" == "application/json" ]]; then
        pass "XH-10 /exc/ve2 -> 422 json {detail} (CT application/json)"
    else
        fail "XH-10 /exc/ve2 -> 422 json" "code=$code body=[$body] ct=[$ct]"
    fi
    # XH-11: 路由级 _exc_handlers 整体替换全局表
    code=$(http_code "$EB/exc/override"); body=$(http_body "$EB/exc/override")
    if [[ "$code" == "429" && "$body" == "overridden x" ]]; then
        pass "XH-11 /exc/override -> 429 (路由级表覆盖全局)"
    else
        fail "XH-11 /exc/override -> 429" "code=$code body=[$body]"
    fi
    # XH-12: 同 tag 后者胜
    code=$(http_code "$EB/exc/dup"); body=$(http_body "$EB/exc/dup")
    if [[ "$code" == "404" && "$body" == "second d" ]]; then
        pass "XH-12 /exc/dup -> 404 'second d' (同 tag 后者胜, P13-2)"
    else
        fail "XH-12 /exc/dup -> 404 last-wins" "code=$code body=[$body]"
    fi
    # XH-13: 无 tag 消息 + 正常路由
    code=$(http_code "$EB/exc/raise-plain"); body=$(http_body "$EB/exc/raise-plain")
    if [[ "$code" == "503" && "$body" == "server down plain message no colon" ]]; then
        pass "XH-13a /exc/raise-plain -> 503 (无 tag 消息落 catch-all)"
    else
        fail "XH-13a /exc/raise-plain -> 503" "code=$code body=[$body]"
    fi
    if [[ "$(http_code "$EB/health")" == "200" ]]; then
        pass "XH-13b /health 200 (有表但正常路由不受影响)"
    else
        fail "XH-13b /health 200 (exc server)" "code=$(http_code "$EB/health")"
    fi
else
    fail "XH-7..13 exception table server" "second server did not start; log: $(tail -3 "$EXC_LOG")"
fi
kill -TERM "$EXC_PID" 2>/dev/null
sleep 0.3
kill -9 "$EXC_PID" 2>/dev/null

# --- Request.state (决策-50, ADR-0025, Goal-0003 矩阵 #22) --------------------------

echo "== Request.state (每请求 scope 存储, 决策-50, ADR-0025) =="
# XS-1: _state_set 静态写 + _reads_state 读 (echo 回显 state_<name>)
S1=$(http_body "$BASE/state")
if [[ "$S1" == *'"state_user": "alice"'* && "$S1" == *'"state_dept": "eng"'* ]]; then
    pass "XS-1 /state set+read (state_user/state_dept)"
else fail "XS-1 /state set+read" "body: ${S1:0:200}"; fi
# XS-2: 值 {param} 插值 (ctx = 已注入参数)
S2=$(http_body "$BASE/state-dyn/bob")
if [[ "$S2" == *'"state_user": "bob"'* && "$S2" == *'"state_greeting": "hi bob"'* ]]; then
    pass "XS-2 /state-dyn/bob {who} 插值"
else fail "XS-2 /state-dyn/bob 插值" "body: ${S2:0:200}"; fi
# XS-3: 无 _state_set -> 两读皆空 (缺失键 -> "" F10 约定, ADR-0025 §3.5-1)
S3=$(http_body "$BASE/state-missing")
if [[ "$S3" == *'"state_user": ""'* && "$S3" == *'"state_ghost": ""'* ]]; then
    pass "XS-3 /state-missing -> 空串 (缺失键 -> \"\")"
else fail "XS-3 /state-missing 空串" "body: ${S3:0:200}"; fi
# XS-4: 跨请求隔离 (bob/alice 的写不泄漏进后续独立请求, P22-6)
curl -s -o /dev/null "$BASE/state-dyn/bob"
S4a=$(http_body "$BASE/state-missing")
curl -s -o /dev/null "$BASE/state-dyn/alice"
S4b=$(http_body "$BASE/state-missing")
if [[ "$S4a" == *'"state_user": ""'* && "$S4b" == *'"state_user": ""'* ]]; then
    pass "XS-4 跨请求隔离 (bob/alice 写后, 新请求 state 仍空)"
else fail "XS-4 跨请求隔离" "a=[${S4a:0:120}] b=[${S4b:0:120}]"; fi
# XS-5: /health 200 回归
if [[ "$(http_code "$BASE/health")" == "200" ]]; then
    pass "XS-5 /health 200 (回归)"
else fail "XS-5 /health 200" "code=$(http_code "$BASE/health")"; fi
# XS-6: /errors/99 404 (F2 回归)
if [[ "$(http_code "$BASE/errors/99")" == "404" ]]; then
    pass "XS-6 /errors/99 404 (F2 回归)"
else fail "XS-6 /errors/99 404" "code=$(http_code "$BASE/errors/99")"; fi
# XS-7: /exc/ve 500 (决策-49 回归: 无 handler 表 -> 默认 500)
if [[ "$(http_code "$BASE/exc/ve")" == "500" ]]; then
    pass "XS-7 /exc/ve 500 (决策-49 回归)"
else fail "XS-7 /exc/ve 500" "code=$(http_code "$BASE/exc/ve")"; fi

# --- WebSocket 精化 (ADR-0026, 决策-51) -------------------------------------------

echo "== websocket refinement (ADR-0026, close/exception/binary/json + close-wait) =="
# 主 server env: FASTAPI_MOJO_WS_CLOSE_WAIT=2000 (close-wait 2s; 1s poll
# tick 粒度 → 超时 close ∈ [2s, 3s); W1..W8 时序断言基于该值) +
# FASTAPI_MOJO_OPENAPI_{DESCRIPTION,TERMS,CONTACT,LICENSE,SERVERS,TAGS,
# EXTERNAL_DOCS} (决策-52 OP2 断言; TITLE/VERSION 保持默认).
WS5_OUT=$("$FMTOOL" ws5 "$PORT" 2>&1)
WS5_FAIL=$(echo "$WS5_OUT" | tail -1)
for m in W1 W2 W3 W4 W5 W6 W7 W8; do
    if echo "$WS5_OUT" | grep -q "$m"; then pass "WS $m"
    else fail "WS $m" "$WS5_FAIL"; fi
done
# server log: [ws-exc] 行 (W3 _ws_raise / W4 _ws_exc_close — 决策-49 同款日志面)
if [[ "$(cat "$TMP/server.log")" == *"[ws-exc] ws_exc_boom: kaboom"* ]]; then
    pass "WS W9 _ws_raise logged [ws-exc] in server log"
else fail "WS W9 [ws-exc] log" "no [ws-exc] ws_exc_boom line"; fi
if [[ "$(cat "$TMP/server.log")" == *"[ws-exc] ws_exc_close: 4002:ws-exc"* ]]; then
    pass "WS W10 _ws_exc_close logged [ws-exc] in server log"
else fail "WS W10 [ws-exc] log" "no [ws-exc] ws_exc_close line"; fi
# --- WebSocket permessage-deflate (ADR-0034, 决策-59) ----------------------------

echo "== websocket permessage-deflate (RFC 7692) =="
WSD_OUT=$("$FMTOOL" wsdeflate "$PORT" 2>&1)
WSD_FAIL=$(echo "$WSD_OUT" | tail -1)
for m in WSD1 WSD2 WSD3 WSD4; do
    if echo "$WSD_OUT" | grep -q "$m"; then pass "WS $m permessage-deflate"
    else fail "WS $m permessage-deflate" "$WSD_FAIL"; fi
done

WSD_PORT=$((PORT + 118))
WSD_DIR="$TMP/ws-deflate"
mkdir -p "$WSD_DIR"
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_WS_DEFLATE=0 \
    "$BIN" --port "$WSD_PORT" \
    > "$WSD_DIR/off.log" 2>&1 ) &
WSD_PID=$!
sleep 5
WSD_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$WSD_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        WSD_READY=1; break
    fi
    sleep 0.3
done
if [[ "$WSD_READY" == 1 ]]; then
    WSD5_OUT=$("$FMTOOL" wsdeflate-off "$WSD_PORT" 2>&1); WSD5_RC=$?
    if [[ "$WSD5_RC" -eq 0 ]] && echo "$WSD5_OUT" | grep -q WSD5; then
        pass "WS WSD5 off mode declines offered extension"
    else
        fail "WS WSD5 off mode declines offered extension" "rc=$WSD5_RC out=$WSD5_OUT"
    fi
else
    fail "WS WSD5 off mode declines offered extension" "sub-server not ready: $(cat "$WSD_DIR/off.log")"
fi
kill -TERM "$WSD_PID" 2>/dev/null || true
for _ in $(seq 1 10); do
    if ! kill -0 "$WSD_PID" 2>/dev/null; then break; fi
    sleep 0.3
done
kill -9 "$WSD_PID" 2>/dev/null || true
wait "$WSD_PID" 2>/dev/null || true

( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    FASTAPI_MOJO_WS_DEFLATE=required \
    "$BIN" --port "$WSD_PORT" \
    > "$WSD_DIR/required.log" 2>&1 ) &
WSD_PID=$!
sleep 5
WSD_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$WSD_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        WSD_READY=1; break
    fi
    sleep 0.3
done
if [[ "$WSD_READY" == 1 ]]; then
    WSD6_OUT=$("$FMTOOL" wsdeflate-required "$WSD_PORT" 2>&1); WSD6_RC=$?
    if [[ "$WSD6_RC" -eq 0 ]] && echo "$WSD6_OUT" | grep -q WSD6; then
        pass "WS WSD6 required mode rejects absent offer (400)"
    else
        fail "WS WSD6 required mode rejects absent offer (400)" "rc=$WSD6_RC out=$WSD6_OUT"
    fi
else
    fail "WS WSD6 required mode rejects absent offer (400)" "sub-server not ready: $(cat "$WSD_DIR/required.log")"
fi
kill -TERM "$WSD_PID" 2>/dev/null || true
for _ in $(seq 1 10); do
    if ! kill -0 "$WSD_PID" 2>/dev/null; then break; fi
    sleep 0.3
done
kill -9 "$WSD_PID" 2>/dev/null || true
wait "$WSD_PID" 2>/dev/null || true

# --- WebSocket application subprotocols (ADR-0035, decision-60) -------------------

echo "== websocket application subprotocols (jsonrpc / graphql-ws / grpc-web) =="
WSP_OUT=$("$FMTOOL" wsmatrix "$PORT" 2>&1)
WSP_FAIL=$(echo "$WSP_OUT" | tail -1)
for m in WSP1 WSP2 WSP3 WSP4 WSP5 WSP6 WSP7 WSP8; do
    if echo "$WSP_OUT" | grep -q "$m"; then pass "WS $m application subprotocol"
    else fail "WS $m application subprotocol" "$WSP_FAIL"; fi
done

# --- OpenAPI refinement (ADR-0027, decision-52) ----------------------------------

echo "== openapi refinement (ADR-0027: info/servers/tags/externalDocs + op-level custom) =="
# Subserver (no OPENAPI envs) for default-shape checks; main server carries the
# 7 OPENAPI envs above (TITLE/VERSION intentionally unset -> defaults).
OA_PORT=$((PORT + 112))
OA_DIR="$TMP/openapi"
mkdir -p "$OA_DIR"
( cd "$SRC" && exec env FASTAPI_MOJO_STATIC_DIR="$SRC/static" \
    "$BIN" --port "$OA_PORT" \
    > "$OA_DIR/server.log" 2>&1 ) &
OA_PID=$!
sleep 5
OA_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$OA_PORT/health" 2>/dev/null)" == *healthy* ]]; then
        OA_READY=1; break
    fi
    sleep 0.3
done
if [[ "$OA_READY" != 1 ]]; then
    fail "OA subserver ready" "second server did not start; log: $(tail -3 "$OA_DIR/server.log")"
fi
OA_BASE="http://127.0.0.1:$OA_PORT"

# OP2-1 (subserver, defaults): minimal info + no servers key (info 直连 paths)
OA1=$(http_body "$OA_BASE/openapi.json")
if [[ "$OA1" == *'"info":{"title":"fastapi_mojo API","version":"1.8.0"},"paths"'* ]]; then
    pass "OP2-1 subserver minimal info (title/version only, no servers)"
else fail "OP2-1 subserver minimal info" "got: ${OA1:0:200}"; fi

# OP2-2 (main): full info exact (键序 + terms 无 quirk + contact/license url quirk)
OA2=$(http_body "$BASE/openapi.json")
if [[ "$OA2" == *'"info":{"title":"fastapi_mojo API","description":"e2e description","termsOfService":"https://tos.example","contact":{"name":"E2E Support","url":"https://support.example/","email":"s@example.com"},"license":{"name":"MIT","url":"https://opensource.org/licenses/MIT"},"version":"1.8.0"}'* ]]; then
    pass "OP2-2 full info (key order + AnyUrl quirk on contact/license)"
else fail "OP2-2 full info" "got: ${OA2:0:260}"; fi

# OP2-3 (main): servers between info and paths
if [[ "$OA2" == *'"servers":[{"url":"https://api.example/v1","description":"Prod"}],"paths"'* ]]; then
    pass "OP2-3 servers array (url:desc split, position before paths)"
else fail "OP2-3 servers array" "got: ${OA2:0:260}"; fi

# OP2-4 (main): root tags (after components) + externalDocs last (desc-first)
if [[ "$OA2" == *',"tags":[{"name":"items","description":"Item ops"},{"name":"users","description":"User mgmt"}],"externalDocs":{"description":"Ext docs","url":"https://docs.example/guide"}}'* ]]; then
    pass "OP2-4 root tags + externalDocs (desc before url, doc terminator)"
else fail "OP2-4 root tags + externalDocs" "got: ${OA2: -300}"; fi

# OP2-5 (main): /meta/probe operation exact (all op-level keys)
if [[ "$OA2" == *'"tags":["probe","custom"],"summary":"Probe Sum","description":"Probe desc","operationId":"probe_op","responses":{"200":{"description":"probe ok","content":{"application/json":{"schema":{"type":"object"}}}},"418":{"description":"Teapot custom"}},"deprecated":true'* ]]; then
    pass "OP2-5 /meta/probe operation exact (tags/summary/desc/opid/responses/deprecated)"
else fail "OP2-5 /meta/probe operation exact" "got: ${OA2:0:400}"; fi

# OP2-6 (main): /meta/hidden served but absent from spec
if [[ "$(http_code "$BASE/meta/hidden")" == "200" ]] && [[ "$(grep -c '"meta/hidden"' <(curl -sS -m 5 "$BASE/openapi.json"))" == "0" ]]; then
    pass "OP2-6 /meta/hidden served 200 + absent from spec (include_in_schema=0)"
else fail "OP2-6 /meta/hidden" "code=$(http_code "$BASE/meta/hidden")"; fi

# OP2-7 (main): /meta/made wire 201 + spec primary key 201
if [[ "$(http_code "$BASE/meta/made")" == "201" ]] && [[ "$OA2" == *'"201":{"description":"Successful Response"'* ]]; then
    pass "OP2-7 /meta/made wire 201 + spec 201 key (Successful Response)"
else fail "OP2-7 /meta/made" "code=$(http_code "$BASE/meta/made")"; fi

# OP2-8 (main): default operationId formula + summary title-case (P24-5/6)
if [[ "$OA2" == *'"operationId":"health_health_get"'* ]] && [[ "$OA2" == *'"summary":"Health"'* ]]; then
    pass "OP2-8 /health defaults (operationId formula + summary title-case)"
else fail "OP2-8 /health defaults" "got: ${OA2:0:300}"; fi

# OP2-9 (main): 200 default description parity ("Successful Response")
if [[ "$OA2" == *'"description":"Successful Response"'* ]]; then
    pass "OP2-9 200 default description = Successful Response"
else fail "OP2-9 200 default description" "not found in spec"; fi

# OP2-10: full doc valid JSON (fmtool jsoncheck) — main + subserver
curl -sS -m 5 "$BASE/openapi.json" > "$TMP/oa_main.json"
curl -sS -m 5 "$OA_BASE/openapi.json" > "$TMP/oa_sub.json"
if "$FMTOOL" jsoncheck "$TMP/oa_main.json" >/dev/null && "$FMTOOL" jsoncheck "$TMP/oa_sub.json" >/dev/null; then
    pass "OP2-10 /openapi.json full doc valid JSON (main + subserver)"
else fail "OP2-10 openapi jsoncheck" "$(head -c 200 "$TMP/oa_main.json")"; fi

# OP2-11 (main): /docs 200 + title (default; TITLE env unset)
if [[ "$(http_code "$BASE/docs")" == "200" ]] && curl -sS -m 5 "$BASE/docs" | grep -q "fastapi_mojo API - Swagger UI"; then
    pass "OP2-11 /docs 200 + title intact"
else fail "OP2-11 /docs" "code=$(http_code "$BASE/docs")"; fi

# OP2-12 (main): /health 200 regression
expect_code "OP2-12 /health 200 regression" "200" "$BASE/health"

# teardown subserver
kill -TERM "$OA_PID" 2>/dev/null
for _ in $(seq 1 20); do
    if ! kill -0 "$OA_PID" 2>/dev/null; then break; fi
    sleep 0.3
done
kill -9 "$OA_PID" 2>/dev/null
sleep 0.2

# --- 决策-53 (ADR-0028): Header alias + 下划线→连字符转换 (矩阵 #7) -----------------
# _reads_headers 条目: "name" (wire = _→- 转换) / "name=alias" (wire = alias 原样);
# 读取走 bridge get_header_value_ci (ASCII CI + 多值取首, FFI diff = 0).

# OP3-1: alias wire 大小写不敏感 (小写 token-literal 命中 → header_x_token)
B=$(curl -s --max-time 10 -H "token-literal: A" "$BASE/hdr/alias")
if [[ "$B" == *'"header_x_token": "A"'* ]]; then pass "OP3-1 alias CI match (token-literal → x_token=A)"
else fail "OP3-1 alias CI match" "got: ${B:0:120}"; fi

# OP3-2: alias 原始拼写 (Token-Literal 原样 → B)
B=$(curl -s --max-time 10 -H "Token-Literal: B" "$BASE/hdr/alias")
if [[ "$B" == *'"header_x_token": "B"'* ]]; then pass "OP3-2 alias exact case (Token-Literal → x_token=B)"
else fail "OP3-2 alias exact case" "got: ${B:0:120}"; fi

# OP3-3: 下划线字面头不绑 alias 参数 (P25-1: x_token: C → 空)
B=$(curl -s --max-time 10 -H "x_token: C" "$BASE/hdr/alias")
if [[ "$B" == *'"header_x_token": ""'* && "$B" == *'"header_client_id": ""'* ]]; then
    pass "OP3-3 underscore literal does not bind aliased param (x_token → empty)"
else fail "OP3-3 underscore literal" "got: ${B:0:120}"; fi

# OP3-4: 默认 _→- 转换 (client-id → header_client_id, P25-1)
B=$(curl -s --max-time 10 -H "client-id: D" "$BASE/hdr/alias")
if [[ "$B" == *'"header_client_id": "D"'* ]]; then pass "OP3-4 default _→- conversion (client-id → client_id=D)"
else fail "OP3-4 default _→-" "got: ${B:0:120}"; fi

# OP3-5: 下划线字面头不读普通参数 (client_id: E → 空)
B=$(curl -s --max-time 10 -H "client_id: E" "$BASE/hdr/alias")
if [[ "$B" == *'"header_client_id": ""'* ]]; then pass "OP3-5 underscore literal does not bind plain param (client_id → empty)"
else fail "OP3-5 underscore literal plain" "got: ${B:0:120}"; fi

# OP3-6: /ctx 回归 (无下划线名行为零变化: X-Custom/User-Agent)
B=$(curl -s --max-time 10 -H "X-Custom: x" -H "User-Agent: ua" "$BASE/ctx")
if [[ "$B" == *'"header_X-Custom": "x"'* && "$B" == *'"header_User-Agent": "ua"'* ]]; then
    pass "OP3-6 /ctx regression (no-underscore names unchanged)"
else fail "OP3-6 /ctx regression" "got: ${B:0:120}"; fi

# OP3-7: OpenAPI header 参数名 = wire 名 (alias 原样 Token-Literal + 转换 client-id)
curl -sS -m 5 "$BASE/openapi.json" > "$TMP/oa53.json"
if grep -q '"name":"Token-Literal","in":"header"' "$TMP/oa53.json" \
   && grep -q '"name":"client-id","in":"header"' "$TMP/oa53.json"; then
    pass "OP3-7 openapi header name = wire name (Token-Literal / client-id)"
else fail "OP3-7 openapi header names" "$(head -c 200 "$TMP/oa53.json")"; fi

# OP3-8: 多值头取第一个 (M1/M2 → M1, P25-5)
B=$(curl -s --max-time 10 -H "client-id: M1" -H "client-id: M2" "$BASE/hdr/alias")
if [[ "$B" == *'"header_client_id": "M1"'* ]]; then pass "OP3-8 multi-value first wins (M1)"
else fail "OP3-8 multi-value" "got: ${B:0:120}"; fi


# ============================================================================
# CP: 决策-54 (ADR-0029) 参数约束面 — path/query/header 约束 + typed header
# (矩阵 #2: {param} + 类型 + 约束; e2e 24 checks)
# ============================================================================

# CP-1: /con/path/2 → gt=3 违反 (n:int + gt=3,le=10)
B=$(curl -s --max-time 10 "$BASE/con/path/2")
if [[ "$B" == *'"loc":["path","n"],"msg":"Input should be greater than 3","type":"greater_than","input":"2","ctx":{"gt":3}'* ]]; then pass "CP-1 path gt violation (422 exact object + ctx)"
else fail "CP-1 path gt" "got: ${B:0:200}"; fi

# CP-2: /con/path/11 → le=10 违反
B=$(curl -s --max-time 10 "$BASE/con/path/11")
if [[ "$B" == *'"msg":"Input should be less than or equal to 10","type":"less_than_equal","input":"11","ctx":{"le":10}'* ]]; then pass "CP-2 path le violation"
else fail "CP-2 path le" "got: ${B:0:200}"; fi

# CP-3: /con/path/5 → 区间内 200
B=$(curl -s --max-time 10 "$BASE/con/path/5")
if [[ "$B" == *'"n": "5"'* ]]; then pass "CP-3 path in-range 200 (echo n=5)"
else fail "CP-3 path in-range" "got: ${B:0:120}"; fi

# CP-4: /con/str/a → min_length=2 违反 (隐式 str)
B=$(curl -s --max-time 10 "$BASE/con/str/a")
if [[ "$B" == *'"loc":["path","s"],"msg":"String should have at least 2 characters","type":"string_too_short","input":"a","ctx":{"min_length":2}'* ]]; then pass "CP-4 implicit str min_length"
else fail "CP-4 str min_length" "got: ${B:0:200}"; fi

# CP-5: /con/str/ABCDE → max_length=4 优先于 pattern
B=$(curl -s --max-time 10 "$BASE/con/str/ABCDE")
if [[ "$B" == *'"msg":"String should have at most 4 characters","type":"string_too_long","input":"ABCDE","ctx":{"max_length":4}'* ]]; then pass "CP-5 str max_length priority over pattern"
else fail "CP-5 str max_length" "got: ${B:0:200}"; fi

# CP-6: /con/str/Ab3 → pattern 违反 (len 通过)
B=$(curl -s --max-time 10 "$BASE/con/str/Ab3")
if [[ "$B" == *'"type":"string_pattern_mismatch"'* && "$B" == *'"input":"Ab3"'* && "$B" == *'"pattern":"^[a-z]+$"'* ]]; then pass "CP-6 str pattern mismatch"
else fail "CP-6 str pattern" "got: ${B:0:200}"; fi

# CP-7: /con/str/ab → len+pattern 全过 200
B=$(curl -s --max-time 10 "$BASE/con/str/ab")
if [[ "$B" == *'"s": "ab"'* ]]; then pass "CP-7 str in-range 200"
else fail "CP-7 str ok" "got: ${B:0:120}"; fi

# CP-8: /con/query?r=ab → q 缺席默认 5 (ge=0,lt=100 过) + r=ab 过 → 200.
# 200 body 的 query 回显 = query_ 前缀 (dispatch 约定); 默认经
# apply_query_extras 注入 query.values 后进入回显.
B=$(curl -s --max-time 10 "$BASE/con/query?r=ab")
if [[ "$B" == *'"query_q": "5"'* && "$B" == *'"query_r": "ab"'* ]]; then pass "CP-8 query default 5 injected + r ok (200)"
else fail "CP-8 query default" "got: ${B:0:160}"; fi

# CP-9: /con/query?q=200 → lt=100 违反 (input = 在场 raw 串)
B=$(curl -s --max-time 10 "$BASE/con/query?q=200")
if [[ "$B" == *'"loc":["query","q"],"msg":"Input should be less than 100","type":"less_than","input":"200","ctx":{"lt":100}'* ]]; then pass "CP-9 query lt violation (input raw string)"
else fail "CP-9 query lt" "got: ${B:0:200}"; fi

# CP-10: /con/query?r=abcd → 隐式 str max_length (loc = query)
B=$(curl -s --max-time 10 "$BASE/con/query?r=abcd")
if [[ "$B" == *'"loc":["query","r"],"msg":"String should have at most 3 characters","type":"string_too_long","input":"abcd","ctx":{"max_length":3}'* ]]; then pass "CP-10 implicit query str violation"
else fail "CP-10 implicit query" "got: ${B:0:200}"; fi

# CP-11: /con/query?q=200&r=abcd → 两种类型同 detail 数组 (collect-all)
B=$(curl -s --max-time 10 "$BASE/con/query?q=200&r=abcd")
if [[ "$B" == *'"type":"less_than"'* && "$B" == *'"type":"string_too_long"'* ]]; then pass "CP-11 collect-all (typed + implicit in one array)"
else fail "CP-11 collect-all" "got: ${B:0:200}"; fi

# CP-12: /con/hdr 裸请求 → x-token 缺失 422 (input null; x-app 有默认无错)
B=$(curl -s --max-time 10 "$BASE/con/hdr")
if [[ "$B" == *'"loc":["header","x-token"],"msg":"Field required","type":"missing","input":null'* ]]; then pass "CP-12 required header missing (input null)"
else fail "CP-12 header missing" "got: ${B:0:200}"; fi

# CP-13: /con/hdr x-token:abc → int_parsing 完整消息
B=$(curl -s --max-time 10 -H "x-token: abc" "$BASE/con/hdr")
if [[ "$B" == *'"msg":"Input should be a valid integer, unable to parse string as an integer","type":"int_parsing","input":"abc"'* ]]; then pass "CP-13 header int parse error (full msg)"
else fail "CP-13 header int parse" "got: ${B:0:200}"; fi

# CP-14: /con/hdr x-app:xyz → bool_parsing 完整消息 (矩阵 #3 偏差销账)
B=$(curl -s --max-time 10 -H "x-app: xyz" "$BASE/con/hdr")
if [[ "$B" == *'"msg":"Input should be a valid boolean, unable to interpret input","type":"bool_parsing","input":"xyz"'* ]]; then pass "CP-14 header bool parse error (full upstream msg)"
else fail "CP-14 header bool parse" "got: ${B:0:200}"; fi

# CP-15: /con/hdr x-token:5 → 200 (bool 默认 true 注入)
B=$(curl -s --max-time 10 -H "x-token: 5" "$BASE/con/hdr")
if [[ "$B" == *'"header_x_token": "5"'* && "$B" == *'"header_x-app": "true"'* ]]; then pass "CP-15 header present ok + default inject (200)"
else fail "CP-15 header ok" "got: ${B:0:120}"; fi

# CP-16: /con/hdr2 裸请求 → 双默认 (x-ver=1 过 ge/le/mo; tag=ab 过 len/pat) 200
B=$(curl -s --max-time 10 "$BASE/con/hdr2")
if [[ "$B" == *'"header_x-ver": "1"'* && "$B" == *'"header_tag": "ab"'* ]]; then pass "CP-16 header defaults pass constraints (200)"
else fail "CP-16 header defaults" "got: ${B:0:120}"; fi

# CP-17: /con/hdr2 X-Ver:5 → le=3 违反 (loc = wire alias 原样)
B=$(curl -s --max-time 10 -H "X-Ver: 5" "$BASE/con/hdr2")
if [[ "$B" == *'"loc":["header","X-Ver"],"msg":"Input should be less than or equal to 3","type":"less_than_equal","input":"5","ctx":{"le":3}'* ]]; then pass "CP-17 alias header constraint violation"
else fail "CP-17 alias header" "got: ${B:0:200}"; fi

# CP-18: /con/hdr2 tag:a3b → max_length=2 违反
B=$(curl -s --max-time 10 -H "tag: a3b" "$BASE/con/hdr2")
if [[ "$B" == *'"loc":["header","tag"],"msg":"String should have at most 2 characters","type":"string_too_long","input":"a3b","ctx":{"max_length":2}'* ]]; then pass "CP-18 header str max_length"
else fail "CP-18 header str len" "got: ${B:0:200}"; fi

# CP-19: /con/hdr2 tag:AB → pattern 违反 (len 过)
B=$(curl -s --max-time 10 -H "tag: AB" "$BASE/con/hdr2")
if [[ "$B" == *'"type":"string_pattern_mismatch"'* && "$B" == *'"input":"AB"'* && "$B" == *'"pattern":"^[0-9a-z]+$"'* ]]; then pass "CP-19 header str pattern mismatch"
else fail "CP-19 header str pat" "got: ${B:0:200}"; fi

# CP-20: /con/all/1?q=200 → 三错群序 path→query→header; header = 缺失+默认违反
#        (input = 类型化字面量裸数字 2, P26-b-8)
B=$(curl -s --max-time 10 "$BASE/con/all/1?q=200")
O1=$(grep -bo '"msg":"Input should be greater than 3"' <<<"$B" | cut -d: -f1)
O2=$(grep -bo '"msg":"Input should be less than 100"' <<<"$B" | cut -d: -f1)
O3=$(grep -bo '"msg":"Input should be greater than or equal to 5"' <<<"$B" | cut -d: -f1)
if [[ -n "$O1" && -n "$O2" && -n "$O3" ]] && (( O1 < O2 && O2 < O3 )); then pass "CP-20a collect-all group order path→query→header"
else fail "CP-20a group order" "offsets: ${O1:-?} ${O2:-?} ${O3:-?}; body: ${B:0:200}"; fi
if [[ "$B" == *'"loc":["header","x-h"],"msg":"Input should be greater than or equal to 5","type":"greater_than_equal","input":2,"ctx":{"ge":5}'* ]]; then pass "CP-20b default violation input = typed literal (unquoted 2)"
else fail "CP-20b default input typed" "got: ${B:0:240}"; fi

# CP-21: OpenAPI /con/path — gt→3.0 exclusiveMinimum bool + le→maximum
curl -sS -m 5 "$BASE/openapi.json" > "$TMP/oa54a.json"
if grep -qF '"name":"n","in":"path","required":true,"schema":{"type":"integer","minimum":3,"exclusiveMinimum":true,"maximum":10}' "$TMP/oa54a.json"; then pass "CP-21 openapi path int constraints (exclusiveMinimum bool)"
else fail "CP-21 openapi path" "$(head -c 200 "$TMP/oa54a.json")"; fi

# CP-22: OpenAPI /con/hdr2 — typed header schema (mo/min/max + default; len/pat)
if grep -qF '"name":"X-Ver","in":"header","required":false,"schema":{"type":"integer","multipleOf":1,"minimum":1,"maximum":3,"default":1}' "$TMP/oa54a.json" \
   && grep -qF '"name":"tag","in":"header","required":false,"schema":{"type":"string","minLength":1,"maxLength":2,"pattern":"^[0-9a-z]+$","default":"ab"}' "$TMP/oa54a.json"; then
    pass "CP-22 openapi typed header schemas (numeric + string constraints)"
else fail "CP-22 openapi headers" "$(head -c 200 "$TMP/oa54a.json")"; fi

# CP-23: OpenAPI /con/str — 隐式 str schema 恒带 type 键 (偏差 ⑥) + len/pat
if grep -qF '"name":"s","in":"path","required":true,"schema":{"type":"string","minLength":2,"maxLength":4,"pattern":"^[a-z]+$"}' "$TMP/oa54a.json"; then pass "CP-23 openapi implicit str schema (type key always present)"
else fail "CP-23 openapi implicit str" "$(head -c 200 "$TMP/oa54a.json")"; fi

# CP-24: /typed?count=abc 回归 — int_parsing 完整消息 (决策-54 bool 改动后)
B=$(curl -s --max-time 10 "$BASE/typed?count=abc&verbose=true")
if [[ "$B" == *'"loc":["query","count"],"msg":"Input should be a valid integer, unable to parse string as an integer","type":"int_parsing","input":"abc"'* ]]; then pass "CP-24 /typed int_parsing full msg regression"
else fail "CP-24 /typed regression" "got: ${B:0:200}"; fi


# --- User middleware (决策-55, ADR-0030, Goal-0003 矩阵 #14) ---------------------
# 声明式 env FASTAPI_MOJO_MIDDLEWARE (Mojo 1.0.0 无闭包, @app.middleware("http") 等价;
# GZip 决策-40 / CORS 决策-42 / 异常 handler 决策-49 先例). 栈序 mw1=innermost...mwN=outermost:
#   请求面 (MAP/REQHDR/BLOCK) Mojo dispatch outermost→innermost, 路由前;
#   响应面 (HDR/STATUS/BODY/LOG) bridge send_response innermost→outermost (env 正序), GZip 前;
#   短路 (BLOCK 于 mwK): 响应仅过 index>k 外层响应动词 (bridge plan_request_path 重推导).
# 零 python3 (Track B 决策-22): curl -D/-o + grep/tr. 4 副 server (各自 env) + 主 server 零回归.
echo "== User middleware (决策-55, ADR-0030) =="

# --- Server A: 请求面 (MAP/REQHDR) + 响应面 (HDR/LOG) --------------------------
#   mw1 (innermost) = HDR:X-Mw:1,LOG (响应); mw2 (outermost) = MAP:/mw/map-old:/mw/map-new,REQHDR:X-Mw-Inj:injected (请求).
MW_PORT=$((PORT + 113))
MW_LOG="$TMP/mw_a.log"
( cd "$SRC" && exec env FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_MIDDLEWARE="HDR:X-Mw:1,LOG;MAP:/mw/map-old:/mw/map-new,REQHDR:X-Mw-Inj:injected" \
    "$BIN" --port "$MW_PORT" > "$MW_LOG" 2>&1 ) &
MW_PID=$!
sleep 5
MW_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$MW_PORT/health" 2>/dev/null)" == *healthy* ]]; then MW_READY=1; break; fi
    sleep 0.3
done
if [[ "$MW_READY" == 1 ]]; then
    MW_BASE="http://127.0.0.1:$MW_PORT"
    # MW-1: HDR 动词 — /health 响应头带 X-Mw: 1
    if curl -s -D - -o /dev/null "$MW_BASE/health" | tr -d '\r' | grep -qi '^X-Mw: *1'; then
        pass "MW-1 HDR: /health has X-Mw: 1"
    else
        fail "MW-1 HDR: /health has X-Mw: 1"
    fi
    # MW-2: REQHDR 合成请求头 — /mw/reqhdr _reads_headers 回显 header_X-Mw-Inj: injected
    B=$(curl -s --max-time 10 "$MW_BASE/mw/reqhdr")
    if printf '%s' "$B" | grep -qE '"header_X-Mw-Inj":? *"injected"'; then
        pass "MW-2 REQHDR: /mw/reqhdr echoes header_X-Mw-Inj: injected"
    else
        fail "MW-2 REQHDR: /mw/reqhdr echoes header_X-Mw-Inj: injected" "got: ${B:0:200}"
    fi
    # MW-3: MAP 路径重写 — /mw/map-old → /mw/map-new (message + path 均 post-MAP)
    B=$(curl -s --max-time 10 "$MW_BASE/mw/map-old")
    if printf '%s' "$B" | grep -q '"message": "mapped here"' && printf '%s' "$B" | grep -qE '"path": *"/mw/map-new"'; then
        pass "MW-3 MAP: /mw/map-old → mapped here + path=/mw/map-new"
    else
        fail "MW-3 MAP: /mw/map-old → mapped here + path=/mw/map-new" "got: ${B:0:200}"
    fi
    # MW-4: LOG 动词 — [mw] 行 (原始 path, 无 query → 无 ?) 落 server stdout
    if grep -aqE '^\[mw\] req-[0-9]+ GET /health -> 200 OK' "$MW_LOG"; then
        pass "MW-4 LOG: [mw] line for GET /health"
    else
        fail "MW-4 LOG: [mw] line for GET /health" "see $MW_LOG"
    fi
else
    fail "MW-A side server did not start" "see $MW_LOG"
fi
kill -TERM "$MW_PID" 2>/dev/null
sleep 0.3
kill -9 "$MW_PID" 2>/dev/null

# --- Server B: 响应面 (STATUS + BODY, 含重算 Content-Length) ------------------
#   mw1 = STATUS:200:201,BODY:GOT {method} {path} {status} {req_id}
#   响应体被替换 → /health 不再是 healthy JSON (readiness 须查 GOT).
MW2_PORT=$((PORT + 114))
MW2_LOG="$TMP/mw_b.log"
( cd "$SRC" && exec env FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_MIDDLEWARE="STATUS:200:201,BODY:GOT {method} {path} {status} {req_id}" \
    "$BIN" --port "$MW2_PORT" > "$MW2_LOG" 2>&1 ) &
MW2_PID=$!
sleep 5
MW2_READY=0
for _ in $(seq 1 30); do
    if curl -s --max-time 1 "http://127.0.0.1:$MW2_PORT/health" 2>/dev/null | grep -q GOT; then MW2_READY=1; break; fi
    sleep 0.3
done
if [[ "$MW2_READY" == 1 ]]; then
    MW2_BASE="http://127.0.0.1:$MW2_PORT"
    # MW-5: STATUS 动词 — 200 → 201
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$MW2_BASE/health")
    if [[ "$code" == "201" ]]; then
        pass "MW-5 STATUS: /health 200 → 201"
    else
        fail "MW-5 STATUS: /health 200 → 201" "code=$code"
    fi
    # MW-6: BODY 动词 — 替换 body (插值 {method}{path}{status}{req_id}) + CT → text/plain
    B=$(curl -s --max-time 10 "$MW2_BASE/health")
    if [[ "$B" == "GOT GET /health 201 req-"* ]] && curl -s -D - -o /dev/null "$MW2_BASE/health" | tr -d '\r' | grep -qi '^content-type: *text/plain'; then
        pass "MW-6 BODY: /health → 'GOT GET /health 201 req-*' + text/plain"
    else
        fail "MW-6 BODY: /health → 'GOT GET /health 201 req-*' + text/plain" "got: ${B:0:200}"
    fi
else
    fail "MW-B side server did not start" "see $MW2_LOG"
fi
kill -TERM "$MW2_PID" 2>/dev/null
sleep 0.3
kill -9 "$MW2_PID" 2>/dev/null

# --- Server C: HDR 同名原位替换 (后写胜, 外层赢) -------------------------------
#   mw1 = HDR:X-Same:inner (innermost); mw2 = HDR:X-Same:outer (outermost) → 单行 X-Same: outer
MW3_PORT=$((PORT + 115))
MW3_LOG="$TMP/mw_c.log"
( cd "$SRC" && exec env FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_MIDDLEWARE="HDR:X-Same:inner;HDR:X-Same:outer" \
    "$BIN" --port "$MW3_PORT" > "$MW3_LOG" 2>&1 ) &
MW3_PID=$!
sleep 5
MW3_READY=0
for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 1 "http://127.0.0.1:$MW3_PORT/health" 2>/dev/null)" == *healthy* ]]; then MW3_READY=1; break; fi
    sleep 0.3
done
if [[ "$MW3_READY" == 1 ]]; then
    MW3_BASE="http://127.0.0.1:$MW3_PORT"
    # MW-7: 两个同名 HDR (inner/outer) → 仅 1 行, 值 = outer (后写胜)
    curl -s -D "$TMP/mw3_hdr" -o /dev/null "$MW3_BASE/health"
    tr -d '\r' < "$TMP/mw3_hdr" > "$TMP/mw3_hdr_c"
    n_same=$(grep -ci '^X-Same:' "$TMP/mw3_hdr_c")
    val=$(grep -i '^X-Same:' "$TMP/mw3_hdr_c" | head -1)
    if [[ "$n_same" == "1" ]] && [[ "$val" == "X-Same: outer" ]]; then
        pass "MW-7 same-name HDR: single line, outer wins"
    else
        fail "MW-7 same-name HDR: single line, outer wins" "n=$n_same val=$val"
    fi
else
    fail "MW-C side server did not start" "see $MW3_LOG"
fi
kill -TERM "$MW3_PID" 2>/dev/null
sleep 0.3
kill -9 "$MW3_PID" 2>/dev/null

# --- Server D: BLOCK 短路 (早期响应, 响应仅过外层) ----------------------------
#   mw1 (innermost) = HDR:X-Inner:1 (响应);
#   mw2 = BLOCK:418:early-blocked:* (请求) + HDR:X-Mid:1 (响应);
#   mw3 (outermost) = HDR:X-Outer:1 (响应).
#   blocker = mw2 (index 1) → 仅 index>1 (mw3) 响应动词应用 → X-Outer 仅此.
MW4_PORT=$((PORT + 116))
MW4_LOG="$TMP/mw_d.log"
( cd "$SRC" && exec env FASTAPI_MOJO_RECV_TIMEOUT=2 FASTAPI_MOJO_IDLE_TIMEOUT=2 \
    FASTAPI_MOJO_MIDDLEWARE="HDR:X-Inner:1;BLOCK:418:early-blocked:*,HDR:X-Mid:1;HDR:X-Outer:1" \
    "$BIN" --port "$MW4_PORT" > "$MW4_LOG" 2>&1 ) &
MW4_PID=$!
sleep 5
MW4_READY=0
for _ in $(seq 1 30); do
    if curl -s --max-time 1 "http://127.0.0.1:$MW4_PORT/health" 2>/dev/null | grep -q early-blocked; then MW4_READY=1; break; fi
    sleep 0.3
done
if [[ "$MW4_READY" == 1 ]]; then
    MW4_BASE="http://127.0.0.1:$MW4_PORT"
    # MW-8: BLOCK 短路 — 418 + body 'early-blocked' + X-Outer 在 / X-Mid,X-Inner 无
    curl -s -D "$TMP/mw4_hdr" -o "$TMP/mw4_body" "$MW4_BASE/health"
    tr -d '\r' < "$TMP/mw4_hdr" > "$TMP/mw4_hdr_c"
    code=$(head -1 "$TMP/mw4_hdr_c" | awk '{print $2}')
    bdy=$(cat "$TMP/mw4_body")
    if [[ "$code" == "418" ]] && [[ "$bdy" == "early-blocked" ]] \
        && grep -qi '^X-Outer: *1' "$TMP/mw4_hdr_c" \
        && ! grep -qi '^X-Mid:' "$TMP/mw4_hdr_c" \
        && ! grep -qi '^X-Inner:' "$TMP/mw4_hdr_c"; then
        pass "MW-8 BLOCK short-circuit: 418 + body + only X-Outer"
    else
        fail "MW-8 BLOCK short-circuit: 418 + body + only X-Outer" "code=$code bdy=$bdy"
    fi
    # MW-9: BLOCK 早期响应 CT = text/plain (路由被跳过, 非 JSON)
    if grep -qi '^content-type: *text/plain' "$TMP/mw4_hdr_c"; then
        pass "MW-9 BLOCK: content-type text/plain"
    else
        fail "MW-9 BLOCK: content-type text/plain"
    fi
else
    fail "MW-D side server did not start" "see $MW4_LOG"
fi
kill -TERM "$MW4_PID" 2>/dev/null
sleep 0.3
kill -9 "$MW4_PID" 2>/dev/null

# --- MW-10: 主 server 无 FASTAPI_MOJO_MIDDLEWARE → 零行为变更 (零回归) ---------
if ! curl -s -D - -o /dev/null "$BASE/health" | tr -d '\r' | grep -qi '^X-Mw:'; then
    pass "MW-10 no env: main server zero change (no X-Mw)"
else
    fail "MW-10 no env: main server zero change (no X-Mw)" "unexpected X-Mw header"
fi

# --- TC: 声明式 TestClient 等价 (决策-56, ADR-0031) ----------------------------------------
# fmtool testclient http/ws/run — Starlette TestClient 的声明式替代 (dev 工具, 不进 runtime).
# http: GET/POST + JSON/form + header/param/cookie/jar + 重定向; ws: RFC6455 握手 + 动作脚本
#       (JSONL 事件); run: 服务器生命周期 (spawn → readiness → actions → SIGTERM → exit 0).
TC_WS="ws://127.0.0.1:$PORT"

# TC-1: http GET /health --json-out → 200 + healthy
TC1_OUT=$("$FMTOOL" testclient http GET "$BASE/health" --json-out 2>&1); TC1_RC=$?
if [[ $TC1_RC -eq 0 ]] && echo "$TC1_OUT" | grep -q '"status_code":200' && echo "$TC1_OUT" | grep -q 'healthy'; then
    pass "TC-1 testclient http /health json-out (200 + healthy)"
else
    fail "TC-1 testclient http /health json-out" "rc=$TC1_RC out=$TC1_OUT"
fi

# TC-2: http POST /items --json → body 回显解析后的 JSON 字段 (KIND_ECHO)
TC2_OUT=$("$FMTOOL" testclient http POST "$BASE/items" --json '{"name":"tc","n":5}' --json-out 2>&1); TC2_RC=$?
if [[ $TC2_RC -eq 0 ]] && echo "$TC2_OUT" | grep -q '"status_code":200' && echo "$TC2_OUT" | grep -q 'item_name'; then
    pass "TC-2 testclient http POST /items --json (echo item_name)"
else
    fail "TC-2 testclient http POST /items --json" "rc=$TC2_RC out=$TC2_OUT"
fi

# TC-3: http GET /cookies --cookie session_id=abc → body 回显 abc
TC3_OUT=$("$FMTOOL" testclient http GET "$BASE/cookies" --cookie session_id=abc --json-out 2>&1); TC3_RC=$?
if [[ $TC3_RC -eq 0 ]] && echo "$TC3_OUT" | grep -q 'cookie_session_id' && echo "$TC3_OUT" | grep -q 'abc'; then
    pass "TC-3 testclient http --cookie (session_id echo)"
else
    fail "TC-3 testclient http --cookie" "rc=$TC3_RC out=$TC3_OUT"
fi

# TC-4: --cookie-jar 捕获 + 回放 (Set-Cookie: tc=jar1 → jar 文件 → 二次回显)
"$FMTOOL" testclient http GET "$BASE/tc/jar" --cookie-jar "$TMP/tc_jar.txt" >/dev/null 2>&1
TC4A_RC=$?
TC4_OUT=$("$FMTOOL" testclient http GET "$BASE/tc/jar" --cookie-jar "$TMP/tc_jar.txt" --json-out 2>&1); TC4_RC=$?
if [[ $TC4A_RC -eq 0 ]] && grep -q 'tc=jar1' "$TMP/tc_jar.txt" 2>/dev/null && [[ $TC4_RC -eq 0 ]] && echo "$TC4_OUT" | grep -q 'jar1'; then
    pass "TC-4 testclient http --cookie-jar (Set-Cookie 捕获 + 回放)"
else
    fail "TC-4 testclient http --cookie-jar" "rc=$TC4A_RC/$TC4_RC jar=$(cat "$TMP/tc_jar.txt" 2>/dev/null) out=$TC4_OUT"
fi

# TC-5: ws /ws echo 往返 — send-text + receive-text + 自动 close 1000, exit 0
TC5_OUT=$("$FMTOOL" testclient ws "$TC_WS/ws" --action send-text:hello --action receive-text:hello 2>&1); TC5_RC=$?
if [[ $TC5_RC -eq 0 ]] && echo "$TC5_OUT" | grep -q '"event":"connect"' && echo "$TC5_OUT" | grep -q '"value":"hello"' && echo "$TC5_OUT" | grep -q '"event":"done"'; then
    pass "TC-5 testclient ws /ws echo (send/receive/done)"
else
    fail "TC-5 testclient ws /ws echo" "rc=$TC5_RC out=$TC5_OUT"
fi

# TC-6: ws /ws/close/4001 — expect-close:4001:custom reason (主 server WS_CLOSE_WAIT=2000)
TC6_OUT=$("$FMTOOL" testclient ws "$TC_WS/ws/close/4001" --action send-text:go --action "expect-close:4001:custom reason" 2>&1); TC6_RC=$?
if [[ $TC6_RC -eq 0 ]] && echo "$TC6_OUT" | grep -q '"code":4001' && echo "$TC6_OUT" | grep -q 'custom reason'; then
    pass "TC-6 testclient ws expect-close 4001 (reason 匹配)"
else
    fail "TC-6 testclient ws expect-close 4001" "rc=$TC6_RC out=$TC6_OUT"
fi

# TC-7: run — 副 server (PORT+117) spawn → http action → SIGTERM → server_exit=0
TC_PORT=$((PORT + 117))
TC_ACTIONS="$TMP/tc_actions.jsonl"
printf '{"op":"http","method":"GET","url":"http://127.0.0.1:%s/health","expect_status":200,"expect_body":"healthy"}\n' "$TC_PORT" > "$TC_ACTIONS"
TC7_OUT=$("$FMTOOL" testclient run --port "$TC_PORT" -- "$BIN" -- "$TC_ACTIONS" 2>&1); TC7_RC=$?
if [[ $TC7_RC -eq 0 ]] && echo "$TC7_OUT" | grep -q 'run: 1 passed, 0 failed' && echo "$TC7_OUT" | grep -q 'server_exit=0'; then
    pass "TC-7 testclient run (server 生命周期 + action + 干净退出)"
else
    fail "TC-7 testclient run" "rc=$TC7_RC out=$TC7_OUT"
fi

# TC-8: ws 打到非 WS 路由 → denial 事件, exit 4 (WS router 404)
TC8_OUT=$("$FMTOOL" testclient ws "$TC_WS/health" 2>&1); TC8_RC=$?
if [[ $TC8_RC -eq 4 ]] && echo "$TC8_OUT" | grep -q '"event":"denial"'; then
    pass "TC-8 testclient ws denial (非 WS 路由, exit 4)"
else
    fail "TC-8 testclient ws denial" "rc=$TC8_RC out=$TC8_OUT"
fi

# TC-9: http 404 — status 透传, exit 0 (收到任意响应即成功)
TC9_OUT=$("$FMTOOL" testclient http GET "$BASE/nope" --json-out 2>&1); TC9_RC=$?
if [[ $TC9_RC -eq 0 ]] && echo "$TC9_OUT" | grep -q '"status_code":404'; then
    pass "TC-9 testclient http 404 (status 透传, exit 0)"
else
    fail "TC-9 testclient http 404" "rc=$TC9_RC out=$TC9_OUT"
fi

# Decision-62: staged OpenTelemetry traces — bounded per-process buffer +
# OTLP JSON-shaped /traces export. FASTAPI_MOJO_OTEL=1 is opt-in.
echo "== OpenTelemetry in-memory traces (决策-62) =="
OTEL_PORT=$((PORT + 103))
OTEL_LOG="$TMP/otel.log"
( env FASTAPI_MOJO_WORKERS=1 FASTAPI_MOJO_OTEL=1 \
    "$BIN" --port "$OTEL_PORT" > "$OTEL_LOG" 2>&1 ) &
OTEL_PID=$!
OTEL_READY=0
for i in $(seq 1 50); do
    if curl -fsS -m 1 "http://127.0.0.1:$OTEL_PORT/health" 2>/dev/null | grep -q healthy; then
        OTEL_READY=1; break
    fi
    sleep 0.1
done
if [[ "$OTEL_READY" != "1" ]]; then
    fail "OT-0 subserver ready" "log: $(tail -5 "$OTEL_LOG")"
else
    pass "OT-0 subserver ready"
    curl -fsS -m 5 "http://127.0.0.1:$OTEL_PORT/items/42" >/dev/null
    OTEL_TRACE_HEADERS=$(curl -sS -m 5 -D - -o "$TMP/traces.json" "http://127.0.0.1:$OTEL_PORT/traces")
    OTEL_JSON=$(cat "$TMP/traces.json")
    if [[ "$OTEL_TRACE_HEADERS" == *"Content-Type: application/json"* ]]; then
        pass "OT-1 /traces returns JSON"
    else
        fail "OT-1 /traces returns JSON" "headers: $OTEL_TRACE_HEADERS"
    fi
    if [[ "$OTEL_JSON" == *'"resourceSpans"'* && "$OTEL_JSON" == *'"service.name"'* && "$OTEL_JSON" == *'"fastapi_mojo.bridge"'* ]]; then
        pass "OT-2 OTLP resource/scope shape"
    else
        fail "OT-2 OTLP resource/scope shape" "body: ${OTEL_JSON:0:240}"
    fi
    if grep -Eq '"traceId":"[0-9a-f]{32}"' "$TMP/traces.json" && grep -Eq '"spanId":"[0-9a-f]{16}"' "$TMP/traces.json"; then
        pass "OT-3 valid traceId/spanId widths"
    else
        fail "OT-3 valid traceId/spanId widths" "body: ${OTEL_JSON:0:240}"
    fi
    if [[ "$OTEL_JSON" == *'"key":"http.request.method","value":{"stringValue":"GET"}'* && "$OTEL_JSON" == *'"key":"url.path","value":{"stringValue":"/health"}'* ]]; then
        pass "OT-4 health server span attributes"
    else
        fail "OT-4 health server span attributes" "body: ${OTEL_JSON:0:300}"
    fi
    OT4=$(grep -bo '"name":"GET /health"' <<<"$OTEL_JSON" | head -1 | cut -d: -f1)
    OT5=$(grep -bo '"name":"GET /items/42"' <<<"$OTEL_JSON" | head -1 | cut -d: -f1)
    if [[ -n "$OT4" && -n "$OT5" ]] && (( OT4 < OT5 )); then
        pass "OT-5 span order + route path"
    else
        fail "OT-5 span order + route path" "offsets=${OT4:-?},${OT5:-?}; body: ${OTEL_JSON:0:300}"
    fi
fi
kill -TERM "$OTEL_PID" 2>/dev/null || true
wait "$OTEL_PID" 2>/dev/null || true
OTEL_DISABLED=$(curl -sS -m 5 "$BASE/traces")
if [[ "$OTEL_DISABLED" == *'"spans":[]'* ]]; then
    pass "OT-6 disabled by default (empty export)"
else
    fail "OT-6 disabled by default" "body: ${OTEL_DISABLED:0:200}"
fi

# Decision-63: HTTP/2 prior-knowledge h2c subset on the main server.
echo "== HTTP/2 prior knowledge (决策-63) =="
H2_OUT=$("$FMTOOL" http2 "$PORT" 2>&1); H2_RC=$?
for marker_name in H2-1 H2-2 H2-3 H2-4 H2-5 H2-6 H2-7; do
    if [[ $H2_RC -eq 0 ]] && grep -q "$marker_name" <<<"$H2_OUT"; then
        pass "$marker_name h2c end-to-end"
    else
        fail "$marker_name h2c end-to-end" "rc=$H2_RC out=$H2_OUT"
    fi
done

# Decision-64: opt-in TLS/HTTPS on a secondary server. openssl/curl are CI
# dev tools only; the delivered binary remains Mojo + Rust and libc-only.
echo "== TLS/HTTPS (决策-64) =="
TLS_PORT=$((PORT + 119))
TLS_INVALID_PORT=$((PORT + 120))
TLS_CERT="$TMP/tls-cert.pem"
TLS_KEY="$TMP/tls-key.pem"
TLS_LOG="$TMP/tls-server.log"
TLS_INVALID_LOG="$TMP/tls-invalid.log"
umask 077
if openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    -keyout "$TLS_KEY" -out "$TLS_CERT" >/dev/null 2>&1; then
    ( cd "$SRC" && exec env FASTAPI_MOJO_WORKERS=1 \
        FASTAPI_MOJO_TLS_CERT="$TLS_CERT" FASTAPI_MOJO_TLS_KEY="$TLS_KEY" \
        "$BIN" --port "$TLS_PORT" >"$TLS_LOG" 2>&1 ) &
    TLS_PID=$!
    TLS_READY=0
    for _ in $(seq 1 50); do
        if [[ "$(curl -sk --max-time 1 "https://127.0.0.1:$TLS_PORT/health" 2>/dev/null)" == *healthy* ]]; then
            TLS_READY=1; break
        fi
        kill -0 "$TLS_PID" 2>/dev/null || break
        sleep 0.1
    done
else
    TLS_READY=0
fi

if [[ "$TLS_READY" == 1 ]]; then
    pass "TLS-0 https subserver ready"
    TLS_BASE="https://127.0.0.1:$TLS_PORT"
    TLS_HEALTH_CODE=$(curl -sk --max-time 5 -o "$TMP/tls-health.json" \
        -w '%{http_code}' "$TLS_BASE/health")
    TLS_HEALTH=$(cat "$TMP/tls-health.json" 2>/dev/null || true)
    if [[ "$TLS_HEALTH_CODE" == 200 && "$TLS_HEALTH" == *healthy* ]]; then
        pass "TLS-1 HTTPS /health 200 + body"
    else
        fail "TLS-1 HTTPS /health 200 + body" "code=$TLS_HEALTH_CODE body=${TLS_HEALTH:0:200}"
    fi

    TLS_POST=$(curl -skS --max-time 5 -H 'Content-Type: application/json' \
        -d '{"name":"tls-e2e","price":7.25}' "$TLS_BASE/items")
    if [[ "$TLS_POST" == *'"item_name": "tls-e2e"'* && "$TLS_POST" == *'"item_price": "7.25"'* ]]; then
        pass "TLS-2 HTTPS POST JSON"
    else
        fail "TLS-2 HTTPS POST JSON" "body=${TLS_POST:0:240}"
    fi

    TLS_KA=$(curl -sk --max-time 10 --http1.1 \
        -o /dev/null -o /dev/null -o /dev/null -o /dev/null -o /dev/null \
        -w '%{num_connects}' \
        "$TLS_BASE/health?ka=1" "$TLS_BASE/health?ka=2" \
        "$TLS_BASE/health?ka=3" "$TLS_BASE/health?ka=4" \
        "$TLS_BASE/health?ka=5")
    if [[ "$TLS_KA" == 10000 ]]; then
        pass "TLS-3 HTTPS keep-alive reuses one connection"
    else
        fail "TLS-3 HTTPS keep-alive reuses one connection" "connect vector=$TLS_KA"
    fi

    TLS_H2=$(curl -skSI --max-time 5 --http2 "$TLS_BASE/health" 2>/dev/null)
    if [[ "$TLS_H2" == HTTP/2\ * ]]; then
        pass "TLS-4 ALPN negotiates HTTP/2"
    else
        fail "TLS-4 ALPN negotiates HTTP/2" "headers=${TLS_H2:0:200}"
    fi

    TLS_PROTO=$(curl -sksv --max-time 5 --http1.1 -o /dev/null \
        "$TLS_BASE/health" 2>&1 | grep 'SSL connection using' | tail -1)
    if [[ "$TLS_PROTO" == *TLSv1.3* ]]; then
        pass "TLS-5 negotiates TLS 1.3"
    else
        fail "TLS-5 negotiates TLS 1.3" "proto=${TLS_PROTO:-none}"
    fi

    if ! curl -sk --max-time 5 --tls-max 1.2 --http1.1 \
        "$TLS_BASE/health" >/dev/null 2>&1; then
        pass "TLS-6 TLS 1.2 boundary rejects handshake"
    else
        fail "TLS-6 TLS 1.2 boundary rejects handshake" "unexpected successful TLS 1.2 handshake"
    fi

    TLS_PLAIN=$(curl -sS --max-time 3 --http1.1 \
        "http://127.0.0.1:$TLS_PORT/health" 2>&1)
    if [[ $? -ne 0 && "$TLS_PLAIN" != HTTP/1.1* ]]; then
        pass "TLS-7 plaintext HTTP rejected"
    else
        fail "TLS-7 plaintext HTTP rejected" "got=${TLS_PLAIN:0:200}"
    fi

    kill -TERM "$TLS_PID" 2>/dev/null || true
    wait "$TLS_PID" 2>/dev/null
    TLS_EXIT=$?
    if [[ "$TLS_EXIT" == 0 ]] && ! kill -0 "$TLS_PID" 2>/dev/null; then
        pass "TLS-8 SIGTERM graceful exit"
    else
        fail "TLS-8 SIGTERM graceful exit" "exit=$TLS_EXIT"
    fi
    TLS_PID=""
else
    fail "TLS-0 https subserver ready" "log=$(tail -5 "$TLS_LOG" 2>/dev/null)"
fi

# Fail closed when TLS is explicitly requested but invalid (no partial HTTP listener).
printf 'not a certificate\n' >"$TMP/tls-invalid-cert.pem"
( cd "$SRC" && exec env FASTAPI_MOJO_WORKERS=1 \
    FASTAPI_MOJO_TLS_CERT="$TMP/tls-invalid-cert.pem" \
    FASTAPI_MOJO_TLS_KEY="$TLS_KEY" \
    "$BIN" --port "$TLS_INVALID_PORT" >"$TLS_INVALID_LOG" 2>&1 ) &
TLS_INVALID_PID=$!
TLS_INVALID_HUNG=0
for _ in $(seq 1 30); do
    kill -0 "$TLS_INVALID_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$TLS_INVALID_PID" 2>/dev/null; then
    TLS_INVALID_HUNG=1
    kill -TERM "$TLS_INVALID_PID" 2>/dev/null || true
    sleep 0.3
    kill -9 "$TLS_INVALID_PID" 2>/dev/null || true
fi
wait "$TLS_INVALID_PID" 2>/dev/null
TLS_INVALID_EXIT=$?
TLS_INVALID_PID=""
if [[ "$TLS_INVALID_HUNG" == 0 && "$TLS_INVALID_EXIT" -ne 0 ]] && grep -q 'TLS configuration failed' "$TLS_INVALID_LOG"; then
    pass "TLS-9 invalid config fails closed"
else
    fail "TLS-9 invalid config fails closed" "hung=$TLS_INVALID_HUNG exit=$TLS_INVALID_EXIT log=$(tail -3 "$TLS_INVALID_LOG")"
fi

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
