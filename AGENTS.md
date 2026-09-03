# fastapi_mojo — Agent 工作指南

> 本文件是 AI Agent 在本仓库工作时的**最高优先级约束**。
> 任何代码修改、任务规划、架构决策都必须与本文件对齐。

---

## 1. 项目本标（North Star）

**最终交付物：用 Mojo + Rust 将代码编译成一个单一 Binary，运行时零外部依赖。**

| 维度 | 目标 |
|------|------|
| 编译产物 | 单个可执行文件（`fastapi_mojo` 或等价命名） |
| 运行时依赖 | **无** — 不依赖 Python、不依赖 pip 包、不依赖系统动态库（除 libc/libm 等基础运行时） |
| 实现语言 | **Mojo + Rust only**：应用/协议层 Mojo 原生，bridge/系统调用层 Rust staticlib（C ABI），**C 代码清零** |
| 部署方式 | `scp` / `docker COPY` 二进制即可运行 |
| 对标体验 | 类似 Go 编译产物：`./fastapi_mojo` 启动即服务 |

### 1.1 本标的约束力

- **任何引入新 Python 依赖的 PR 都是倒退**，必须被拒绝或标记为临时过渡方案。
- **任何依赖系统 Python 运行时的代码路径**，最终都必须被 Mojo 原生实现替换。
- **任何新增或保留的 C 代码路径都是倒退**：bridge 层终态必须是 Rust（staticlib +
  C ABI），`src/` 下 `*.c` 必须归零（ADR-0010，决策-19）。
- 当前 "Mojo wrapper 调 Python FastAPI" 是**引导阶段（bootstrap）**，不是终点；
  当前 "Mojo + C bridge" 是**迁移中间态**，bridge 语言终态是 Rust。

---

## 2. 当前阶段定位

| 阶段 | 状态 | 说明 |
|------|------|------|
| Phase 0: Wrapper 引导 | ✅ 完成 | Mojo 薄壳调 Python FastAPI（已拆除，历史阶段） |
| Phase 1: 核心组件 Mojo 化 | ✅ 完成 | HTTP server（C FFI 桥接）/ JSON / Router / 参数解析 全部原生 |
| Phase 2: 去 Python 化 | ✅ 完成 | 零 Python 运行期依赖（.venv 仅保留给 benchmark 工具链） |
| Phase 3: 单 Binary 交付 | ✅ 已达成 | `./build_single.sh` 产出 `build/fastapi_mojo`，ldd 仅 libc |
| Phase 4: 去 C 化（Rust bridge）| 🚧 进行中 | `http_bridge_final.c` / `ws.c` / `runtime_shim.c` → Rust staticlib（ADR-0010）；终态 **Mojo + Rust only** |

**本标已达成（Phase 3）**：单一文件部署（scp 即运行）。实现机制见 `docs/adr/0003-single-binary-mechanism/`
（Mojo 1.0.0 无静态运行时库 → 嵌入 + 启动暂存 + dlopen 符号转发）。

> 注：bootstrap 时代（Phase 0）的 `fastapi/` git submodule（FastAPI 0.141.1 源码
> 参考）**已移除**（Phase 2 完成后不再需要；单一 binary 从未读取它）。
> 后续若需对照 FastAPI 语义，直接查上游仓库即可。
>
> 注2：bridge 层语言正从 C 迁移到 Rust（ADR-0010，决策-19）：FFI 表面（`extern "C"`
> 导出表）与架构分层完全不变，仅实现语言切换；`src/` 下 `*.c` 清零为 Phase 4 红线。

---

## 3. 架构约束（不可违背）

### 3.1 部署约束

- ✅ **允许**：Mojo 标准库、Mojo 社区包（可静态链接）、**Rust staticlib（C ABI，
  随 binary 静态链接；仅 libc/libm 等基础运行时）**
- ❌ **禁止**（最终形态）：Python 运行时、pip 包、`.venv`、系统动态库依赖、
  **C 代码（bridge 层终态必须 Rust）**
- ⚠️ **过渡允许**：当前迁移中间态存在 C bridge（`http_bridge_final.c` / `ws.c` /
  `runtime_shim.c`），须按 ADR-0010 逐步由 Rust staticlib 替换，C 清零为 Phase 4
  验收红线；历史 bootstrap 时代的 Python interop 已拆除。

### 3.2 代码约束

- 每个 `.mojo` 文件 < 500 行（God package 阈值）；每个 Rust bridge 模块（`*.rs`）
  建议 < 500 行（超限拆子模块，标注拆分边界）
- `src/fastapi_mojo/` 只做 FastAPI 域，不混杂其他主题
- 当前运行期桥接是 **Rust staticlib**（`extern "C"` 导出，FFI 表面与既有 C bridge
  完全一致）：socket I/O / poll 事件循环 / CORS / 静态 / 限流 / 信号 / WS 会话状态
  / WS 协议原语 / 单 binary loader（运行时嵌入/暂存/dlopen 转发）。C 源文件正由
  同名 Rust 模块替换：`http_bridge_final.c` → `bridge.rs`、`ws.c` → `ws.rs`（**DC1 ✅ 已完成，ws.c 已删除**）、
  `runtime_shim.c` → `shim.rs`；Phase 0 的 `wrapper.mojo` 已拆除，未来每个新替换点
  都需显式 bridge/adapter
- **build 链接守则（Rust bridge 实战教训）**：Rust staticlib 默认拉入
  `libgcc_s.so.1`（compiler-rt 内建函数如 `__udivti3`），破坏 North Star；`build_single.sh`
  必须用 `gcc -fPIE -pie -O2 -static-libgcc` 静态链接 libgcc_s，使 `ldd` 回归仅
  libc。新增 / 替换 Rust bridge 时若引新依赖，须再次核对 `ldd`。
- **测试 syscall 隔离（Rust bridge 实战教训）**：`bridge::conn` 的 `reset_for_close`
  调用真 `close(fd)`；单元测试必须用 `#[cfg(test)] sys_close` no-op（或同等隔离
  机制），避免合成 fd 误关 libtest 捕获管道 / stdio。

- 测试文件与生产代码同目录

### 3.3 依赖方向

```
用户代码 → Mojo 原生实现 → (可选) Rust bridge（staticlib / C ABI）→ 操作系统
```

**Mojo 1.0.0 标准库缺口（socket/网络/静态运行时）由 Rust bridge 承载；桥接语言
终态 = Rust（决策-19）。**

---

## 4. 任务管理

- 使用 **beads-rust (`br`)** 管理任务，数据库在 `.beads/`
- ADR 在 `docs/adr/`，每个 ADR 必须包含 **6 条架构隔离约束声明**
- Benchmark 统一走 `./benchmark.sh`，禁止手写压测脚本
- **CI** (`.github/workflows/ci.yml`) 在每次 push/PR 到 main 时守护本标：
  单一 binary 构建（含 rust toolchain：`cargo build --release` 出 staticlib，
  `-static-libgcc` 静态链接 libgcc_s 保 ldd 干净，见 §3.2）
  + `ldd` 零依赖断言 + 干净环境 (`env -i`) 启动 + 单元测试（含 `cargo test --release
  -- --test-threads=1`，env 全局副作用需单线程）+ e2e (79 项起，含
  WebSocket 增强/并发/精化，扩展中) + 体积预算（中间态 ≤ 6M，终态 ≤ C + 2M）
  + **C 清零步骤**（终态门禁：`find src -name '*.c'` = 0；当前 Phase 4-5 为 INFO）

---

## 5. 关键风险与阻塞

| 风险 | 影响 | 当前状态 |
|------|------|---------|
| Mojo 1.0.0 无 `std.http`/`std.socket`/`std.net` | 无法原生实现 HTTP server | ✅ 已解除：Rust staticlib socket 桥接 + Mojo 原生协议层（C5，ADR-0001 决策-9；桥接语言已定 Rust，ADR-0010） |
| Mojo 无成熟 JSON 库 | 需自研或 FFI | ✅ 已解决：`json.mojo` 原生线性时间序列化，orjson 路径已删除（决策-10） |
| Mojo 异步/并发模型不稳定 | 高并发 HTTP server 实现难度 | ✅ 已解决：多进程 worker + SO_REUSEPORT（nginx pre-fork，ADR-0005） |
| 静态链接可行性未验证 | `mojo build` 是否真能产出无依赖 binary | ✅ 已验证：运行时嵌入 + 启动暂存 + dlopen 符号转发（ADR-0003，决策-14；shim 将迁 Rust） |
| C 清零可行性 | Rust staticlib 能否完全替换三份 C bridge | 🚧 评估中：ADR-0010 已接受；三份文件逐一替换，以 e2e + ldd + env -i 为验收门禁 |

> 注：Mojo 1.0.0 标准库无网络模块的约束经 **Rust 桥接**绕过；单 Binary 零依赖本标
> 已达成（§2 Phase 3）。后续风险以新 ADR 跟踪。

---

## 6. 决议链速查

- **已决策-1~4**：wrapper 基础形态（见 `docs/adr/0001-mojo-replacement-strategy/`）
- **已决策-5 (C1)**：handler 业务逻辑由 Mojo 构造 lambda 源码
- **已决策-6 (C2)**：Mojo 构造 JSON + Response 包装
- **已决策-7 (C3)**：Mojo 路由表 + 批量注册
- **已决策-8 (C4)**：Path/Body 参数解析迁移到 Mojo
- **已决策-9 (C5)**：Mojo HTTP 服务器 — ✅ 达成（socket 桥接 + Mojo 原生协议层；
  Mojo 1.0.0 无网络模块的约束经桥接绕过；桥接语言终态 = Rust，ADR-0010）
- **已决策-10**：不自造 JSON 序列化，直接包 orjson — ✅ **已重审并替换**：json.mojo 原生线性时间序列化（orjson 路径已删除）
- **已决策-11**：.venv 环境隔离 — ✅ **服务器侧已移除**（bootstrap 结束）；.venv 仅保留给 benchmark 工具链（bench.py），非运行期依赖
- **已决策-12**：异常 → JSON 响应（orjson 序列化）— ✅ **已替换**：错误响应由 json.mojo 原生构造
- **已决策-13**：**项目本标 = Mojo 单 Binary 零依赖部署**（本文件 §1）
- **已决策-14**：单一二进制实现机制 = 运行时嵌入 + 启动暂存 + dlopen 符号转发（见 ADR-0003）；构建入口 `./build_single.sh`，部署 `./deploy.sh`；shim 将迁 Rust（ADR-0010）
- **已决策-15**：WebSocket (RFC 6455) = 桥接协议层 `ws` + `/ws` echo 端点（见 ADR-0006）；不等待 Mojo 原生网络模块，与 C5 同一桥接绕过模式（语言：C → Rust，ADR-0010）
- **已决策-16**：WebSocket 增强 = Mojo 驱动会话循环 + WS 路由注册（`/ws` echo / `/ws/counter` 有状态 / `/ws/chat` 必需子协议）+ 子协议协商 + 服务端保活 ping（`FASTAPI_MOJO_WS_PING_MAX`）+ close 码校验（1002）/ text UTF-8 校验（1007）（见 ADR-0007）；桥接内 echo 循环（`ws_upgrade_and_echo`）移除，业务分派归 `run_ws_message` 单点 dispatch
- **已决策-17**：高并发 WebSocket = bridge poll 循环驱动 WS 会话（conn 阶段 3/4）+ FIFO 事件队列（数据帧逐条交 Mojo 分派）+ 控制帧/保活/UTF-8 校验桥接层自动处理（见 ADR-0008）；WS 会话不再阻塞 dispatch，多 WS 会话与 HTTP 并发（e2e：10 并发 + 空闲 WS 下探针 <1s）
- **已决策-18**：WebSocket 精化 = 合并帧尾块丢失 P0 修复（feed consumed 语义 + 每连接尾块重放 + `ws_pump_now` 立即重 pump）+ WS `{param}` 路由/参数分派 + 升级 token 鉴权（403）+ 重组缓冲按需增长（4KB→1MB）+ 事件队列结构上不可溢出（1008 防御）（见 ADR-0009）
- **已决策-19**：**Bridge 层语言终态 = Rust（Mojo + Rust only）** — Rust staticlib
  (C ABI) 替代全部 C bridge（`http_bridge_final.c` / `ws.c` / `runtime_shim.c` →
  Rust 模块）；FFI 表面 / 架构分层 / 单 binary 机制不变；`src/` 下 `*.c` 清零为
  Phase 4 验收红线（见 ADR-0010）

---

*最后更新：2026-09-04（决策-19：Bridge 层语言终态 = Rust（Mojo + Rust only），ADR-0010；
决策-18 WebSocket 精化，ADR-0009；决策-17 高并发 WebSocket，ADR-0008；
决策-16 WebSocket 增强，ADR-0007）*
