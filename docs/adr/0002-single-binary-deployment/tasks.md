# ADR-0002: 单二进制部署 — 任务清单

> 关联：`AGENTS.md` §1（本标）、`docs/adr/0002-single-binary-deployment/01-decisions.md`（决策）

## 任务列表

### Epic: Phase 1 — 核心组件 Mojo 化

| # | 任务 | 状态 | 关联 |
|---|------|------|------|
| 1 | 验证 `mojo build` 静态链接可行性 | 📋 待启动 | C5 前置 |
| 2 | C5 解除阻塞：Mojo 原生 HTTP server（替代 uvicorn） | 🚧 阻塞 → 转关键路径 | 已决策-9 |
| 3 | Mojo 原生 JSON 序列化（替代 orjson） | 📋 待启动 | 已决策-10 重审 |
| 4 | Mojo 原生 Router（替代 FastAPI 路由表） | 📋 待启动 | 已决策-7 重审 |
| 5 | Mojo 原生参数解析（替代 FastAPI Depends） | 📋 待启动 | 已决策-8 重审 |
| 6 | Mojo 原生 ASGI/WSGI 协议层（替代 Starlette） | 📋 待启动 | C6 升为关键路径 |

### Epic: Phase 2 — 去 Python 化

| # | 任务 | 状态 | 关联 |
|---|------|------|------|
| 7 | 移除 Python interop（Phase 2 拆除 wrapper） | 📋 待启动 | 已决策-11 退役 |
| 8 | 移除 .venv 依赖 | 📋 待启动 | 已决策-11 退役 |
| 9 | 异常处理改用 Mojo 原生实现（移除 orjson） | 📋 待启动 | 已决策-12 重审 |

### Epic: Phase 3 — 单 Binary 交付

| # | 任务 | 状态 | 关联 |
|---|------|------|------|
| 10 | `mojo build` 产出独立可执行文件 | 🎯 终点 | 本标 |
| 11 | 干净环境部署验证（无 Python/pip） | 🎯 终点 | 本标 |
| 12 | 部署文档与脚本（`./build.sh` + `./fastapi_mojo`） | 🎯 终点 | 本标 |

## 验收标准（Phase 3 终点）

1. `mojo build` 产出单个可执行文件（无 .so/.dylib 依赖，除 libc）
2. 在无 Python 的容器中运行二进制，服务正常启动
3. `./benchmark.sh` 在 binary 上跑通，性能不退化
4. `AGENTS.md` §1 描述的本标全部达成
