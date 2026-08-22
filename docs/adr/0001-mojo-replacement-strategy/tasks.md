# ADR-0001: Mojo 替换 Python 策略 — 任务清单

> 关联：`docs/adr/0001-mojo-replacement-strategy/01-decisions.md`（决策）
> 决议链：`docs/migrate_mojo/todo.md`（权威）← ADR-0001 ← `docs/migrate_mojo/architecture.md` §10

## 任务列表

| # | 任务 | 关联决议 | 状态 |
|---|------|---------|------|
| 1 | C1: Mojo 生成 lambda 源码（handler 层） | 已决策-5 | ✅ 完成（ce423ba） |
| 2 | C2: Mojo 构造 JSON + Response 包装（序列化） | 已决策-6 | ✅ 完成（9054ad9） |
| 3 | C3: Mojo 路由表 + 批量注册 | 已决策-7 | ✅ 完成（b239df3） |
| 4 | C4: Mojo 构造 Request 注解 handler（参数解析） | 已决策-8 | ✅ 完成（4a7e2d2） |
| 5 | C5: Mojo HTTP 服务器（替代 uvicorn） | 已决策-9（阻塞） | 🚧 阻塞：Mojo 1.0.0 无网络模块 |
| 6 | C2 深化: Mojo 完整 JSON 序列化函数 | 待开发 | 📋 待开发 |
| 7 | C4 深化: Path/Body 参数解析 | 待开发 | 📋 待开发 |
| 8 | C6: Mojo ASGI 协议层 | 待开发 | 📋 待开发 |

## 验收标准（每步）

1. `cd src/fastapi_mojo && mojo run hello.mojo` 可运行
2. `curl :8000/`、`curl :8000/hello?name=Mojo`、`curl :8000/docs` 全部 200
3. `./benchmark.sh` 跑一轮，吞吐无回退（对比 SQLite 历史）
4. 决议链同步：todo.md + architecture.md §10 + 章节引用 + ADR 6 条声明
