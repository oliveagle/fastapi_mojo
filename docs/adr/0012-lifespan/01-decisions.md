# ADR-0012: Lifespan（startup/shutdown）— 声明式 env 命令 + FFI NUL 终止契约（发现并修复）

- **日期**：2026-09-05
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P1 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-36**）、Goal-0003（T-P1c Lifespan）、
  ADR-0004（路由注册「用户代码 = 数据」扩展点模式）、ADR-0005（多 worker re-exec 模型）、
  ADR-0010（Rust bridge 分层）、F11 BackgroundTasks（决策-29，复用 `run_command_json`
  FFI）、FastAPI `lifespan`（上下文管理器语义对标）

## 1. 背景

FastAPI 的 **Lifespan**（`lifespan` 上下文管理器）是 Goal-0003 矩阵**第 19 项**
（❌ 缺失）：`async with lifespan(app): yield` — yield 前 = startup（每进程一次，
服务开始接请求之前），yield 后 = shutdown（服务停止之后）；**startup 抛异常 →
uvicorn 启动失败，进程退出**。典型用途：数据库连接/初始化、缓存预热、清理。

约束（Mojo 1.0.0 + North Star）：
- Mojo 1.0.0 **无闭包 / async / lifespan 对象** → 只能用**声明式 env 命令**
  （shell，换行分隔）近似；单 binary 无 Python，等价能力 = 系统命令
- 执行机制必须复用既有（`run_command_json` FFI：`/bin/sh -c` + fork/poll +
  进程组 timeout SIGKILL，F11 已验证），不新增 syscall 面
- 多 worker（ADR-0005 re-exec 模型）下不得重复执行（N 个进程各跑一次 init 是错的）

**实现过程中发现并修复了一个贯穿 bridge 的 FFI 契约 bug**（见 §3.5）：
Mojo `CStringSlice.as_bytes()` 按 **C 串语义读到首个 NUL（忽略 `fmc_slice.len`）**。
probe 实测：len=28 且缓冲内无 NUL 的 slice，实际返回 **50 字节**（越过声明 len，
一路读到相邻 Rust static 里的 NUL，垃圾包括其他 static 的字符串 `src/bridge/shim.rs`）。
这解释了为什么既有 slice 全部「碰巧正确」——决策-20 的 NUL 终止修复
（`g.method[mlen]=0` 等）不只是 C 兼容，**正是 Mojo 读取路径的硬性前提**。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. Mojo 代码直写 main() | 用户把 startup/shutdown 逻辑写在 `main()` 里 serve_forever 前后 | ❌ 部署时不可配置（须重编译），不是「应用级配置」；且与 e2e/CI 无法注入差异行为（无法测失败路径） |
| B. **声明式 env 命令（本 ADR）** | `FASTAPI_MOJO_LIFESPAN_STARTUP/SHUTDOWN` = 换行分隔 shell 命令，经 `run_command_json` FFI 执行；仅主进程执行；startup 失败 → 退出 | ✅ 与 ADR-0004 声明式风格一致；复用 F11 执行机制（零新 syscall）；部署时可配置；e2e 可验证（文件创建/进程退出）；Mojo 代码仍可并行使用 main() 直写（互补，不冲突） |
| C. 通用配置文件 | 启动时读 JSON/YAML 配置执行 | ❌ 需解析器（json.mojo 只有序列化器）；为两个 env 值引入配置子系统 = 过度工程 |

**决策：B** —— 声明式 env 命令 + 单一扩展点（决策-36）。

## 3. 决策

1. **声明式 API**（环境契约，部署时配置，与 `FASTAPI_MOJO_ACCESS_LOG` 等同族）：
   - `FASTAPI_MOJO_LIFESPAN_STARTUP`：startup 命令（**换行分隔**，每行 trim 空白，
     空行跳过；命令内不含换行）
   - `FASTAPI_MOJO_LIFESPAN_SHUTDOWN`：shutdown 命令（同上）
   - `FASTAPI_MOJO_LIFESPAN_TIMEOUT_MS`：单条命令 timeout（默认 30000 ms，
     超时整组 SIGKILL）
2. **语义对齐 FastAPI/uvicorn**：
   - startup：`main()` 里 **bind 之后、`serve_forever` 之前**（uvicorn 同样先
     bind 再跑 lifespan）；命令在接请求之前完成
   - shutdown：`serve_forever` 返回（收到停止信号）之后
   - **startup 任一命令 rc≠0 → 打印 ERROR + `bridge_fail`（进程退出，服务不启动）**
     —— FastAPI lifespan 异常 → uvicorn 启动失败的同构语义
   - shutdown 失败只记日志（rc≠0 已输出），不阻塞进程退出
3. **多 worker 门控（ADR-0005 re-exec 模型）**：仅**主进程**（`worker_id=0`）
   执行 startup/shutdown；re-exec 出的 worker（`worker_id>0`）跳过 —— 对齐
   **nginx master init** 语义（init 脚本只在 master 跑一次），避免 N 倍重复执行。
   门控在 Mojo 侧（`if worker_id > 0: return`），Rust 侧不感知 worker。
4. **执行机制**：复用 `run_command_json` FFI（`/bin/sh -c` + fork/poll + 进程组
   timeout kill，与 F11 BackgroundTasks 同一机制）。命令切分/trim/日志在 Mojo
   `lifespan.mojo`；rc 解析 = JSON 输出第一个 `"rc":`（cmd.rs 固定 key 序，
   out 字段内同名文本不干扰——第一个出现优先；未找到 → -1 → 视为失败）。
   env 一次性读取 + `OnceLock` 缓存（Rust 侧，与 `get_access_log_mode` 同模式）。
5. **🔴 NUL 终止契约（通用 FFI 约束，写入 AGENTS.md §3.2 build 守则）**：
   - **Mojo `CStringSlice.as_bytes()` 按 C 串语义读到首个 NUL，忽略
     `fmc_slice.len`**（probe 实测：len=28 无 NUL → 实读 50 字节含堆/static 垃圾；
     len=3 且 [3]=0 → 恰好 3 字节）。
   - 因此 **bridge 返回的每个 fmc_slice 缓冲必须 `[len]=0`**。
   - 全量审计（决策-36）：method/path/query（决策-20 NUL 修复）、header_value
     （`hdr_value[n]=0`）、metrics（零初始化 4096 缓冲）、body（决策-20 +1 NUL 槽）、
     ws_key（`ws_key[klen]=0`）、ws_protocol/offer（决策-20 `push(0)`）、ws_path
     （决策-20 `push(0)`）、ws_reasm（parser 消息完成时 `reasm[reasm_len]=0`）
     —— 全部已 NUL 终止 ✅。
   - **修复 ×2**：
     1. `run_command_json` FFI：`malloc(n)+memcpy(n)` → `malloc(n+1)+memcpy(n)+
        [n]=0`（**C bridge 时代遗留潜伏 bug**：F11 `out=` 日志尾部一直带堆垃圾，
        无人校验过尾部）。回归守护：`cargo test
        ffi_run_command_json_nul_terminated`。
     2. 新增 lifespan env 串：`OnceLock<Vec<u8>>` = env bytes + 尾 NUL，FFI len
        = `v.len()-1`（NUL 不计入）。
6. **文件布局（扩展点模式，核心零 dispatch 改动）**：
   - Rust：`bridge/lifespan.rs`（env OnceLock + NUL 终止 + `parse_timeout`/
     `read_env` 纯函数 + 7 单测）+ `ffi.rs` 3 个新导出
   - Mojo：`lifespan.mojo`（~140 LOC：`_parse_cmd_rc` / `_run_commands` /
     `run_lifespan_startup` / `run_lifespan_shutdown` / `main()` 自测）
   - 核心：`http_server_final.mojo` 仅 +1 import、+2 调用点（`main()` 内 bind
     后 / `serve_forever` 后）；**dispatch 主循环零改动**
   - e2e：LS-1..LS-4（4 项）

## 4. 边界与已知限制

- **shell 命令是 Python lifespan 的声明式近似**：能表达「启动时初始化/停止时清理」
  的系统级动作；若需把 startup 结果传给请求 handler，handler 自行读文件/env
  （Mojo 无 `app.state`，单 binary 场景下文件/env 是状态载体）。
- timeout 30s 是**单条命令**上限（整组 kill）；长初始化调
  `FASTAPI_MOJO_LIFESPAN_TIMEOUT_MS`。
- 多 worker 下 lifespan 只跑一次（master）；worker 进程内的初始化（如有）需
  写在 worker 可重入的命令里或走 handler 惰性初始化。

## 5. 风险

| 风险 | 缓解 |
|------|------|
| 命令注入（env 值来自部署者） | env 即部署者信任边界（与 systemd unit / Docker CMD 同级）；非攻击面 |
| startup 命令挂死 | 进程组 timeout SIGKILL（默认 30s），rc=137 → 启动失败退出 |
| 多 worker 重复执行 | worker_id 门控（仅 0）；e2e + 8 轮 stress 实测 count=1 |

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`http_server_final`（main 调用点）→ `lifespan`（两入口函数）→ `string_builder`（span_to_str）+ `std.ffi`（external_call）。lifespan 不 import http_server_final；无回调上溯 |
| 2. 分层向下依赖 | ✅ 遵守 | 命令执行 = **系统 I/O**（复用 Rust bridge 既有 `run_command_json`，零新 syscall）；env 读取 = **进程配置**（Rust OnceLock，state.rs 同模式）；切分/rc 解析/日志 = **业务层**（Mojo lifespan.mojo）。与 ADR-0010 分层一致 |
| 3. God package 阈值 | ✅ 遵守 | `lifespan.mojo` 140 LOC（< 500）；`lifespan.rs` ~135 LOC（< 500）；核心 `http_server_final.mojo` 仅 +3 行（1 import + 2 调用点），无 dispatch 膨胀 |
| 4. 主题域边界清晰 | ✅ 遵守 | `lifespan.mojo` 只做 startup/shutdown 两阶段（读 env 串 + 执行 + 失败短路），不感知路由/序列化/WS/metrics；NUL 终止契约是 **bridge 级通用约束**（写入 AGENTS.md §3.2），不专属本功能 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | FFI diff = **+3 导出**（`get_lifespan_startup_slice` / `get_lifespan_shutdown_slice` / `get_lifespan_timeout_ms`）+ **1 修复**（`run_command_json` malloc(n+1) NUL 收尾）；契约文档化（NUL 终止，lifespan.rs/ffi.rs 注释 + AGENTS.md） |
| 6. 测试文件跟随 | ✅ 遵守 | Rust：`lifespan.rs` 7 单测（parse_timeout ×4 / read_env ×2 / env 名钉死 ×1）+ `cmd_tests.rs` 1 回归（NUL 契约）= **307 passed / 0 failed / 4 ignored**；Mojo：`lifespan.mojo` `main()` 自测（rc 解析 7 向量含负数/缺失/out 内干扰）；e2e **LS-1..LS-4 = 168/168 全绿**；`cargo clippy --release --tests -D warnings` **0 警告** |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动；
   体积 2.9M（≤4.2M）。
2. **e2e 全量不回归**：164 → **168**（+4 LS 项）全绿。
3. **质量门禁**：`cargo clippy --release --tests -- -D warnings` 0 警告；
   `cargo test --release -- --test-threads=1` **307 passed / 0 failed / 4 ignored**。
4. **Lifespan 功能路径**：
   - startup：2 条换行分隔命令在 serve 前执行（文件存在 + health 200）
   - shutdown：SIGTERM 优雅停止后执行（文件存在）
   - 失败短路：`exit 3` startup → 进程退出 + 端口不可达 + 日志
     "refusing to serve"
   - 多 worker 8 轮 stress：每轮 startup **恰好执行 1 次**（count=1）、无崩溃、
     无命令串损坏、无孤儿进程
5. **NUL 契约 probe 实测**（诊断用，已删）：
   - len=3 + [3]=0 → `as_bytes()` 恰好 3 字节 ✅
   - len=28 + 无 NUL → `as_bytes()` 实读 **50 字节**（含 "live" 堆垃圾 +
     相邻 static 字符串 `src/bridge/shim.rs`）❌ → 证实契约
   - 修复后 8 轮 stress 日志零垃圾（`cmd=`/`out=` 精确到字节）
