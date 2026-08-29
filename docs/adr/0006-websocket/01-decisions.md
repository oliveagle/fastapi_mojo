# ADR-0006: WebSocket (RFC 6455) 支持 — C FFI 协议层 + /ws echo 端点

- **日期**：2026-08-29
- **状态**：✅ 已接受（部分被 **ADR-0007** 取代：单一端点/无保活/无 subprotocol 限制已解除，见 §4 注）
- **决策者**：oliveagle（agent 执行）
- **关联**：ADR-0001（C5 经 C FFI 绕过 Mojo 无网络模块）、ADR-0003（单 binary 机制）、
  `ws.c`（RFC 6455 协议层）、`http_bridge_final.c`（升级头检测）、
  `http_server_final.mojo`（/ws 分支）、`scripts/e2e_test.sh`（websocket 节）、README 路线图

## 1. 背景

README 路线图中唯一未勾选的项是「WebSocket 支持（待 Mojo 网络生态成熟）」。
此前将其推迟的假设是：Mojo 1.0.0 无 `std.net`/`std.socket`，WebSocket 无法实现。

但本项目的 HTTP 服务器本身已经用 **C FFI 桥接**（ADR-0001 C5）绕过了"Mojo 无网络
模块"这一约束——socket I/O 在 C 层，协议语义在 Mojo 层。WebSocket 与 HTTP 同属
"线路协议"，完全可以复用同一模式：C 层做 RFC 6455 协议（握手 + 帧），Mojo 层做
路由决策（是否 /ws + 升级头）。因此"等待生态成熟"并非硬阻塞，而是一个可现在落地的
设计选择。

本 ADR 记录该决策：以 C FFI 方式提供**最小可用**的 WebSocket echo 端点（`/ws`），
打通 RFC 6455 的握手、帧编解码（掩码 / 7|16|64-bit 长度 / 分片重组）、控制帧
（ping/pong/close），并给出完整的单元 + e2e 验证。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 等待 Mojo 原生网络模块 | 维持现状，Mojo `std.net`/WS 成熟后再做 | 无时间表；与 C5 的既有绕过模式不一致；阻塞路线图最后一项 |
| B. **C FFI 协议层 + /ws echo（本 ADR）** | 握手/帧/echo 在 `ws.c`（纯 C、零依赖）；路由决策在 Mojo；复用 ADR-0001 的 C5 模式 | ✅ 与现有架构一致；现在即可落地；自包含、可测试 |
| C. 在 C 层做完整 WS 库（含业务回调） | C 层暴露通用 WS server + Mojo 回调 | 引入隐式回调（违反 §3.5 显式 bridge 约束）；过度设计（当前只需 echo） |

## 3. 决策

采用 **方案 B**：
- 新增 `src/fastapi_mojo/ws.c`（~256 行，纯 C、零依赖）：SHA-1、base64、
  `Sec-WebSocket-Accept` 计算、帧读（掩码 + 7|16|64-bit 长度 + 分片重组）、
  帧写（未掩码）、101 握手、`ws_upgrade_and_echo()` 最小 echo 会话
  （text/binary 回显、ping→pong、close→close）。
- `http_bridge_final.c` 仅新增**升级头检测**（`is_ws_upgrade()` +
  `get_ws_key_slice()`）——复用既有 header 解析，不做协议。
- `http_server_final.mojo` 在 OPTIONS 分支后新增一个 `elif`：`path == "/ws"` 且
  `is_ws_upgrade()` 为真 → 调 `ws_upgrade_and_echo(cfd, key)` → `conn_done(cfd, False)`。
  非升级的 `GET /ws` 落回路由表 → 404。
- 构建：`build_single.sh` 编译并链接 `ws.c`（`ws.o`）。单一 binary、零运行期依赖不变。

## 4. 后果与限制（文档化）

- **单一端点**：仅 `/ws`，且为 echo（回显）。不是通用 WS 路由注册；后续扩展
  （多端点 / 业务消息）需新增 ADR。~~（已由 ADR-0007 落地：多端点 + 子协议 + 保活，
  C 内 `ws_upgrade_and_echo` 循环已移除，会话改由 Mojo 驱动）~~
- **消息上限 1 MB**：与 HTTP body 上限一致（`WS_MAX_MSG`）。超限帧丢弃连接。
- **空闲断开**：WS 连接受 socket `SO_RCVTIMEO`（`FASTAPI_MOJO_RECV_TIMEOUT`，默认 5s）
  约束——帧间隔超过该值即断开。客户端可用 **ping 帧保活**（服务端回 pong）。
- **握手校验**：校验 `Upgrade: websocket` + `Connection` 含 `upgrade` + 非空
  `Sec-WebSocket-Key`；**不强制** `Sec-WebSocket-Version: 13`（最小端点）。
- **并发模型**：WS 会话期间，Mojo 单线程 dispatch 被占用（v11 既有"一次一个请求
  分派"限制）；其他连接的 I/O 在会话内不被 poll 服务，可能触发其超时。对 echo
  端点与 e2e 可接受；高并发 WS 需后续 ADR（worker 级 WS 或 C 层独立 poll）。
- **无 subprotocol / 无鉴权**：最小实现，未处理 `Sec-WebSocket-Protocol` 与认证。
  ~~（subprotocol 已由 ADR-0007 落地；鉴权仍待新 ADR）~~
- **正向影响**：路线图最后一项关闭；WebSocket 与 HTTP 共享同一 C FFI 桥接哲学，
  架构一致性增强。

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 方向单向：Mojo(`http_server_final`) → C(`is_ws_upgrade`/`get_ws_key_slice`/`ws_upgrade_and_echo`) → OS(socket)。`ws.c` 不 import/链接 Mojo 或 `http_bridge_final.c` 的内部符号；Mojo 不反向 |
| 2. 分层向下依赖 | ✅ 遵守 | 业务决策（是否 WS）在 Mojo 层；RFC 6455 协议（握手/帧/echo）在 C 协议层(`ws.c`)；socket I/O 在 C 桥接层(`http_bridge_final.c`)。每层只依赖下层 |
| 3. God package 阈值 | ✅ 遵守 | `ws.c` ~256 行（< 500）；`http_bridge_final.c` 增量 ~45 行（仅升级头检测）；`http_server_final.mojo` 308 行（< 500）。无文件越限 |
| 4. 主题域边界清晰 | ✅ 遵守 | `ws.c` 只含 RFC 6455 协议主题（SHA-1/base64/帧/echo），不含连接生命周期（归 `http_bridge_final.c`）、不含路由（归 `router.mojo`）、不含 JSON/静态/CORS |
| 5. bridge/adapter 显式化 | ✅ 遵守 | 唯一入口是显式函数 `ws_upgrade_and_echo(fd, key)`（Mojo 经 `external_call` 调用）；无隐式回调、无字符串魔法；升级判定是显式 `is_ws_upgrade()` |
| 6. 测试文件跟随 | ✅ 遵守 | e2e `scripts/e2e_test.sh` 新增 websocket 节（7 项：握手 RFC 向量 / 文本回显 / 分片重组 / 76800B 大帧 / ping-pong / close / 非升级 404）；协议原语另有 C 单元自检（RFC 6455 §1.3 向量 + socketpair 回环） |

## 6. 验证方式

1. **协议单元自检**（C，socketpair 回环）：
   - RFC 6455 §1.3 握手向量：key `dGhlIHNhbXBsZSBub25jZQ==` → accept
     `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`（与 Python `hashlib` 交叉验证一致）
   - 帧回环：7-bit / 16-bit(300B) / 64-bit(70000B) / 空 payload
   - 掩码分片重组（fin=0 text + fin=1 cont）
   - 掩码控制帧（ping）
   - 完整会话：握手 101 + 文本回显 + ping→pong + close→close（code 1000）+ 子进程干净退出
2. **e2e**（`scripts/e2e_test.sh` websocket 节，CI 可重复）：
   握手 / 文本回显 / 分片重组 / 76800B 大帧 / ping-pong / close / `GET /ws` 非升级 → 404。
   全量 e2e 63 项通过。
3. **单 binary 不变式**：`ldd build/fastapi_mojo` 仍仅 libc + 内核组件；
   `env -i` 干净环境启动正常；`./build_single.sh` 成功（2.1M）。
