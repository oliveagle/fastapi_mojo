# Mojo 替换 Python 架构决策记录（fastapi_mojo）

> 目标：从外层开始，一点一点用 Mojo 替换 Python。不是所有 Python 库都需要替换，只聚焦容易的。
> 决策链：`docs/migrate_mojo/todo.md`（权威）← `docs/adr/`（ADR 文件）← 本文档 §10 决策表（索引）。

## 1. 当前架构（Baseline）

```
┌─────────────────────────────────────────────────────────┐
│  curl / 客户端                                            │
└──────────────┬──────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────┐
│  uvicorn（Python）— ASGI 服务器                           │
└──────────────┬──────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────┐
│  FastAPI / Starlette（Python）— 路由 + 参数解析 + 序列化    │
└──────────────┬──────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────┐
│  Mojo wrapper（FastAPIWrapper）— 创建 app + 注册路由       │
│  handler：Python lambda（Python.evaluate）               │
└─────────────────────────────────────────────────────────┘
```

**当前 Mojo 侧只做**：创建 FastAPI 实例、转发 get/post/put/delete、注册路由。
**真正干活的全是 Python 侧**：uvicorn（服务器）、FastAPI/Starlette（框架）、lambda（handler）。

## 2. 替换候选扫描（从外层到内层）

| # | 候选 | 当前实现 | 替换难度 | 收益 | 状态 |
|---|------|---------|---------|------|------|
| C1 | **handler 层**（最外层业务逻辑） | Python lambda | ⭐ 容易 | 中 | 📋 待开发 |
| C2 | **响应序列化**（dict → JSON） | FastAPI 内部 | ⭐⭐ 中 | 中 | 📋 待开发 |
| C3 | **路由注册表**（path → handler 映射） | FastAPI 内部 | ⭐⭐⭐ 难 | 高 | 📋 待开发 |
| C4 | **参数解析**（Query/Path/Body） | FastAPI 内部 | ⭐⭐⭐ 难 | 高 | 📋 待开发 |
| C5 | **HTTP 服务器**（替代 uvicorn） | uvicorn | ⭐⭐⭐⭐ 很难 | 高 | 📋 待开发 |
| C6 | **ASGI 协议层** | Starlette | ⭐⭐⭐⭐⭐ 极难 | 极高 | 📋 待开发 |

**原则**：从容易的开始（C1 → C2 → C3 → ...），每步保持可运行、可 benchmark 对比。

## 3. 关键技术验证（2026-08-22）

### 3.1 Mojo 函数不能直接作为 Python callable

```mojo
var wrapped = PythonObject(mojo_handler)  # ❌ 编译错误
```

Mojo 的 `def` 函数无法转换为 Python 可调用的 `PythonObject`。

### 3.2 FastAPI 接受返回 str 的 handler，但会二次序列化

```python
lambda: '{"message": "hi"}'   # → body: "{\"message\": \"hi\"}"（带转义引号）
```

### 3.3 FastAPI 接受返回 dict 的 handler，输出纯 JSON ✅

```python
lambda: {'message': 'hi'}     # → body: {"message":"hi"}，content-type: application/json
```

### 3.4 Mojo String 可传给 Python，可动态构造 JSON 字符串 ✅

```mojo
var json_str = '{"message": "' + msg + '"}'
```

## 4. 结论

- **C1（handler 层）是第一个替换点**：Mojo 侧构造 dict（PythonObject）作为 handler 返回，替代 Python lambda 的"业务逻辑"部分。
- 但 Mojo 函数不能直接作为 callable 传给 FastAPI → **handler 仍需是 Python lambda，只是 lambda 内部逻辑由 Mojo 生成/驱动**。
- 更彻底的路径：Mojo 侧维护自己的路由表 + handler 注册，FastAPI 只做"最后一跳"转发。

> 📌 **引用决议**: ✅ 已决策-5（C1 方案 A：Mojo 生成 lambda 源码）— handler 业务逻辑由 Mojo 构造 lambda 字符串，Python 只做执行壳。详见 `docs/migrate_mojo/todo.md` #5。

> 📌 **引用决议**: ✅ 已决策-6（C2 方案 A：Mojo 构造 JSON + Response 包装）— Mojo 拼接 JSON 字符串，handler 返回 Response 对象，FastAPI 原样返回不二次序列化。详见 `docs/migrate_mojo/todo.md` #6。

> 📌 **引用决议**: ✅ 已决策-7（C3 方案 A：Mojo 路由表 + 批量注册）— Mojo 侧集中管理 Route 列表，启动时批量注册到 FastAPI。详见 `docs/migrate_mojo/todo.md` #7。

> 📌 **引用决议**: ✅ 已决策-8（C4 方案 A：Mojo 构造 Request 注入 handler）— Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成。详见 `docs/migrate_mojo/todo.md` #8。

> 📌 **引用决议**: 🚧 已决策-9（C5 阻塞：Mojo 1.0.0 无网络模块）— `std.http`/`std.socket`/`std.net` 均不存在，C5（替代 uvicorn）当前不可行，需等待 Mojo 标准库支持网络。详见 `docs/migrate_mojo/todo.md` #9。

## 5. 约束边界

### 5.1 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | Mojo wrapper → Python FastAPI 单向依赖 |
| 2. 分层向下依赖 | ✅ 遵守 | 外层（handler）→ 内层（框架）单向 |
| 3. God package 阈值 | ✅ 遵守 | 每个 .mojo 文件 < 500 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | src/fastapi_mojo/ 只做 FastAPI 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | wrapper.mojo 是唯一 bridge |
| 6. 测试文件跟随 | ✅ 遵守 | 测试与生产代码同目录 |

## 10. 决策表（索引）

> 权威决议链：`docs/migrate_mojo/todo.md`（完整内容）← 本文档（索引）。

| 日期 | 决议 | 决策者 | 类型 |
|------|------|--------|------|
| 2026-08-22 | **从 handler 层开始替换** — 从最外层（handler）开始用 Mojo 替换 Python，从容易的开始。详见 `docs/migrate_mojo/todo.md` #1 | oliveagle | ✅ 已决策-1 |
| 2026-08-22 | **Mojo 函数不能直接作为 Python callable** — `PythonObject(mojo_handler)` 编译失败，handler 仍需 Python lambda 壳。详见 `docs/migrate_mojo/todo.md` #2 | oliveagle | ✅ 已决策-2 |
| 2026-08-22 | **handler 返回 dict 而非 str** — FastAPI 对 str 二次序列化，对 dict 输出纯 JSON。详见 `docs/migrate_mojo/todo.md` #3 | oliveagle | ✅ 已决策-3 |
| 2026-08-22 | **替换顺序 C1→C2→C3→C4→C5→C6** — 从容易到难，每步保持可运行、可 benchmark 对比。详见 `docs/migrate_mojo/todo.md` #4 | oliveagle | ✅ 已决策-4 |
| 2026-08-22 | **C1 方案 A：Mojo 生成 lambda 源码** — handler 业务逻辑由 Mojo 构造 lambda 字符串，Python 只做执行壳。详见 `docs/migrate_mojo/todo.md` #5 | oliveagle | ✅ 已决策-5 |
| 2026-08-22 | **C2 方案 A：Mojo 构造 JSON + Response 包装** — Mojo 拼接 JSON 字符串，handler 返回 Response 对象，FastAPI 原样返回不二次序列化。详见 `docs/migrate_mojo/todo.md` #6 | oliveagle | ✅ 已决策-6 |
| 2026-08-22 | **C3 方案 A：Mojo 路由表 + 批量注册** — Mojo 侧集中管理 Route 列表，启动时批量注册到 FastAPI。详见 `docs/migrate_mojo/todo.md` #7 | oliveagle | ✅ 已决策-7 |
| 2026-08-22 | **C4 方案 A：Mojo 构造 Request 注入 handler** — Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成。详见 `docs/migrate_mojo/todo.md` #8 | oliveagle | ✅ 已决策-8 |
| 2026-08-22 | **C5 阻塞：Mojo 1.0.0 无网络模块** — `std.http`/`std.socket`/`std.net` 均不存在，C5（替代 uvicorn）当前不可行。详见 `docs/migrate_mojo/todo.md` #9 | oliveagle | 🚧 已决策-9 |
