# ADR-0052: HEAD 请求统一仅头无体（桥接层 request 全局抑制）

**状态**：已接受
**日期**：2026-09-12
**决策**：77（Goal-0003 §1 矩阵 #1 路径方法 / `fastapi_mojo-ki9` bead）

## 1. 背景

上游 FastAPI 对 HEAD 的语义（0.141.1 实测，`starlette.testclient`）：

- 4 条内置路由（`/openapi.json` / `/docs` / `/docs/oauth2-redirect` / `/redoc`）
  注册 `GET, HEAD`；HEAD 返回 **与 GET 相同的响应头**（`Content-Length` = 完整体
  长度、`Content-Type` 相同）但 **body 为空**。
- 用户 GET 路由 HEAD → **405**（`Allow: GET`，无 body）；POST-only 路由 HEAD →
  405（`Allow: POST`）；未知路径 HEAD → 404（无 body）。即 **任何 HEAD 响应体都为空**
  （RFC 9110 §9.3.2）。

本仓库现状（实测 `build/fastapi_mojo`）：

| 请求 | 上游 | 本仓库（改前） |
|---|---|---|
| `HEAD /docs` | 200，CL=482，body 0 | 200，CL=482，**body 482** |
| `HEAD /redoc` | 200，CL=537，body 0 | 200，CL=537，**body 537** |
| `HEAD /docs/oauth2-redirect` | 200，CL=2715，body 0 | 200，CL=2715，**body 2715** |
| `HEAD /openapi.json` | 200，CL=N，body 0 | 200，CL=N，**body N** |
| `HEAD <KIND_HTML 路由>` | 200，body 0 | 200，**body**（分支与 GET 同体） |
| `HEAD <streaming/SSE 路由>` | 405 | 200 + **完整 chunk 体** |

用户 JSON 路由 HEAD 早已正确（`send_head_response` → `include_body=false`，
e2e「HEAD / → body 0」守护）；但**内置 doc 路由 / KIND_HTML / streaming** 三条
路径绕过该抑制。**后果**：HEAD 响应把完整体字节留在 keep-alive 连接上 → 下一条
请求解析脱轨（协议 bug；curl/httpx 因 HEAD 不读体而侥幸，但复用连接会中招）。

## 2. 目标

1. 所有 HEAD 响应仅头无体，`Content-Length` = 完整体长度（上游 parity）；
2. 覆盖内置 doc 路由 / KIND_HTML / JSON / static / SSE / streaming / error / 404 / 405；
3. 复用既有 request 全局（`current_method_is_head`，`file_serve` 已用）；
4. 单点实现，**不逐路由打补丁**；零新 FFI 符号。

## 3. 决策

### 3.1 `send_response` 单点抑制（覆盖绝大多数响应）

```rust
// bridge/send.rs send_response()
let include_body = include_body && !current_method_is_head();
```

- 经 `send_response` 的所有响应（内置 doc 路由 / KIND_HTML / JSON / static /
  SSE / error / 404 / 405）在 HEAD 下统一不发体；`Content-Length` 仍为完整体长度
  （`build_response_headers(body_out.len())`）。HTTP/1.1 与 HTTP/2 同享（h2 委托
  透传 `include_body`）。
- GZip 判定以 `include_body` 为门 → HEAD 不压缩（无需额外分支）。

### 3.2 `send_streaming_response` 仅头（HTTP/1.1 与 HTTP/2）

- H1：发完头块后 `if current_method_is_head() { return 0; }`（无 chunk / 无终止符）。
- H2（`http2_response::send_streaming`）：HEAD → `header_frames(..., end_stream=true)`
  且跳过 DATA 帧（HEADERS 直接带 END_STREAM）。头字段（`Transfer-Encoding: chunked`
  H1 / 无 CL）与 GET 相同。

### 3.3 判定复用既有全局

`request::current_method_is_head()`（读请求行原始方法，`file_serve` HEAD 分支已用）
—— 无新 FFI 导出、无新 request 字段、无 io.rs 改动。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 逐路由加 HEAD 分支（doc 路由 ×4 + KIND_HTML + streaming + SSE...） | 拒绝 | 重复、易漏、违背「单点钩子」约束 |
| 新增 FFI `send_*_head` 系列 | 拒绝 | FFI 膨胀；且无法覆盖未来响应类型 |
| **桥接层 request 全局单点抑制** | 接受 | 零 FFI / 单点 / 自动覆盖全部现有+未来响应 |
| 让 `is_head` 走 Mojo dispatch 分支 | 拒绝 | dispatch 需 6+ 处分支（doc/HTML/stream/SSE/file/redirect），且 FFI 边界仍要传 body |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `send` → `request`（既有单向）；`http2_response` → `request`（既有） |
| 2. 分层向下依赖 | ✅ 遵守 | HTTP 语义（HEAD 无体）在桥接发送层单点落地；Mojo 协议层零改动 |
| 3. God package 阈值 | ✅ 遵守 | `send.rs` net +4 行 / `http2_response.rs` net +6 行（均 <500） |
| 4. 主题域边界清晰 | ✅ 遵守 | 仅「响应发送」面变更；不触碰 CORS/GZip/路由/Cookie 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出/零新 crate）；复用既有 request 全局 |
| 6. 测试文件跟随 | ✅ 遵守 | `send_tests.rs`（HEAD JSON 抑制 + HEAD streaming 抑制）；e2e HD-1..4 |

## 6. 验收（2026-09-12）

- e2e **600 → 604/604**（HD-1 `/docs` / HD-2 `/redoc` / HD-3 `/docs/oauth2-redirect`
  / HD-4 `/openapi.json`：body 0 且 CL == GET 长度）。
- cargo bridge **507/0/4**（+2：HEAD JSON / HEAD streaming）；clippy 双 crate **0**；
  fmtool **35/0**。
- canonical `./benchmark.sh` 6 场景 **0 errors**（get_root_10k_100c ≈ 33.2k req/s）。
- `ldd` 仅 libc；`env -i` 干净启动 200（且 `/redoc` 200）；binary 5,089,704 B（≤6 MiB）；
  C=Python=orphans 0。
- 实测：`HEAD /docs|/redoc|/docs/oauth2-redirect|/openapi.json` → body 0、CL == GET 长度；
  keep-alive 复用（`HEAD /docs` 后同连接 `GET /health`）两请求均 200（无脱轨）。

## 7. 实现 / 边界

- `src/fastapi_mojo_rs/src/bridge/send.rs`：`send_response` 单点 `include_body` 抑制 +
  `send_streaming_response` HEAD 仅头。
- `src/fastapi_mojo_rs/src/bridge/http2_response.rs`：`send_streaming` HEAD → END_STREAM。
- `src/fmtool/src/{main,e2e}.rs`：`headbody <port> [path]`（可选路径 + `Connection: close`）。
- `scripts/e2e_test.sh`：HD-1..4。

边界：用户 GET 路由 HEAD 仍返回 **200**（本仓库的 HEAD 自动归一 = 既有文档化超集；
上游为 405 `Allow: GET`，row #1 已记，本轮不翻案——只保证「HEAD 无体」这一 HTTP 语义
正确）；HEAD 响应头与 GET 逐字段相同（含 `Content-Length`），不做上游 `Content-Length`
省略等变体；`/metrics`、`/traces` 等非 FastAPI 内置路由的 HEAD 亦随单点抑制变为无体
（HTTP 正确性，非上游对标项）。
