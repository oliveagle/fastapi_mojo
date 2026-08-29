# ADR-0009: WebSocket 精化 — 合并帧丢失修复 + {param} 路由 + 鉴权 + 内存/背压加固

- **日期**：2026-08-30
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行）
- **关联**：ADR-0008（其实现审计发现 P0 bug，即本 ADR 核心修复；§后续 4 项中 3 项由
  本 ADR 落地）、ADR-0007（§后续：{param} 路由 / 鉴权 / NUL 回复）、
  `ws.c`（feed consumed/cap 语义）、`http_bridge_final.c`（尾块重放 + ws_pump_now +
  按需增长 + 事件队列加固）、`router.mojo`（WsRoute pattern）、`handler.mojo`
  （KIND_WS_GREET + params）、`ws_session.mojo`（ws_check_token）、
  `scripts/e2e_test.sh`（websocket 节 M17-M21）

## 1. 背景

ADR-0008 交付后，对其实现做正确性审计（RFC 6455 逐条 + 真实流量形态推演），发现
**P0 bug：合并帧丢失**。

**bug 机理**：`pump_ws_conn` 每次 recv 最多 8192B 进 `ws_parser_feed`；feed 在
**第一条完整消息**处返回（r=1），该 recv 块内**第一条消息之后的剩余字节被直接丢弃**
（buf 是栈上局部变量，pump 返回后即失）。真实客户端只要把两条消息放进同一个 TCP
段（burst 发送、sendall 拼接、零拷贝聚合 —— 生产流量常态），第二条消息即丢失，
客户端永远等不到回复（直到保活 ping / 超时断连）。同理，"数据帧 + ping" 混在同一
块时 ping 之后的帧也丢。ADR-0008 的 e2e 全部是"发一帧等一帧"形态，未覆盖合并帧，
故测试全绿而 bug 潜伏。

**次要缺陷（同审计发现）**：
- 尾块即使保留（P0 修复后）也**不产生 socket 事件** —— poll 循环不会为它唤醒，
  消息要等 1s poll tick 或无关数据才处理（实测延迟 5s 级，直到保活 ping 触发）。
- 重组缓冲首用即分配 1MB（1024 连接理论上界 ~1GB；典型小消息场景纯浪费）。
- 事件队列溢出**静默丢弃**（消息事件被丢 = 连接 phase 4 永久僵死：check_deadlines
  跳过 busy 连接 —— 比丢消息更严重）。

另落实 ADR-0007/0008 后续清单中的功能项：WS `{param}` 路由、WS 鉴权。

## 2. 候选方案（P0 修复）

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 每次只 recv 一条帧 | 按帧长精确 recv | 帧长未知时要先读头（多次 recv）；仍可能一块里有多帧（recv 返回超量）；治标 |
| B. **feed 报告 consumed + 每连接尾块缓冲重放（本 ADR）** | feed 增加 `consumed` 出参；pump 把未消费尾部存入每连接缓冲，下轮优先重放；Mojo 处理完消息后显式 `ws_pump_now(fd)` 立即重 pump（尾块无 socket 事件） | ✅ 与既有"显式 bridge"模式一致；零延迟；状态全部在 conn 内（多连接安全） |
| C. C 层每连接消息队列 | 协议层自己缓存多条待处理消息 | 把"消息交付节奏"从 Mojo 手里拿走；与 ADR-0008 的"Mojo 逐条分派"矛盾；内存策略复杂化 |

## 3. 决策

**P0 修复（方案 B）：**
- `ws_parser_feed` 新签名：`(..., unsigned char *reasm, size_t reasm_cap,
  size_t *consumed)`。每个返回点写 `*consumed = off`（错误点 = 出错字节处；
  0 = 全块消耗；1/2 = 消息/控制帧结束处）。
- `pump_ws_conn` 重构为"数据源 → feed → 尾块保留"循环：
  - 数据源：`c->ws_tail` 有残留（上一块的未消费尾部）则优先重放，否则
    `recv(MSG_DONTWAIT)` 进 `c->ws_tail`（8KB，惰性分配）。
  - 每轮 feed 后 `memmove` 未消费尾部回 `c->ws_tail` 头部 —— **任何路径
    （消息完成/控制帧/扩容）都不再丢字节**。
  - 控制帧处理完 `continue`（同块内可能有数据帧）；数据消息 → 事件 + phase 4 返回。
- **`ws_pump_now(fd)`**（bridge 新入口）：Mojo 在 `ws_message_done(fd)` 之后立即
  调用 —— 尾块数据不产生 socket 事件，不显式重 pump 就要等下一次 poll 唤醒
  （1s tick 或无关数据；实测无唤醒时延迟达 5s+）。显式调用 = 零延迟且无回调。

**内存/背压加固：**
- 重组缓冲**按需增长**：`WS_REASM_INIT = 4KB+1` 起步，feed 返回 `-2`（本块写入
  将越界，**未写越界**，consumed 指向待扩容点）→ pump `realloc` 翻倍（上限
  `WS_MAX_MSG+1`）→ 重放尾块。小消息连接只占 4KB；1MB 大消息渐进扩容（e2e
  76800B 大帧回归通过 = 扩容路径覆盖）。
- 事件队列：`WS_EV_MAX = 2*MAX_CONNS+64` —— 每个存活连接至多 1 条待处理事件
  （消息事件 ⇒ phase 4 暂停其 pump；结束事件 ⇒ 连接已死），**结构上不可溢出**。
  防御路径保留：溢出时消息事件 → close 1008 结束会话（绝不静默丢弃僵死连接）。

**功能项（ADR-0007/0008 后续落地）：**
- **WS `{param}` 路由**：`WsRoute.match_with_params`（segment pattern，与 HTTP
  `Route` 同语义：`{name}` 段捕获、段数必须相等）；`WsRouteMatch.params`
  贯穿事件分支 → `handle_ws_data` → `run_ws_message(handler, opcode, msg,
  state, params)`。演示端点：`/ws/greet/{name}`（新 `KIND_WS_GREET`：
  回复 `hello {name}: {msg}`，name 缺省 world）、`/ws/room/{room}`（echo）。
- **WS 鉴权**：handler data `ws_token` = 期望 token；**升级请求** query 必须带
  `token=<ws_token>`，否则 403（101 之前拒绝，RFC 语义：升级失败用普通 HTTP
  状态码）。`ws_check_token(handler, query)` 纯函数（可单测）；演示端点
  `/ws/private`（token=secret）。首帧 token / 自定义头鉴权 = 后续 ADR。
- **NUL 文本**：echo 路径（`ws_write_current`，C 侧真长度）本就 NUL 安全 ——
  e2e M18 固化"text 帧含 NUL 逐字节回显"。业务 handler **回复**含 NUL 仍受
  Mojo FFI strlen 约束（ADR-0007 §5 教训 3）—— 维持文档化约束。

**e2e 新增（websocket 节 M17-M21，74 → 79 项）：**
- M17 合并帧：2 帧同 sendall + 数据/ping/数据 3 帧混合 —— 全部按序到达（P0 回归）
- M18 text 含 NUL 逐字节回显
- M19 `/ws/greet/{name}` 参数化问候（两次消息，参数稳定）
- M20 鉴权：`?token=secret` → 101+回显；缺失 → 403；错误 → 403
- M21 `/ws/room/{room}` pattern + echo

## 4. 后果与限制（文档化）

- **合并帧不再丢失**（P0 关闭）；burst 20 帧单 sendall 有序全达（实施期验证）。
- **尾块重放零延迟**（ws_pump_now）；保活/控制帧语义不变（e2e M10 回归）。
- 每连接新增：`ws_tail` 8KB（惰性）+ `ws_reasm` 4KB 起步（惰性，按需 → 1MB）。
  典型小消息 WS 连接内存 ≈ 12KB（ADR-0008 的 1MB+）。
- 事件队列结构上不可溢出；1008 防御路径保留（理论不可达）。
- **限制**：
  - `{param}` 路由的 pattern 段不做 URL 解码（与 HTTP Route 现状一致；需新 ADR）
  - 鉴权仅支持升级 query token（首帧/自定义头 = 后续）
  - handler 回复含 NUL 仍截断（FFI 约束，ADR-0007 §5）
  - 单条消息处理仍是串行的（Mojo 单线程 dispatch 固有，ADR-0008 §4）
- **单 binary 不变式保持**：ldd 仅 libc；e2e 79 项全绿。

## 5. 实测教训（本 ADR 实施中验证）

1. **"发一帧等一帧"的 e2e 不能证明帧解析器正确**：合并帧（多帧同 TCP 段）是
   生产常态。帧协议测试必须覆盖：同块多帧、数据+控制混块、burst N 帧、
   帧跨多个 recv 块（大帧）。本 ADR 的 M17 即前两类的最小固化。
2. **用户态缓冲不产生 I/O 事件**：poll 驱动模型里，"数据已经在我的缓冲里"
   永远不会出现在 revents 中 —— 任何"存而待后"的缓冲都需要同步的显式
   重入点（本 ADR：ws_pump_now），否则延迟退化为 tick 级。
3. **越界检查必须在写入前且返回"未写"语义**：feed 的 `-2`（需扩容）在
   `dst + take > reasm_cap` 时**先于写入**返回 —— 与 ADR-0008 教训 2
   （dst 漏 pgot）同源：对重组缓冲的每次写入都要有"位置推导"审查。
4. **Mojo Dict 下标可 raise**：`params["name"]` 即使先 `in` 检查，编译器仍要求
   所在函数标 `raises`（与 run_handler 既有约定一致）—— 新增 handler 行为时
   别忘签名。

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 方向单向不变：Mojo(`http_server_final`/`ws_session`) → C(bridge 尾块/pump_now/队列) → C(`ws.c` feed 原语) → OS。`ws_pump_now` 是 bridge 内部函数（Mojo 显式调用，非回调）；`ws_check_token` 在 `ws_session.mojo`（只依赖 `params_query`） |
| 2. 分层向下依赖 | ✅ 遵守 | 尾块/扩容/队列是 I/O 与协议状态（C 桥接层）；`{param}` 匹配与鉴权判定是路由/安全策略（Mojo 层，数据驱动：路由表 + handler data）；帧字节语义仍在 `ws.c`。无层间上溯 |
| 3. God package 阈值 | ✅ 遵守 | `.mojo` 均 < 500 行：`test_all.mojo` 400、`http_server_final.mojo` 375、`handler.mojo` 317、`router.mojo` 291、`ws_session.mojo` 101；C：`ws.c` 380、`http_bridge_final.c` 1587（+58：尾块/pump_now/队列加固；`ws.c` +72：consumed/cap/-2） |
| 4. 主题域边界清晰 | ✅ 遵守 | `ws.c` 仍只含帧解析原语（不感知尾块/队列/连接）；bridge 的 WS 增量集中在"pump_ws_conn + 事件队列"既有块内；`ws_check_token` 与 `ws_select_subprotocol` 同处 `ws_session.mojo`（升级期策略）；路由 pattern 复用 `router.mojo` 既有 segment 语义（不复制 HTTP 路由逻辑，WsRoute 自持） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | `ws_pump_now(fd)` 是显式 FFI 入口（Mojo 主动调用，无回调）；鉴权/参数都是数据（handler.data / 路由 pattern），不是新 bridge 面；事件队列是数据（fd+type），交付仍走 `recv_and_parse` + `ws_event_type` |
| 6. 测试文件跟随 | ✅ 遵守 | e2e M17-M21（含 P0 回归 M17、burst 实施期验证）；单元：`test_all` WS 节 +pattern/greet/token（新增 ~15 断言）、`router.mojo` 自检 +WS pattern 3 例；原 74 项全部回归（79 passed, 0 failed） |

## 7. 验证方式

1. **P0 回归**：e2e M17（2 帧合并 + 数据/ping/数据混块）—— 修复前该场景
   第二帧丢失（实测：第二帧 5s 后才随保活 ping 后的唤醒到达，顺序错乱）。
   实施期另验证 burst 20 帧单 sendall 有序全达。
2. **功能**：e2e M18（NUL 回显）、M19（greet 参数化，双消息参数稳定）、
   M20（鉴权 101/403/403）、M21（room pattern）。
3. **回归**：原 74 项 e2e 全绿（含 ADR-0007 全部 15 项 WS + ADR-0008 并发 3 项 +
   76800B 大帧 —— 大帧同时覆盖重组按需增长路径）。
4. **单元**：`mojo run` 各模块 + `test_all`（WS 节扩展）全绿。
5. **单 binary 不变式**：`./build_single.sh`（2.2M）、`ldd` 仅 libc、`env -i` 启动正常。
