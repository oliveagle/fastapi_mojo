# ADR-0002: 项目本标 = Mojo 单一二进制零依赖部署

- **日期**：2026-08-23
- **状态**：✅ 已接受（项目本标）
- **决策者**：oliveagle
- **关联**：`AGENTS.md` §1（本标权威定义）、ADR-0001（Mojo 替换策略）、`docs/adr/0001-mojo-replacement-strategy/tasks.md`

## 1. 背景

fastapi_mojo 当前以"Mojo 薄 wrapper 调用 Python FastAPI"为 baseline（Phase 0）。
在此过程中逐步确立了部署形态的北极星目标：

> **部署需要用 Mojo 把代码编译成一个 Binary，运行时没有任何其他依赖。**

即：最终交付物必须像 Go 编译产物一样，`mojo build` 后得到一个独立的可执行文件，
`scp`/`docker COPY` 即可运行，**不依赖 Python 运行时、不依赖 pip 包、不依赖 .venv**。

这与当前 Phase 0（依赖系统 Python + fastapi/uvicorn/orjson）存在根本性架构冲突，
需要单独成决议，作为后续所有任务规划的最高优先级约束。

## 2. 决策

### 2.1 本标内容

1. **编译方式**：使用 Mojo 编译器将代码编译为**单一二进制**（`mojo build` / 等价链路）。
2. **零外部依赖**：运行时不依赖 Python、pip 包、系统动态库（除 libc/libm 等基础运行时）。
3. **部署体验**：`./fastapi_mojo` 一条命令启动服务，对标 Go 单二进制部署。
4. **验证方式**：在干净环境（无 Python/pip 安装）中运行二进制，服务可正常启动并响应。

### 2.2 对既有决策的影响

| 既有决策 | 原立场 | 本标影响 |
|---------|--------|---------|
| 已决策-10（包 orjson） | 直接包 orjson 不自造 JSON | ⚠️ **重审**：orjson 是 Python 包，Phase 1 起需 Mojo 原生 JSON 或静态链接替代 |
| 已决策-11（.venv 隔离） | 用 .venv 避免污染系统 | ⚠️ **bootstrap-only**：Phase 2 必须移除 .venv / Python interop |
| 已决策-12（异常→JSON orjson） | orjson 序列化 | ⚠️ **重审**：同上，依赖 orjson 的路径需替换 |
| 已决策-9（C5 Mojo HTTP server） | 阻塞、可延后 | 🔺 **升为关键路径**：HTTP server 是去 Python 化的前置依赖 |

### 2.3 阶段性过渡

- **Phase 0（当前）**：Python interop 作为临时脚手架，**明确标记 bootstrap-only**。
- **Phase 1**：Mojo 原生实现核心组件（HTTP server / JSON / Router / 参数解析），与 Python 路径并存对比。
- **Phase 2**：拆除 Python interop 与 .venv。
- **Phase 3（终点）**：`mojo build` 产出单二进制，零外部依赖部署。

## 3. 决策结果

- 本决议为**项目本标**，优先级高于其他任何阶段性决策。
- 任何引入新 Python 依赖的 PR 视为倒退；任何依赖系统 Python 的代码路径最终必须被替换。
- 任务规划必须围绕本标拆解（见 `tasks.md`）。

## 4. 约束边界

### 4.1 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | Mojo 原生实现单向向下，无循环 |
| 2. 分层向下依赖 | ✅ 遵守 | 用户代码 → Mojo 实现 → OS，单向 |
| 3. God package 阈值 | ✅ 遵守 | 每个 .mojo 文件 < 500 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | src/fastapi_mojo/ 只做 FastAPI 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | Python interop 收敛在显式 bridge，Phase 2 拆除 |
| 6. 测试文件跟随 | ✅ 遵守 | 测试与生产代码同目录 |
