# ADR-0043: RedirectResponse 等价（307/303/301/308 + Location 头）

**状态**：已接受
**日期**：2026-09-12
**决策**：68（Goal-0003 FastAPI 公开 API 补全 / `redirect-response` bead）

## 1. 背景

Goal-0003 的 FastAPI parity 矩阵聚焦请求侧参数/校验/依赖/安全，`fastapi.responses`
的 **`RedirectResponse`** 一直是缺口：`src/fastapi_mojo` 无任何 redirect 发送路径，
`handler.mojo` 无 redirect kind，Rust bridge 亦无对应 FFI。上游 `fastapi.responses`
导出 `RedirectResponse`（Starlette `starlette.responses.RedirectResponse`），是公开
API 面的一部分；fmtool testclient 早已实现 follow 语义（P-TCL-8），但服务端无法产出
可 follow 的响应。

**上游实测（fastapi 0.141.1 + starlette 1.6.0，`/tmp/fm_redir_probe/probe*.py`）**：

- `RedirectResponse(url="/target")` 默认 `status_code=307`。
- 响应头：`content-length: 0` + `location: "<quoted url>"`；**无 `content-type`**
  （Starlette `Response.media_type=None`）。
- body 为空（`b""`）。
- `status_code=303` / `301` / `308` 同形，仅状态行不同（`See Other` /
  `Moved Permanently` / `Permanent Redirect`）。
- URL 经 `quote(str(url), safe=":/%#?=@[]!$&'()*+,;")`：`/p a th?x=1&y=2#frag`
  → `/p%20a%20th?x=1&y=2#frag`（空格 %20；safe set 保留 `?& = #`）。

## 2. 目标

1. `RedirectResponse(url, status_code=...)` 的 wire 语义：状态行 + `Location` +
   `Content-Length: 0` + 无 `Content-Type` + 空 body；
2. URL 按上游 safe set 百分号编码（byte 级 parity）；
3. 默认 307，支持 303/301/308（声明式 status line）；
4. 默认行为零扰动（新增 kind，不影响既有路由）；
5. 零新依赖 / North Star（Mojo + Rust only 单 binary，ldd 仅 libc）不变。

## 3. 决策

### 3.1 声明式 surface（延续 handler.data 范式）

| 键 | 语义 |
|---|---|
| `_redirect_url` | 目标 URL（原始，bridge 内按上游 safe set 百分号编码） |
| `_redirect_status` | 可选，完整 status line（默认 `"307 Temporary Redirect"`；亦支持 303/301/308） |

新增 `KIND_REDIRECT()`（handler.mojo，常量 = 400）。`run_handler` 返回占位
（`"307 Temporary Redirect"` + `{"message":"redirect response"}`）；真实发送在
dispatch 特例（需 fd，与 SSE / FILE 同型）。

### 3.2 发送路径（Rust bridge，FFI +1）

- `send.rs::send_redirect_response(fd, status, location)`：
  - `redirect_quote(url)`：上游 safe set（`:/%#?=@[]!$&'()*+,;` + `_.-~` +
    alnum）保留，其余 byte → `%XX`（大写 hex，UTF-8 逐字节）。
  - HTTP/1：手装头 `HTTP/1.1 <status>` + `Content-Length: 0` + `Connection` +
    CORS 行 + `Location` + 空行；**不写 Content-Type**。
  - HTTP/2：`http2_response::send_redirect` → HEADERS-only 帧（无 content-type，
    `content-length: 0`，END_STREAM）。
- `build_redirect_headers(status, location, keep_alive, cors_lines)`：纯函数头装配
  （便于单测）。
- `ffi.rs::send_redirect_response` extern "C" 包装。

### 3.3 与 GZip / 中间件的关系

redirect 无 body，GZip（MIN_SIZE 门槛）不介入；发送路径不经过 `send_response`
单点，故不触发用户中间件 response 面 —— 与 `send_streaming_response` 同型
（documented deviation：用户中间件不观测 redirect 响应体，因其无体可观测）。

### 3.4 语义边界（文档化偏差）与上游一致项

- redirect 是用户显式返回值（返回 `RedirectResponse`），**不是**路由自动 307/308
  尾斜杠重定向（`redirect_slashes` 是 Starlette Router 行为，本仓库暂无该自动面，
  单独跟踪）。
- `Location` 值不做多跳解析（上游 `quote` 同样只做编码）。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 复用 `send_simple_response_extra`（Content-Type: application/json） | 拒绝 | 上游 redirect **无 Content-Type**；byte 级 parity 不符 |
| 复用 streaming 路径（Transfer-Encoding: chunked, 0 chunk） | 拒绝 | 上游是 `Content-Length: 0`，非 chunked |
| 专用 `send_redirect_response` FFI（FFI +1） | 接受 | 头装配精确可控、可纯函数单测、h2 分支同型 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `send → http2_response/cors/request`（既有方向）；无反向依赖 |
| 2. 分层向下依赖 | ✅ 遵守 | Mojo 协议/dispatch 层只声明数据；字节装配 + I/O 在 bridge 层 |
| 3. God package 阈值 | ✅ 遵守 | 无新模块；`handler.mojo` / `http_server_final.mojo` 增量 <500 行预算 |
| 4. 主题域边界清晰 | ✅ 遵守 | 响应发送归 `send.rs`；URL 编码是 redirect 专属纯函数 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI +1（`send_redirect_response`）**，显式长度/NUL 契约；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | `send_tests.rs` 4 单测（quote / 头装配 / 真 socket 字节 / status 透传）；e2e RD-1..RD-10 |

## 6. 验收（2026-09-12）

- e2e **535 → 545/545**（RD-1..RD-10：307 默认/无 CT/CL:0/空 body/303/301/308/
  URL quote/testclient --no-follow/testclient follow）。
- canonical `./benchmark.sh` 6 场景 **0 errors**。
- `ldd build/fastapi_mojo` 仅 libc / loader / vdso；`env -i` 干净启动（HTTP 200）。
- binary **4,999,520 B**（≤6 MiB）；C=Python=orphans 0。
- cargo bridge **500 passed / 0 failed / 4 ignored**（+4）；clippy `--release --tests
  -- -D warnings` 0 警告；fmtool 35/0 + clippy 0。

## 7. 实现 / 边界

- `src/fastapi_mojo_rs/src/bridge/send.rs`：`redirect_quote` /
  `build_redirect_headers` / `send_redirect_response`。
- `src/fastapi_mojo_rs/src/bridge/http2_response.rs`：`send_redirect`。
- `src/fastapi_mojo_rs/src/bridge/ffi.rs`：`send_redirect_response` 包装层。
- `src/fastapi_mojo/handler.mojo`：`KIND_REDIRECT()` + `run_handler` 占位。
- `src/fastapi_mojo/http_server_final.mojo`：dispatch 分支 + 6 demo 路由
  （`/redirect` `/redirect/303` `/redirect/301` `/redirect/308` `/redirect/quote`
  `/redirect/health`）。
- `scripts/e2e_test.sh`：RD-1..RD-10。
