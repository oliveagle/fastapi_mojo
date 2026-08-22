# Mojo 替换 Python — 决策与任务清单

> 权威决议链：本文档（完整内容）← `docs/adr/`（ADR 文件）← `docs/migrate_mojo/architecture.md` §10 决策表（索引）。
> 分类：✅ 已决策 / 🚧 改造 / 📋 待开发 / 💬 待讨论

## ✅ 已决策

| # | 决议 | 描述 | 涉及方 + 工作量 |
|---|------|------|----------------|
| 1 | **从 handler 层开始替换** | 从最外层（handler）开始用 Mojo 替换 Python，从容易的开始。不是所有 Python 库都需要替换，只聚焦容易的。 | fastapi_mojo + 小 |
| 2 | **Mojo 函数不能直接作为 Python callable** | 验证结论：`PythonObject(mojo_handler)` 编译失败。handler 仍需 Python lambda 壳，但业务逻辑可由 Mojo 驱动。 | fastapi_mojo + 小 |
| 3 | **handler 返回 dict 而非 str** | FastAPI 对 str 会二次序列化（带转义引号），对 dict 输出纯 JSON。Mojo 侧构造 dict（PythonObject）作为 handler 返回值。 | fastapi_mojo + 小 |
| 4 | **替换顺序 C1→C2→C3→C4→C5→C6** | 从容易到难：handler → 序列化 → 路由表 → 参数解析 → HTTP 服务器 → ASGI。每步保持可运行、可 benchmark 对比。 | fastapi_mojo + 中 |
| 5 | **C1 方案 A：Mojo 生成 lambda 源码** | handler 业务逻辑由 Mojo 构造 lambda 字符串（含业务数据），`Python.evaluate` 执行，Python 只做执行壳。已验证可行。 | fastapi_mojo + 小 |
| 6 | **C2 方案 A：Mojo 构造 JSON + Response 包装** | Mojo 拼接 JSON 字符串，handler 返回 `Response(content=json_str, media_type='application/json')`，FastAPI 原样返回不二次序列化。已验证可行。 | fastapi_mojo + 小 |
| 7 | **C3 方案 A：Mojo 路由表 + 批量注册** | wrapper 增加 `Route` struct + `add_route(path, method, handler)` + `register_all()`，Mojo 侧集中管理路由，启动时批量注册到 FastAPI。已验证可行。 | fastapi_mojo + 中 |
| 8 | **C4 方案 A：Mojo 构造 Request 注入 handler** | wrapper 增加 `register_query(path, method, param_name, default)`，Mojo 构造带 `request: Request` 注解的 handler 源码，参数解析逻辑由 Mojo 生成。已验证可行。 | fastapi_mojo + 中 |
| 9 | **C5 阻塞：Mojo 1.0.0 无网络模块** | 验证结论：`std.http` / `std.socket` / `std.net` 均不存在，Mojo 1.0.0 标准库无法原生实现 HTTP 服务器。C5（替代 uvicorn）需等待 Mojo 标准库支持网络，或改用 Python socket 桥接（非纯 Mojo 替换）。 | fastapi_mojo + 阻塞 |
| 10 | **C2-改：直接包 orjson 替代自造 JSON 序列化** | 不自造 JSON 序列化逻辑（转义、嵌套、类型转换），直接用现成的 orjson（Rust 实现，~8M ops/s，比 stdlib json 快 10x）。Mojo 侧只调 `orjson.dumps(dict)`。 | fastapi_mojo + 小 |
| 11 | **环境隔离：使用仓库 .venv 不污染系统** | Python 依赖装在 `.venv`（已 gitignore），不污染系统 Python。Mojo 通过 `sys.path.insert(0, .venv site-packages)` 自动使用 .venv。 | fastapi_mojo + 小 |

## 🚧 改造

| # | 任务 | 描述 | 工作量 |
|---|------|------|--------|
| 1 | **Mojo 原生 handler 注册** | wrapper.mojo 增加 `register_handler(path, handler)`，handler 由 Mojo 侧构造 dict 返回，替代 hello.mojo 中的 Python lambda 业务逻辑 | 小 |
| 2 | **POST/PUT/DELETE 方法支持** | register_* 系列目前只验证了 GET，需验证 POST 路由 + Body 参数 | 小 |

## 📋 待开发

| # | 任务 | 描述 | 工作量 |
|---|------|------|--------|
| 1 | **C4-深化：Path/Body 参数解析** | register_path + register_body，从 request.path_params / request.body() 提取参数 | 中 |
| 2 | **错误处理** | HTTPException、404 处理、异常 → JSON 响应 | 中 |
| 3 | **Mojo 侧测试** | mojo test 单元测试（wrapper 各方法），目前只有手动 curl + benchmark | 中 |
| 4 | **README 更新** | 反映 orjson + .venv + ADR 流程 | 小 |
| 5 | **benchmark 场景扩展** | 增加 POST 场景（当前只有 GET） | 小 |
| 6 | **C5 解除阻塞探索** | 检查 Mojo FFI（@export + C ABI）能否桥接 socket，或 Python socket 桥接 | 大 |
| 7 | **Mojo HTTP 服务器** | 替代 uvicorn（依赖 #6） | 很大 |
| 8 | **Mojo ASGI 协议层** | 替代 Starlette（依赖 #7） | 极大 |

## 💬 待讨论

| # | 议题 | 描述 |
|---|------|------|
| 1 | **handler 的 Mojo 驱动方式** | Mojo 函数不能直接作为 callable，是"Mojo 生成 Python lambda"还是"Mojo 维护路由表 + Python 转发"？ |
| 2 | **序列化边界** | Mojo 序列化到哪一层？dict → JSON 字符串（FastAPI 原样返回）还是更底层？ |
