# ADR-0034: WebSocket permessage-deflate（RFC 7692）

**状态**：已接受
**日期**：2026-09-11
**决策**：59（Goal-0003 后续 P2：WebSocket 压缩 / `ws-deflate` open bead）

## 1. 背景

决策-15~18 已完成 RFC 6455 WebSocket、增强、并发与精化，但消息仍是明文
TEXT/BINARY 帧。FastAPI/uvicorn 常用部署面提供 RFC 7692
`permessage-deflate`（uvicorn 的 `ws_per_message_deflate` 默认开启），
Goal-0003 后续 P2 也保留了 `ws-deflate` open bead。

本决议补齐：

- 协商：`Sec-WebSocket-Extensions: permessage-deflate` 多 offer fallback；
- 出站：TEXT/BINARY 消息压缩后以 RSV1 标记；
- 入站：RSV1 数据消息解压后再进入既有 UTF-8 校验 / Mojo dispatch 路径；
- 方向正确的 context takeover / no_context_takeover；
- e2e 客户端必须能读取压缩帧（fmtool 保持零第三方依赖）。

## 2. 候选方案

| 方案 | 描述 | 判定 |
|------|------|------|
| A. Mojo 手写 DEFLATE | 压缩/解压状态机均放 Mojo 协议层 | ❌ Mojo 1.0.0 表达成本高；bridge 已有纯 Rust 压缩后端，重复造轮子 |
| B. 引入 C zlib / libz-sys | 直接使用成熟 zlib | ❌ 引入 C/系统动态库路径，破坏 Mojo+Rust only 与 North Star |
| C. **Rust bridge 复用 miniz_oxide（本 ADR）** | 服务端用 miniz_oxide raw DEFLATE stream API；FFI 表面不变 | ✅ 纯 Rust；flate2/miniz 组合已在 GZip（决策-40）存在，`miniz_oxide` 本已随 flate2 链入 |
| D. fmtool 依赖 flate2 | 测试客户端直接复用 crate | ❌ Track B 红线：fmtool 保持零第三方依赖 |

**决策**：服务端 C，开发工具 D 的替代实现为 **fmtool 手写 RFC 1951 inflater**。

## 3. 决策

### 3.1 配置与协商

- env `FASTAPI_MOJO_WS_DEFLATE`：
  - unset / `1` / `true` / `on` / `yes` → `on`（默认，uvicorn 默认开启对齐）；
  - `0` / `false` / `off` / `no` → `off`（有 offer 也不回扩展头，WS 仍 101）；
  - `required` → 必须协商成功；无有效 offer 时 Mojo 返回 HTTP 400
    `{"error":"permessage-deflate required but not offered","status":"400"}`；
  - 畸形值保守回退 `on`（一次读取 + AtomicI32 缓存）。
- offer 解析：
  - 逗号分隔多个 offer，按顺序取第一个可支持者（RFC fallback）；
  - 仅接受 `permessage-deflate`；
  - 未知参数 / 重复参数 → 该 offer 不支持（不污染其他 offer）；
  - `server_no_context_takeover`、`client_no_context_takeover` 支持；
  - `server_max_window_bits` 仅接受 **15**（miniz 固定 32 KiB LZ77 window；
    `<15` 的 offer 整体拒绝，不做缩小窗口伪装）；
  - `client_max_window_bits` 接受无值或 8..15（服务端响应不额外约束客户端）；
  - 响应只回显实际协商参数；`server_max_window_bits=15` 仅在客户端提供时返回。

### 3.2 方向语义（本决策的关键纠正）

`server_no_context_takeover` 控制 **服务端出站 compressor**；
`client_no_context_takeover` 控制 **客户端出站 / 服务端入站 inflater**。

因此：

- 客户端两个 flag 都提供且被接受 → 101 扩展头都回显；
- `server_no_context_takeover=true` → 每条服务端消息压缩前 reset compressor；
- `client_no_context_takeover=true` → 每条客户端消息解压前 reset inflater；
- 默认 takeover：同连接两方向均保持 DEFLATE 历史窗口。

不做「client flag 强制服务端 reset」的错误映射。

### 3.3 出站消息

- 仅非空 TEXT/BINARY 尝试压缩；空数据消息、控制帧、close 帧保持普通帧；
- raw DEFLATE level 6，每条消息 `Z_SYNC_FLUSH`；
- 按 RFC 7692 transformation 移除尾部 `00 00 ff ff`；
- 压缩帧首字节设置 FIN + RSV1 + opcode；
- miniz 空同步流的剩余 `02 00` 是合法 raw DEFLATE 字节，不做 4 字节 padding；
- 压缩失败（或超过 1 MiB）时回退未压缩帧；若 compressor 已部分推进则 reset；
- 不发送 close 前的空压缩数据帧（RFC 不要求，websockets 参考实现也不发送）。

### 3.4 入站消息

- RSV2/RSV3 永远协议错误；
- RSV1 仅允许出现在已协商连接的首个 TEXT/BINARY 帧；
- RSV1 控制帧 / 延续帧协议错误；
- 压缩首帧/延续帧 payload 进入连接级 `ws_decomp_buf`；普通与控制帧仍走
  `ws_reasm`，未协商客户端完全保持旧路径；
- 压缩消息支持 fragmentation，完成后：
  - append `00 00 ff ff` 并通过连接持久 inflater 解压；
  - 解压数据复制回 `ws_reasm`，再执行 UTF-8 校验与事件入队；
  - bad compressed data → close 1002；
  - 超 1 MiB（压缩消息或展开消息）→ close 1009；
- UTF-8 语义发生在解压后，不检查压缩字节本身；
- close-wait 期间数据仍按既有语义丢弃，不恢复业务 dispatch。

### 3.5 FFI / ABI 不变式

**FFI diff = 0**：

- `ws_handshake` 仍是 3 参数 `extern "C"`；扩展头由 Rust 内部
  `ws_handshake_inner(..., extension)` 附加，不改 Mojo/C ABI；
- `ws_parser_feed` 仍是 8 参数 FFI；压缩缓冲通过 `WsParser` 内部 pump 每次
  feed 前刷新的 `decomp_addr/decomp_cap` 提供；
- `ws_write_message` ABI 不变；RSV1 由 Rust 内部 helper 写首帧；
- `ws_session_begin` 既有签名不变，仅扩展返回值语义：`0=ok`,
  `1=internal failure`, `2=required 但无可接受 offer`（Mojo 映射 400）；
- 无新增 `#[no_mangle] extern "C"` 导出。

### 3.6 parser 布局与依赖

- 退役历史 72 字节 C-mirror `WsParser` compile-time assert：Rust DC1 后不再
  存在 C twin，RFC 7692 需要新增 RSV / compressed-length / pump-buffer 字段；
- 新状态仍为 `#[repr(C)]`，但布局是 Rust 内部契约而非 C 结构镜像；
- `decomp_addr` 使用 `usize` 而非裸指针，保持 `Conn` 可 `Send` 进入
  `ConnTable`；
- bridge 直接依赖 `miniz_oxide = 0.8`（该版本此前已由 flate2 传入并链接），
  raw stream API 需要直接类型；两者均为纯 Rust，无 C 路径。

### 3.7 fmtool（Track B）

fmtool 保持 **零第三方依赖**，新增 `src/fmtool/src/deflate.rs`：

- 出站编码：独立 raw stored blocks（每 block ≤65535），append 完整空 stored
  block 后移除 RFC 7692 尾 4 字节，天然支持 `client_no_context_takeover`；
- 入站解码：完整 RFC 1951 inflater（stored / fixed Huffman / dynamic Huffman /
  canonical code / LZ77 copy），持久 32 KiB window 验证服务端 takeover；
- 1 MiB 上限；
- `Frame` 捕获 RSV1，`make_frame_rsv1` 只影响新增 WSD 客户端；
- 新子命令：`wsdeflate`（WSD1..WSD4）、`wsdeflate-off`（WSD5）、
  `wsdeflate-required`（WSD6）；既有 ws1..ws5/testclient 未 offer 压缩，行为不变。

## 4. 风险与权衡

| 风险 | 处置 |
|------|------|
| DEFLATE bomb | 压缩 wire 与展开输出均 1 MiB cap；超限 close 1009 |
| per-connection 内存放大 | compressor/inflater/decomp buffer 仅协商后 heap 分配；未协商连接零新增大对象 |
| 协商参数导致语义误配 | 未知/重复/非法参数拒绝该 offer；server window `<15` 不接受 |
| 分片压缩状态与 close-wait 交错 | parser 只收集 compressed bytes，完成消息才解压；close-wait 丢弃语义不变 |
| fmtool 手写 inflater 回归 | stored / fixed / dynamic / persistent window / invalid vectors 单测，且 e2e 对真实 miniz 输出解码 |
| 体积预算 | miniz 已存在，直接类型/API 仅 +约24 KB；最终 binary 仍 ≤4.2M |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | 依赖保持单向：Mojo WS 升级 → bridge FFI → `ws::deflate` → miniz_oxide；`ws_session_deflate` 只被 session FFI 调用，不反向 import conn/io 业务循环 |
| 2. 分层向下依赖 | ✅ 遵守 | 协商/压缩属于 bridge 协议层；Mojo 仅消费既有 `ws_session_begin` 返回值；无新 syscall、无 Python/C 路径 |
| 3. God package 阈值 | ✅ 遵守 | `ws.rs` 498 / `ws/deflate.rs` 330 / `bridge/ws_session_ffi.rs` 499 / `bridge/ws_session_deflate.rs` 80（均 <500）；`bridge/io.rs` 为既有超阈值 hub 例外，本次仅接入 decomp buffer |
| 4. 主题域边界清晰 | ✅ 遵守 | RFC 6455 frame/parser、RFC 7692 negotiation/codecs、conn 状态、Mojo WS 升级映射分层；fmtool codec 是独立 dev tool，不进入运行期 binary |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff=0**；`ws_handshake` 3 参数、`ws_parser_feed` 8 参数、所有 `extern "C"` 签名不变；新增依赖为 pure Rust staticlib 内部实现 |
| 6. 测试文件跟随 | ✅ 遵守 | Rust `ws/deflate_tests.rs`、`ws/parser_tests.rs`（433）/ `ws/ws_tests.rs`（222）、`bridge/ws_session_deflate_tests.rs`、fmtool `deflate_tests.rs` 与生产代码同目录树；e2e WSD1..WSD6 真服务器守护 |

## 6. 验收（2026-09-11）

- fastapi_mojo_rs：**474 tests**（470 passed / 0 failed / 4 ignored；
  新增 deflate/negotiation/parser/session 17 tests）
- fmtool：**35 passed / 0 failed**（新增 5 tests）
- clippy：双 crate `--release --tests -- -D warnings` **0 警告**
- build：`./build_single.sh` 成功；binary **4,135,064 B**（≤4.2M，
  +24,584 B vs 决策-58）
- ldd：仅 libc/loader/vdso；无 libstdc++/libgcc_s/zlib/Python
- e2e：465 → **471/471**（WSD1..WSD6，既有 465 零回归）
- env 模式实测：默认 ON WSD1..4 绿；`FASTAPI_MOJO_WS_DEFLATE=0` WSD5 绿；
  `FASTAPI_MOJO_WS_DEFLATE=required` WSD6 400 绿
- bench：6 场景 **0 errors**（get_root_10k_100c = 28,794 req/s；本机噪声带宽,
  非 WS 压缩客户端不触发 deflate 热路径）
- RSS 平台化：1000 req ×3 rounds = 19,780 → 19,928 → 19,944 kB
  （round3 增量 +16 kB，无随请求线性增长）
- `find src -name '*.c'` = 0；fmtool Cargo 依赖数 = 0

## 7. 文档化偏差 / 边界

1. `server_max_window_bits < 15` 不支持：固定 miniz 32 KiB window，不做动态
   缩窗；相关 offer 会 fallback / 拒绝。
2. 空数据消息不压缩：RFC 允许逐消息选择，当前实现空 TEXT/BINARY 直接普通帧。
3. 服务端出站仍为单 FIN 帧；压缩 fragmented 出站不是既有 writer 语义，本决策
   不引入新 API。
4. 多个 `Sec-WebSocket-Extensions` 头的跨 header 合并顺序以现有 header 提取
   helper 为准；标准 comma-separated fallback 已覆盖。
5. fmtool 出站采用 stored blocks（非最小压缩），目的为零依赖、确定且自包含；
   读取侧完整支持服务端 miniz dynamic/fixed 输出。

## 8. 实现

- `src/fastapi_mojo_rs/src/ws/deflate.rs`：env mode / offer fallback / streams /
  sync-flush tail removal / bounded inflate
- `src/fastapi_mojo_rs/src/ws/parser.rs`：RSV 规则、compressed fragmentation、
  decomp 缓冲路由（8 参数 FFI 不变）
- `src/fastapi_mojo_rs/src/bridge/conn.rs`：连接级 compressor/inflater 与 flags
- `src/fastapi_mojo_rs/src/bridge/ws_session_deflate.rs`：协商初始化与出站统一 writer
- `src/fastapi_mojo_rs/src/bridge/ws_session_ffi.rs`：`ws_session_begin` 返回 2
  / 内部扩展握手头；所有写路径走压缩感知 helper
- `src/fastapi_mojo_rs/src/bridge/io.rs`：入站消息完成后解压、错误 close、
  UTF-8 与事件路径复用
- `src/fastapi_mojo/ws_session.mojo`：返回 2 → HTTP 400
- `src/fmtool/src/deflate.rs`、`src/fmtool/src/ws.rs`、`src/fmtool/src/e2e.rs`：
  零依赖 raw DEFLATE codec + RSV1 + WSD 子命令
- `scripts/e2e_test.sh` / `.github/workflows/ci.yml`：WSD1..WSD6，465→471
