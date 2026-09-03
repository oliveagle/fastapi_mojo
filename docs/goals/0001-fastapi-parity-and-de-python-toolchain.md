# Goal-0001：FastAPI 对标实现 + 全链路去 Python 化（Phase 4+）

- **日期**：2026-09-04
- **状态**：🚧 进行中（roadmap / 待排期）
- **负责人**：oliveagle（agent 执行）
- **上游**：`AGENTS.md`（§1 North Star / §3 架构约束 / §6 决议链）、`docs/adr/0001~0009`
  （已接受决策）、`docs/migrate_mojo/todo.md`（bootstrap 时代历史规划，已废弃，仅参考）
- **说明**：本文件是 `docs/goals/` 下**第一个** goal 文件。仓库此前无 goals 目录；
  本 goal 在既有 ADR 决策链与各 ADR `tasks.md` 的「后续」清单基础上向前推进。

---

## 1. 北极星引用

> **AGENTS.md §1**：用 Mojo 将代码编译成**单一 Binary，运行时零外部依赖**；
> 部署 = `scp` 一个文件即运行。任何引入新 Python 依赖的 PR 都是倒退；
> 任何依赖系统 Python 运行时的代码路径，最终都必须被 Mojo 原生实现替换。

**已达成现状**：Phase 3 单一 binary 交付（ADR-0003 决策-14，运行时嵌入 + 启动暂存 +
dlopen 符号转发）；`ldd build/fastapi_mojo` 动态依赖仅 libc；`env -i` 可干净启动。

**本 goal 的两条主线**（都是对北极星的延续，不是推翻）：

1. **Track A — FastAPI 对标**：把 Mojo 侧框架从「demo server」推进到「可对标 FastAPI
   常用语义的框架」（类型化参数、异常、Request/Response 对象、依赖注入、表单/文件、
   流式响应等），**全部 Mojo 原生 / C FFI 随 binary 打包**。
2. **Track B — 全链路去 Python**：把构建 / 测试 / 压测工具链里**剩余的所有 Python
   环节**替换为纯 shell / C / Mojo，最终仓库 `*.py` 清零、`.venv` 移除。

---

## 2. 现状盘点（2026-09-04 基线）

### 2.1 运行时：✅ 已 0 Python（本 goal 不触碰）

- Mojo 原生 HTTP server（C FFI socket 桥接 + 原生协议层）+ 原生 JSON（json.mojo
  线性序列化）+ 原生 Router / 参数解析 / 异常→JSON。
- WebSocket 全链路（ADR-0006~0009，决策-15~18）：多端点、{param} 路由、子协议、
  保活 ping、close 码 / UTF-8 校验、高并发（C poll 循环 + Mojo 逐消息分派）、
  鉴权 token、合并帧尾块 P0 修复。
- 并发：多进程 worker + SO_REUSEPORT（ADR-0005）。

### 2.2 工具链：⚠️ 剩余 Python 环节（Track B 目标，共 3 处）

| # | 环节 | 现状（Python 用法） | 目标替代方案 | 工作量 |
|---|------|--------------------|--------------|--------|
| T1 | `bench.py` + `benchmark.sh` | 唯一 `.py`；stdlib 实现 HTTP(hey)/WS 负载；`.venv` 仅为它保留 | Mojo 原生 bench 二进制（或纯 shell + curl + 内置 WS 客户端）；移除 `.venv` | 大 |
| T2 | `scripts/e2e_test.sh` | `python3` 生成畸形字节流 hex / 大 payload / WS 客户端 / keep-alive / HEAD body 校验 | 纯 shell（printf/od/openssl）+ 仓库内小 C 工具（随测试构建）| 中 |
| T3 | `build_single.sh` | `python3 -c 'import modular…'` 定位 Mojo 运行时 lib | shell 探测 `$MODULAR_LIB` + 固定路径候选扫描（`~/.modular/pkg/packages/…`）| 小 |

> 约束：工具链去 Python **只影响 build/test/bench**，不得改变运行时交付物（single
> binary 仍零依赖）。CI 里 Mojo 安装本身仍可借 python-pip（工具链启动依赖，可接受）。

### 2.3 FastAPI 对标缺口（Track A 目标，优先级排序）

**已有能力**：GET/POST/PUT/DELETE、Path `{param}` / Query / JSON Body 参数
（`Dict[String,String]`）、静态文件嵌入、before/after 钩子 + timing、CORS、限流、
/health /status /routes、WebSocket 全套、keep-alive。

**对标缺口（按 P0→P3 排序，详见附录 A 矩阵）**：

- **P0 框架语义**（建议 Phase 4）：类型化参数（Int/Float/Bool/List/嵌套 JSON，不再
  只有 String）、`HTTPException` + 自定义异常处理器→统一 JSON 错误体、Request/Response
  对象（读 headers/cookies、改 status_code、自定义响应头）、响应嵌套序列化。
- **P1 API 表面**（建议 Phase 5）：Header/Cookie 参数、表单（urlencoded/multipart）、
  文件上传、依赖注入（Depends 语义）、中间件链（顺序/优先级）、后台任务、
  Streaming/File/Redirect Response。
- **P2 框架生态**：URL 解码（`{param}` 含 `%xx`）、NUL 回复 FFI 协议修订
  （ADR-0007 §5 教训 3）、鉴权链统一（首帧 token / 自定义头 / 与 HTTP 中间件统一）、
  模块化 Router/APIRouter、OpenAPI 文档、lifespan 事件、JWT/OAuth2 助手、模板渲染。
- **P3 协议/服务器**：gzip 压缩、Range/静态缓存头、TLS/HTTPS（可选，需新 C 依赖评估）、
  HTTP/2（远期，不承诺）。

---

## 3. 目标（成功标准可验证）

1. **Track A**：覆盖 P0 全部 + P1 大部分 + P2 可落地子项，全部 Mojo 原生 / C FFI
   随 binary 打包；`e2e` 从 79 项扩展到 ≥ 120 项，覆盖每个新特性。
2. **Track B**：仓库 `find . -name "*.py"`（排除 `.venv`）→ **0 个**；`.venv` 删除；
   `benchmark.sh` / `scripts/e2e_test.sh` / `build_single.sh` 中 `python3` 调用清零。
3. **不变量保持**：`ldd` 仅 libc；`env -i ./build/fastapi_mojo` 干净启动；
   CI（build + ldd + 干净环境 + unit + e2e）全绿；每个 `.mojo` 文件 < 500 行。
4. **任务治理**：每个子项以 beads（`br`）建任务；每项重大特性/协议变更写新 ADR
   （含 6 条架构隔离约束声明）+ e2e 增量 + README/AGENTS 对齐。

---

## 4. 非目标（anti-goals）

- ❌ 不追求「逐字节复刻 FastAPI 全部 API」——只对标**常用语义**，Mojo 1.0.0 语法
  约束不允许的能力（一等函数/闭包）用「类型 + 数据 + 单点 dispatch」模式绕行。
- ❌ 不引入 Python / 第三方 C 动态库到运行时；不引入 Mojo 社区包到运行时（除非可
  静态链接进单 binary 且经 ADR 评审）。
- ❌ 不在本 goal 内做「Mojo 原生 ASGI/WSGI 协议层」（beads: phase1-mojo-native-crt.6，
  独立评估；与本仓库「自研 HTTP 协议层」路线重复，除非用户明确要求）。
- ❌ 不承诺 HTTP/2 / TLS 全量实现（列入 P3 观察，需新 C 依赖与安全评审）。
- ❌ 不在本 goal 内把 benchmark 工具链语言本身变成「产品」——它是开发工具。

---

## 5. 阶段划分（roadmap）

### Phase 4 — 框架语义对标（Track A·P0）

- P4.1 类型化参数：Path/Query/Body 支持 `Int/Float/Bool/List[String]/Dict[String,Any]`
  强类型转换 + 校验失败→422（对标 FastAPI/Pydantic 语义）。
- P4.2 `HTTPException` + 自定义异常处理器注册 → 统一 JSON 错误体（替换硬编码
  400/404/405/413 分支）。
- P4.3 Request/Response 对象：handler 可读 headers/cookies、设置 status_code /
  响应头 / set_cookie；响应支持嵌套 JSON 序列化。
- 里程碑：新增 ADR-0010；e2e 79→90+；bench 不回归。

### Phase 5 — API 表面补齐（Track A·P1 + Track B 启动）

- P5.1 Header/Cookie 参数 + 表单（application/x-www-form-urlencoded）解析。
- P5.2 文件上传（multipart，C 侧分块解析 + 内存缓冲，不落盘）。
- P5.3 依赖注入（`Depends` 语义：解析顺序、缓存、子依赖）。
- P5.4 中间件链（before/after 有序链 + 异常透传）+ 后台任务（进程内简单队列）。
- P5.5 Streaming/File/Redirect Response 原语。
- T1 启动：bench.py → Mojo 原生（与 P5 并行，独立任务线）。
- 里程碑：新增 ADR-0011/0012；e2e 90→110；`.venv` 移除（bench 不再依赖 Python）。

### Phase 6 — 协议/生态收口（Track A·P2 + Track B 收尾）

- P6.1 URL 解码（HTTP + WS `{param}` 统一）；NUL 回复 FFI 协议修订。
- P6.2 鉴权链统一（WS 首帧 token / 自定义头 / 与 HTTP 中间件共用）。
- P6.3 模块化 Router 组合（多路由表合并）。
- P6.4 OpenAPI/Swagger 文档（只读生成，`/openapi.json` 起步）+ lifespan 事件。
- T2/T3 收尾：e2e_test.sh 与 build_single.sh python3 清零。
- 里程碑：全仓库 `*.py` = 0；e2e ≥ 120；CI 全绿；最终发布 v0.4.0（或按里程碑细分）。

---

## 6. 风险与约束（6 条架构隔离约束声明）

1. **单 binary 零依赖不变量**：任何新增能力必须 Mojo 原生或 C FFI 随 binary 打包；
   禁止新增 Python 运行期依赖 / 系统动态库依赖（ldd 仅 libc + env -i 启动断言永续）。
2. **用户代码 = 纯数据**：新增路由/处理器 = 数据声明；行为扩展只走显式单点 dispatch
   （`run_handler` / `run_ws_message`）加 kind 分支，核心不含 per-handler 业务逻辑。
3. **God-file 阈值**：每个 `.mojo` 文件 < 500 行；超限即拆分新模块，并在 ADR 标注
   拆分边界（如 params.mojo 已拆 params_query/params_json 的先例）。
4. **工具链与运行时解耦**：Track B 只改 build/test/bench；运行时交付物形态不变；
   工具链可用 shell/C/Mojo，不反向污染运行时依赖图。
5. **决策先行**：每项重大特性/协议变更须先立 ADR（6 条约束声明）+ `br` 任务 +
   e2e 增量；禁止「大改后补文档」。
6. **兼容既有模式**：所有 C 侧新能力走显式 bridge/adapter 入口（如 ws.c /
   http_bridge_final.c 先例）；Mojo 1.0.0 语法缺口（无闭包/match/文件级 let）用已验证
   的「类型 + 数据 + 零参 def 常量」模式绕行，不引入新的不可验证技巧。

---

## 7. 关联决议 / 上游工件

| 工件 | 与本 goal 的关系 |
|------|-----------------|
| `AGENTS.md` §1/§3/§6 | 北极星、架构约束、决策链（本 goal 的硬约束） |
| ADR-0001~0005 | Mojo 替换策略 / 单 binary / 路由注册 / 并发 —— 已落地，本 goal 沿用其模式 |
| ADR-0006~0009 | WebSocket 全链路 —— 其「后续」清单（鉴权扩展 / URL 解码 / NUL 回复 / WS bench）纳入本 goal P2/T1 |
| `docs/migrate_mojo/todo.md` | 历史规划（已废弃）；其 C6「Mojo ASGI 协议层」标注为独立评估，非本 goal 范围 |
| `scripts/e2e_test.sh` | 79 项 e2e，Track A/B 每步的验收门禁 |
| `benchmark.sh` / `bench.py` | 统一压测入口；Track B T1 的替换对象 |
| beads（`br`）| 每个子项建任务并跟踪状态 |

---

## 8. 度量（每阶段验收）

- **功能**：e2e 增量（79 → 90 → 110 → 120+）；单元自检增量；每特性对应 e2e 用例数。
- **性能**：`./benchmark.sh` 固定姿势；新增特性不得使既有场景吞吐倒退 >10%
  （HEY HTTP ~20k rps / 单核顺序 ~300 rps 为基线）。
- **去 Python**：`find . -name "*.py"` 计数；`.venv` 是否移除；三个脚本 `python3`
  调用数归零。
- **不变量**：CI 上 `ldd` 断言 + `env -i` 启动断言每 push 自动守护。

---

## 附录 A：FastAPI 对标缺口矩阵（详细）

| 能力 | FastAPI/Starlette | fastapi_mojo 现状 | 本 goal 目标 | 阶段 |
|------|------------------|-------------------|--------------|------|
| 类型化 Path 参数 | `int`/`float`/`bool`/枚举 | String only | 强类型 + 422 | P4.1 |
| 类型化 Query 参数 | 同上 + 默认值/必填 | String only | 强类型 + 422 | P4.1 |
| 类型化 Body | Pydantic 模型嵌套 | `Dict[String,String]` | `Dict[String,Any]` + 嵌套 | P4.1 |
| 异常 → JSON | `HTTPException` + 自定义 handler | 硬编码 400/404/405/413 | 统一错误体 + 自定义处理器 | P4.2 |
| Request 对象 | headers/cookies/method/url | 未暴露 | 读 headers/cookies | P4.3 |
| Response 对象 | status/headers/cookies/redirect | 静态 body only | 完整响应原语 | P4.3/P5.5 |
| Header 参数 | Header(...) | ❌ | 支持 | P5.1 |
| Cookie 参数 | Cookie(...) | ❌ | 支持 | P5.1 |
| 表单 | urlencoded | ❌ | 支持 | P5.1 |
| 文件上传 | multipart/UploadFile | ❌ | 支持（内存） | P5.2 |
| 依赖注入 | Depends | ❌ | 支持 | P5.3 |
| 中间件链 | 有序 + 异常透传 | before/after 单层 | 有序链 | P5.4 |
| 后台任务 | BackgroundTasks | ❌ | 进程内队列 | P5.4 |
| 流式响应 | StreamingResponse | ❌ | 支持 | P5.5 |
| 静态文件 | StaticFiles | 嵌入 binary | 已达标（+缓存头/range） | P3 |
| URL 解码 | 自动 | `{param}` 未解码 | 统一解码 | P6.1 |
| NUL 回复 | 支持 | FFI len 协议缺口 | 修订 | P6.2 |
| 鉴权链 | 中间件/依赖 | WS token 单点 | 统一 | P6.2 |
| 模块化 Router | APIRouter | 单路由表 | 多表合并 | P6.3 |
| OpenAPI 文档 | 自动生成 | ❌ | /openapi.json 起步 | P6.4 |
| lifespan | 事件 | ❌ | 支持 | P6.4 |
| gzip 压缩 | 中间件 | ❌ | 支持 | P3 |
| CORS 精细配置 | allow_headers/expose/max_age | 基础 | 补全 | P3 |
| TLS/HTTPS | 支持 | ❌ | 观察（需新 C 依赖评审） | P3 |
| HTTP/2 | 支持 | ❌ | 远期，不承诺 | P3 |

## 附录 B：Track B 去 Python 明细（当前 python3 调用点）

| 文件 | 调用点 | 替代方案 | 阶段 |
|------|--------|---------|------|
| `bench.py` | 整个文件（HTTP + WS 负载、统计、SQLite 落库） | Mojo 原生 bench 二进制 | T1/Phase 5 |
| `benchmark.sh` | `$PYTHON_BIN bench.py …`、`.venv` 探测 | 调用 Mojo bench | T1/Phase 5 |
| `scripts/e2e_test.sh` | `python3 -c`/heredoc 共 ~15 处（hex 构造 / 大 payload / WS 客户端 / keep-alive / HEAD body） | 纯 shell（printf/od/openssl）+ 小 C 工具 | T2/Phase 6 |
| `build_single.sh` | `python3 -c 'import modular…'` 定位 lib | `$MODULAR_LIB` + 固定路径候选扫描 | T3/Phase 6 |

> **验收红线**：Phase 6 结束时 `git grep -n "python3\|\.venv\|bench\.py" -- ':!docs' ':!AGENTS.md' ':!README.md'`
> 应仅剩历史文档提及；`.venv/` 目录删除。
