# ADR-0007: WebSocket 增强 — 多端点路由 + 子协议 + 服务端保活 + close/UTF-8 校验

- **日期**：2026-08-30
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行）
- **关联**：ADR-0006（WS 基础，其 §后续 清单即本 ADR 范围）、ADR-0004（user code = data
  路由注册模式）、`ws.c`（协议原语）、`http_bridge_final.c`（会话状态包装）、
  `ws_session.mojo`（Mojo 驱动会话循环）、`router.mojo`（WS 路由注册）、
  `handler.mojo`（KIND_WS_* 分派）、`scripts/e2e_test.sh`（websocket 节）

## 1. 背景

ADR-0006 交付了最小可用 WS（`/ws` echo，会话循环在 C 内阻塞执行）。其 §后续 清单
（"不在本 ADR 范围，需新 ADR"）列出了四类增强：

1. **多 WS 端点 / 业务消息路由**（当前仅 /ws echo）
2. **高并发 WS**（会话占用 Mojo 单线程 dispatch）
3. **subprotocol / 鉴权**
4. **空闲保活策略**（当前靠客户端 ping，受 RECV_TIMEOUT 约束，超时即断）

本 ADR 落地其中 1/3/4 及 close 帧合规性（原 C 循环对 close 码不做校验）。
**第 2 项（高并发 WS）明确不在本 ADR 范围**：它要求 worker 级 WS 或 C 层独立
poll + 回调，是对 ADR-0005 并发模型的结构改动，需要独立评估（见 §6）。

关键架构问题：ADR-0006 把会话循环放在 C（`ws_upgrade_and_echo`），多端点业务路由
要求"消息 → handler"的分派发生在 Mojo 层（user code = data，ADR-0004 模式），
而 ADR-0006 同时明确拒绝"C 层完整 WS 库 + Mojo 回调"（隐式回调违反显式 bridge 约束）。
因此本 ADR 的核心决策是：**把会话循环从 C 移到 Mojo，C 只保留协议原语**，
以"Mojo 逐消息显式调用"（与 HTTP 请求循环同构）替代"C 内循环"。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. C 内 mode 枚举 | `ws_upgrade_and_serve(fd, key, mode)`，C 实现 echo/counter 等模式 | 业务逻辑进 C（违反分层：业务决策应在 Mojo）；新增行为要改 C 重编译；与 ADR-0004 的 handler 注册模式不一致 |
| B. **C 协议原语 + Mojo 驱动会话循环（本 ADR）** | C 暴露 握手/读帧/写帧/close 原语；Mojo 持有会话状态（保活计数/连接级 state），逐消息显式 FFI 调用并分派 `run_ws_message` | ✅ 与 HTTP 循环同构（Mojo 驱动、C 原语）；显式 bridge（无隐式回调）；多端点 = 路由数据；每新增 WS 行为 = 1 个 KIND_WS_x + 1 个 elif |
| C. C 独立 poll + Mojo 回调 | C 层常驻 WS poll 循环，消息到达时回调 Mojo | 隐式回调（ADR-0006 已拒）；Mojo 1.0.0 无稳定函数指针/闭包传递；高并发是它的主场，但属于 ADR-0005 范畴 |

## 3. 决策

采用 **方案 B**：

**协议原语（`ws.c`，纯 C，零依赖）— 改动：**
- `ws_read_message` 返回值细分：`0` = 成功，`-1` = 错误/EOF/超限/**帧中途超时**
  （流已消耗、不可重试），`-2` = **空闲超时且本次调用未消耗任何字节**
  （流位置不变，可安全重试）。超时判定基于 `recv` 的 `EAGAIN/EWOULDBLOCK/EINTR`。
- `ws_handshake(fd, key, subprotocol)`：subprotocol 非空时 101 响应含
  `Sec-WebSocket-Protocol: <sp>`（RFC 6455 §4.1：服务端只能回显客户端提供的协议）。
- 新增 `ws_parse_close_code`（§7.4.1 码合法性）、`ws_validate_utf8`（§5.6 text 必须
  是合法 UTF-8）。
- **移除 `ws_upgrade_and_echo`**（C 内阻塞循环）：会话循环移到 Mojo。

**会话状态与包装（`http_bridge_final.c`）— 新增：**
- 每会话存储最近一条消息 payload（`g_ws_cur_*` 全局；进程单线程且会话期间 bridge
  poll 循环挂起，安全）；**payload 拷贝为 (n+1) 缓冲并 NUL 结尾**（见 §5 FFI 教训）。
- Mojo 面向的无符号状态码：`ws_session_read -> 0/1/2`（C 的 0/-1/-2 映射；
  **C `int` 负返回值经 Mojo i64 零扩展会变成巨大正数**，必须避免，见 §5）。
- 原语包装：`ws_session_begin`（101 握手，key 取自 `is_ws_upgrade`）、
  `ws_payload_slice`、`ws_last_opcode`、`ws_write_current`（零拷贝原样回显，
  text/binary echo）、`ws_write_text`（Mojo String → text 帧）、`ws_write_empty`
  （空 ping 帧）、`ws_reply_close`（合法回显 code+reason 上限 125B / 空按 1000 /
  非法按 1002）、`ws_send_close`（服务端发起）、`ws_session_end`（释放存储）、
  `get_ws_protocol_slice`（客户端 `Sec-WebSocket-Protocol` 原始值）、
  `get_ws_ping_max`（`FASTAPI_MOJO_WS_PING_MAX`，默认 3，0 = 禁用保活）。

**Mojo 会话循环（新增 `ws_session.mojo`）：**
- `run_ws_session(cfd, handler) -> Int`（返回日志状态码 101/400/500；调用方
  `conn_done(cfd, False)` —— WS 会话总是结束连接）。
- 子协议协商：路由声明 `ws_sp` 而客户端未提供/未包含 → 400（RFC 6455 §4.1）。
- 保活：读帧超时（状态 2）→ 发空 ping；连续 `ping_max` 次无客户端数据 →
  close 1000 结束；任何数据（含 pong）重置计数。`ping_max = 0` → 首次空闲超时
  即 close 1000（可配置关闭）。
- 控制帧：ping → pong（零拷贝同载荷）；pong → 忽略（活性证明）；close →
  `ws_reply_close` 后结束。
- text：UTF-8 校验（非法 → close 1007 结束）；`KIND_WS_ECHO` 零拷贝原样回显；
  其余 handler 解码为 String 后 `run_ws_message` 分派。
- binary：`KIND_WS_ECHO` 零拷贝原样回显；其余 handler → close 1003
  （unsupported data type）结束。

**路由与分派（`router.mojo` + `handler.mojo`，ADR-0004 模式）：**
- `router.add_ws_route(path, handler)` / `match_ws_route(path)`（**v1 精确匹配**，
  WS 暂不支持 `{param}` pattern —— 需要新 ADR）。
- `KIND_WS_ECHO`（100）、`KIND_WS_COUNTER`（101，连接级累加和有状态演示）。
- `run_ws_message(handler, opcode, msg, state) -> (reply_opcode, reply_text,
  new_state)`：WS 侧的"单一 dispatch 扩展点"，镜像 `run_handler`。
  新增 WS 行为 = 1 个 `KIND_WS_x()` + 1 个 elif。
- 内置端点（注册 = 数据）：`/ws`（echo）、`/ws/counter`（计数器）、
  `/ws/chat`（echo + 必需子协议 `chat`）。`/routes` 输出含 `WS /path` 条目。

**配置：** `FASTAPI_MOJO_WS_PING_MAX`（保活 ping 次数上限，默认 3）。
空闲窗口 = 既有 `FASTAPI_MOJO_RECV_TIMEOUT`（默认 5s）：超时后按计数发 ping。

## 4. 后果与限制（文档化）

- **单一会话串行**：不变（ADR-0006 已知限制）——WS 会话期间 Mojo dispatch 被占用，
  新连接的 upgrade 需等待当前会话结束。e2e 因此逐连接串行测试。高并发 WS 待后续
  ADR（方案 C 或 worker 级 WS）。
- **WS 路由 v1 精确匹配**：无 `{param}`、无 method 概念（WS 升级恒为 GET）。
- **text 回复不可含 NUL 字节**：Mojo 1.0.0 FFI 把传入的 CStringSlice 当作
  NUL 结尾 C 字符串消费（§5 教训）。需要 NUL 的回复用 binary 帧路径
  （`ws_write_current` 零拷贝）。当前内置 handler 不受影响。
- **保活 ping 间隔粒度 = RECV_TIMEOUT**：超时事件是最早的"空闲信号"，实际 ping
  发送时间 = 超时时刻（默认 5s 的整数倍附近，受 `WS_PING_MAX` 上限约束）。
  帧**中途**超时（客户端分帧慢）仍按 ADR-0006 行为结束会话（流已消耗不可重试）。
- **close 回显上限 125 字节**（RFC 6455 §5.5 控制帧 payload 上限）。
- **正向影响**：ADR-0006 §后续 4 项中 3 项落地；WS 与 HTTP 共享同一
  "Mojo 驱动 + C 原语" 结构；e2e 从 63 → 71 项。

## 5. 实测 FFI 教训（Mojo 1.0.0，本 ADR 实施中验证）

这些是 `external_call` 与 C ABI 的实测边界，后续所有 bridge 函数应遵循：

1. **C `int` 负返回值会失真**：x86-64 写 EAX 会清零 RAX 高 32 位，C `int` 返回
   `-1` 在 RAX 中是 `0x00000000FFFFFFFF`；Mojo `Int`（i64）按整寄存器读取 →
   得到 `4294967295` 而非 `-1`。**Mojo 面向的状态码必须用非负编码**
   （本 ADR：0/1/2）。
2. **返回的 CStringSlice 只消费指针半**：Mojo 对 16 字节结构返回值只读 RAX
   （ptr），并对指针做 **strlen**（NUL 结尾假设）；RDX 中的 len 被忽略。
   因此所有返回给 Mojo 的缓冲必须 NUL 结尾且语义上不含 NUL（`get_body_slice`
   等既有函数恰好满足：HTTP 文本域）。
3. **参数方向同规**：Mojo 传入的 `.as_c_string_slice()` 参数，C 端应声明为
   `const char *`（只读指针半，strlen 取长）——与 `send_static_file` /
   `send_simple_response` 的既有模式一致。
4. **结构参数的位置敏感**：`(int, slice, int)` 触发 Mojo 运行时时 trap（SIGILL）；
   `(int, int, slice)` 静默交付错误寄存器。实测可靠的形态：`(slice)`、
   `(int, slice)`、`(int, slice, slice[, slice])`（slice 紧跟 int 组之后）。

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 方向单向：Mojo(`ws_session`/`http_server_final`) → C(`http_bridge_final.c` 会话包装) → C(`ws.c` 协议原语) → OS(socket)。`ws.c` 不引用 bridge 符号；Mojo 不反向依赖；`ws_session.mojo` 只 import `handler`/`string_builder`（同层 Mojo） |
| 2. 分层向下依赖 | ✅ 遵守 | 业务决策（子协议选择、保活策略、消息分派、连接级 state）在 Mojo 层（`ws_session.mojo` + `handler.mojo`）；RFC 6455 协议（帧/掩码/分片/close 码/UTF-8/握手）在 C 协议层（`ws.c`）；连接生命周期与缓冲存储在 C 桥接层（`http_bridge_final.c`）。每层只依赖下层 |
| 3. God package 阈值 | ✅ 遵守 | 所有 .mojo < 500 行：`http_server_final.mojo` 334、`handler.mojo` 303、`router.mojo` 259、`ws_session.mojo` 103、`string_builder.mojo` 230、`test_all.mojo` 373；C 侧：`ws.c` 308（净增 ~50：超时细分/subprotocol/close 码/UTF-8，净删 echo 循环）、`http_bridge_final.c` +150（会话状态区，独立注释块） |
| 4. 主题域边界清晰 | ✅ 遵守 | `ws.c` 仅 RFC 6455 协议原语；`ws_session.mojo` 仅 WS 会话编排（不碰 HTTP 响应构造以外的 bridge 面）；`handler.mojo` 的 `run_ws_message` 是 WS 行为唯一分派点；WS 路由与 HTTP 路由在 `router.mojo` 内平行存放（`routes` / `ws_routes`），互不混入 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | 无隐式回调：会话循环由 Mojo 显式逐消息调用（`ws_session_read`/`ws_write_*`/`ws_reply_close` 等具名函数）。ADR-0006 的 C 内循环 `ws_upgrade_and_echo` 已删除，不留双路径。新增 bridge 函数全部单点注释（§5 FFI 形态约束写在函数头） |
| 6. 测试文件跟随 | ✅ 遵守 | 单元：`test_all.mojo` 新增 `test_ws()`（子协议协商 6 例 / 计数器 6 例 / 未知 kind / WS 路由 3 例 / trim_spaces 4 例）；`router.mojo`/`handler.mojo` 自检扩展；e2e：websocket 节 15 项（原 7 + 新 8：subprotocol 101 / 缺 sp 400 / counter 状态 / 保活 ping / close 1002 / UTF-8 1007 / close reason 回显 / 非 WS 路径 404） |

## 7. 验证方式

1. **单元（`mojo run` 自检）**：`test_all.mojo` WS 节全绿；`router.mojo`
   （WS 精确匹配 + handler data）、`handler.mojo` 自检通过。
2. **e2e（`scripts/e2e_test.sh`，71 项，CI 可重复）**：
   - 回归：原 7 项 WS 检查（RFC 向量握手 / 文本回显 / 分片重组 / 76800B 大帧 /
     ping-pong / close / 非升级 404）全部保持通过
   - 新增 8 项：`/ws/chat` 子协议协商（101 + `Sec-WebSocket-Protocol: chat`）、
     缺必需子协议 → 400、`/ws/counter` 连接级状态（1→sum=1, 2→sum=3, 3→sum=6）、
     空闲保活 ping（e2e 环境 RECV_TIMEOUT=2s，两次 ping + pong 重置）、
     非法 close 码 1005 → 1002、非法 UTF-8 text → close 1007、
     close(4000,"bye") 回显 code+reason、WS 升级到非 WS 路径 → 404
3. **单 binary 不变式**：`./build_single.sh` 成功（2.1M）；`ldd` 仅 libc +
   内核组件；`env -i` 干净环境启动正常；`/routes` 含 3 条 `WS /path`。
