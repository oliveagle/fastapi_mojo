# fastapi_mojo — Agent 工作指南

> 本文件是 AI Agent 在本仓库工作时的**最高优先级约束**。
> 任何代码修改、任务规划、架构决策都必须与本文件对齐。

---

## 1. 项目本标（North Star）

**最终交付物：用 Mojo 将代码编译成一个单一 Binary，运行时零外部依赖。**

| 维度 | 目标 |
|------|------|
| 编译产物 | 单个可执行文件（`fastapi_mojo` 或等价命名） |
| 运行时依赖 | **无** — 不依赖 Python、不依赖 pip 包、不依赖系统动态库（除 libc/libm 等基础运行时） |
| 部署方式 | `scp` / `docker COPY` 二进制即可运行 |
| 对标体验 | 类似 Go 编译产物：`./fastapi_mojo` 启动即服务 |

### 1.1 本标的约束力

- **任何引入新 Python 依赖的 PR 都是倒退**，必须被拒绝或标记为临时过渡方案。
- **任何依赖系统 Python 运行时的代码路径**，最终都必须被 Mojo 原生实现替换。
- 当前 "Mojo wrapper 调 Python FastAPI" 是**引导阶段（bootstrap）**，不是终点。

---

## 2. 当前阶段定位

| 阶段 | 状态 | 说明 |
|------|------|------|
| Phase 0: Wrapper 引导 | ✅ 完成 | Mojo 薄壳调 Python FastAPI（已拆除，历史阶段） |
| Phase 1: 核心组件 Mojo 化 | ✅ 完成 | HTTP server（C FFI 桥接）/ JSON / Router / 参数解析 全部原生 |
| Phase 2: 去 Python 化 | ✅ 完成 | 零 Python 运行期依赖（.venv 仅保留给 benchmark 工具链） |
| Phase 3: 单 Binary 交付 | ✅ **已达成** | `./build_single.sh` 产出 `build/fastapi_mojo`，ldd 仅 libc |

**本标已达成**：单一文件部署（scp 即运行）。实现机制见 `docs/adr/0003-single-binary-mechanism/`
（Mojo 1.0.0 无静态运行时库 → 嵌入 + 启动暂存 + dlopen 符号转发）。

> 注：`fastapi/` 目录是 bootstrap 时代（Phase 0，Mojo wrapper 调 Python FastAPI）
> 保留的 git submodule（FastAPI 0.141.1 源码参考），**非运行期依赖** ——
> 单一 binary 不读取它；Phase 2 完成后若不再需要参考可移除。

---

## 3. 架构约束（不可违背）

### 3.1 部署约束

- ✅ **允许**：Mojo 标准库、Mojo 社区包（可静态链接）、C FFI（随 binary 打包）
- ❌ **禁止**（最终形态）：Python 运行时、pip 包、`.venv`、系统动态库依赖
- ⚠️ **过渡允许**：当前 Phase 0 的 Python interop，但必须在 ADR 中标记为 "bootstrap-only"

### 3.2 代码约束

- 每个 `.mojo` 文件 < 500 行（God package 阈值）
- `src/fastapi_mojo/` 只做 FastAPI 域，不混杂其他主题
- `wrapper.mojo` 是当前唯一 bridge，未来每个替换点都需要显式 bridge/adapter
- 测试文件与生产代码同目录

### 3.3 依赖方向

```
用户代码 → Mojo 原生实现 → (可选) C FFI → 操作系统
         ↘ (Phase 0 临时) Python interop → fastapi/uvicorn/orjson
```

**Phase 0 的 Python 路径是临时脚手架，Phase 2 必须拆除。**

---

## 4. 任务管理

- 使用 **beads-rust (`br`)** 管理任务，数据库在 `.beads/`
- ADR 在 `docs/adr/`，每个 ADR 必须包含 **6 条架构隔离约束声明**
- Benchmark 统一走 `./benchmark.sh`，禁止手写压测脚本

---

## 5. 关键风险与阻塞

| 风险 | 影响 | 当前状态 |
|------|------|---------|
| Mojo 1.0.0 无 `std.http`/`std.socket`/`std.net` | 无法原生实现 HTTP server | 🚧 C5 阻塞 |
| Mojo 无成熟 JSON 库 | 需自研或 FFI | 📋 待评估 |
| Mojo 异步/并发模型不稳定 | 高并发 HTTP server 实现难度 | 📋 待验证 |
| 静态链接可行性未验证 | `mojo build` 是否真能产出无依赖 binary | 📋 待验证 |

---

## 6. 决议链速查

- **已决策-1~4**：wrapper 基础形态（见 `docs/adr/0001-mojo-replacement-strategy/`）
- **已决策-5 (C1)**：handler 业务逻辑由 Mojo 构造 lambda 源码
- **已决策-6 (C2)**：Mojo 构造 JSON + Response 包装
- **已决策-7 (C3)**：Mojo 路由表 + 批量注册
- **已决策-8 (C4)**：Path/Body 参数解析迁移到 Mojo
- **已决策-9 (C5)**：Mojo HTTP 服务器 — ✅ 达成（C FFI socket 桥接 + Mojo 原生协议层；Mojo 1.0.0 无网络模块的约束经 C 桥接绕过）
- **已决策-10**：不自造 JSON 序列化，直接包 orjson — ✅ **已重审并替换**：json.mojo 原生线性时间序列化（orjson 路径已删除）
- **已决策-11**：.venv 环境隔离 — ✅ **服务器侧已移除**（bootstrap 结束）；.venv 仅保留给 benchmark 工具链（bench.py），非运行期依赖
- **已决策-12**：异常 → JSON 响应（orjson 序列化）— ✅ **已替换**：错误响应由 json.mojo 原生构造
- **已决策-13**：**项目本标 = Mojo 单 Binary 零依赖部署**（本文件 §1）
- **已决策-14**：单一二进制实现机制 = 运行时嵌入 + 启动暂存 + dlopen 符号转发（见 ADR-0003）；构建入口 `./build_single.sh`，部署 `./deploy.sh`

---

*最后更新：2026-08-26*
