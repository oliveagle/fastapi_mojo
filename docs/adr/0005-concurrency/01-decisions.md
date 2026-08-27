# ADR-0005: 并发化 — 多进程 worker + SO_REUSEPORT（nginx pre-fork 模型）

- **日期**：2026-08-28
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行）
- **关联**：ADR-0003（单 binary 机制）、`http_bridge_final.c`（事件循环 + worker 派生）、AGENTS.md §5（"Mojo 异步/并发模型不稳定"风险项）

## 1. 背景

v11 事件循环消除了 I/O 头阻塞（空闲/慢连接不再卡住其他客户端），但请求
**处理**仍是单进程串行：一个 poll 循环、一次一个请求。实测单进程上限
~48k rps（100c），500c 场景 P99 高、max ≈ 总时长（排队深度 = 全部请求数）。
AGENTS.md §5 早已标注风险："Mojo 异步/并发模型不稳定"——Mojo 1.0.0 无
成熟 async，且运行时（KGEN/AsyncRT）线程安全性未经验证，主线程之外调用
Mojo 代码（dispatch/run_handler）是禁区。

## 2. 候选方案

| 方案 | 评估 |
|------|------|
| **A) C 线程池：worker 线程 accept+parse，主线程 dispatch** | parse 是 C 速度（不是瓶颈）；瓶颈是 Mojo dispatch，仍串行 → 吞吐不升，只增加复杂度与跨线程队列。否决 |
| **B) 多进程 worker + SO_REUSEPORT（nginx pre-fork）** | 每个 worker 是完整独立进程（自己的 Mojo 运行时 + poll 循环），内核按连接 hash 分发。真并行：吞吐 ≈ N×单进程，尾延迟 ≈ 单 worker 队列深度。进程隔离 = 无共享内存/锁/线程安全问题；一个 worker 崩溃不影响其他。与单 binary 模型兼容（worker 是自身 re-exec）。**选定** |
| C) fork 后不 re-exec（共享运行时状态） | KGEN/AsyncRT 运行时可能在启动时持有线程/锁，multithreaded 进程里 fork 有死锁风险（POSIX 明确告诫）；re-exec 后每个 worker 运行时全新初始化，无此风险。否决 |
| D) 等 Mojo 上游 async/并发成熟 | AGENTS.md 风险项；时间不可控，且单 binary 场景下进程模型比 async 更稳（隔离性）。作为长期方向记录，不阻塞 |

## 3. 决策

### 3.1 机制

1. **派生**：`init_workers()`（C 桥接，main 里 create_bound_socket 之前调用）。
   读 `FASTAPI_MOJO_WORKERS`（默认 **1 = 现状单进程**）：
   - N>1 且自身不是 worker → 成为 worker 0，fork N-1 个子进程；
     每个子进程 `setenv(FASTAPI_MOJO_WORKER=i)` 后 **re-exec 自身**
     （`/proc/self/exe` + `--port <port>`）——全新进程、全新运行时初始化。
   - 自身是 worker（env 已设）→ 不再派生。
2. **端口共享**：`create_bound_socket` 增加 `SO_REUSEPORT`（与既有
   SO_REUSEADDR 并存）；每个 worker 各自 bind 同一端口，内核按 4-tuple
   hash 把新连接分给某个 worker。已建连接粘性于其 worker（与 nginx 一致）。
3. **资源**：每 worker 独立暂存运行时（ADR-0003 机制，按 pid 的 mkdtemp）
   + 独立嵌入静态文件暂存 + 独立 req 计数/req_id（per-worker 序列，文档化）。
   8 worker ≈ 8×2MB /dev/shm 暂存（可接受）。
4. **优雅退出**：worker 继承 SIGINT/SIGTERM handler；`pkill -x fastapi_mojo`
   （按进程名）杀全部 worker。spawner 即 worker 0，无额外 supervisor。
   （supervisor 自动重启 = 超出本 ADR 范围，记录为后续可选。）

### 3.2 否决 A（线程池）的量化理由

单进程瓶颈 = Mojo dispatch 串行（~48k rps 天花板）。线程池化 accept/parse
不改变 dispatch 串行性（运行时非线程安全，dispatch 必须回主线程）→
吞吐不变 + 跨线程请求队列 + per-conn 状态跨线程保护 ≈ 纯成本。
进程模型则把 dispatch 本身并行化（N 份独立运行时）。

### 3.3 约束与边界

- **默认行为不变**：`FASTAPI_MOJO_WORKERS` 未设 = 1 worker = 现状。
  多 worker 是显式 opt-in。
- 连接粘性：SO_REUSEPORT 按新连接分发；单连接内请求始终同 worker
  （天然保持 keep-alive 语义）。
- req_id 为 per-worker 序列（跨 worker 可能重号）——request_id 仅用于
  单连接日志关联，功能无影响（文档化）。
- 崩溃隔离：单 worker 崩溃只影响其持有的连接；内核把新连接分给存活 worker。
- 静态文件/运行时暂存按 pid 隔离，无跨进程竞争；启动时 sweep 只清
  "pid 已死"的目录（P3.1 机制复用，天然兼容多 worker）。

## 4. 决策结果

- `http_bridge_final.c`：`init_workers()`（fork+re-exec 派生）、
  `create_bound_socket` 加 SO_REUSEPORT、`get_worker_id()`。
- `http_server_final.mojo`：main 启动时调用 `init_workers()`；
  banner 打印 worker 号（多 worker 时）。
- 部署：`FASTAPI_MOJO_WORKERS=8 ./fastapi_mojo --port 8000` 即可横向扩展；
  deploy.sh/README 补充说明。
- 验收基准（见 §6）：200 并发下 p99 < 50ms 且 rps ≥ 3× 单进程。

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | worker 派生逻辑在 C 桥接（init_workers → fork/exec），不依赖 Mojo 层；Mojo 只调用 init_workers()/get_worker_id()，方向单向 server→bridge |
| 2. 分层向下依赖 | ✅ 遵守 | 并发机制位于 C 桥接/OS 层（fork、SO_REUSEPORT、内核连接分发）；Mojo 业务层（路由/handler/中间件）零改动，不感知进程模型 |
| 3. God package 阈值 | ✅ 遵守 | 增量仅 ~90 行 C（init_workers + SO_REUSEPORT + get_worker_id），为内聚的并发子系统；Mojo 侧 < 10 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | 并发/进程模型是部署-运行时主题，与 ADR-0003（单 binary 暂存）同域协同：worker re-exec 复用 shim 暂存/sweep 机制，不引入新主题文件 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | 唯一的进程模型入口是 C 桥接 init_workers()（显式函数、env 驱动、文档化）；无隐式 fork（只在 main 启动路径调用一次）；re-exec 用 /proc/self/exe 显式定位 |
| 6. 测试文件跟随 | ✅ 遵守 | 单 worker 行为由既有 e2e（56 项）固化（默认路径不变）；多 worker 验收 = 可重复的 hey 200c 基准（commit 记录）+ init_workers 的 env 分支代码评审；e2e 默认 1 worker 不受影响 |

## 6. 验证方式

1. 默认（无 env）：`./build_single.sh && ./build/fastapi_mojo` 行为与 v11
   完全一致（e2e 56/56 复跑）。
2. `FASTAPI_MOJO_WORKERS=8` 启动：`pgrep -c -x fastapi_mojo` = 8；
   `ss -ltn | grep :8000` 显示 8 个 LISTEN（SO_REUSEPORT）。
3. hey -n 20000 -c 200：rps ≥ 3× 单进程基线，p99 < 50ms（§4 验收）。
4. 单 worker 崩溃（kill -9 其中一个 pid）：其余 worker 继续服务；
   新连接由存活 worker 接收。
5. 进程全部退出后 /dev/shm 无 fastapi_mojo_rt_* 残留（atexit + sweep）。
