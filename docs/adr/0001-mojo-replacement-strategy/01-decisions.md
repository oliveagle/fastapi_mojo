# ADR-0001: Mojo 替换 Python 策略（从外层开始，从容易的开始）

- **日期**：2026-08-22
- **状态**：✅ 已接受
- **决策者**：oliveagle
- **关联**：`docs/migrate_mojo/architecture.md`（候选扫描 + 技术验证）、`docs/migrate_mojo/todo.md`（决议链）

## 1. 背景

fastapi_mojo 的目标是用 Mojo 实现一套 FastAPI。当前 baseline 是"Mojo 薄 wrapper 调用 Python FastAPI"。
需要确定替换策略：**不是所有 Python 库都需要替换，只聚焦容易的，从外层开始一点一点替换**。

## 2. 决策

### 2.1 替换顺序（从外层到内层）

| 步骤 | 替换点 | 难度 | 状态 |
|------|--------|------|------|
| C1 | handler 层（业务逻辑） | ⭐ 容易 | ✅ 已决策-5 |
| C2 | 响应序列化（dict → JSON） | ⭐⭐ 中 | ✅ 已决策-6 |
| C3 | 路由注册表（path → handler） | ⭐⭐⭐ 难 | ✅ 已决策-7 |
| C4 | 参数解析（Query/Path/Body） | ⭐⭐⭐ 难 | ✅ 已决策-8 |
| C5 | HTTP 服务器（替代 uvicorn） | ⭐⭐⭐⭐ 很难 | 🚧 已决策-9（阻塞） |
| C6 | ASGI 协议层（替代 Starlette） | ⭐⭐⭐⭐⭐ 极难 | 📋 待开发 |

### 2.2 已决策方案

- **C1（已决策-5）**：Mojo 生成 lambda 源码（业务逻辑 Mojo 控制，Python 只做执行壳）
- **C2（已决策-6）**：Mojo 构造 JSON 字符串 + Response 包装（FastAPI 原样返回不二次序列化）
- **C3（已决策-7）**：Mojo Route struct + 路由表 + 批量注册
- **C4（已决策-8）**：Mojo 构造 Request 注解 handler（builtins.exec + 命名空间注入）
- **C5（已决策-9，阻塞）**：Mojo 1.0.0 无 `std.http`/`std.socket`/`std.net`，无法原生实现 HTTP 服务器

### 2.3 关键技术约束

1. Mojo 函数不能直接作为 Python callable（`PythonObject(mojo_handler)` 编译失败）
2. FastAPI 对返回 str 的 handler 二次序列化（带转义引号），对 dict/Response 原样返回
3. Mojo 1.0.0 标准库无网络模块（http/socket/net），C5 阻塞

## 3. 决策结果

- 每步替换保持可运行、可 benchmark 对比（`./benchmark.sh`，SQLite 长期跟踪）
- 每步替换后跑 benchmark 验证无性能回退
- C5 阻塞期间，可深化 C2（Mojo 完整 JSON 序列化）或 C4（Path/Body 参数）

## 4. 约束边界

### 4.1 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | Mojo wrapper → Python FastAPI 单向依赖 |
| 2. 分层向下依赖 | ✅ 遵守 | 外层（handler）→ 内层（框架）单向 |
| 3. God package 阈值 | ✅ 遵守 | 每个 .mojo 文件 < 500 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | src/fastapi_mojo/ 只做 FastAPI 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | wrapper.mojo 是唯一 bridge |
| 6. 测试文件跟随 | ✅ 遵守 | 测试与生产代码同目录 |
