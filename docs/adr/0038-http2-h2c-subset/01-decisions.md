# ADR-0038: Dependency-free HTTP/2 prior-knowledge h2c subset

**状态**：已接受
**日期**：2026-09-12
**决策**：63（Goal-0003 P2 / `http2` bead）

## 1. 背景

上游 FastAPI/Starlette 生态在反向代理与浏览器入口大量使用 HTTP/2。完整通用
HTTP/2 引擎（TLS/ALPN、h2c Upgrade、全量流量控制、 trailers、server push、
extended CONNECT）通常依赖 `h2`/`hyper` 这类大型协议栈。本项目的 North Star 是
Mojo + Rust only、单 binary、零外部动态依赖；因此不能为了入口协议引入无界依赖面。

本决策交付一个有边界的 **prior-knowledge cleartext HTTP/2 (h2c)** 子集：客户端在
普通端口直接发送 RFC 7540 connection preface（`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`），
服务器在同一 poll 循环内识别并切换，不提供 HTTP/1.1 Upgrade 协商。

## 2. 目标

1. 浏览器/代理最常用的 `GET` / `POST` / `HEAD` 请求可在单连接上按 stream id 串行分派；
2. 请求头可被 HPACK 静态表、动态表与 Huffman 编码压缩；
3. 帧边界、padding、CONTINUATION、SETTINGS、PING、WINDOW_UPDATE、RST_STREAM、
   GOAWAY 与常见协议错误有明确处理；
4. 复用既有 Mojo Router/中间件/OpenAPI/请求注入语义，**不新增 FFI 导出**；
5. 全部实现为 Rust `std` + 既有依赖，不引入 C / Python / 新动态库。

## 3. 决策

### 3.1 传输入口与连接状态

- `Conn` 新增 `h2: Option<H2Connection>`；phase 0 收到完整 preface 后进入 **phase 6**；
  preface 后已经到达的字节直接交给 frame parser。
- phase 6 保持 socket 生命周期；HTTP/1.x 原有 phase 0/1/2/3/4/5 不变。
- H2 与 HTTP/1 共用同一个 listen fd 与 poll 循环，不开新线程/进程协议分支。
- 客户端 GOAWAY、EOF、发送失败或不可恢复帧错误会释放连接。

### 3.2 HPACK

- `hpack.rs` 实现 RFC 7541 请求解码：
  - 61 项静态表；
  - 有界动态表（默认/最大 4096 entry bytes）；
  - dynamic table size update；
  - indexed / literal-with-indexed-name / literal-with-new-name；
  - never-indexed 与 without-indexing 按相同语义读取；
  - 24-bit integer 上限与 1 MiB string 防御。
- `hpack_huffman.rs` 内嵌 canonical Huffman 表，支持解码请求头与 ones-padding 校验。
- 响应编码采用 literal-only（静态表 indexed name + literal value），不建响应动态表；
  这是合法 HPACK，且显著减小代码面。

### 3.3 Frame 与请求校验

支持/处理：

| Frame | 行为 |
|-------|------|
| HEADERS | padding + priority 前缀、pseudo-header 校验、END_STREAM/END_HEADERS |
| CONTINUATION | 必须紧跟对应 HEADERS；禁止其它帧交错；header block ≤16 KiB |
| DATA | padding、body ≤ max body（默认 1 MiB）、END_STREAM 时 Content-Length 匹配 |
| SETTINGS | ACK；SETTINGS_MAX_FRAME_SIZE；SETTINGS_INITIAL_WINDOW_SIZE |
| PING | 8-byte payload 原样 ACK |
| WINDOW_UPDATE | connection/current stream send window 更新 |
| PRIORITY | 忽略已知合法长度 |
| RST_STREAM | 丢弃尚未完成的 partial request |
| GOAWAY | 释放连接 |

协议防御：

- 请求 method/path/query/authority/field 长度有界；
- method ≤15、path/query ≤1023、field ≤4096、header list ≤256 项；
- RX 缓冲 ≤2 MiB，单帧长度遵 peer `SETTINGS_MAX_FRAME_SIZE`（本实现收紧到 ≤1 MiB）；
- pseudo-header 顺序、重复、未知值、connection-specific header
  （`connection` / `keep-alive` / `proxy-connection` / `te` / `transfer-encoding` /
  `upgrade`）、大小写、CR/LF/NUL 均拒绝；
- Content-Length 只允许 ASCII digits，并在 END_STREAM 时与 body 精确匹配。

### 3.4 与 Mojo HTTP 语义的适配

- `H2Request` 转换为既有 request globals：method/path/query、Accept-Encoding、
  CORS 三元组、Range/If-Range、body 与 active fd。
- `:authority` 适配为大小写不敏感 `Host` 查询；普通 header 查询复用
  `extract_request_header` FFI。
- body 拷贝到 `Conn.body` 时追加 NUL，保持既有 FFI NUL 终止契约。
- 非 multipart 且非 UTF-8 的 DATA 以 RST_STREAM(PROTOCOL_ERROR) 终止该 stream，
  不把 HTTP/1 错误行混入 H2 连接。
- **FFI diff = 0**：Mojo 侧没有新 `extern "C"` 导出，Router/dispatch 语义不感知 h2c。

### 3.5 Response framing 与并发边界

- `send_response` / streaming / preflight facade 根据 active request 的 HTTP/2 标记
  分派到 H2 response encoder；GZip/CORS/extra header 转换仍先在 facade 完成。
- 响应 `:status`、`content-type`、`content-length` 与 extra headers 使用 literal HPACK；
  empty/HEAD response 在 HEADERS 上直接 END_STREAM。
- DATA 按 16 KiB 分帧，response body ≤1 MiB，响应 header block ≤16 KiB。
- **串行 dispatch**：一次只把一个 ready stream 交给 Mojo；最多缓存 100 个 ready/pending
  stream。多个 HEADERS 可先到达，`recv_and_parse` 在 poll 前主动 drain 已缓冲的下一
  stream，避免等待新的 socket 事件。
- 只跟踪 connection send window；响应 DATA 在发送前一次性预留窗口。若当前窗口不足，
  本次 bounded subset 返回失败而不是阻塞等待 WINDOW_UPDATE。HEAD 只预留 0 byte DATA，
  不消耗 body 窗口。
- H2 timeout 发送 GOAWAY(ENHANCE_YOUR_CALM)，不会把 HTTP/1.1 408 状态行写入 H2 连接。

### 3.6 e2e 工具

`fmtool http2` 新增纯 Rust H2 客户端，覆盖：

1. prior-knowledge preface + SETTINGS；
2. GET `/health` 与响应 status/body/headers；
3. POST body + Content-Length；
4. CONTINUATION split header block；
5. HEAD 只返回 headers；
6. PING round-trip；
7. 两个 stream 的 HEADERS 先全部发送、响应后读取，验证 buffered multiplex drain。

## 4. 备选方案与权衡

| 方案 | 结论 | 理由 |
|------|------|------|
| 引入 `h2` / `hyper` | 拒绝 | 扩大第三方依赖面与安全审计面，违背单 binary 最小依赖目标 |
| 只做 HTTP/1.1 Upgrade h2c | 本期拒绝 | 需要双向 101/flush 状态机，且现代浏览器实际使用 TLS/ALPN 或 prior-knowledge 工具链 |
| 全量并发 stream + per-stream flow control | 后续决策 | 需要改造 Mojo 单请求 dispatch 生命周期；本期以串行 bounded subset 固化语义 |
| 自研 HPACK 子集 | 采纳 | 请求解码覆盖常用客户端压缩；响应 literal-only 保持小代码面 |

## 5. 风险与缓解

| 风险 | 处置 |
|------|------|
| 自研协议解析引入安全漏洞 | 长度/数量/整数/UTF-8/伪头部/connection-specific 全部 fail-fast；单元 + e2e 覆盖 |
| response 大于当前窗口 | 明确失败并记录为本期边界，不阻塞 poll worker |
| HPACK 动态表状态污染 | 每连接独立 decoder，4096 entry-byte 上限，RFC vectors 回归 |
| HTTP/1 early error 与 H2 response 判定形成 conn_table 重入死锁 | active request 全局协议标记，不通过 response 时二次 lock conn_table；413/raw malformed e2e 回归 |
| 已缓冲多 stream 在 conn_done 后无人唤醒 | recv_and_parse 在阻塞 poll 前 drain phase-6 ready stream；H2-7 回归 |
| Huffman 表手写错误 | RFC 7541 request examples + invalid padding 测试 |
| 协议错误破坏既有 HTTP/1 | H2 只在完整 preface 精确匹配后激活；504 项既有 e2e 全量回归 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | `io → http2_io → http2/hpack → frames` 单向；response facade 不回读 Router/Handler |
| 2. 分层向下依赖 | ✅ 遵守 | Mojo 请求语义复用既有 FFI；Rust bridge 内处理 framing，不新增 syscall 类型 |
| 3. God package 阈值 | ✅ 遵守 | 新 bridge 模块均 <500 行（http2 487 / HPACK 310 / Huffman 304 / response 235 / io adapter 159）；fmtool H2 客户端 <500 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | HPACK、frame、transport、response、fmtool client 各自独立；不混入 WebSocket/OpenAPI/body validation |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff=0**；H2 request→既有 request globals 的适配集中在 `http2_io.rs` |
| 6. 测试文件跟随 | ✅ 遵守 | `hpack_tests.rs` / `http2_tests.rs` 与生产模块同目录；真实 binary 覆盖 H2-1..H2-7 |

## 7. 验收（2026-09-12）

- Rust bridge：**483 passed / 0 failed / 4 ignored**；clippy `--release --tests -D warnings` **0 警告**
- fmtool：**35 passed / 0 failed**；clippy **0 警告**
- build：`./build_single.sh` 成功；binary **4,221,136 B**（≤6 MiB CI 门禁；较 ADR-0037 +36,864 B）
- e2e：504 → **511/511**（新增 H2-1..H2-7，既有 504 零回归）
- benchmark：6 场景 **0 errors**；get_root_10k_100c = **34,916.2 req/s**
- ldd：仅 libc/loader/vdso
- clean env：`env -i PATH=/usr/bin:/bin ./build/fastapi_mojo …` health 200，退出无孤儿
- `find src -name '*.c'` = 0；交付面 `*.py` = 0

## 8. 文档化偏差 / 后续边界

1. 仅支持 prior-knowledge h2c，不支持 TLS/ALPN 与 HTTP/1.1 Upgrade；
2. stream dispatch 串行，ready/pending 上限 100，不并发执行 Mojo handler；
3. 不支持 trailers、extended CONNECT、server push、WebSocket over HTTP/2；
4. 未维护 per-stream response send window，只在 response 发送前检查 connection window；
   窗口不足时本次响应失败而不是等待；
5. response HPACK 不使用动态表/Huffman；
6. RST_STREAM 只清理当前 partial request，未实现完整 open/closed stream state machine；
7. 客户端 `TE: trailers` 这一本可安全处理的特例也按 connection-specific header 拒绝；
8. TLS/ALPN 与 rustls 仍由 `tls-rustls` open bead 单独评估。

## 9. 实现

- `src/fastapi_mojo_rs/src/bridge/hpack.rs` / `hpack_huffman.rs` / `hpack_tests.rs`
- `src/fastapi_mojo_rs/src/bridge/http2.rs` / `http2_request.rs` / `http2_frames.rs`
- `src/fastapi_mojo_rs/src/bridge/http2_io.rs` / `http2_response.rs` / `http2_tests.rs`
- `src/fastapi_mojo_rs/src/bridge/{conn,io,request,send,mod}.rs`：phase 6、active H2 标记、response facade、buffered stream drain
- `src/fmtool/src/http2.rs`：零依赖 H2 e2e 客户端
- `scripts/e2e_test.sh` / `.github/workflows/ci.yml`：H2-1..H2-7 与 511 门禁
- `AGENTS.md`、`docs/goals/0003-fastapi-full-parity.md`：决策-63 记录
