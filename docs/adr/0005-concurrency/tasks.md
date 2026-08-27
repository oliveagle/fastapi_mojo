# ADR-0005: 并发化 — 任务清单

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | ADR-0005（候选方案对比 + 6 条隔离约束 + 验证方式） | ✅ 完成 | docs/adr/0005-concurrency/01-decisions.md |
| 2 | C 桥接：init_workers() (fork+re-exec, env 驱动) + SO_REUSEPORT + get_worker_id() | ✅ 完成 | http_bridge_final.c (commit 见 beads) |
| 3 | Mojo main: init_workers() 调用 + banner worker 号 | ✅ 完成 | http_server_final.mojo |
| 4 | 验收: 默认 1 worker 行为不变 (e2e 56/56); 8 worker 200c p99<50ms & rps≥3× | ⏳ 验证中 | hey 基准 + pgrep/ss 检查 |
