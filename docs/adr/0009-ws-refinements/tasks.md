# ADR-0009: WebSocket 精化 — 任务清单

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | ADR-0009（bug 机理 + 候选方案 + 6 约束 + 实测教训） | ✅ 完成 | `docs/adr/0009-ws-refinements/01-decisions.md` |
| 2 | **P0**：`ws_parser_feed` consumed 语义 + 每轮错误点/完成点精确定位 | ✅ 完成 | 单元编译 + e2e M17 |
| 3 | **P0**：`pump_ws_conn` 尾块缓冲重放（recv/尾块统一数据源，全路径不丢字节） | ✅ 完成 | e2e M17（2 帧合并 + 混块）；实施期 burst 20 帧有序 |
| 4 | **P0**：`ws_pump_now(fd)` 显式立即重 pump（尾块无 socket 事件） | ✅ 完成 | 合并帧回复 0.000s（修复前实测 5s+ 延迟） |
| 5 | 重组缓冲按需增长（4KB 起步 → 1MB 上限，feed -2 语义，未写越界） | ✅ 完成 | e2e 76800B 大帧回归（增长路径）；小消息连接 ~4KB |
| 6 | 事件队列加固（2*MAX_CONNS+64 结构上不可溢出 + 1008 防御路径） | ✅ 完成 | 代码注释论证不变式；e2e 全量无僵死连接 |
| 7 | WS `{param}` 路由（WsRoute.match_with_params + WsRouteMatch.params 贯穿） | ✅ 完成 | e2e M19/M21；router 自检 3 例；test_all pattern 3 例 |
| 8 | `KIND_WS_GREET` + `run_ws_message` params 参数（单点 dispatch 扩展） | ✅ 完成 | e2e M19（双消息参数稳定）；test_all greet 2 例 |
| 9 | WS 鉴权（ws_token 升级 query 校验，101 前 403；ws_check_token 纯函数） | ✅ 完成 | e2e M20（101/403/403）；test_all token 5 例 |
| 10 | e2e M17-M21（74 → 79 项）+ 单元扩展 | ✅ 完成 | `./scripts/e2e_test.sh`：79 passed, 0 failed |
| 11 | 文档：ADR-0007/0008 后续对齐 + README + AGENTS.md（决策-18）+ CI 计数 | ✅ 完成 | 见 commit |

## 后续（不在本 ADR 范围，需新 ADR）

- 鉴权扩展：首帧 token / 自定义头 / 与 HTTP 中间件统一的鉴权链
- `{param}` 段 URL 解码（与 HTTP Route 一并处理）
- handler 回复含 NUL（Mojo FFI len 传递协议修订，ADR-0007 §5 教训 3）
- WS benchmark 场景（bench.py 目前 HTTP/hey 形态，WS 压测需专用工具）
- P2：Mojo 原生 ASGI/WSGI 协议层（beads: phase1-mojo-native-crt.6，独立评估）
