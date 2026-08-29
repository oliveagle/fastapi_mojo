# ADR-0006: WebSocket (RFC 6455) — 任务清单

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | ADR-0006（候选方案对比 + 6 条隔离约束 + 验证方式） | ✅ 完成 | `docs/adr/0006-websocket/01-decisions.md` |
| 2 | `ws.c`：SHA-1 + base64 + `ws_compute_accept`（RFC 6455 §4.1） | ✅ 完成 | 协议单元自检：RFC §1.3 向量 `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`（与 Python hashlib 一致） |
| 3 | `ws.c`：帧编解码（掩码 / 7\|16\|64-bit 长度 / 分片重组 / 控制帧） | ✅ 完成 | socketpair 回环：300B(16-bit) + 70000B(64-bit) + 空 + 掩码分片 + ping |
| 4 | `ws.c`：`ws_upgrade_and_echo`（握手 101 + echo/ping-pong/close 会话） | ✅ 完成 | 单元会话：握手 101 + 文本回显 + ping→pong + close(1000) + 子进程干净退出 |
| 5 | `http_bridge_final.c`：`is_ws_upgrade()` + `get_ws_key_slice()`（仅升级头检测） | ✅ 完成 | 编译无警告；e2e 非升级 `GET /ws` → 404 |
| 6 | `http_server_final.mojo`：/ws 分支（OPTIONS 后新增 elif） | ✅ 完成 | 308 行（< 500）；e2e websocket 节通过 |
| 7 | `build_single.sh`：编译 + 链接 `ws.c` | ✅ 完成 | `./build_single.sh` 成功，2.1M 单 binary，ldd 仅 libc |
| 8 | e2e：websocket 节（7 项检查，CI 可重复，stdlib-only Python 客户端） | ✅ 完成 | `scripts/e2e_test.sh`：全量 63 项通过（原 56 + 新 7） |
| 9 | 文档：README（路线图勾选 / 路由表 / 目录 / 架构图）+ AGENTS.md（决策-15） | ✅ 完成 | 见 commit |

## 后续（不在本 ADR 范围，需新 ADR）

- 多 WS 端点 / 业务消息路由（当前仅 /ws echo）
- 高并发 WS（当前 WS 会话占用 Mojo 单线程 dispatch；见 §4 并发模型限制）
- subprotocol（`Sec-WebSocket-Protocol`）/ 鉴权
- 空闲保活策略（当前靠客户端 ping，受 RECV_TIMEOUT 约束）
