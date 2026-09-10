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

**已达成（v0.5.1 + 决策-31~48）**：
- 单 binary 3.5M（3,663,872 B），ldd 仅 libc，env -i 干净启动，e2e **366 项**，cargo 409 单测
- 已覆盖能力（见 §1 矩阵 ✅）：路由/路径参数/查询参数/类型化参数+422/JSON body/
  Form/multipart 文件上传/Header/Cookie/HTTPException+error_map/Request-Response 对象/
  嵌套 JSON/OpenAPI+SwaggerUI+components schemas/SSE(自定义 status+额外头)//metrics/
  结构化 access log/WebSocket 全链路/Depends 嵌套依赖/BackgroundTasks/CORS preflight/
  多 worker/静态文件/HTML 响应/生产化(Docker+systemd+nginx)/**安全认证
  (HTTPBasic/HTTPBearer/APIKey, 决策-34)**/**response_model 字段过滤 (决策-35)**/
  **Lifespan startup/shutdown (决策-36)**/**APIRouter prefix/tags/deps + include_router (决策-37)**/
  **Pydantic 式 body 校验 (嵌套/Field 约束/Enum/422 全收集, 决策-38)**/
  **GZip 中间件 (FASTAPI_MOJO_GZIP env 声明式, Rust bridge flate2 纯 Rust, 决策-40)**/
  **CORS 完整配置 (Starlette CORSMiddleware 声明式 env 等价, 决策-42)**/
  **查询参数精化 (List 多值 / alias / description, 声明式纯 Mojo, 决策-43)**/
  **OAuth2/JWT (password grant + JWT HS256, Rust crypto 原语 + 纯 Mojo 协议层, 决策-44)**/
  **Form 多值/alias/desc + 422 detail parity (List 多值 / alias / desc / input / collect-all, 声明式纯 Mojo, 决策-45)**/
  **UploadFile 对象 API (file/bytes 声明 + 422 parity U2-U5/U9 + 对象操作 head/range/sha256/save + multipart
  OpenAPI, 声明式纯 Mojo + FFI +1, 决策-46)**/
  **Depends use_cache (每请求 memo 表, 默认 cached / _depends_nocache = use_cache=False, 声明式纯 Mojo,
  决策-47)**/
  **FileResponse/StreamingResponse (Range/206/multipart/etag/CD/500 + chunked streaming, Rust bridge 协议层 file_protocol+file_serve, 决策-48)**

## 1. FastAPI 全功能对标矩阵（✅ 已实现 / 🟡 部分 / ❌ 缺失）

| # | 能力 | FastAPI 语义 | 现状 | 差距 | 计划 |
|---|------|-------------|------|------|------|
| 1 | 路径方法 | GET/POST/PUT/DELETE/PATCH/OPTIONS/HEAD + 405+Allow | ✅ | PATCH 未单独注册(走通用) | 补 PATCH |
| 2 | 路径参数 | `{param}` + 类型 + 约束 | ✅ 类型化 | 约束(gt/lt/regex) | §P2 |
| 3 | 查询参数 | 可选/必填/多值/alias/desc | ✅ 多值 List/alias/desc/collect-all（决策-43/45, ADR-0018/0020：T[] 语法 + alias query-only + desc 双处；元素校验 **collect-all** — ADR-0020 更正 ADR-0018「首败即停 = 上游同款」错误实测） | 标量 bool 短消息 vs list 完整消息 + CSV 逗号歧义（均文档化, ADR-0018 §3.5, e2e 守护） | — |
| 4 | 请求体 | Pydantic 模型 / dict / 嵌套 | ✅ 声明式 spec（决策-38） | validator 自定义回调 = Mojo 无闭包，声明式约束词表为等价形态（扩充 P2） | — |
| 5 | Form | Form(...) 多值 / alias / desc | ✅ 全量（决策-45, ADR-0020：List 多值 = 全部 occurrence / 标量 last-wins / alias wire key（原始名无效力）/ _param_descs → OpenAPI；422 = "Field required" + input + list collect-all；/login 未标注字段旧语义兼容） | 未标注字段 = 未声明校验（不 422）+ CSV 逗号歧义（均文档化, ADR-0020 §3.5, e2e FM 守护） | — |
| 6 | 文件上传 | UploadFile (read/seek/size/close) | ✅ 全量（决策-46, ADR-0021：file/bytes 声明（`[]`/`=可选`）+ 422 parity（U2 value_error 完整措辞 / U3 string_type 稳定子集 / U4 last-wins / U5 非 multipart 全缺失 / U9 bytes 双路）+ 对象操作（head/range/sha256/save 原子）+ multipart OpenAPI（contentMediaType 四形态 / required 仅当必填字段）；size = 实际字节（U1） | 文档化偏差 ×7（ADR-0021 §3.5：U9 上游 500 不复制 / input 稳定子集 / Body 命名 / save `..` 守卫 / 未声明不校验 / 空默认 = required（上游 optional, p8, 不修）/ missing de-dup） | — |
| 7 | Header | Header(...) | ✅ desc（决策-43, _param_descs → OpenAPI） | alias | §P2 |
| 8 | Cookie | Cookie(...) | ✅ | — | — |
| 9 | 依赖注入 | Depends (嵌套/缓存/安全依赖) | ✅ 全量（决策-47, ADR-0022：默认 cached = 每请求 memo 表（菱形/三重菱形 1 次，值同源，P9-1/5）+ `_depends_nocache` = use_cache=False（P9-2/4）+ 嵌套 nocache 结果入库供 cached 引用复用（P9-3）+ 每请求作用域 + `_dep_calls` 观测超集；APIRouter 对称扩展 `base_deps_nocache`/`include_router(deps_nc=)`；FFI diff = 0） | 文档化偏差 ×4（ADR-0022 §3.5：per-name memo vs per-dependant / _dep_calls 超集 / 基础依赖恒 cached / 解析序先 cached 后 nocache） | — |
| 10 | 响应类型 | JSON/HTML/PlainText/File/Streaming/ORJSON/UJSON/Response | ✅ 全量（JSON/HTML/SSE 既有 + **File/Streaming 决策-48, ADR-0023**：FileResponse = Range 7 步顺序解析（>100 段 → 200 quirk）/ 206 单段·suffix·open·clamp / multipart（26-hex boundary + CL 闭式 + 重叠合并）/ 400×4 精确消息 / 416（`bytes */size` 空体）/ 500（无文件头）/ If-Range = ETag\|LM / HEAD 仅头 / CD（attachment\|inline RFC5987）/ etag = md5(f64(mtime)-size) / 64KB 块直发；StreamingResponse = TE chunked（no-CT quirk / 自定义 status / extra 头 / 空体键存在语义）；ORJSON/UJSON ≡ json.mojo（既有 F3 决策）；Rust bridge file_protocol 230 + file_serve 416 + FFI ×2，零新 crate，MD5 K 表 const = libm 零化） | 文档化偏差 ×7（ADR-0023 §3.5：① ORJSON≡json.mojo（既有）② HEAD 仅头 vs 上游 405 quirk（APIRoute methods={GET}，更优）③ GZip 不介入 file/streaming（上游压缩，P2）④ 整秒 mtime etag `"N"` vs 上游 `"N.0"`（opaque；非整秒逐字节相同）⑤ i64 溢出段 → 400 vs 上游 416（>9.2EB 不可达）⑥ `_file_path` 静态目录相对 + extra 不得覆写 CT/ETag（收窄）⑦ INM·IMS 忽略 = parity（列此完备）） | — |
| 11 | response_model | 只返回声明字段 + exclude/include/none | ✅ include+exclude+exclude_none（决策-35/41, ADR-0016：FastAPI 语义对齐，无模型 no-op） | — | — |
| 12 | 状态码 | status_code 声明 | ✅ | — | — |
| 13 | 异常 | HTTPException/RequestValidationError/自定义 handler | ✅ 全量（HTTPException F2 / 422 F1 既有 + **任意异常类型 handler 决策-49, ADR-0024**：字符串 tag 约定 `raise Error("TAG: msg")`（Mojo 1.0.0 仅 Error 类型, P13-M2/M5）+ 声明式表（env `FASTAPI_MOJO_EXCEPTION_HANDLERS` "TAG:STATUS:BODY[:json];…" 全局 / `_exc_handlers` 路由级整体替换超集 / 同 tag 后者胜 P13-2）+ 声明式 raise 钩子 `_exception_raise`（endpoint body 位置）+ 路由级 try/except guard（= 上游 wrap_app_handling_exceptions；查找 精确 tag → `Exception` catch-all（= ServerErrorMiddleware 500/Exception 键, P13-9）→ 默认 500 "Internal Server Error" text/plain（P13-10 逐字 parity）；body 模板 {exc}/{tag} 插值（json 条目 `_json_escape`）；P13-8 日志 quirk 模拟） | 文档化偏差 ×8（ADR-0024 §3.5：① 无类→字符串 tag（无 MRO）② handler=声明式条目非 callable ③ 无 int status 键（HTTPException 非 raised 异常）④ response_started 路径结构性不可达（单发）⑤ 双层 map→单表 ⑥ 日志 quirk 线形模拟 ⑦ per-route=超集 ⑧ 中间件抛出 gap） | — |
| 14 | 中间件 | BaseHTTPMiddleware/GZip/自定义 | 🟡 固定3 + GZip ✅（决策-40 env 声明式） | 用户自定义（Mojo 无闭包：声明式 env / 固定链为等价形态，扩充 P2） | §P2 |
| 15 | CORS | CORSMiddleware (origins/methods/headers/credentials) | ✅ 声明式 env 等价（决策-42, ADR-0017：ORIGINS/METHODS/HEADERS/CREDENTIALS/MAX_AGE + 普通响应条件附带 + 预检 204/400 动态） | 预检 400 体为本实现 JSON 简化 + 裸 OPTIONS 204 超集（均文档化, e2e 守护） | — |
| 16 | OpenAPI | spec + Swagger + tags/prefix/desc | ✅ | tags/prefix/custom | §P2 |
| 17 | 安全 | HTTPBasic/HTTPBearer/APIKey/OAuth2/JWT/get_current_user | ✅ 全量（决策-34 Basic/Bearer/APIKey + 决策-44 OAuth2/JWT，ADR-0019：/token password grant（宽松 form 422 全收集）+ JWT HS256（alg 白名单 + exp/nbf/sub）+ get_current_user = sub→auth_user + OpenAPI securitySchemes） | 文档化偏差（空 Bearer → 401 非 403；sub 空串也拒；_auth_users CSV = 凭据声明式等价，ADR-0019 §3.5，e2e 守护） | — |
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
- 查询多值 / alias / desc ✅（决策-43, ADR-0018）
- Form 多值 / alias / desc ✅（决策-45, ADR-0020）
- 中间件自定义（GZip ✅ 决策-40；自定义逻辑 = 声明式 env 扩充）
- CORS 完整配置 ✅（决策-42, ADR-0017）
- OAuth2/JWT（password grant + JWT HS256）✅（决策-44, ADR-0019）
- 任意异常类型 handler ✅（决策-49, ADR-0024）
- UploadFile 对象 API ✅（决策-46, ADR-0021）
- File/Streaming 通用响应 ✅（决策-48, ADR-0023）
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
| T-P2* | 查询多值/alias ✅（决策-43）、Form 多值/alias ✅（决策-45）、中间件 GZip ✅（决策-40）、CORS 完整 ✅（决策-42）、OAuth2/JWT ✅（决策-44）、UploadFile 对象 API ✅（决策-46）、Depends use_cache ✅（决策-47）、File/Streaming 通用响应 ✅（决策-48）、异常 handler ✅（决策-49）、WS 精化、OpenAPI tags | P2 | 📋 |

---
*最后更新：2026-09-10（**决策-49 任意异常类型 handler**（ADR-0024, P2 矩阵 #13 ✅）：
Mojo 1.0.0 异常面探测（P13-M1..M8：**异常类型仅 Error**（无类/无 MRO/无内省）/ `String(e)` = message /
`std.os.getenv` 原生可读 / try 块内变量 except 不可见 / 含 String 字段 struct 须显式 `__init__`）
→ **字符串 tag 约定** `raise Error("TAG: msg")` + 声明式表 + 路由级 try/except guard（= 上游 route
wrap_app_handling_exceptions）：**全局表** env `FASTAPI_MOJO_EXCEPTION_HANDLERS = "TAG:STATUS:BODY[:json];…"`
（同 tag 后者胜, P13-2；`Exception` 条目 = catch-all = 上游 ServerErrorMiddleware 500/Exception 键,
P13-9 双层 map 单表化）/ **路由级** `_exc_handlers`（整体替换全局, 超集 §3.5-7）/ **声明式 raise
钩子** `_exception_raise`（Depends 后、handler 前 = endpoint body 抛异常位置）；查找顺序 = 精确 tag →
`Exception` → **默认 500 "Internal Server Error"（text/plain; charset=utf-8, P13-10 逐字 parity）**；
body 模板 `{exc}`/`{tag}` 插值（json 条目先 `_json_escape`）；P13-8 日志 quirk 模拟（具体命中 → 单行 /
catch-all·未处理 → 完整 message 行）
+ **新模块 `exception_handlers.mojo`（254 行 <500）** + dispatch `guarded_run_handler` 单点接线
（http_server_final 1444 → 1509，异常响应分支 = SSE 同型 cfd 透传 + continue）+ **新 FFI
`send_text_response_status`**（send.rs + ffi.rs；复用 `send_response` 核心 — 零新依赖/零 libm/
NUL 契约不变）+ **7 demo 路由**（/exc/ve · /exc/unicorn（上游文档 UnicornException 例名）·
/exc/unhandled · /exc/raise-plain · /exc/ve2 · /exc/override · /exc/dup）+
`standard_status_line` +418（Teapot, 自定义异常 demo 常用码）
+ **`exception_handlers_selftest.mojo`**（JIT 可达纯逻辑自检 28 checks：split/entry 解析/后者胜/
插值/resolve 全分支/json 转义/env 表 — file_params_selftest 同模式, 不触 run_handler FFI 闭包）
e2e **366/366**（351 + 15 XH：默认 500 ×4 + CT 精确 / 正常路由 + _error_map 回归 ×2 / 精确 tag 418 /
自定义 tag 418 / catch-all 503 / json 422（CT application/json）/ 路由级覆盖 429 / 同 tag 后者胜 404 /
无 tag 消息落 catch-all / 有表正常路由 ×7）/ cargo **409/0/4**（407 + 2：send_text_response_status
×2）/ clippy 0 警告（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c **37,216 req/s**,
32.9k–43.9k 区间内, 无回归）/ **ldd 仅 libc** / env -i 干净启动（health 200 + /exc/ve 500）/
**3.5M**（3,663,872 B，≤4.2M，+32 KB vs 决策-48）/ `find src -name '*.c'` = 0 保持；
下一轮：P2 剩余（Request.state / WS 精化 / OpenAPI tags / Header alias / 约束扩充 / TestClient）；
2026-09-10（**决策-48 FileResponse/StreamingResponse**（ADR-0023, P1 矩阵 #10 ✅）：
Rust bridge 协议层 **file_protocol**（230 行纯函数：Range **7 步顺序解析** — 无 `=` → 400 / 单位≠bytes → 400 /
**>100 段 → `[]` → 200 quirk**（starlette max_ranges=100）/ 逐段 skip（空/`-`/无 `-`/非数字）+ suffix·open·
**clamp**（end≥size）/ 0 有效段 → 400 / **start 越界 → 416（先于 start≥end → 400）** / 多段排序 + 重叠合并；
RFC1123（civil_from_days）/ RFC5987 / CD（quote 变化 → `filename*=utf-8''{q}`）/ charset 规则 / etag =
md5(f64Display(mtime) + "-" + size) / multipart CL 闭式（p10c MP2 锚定 242）/ 26-hex 小写 boundary（token_hex(13)
parity））+ **file_serve**（416 行 I/O：**144B glibc `struct stat` 布局**（stat(2) 整写 — 128B = 栈 OOB 写）/
**S_IFMT = 0o170000**（初版 `0o070000` 少一位八进制 → REG 恒 false 全 500，🔴 实测 catch）/ 64KB 块
lseek+read+send 直发（上游 chunk_size）/ 单点 FFI **send_file_response** + **send_streaming_response**
（TE chunked `{len:x}\r\n{data}\r\n…0\r\n\r\n`，media 空 = 无 CT quirk））
+ **Mojo 声明式接线**（KIND_FILE = 300，handler.mojo 495 ≤500；`_file_path`/`_file_media`/`_file_name`/
`_file_cdt`/`_file_status`/`_response_headers`；dispatch FILE 分支 = SSE 同型 cfd 透传 + continue，
http_server_final 1332 → 1444）+ **8 demo 路由**（/file /file-name /file-inline /file-missing /
file-201 /stream /stream-json /stream-empty）+ filedemo.bin（30B）build 自动嵌入
+ **MD5（RFC 1321）K 表 const 嵌入 = libm 零化**：运行时 `f64::sin` 会链入 `libm.so.6` **破 CI ldd
门禁**（ci.yml 禁 libm.so）→ const 256B `.rodata`（值由 glibc 正确舍入 sin 逐位导出，
`md5_k_table_matches_sin_derivation` 守护 ≡ 派生）→ **ldd 回归仅 libc**；
（🔴 K 表弧度教训：RFC 1321 的 (i+1) 本身是弧度，初版 to_radians() 双转换 = 系统性错表；
两个「RFC 向量」凭记忆抄错 — 一律以 md5sum/hashlib oracle 为准）
+ 上游语义锚点（starlette 1.6.0 源码 + uvicorn 0.52.4 活体，/tmp/fresp_probe p10*）：**HEAD → 405
quirk**（`APIRoute` methods = `{GET}` 不含 HEAD — 与 starlette 内置 Route / /openapi.json（`{GET, HEAD}`）
不同；带 Range 也 405）→ 本实现 HEAD = 仅头（200/206，RFC 9110 语义，**更优**）/ If-None-Match /
If-Modified-Since 上游 FileResponse 同样不处理（忽略 → 200 = **parity**）/ 400/416/500 = 全新
PlainTextResponse（**无文件头**，`Internal Server Error` = 21B）
+ 文档化偏差 ×7（ADR-0023 §3.5：① ORJSON/UJSON ≡ json.mojo（既有 F3）② HEAD 仅头 vs 上游 405（更优）
③ GZip 不介入 file/streaming（上游 starlette 1.6.0 压缩它们 — GZip 层重构为 body iterator 包装 = P2 剩余）
④ 整秒 mtime 的 ETag `"N"` vs 上游 `"N.0"`（opaque token；**非整秒 mtime 与上游逐字节相同** — 活体交叉
验证 data.txt etag 两边相同）⑤ i64 溢出 Range 段 → 跳过（全跳 → 400）vs 上游无界 int → 416（仅 >9.2 EB
可触发）⑥ `_file_path` = 静态目录相对 + extra 不得覆写 CT/ETag（上游 `headers=` 可覆写 — 收窄防 MIME
混淆，P2 剩余）⑦ INM·IMS 忽略 = parity（非偏差，列此完备））
验收：e2e **351/351**（319 + 32 FR：200 精确体 / 头（LM vs `date -u -R`）/ **ETag =
md5(f64repr(mtime)-size) 独立交叉验证**（fmtool f64repr × md5sum oracle）/ 201 / CD attachment +
RFC5987 inline / 500 无文件头 / 206 单段·suffix·open·clamp / 416（`bytes */30` + CL 0）/ 400×4 精确
消息 / 101 段 quirk → 200 / 重叠合并 / **multi-range 精确体**（boundary 抽取 + printf 期望 + cmp，
CL = 246 闭式手算，26-hex，头无 CR）/ If-Range ETag·LM·stale / INM·IMS 忽略 / HEAD 200·206
**raw-socket 线级空体**（curl -I -o 会把头 dump 进 -o 文件 = curl quirk，故线级证明）/ chunked×3
（no-CT quirk / 202 + X-Custom / 空体键存在）/ **raw-socket chunked 帧级**（`6\r\nhello ` / `3\r\n中`
/ `0\r\n\r\n`）/ ×10 稳定）/ cargo **407/0/4**（354 + 53：file_protocol 30 + file_serve 15 + MD5 8）/
clippy 0 警告（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c **37,665 req/s**，历史区间
32.9k–43.9k 内，无回归）/ **ldd 仅 libc（libm 零化）** / env -i 干净启动（health + /file 200 30B +
/stream 200 14B）/ **3.5M**（3,631,104 B，≤4.2M，+75 KB vs 决策-47）/ `find src -name '*.c'` = 0 保持；
下一轮：P2 剩余（任意异常类型 handler / Request.state / WS 精化 / OpenAPI tags / Header alias /
约束扩充 / TestClient）；
2026-09-10（**决策-47 Depends use_cache**（ADR-0022, P2 矩阵 #9 ✅）：
每请求 memo 表（dep_cache 106 行，append-only，find 取最新条 = P9-3 覆写语义，calls_of = 实际派发
次数）— 上游 0.141.1 probe P9-1..P9-5 逐条对齐：默认 _depends = cached（upstream use_cache=True；
菱形/三重菱形共享 dep 每请求仅派发 1 次，所有引用值同源，P9-1/5 — 决策-33「各路径独立解析」收紧
为上游语义）+ _depends_nocache（新增）= use_cache=False（route 级/嵌套级，恒重新派发，P9-2/4）+
**P9-3 关键 nuance**（nocache 派发的结果同样写入 memo — 写入无条件，use_cache=False 仅跳过查找；
后续 cached 引用直接复用 = calls 1 次）+ 每请求 cache 作用域（P9-1 第二请求再派发）
+ dispatch_dep/resolve_depends 加 nocache/cache 参数（子依赖递归双表；解析序先 cached 后 nocache
CSV，确定性）+ _dep_calls=true 声明门控注入 <dep>_calls（observability 超集，上游无此面；未声明
= 零输出）+ APIRouter 对称扩展（router.mojo 495：base_deps_nocache + set_base_deps_nocache +
include_router(deps_nc=)，WS 同步合并）
+ demo dc_tick/dc_auth（默认 cached）/dc_auth2（嵌套 nocache）+ /di-cache（菱形 1 次）/ /di-nocache
（route nocache 2 次）/ /di-mix（嵌套 nocache 1 次，P9-3）
+ 文档化偏差 ×4（ADR-0022 §3.5：per-name memo vs per-dependant（声明式等价 — dep 无 per-reference
参数面）/ _dep_calls observability 超集 / APIRouter 基础依赖恒 cached（无 per-base-dep nocache
声明面）/ 解析序先 cached 后 nocache（上游 = 参数声明序））
验收：e2e **319/319**（312+7 DC：P9-1 菱形 1 次 / P9-1 值同源 / P9-2 route nocache 2 次 / P9-3
嵌套 nocache 1 次 / 每请求作用域 / /di 回归零泄漏 / APIRouter 回归零泄漏）/ cargo **354/0/4**
（FFI diff = 0）/ clippy 0 警告（双 crate）/ dep_cache_selftest 16 check 全绿（JIT）/ bench 0 errors
（34.8k req/s，历史区间内）/ ldd 仅 libc / env -i 干净启动（health + /di-cache 200 + calls=1）/
**3.4M**（3,556,048 B，≤4.2M，+25 KB）/ `find src -name '*.c'` = 0 保持；
下一轮：P2 剩余（任意异常 handler / Request.state / WS 精化 / OpenAPI tags / TestClient）；
2026-09-10（**决策-46 UploadFile 对象 API**（ADR-0021, P2 矩阵 #6 ✅）：
Rust bridge multipart.rs 重构（解析 helpers pub(crate) + b64_decode/to_hex/sha256_hex_of（lock-free 纯 std 手写）+
part_save（原子 .tmp→rename）+ parts getter field 5=sha256hex 解析期预算（🔴 修复非重入 Mutex 读路径自锁死锁隐患）
+ 测试拆出 multipart_tests.rs（17））+ FFI +1 mp_part_save（NUL 契约决策-36；`..` 穿越守卫在 Mojo 层 _path_safe）
+ 纯 Mojo 新模块 ×4（file_params 427：_file_types file|bytes/[]/= + _file_aliases + validate_file_collect（U2
value_error 上游完整措辞 / U4 last-wins / U5 非 multipart 全缺失 / unknown_type）+ apply_file_extras（file_ keys：
size = 实际字节 U1 / alias → 声明名 / text → bytes 字段（U9）/ text → form（U8）/ list _count+_list_json）
+ file_form_check 126：U3 string_type（input = 稳定子集 {filename,size,headers} — 上游 _file/_max_mem_size 等
env 细节排除）+ 声明 file 字段 claim 的 part 不参与 + file_ops_ffi 195：snapshot_mp_parts 单一 FFI 快照点
（失败 = 空 = U5）+ _file_ops head:N/range:S:L/sha256/save:PATH（alias-aware，输出 key = 声明名）
+ openapi_multipart 145：U7 四形态 schema（字段序 type/contentMediaType/title/description / optional anyOf-null /
list items）+ key 序 properties/type/required/title + required 仅当必填字段 + Body_<handler.name>_<method>）
+ dispatch（决策-32 旧注入移除 → CT 检测 → snapshot → filtered text map（U8）/ parse_form_multi（urlencoded）/
空（U5）→ validate_file_collect 恒执行 → 422 de-dup（p7 presence 胜，整串精确匹配）→ 成功路径
apply_file_extras + apply_file_ops（conn 活跃，快照重读安全））
+ demo /upload-file（doc:file + alias docfile + opt:file= + docs:file[] + note:str 必填 + ops sha256 + descs）/
/upload-bytes（raw:bytes= + small:bytes= 全 optional + ops head/range/save）+ OpenAPI multipart requestBody
（与 _body_schema 互斥；urlencoded 分支保留）
+ 文档化偏差 ×7（ADR-0021 §3.5：U9 上游 500 不复制 / string_type input 稳定子集 / Body_<handler.name>_<method>
命名 / save `..` 守卫安全超集 / 未声明字段不校验（决策-32 兼容）/ name:type= = required（上游 Form("")/Form(None)
= optional，p8 — 本决策不修，ripple 决策-43/45 面）/ file part 使 form 字段「存在」→ missing 422 de-dup）
验收：e2e **312/312**（294+18 MP8–MP23b：sha256 vs sha256sum / head+range b64 / save roundtrip cmp /
all-optional 非 CT 200 / required-missing ×2 / value_error alias / string_type 稳定子集 / list count+顺序 /
bytes-text / bytes-file / no-CT ×3 / urlencoded ×2 / openapi 子串 / jsoncheck 整文 / text→form / alias ×2）
+ MP4 语义修正（size = 实际字节 U1；b64 长 344 → 256）/ cargo **354/0/4**（+5 净）/ clippy 0 警告（双 crate）/
bench 0 errors（34.3k req/s，历史区间内）/ ldd 仅 libc / env -i 干净启动（health + /upload-file + /upload-bytes 200）/
**3.4M**（3,531,472 B，≤4.2M，+131 KB）/ `find src -name '*.c'` = 0 保持；
下一轮：P2 剩余（Depends use_cache / File-Streaming 通用响应 / 任意异常 handler / Request.state / WS 精化 / TestClient）；
2026-09-10（**决策-45 Form 多值/alias/desc + 422 detail parity**（ADR-0020, P2 矩阵 #5 ✅）：
纯 Mojo form_params（493：parse_form_multi multi-map（同 key 全部 occurrence 按序, url_decode, 裸 key→""）/ validate_form_collect
（缺失 → "Field required" F 大写 + input null；list = 全部 occurrence 逐元素 **collect-all**；标量 = last-wins；
loc ["body",name(,i)]）/ apply_form_extras（list→CSV / 标量 last-wins / alias wire key 绑定（原始名无效力）/ 未标注
_form_fields 字段旧语义（缺失 → ""，/login 向后兼容））/ form_openapi_schema（F10 字段序 items/type/title/description/default）/
form_request_body_required（仅当存在无默认 _form_types 字段时 required:true））
+ request_response.parse_form_multi（_parse_form_body multi 姊妹，决策-44 纯 Mojo 分层延续，FFI diff = 0）
+ 422 全局 parity（P1-P5，FastAPI 0.141.1 + pydantic 2.13.5 probe）：3 个构造器（params_typed._pe / params_query_extra.
make_error_json / body_validate.err_obj）加 input（missing=null / parse=raw 转义 / JSON body 缺失=收到的 body 对象；
字段序 loc,msg,type,input — 上游序差异文档化）；"field required" → "Field required"；
validate_list_values stop-on-first → **collect-all**（P1 更正 ADR-0018 错误实测 — 0.141.1 对 query/body 均 collect-all）；
parse_typed_value float 接受 int 字面量（P6：pydantic v2 "1" → 1.0）+ 接受 "str"（潜在 bug 修复）
+ dispatch 2 点接线（校验段：CT 含 urlencoded（大小写不敏感）→ parse_form_multi，否则空 multi = **上游同款**（非 form
body → 字段全缺失 → 默认/422）；注入段：inject_form_fields（决策-28）移除 → apply_form_extras 单点）
+ /form-multi（items:int[];tags:str[];count:int=0;fx:float[]=;fb:bool[]= + _param_descs）+ /form-alias（labels:str[]=;size:int=2
+ _form_aliases labels=tags）demo + OpenAPI form requestBody（与 _body_schema 互斥；_multipart 跳过）
+ 附带 P0 修复（P7）：/openapi.json 自决策-38 起非法 JSON（query 参数 schema 括号配对错 — 标量分支不关对象 +
_generate_parameter 过早关参数对象且 parameter 级 description 落到对象外；子串 e2e 从未发现）— 修正 +
fmtool jsoncheck 整文合法性门禁（fmtool 新增纯 std 子命令）；FFI diff = 0，零新 crate；
e2e **294/294**（274+20 FM：3-occ/wrap / missing F+input null / 默认×3 / collect-all×3（int 双错误+loc idx）/ alias×3 /
兼容×2 / URL 编码 / openapi.json jsoncheck 整文 / requestBody×2（required:true / 无 required）/ query collect-all×2（P1））
/ cargo **349/0/4**（FFI 零改动）/ clippy 0 警告（双 crate）/ bench 0 errors（34.2k, 历史区间内）/ ldd 仅 libc / env -i
（health + /form-multi + /form-alias 200）/ **3.24M**（3,400,400 B，≤4.2M，+74 KB）；
下一轮：P2 剩余（UploadFile 对象 API / Depends use_cache / File-Streaming 通用响应 / 任意异常 handler /
Request.state / WS 精化 / TestClient）；
2026-09-10（**决策-44 OAuth2 password flow + JWT（HS256）**（ADR-0019, P2 矩阵 #17 ✅，对标矩阵最后一项）：
Rust bridge crypto.rs（185 行，零第三方 crate，纯 std 手写 SHA-256 FIPS 180-4 / HMAC-SHA256 RFC 2104
（>64B key 先 sha256）/ base64url RFC 7515 宽松解码；known vectors ×12 + pyjwt-2.13 独立实现 oracle 交叉验证）
+ FFI +2（fm_hmac_sha256_b64url[_free]，malloc(n+1)+NUL 决策-36 契约）
+ 纯 Mojo security_jwt（497：3-part 切分 / flat JSON claims / check_oauth2 / handle_oauth2_token）；
FastAPI 0.141.1 + pyjwt 2.13 逐条 probe 对齐（宽松 form 模型：grant_type 可选（存在须 ^password$ 否则 422 pattern mismatch）/
username+password 必填（422 missing 全收集）/ 凭据错 401 "Incorrect email or password"；
gate：无头 / 非 bearer scheme（大小写不敏感）401 "Not authenticated" / 校验失败（含空 Bearer）401
"Could not validate credentials" — 修正早期 403 假设）；
/token + /token-exp（ttl=-1）+ /secure-jwt 路由 + KIND_OAUTH2_TOKEN（201）dispatch 特例
+ OpenAPI securitySchemes.OAuth2PasswordBearer（bearerFormat: JWT）+ operation 级 security；
oauth2 分支放 dispatch（避免 FFI 闭包破坏 security.mojo JIT 自检，ADR-0019 §3.5-2；security.mojo 与 HEAD 字节一致）；
FFI diff = +2，零新 crate；
e2e **274/274**（248+26 OT：签发 / 服务端 token / 401 多态 / 422 pattern+missing / 宽松 grant / gate / pyjwt fixture T1..T5 / ttl=-1 / OpenAPI）
/ cargo **349/0/4**（+14 crypto）/ clippy 0 警告（双 crate）/ bench 0 errors（41.2k）/ ldd libc / env -i /
**3.17M**（3,326,672 B，≤4.2M，+49 KB）；
下一轮：P2 剩余（Form 多值 / UploadFile 对象 API / Depends use_cache / File-Streaming 通用响应 /
任意异常 handler / Request.state / WS 精化 / TestClient）；
2026-09-10（**决策-43 查询参数精化**（ADR-0018, P2 矩阵 #3 ✅）：
List 多值（_param_types 语法扩展: T[] 必填 / T[]= 可选空 list / T[]=csv 带默认, 空括号 = list 非空 = enum 决策-38;
list = 全部 occurrence 的 CSV 内部表示, handler 读 query_<key> 得 "a,b"; 缺失 → 默认 CSV; 非法元素 422 首败即停
loc ["query",name,i], pydantic v2 完整措辞）
+ alias（_param_aliases, query-only path 豁免: 查询 key = alias, 原始 name 无绑定效力 — 校验按 alias key,
成功路径 values[name] 恒覆写绑定值, OpenAPI parameter.name = alias）
+ description（_param_descs → OpenAPI parameter 级 + schema 级双处, path/header 同样支持）;
纯 Mojo params_query_extra（364）+ parse_table 泛化, 依赖图无环（params_typed → params_query_extra → params_query）;
标量多值保持 last-wins（Starlette, QS-R1 回归守护）; FFI diff = 0（Rust 零改动）;
e2e **248/248**（+27 QS）/ cargo **335/0/4** / clippy 0 警告 / bench 0 errors（37.3k）/
ldd libc / env -i / **3.12M**（3,277,520 B, ≤4.2M）；
下一轮：P2 剩余（Form 多值 / UploadFile 对象 API / Depends use_cache / File-Streaming 通用响应 /
任意异常 handler / OAuth2-JWT（需 SHA-256+HMAC in Rust bridge）/ Request.state / WS 精化 / TestClient）；
2026-09-10（**决策-42 CORS 完整配置**（ADR-0017, P2 矩阵 #15 ✅）：
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
