# ADR-0026: WebSocket 精化 — close(code,reason) / exception_handler / send_bytes / send_json（声明式 _ws_* 指令 + close-wait phase 5）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #23 落地）
- **关联**：AGENTS.md §3/§6（**决策-51**）、Goal-0003（P2 矩阵 #23：
  WebSocket 进阶 — close(code)/exception_handler/send_text/bytes/json）、
  North Star（Mojo + Rust only 单 binary 零依赖 — ldd = 仅 libc）、
  ADR-0004（声明式 handler.data 范式）、ADR-0006~0009（WS 全链路既有
  架构：poll 驱动会话 / FIFO 事件 / 单点 dispatch）、决策-49（异常 tag
  约定 + 声明式处理表先例）、决策-50（`_reads_*`/注册期校验/check_*
  specs 范式）、FastAPI 0.141.1 + starlette 1.6.0 + uvicorn 0.52.4 +
  wsproto 1.3.2（/tmp/exch_probe p23/p23h/p23i 逐条 probe + 源码核对，
  本 ADR §1 证据）

## 1. 背景

Goal-0003 矩阵 #23：WebSocket 进阶面 = `close(code, reason)` /
`exception_handler`（`WebSocketException`）/ `send_text` / `send_bytes` /
`send_json`。本仓库已有 WS 全链路（ADR-0006~0009：RFC 6455 握手 /
帧解析 / 子协议 / 鉴权 / poll 驱动会话 / FIFO 事件 / `{param}` 路由 /
合并帧 / NUL 安全 / UTF-8 校验 / 保活 ping / close 码校验回复），缺口 =
**服务端主动关闭（带 code + reason）**、**异常路径（无 close 帧 / 带
close 帧）**、**二进制回复**、**compact JSON 回复**。

**上游实测证据（uvicorn 0.52.4 (wsproto 1.3.2) + starlette 1.6.0 活体
probe，/tmp/exch_probe p23/p23h/p23i；源码行号引自同一环境）**：

- **P23-1 `close(code, reason)`（P23-1/2/4 三例）**：starlette
  `WebSocket.close(code=1000, reason=None)`（websockets.py:180）=
  `send({"type":"websocket.close","code":code,"reason":reason or ""})`
  — **starlette 层零 code 校验**（uvicorn/wsproto 做）。uvicorn
  wsproto_impl `send()`（close 分支 ~L463）：`close_sent=True` +
  `conn.send(CloseConnection(code, reason))` 发 close 帧 +
  **`close_timer = call_later(10.0, transport.close)`**（L104 硬编码
  10.0s）。实测：`close(1000,"bye")` → 客户端 TEXT `got` → CLOSE 1000
  reason `bye` → **TCP 恰好 10.00s 后 EOF**；`close(4001,"custom
  reason")`（无回复）→ CLOSE 4001 `custom reason` → 10.00s EOF。
- **P23-3 未处理异常**：endpoint `raise RuntimeError("kaboom")` →
  uvicorn `run_asgi`（L362-376）`except BaseException:` →
  `logger.exception("Exception in ASGI application\n")` +
  `send_500_response()`（handshake 后 no-op）→ `close_timer is None`
  → **立即 `transport.close()`**。实测：服务端完整 traceback；客户端
  **无 close 帧，立即 TCP EOF（= 1006）**。
- **P23-4 `WebSocketException(code, reason)`**：starlette
  `wrap_app_handling_exceptions` 按 session 注册表捕获（routing.py
  `websocket_session` 内层 wrap）→ `websocket.close(code=exc.code,
  reason=exc.reason)` → **wire 行为与显式 close 完全相同**（close
  帧 + 10s close-wait）；差异仅在服务端异常路径/日志。
  实测：CLOSE 4002 `ws-exc` → 10.00s EOF。
- **P23-5 `send_bytes`**：BINARY 帧逐字节（含 NUL + 0xFF）。
  starlette 1.6.0 `websocket_session`（routing.py:70-84）**endpoint
  返回后无 post-endpoint close**（旧版曾有 `session.close()`，1.6.0
  已移除）→ uvicorn `run_asgi` `close_timer is None → transport.
  close()` → **endpoint 返回 = 连接立即关闭（无 close 帧）**。
  实测：BINARY 后 **立即 EOF**（p23h P23-5b 复核）。
- **P23-6 `send_json`**：TEXT 帧，**compact JSON 原始 UTF-8**（
  websockets.py:171：`json.dumps(data, separators=(",",":"),
  ensure_ascii=False)`，无 allow_nan 参数）。实测：
  `{"a":1,"b":"中文","c":[1,2]}`（中文为原始 UTF-8 字节）。
- **P23-7 close-wait 提前结束**：close-wait 期间收到**客户端 close
  回显** → uvicorn `handle_close`（L273-283）`close_sent` 分支：
  **不回显 close**（已发过）→ **cancel close_timer + 立即
  transport.close()**。实测：回显后 TCP **立即 EOF（0.00s）**，非
  10s。
- **p23i close-wait 边缘（uvicorn 0.52.4 实测）**：
  - **A 数据帧**：close-wait 期间收到 text → **丢弃，连接保持打开**
    （3s+ 仍 open；uvicorn `handle_events` L179-183：`close_sent` 时
    非 Close 事件全部 `continue`）；
  - **B/C 非法 close 码**（999 / 1006）：→ **立即静默 close，无 close
    帧**（wsproto `_process_close` 对非法码抛 `ParseFailed(1002)`，
    `events()` yield `CloseConnection(1002, …)`，uvicorn close_sent
    分支同样不回显只 close）；
  - **D ping**：close-wait 期间收到 ping → **丢弃（不回 pong）**，
    10.00s 定时器 close（`send_keepalive_ping`/`handle_events` 对
    `close_sent` 均短路）；
  - **E OPEN 态客户端 close**（既有 ADR-0009 行为）：echo close +
    立即 close（uvicorn `handle_close` 非 close_sent 分支：
    `REMOTE_CLOSING → event.response()` 回显 + `transport.close()`
    立即）— **既有实现已 parity，本 ADR 不动**。
- **wsproto 1.3.2 close 语义（frame_protocol.py）**：
  - **发送侧 `close(code, reason)`（L589-612）**：`code=1005`（
    NO_STATUS_RCVD）→ 无 payload close 帧；`code in
    LOCAL_ONLY_CLOSE_REASONS`（1004/1006）→ **改写 1000**；
    **无 range 检查**（其他 code 原样 pack）；`code is None and
    reason` → **TypeError**；reason UTF-8 **截断 123 字节**
    （125−2，`_truncate_utf8` codepoint 安全）。
  - **接收侧 `_process_close`（L514-553）**：空 payload → 1005；
    1 字节 → ParseFailed；code 不在 1000-4999 → ParseFailed；
    1004/1006（local-only）→ ParseFailed；**未注册且 ≤1015**
    （1005 之外）→ ParseFailed；即合法接收码 = {1000,1001,1002,
    1003,1007-1015} ∪ [3000,4999]；reason 非 UTF-8 →
    ParseFailed(1007)。

**约束（声明式范式）**：Mojo 无用户代码面 — 上游「endpoint 内
`await ws.close(...)` / `raise` / `send_*`」在声明式世界 = **路由级
声明指令**（handler.data）；语义落点 = ADR-0007/8 既定的
`handle_ws_data` 单点 dispatch 扩展点（每消息）。close-wait 需要
**poll 循环侧新阶段**（phase 5：close 帧已发、等回显/超时）—
bridge 承载（timer/状态机是系统级 I/O，分层必须 bridge；Mojo 只
声明意图）。

## 2. 候选方案

- **A. Rust bridge 全承载（close 语义 + 异常处理全在 bridge）**：
  ❌ 业务语义（哪个路由 close 什么 code/异常 message）是路由声明
  数据，放 bridge 违反分层向下依赖（同 ADR-0024/0025 论证）；bridge
  只能承载「close-wait 状态机」这种纯 I/O/时序原语。
- **B. 声明式 `_ws_*` 指令（Mojo）+ 最小 FFI（close-wait 状态机
  原语，Rust）**（✅ 采纳）：
  - Mojo 声明：`_ws_close` / `_ws_exc_close` / `_ws_raise` /
    `_ws_binary` / `_ws_json`（ADR-0004 范式；决策-49 `_exception_
    raise` / 决策-50 `_state_set` 同款「路由 data 承载意图」）；
  - bridge 新增 3 个 FFI 原语：`ws_send_close_reason`（code +
    reason → close 帧，wsproto 规范化）/ `ws_write_binary` /
    `ws_write_current_binary`（NUL 安全二进制帧）/ `ws_set_closing`
    （进 phase 5 close-wait）+ env 读取（`FASTAPI_MOJO_WS_CLOSE_
    WAIT`，`get_ws_ping_max` 同款 AtomicI32 sentinel 一次性缓存）；
  - phase 5 状态机 = bridge `pump_ws_closing`（丢数据/ping、close
    回显 → 静默 close、EOF/协议错误/超时 → 静默 close，uvicorn
    parity，§1 p23i）。
- **C. 仅 wire 层补 close 帧（不做 close-wait，发完 close 立即
  断 TCP）**：❌ 破坏 P23-1/4 parity（uvicorn 保持 10s close-wait；
  客户端 close 回显有真实用途 — 提前结束、半开连接快速回收）；
  且 P23-7 提前结束语义无法表达。

## 3. 决策

### 3.1 声明式指令（handler.data，每消息评估，`handle_ws_data`）

| key | 形 | 语义（每收到一条数据帧） |
|-----|----|--------------------------|
| `_ws_raise` | `"msg"` | **无回复**；server log `[ws-exc] <route>: <msg>`；**TCP close，无 close 帧**（客户端 1006 — P23-3 parity） |
| `_ws_exc_close` | `"CODE[:REASON]"` | **无回复**；log 同上；**close 帧 (code, reason) + close-wait**（WebSocketException parity，P23-4） |
| `_ws_close` | `"CODE[:REASON]"` | **正常回复后**发 close 帧 (code, reason) + close-wait（`close(code, reason)` parity，P23-1/2） |
| `_ws_binary` | `"1"` | 回复改 **BINARY 帧**（opcode 2）发送（send_bytes parity；正交于上述三者） |
| `_ws_json` | `"<JSON 文本>"` | 回复 = 该 JSON 模板（TEXT 帧，原样发送 — send_json parity，§3.5-1） |

**优先级（同一消息）**：`_ws_raise` > `_ws_exc_close` > `_ws_close`
（前两 pre-reply：跳过回复直接走关闭路径；`_ws_close` post-reply）。
`_ws_binary` 正交（修饰回复帧类型）。`run_ws_message` **签名不变**
（三元组返回）— 指令处理全在 `handle_ws_data`（决策-49 dispatch
guard 同款模式）。

**close code 合法集（注册期校验，wsproto 接收侧合法集）**：
{1000,1001,1002,1003,1007,1008,1009,1010,1011,1012,1013,1014,1015} ∪
[3000,4999]；**1004/1005/1006 拒绝**（RFC local-only，MUST NOT 置入
close 帧 — wsproto 发送侧对三者有静默改写，注册期显式拒绝更可预期，
§3.5 偏差）；`"CODE:REASON"` 首个 `:` 切分（reason 可再含 `:`）；
**reason-without-code（`":msg"`）= 注册错误**（wsproto 发送侧
TypeError parity）；code 解析失败/越界 = 注册错误。

### 3.2 close-wait（bridge phase 5）

- **新 Conn 字段** `ws_close_at: i64`（0 = 非 close-wait；否则进入
  phase 5 的 ms 时间戳）。`Conn::phase` 语义扩展：
  **5 = WS close-wait**（close 帧已发，等回显/超时/EOF）。
- **`ws_set_closing(fd)`（新 FFI）**：调用方（Mojo）已发 close 帧；
  设 `phase=5` + `ws_close_at=now_ms()`；env `FASTAPI_MOJO_WS_CLOSE_
  WAIT=0` 时直接入队 END 事件 + `reset_for_close`（立即关，无
  二次 close 帧）。
- **env `FASTAPI_MOJO_WS_CLOSE_WAIT`**（默认 **10000ms** = uvicorn
  10.0s 硬编码 parity；0 = 立即关闭）：`get_ws_close_wait_ms()`
  AtomicI32 sentinel 一次性缓存（`get_ws_ping_max` 同款，ws_session_
  ffi.rs）。
- **phase 5 pump（`pump_ws_closing`，io.rs）**（uvicorn 0.52.4
  parity，§1 p23i A/B/C/D）：
  - 数据帧 → **丢弃**（parser 已重置 reasm，不入队、不 UTF-8 校验
    close、不回复）；
  - ping → **丢弃（不回 pong）**；pong → no-op；
  - **任何 close 帧（合法或非法码）→ 静默 close**（END 事件 +
    `reset_for_close`，**不回显** — close 已发，uvicorn handle_close
    close_sent 分支不回显；非法码的 ParseFailed(1002) 也走同一路径）；
  - **EOF → 静默 close**；**协议错误 → 静默 close**（§3.5-6d 偏差：
    uvicorn 对 parse 级 RemoteProtocolError 发 1002/1007 提示帧再
    close，本实现不发）；
  - **超时**（`check_deadlines` 1s tick → 新
    `DeadlineAction::WsCloseWaitTimeout`）：`now - ws_close_at ≥
    close_wait_ms` → END 事件 + `ConnTable::close`（静默，不发
    close 帧）。
- **phase 5 不受**既有 phase-3 保活（ping/`ws_strikes`）与
  phase-0/1 idle/408 逻辑影响（`decide()` 新增 phase-5 分支前置短路）；
  `conn_done` / `ws_pump_now` 对 phase 5 保持 no-op（前者跳过、后者
  只泵 phase 3 — 既有行为天然兼容）。

### 3.3 新 FFI（Rust staticlib，C ABI；FFI diff = +5 导出）

| 导出 | 签名 | 说明 |
|------|------|------|
| `ws_send_close_reason` | `(fd, code, reason_cstr) -> int` | close 帧 = 2B code + reason（NUL 串读取；wsproto 规范化：1004/1006→1000、1005→空 payload、reason UTF-8 截断 123B codepoint 安全，ws.rs 纯函数 helper + 单测） |
| `ws_write_binary` | `(fd, data_cstr) -> int` | 回复文本 → BINARY 帧（非 echo handler + `_ws_binary`；NUL-free 数据） |
| `ws_write_current_binary` | `(fd) -> int` | **零拷贝**：待处理消息载荷 → BINARY 帧（NUL 安全，echo + `_ws_binary`，`ws_write_current` 的 opcode-2 版） |
| `ws_set_closing` | `(fd) -> int` | 进 phase 5（§3.2） |

既有 `ws_send_close(fd, code)`（2B 无 reason）保留（1002/1003/1007/
1008/1009 协议路径继续用）。第 5 导出 `get_ws_close_wait_ms()`（表
外，测试/诊断用；Mojo 侧不需要值 — `ws_set_closing` 内部自读 env）。
本决策 FFI diff = +5（4 上表 + 1 env 访问器），与 `git diff ffi.rs`
核对一致。

### 3.4 demo 路由（http_server_final.mojo，P23 六场景全覆盖）

`/ws/close`（echo + `_ws_close = "1000:bye"`，P23-1）/
`/ws/close/4001`（echo + `_ws_close = "4001:custom reason"`，P23-2）/
`/ws-exc/boom`（`_ws_raise = "kaboom"`，P23-3）/ `/ws-exc/close`
（`_ws_exc_close = "4002:ws-exc"`，P23-4）/ `/ws/bin`（echo +
`_ws_binary = "1"`，P23-5 的 UTF-8 等价 — NUL 保留，§3.5-5）/
`/ws/json`（`_ws_json = "{\"a\":1,\"b\":\"中文\",\"c\":[1,2]}"`，
P23-6 compact 原始 UTF-8 逐字节）。

### 3.5 文档化偏差（vs 上游 FastAPI 0.141.1 / starlette 1.6.0 /
uvicorn 0.52.4）

| # | 上游 | 本实现 | 定性 |
|---|------|--------|------|
| 1 | `send_json(data)` = 运行期 `json.dumps(data, separators=(",",":"), ensure_ascii=False)`（websockets.py:171） | `_ws_json = "<模板>"` 原样 TEXT 帧发送 | **偏差（声明式等价）**：「对象」= 声明的 JSON 文本本身；compactness/合法 JSON 为声明者责任（注册期不验证 JSON 语法 — 纯 Mojo 路径无 JSON parser，json.mojo 仅序列化） |
| 2 | uvicorn `close_timeout = 10.0` 硬编码（wsproto_impl.py:104，asyncio 精确定时器） | env `FASTAPI_MOJO_WS_CLOSE_WAIT`（默认 10000ms；0 = 立即关），**分辨率 = 1s poll tick**（check_deadlines 周期） | **偏差（可配置超集 + 粒度）**：默认值/语义 = parity；0=立即为超集；实际关闭时刻 ∈ [wait, wait+1s) |
| 3 | endpoint 内 `close()/raise/send_*`（用户代码） | 路由声明 `_ws_*` 指令，每消息评估 | **偏差（声明式范式，ADR-0004）**：无用户代码面；每消息语义（ADR-0007/8 会话循环）vs 上游每连接 endpoint 生命周期 |
| 4 | 上游 starlette 1.6.0 `websocket_session` **endpoint 返回后无 close** → `run_asgi` `close_timer is None → transport.close()` = **endpoint 返回即断（无 close 帧）**（P23-5/6 实测） | `/ws/bin` `/ws/json` 回复后**会话继续**（可继续收消息） | **偏差（会话生命周期，ADR-0007/8 既有）**：声明式每消息模型 = 长连接可复用（与上游「一轮一问」不同；既有 WS 路由同款偏差，本 ADR 显式记录于 #23 行） |
| 5 | `send_bytes(b"...")` 任意字节（含非 UTF-8，如 0xFF） | `_ws_binary` 回复字节 = 回复文本的 UTF-8 编码（echo 路径 = 原样载荷零拷贝，含 NUL） | **偏差（值域收窄）**：声明式模板 = UTF-8 文本；任意非 UTF-8 字节不可表达（NUL 保留 — `ws_write_current_binary` 零拷贝 + e2e W5 守护） |
| 6 | close-wait 期间 parse 级协议错误（RemoteProtocolError）→ 发 1002/1007 **提示 close 帧**再 close | phase 5 协议错误 → **静默 close（不发帧）** | **偏差（极端边缘简化）**：close 已发、连接正在关闭；提示帧无信息增益（客户端已处于 CLOSING）；合法/非法 close 码均静默 close = uvicorn parity（p23i B/C） |
| 7 | `WebSocketException(code, reason)` / 任意 Python 异常类 | `_ws_raise` / `_ws_exc_close` = **字符串**（tag/message，决策-49 同款；无类/MRO — Mojo 异常面仅 `Error`） | **偏差（类型面收窄，决策-49 同款论证）**：wire 行为 parity（P23-3/4）；服务端日志 `[ws-exc] <route>: <msg>` 线形模拟 uvicorn "Exception in ASGI application" + traceback（Mojo 无 traceback 机制） |

## 4. 风险

- **R1 close-wait 超时粒度**：1s poll tick → 实际关闭 ∈ [wait,
  wait+1s)；uvicorn 精确 10.0s。e2e 断言用宽区间（1.2s ≤ t ≤
  3.5s @ 2000ms 配置）吸收粒度。
- **R2 close-wait 期大数据帧**：帧序在 close 前的数据帧会先被
  parser 重组（缓冲按需增长 ≤1MB，与 phase 3 同款上限）后才见
  close — 有界，连接关闭即释放（`reset_for_close`）。
- **R3 env 一次性读取**：进程内 `FASTAPI_MOJO_WS_CLOSE_WAIT` 改
  值不生效（`get_ws_ping_max` 同款 sentinel 语义，文档化）。
- **R4 reason 截断**：>123B 的 reason 按 codepoint 边界截断
  （wsproto parity）— 声明者应自行控制长度。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`ws_session → {ws_directives, handler}`；`ws_directives → {router, handler}`（纯解析/校验）；`http_server_final → ws_directives`（注册期 check）；bridge 模块树 `io → {conn, ws, ws_session_ffi}` 既有方向不变 |
| 2. 分层向下依赖 | ✅ 遵守 | 业务意图（哪个路由 close/raise/回复类型）= Mojo 声明；bridge 只承载 close-wait 状态机（timer/阶段/静默 close = 系统级 I/O 时序，必须 bridge）+ close 帧规范化（wsproto 语义移植）；FFI diff = +4 导出（无新 crate、无新依赖、零 libm） |
| 3. God package 阈值 | ✅ 遵守 | 新 `ws_directives.mojo`（<500）+ `ws_directives_selftest.mojo`；`ws_session.mojo` 101 → ~150；`http_server_final.mojo` 1551 → ~1600（既有超阈值 — ADR-0023/0024/0025 已标注，本决策 +5 demo 路由 + 1 check 调用）；Rust：`ws.rs` 392 → ~455、`ws_session_ffi.rs` 370 → ~440、`io.rs` +~90（均 <500 或标注） |
| 4. 主题域边界清晰 | ✅ 遵守 | WS 精化 = 既有 WS 域内扩展（`handle_ws_data` 单点扩展点，ADR-0007 既定）；HTTP dispatch / F1-F11 / 静态 / 中间件零改动；既有 M1..M21 WS e2e 全保留 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | ldd 保持仅 libc（+4 FFI 全在本 crate，无新符号依赖）；`find src -name '*.c'` = 0 保持；`build_single.sh` 链接线不变（staticlib 整体重链）；binary ≤4.2M 门禁实测 |
| 6. 测试文件跟随 | ✅ 遵守 | `ws_directives_selftest.mojo`（JIT 纯逻辑：spec 解析/合法集/TypeError parity/注册校验）+ ws.rs close-payload 单测（RFC 向量 + 1004/1005/1006 改写 + 123B codepoint 截断）+ deadlines phase-5 单测 + e2e `W1..W8`（fmtool ws5 新子命令）+ e2e shell 块 — 全部与生产代码同目录 |

## 7. 验证方式（实测 2026-09-10）

1. **单 binary 不变式**：`ldd build/fastapi_mojo` = 仅 libc；binary
   **3,733,504 B**（3.7M ≤ 4.2M，vs 决策-50 基线 3,700,736 B +33 KB —
   新 FFI 导出 + phase-5 状态字段）；`env -i` 干净启动（`/health`
   JSON 200 healthy，§3.5 warm-up 协议：等 listener + sleep 5 + 验
   真实 server 响应体）；`find src -name '*.c'` = 0；`find . -name
   '*.py'`（excl .git/docs）= 0；`pgrep -x fastapi_mojo` = 0（SIGTERM
   优雅关停 ~5s：close-wait 定时器排空 + atexit 清理，随后自行退出）。
2. **质量门禁**：`cargo test --release -- --test-threads=1`
   (fastapi_mojo_rs) = **431 passed / 0 failed / 4 ignored**（+22 新：
   ws.rs close_reason_payload ×8（含 1005 无 payload / 1004-1006 改写 /
   ASCII + 3/4 字节截断回退）+ deadlines phase-5 ×4（超时/未超时/无
   close_at/zero-wait）+ ws_session_ffi ×10（close 帧内容/截断/
   write_binary/zero-copy NUL 安全/set_closing phase-5/unknown fd/
   zero-wait 立即关/env 只读一次））；fmtool `cargo test` = 0 测试
   exit 0；`cargo clippy --release --tests -- -D warnings` 双 crate =
   **0 警告**；`mojo run ws_directives_selftest.mojo` = all checks
   passed（0 警告）；`ws_session.mojo` 独立 `--emit object` = 0 警告
   （4 处 docstring summary 以 ASCII `.` 收尾 — Mojo 1.0.0 的
   docstring lint 仅对 primary target 生效，见 §4 环境注记）。
3. **e2e**：373 → **383/383 全绿**（+W1..W10，§3.4 演示路由实测：
   W1 回复后 close 1000 "bye" + close 回显提前结束 <1s；W2 无回复
   close 4001 "custom reason" + close-wait 保持 ∈ [1s,4s)（2s 配置）；
   W3 未处理异常**无 close 帧**立即 EOF（1006 parity）<1s；W4
   WebSocketException close 4002 "ws-exc"；W5 binary NUL 保留
   往返；W6 compact JSON（`separators=(",",":"), ensure_ascii=False`
   逐字节含 UTF-8 中文）；W7 close-wait 期间 ping 丢弃（无 pong）；
   W8 close-wait 期间数据丢弃（无回复）；W9/W10 server log
   `[ws-exc] ws_exc_boom: kaboom` / `[ws-exc] ws_exc_close: 4002:ws-exc`）。
4. **性能**：bench 6 场景 **0 errors**；**get_root_10k_100c =
   34,880 req/s**（32.9k–43.9k 区间内，vs 决策-50 32,938 — 噪声带内，
   无退化）；RSS 平台化无线性泄漏（WS 会话状态复用既有 conn 表，
   phase 5 仅增 2 字段）。
5. **环境注记**：
   - Mojo 1.0.0 docstring-summary lint 只对 `mojo build` 的 primary
     target 生效（imported 文件不报）— 故 ws_session.mojo 此前作为
     imported 文件的 3 处 `。` 结尾 summary 从未暴露；本次作为
     primary 编译时全部暴露并已修为 ASCII `.`。
   - Rust `Mutex` 不可重入：2 个单测曾因持 guard 调自锁函数死锁
     （`futex_do_wait`）— 已改 `{}` 作用域先放锁再调用；历史残留的
     死锁测试进程（旧 binary, etime 33min）已 kill -9 清理。
   - `ws_send_close_reason` 内部 256B 栈缓冲 + NUL 终止契约（决策-20）；
     实施中 2 个单测断言笔误（raw[4..125] 应为 raw[4..127]；3 字节
     NUL payload 误写 4 字节目标）已修 — 实现无改动。
   - 实施修正：`_ws_json` 最初仅接在非 echo 路径，smoke 发现 echo
     路径（KIND_WS_ECHO + `_ws_json`）仍回显 — 已修（echo 路径
     `_ws_json` 优先，TEXT 帧发 JSON 模板），与 §3.1 语义一致。
   - FMTOOL `ws5` 新子命令（10 检查）；e2e 主 server env 新增
     `FASTAPI_MOJO_WS_CLOSE_WAIT=2000`（默认 10000 = uvicorn parity）。
   - 透明代理 warm-up 协议（§3.5）沿用既有 e2e/fmtool 实现，本决策
     无基础设施改动；CI 干净环境仅多等 5s。
