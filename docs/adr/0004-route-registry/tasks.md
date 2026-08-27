# ADR-0004: 用户路由注册机制 — 任务清单

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | 验证 Mojo 1.0.0 语言约束（无 match / 无模块级 let / 零参 def 常量 / struct+Dict+Tuple） | ✅ 完成 | /tmp/handler_test2.mojo 实测：def 常量 + Handler struct + if/elif dispatch + Tuple 返回全部可行 |
| 2 | ADR-0004 01-decisions.md（背景/约束/决策/接口草案/否决备选/6 条隔离约束/验证方式） | ✅ 完成 | docs/adr/0004-route-registry/01-decisions.md |
| 3 | 接口草案：`Handler`(kind/name/data) + kind 常量 + `ServerInfo` + `run_handler` 签名 | ✅ 完成 | 01-decisions.md §3.1 |
| 4 | P4.2 实现：`handler.mojo`（run_handler + 内置处理器）+ router 携带 Handler + 核心 dispatch 收敛 | ⏳ 待做 | beads: fastapi_mojo-p4-framework-tfr.2 |
| 5 | P4.2 验收：新增 /echo 路由核心零改动 + test_all 用例 + 端到端 | ⏳ 待做 | beads: fastapi_mojo-p4-framework-tfr.2 |
| 6 | P4.5：e2e_test.sh 新增 /echo GET/POST 场景 | ⏳ 待做 | beads: fastapi_mojo-p4-framework-tfr.5 |
