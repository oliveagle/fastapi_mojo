# ADR-0037: Staged OpenTelemetry in-memory traces

**状态**：已接受
**日期**：2026-09-12
**决策**：62（Goal-0003 observability extension / `otel` bead）

## 1. 背景

项目已有 Prometheus `/metrics` 与 JSON access log，但缺少分布式追踪的可观测
出口。OpenTelemetry 的完整网络 exporter 需要 OTLP/HTTP 或 protobuf 编解码、
后台重试队列、DNS/TLS 与时钟/采样策略；这些都不是当前 FastAPI 语义对标的最小
闭环，且会显著扩大运行期依赖面。

本 bead 的第一阶段目标是先提供**可验证、有界、零第三方依赖的 server span
缓冲**，为未来 OTLP exporter 保留同一数据形态。

## 2. 候选方案

| 方案 | 描述 | 判定 |
|------|------|------|
| A. 继续只提供 metrics/access log | 不新增 ABI 或内存面 | ❌ traces 缺口仍无法验证 |
| B. 直接实现 OTLP/HTTP exporter | 后台线程、重试、网络 I/O、TLS/protobuf 依赖 | ❌ 违反 staged 边界，且引入 North Star 风险 |
| C. **有界进程内 trace ring + `/traces` OTLP JSON-shaped 导出** | 每请求一个 server span，容量固定，`FASTAPI_MOJO_OTEL=1` opt-in | ✅ 可先落地语义与数据形态，后续 exporter 复用 |
| D. 把 span 写入 access log | 复用日志输出，不新增端点 | ❌ 不是 OTLP 结构，工具链难以消费 |

**决策**：C。

## 3. 决策

### 3.1 开关与生命周期

- 环境变量 `FASTAPI_MOJO_OTEL=1` 显式开启；默认关闭；
- Mojo 侧统一由 `_finish_request(...)` 作为响应后 telemetry hook：
  - 先执行既有 `mw_logging`；
  - 开关开启时记录一个 OpenTelemetry server span；
- hook 覆盖普通路由、错误、middleware、static、OpenAPI/docs、metrics、
  `/traces`、SSE/file 与 WebSocket upgrade/rejection 边界；
- `/traces` 先渲染当前快照，再记录本次 `/traces` 请求，避免导出结果依赖
  未完成的自身 span。

### 3.2 有界缓冲

- 每个 worker/process 一个 trace ring，容量 **128 spans**；
- 超容量时淘汰最旧 span；
- method/path/query/status 均做长度与 NUL 防御，导出渲染缓冲有固定上限；
- ring 使用 `Mutex + VecDeque` 与原子序列号，不引入第三方 crate。

### 3.3 `/traces` OTLP JSON 形态

响应 `Content-Type: application/json`，顶层为：

```json
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "fastapi_mojo"}}
        ]
      },
      "scopeSpans": [
        {
          "scope": {"name": "fastapi_mojo.bridge"},
          "spans": []
        }
      ]
    }
  ]
}
```

每个 span 包含：

- 32 hex `traceId` / 16 hex `spanId`；
- `kind: 2`（SERVER）；
- `startTimeUnixNano` / `endTimeUnixNano`；
- attributes：
  - `http.request.method`
  - `url.path`
  - `url.query`
  - `http.response.status_code`
  - `fastapi_mojo.duration_ms`
- OTel status：`1`（Unset/OK 边界阶段的非错误表达）或 `2`（Error，5xx）。

### 3.4 架构与 ABI

- 新 Rust bridge 模块：`bridge/otel_traces.rs`；
- **FFI diff = +2**：
  - `otel_trace_record(method, path, query, status, duration_ms)`
  - `get_traces_block()`
- `get_traces_block` 返回的静态 slice 满足既有 FFI NUL 终止契约；
- 不新增系统动态库、C 源文件或 Python 路径；
- 网络出口、跨进程聚合、context propagation、采样器均留给后续决策。

## 4. 风险与权衡

| 风险 | 处置 |
|------|------|
| tracing 热路径带来性能回归 | 默认关闭；开启后仅一次固定容量 push，不执行网络 I/O |
| 长时间运行内存无界增长 | ring 固定 128 项，字符串字段与渲染缓冲均有上限 |
| 多 worker 下 `/traces` 只看到一个进程 | 与 `/metrics` 一致，按 worker 隔离；跨进程聚合是后续 exporter 边界 |
| 导出 JSON 被特殊字符破坏 | 复用 bridge JSON escape；NUL 被移除，UTF-8 lossy 替换 |
| 直接引入 OTLP exporter 拉入第三方依赖 | 本决策仅固化 OTLP JSON 形态，网络 exporter 单独评估 |
| self-trace 让测试结果不稳定 | `/traces` 先 snapshot 后 record |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | `http_server_final → FFI → otel_traces → response/time_util` 单向；trace 模块不回读 Router/Handler |
| 2. 分层向下依赖 | ✅ 遵守 | Mojo 请求边界只通过显式 C ABI 调 Rust 有界缓冲；trace 模块无 socket/文件/进程新增 syscall |
| 3. God package 阈值 | ✅ 遵守 | 新 `otel_traces.rs` 161 行、`otel_traces_tests.rs` 36 行；Mojo 只集中一个 `_finish_request` telemetry hook，不新增协议分支包 |
| 4. 主题域边界清晰 | ✅ 遵守 | observability 独立成 Rust 子模块；路由/handler/OpenAPI/WS 语义不感知 trace 细节 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff=+2**，两个 `extern "C"` 导出集中登记；无第三方 crate、无 C 源、NUL 契约有单测 |
| 6. 测试文件跟随 | ✅ 遵守 | `otel_traces_tests.rs` 与生产模块同目录；e2e 直接验证真实 binary 与默认关闭行为 |

## 6. 验收（2026-09-12）

- Rust bridge：**472 passed / 0 failed / 4 ignored**；clippy `-D warnings` **0 警告**
- fmtool：**35 passed / 0 failed**；clippy `-D warnings` **0 警告**
- build：`./build_single.sh` 成功；binary **4,184,272 B**（≤4.2M）
- e2e：497 → **504/504**（新增 OT-0..OT-6，既有 497 零回归）
- benchmark：6 场景 **0 errors**；get_root_10k_100c = **33,863.87 req/s**
- ldd：仅 libc/loader/vdso
- clean env：`env -i PATH=/usr/bin:/bin ./build/fastapi_mojo …` health 200，退出无孤儿
- `find src -name '*.c'` = 0；仓库交付面 `*.py` = 0

## 7. 文档化偏差 / 边界

1. 本决策是**阶段化 traces**，不是完整 OTLP collector/exporter；
2. trace/span ID 为进程内单调序列的固定宽度 hex，不是密码学随机 ID；
3. start/end nanosecond 由整数毫秒 duration 推导，保留毫秒级精度；
4. ring 与 `/traces` 均按 worker 隔离，不做跨进程聚合；
5. 尚无 W3C trace context 传播、采样器、span exporter 或 WebSocket 消息内部子 span。

## 8. 实现

- `src/fastapi_mojo_rs/src/bridge/otel_traces.rs`：有界 ring、OTLP JSON renderer、FFI NUL slice
- `src/fastapi_mojo_rs/src/bridge/otel_traces_tests.rs`：OTLP 形态与 NUL 契约单测
- `src/fastapi_mojo_rs/src/bridge/ffi.rs`：`otel_trace_record` / `get_traces_block` C ABI 导出
- `src/fastapi_mojo/http_server_final.mojo`：`_finish_request` 统一 access log + optional trace completion hook
- `scripts/e2e_test.sh`：OT-0..OT-6 真实 binary 集成测试
- `.github/workflows/ci.yml`、`AGENTS.md`、`docs/goals/0003-fastapi-full-parity.md`：504 门禁与决策-62 记录
