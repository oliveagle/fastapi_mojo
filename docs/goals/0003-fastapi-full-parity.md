# Goal-0003：FastAPI 全功能 100% 对标 — 一个不少

> **本标**：用 Mojo（+ Rust bridge，仅 Mojo 1.0.0 无 std 模块处）实现 FastAPI **全部**
> 功能，对标上游 FastAPI 0.141.1。不追求"逐字节复刻"，但**功能语义一个不少**：
> 每个 FastAPI 公开 API / 行为在本项目都有可验证的对应实现。
>
> **上游**：Goal-0001（Mojo+Rust only 单 binary 零依赖，终态达成）+ Goal-0002
> （v0.5.0 核心语义 F1-F11）。本 goal 是"全功能闭环"，不是对前两者的修订。
>
> **对标基线**：FastAPI 0.141.1 公开 API 面（`fastapi.*` 模块导出 + `fastapi.security.*`
> + `fastapi.middleware.*` + `fastapi.responses.*` + `fastapi.dependencies.*` +
> Starlette `Request/Response/WebSocket` 常用面）。

## 0. 现状定位（2026-09-05 盘点）

**已达成（v0.5.1 + 决策-31~42）**：
- 单 binary 3.1M，ldd 仅 libc，env -i 干净启动，e2e **221 项**，cargo 335 单测
- 已覆盖能力（见 §1 矩阵 ✅）：路由/路径参数/查询参数/类型化参数+422/JSON body/
  Form/multipart 文件上传/Header/Cookie/HTTPException+error_map/Request-Response 对象/
  嵌套 JSON/OpenAPI+SwaggerUI+components schemas/SSE(自定义 status+额外头)//metrics/
  结构化 access log/WebSocket 全链路/Depends 嵌套依赖/BackgroundTasks/CORS preflight/
  多 worker/静态文件/HTML 响应/生产化(Docker+systemd+nginx)/**安全认证
  (HTTPBasic/HTTPBearer/APIKey, 决策-34)**/**response_model 字段过滤 (决策-35)**/
  **Lifespan startup/shutdown (决策-36)**/**APIRouter prefix/tags/deps + include_router (决策-37)**/
  **Pydantic 式 body 校验 (嵌套/Field 约束/Enum/422 全收集, 决策-38)**/
  **GZip 中间件 (FASTAPI_MOJO_GZIP env 声明式, Rust bridge flate2 纯 Rust, 决策-40)**/
  **CORS 完整配置 (Starlette CORSMiddleware 声明式 env 等价, 决策-42)**

## 1. FastAPI 全功能对标矩阵（✅ 已实现 / 🟡 部分 / ❌ 缺失）

| # | 能力 | FastAPI 语义 | 现状 | 差距 | 计划 |
|---|------|-------------|------|------|------|
| 1 | 路径方法 | GET/POST/PUT/DELETE/PATCH/OPTIONS/HEAD + 405+Allow | ✅ | PATCH 未单独注册(走通用) | 补 PATCH |
| 2 | 路径参数 | `{param}` + 类型 + 约束 | ✅ 类型化 | 约束(gt/lt/regex) | §P2 |
| 3 | 查询参数 | 可选/必填/多值/alias/desc | ✅ 类型化 | 多值 List、alias | §P2 |
| 4 | 请求体 | Pydantic 模型 / dict / 嵌套 | ✅ 声明式 spec（决策-38） | validator 自定义回调 = Mojo 无闭包，声明式约束词表为等价形态（扩充 P2） | — |
| 5 | Form | Form(...) 多值 | 🟡 单值 | 多值 | §P2 |
| 6 | 文件上传 | UploadFile (read/seek/size/close) | ✅ 字节+b64 | UploadFile 对象 API | §P2 |
| 7 | Header | Header(...) | ✅ | alias/desc | §P2 |
| 8 | Cookie | Cookie(...) | ✅ | — | — |
| 9 | 依赖注入 | Depends (嵌套/缓存/安全依赖) | ✅ 嵌套 | 缓存(use_cache) | §P2 |
| 10 | 响应类型 | JSON/HTML/PlainText/File/Streaming/ORJSON/UJSON/Response | 🟡 JSON/HTML/SSE | File/Streaming 通用/ORJSON | §P1 |
| 11 | response_model | 只返回声明字段 + exclude/include/none | ✅ include+exclude+exclude_none（决策-35/41, ADR-0016：FastAPI 语义对齐，无模型 no-op） | — | — |
| 12 | 状态码 | status_code 声明 | ✅ | — | — |
| 13 | 异常 | HTTPException/RequestValidationError/自定义 handler | 🟡 error_map | 任意异常类型 handler | §P2 |
| 14 | 中间件 | BaseHTTPMiddleware/GZip/自定义 | 🟡 固定3 + GZip ✅（决策-40 env 声明式） | 用户自定义（Mojo 无闭包：声明式 env / 固定链为等价形态，扩充 P2） | §P2 |
| 15 | CORS | CORSMiddleware (origins/methods/headers/credentials) | ✅ 声明式 env 等价（决策-42, ADR-0017：ORIGINS/METHODS/HEADERS/CREDENTIALS/MAX_AGE + 普通响应条件附带 + 预检 204/400 动态） | 预检 400 体为本实现 JSON 简化 + 裸 OPTIONS 204 超集（均文档化, e2e 守护） | — |
| 16 | OpenAPI | spec + Swagger + tags/prefix/desc | ✅ | tags/prefix/custom | §P2 |
| 17 | 安全 | HTTPBasic/HTTPBearer/APIKey/OAuth2/JWT/get_current_user | ✅ Basic/Bearer/APIKey（决策-34）；OAuth2/JWT P2 | OAuth2/JWT | §P2 |
| 18 | APIRouter | include_router(prefix/tags/dependencies) | ✅ include 时合并，dispatch 零改动（决策-37，ADR-0013）；OpenAPI tags + path 分组 | — | — |
| 19 | Lifespan | startup/shutdown (context manager) | ✅ 声明式 env 命令（决策-36，Mojo 无闭包的等价形态）；失败→服务不启动 | — | — |
| 20 | Pydantic | 嵌套模型/Field 约束/validator/enum/自定义类型 | ✅ 嵌套+Field 约束+enum（决策-38，声明式 spec 等价形态） | 约束词表扩充（P2） | §P2 |
| 21 | Enum | 枚举参数/响应 | ✅ query/path/body enum + 422 + OpenAPI enum 数组（决策-38） | — | — |
| 22 | Request 对象 | state/client/url.full_url/query_params | 🟡 部分 | state | §P2 |
| 23 | WebSocket 进阶 | close(code)/exception_handler/send_text/bytes/json | 🟡 部分 | 精化 | §P2 |
| 24 | 压缩 | GZipMiddleware | ✅ env 声明式（决策-40, ADR-0015：FASTAPI_MOJO_GZIP* + send_response 单点 + flate2 纯 Rust） | — | — |
| 25 | TestClient | 测试客户端 | ❌(dev 工具) | — | 低优先 |

## 2. 优先级与计划

### P0（本次交付 — Security 安全，决策-34）
FastAPI 使用率最高的能力之一。声明式 + 单一 dispatch 钩子，与现有架构完全对齐：
- **HTTPBasic**：`Authorization: Basic base64(user:pass)` → 401 + `WWW-Authenticate: Basic realm=...`
- **HTTPBearer**：`Authorization: Bearer <token>` → 401 + `WWW-Authenticate: Bearer realm=...`
- **APIKey**：header / query / cookie 三位置 → 401
- 成功 → 注入 `auth_user` / `auth_token` / `auth_apikey` 到 handler 参数
- 声明式：`_auth` + `_auth_users` / `_auth_tokens` / `_auth_realm`
- 新增 `security.mojo`（base64 解码 + 3 种校验）+ dispatch 钩子 + e2e ≥8 用例

### P1（后续 — 核心卖点闭环）
- response_model（响应字段过滤）✅ 决策-35
- APIRouter / include_router（prefix/tags/dependencies）✅ 决策-37
- Lifespan（startup/shutdown）✅ 决策-36
- Pydantic 式嵌套 body 校验 + Field 约束
- Enum 类型

### P2（后续 — 精化/完备）
- 查询多值 / alias / desc
- 中间件自定义（GZip ✅ 决策-40；自定义逻辑 = 声明式 env 扩充）
- CORS 完整配置 ✅（决策-42, ADR-0017）
- 任意异常类型 handler
- UploadFile 对象 API
- WebSocket 精化
- OpenAPI tags/prefix

## 3. 约束（与 AGENTS.md 对齐）

- 每个 `.mojo` < 500 行；新能力 = 新模块 + 单一 dispatch 钩子（run_handler / 钩子模式）
- 声明式优先：新增路由/行为 = 数据（`set_data`），核心零改动
- e2e 全程不回归（每次提交跑全量）；binary ≤4.2M；ldd 仅 libc
- ADR 含 6 条架构隔离约束声明；决策先行

## 4. 任务清单（beads / 决议链）

| # | 任务 | 阶段 | 状态 |
|---|------|------|------|
| T-P0 | Security：HTTPBasic/HTTPBearer/APIKey（决策-34，ADR-0011） | P0 | ✅（e2e 160/160，cargo 299/0/4，clippy 0 警告，ldd 仅 libc，2.8M） |
| T-P1a | response_model（响应字段过滤，决策-35） | P1 | ✅（e2e RM-1..4，164/164，/profile demo） |
| T-P1b | APIRouter / include_router (决策-37, ADR-0013) | P1 | ✅（e2e AR-1..8, 180/180; cargo 307/0/4; clippy 0 警告; ldd 仅 libc; 2.9M; OpenAPI tags + path 分组修复既有重复 key bug） |
| T-P1c | Lifespan (startup/shutdown, 决策-36, ADR-0012) | P1 | ✅（e2e LS-1..4, 168/168; cargo 307/0/4; clippy 0 警告; ldd 仅 libc; 2.9M; +F11 out= 垃圾 NUL 契约修复） |
| T-P1d | Pydantic 式嵌套 body + Field 约束 | P1 | ✅（决策-38, ADR-0014: _body_schema 声明式 spec + 422 全收集 + OpenAPI components; e2e 205/205, cargo 312/0/4, clippy 0, 3.1M） |
| T-P1e | Enum 类型 | P1 | ✅（决策-38: _param_types T[values] + OpenAPI enum 数组; BS-11/BS-12 e2e） |
| T-P2* | 查询多值/alias、中间件 GZip、CORS 完整、异常 handler、UploadFile、WS 精化、OpenAPI tags | P2 | 📋 |

---
*最后更新：2026-09-10（**决策-42 CORS 完整配置**（ADR-0017, P2 矩阵 #15 ✅）：
Starlette CORSMiddleware 声明式 env 等价（FASTAPI_MOJO_CORS_ORIGINS CSV/`*` 默认 `*` +
_METHODS 默认 7 + _HEADERS CSV/`*` 默认 Content-Type,Authorization（未设置 ≠ `*`）+
_CREDENTIALS 默认 false + _MAX_AGE 默认 600 = Starlette）；
普通响应仅当请求带被允许 Origin（通配 → `*` / 白名单或 credentials → 回显 / 不允许 → 无头 —
C 时代「每响应必带 `*`」偏差移除, 文档化）；预检 204/400 动态（origin/ACRM/ACHR 越界 →
400 JSON, 裸 OPTIONS → 204 通配超集）；FFI diff = 0（send_preflight_response 签名不变）,
零新增依赖（std only）；
e2e **221/221**（CRS-1..8）/ cargo **335/0/4** / clippy 0 警告 / bench 0 errors（36.0k）/
ldd libc / env -i / 3.1M；
下一轮：P2 精化（查询多值+alias / Form 多值 / UploadFile 对象 API / Depends use_cache /
任意异常 handler / OAuth2-JWT / Request.state / WS 精化 / File-Streaming 通用响应 /
OpenAPI custom / ws-deflate）；
2026-09-09（**决策-41 response_model 精化**（ADR-0016, P2 矩阵 #11 ✅）：
FastAPI/Pydantic 三参数声明式（_response_model include + _response_exclude 剔除模型字段 +
_response_exclude_none 剔除 null — 空串/__nested__:null 等价, "null" 字符串不算）；
应用序 include→exclude→exclude_none; 无模型时 no-op（FastAPI 对齐）；
单一 helper response_model_body（dispatch 14 行 → 1 行, FFI diff = 0）；
e2e **213/213**（RM-1..7）/ cargo 323/0/4 / clippy 0 / bench 0 errors (42.2k) / ldd libc / env -i / 3.1M；
下一轮：P2 精化（CORS 完整配置 / 查询多值+alias / OAuth2-JWT / Request.state / WS 精化 / OpenAPI custom info / ws-deflate / Form 多值 / UploadFile 对象 API）；
前一轮：决策-40 GZip 中间件（ADR-0015, P2 矩阵 #24）：
Starlette GZipMiddleware 声明式 env 等价（FASTAPI_MOJO_GZIP 默认关 = FastAPI 对齐；
MIN_SIZE 500 / MAX_SIZE 1MiB；裸 token 判定不支持 q — 上游 quirk；非 304 + extra 无
Content-Encoding）；钩子 = send_response 单点（所有响应类型必经，level 6 对齐 Starlette）；
client 判定走 request 全局（io.rs set_accepts_gzip，FFI diff = 0）；
flate2 纯 Rust miniz_oxide（无 C 路径，静态，ldd 实测仍仅 libc，3.1M）；
e2e **210/210**（+GZ-1..5）/ cargo **323/0/4** / clippy 0 警告 / bench 0 errors（39.2k req/s）/ env -i 干净启动；
**决策-38/39**（ADR-0014 + multipart UTF-8 豁免 P0 修复）同轮落地（见下）；
下一轮：P2 精化（CORS 完整配置 / 查询多值+alias / response_model exclude-include / OAuth2-JWT / Request.state / WS 精化 / OpenAPI custom info / ws-deflate）；
前一轮：T-P1d + T-P1e 达成（决策-38, ADR-0014）— P1 全部闭环：
Pydantic 式 body 校验（`_body_schema` 声明式 spec：嵌套/Field 约束/enum/数组/默认值）+
统一 FastAPI 422 detail（loc/msg/type，参数+body 全错误收集）+ Enum 参数（query/path）+
OpenAPI components/schemas 自动生成（requestBody $ref，单一事实源）；
🔴 Mojo 1.0.0 assert no-op 实测发现（首用 check() 真断言）；
**决策-39**：finish_header multipart UTF-8 豁免 P0 修复（body 与 header 同 recv 到齐路径，MP4 256B 二进制 roundtrip）；
e2e **205/205** / cargo **312/0/4** / clippy 0 警告 / bench 0 errors（41.9k req/s）/ ldd 仅 libc / 3.1M；
下一轮：P2 精化（GZip 中间件 / CORS 完整配置 / 查询多值+alias / response_model exclude-include / OAuth2-JWT / Request.state / WS 精化 / OpenAPI custom info））*
