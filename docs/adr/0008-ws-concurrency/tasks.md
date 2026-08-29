# ADR-0008: 高并发 WebSocket — 任务清单

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | ADR-0008（候选方案 + 6 约束 + 实测教训 + 验证） | ✅ 完成 | `docs/adr/0008-ws-concurrency/01-decisions.md` |
| 2 | `ws.c`：状态化帧解析器（五阶段状态机/分片重组/控制帧/掩码强制/NUL 结尾） | ✅ 完成 | e2e 全帧形态回归 + 76800B/80000B 分片/30000×3 大帧逐字节一致 |
| 3 | `ws.c`：`ws_reply_close_buf`（任意缓冲 close 码校验回复） | ✅ 完成 | e2e M11/M12/M13 回归 |
| 4 | `ws.c`：移除阻塞式 `ws_read_exact/ws_read_message/ws_free_payload` | ✅ 完成 | 符号消失；e2e 74 项全绿 |
| 5 | bridge：conn 阶段 3/4 + pump 守卫 + `pump_ws_conn`（控制帧/保活/UTF-8 自动处理） | ✅ 完成 | M14 十并发 + M15 探针 <1s + 保活 M10 回归 |
| 6 | bridge：FIFO 事件队列 + `recv_and_parse` 事件优先 + `ws_event_type` | ✅ 完成 | fd 复用时序由 FIFO 保证（§5 教训 4）；e2e 无状态串扰 |
| 7 | bridge：保活移入 `check_deadlines`（WS conn 分支） | ✅ 完成 | e2e M10（RECV_TIMEOUT=2s 下两次 ping + pong 重置） |
| 8 | Mojo：`ws_session.mojo` 重构（`run_ws_upgrade` 移交 + `handle_ws_data` 单消息） | ✅ 完成 | 76 行（<500）；M16 state 隔离 |
| 9 | Mojo：主循环事件分支 + `ws_state` Dict（fd→state，pop 清理） | ✅ 完成 | e2e M14/M16；`/routes` 等 HTTP 功能零回归 |
| 10 | e2e：并发节 M14/M15/M16（71 → 74 项） | ✅ 完成 | `./scripts/e2e_test.sh`：74 passed, 0 failed |
| 11 | 文档：ADR-0007 §后续 交叉引用 + README + AGENTS.md（决策-17）+ CI 计数 | ✅ 完成 | 见 commit |

## 后续（不在本 ADR 范围，需新 ADR）

- WS 路由 `{param}` pattern 匹配（当前精确匹配）
- WS 鉴权（升级头/首帧 token）
- 事件队列背压策略（当前溢出丢弃；可改为按连接限流/4xx 关闭）
- 重组缓冲内存策略（当前每连接惰性 1MB；可改为按需增长）
