# Goal-0002：FastAPI 语义对标 v0.5.0 — 从「能跑 HTTP 的 Mojo demo」到「真正像个 FastAPI」

> **上游**：Goal-0001（Track A/B/C 全部 ✅，终态 Mojo + Rust only 单 binary 零依赖）已达成。
> 本 goal 是 Goal-0001 §4 Phase 4-6 的**首个交付切片**（v0.5.0 范围），不是对 0001 的修订。
> 本 goal 交付后，fastapi_mojo 将具备 FastAPI 的**核心使用体验**：
> 类型化参数自动 422、HTTPException、Request/Response 对象、嵌套 JSON、
> OpenAPI 文档、Streaming/SSE、/metrics、结构化 access log、binary 体积 ≤4.2M。

## 0. 现状定位（2026-09-04 盘点）

**已达成（v0.4.0，Goal-0001 终态）**：
- 语言栈：Mojo（2 645 LOC，10 文件）+ Rust bridge（8 893 LOC，36 文件）+ Rust tool（2 249 LOC，7 文件）；**C = 0，Python = 0**
- 单 binary：`build/fastapi_mojo` **5.2M**（C-only 基线 2.2M，+3M 预算内但可优化）
- 质量门禁：clippy `-D warnings` 0 警告、cargo test 281 passed、e2e 79/79、bench 0 errors
- WebSocket 全链路（ADR-0006~0009）：echo / 有状态 / 子协议协商 / ping-pong / 合并帧 / `{param}` 路由 / token 鉴权

**FastAPI 语义缺口（对标矩阵 23 项，当前覆盖 ~20%）**：

| 能力 | 现状 | FastAPI 标准 | 差距 |
|------|------|------------|------|
| 类型化参数（Path/Query/Body） | String only，无校验 | `int`/`float`/`bool` + 422 | 🔴 核心卖点缺失 |
| 异常 → JSON | 硬编码 400/404/405/413 | `HTTPException` + 自定义 handler | 🔴 核心卖点缺失 |
| Request/Response 对象 | 未暴露 | headers/cookies/status/set_cookie | 🔴 核心能力缺失 |
| 嵌套 JSON 序列化 | 只一层 `Dict[String,String]` | 任意嵌套 object/array | 🟡 常用 |
| OpenAPI 文档 | ❌ | `/openapi.json` + Swagger UI | 🟡 开发者体验 |
| Streaming Response / SSE | ❌ | `StreamingResponse` / `EventSourceResponse` | 🟡 上游热点 |
| Header/Cookie/Form 参数 | ❌ | `Header(...)` / `Cookie(...)` / `Form(...)` | 🟡 常用 |
| 依赖注入（Depends） | ❌ | 解析顺序/缓存/子依赖 | 🟡 杀手级（设计有挑战） |
| 中间件链 | 单层 before/after | 有序链 + 异常透传 | 🟡 常用 |
| 后台任务 | ❌ | `BackgroundTasks` 进程内队列 | 🟢 中等 |
| /metrics 端点 | ❌ | Prometheus 文本 | 🟢 单 binary 差异化 |
| 结构化 access log | `[req_id] METHOD path → status Nms` | JSON 行 + 字段化 | 🟢 运维刚需 |
| Binary 体积 | 5.2M | ≤4.2M（C + 2MB 预算内收口） | 🟢 质量项 |

## 1. 本 goal 目标（成功标准可验证）

### 1.1 范围（v0.5.0 交付物）

| # | 能力 | 交付形态 | 验收 |
|---|------|---------|------|
| **F1** | **类型化 Path/Query/Body 参数**（`int`/`float`/`bool` + 默认值/必填 + 校验失败→422） | `params_typed.mojo`（新模块）；`Handler.data["param_types"]` 声明式类型标注 | e2e 新增 ≥8 用例：int/float/bool 转换、默认值、必填缺失→422、类型错误→422、嵌套 body 校验 |
| **F2** | **HTTPException + 自定义异常处理器**（统一 JSON 错误体 `{detail: ...}`，替换硬编码 400/404/405/413） | `exceptions.mojo`（新模块）；`run_handler` 支持 handler 返回 raise 信号 → dispatch 统一转 4xx/5xx JSON | e2e 新增 ≥4 用例：raise HTTPException(404) → `{"detail":"Not Found"}`；自定义 handler 注册；状态码覆盖 |
| **F3** | **Request/Response 对象**（handler 可读 headers/cookies/method/url；可设 status_code/响应头/set_cookie；支持嵌套 JSON body） | `request_response.mojo`（新模块）；`run_handler` 签名扩展；`json.mojo` 嵌套序列化 | e2e 新增 ≥6 用例：读 header/cookie、set status、set header、set cookie、嵌套 body 回显 |
| **F4** | **OpenAPI 文档**（`/openapi.json` 只读生成 + Swagger UI 静态页） | `openapi.mojo`（新模块）；从 Router 路由表 + Handler 类型标注自动生成；`index.html` 嵌入 Swagger UI | e2e 新增 ≥3 用例：/openapi.json 200 + 路由覆盖 + 类型标注准确 |
| **F5** | **Streaming Response / SSE**（`text/event-stream` + 服务端推送循环；复用 WS 基础设施） | `streaming.mojo`（新模块）；`Handler.data["stream"]` 声明；参考 FastAPI 0.140.12/13 SSE spec 合规 | e2e 新增 ≥3 用例：SSE 连接建立 + 事件推送 + `format_sse_event` 行切分合规 |
| **F6** | **/metrics 端点**（Prometheus 文本格式：requests_total / request_duration_seconds / active_connections） | `metrics.mojo`（新模块）；Mojo 侧计数器 + bridge 侧 gauge | e2e 新增 ≥2 用例：/metrics 200 + 计数随请求增长 |
| **F7** | **结构化 access log**（JSON 行：`{"ts":..,"req_id":..,"method":..,"path":..,"status":..,"duration_ms":..,"worker":..}`） | `middleware.mojo` 扩展（现有 logging 钩子升级）；env 开关 `FASTAPI_MOJO_ACCESS_LOG=json` | e2e 新增 ≥2 用例：JSON log 输出 + 字段完整 |
| **F8** | **Binary 体积瘦身**（去 std 化：`core::ffi`/`core::slice` + 手写字节组装 + 栈缓冲） | Rust bridge 重构（不新增 C，不改 FFI 表面） | binary ≤4.2M（CI 断言）；e2e 79+ 不回归；bench 不倒退 >10% |

### 1.2 阶段划分（roadmap）

| 阶段 | 内容 | 交付物 | 依赖 |
|------|------|--------|------|
| **P1 框架语义核心** | F1 + F2 + F3 | 类型化参数、HTTPException、Request/Response、嵌套 JSON | 无（可并行） |
| **P2 开发者体验** | F4 + F5 | OpenAPI + Streaming/SSE | F1 的类型标注是 F4 输入 |
| **P3 可观测性** | F6 + F7 | /metrics + 结构化 access log | 独立 |
| **P4 体积收口** | F8 | 去 std 化 | 最后做（避免中途破坏稳定性） |

**优先级排序依据**（2026-09-04 用户盘点结论）：
- F1/F2/F3 是「像个 FastAPI」的**门槛**（不做就只是 demo）
- F4 OpenAPI 是开发者体验 ROI 最高的单项
- F5 SSE 是上游热点（0.140.12/13 刚修）+ 复用 WS 基础设施
- F6 /metrics 是单 binary 部署的差异化优势（运维零 agent）
- F7 结构化 log 是运维刚需
- F8 体积收口是质量项，最后做

### 1.3 度量

- **e2e**：79 → **≥105**（+26 用例，覆盖 8 个新能力）
- **单测**：Mojo `test_all.mojo` 扩展 ≥20 用例；Rust bridge 保持 281 + 新增（F8 瘦身不新增逻辑）
- **binary**：5.2M → **≤4.2M**（F8 达成）
- **bench**：get_root_10k_100c 不倒退 >10%（当前 ~42k rps）
- **不变量**：ldd 仅 libc / env -i 干净启动 / clippy 0 警告 / 0 BUG 门禁

## 2. 非目标（anti-goals）

- ❌ 不追求逐字节复刻 FastAPI 全部 API（Mojo 1.0.0 无一等函数/闭包，Depends 等用「类型+数据+单点 dispatch」绕行，F1 的类型标注也是声明式而非 decorator）
- ❌ 不引入第三方 Mojo/Rust crate（除 F8 允许纯 Rust 静态链接 crate 经 ADR 评审；OpenAPI/SSE/metrics 全手写）
- ❌ 不做 HTTP/2 / TLS（P3 观察项；rustls 评审单独立项，不在本 goal）
- ❌ 不做 gzip / CORS 精细配置 / 模块化 Router / lifespan（列入 v0.6.0 候选，不在本 goal）
- ❌ 不追求 Mojo 原生实现一切（Mojo 1.0.0 标准库缺口由 Rust bridge 承载，与 Goal-0001 决策-19 一致）
- ❌ 不改变单 binary 部署形态 / ldd 仅 libc / env -i 启动等不变量
- ❌ 不在本 goal 内做依赖注入（Depends）——设计复杂度高（Mojo 无闭包，需重新设计 dispatch 模型），单独立项评估后再进 v0.6.0

## 3. 风险与约束（6 条架构隔离约束声明）

1. **单 binary 零依赖不变量**：任何新能力必须 Mojo 原生优先，其次 Rust staticlib（C ABI）；禁止新增 Python / C / 系统动态库依赖。F1-F7 全部 Mojo 原生（json.mojo 扩展 + 新模块）；F8 只重构现有 Rust 代码。
2. **用户代码 = 纯数据**：新增路由/处理器 = 数据声明（`Handler.data["param_types"]` / `Handler.data["stream"]` 等）；行为扩展只走显式单点 dispatch（`run_handler` / `run_ws_message`）加 kind 分支。F1-F5 全部遵循此模式。
3. **God-file 阈值**：每个 `.mojo` 文件 < 500 行；新模块（`params_typed.mojo` / `exceptions.mojo` / `request_response.mojo` / `openapi.mojo` / `streaming.mojo` / `metrics.mojo`）均独立文件，不挤入现有模块。Rust bridge F8 瘦身不新增模块（只改实现）。
4. **FFI 表面稳定**：F1-F7 全部在 Mojo 层完成（类型化参数在 `params_*.mojo`、异常在 `exceptions.mojo`、Request/Response 在 `request_response.mojo`、OpenAPI 在 `openapi.mojo`、SSE 在 `streaming.mojo`、metrics 计数器在 Mojo 侧 + bridge gauge 读）；F8 只改 Rust 实现，FFI 符号不变。
5. **决策先行**：F1-F5 涉及 API 语义变更，须先立 ADR（含 6 条约束声明）+ `br` 任务 + e2e 增量；F6-F8 是工具/质量项，可在 goal doc 内决策。禁止「大改后补文档」。
6. **兼容既有模式 + 无回归**：e2e 79/79 全程不回归（每个 F 完成后跑全量）；bench 不倒退 >10%；新增能力用「类型 + 数据 + 零参 def 常量」模式（Mojo 1.0.0 语法约束），不引入新的不可验证技巧。

## 4. 上游参考（FastAPI 语义对齐）

| FastAPI 版本 | 关键能力 | 本 goal 对齐点 |
|------------|---------|--------------|
| 0.141.1（当前最新） | 类型化参数 / HTTPException / Request/Response / OpenAPI / Streaming | F1/F2/F3/F4/F5 直接对标 |
| 0.140.12/13 | SSE 修复（`format_sse_event` 行切分 / streaming `status_code`） | F5 SSE 实现的 spec 合规参考 |
| 0.140.x | `response_model_*` / `exclude_defaults` / stream item type | F1/F4 深水区参考（不在 v0.5.0 范围） |

> 注：本 goal 对标的是 FastAPI **常用语义子集**（类型化参数 + 422 + HTTPException + Request/Response + OpenAPI + Streaming/SSE），不是逐字节复刻。详见 §2 非目标。

## 5. 关联决议 / 工件

| 工件 | 与本 goal 的关系 |
|------|----------------|
| Goal-0001 | 上游：Track A/B/C 终态已达成；本 goal 是其 Phase 4-6 的首个交付切片 |
| ADR-0004 | 路由注册机制 — F1/F4 的类型标注输入源 |
| ADR-0006~0009 | WebSocket 全链路 — F5 SSE 复用其会话/事件基础设施 |
| ADR-0010 | Rust bridge — F8 去 std 化的实施载体 |
| `scripts/e2e_test.sh` | 79 项基线，每个 F 完成后跑全量不回归 |
| beads (`br`) | 每个 F 建独立任务并跟踪状态 |
| `docs/reports/auto/` | benchmark 历史快照（JSONL） |

## 6. 任务清单（beads）

| # | 任务 | 阶段 | 状态 | 验收 |
|---|------|------|------|------|
| T1 | F1 类型化 Path/Query/Body 参数 + 422 | P1 | ⬜ | e2e +8；`params_typed.mojo` <500 行 |
| T2 | F2 HTTPException + 自定义异常处理器 | P1 | ⬜ | e2e +4；`exceptions.mojo` <500 行 |
| T3 | F3 Request/Response 对象 + 嵌套 JSON | P1 | ⬜ | e2e +6；`request_response.mojo` <500 行 + `json.mojo` 嵌套扩展 |
| T4 | F4 OpenAPI 文档（/openapi.json + Swagger UI） | P2 | ⬜ | e2e +3；`openapi.mojo` <500 行 |
| T5 | F5 Streaming Response / SSE | P2 | ⬜ | e2e +3；`streaming.mojo` <500 行 |
| T6 | F6 /metrics 端点（Prometheus 文本） | P3 | ⬜ | e2e +2；`metrics.mojo` <500 行 |
| T7 | F7 结构化 access log（JSON 行） | P3 | ⬜ | e2e +2；`middleware.mojo` 扩展 |
| T8 | F8 Binary 瘦身（去 std 化 ≤4.2M） | P4 | ⬜ | binary ≤4.2M；e2e 不回归；bench 不倒退 |
| T9 | v0.5.0 发布（版本 bump + release notes + push） | P4 | ⬜ | tag v0.5.0 + release branch |

## 7. 验收红线（全部必须达成）

- [ ] e2e 从 79 → **≥105**（8 个 F 全部落地）
- [ ] Mojo `test_all.mojo` 扩展 ≥20 用例
- [ ] binary 体积 **≤4.2M**（F8 达成）
- [ ] bench `get_root_10k_100c` 不倒退 >10%
- [ ] `ldd build/fastapi_mojo` 仅 libc
- [ ] `env -i ./build/fastapi_mojo` 干净启动
- [ ] clippy `-D warnings` 0 警告（fmtool + fastapi_mojo_rs）
- [ ] cargo test 281 + 新增全绿（0 BUG 门禁）
- [ ] 每个新 `.mojo` 文件 <500 行
- [ ] 每个 F 完成后全量 e2e 不回归

---

*最后更新：2026-09-04（v0.5.0 范围定稿：F1-F8 8 项能力，P1-P4 四阶段；上游 Goal-0001 终态已达成；FastAPI 0.141.1 为对标基线）*
