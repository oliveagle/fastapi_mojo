# ADR-0031: TestClient 声明式等价 — `fmtool testclient`
# （Goal-0003 矩阵 #25：`fastapi.testclient.TestClient` / `starlette.testclient.TestClient`
# 等价；决策-56）

## 1. 背景

Goal-0003 矩阵 #25：`TestClient | 测试客户端 | ❌(dev 工具) | — | 低优先`。
这是对标矩阵的**最后一项**（#1–24 已全 ✅，含文档化偏差）。

**性质界定**：TestClient 是**开发者工具**（测试辅助），不是运行时功能 ——
上游 `fastapi.testclient` 从 Starlette `TestClient` 派生，本质是一个
**in-process ASGI 测试客户端**：`TestClient(app)` 把 app 包进 httpx
`MockTransport`，请求不走真实 socket，直接在测试进程内调 ASGI 接口。

### 1.1 上游活体探测（`/tmp/fm_probe`, fastapi 0.141.1 / starlette 1.6.0 /
httpx2 2.12.0, uvicorn 0.52.4, pydantic 2.13.4, anyio 4.13.0；探针脚本
`/tmp/probe_tcl*.py`）

| # | 语义 | 实测 |
|---|------|------|
| P-TCL-1 | **base_url** | 默认 `http://testserver`（WS = `ws://testserver`）；Host 头 = `testserver`；可覆盖 `TestClient(app, base_url=...)` |
| P-TCL-2 | **默认 UA** | `testclient` |
| P-TCL-3 | **Response 对象** | `status_code` / `reason_phrase` / `headers`（httpx.Headers **大小写不敏感**，`r.headers['content-type']` 与 `r.headers['CONTENT-TYPE']` 等价）/ `text` / `json()` / `content`(bytes) / `cookies` / `url` |
| P-TCL-4 | **json=** | **紧凑** `separators=(",",":")` + `ensure_ascii=False` → `{"k":"v","n":5}`（15B）；CT = `application/json`；Content-Length 精确 |
| P-TCL-5 | **data=** | dict → `application/x-www-form-urlencoded`，空格→`+`（`a=x+y&b=2`）；str → 原样透传 + CT 透传 |
| P-TCL-6 | **params** | 查询串，空格→`+`（`?x=1&y=two+three`） |
| P-TCL-7 | **Cookie** | Set-Cookie → 存 `client.cookies` jar → 下次请求回显 `Cookie: sid=abc123`；另有 per-response `r.cookies` |
| P-TCL-8 | **follow_redirects** | **默认 True**（Starlette 特例；httpx.Client 本身默认 False）— 302 自动跟随 |
| P-TCL-9 | **raise_server_exceptions** | 默认 True → app 异常**传播到测试进程**（ValueError 在调用点抛出）；False → 500 "Internal Server Error"；HTTPException ≠ 异常（404 JSON 普通响应） |
| P-TCL-10 | **lifespan** | `with TestClient(app) as c` → enter startup / exit shutdown（实测）；裸用（无 `with`）→ lifespan 不执行 |
| P-TCL-11 | **WS connect** | `with client.websocket_connect(url, subprotocols=None, **kwargs) as ws:`（starlette 1.6.0 **必须 context-manager**；旧裸返回已废）；内部 GET：`connection:upgrade` / `sec-websocket-key:"testserver=="` / `sec-websocket-version:13` / `sec-websocket-protocol`（逗号+空格 join） |
| P-TCL-12 | **WS send** | `send_text` / `send_bytes` / `send_json(mode="text" 默认\|"binary"`；紧凑 JSON） |
| P-TCL-13 | **WS receive** | `receive()` = 原始 ASGI msg dict（`{'type':'websocket.send','text':...}`）；`receive_text` / `receive_bytes` / `receive_json(mode)`；**server 先 close → `WebSocketDisconnect(code=4001, reason='custom-why')`**（实测） |
| P-TCL-14 | **子协议** | offer `["chat","alt"]` → server 接受 `"chat"` → `ws.accepted_subprotocol == 'chat'` |
| P-TCL-15 | **denial** | 非 101（403）→ **`WebSocketDenialResponse`**（MRO = Response + WebSocketDisconnect；status_code/headers/content 保留） |
| P-TCL-16 | **extra_headers** | 101 响应头暴露为 `ws.extra_headers`（默认 `[]`） |

> 探测注记：WS 端点必须有 `websocket: WebSocket` **类型标注**，否则参数名
> `"websocket"` 被当 query 参数 → 422 → close 1008（探测期踩坑，非环境问题）。

### 1.2 范围切分

- **本 ADR = TestClient 的声明式等价**（能力面：HTTP 请求/响应/redirect/cookie
  / WS 会话 / WS denial / WS close / WS subprotocol / lifespan 生命周期）。
- **等价形态**：TestClient 的本质是"对 FastAPI app 发请求 + 拿结构化响应 +
  WS 会话"。本实现把"in-process ASGI"替换为**对真实部署产物（单一 binary）
  的真实 TCP 请求** —— 声明式 CLI + JSONL action script，落在 **fmtool**
  （dev tool 归 fmtool，决策-22 Track B 先例；不进 runtime binary）。
- **Mojo 1.0.0 无 socket/网络**（ADR-0001 C5 同款约束）→ 客户端必然 Rust；
  fmtool 已有 net.rs（TCP）+ ws.rs（WS 帧/handshake）+ json.rs（解析/序列化）
  全套零依赖原语，TestClient 客户端是这些原语的**组合**，非新依赖。

## 2. 候选方案

| # | 方案 | 评估 |
|---|------|------|
| A | **`fmtool testclient` 子命令组**（http / ws / run），纯 Rust 真实网络客户端 + JSONL action script | ✅ dev tool 归 fmtool（决策-22 先例）；零第三方依赖（net/ws/json 原语已在 fmtool）；不进 runtime binary（North Star 不变：ldd 仅 libc / 体积预算）；声明式（无闭包，Mojo 1.0.0 约束同款）；真实 TCP = 比 in-process ASGI **更贴近部署产物** |
| B | runtime binary 内置 `--test` 模式（自测客户端进交付物） | ❌ 膨胀交付物（违反单 binary 零依赖北星）；test 客户端是 dev tool，不应进生产 binary |
| C | Mojo 客户端 | ❌ Mojo 1.0.0 无 socket/网络模块（ADR-0001 C5 同款约束）；无闭包无法表达 TestClient 的 callable/portal 语义 |

**决策：A** — `fmtool testclient`（决策-56）。

## 3. 决策

### 3.1 子命令面

三个子命令（声明式，参数驱动，无闭包）：

| 子命令 | 形态 | 对标的 TestClient 面 |
|--------|------|----------------------|
| `testclient http` | `<METHOD> <URL> [opts]` | `client.get/post/...` + `json=`/`data=`/`params`/`headers`/`cookies`/`follow_redirects` + Response 对象（`--json-out` 输出 P-TCL-3 全字段） |
| `testclient ws` | `<URL> [opts]` | `client.websocket_connect` + `send_text/bytes/json` + `receive*` + subprotocol + close + denial + disconnect（P-TCL-11..16） |
| `testclient run` | `<server-cmd...> -- <actions.jsonl>` | **lifespan context-manager 等价**（P-TCL-10）：spawn server → readiness → 执行 actions（http/ws）→ SIGTERM → 报告 |

### 3.2 `testclient http` spec

```
fmtool testclient http <METHOD> <URL>
    [--json <body>]          # 紧凑 JSON body (CT application/json; separators=(",",":") ensure_ascii=False)
    [--data <form-or-raw>]   # form (含 = → urlencoded 空格→+) 或 raw (原样透传)
    [--param k=v]...         # 查询串 (空格→+)
    [--header NAME:VAL]...   # 请求头 (可重复)
    [--cookie k=v]...        # Cookie 头 (可重复)
    [--cookie-jar FILE]      # cookie jar 文件 (capture + replay; 持久化)
    [--no-follow]            # 默认 follow (P-TCL-8 parity); --no-follow 禁
    [--max-hops N]           # 重定向跳数上限 (默认 10)
    [--timeout-ms N]         # 超时 (默认 5000)
    [--json-out]             # 输出 Response JSON (P-TCL-3 全字段)
```

- **默认 UA = `testclient`**（P-TCL-2）。
- **Response 对象**（`--json-out`）= P-TCL-3 全字段：
  `{"status_code":N,"reason":"...","headers":[[k,v],...],"cookies":[[k,v],...],
  "url":"...","body":"...","body_b64":...}`（非 UTF-8 时 body=null + body_b64）。
- **redirect 语义**（P-TCL-8 follow 默认）：303→恒 GET；301/302→POST 变 GET；
  307/308→保方法+body；相对 Location→同 host。
- **退出码**：0=有响应（任意 status）/ 1=连接失败 / 2=超时 / 3=协议错 / 4=重定向环。
- **cookie jar 文件** = `name=value` 行（首个 `=` 切）；请求时拼 `Cookie:`，
  响应 Set-Cookie 更新 jar 并重写文件（**文件持久化** = dev tool 便利，
  比 in-memory 更适合脚本编排）。

### 3.3 `testclient ws` spec

```
fmtool testclient ws <URL>
    [--subprotocol a,b]      # 子协议 offer (CSV; P-TCL-14)
    [--action SPEC]...       # action 列表 (见 3.4)
    [--timeout-ms N]         # 超时 (默认 5000)
```

**输出 = JSONL 事件流**（每行一个 JSON 对象）：

| 事件 | 形态 | 触发 |
|------|------|------|
| `connect` | `{"event":"connect","subprotocol":...}` | 101 后（subprotocol = 协商值或 null） |
| `send-*` | `{"event":"send-text","text":...}` / `send-json` / `send-bytes` | 对应 send action |
| `receive` | `{"event":"receive","type":"websocket.send","text":...}` | `receive`（raw ASGI dict 等价） |
| `receive-text` | `{"event":"receive-text","text":...}` | `receive-text` |
| `receive-bytes` | `{"event":"receive-bytes","bytes":"<hex>"}` | `receive-bytes` |
| `receive-json` | `{"event":"receive-json","json":...}` | `receive-json` |
| `close` | `{"event":"close","code":N,"reason":"...","initiator":"server\|client"}` | 收到/发出 close 帧 |
| `denial` | `{"event":"denial","status":N,"reason":"...","body":"..."}` | 非 101（P-TCL-15 WebSocketDenialResponse 等价） |
| `error` | `{"event":"error","msg":"..."}` | 超时/协议错 |
| `done` | `{"event":"done"}` | 脚本正常结束 |

**退出码**：0=脚本完（或 expect-close 命中）/ 4=denial / 5=提前断（server
先 close 且非 expect-close）/ 6=超时。

### 3.4 action 表（`--action`，ws 用）

| action | 字段 | 语义 | 对标 TestClient |
|--------|------|------|-----------------|
| `send-text:D` | D = 文本 | 发 text 帧 | `ws.send_text` |
| `send-json:J` | J = JSON | 发 compact JSON text 帧 | `ws.send_json(mode="text")` |
| `send-bytes:HEX` | HEX | 发 binary 帧 | `ws.send_bytes` |
| `close:CODE[:REASON]` | | 发 close 帧（发起 close 握手） | `ws.close` |
| `expect-close:CODE[:REASON]` | | **断言下一个 close 帧匹配**（code + reason）；命中→脚本完 exit 0 | `WebSocketDisconnect` 断言（P-TCL-13 server 先 close） |
| `receive` | | 读下一数据帧（raw） | `ws.receive()` |
| `receive-text[:EXPECTED]` | | 读 text 帧（可选 EXPECTED 断言） | `ws.receive_text` |
| `receive-bytes[:HEX]` | | 读 binary 帧（可选 HEX 断言） | `ws.receive_bytes` |
| `receive-json[:J]` | | 读 JSON 帧（可选断言） | `ws.receive_json` |

**control 帧透明处理**：server keep-alive ping → 客户端自动 pong（RFC 6455）；
pong → 静默忽略；**这些不产生 receive 事件**（上游 TestClient 的 receive()
也不返回 control 帧，协议层内部处理 = parity）。

### 3.5 `testclient run` spec（lifespan CM 等价，P-TCL-10）

```
fmtool testclient run [--port N] [--timeout-ms N] [--readiness PATH]
                      [--max-wait N] <server-cmd...> -- <actions.jsonl>
```

流程（= `with TestClient(app) as c:` 生命周期）：
1. **spawn server**（`<server-cmd...>` + 注入 `--port N`；`with` enter 等价）
2. **readiness**：GET /health（默认）含 "healthy"，超时 `--max-wait`（默认 10s）
   —— 对应 lifespan startup 完成后服务可用
3. **执行 actions**（JSONL 文件，每行一个）：
   - `{"op":"http","method":"GET","url":"...","expect_status":200,"expect_body":"healthy"}`
   - `{"op":"ws","url":"ws://...","actions":["send-text:hi","receive-text:hi"]}`
   （`expect_*` 均可选；ws action 复用 3.4 action 表）
4. **SIGTERM → wait**（`with` exit 等价 = lifespan shutdown）
5. **报告**：逐 action `PASS/FAIL` + 汇总 `run: N passed, M failed; server_exit=...`
   **exit 0 仅当全部 action 通过 + server 干净退出（exit 0）**。

> server 对 SIGTERM = 优雅关停（G_RUNNING=0 → poll 退出 → lifespan shutdown
> → main return → exit 0），故 run 可断言 `server_exit=0`。

### 3.6 文件面（实现 = 目录模块，非单文件）

| 文件 | 变更 | 说明 |
|------|------|------|
| `src/fmtool/src/testclient/mod.rs` | **新增**（180 行） | 共享类型（UrlParts/Action/RcvKind/CookieJar）+ `parse_url`/`url_encode`/`parse_action`/`cookie_header` + `dispatch` 路由 |
| `src/fmtool/src/testclient/http.rs` | **新增**（484 行） | `testclient http` 子命令：请求构造 + 重定向循环（`redirect_method` 纯函数）+ Cookie jar 存取 + `--json-out`/human 输出 + 退出码 |
| `src/fmtool/src/testclient/ws.rs` | **新增**（462 行） | `testclient ws` 子命令：**host-aware** RFC 6455 握手（自实现，见下）+ Sec-WebSocket-Accept 校验 + 动作循环 + JSONL 事件 + 退出码 |
| `src/fmtool/src/testclient/run.rs` | **新增**（277 行） | `testclient run` 子命令：spawn（coreutils `kill -TERM`，fmtool 零 crate 依赖故无 libc）+ readiness 轮询 + JSONL actions + SIGTERM→exit 0 断言 |
| `src/fmtool/src/testclient/testclient_tests.rs` | **新增**（243 行） | `#[cfg(test)]` 30 单测（parse_url/url_encode/parse_action/CookieJar/redirect_method/build_body）；独立文件（house 模式） |
| `src/fmtool/src/main.rs` | 修改 | 加 `mod testclient` + `testclient` arm + usage 文本 |
| `http_server_final.mojo` | 修改 | 加 `/tc/jar` demo 路由（KIND_ECHO + `_reads_cookies` + `_response_headers` Set-Cookie，供 cookie capture e2e）；hub 文件小增量 |

> 实现说明：`src/fmtool/src/ws.rs` **未改** —— 其 `connect_and_handshake`
> 保持 `127.0.0.1` 硬编码（e2e ws1..ws5 逐字节行为不动）；testclient/ws.rs
> 自带 host-aware 握手（复用同一 SHA-1/base64/make_frame/recv_frame/
> expected_accept 原语）。所有文件 < 500 行约束满足（最大 484）。

### 3.7 FFI 表面 = **不变（diff 0）**

TestClient 是 **dev tool**，不进 runtime binary，**不碰 Rust bridge**。
`/tc/jar` demo 路由复用既有 `KIND_ECHO` + `_response_headers`（决策-28 F10 既有
机制），**零新增 FFI 导出**。binary 仅多一个 demo 路由，FFI 表面零改动
（ADR-0010 FFI 表面规则）。

### 3.8 层级与边界（文档化）

- fmtool = 独立 Rust crate（零第三方依赖，pure std）；testclient.rs 依赖
  net.rs（TCP）+ ws.rs（WS）+ json.rs（JSON）+ std::process（spawn server）
  —— **单向依赖，无环**（fmtool 内既有分层）。
- testclient 不 import fastapi_mojo_rs（bridge）—— dev tool 与 runtime
  物理隔离（不同 crate）。

### 3.9 文档化偏差（vs 上游 in-process TestClient）

| # | 偏差 | 理由 |
|---|------|------|
| 1 | **真实 TCP 对真实 binary**，非 in-process ASGI | fmtool 是独立进程，无法 in-process 调 ASGI；真实网络**更贴近部署产物**（单一 binary 即被测物）—— 可视为优于上游（in-process 会掩盖真实网络边界） |
| 2 | **无 in-process 异常传播** | 独立进程，app 异常无法传播到客户端进程；500 面 = 上游 `raise_server_exceptions=False` 路径（P-TCL-9 的后半） |
| 3 | **cookie jar = 文件**（`name=value` 行，首个 `=` 切） | 非 in-memory + 非完整 RFC domain/path/expiry 模型；文件持久化更适合脚本编排 |
| 4 | **declarative action script**（CLI 参数 + JSONL） | 替代闭包/portal 对象（Mojo 1.0.0 无闭包同款约束）；JSONL action = 声明式世界观 |
| 5 | **UA = `testclient`** 但 Host = 真实 host:port（非 `testserver`） | 真实网络对真实 binary，Host 必须是可达地址（`testserver` 不可解析）；语义等价（host 标识） |
| 6 | **lifespan = spawn/kill 真实 server**（非 in-process CM） | 同上；spawn→readiness→actions→SIGTERM 等价 `with TestClient(app)` |

## 4. 风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| 真实网络 vs in-process：异常不传播 | 无法复现 P-TCL-9 前半（raise_server_exceptions=True 的 in-process 抛出） | 文档化偏差 #2；500 面仍覆盖（raise=False）；e2e 用真实 HTTP 500 验证 |
| WS denial/close 时序 | close-wait 持有时长影响 e2e 稳定性 | e2e server 设 `FASTAPI_MOJO_WS_CLOSE_WAIT=2000`；testclient close 读 echo 带超时 |
| cookie jar 文件并发 | 多进程同时写 jar | dev tool 单进程使用；文档说明 |
| 体积增量（/tc/jar 路由进 binary） | 体积超预算 | /tc/jar 复用 KIND_ECHO + _response_headers，增量极小（< KB）；门禁 ≤4.2M 兜底 |
| testclient.rs 超 500 行 | 违反模块约束 | 已按目录模块拆 mod/http/ws/run/tests；最大文件 484 行 < 500（验收时点） |

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | fmtool 独立 crate；`testclient → net/ws/json`（单向）；不 import fastapi_mojo_rs；无环 |
| 2. 模块 < 500 行 | ✅ 遵守 | testclient.rs 目标 < 500（超则拆 testclient_http.rs / testclient_ws.rs）；testclient_tests.rs 独立文件 |
| 3. FFI 表面 | ✅ 不变（diff 0） | TestClient = dev tool 不碰 bridge；`/tc/jar` 复用既有 KIND_ECHO + _response_headers（零新 FFI 导出） |
| 4. 零新依赖 | ✅ 遵守 | fmtool pure std（net/ws/json/process 全 std，零第三方 crate） |
| 5. 单 binary 不变式 | ✅ 遵守 | testclient **不进** runtime binary；binary 仅加 /tc/jar demo 路由（< KB 增量）；ldd 仍仅 libc；env -i 仍干净；≤4.2M |
| 6. 声明式世界观 | ✅ 遵守 | CLI 参数 + JSONL action script = 声明式；无闭包/无函数指针（Mojo 1.0.0 约束同款）；dev tool 与 runtime 物理隔离（不同 crate） |

## 7. 验收（门禁实测）

- **7.1 单 binary / ldd / env -i**：`./build_single.sh` → `build/fastapi_mojo`
  = **4,081,808 B（4.0M ≤ 4.2M）**；`ldd` = **仅 libc**（vdso/ld 为内核组件）；
  `env -i PATH=/usr/bin:/bin ./build/fastapi_mojo --port N` **干净启动**
  （health 200 `{"status": "healthy", ...}`，SIGTERM 优雅退出，无孤儿）。
- **7.2 质量门禁**：`cargo test --release -- --test-threads=1` 双 crate =
  **fastapi_mojo_rs 453 passed / 0 failed / 4 ignored（不变）** +
  **fmtool 30 passed / 0 failed**（testclient 新增：parse_url ×4 /
  url_encode ×4 / parse_action ×9 / CookieJar ×4 / redirect_method ×5 /
  build_body ×4）；`cargo clippy --release --tests -- -D warnings`
  双 crate = **0 警告**。
- **7.3 e2e TC-\***（`./scripts/e2e_test.sh`）：**TC-1..9 全 PASS**，
  e2e 总数 **438 → 447**（`e2e result: 447 passed, 0 failed`）。
- **7.4 性能 / 体积**：`./benchmark.sh` **6 场景 0 errors**；
  get_root_10k_100c = **34,867 req/s**（决策-55 基线 35,124，噪声内，无回归）。
- **7.5 e2e TC- 用例（实测）**：
  - TC-1: `http GET /health --json-out` → `"status_code":200` + body 含 healthy（exit 0）✅
  - TC-2: `http POST /items --json '{"name":"tc","n":5}'` → 200，body 回显 **解析后字段** `"item_name":"tc","item_n":"5"`（KIND_ECHO 解析 JSON body 注入参数，非原文回显）✅
  - TC-3: `http GET /cookies --cookie session_id=abc` → body 回显 `"cookie_session_id":"abc"` ✅
  - TC-4: `/tc/jar` `--cookie-jar` 两轮：首轮 Set-Cookie `tc=jar1` 落盘 jar 文件；次轮回放 → body 回显 `"cookie_tc":"jar1"` ✅
  - TC-5: `ws /ws --action send-text:hello --action receive-text:hello` → JSONL `connect → receive("hello") → done`（自动 close 1000），exit 0 ✅
  - TC-6: `ws /ws/close/4001 --action send-text:go --action "expect-close:4001:custom reason"` → `close{code:4001,reason:"custom reason",initiator:server}` + done，exit 0（P-TCL-13）✅
  - TC-7: `run --port 8117 -- <binary> -- actions.jsonl` → `run: 1 passed, 0 failed; server_exit=0`（spawn→readiness→action→SIGTERM→exit 0），exit 0 ✅
  - TC-8: `ws /health`（非 WS 路由 upgrade）→ `denial{status:404}` 事件，**exit 4**（WS router 对非 WS path 回 404，非 200 —— 实测行为）✅
  - TC-9: `http GET /nope --json-out` → `"status_code":404`，**exit 0**（收到任意响应即成功，与 TestClient 无 assert 语义一致）✅
- **7.6 实现期修复（本 ADR 落地偏差记录）**：
  1. `run` 参数解析 = **最后一个 `--`** 切 actions 文件（选项后可跟一个装饰性 `--`，两种写法都接受）；
  2. `run` 注入端口 = `--port` + 值 **两个 argv**（单个 `"--port N"` argv 会被服务器忽略 → 默认 8000，实现期实测 catch）；
  3. `run` SIGTERM 走 **coreutils `kill`**（fmtool 零 crate 依赖，无 libc crate；`std::process::Child::kill()` 是 SIGKILL 不可用）；
  4. ws 握手 host-aware 版 **新建于 testclient/ws.rs**（ws.rs 原 helper 不动，e2e ws1..ws5 逐字节不变）；
  5. `read_response` 去除 dead `timeout` 参数（socket 超时已由 `tcp_connect` 设置）。
