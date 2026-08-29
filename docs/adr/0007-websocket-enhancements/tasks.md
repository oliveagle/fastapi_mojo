# ADR-0007: WebSocket 增强 — 任务清单

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | ADR-0007（候选方案对比 + 6 条隔离约束 + FFI 实测教训 + 验证方式） | ✅ 完成 | `docs/adr/0007-websocket-enhancements/01-decisions.md` |
| 2 | `ws.c`：`ws_read_message` 超时细分（0/-1/-2，帧中途不可重试） | ✅ 完成 | e2e M10 保活 ping 在空闲超时后发出；M1-M6 回归通过 |
| 3 | `ws.c`：`ws_handshake` 支持 subprotocol 头（RFC 6455 §4.1） | ✅ 完成 | e2e M7：101 含 `Sec-WebSocket-Protocol: chat` |
| 4 | `ws.c`：`ws_parse_close_code`（§7.4.1）+ `ws_validate_utf8`（§5.6） | ✅ 完成 | e2e M11（1005→1002）、M12（bad UTF-8→1007）、M13（4000+reason 回显） |
| 5 | `ws.c`：移除 C 内 `ws_upgrade_and_echo` 循环 | ✅ 完成 | 符号消失于 binary；e2e 全量 71 项通过（无回归） |
| 6 | `http_bridge_final.c`：会话状态 + 包装函数（begin/read/payload/write_current/write_text/write_empty/reply_close/send_close/end/protocol_slice/ping_max） | ✅ 完成 | 编译无警告；FFI 形态约束注释在函数头（§5） |
| 7 | `router.mojo`：`WsRoute`/`add_ws_route`/`match_ws_route`（精确匹配 v1） | ✅ 完成 | `mojo run router.mojo` 自检 + `test_all` WS 路由 3 例 |
| 8 | `handler.mojo`：`KIND_WS_ECHO`/`KIND_WS_COUNTER` + `run_ws_message` 单点 dispatch | ✅ 完成 | `test_all` 计数器 6 例 + echo + 未知 kind |
| 9 | `ws_session.mojo`：Mojo 驱动会话循环（子协议 400 / 保活 ping / 控制帧 / text UTF-8 / binary 1003） | ✅ 完成 | e2e M7-M12；单文件 103 行（<500） |
| 10 | `http_server_final.mojo`：WS 分支改为路由查表 + `run_ws_session`；注册 `/ws`、`/ws/counter`、`/ws/chat`；`/routes` 含 WS 条目 | ✅ 完成 | 334 行（<500）；env -i 下 `/routes` 输出 3 条 `WS /path` |
| 11 | 单元 + e2e：`test_all` WS 节；e2e websocket 节 7 → 15 项 | ✅ 完成 | e2e result: 71 passed, 0 failed |
| 12 | 文档：README（路由表/架构图/路线图）+ AGENTS.md（决策-16）+ CI 计数（63→71） | ✅ 完成 | 见 commit |

## 后续（不在本 ADR 范围，需新 ADR）

- ~~**高并发 WS**（ADR-0006 §后续 第 2 项）~~ → ✅ **已由 ADR-0008 落地**
  （poll 循环驱动 + FIFO 事件队列 + 控制帧/保活 C 层自动处理；worker 级
  分摊仍由 ADR-0005 提供）
- WS 路由 `{param}` pattern 匹配
- 鉴权（WS 升级头/首帧 token 校验）
- 多字节 NUL 文本回复（binary 帧承载或 C 侧 len 传递协议修订）
