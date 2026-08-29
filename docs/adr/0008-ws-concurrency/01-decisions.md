# ADR-0008: 高并发 WebSocket — poll 循环驱动 + 协议自动处理 + Mojo 逐消息分派

- **日期**：2026-08-30
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行）
- **关联**：ADR-0007（其 §后续 第 1 项"高并发 WS"即本 ADR）、ADR-0005（多进程
  worker + SO_REUSEPORT，本 ADR 的进程内并发补充）、`ws.c`（状态化帧解析器）、
  `http_bridge_final.c`（WS conn 阶段 + 事件队列）、`ws_session.mojo`
  （upgrade 移交 + 逐消息分派）、`scripts/e2e_test.sh`（websocket 并发节）

## 1. 背景

ADR-0007 把 WS 会话循环移到 Mojo（显式 FFI、无隐式回调），但循环是**阻塞式**的：
`ws_session_read` 在 C 层 `recv` 上等待（SO_RCVTIMEO），期间 Mojo 主循环挂起，
bridge poll 循环停转 —— 一个 WS 会话占住 dispatch，其他连接（HTTP 或 WS）的
I/O 无人服务。ADR-0007 文档化该限制，并把"高并发 WS（worker 级 WS 或 C 层独立
poll）"列为后续 ADR。

多进程 worker（ADR-0005）只把阻塞分摊到 N 个进程，**单 worker 内** WS 会话
仍阻塞该 worker 的全部连接（e2e 默认 1 worker 时问题原样存在）。本 ADR 解决
进程内并发：**WS 会话不再阻塞 dispatch**。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 仅靠多 worker 分摊 | FASTAPI_MOJO_WORKERS=N；WS 会话阻塞所在 worker | 零改动但非根治：单 worker 仍串行；worker 数受核数限制；e2e/CI 默认 1 worker 无法验证 |
| B. **poll 循环驱动 + 事件队列（本 ADR）** | WS conn 纳入 bridge 既有 poll 状态机（新阶段 3/4）：帧解析、控制帧、保活、UTF-8 校验全部在 poll 循环内非阻塞完成（纯协议）；数据帧入 FIFO 事件队列，Mojo 主循环取事件逐条分派（业务）；Mojo 处理期间该 conn 暂停 pump（phase 4），其余连接照常服务 | ✅ 根治进程内阻塞；控制帧/保活零 Mojo 开销（高频小帧不唤醒 dispatch）；复用既有 poll 架构（无新线程、无回调）；显式 bridge（逐条 FFI）保持 ADR-0007 §3.5 约束 |
| C. C 层独立 poll + Mojo 回调 | WS 会话完全脱离 Mojo 主循环，C 回调 Mojo | 隐式回调（ADR-0006 已拒）；Mojo 1.0.0 函数指针/闭包传递不稳定；与 B 相比无额外收益（B 已不阻塞） |

## 3. 决策

采用 **方案 B**：

**`ws.c` — 状态化帧解析器（替换阻塞式 `ws_read_message`）：**
- `ws_parser_t` + `ws_parser_feed(parser, buf, n, &op, &mlen, reasm)`：
  非阻塞、partial-frame 安全的逐字节状态机（hdr0/hdr1/extlen/mask/payload
  五阶段），每帧/每消息状态逐帧显式重置（`mask_got` 等 —— 跨帧残留曾导致
  越界写，见 §5 实测）。
- 数据分片重组（含 >1MB 拒绝）；控制帧（≤125B、必须 fin）即时返回；
  客户端未掩码帧 = 协议错误（RFC 6455 §5.1）；保留 opcode (3-7) 拒绝。
- 消息完成时 `reasm` NUL 结尾（Mojo FFI 约定，ADR-0007 §5）。
- 移除：`ws_read_exact` / `ws_read_message` / `ws_free_payload`（阻塞式读）。
- 新增 `ws_reply_close_buf`（从任意缓冲校验并回复 close 码，供 poll 循环
  的 close 帧自动处理复用）。

**`http_bridge_final.c` — WS conn 阶段 + 事件队列：**
- conn 新阶段：`3 = WS 会话（poll 可驱动）`、`4 = WS 分派中（Mojo 处理一条
  消息，本 conn 暂停 pump）`；HTTP 阶段 2 同样加入 pump 守卫
  （`phase 2/4 -> 不做 I/O`）。
- conn 内 WS 状态：`ws_path`（upgrade 时存 path，供逐消息查路由）、
  `ws_reasm`（惰性 1MB+1 缓冲，即消息载荷存储）、`ws_par`（解析器）、
  `ws_opcode/ws_mlen`（待处理消息）、`ws_strikes`（保活计数）。
- `pump_ws_conn`：`MSG_DONTWAIT` 批量 recv → feed →
  **控制帧自动处理**（ping→pong 零拷贝、close→码校验回复+结束、pong→仅计活性）、
  **数据帧**（text 先 UTF-8 校验，非法 close 1007；合法则入事件队列 + phase 4）、
  协议错误 close 1002、EOF/错误入"结束"事件。
- **FIFO 事件队列**（`WS_EV_MAX=1024`）：`{fd, type}`，type 1=消息就绪、
  2=会话结束。`recv_and_parse` 每轮先查队首 —— 队列非空立即返回该事件
  （不 poll），空则走原 poll 循环。FIFO 顺序天然处理 fd 复用（旧 conn 的
  结束事件必在新 conn 的事件之前被 Mojo 消费）。
- **保活移入 poll 循环**（`check_deadlines`，1s tick）：WS conn 空闲超
  `RECV_TIMEOUT` → 发空 ping、`ws_strikes++`；超 `WS_PING_MAX`（默认 3）次
  无客户端数据 → close 1000 + 结束事件；任何客户端数据（含 pong）清零计数。
  语义与 ADR-0007 一致，实现从 Mojo 循环移到 C（零 Mojo 开销）。
- Mojo 面向入口：`ws_event_type()`（0=HTTP 请求 / 1=WS 消息 / 2=WS 结束）、
  `ws_conn_upgrade(fd)`（101 后移交，phase 0→3）、`ws_message_done(fd)`
  （phase 4→3）、`ws_conn_close(fd)`（Mojo 发起结束 + 结束事件）、
  `get_ws_path_slice()`；`ws_last_opcode/ws_payload_slice/ws_write_current/
  ws_write_text/ws_send_close/ws_session_begin` 改为按 active conn（事件所属
  连接）读取。移除：`ws_session_read/ws_session_end/ws_reply_close/
  ws_payload_valid_utf8/ws_write_empty` 与 `g_ws_cur_*` 全局（多会话并发下
  全局即竞态）。
- `conn_done` 对 phase 3/4 的 conn 直接忽略（WS 生命周期归 poll 循环）。

**Mojo（`ws_session.mojo` 重构 + `http_server_final.mojo` 主循环）：**
- `run_ws_upgrade(cfd, handler)`：子协议协商（必需未提供 → 400）+ 101 握手
  + `ws_conn_upgrade` 移交；返回 101 时主循环**不 conn_done**（连接已归
  bridge 驱动）。
- `handle_ws_data(cfd, handler, opcode, state)`：一条数据帧 = 一次显式 FFI
  往返 —— echo 零拷贝回显（`ws_write_current`）/ 其余 handler 解码后经
  `run_ws_message` 单点分派 / text-only handler 收到 binary → close 1003。
- 主循环新增事件分支（`recv_and_parse` 之后）：
  - `ws_event_type == 1`：按 `get_ws_path_slice` 查 WS 路由 →
    `handle_ws_data` → 更新 `ws_state[cfd]` → `ws_message_done(cfd)`。
  - `ws_event_type == 2`：`ws_state.pop(cfd)`（清理连接级状态）。
- 连接级状态：`var ws_state = Dict[Int, Int]()`（fd → 计数器累计值等）。

**e2e 新增（websocket 并发节，3 项）：**
- M14：10 线程并发 WS 会话，各自 echo 往返成功
- M15：**3 个 WS 会话空闲时，HTTP 探针 <1s 完成**（ADR-0008 核心回归；
  旧设计下探针需等待空闲超时，秒级阻塞）
- M16：两个 counter 会话交替消息，连接级 state 互不干扰

## 4. 后果与限制（文档化）

- **进程内 WS 并发达成**：任意数量 WS 会话 + HTTP 请求在单 worker 内并发
  （受 MAX_CONNS=1024 与每连接 1MB 重组缓冲的上限约束）。
- **单条消息处理仍是串行的**（Mojo 单线程 dispatch 固有）：消息 N 的 handler
  执行期间，同连接的消息 N+1 暂停 pump（phase 4），但**其他连接不受影响**。
- **事件队列溢出**（>1024 条未处理事件）：丢弃事件（连接保持打开）。
  正常负载不可达（每连接至多 1 条待处理消息 + 1 条结束事件）。
- **重组缓冲按连接惰性分配**（1MB+1）：大量 WS 连接均收过数据帧时内存
  上界 ≈ 连接数 × 1MB（MAX_CONNS=1024 理论上限 ~1GB；实际受并发约束）。
- **保活粒度**：poll tick = 1s（`POLL_TICK_MS`），ping 发送时刻精度 1s 级
  （ADR-0007 为 recv 超时精度）。
- **单 binary 不变式保持**：无新依赖（ldd 仅 libc）；e2e 74 项全绿。
- **正向影响**：ADR-0007 §后续 第 1 项（高并发 WS）关闭；WS 与 HTTP 共享
  同一 poll 状态机，架构一致性进一步增强；控制帧/保活移出 Mojo 路径，
  高频小帧（ping/pong/close）不再消耗 dispatch 时间。

## 5. 实测教训（本 ADR 实施中验证）

1. **跨帧残留状态 = 越界写**：`mask_got` 未逐帧重置，第二帧的 mask 字节
   写入 `mask[4..7]`（OOB），覆盖结构体相邻字段（`mask_got` 本身），
   导致后续帧解析状态错乱。状态机每个字段的"逐帧/逐消息"生命周期必须
   显式界定并逐帧重置（fin/opcode/masked 在 stage 0/1 覆盖；mask_got/pgot
   在进入 mask/payload 阶段时归零；in_msg/reasm_len/msg_opcode 为消息级）。
2. **分块帧的写入偏移必须含帧内进度**：`dst = reasm_len + pgot`（数据帧）/
   `pgot`（控制帧）。漏掉 `pgot` 会让一个 >8KB 帧的所有块都从偏移 0 互相
   覆盖（76800B binary echo 内容损坏的根因）。
3. **feed 返回后残留字节**：一个 recv 块内含多条消息时，feed 在首条消息
   完成后返回，块内剩余字节由 pump 循环的下一次 recv 自然衔接（socket
   缓冲区语义）——前提是 feed 不吞掉未解析字节（实现为"只消耗已解析部分"
   的 while 循环，剩余在 buf 内继续处理或留给下次 feed）。
4. **fd 复用 × 事件时序**：FIFO 事件队列保证旧 conn 的"结束"事件先于新
   conn（复用 fd）的任何事件被 Mojo 消费 —— 连接级状态清理不会误删新
   连接的 state。
5. **Mojo 1.0.0 Dict 无 `remove`**：用 `pop(key)`（返回值需 `_ =` 丢弃）。

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 方向单向：Mojo(`http_server_final`/`ws_session`) → C(`http_bridge_final.c` 阶段机/事件队列) → C(`ws.c` 解析器/帧写) → OS(socket/poll)。`ws.c` 不引用 bridge 符号（仅 extern 声明由 bridge 持有）；Mojo 不反向 |
| 2. 分层向下依赖 | ✅ 遵守 | 业务（消息分派、连接级 state、子协议选择）在 Mojo；协议（帧/掩码/分片/控制帧语义/close 码/UTF-8/保活策略执行）在 C（`ws.c` 解析 + bridge 阶段机内联）；socket I/O/poll 在 C 桥接层。保活是"策略参数 + 协议动作"（发空 ping 帧、回 close 1000），无业务判断，归 C 合理 |
| 3. God package 阈值 | ✅ 遵守 | `.mojo` 均 < 500 行：`http_server_final.mojo` 364、`ws_session.mojo` 76、`handler.mojo` 303、`router.mojo` 259；C 侧：`ws.c` 366（状态机替换阻塞读）、`http_bridge_final.c` 1529（阶段/事件队列/pump_ws_conn/保活）—— C 文件 500 行阈值不适用于 `.c`（AGENTS.md §3.2 仅约束 `.mojo`） |
| 4. 主题域边界清晰 | ✅ 遵守 | `ws.c` 仅 RFC 6455 解析/帧原语；bridge 的 WS 代码集中在"WS 阶段机 + 事件队列"两个注释块；`ws_session.mojo` 仅 upgrade 移交与单消息分派（不碰 poll）；HTTP 路径零改动（仅 pump 阶段守卫 + conn_done 守卫两处一行级保护） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | 无隐式回调：Mojo 主动取事件（`recv_and_parse` + `ws_event_type`）并显式回复（`ws_write_*`/`ws_message_done`/`ws_conn_close`）；事件是数据（fd+type），不是函数调用；控制帧自动处理是**协议层**行为（ping/pong/close 无语义负载），不属业务回调 |
| 6. 测试文件跟随 | ✅ 遵守 | e2e 新增并发节 3 项（M14 十并发 / M15 空闲不阻塞 / M16 state 隔离）+ 原 15 项 WS 检查全部回归通过（74 项总）；解析器正确性由 e2e 全量帧形态覆盖（7-bit/16-bit/64-bit 长度、分片、掩码、控制帧交错、大帧分块） |

## 7. 验证方式

1. **单元**：`mojo run` 各模块自检 + `test_all.mojo`（WS 节：子协议/计数器/
   路由）全绿。
2. **e2e（74 项，CI 可重复）**：原 71 项（含 ADR-0007 全部 15 项 WS）回归
   通过 + 新 3 项并发检查。重点：M15 在 e2e 环境（RECV_TIMEOUT=2s）下，
   3 个空闲 WS 会话期间 HTTP 探针 <1s —— 旧设计该场景探针阻塞 2s+。
3. **专项大帧验证**（实施期）：76800B binary 单帧（64-bit 长度，跨 ~9 个
   8KB recv 块）、80000B 两分片、30000×3 三分片 text —— 全部逐字节回显
   一致（修复 §5 教训 2 后）。
4. **单 binary 不变式**：`./build_single.sh` 成功（2.2M）；`ldd` 仅 libc +
   内核组件；`env -i` 干净环境启动 + `/health` 正常。
