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

**已达成（v0.5.1 + 决策-31~54）**：
- 单 binary **4.0M（4,081,808 B）**，ldd 仅 libc，env -i 干净启动，e2e **447 项**，cargo **453**（bridge）+ **30**（fmtool）单测
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
  **FileResponse/StreamingResponse (Range/206/multipart/etag/CD/500 + chunked streaming, Rust bridge 协议层 file_protocol+file_serve, 决策-48)**/
  **参数约束面 (path/query/header gt/ge/lt/le/mo/len/pat + typed header 校验 + 422 ctx + 自研 regex 引擎, 声明式纯 Mojo + FFI +1, 决策-54, ADR-0029)**
  **用户自定义中间件 (FASTAPI_MOJO_MIDDLEWARE 声明式动词表: 请求面 MAP/REQHDR/BLOCK + 响应面 HDR/STATUS/BODY/LOG + 短路, 纯 Mojo 计划 + Rust bridge FFI +2, 决策-55, ADR-0030)**
  **TestClient 声明式等价 (fmtool testclient http/ws/run: 真实网络声明式测试客户端 + JSONL 事件流 + run 服务器生命周期断言; dev 工具, FFI diff 0, 决策-56, ADR-0031)**

## 1. FastAPI 全功能对标矩阵（✅ 已实现 / 🟡 部分 / ❌ 缺失）

| # | 能力 | FastAPI 语义 | 现状 | 差距 | 计划 |
|---|------|-------------|------|------|------|
| 1 | 路径方法 | GET/POST/PUT/DELETE/PATCH/OPTIONS/HEAD + 405+Allow | ✅ **机制全支持**（bridge opaque method bytes + router 通用匹配） | **PATCH+body 解析 ✅（决策-57, ADR-0032: dispatch body = POST/PUT/PATCH，闭环 ADR-0014 偏差）** | — |
| 2 | 路径参数 | `{param}` + 类型 + 约束 | ✅ 全量（**参数约束面统一落地 决策-54, ADR-0029**：`_param_constraints` 声明式（`name=gt=3,le=10` / `len=2-4` / `pat=regex` / `mo`（=0 no-op）；**未声明 query 键 = 隐式 str 声明**（len/pat only）；每字段首违 only（数值 mo→ge→gt→le→lt / 字符串 minl→maxl→pat）；422 对象 house 键序 + `ctx` 末位（上游拼写）；**input 类型化 P26-b-8**（在场=raw / 缺失+默认违约=类型化字面量 unquoted / parse 失败=raw）；**typed header**（`_header_types`, 决策-53 面）缺失→默认值校验→422/注入默认字面量, 在场→parse→约束→注入 raw；collect-all 群序 path→query→header；**自研 regex 引擎 `bridge/regex.rs`**（re.search 语义: literal/escape/类/量词/组/alternation/锚/\b; 无反引/环视/命名组/内联标志; 匹配步数上限防 DoS; **FFI diff = +1** `regex_match`）；OpenAPI 3.0.3 约束键（3.0 布尔 exclusiveMinimum / 隐式 str 恒带 type / 字面量原样）；6 demo 路由 /con/*（含 /con/all 三错群序）） | 文档化偏差 ×8（ADR-0029 §3.8：① house 键序+ctx 末位 ② str+数值约束注册期拒（优于上游 no-op）③ list+约束注册期拒（优于上游 500）④ 3.0.3 布尔 exclusive 形式 ⑤ regex = 自研 backtracking 子集 ⑥ 隐式 str schema 恒带 type ⑦ 数字字面量原样 ⑧ body 词表扩充 = 矩阵 #4 未来; **矩阵 #3 标量 bool 短消息偏差本决策销账**（完整消息三面对齐, CP-14/24 守护）） | — |
| 3 | 查询参数 | 可选/必填/多值/alias/desc | ✅ 多值 List/alias/desc/collect-all（决策-43/45, ADR-0018/0020：T[] 语法 + alias query-only + desc 双处；元素校验 **collect-all** — ADR-0020 更正 ADR-0018「首败即停 = 上游同款」错误实测） | **CSV 逗号歧义**（文档化, ADR-0018 §3.5, e2e 守护; 标量 bool 短消息偏差已由 **决策-54** 销账 — 完整消息 "Input should be a valid boolean, unable to interpret input" 三面对齐, CP-14/CP-24 守护） | — |
| 4 | 请求体 | Pydantic 模型 / dict / 嵌套 | ✅ 声明式 spec（决策-38）+ **pat=REGEX（决策-57, ADR-0032）** + **数组元素级约束（决策-58, ADR-0033：pat/len 逐元素 str[]、ge/le/gt/lt 逐元素 int[]/float[]、items 数组级、422 loc 带 idx、注册期 fail-fast key×类型、OpenAPI 元素级入 items）** + **递归嵌套 JSON Schema（决策-61, ADR-0036：obj{} 与 obj[]{} 全量递归、数组元素 loc/input、OpenAPI recursive object items + min/max）** | **validator 自定义回调 = Mojo 无闭包（硬边界, ADR-0014）**；约束词表（gt/ge/lt/le/len/items/pat, 标量+数组元素级）= 等价形态；T[][] 仍为文档化边界 | — |
| 5 | Form | Form(...) 多值 / alias / desc | ✅ 全量（决策-45, ADR-0020：List 多值 = 全部 occurrence / 标量 last-wins / alias wire key（原始名无效力）/ _param_descs → OpenAPI；422 = "Field required" + input + list collect-all；/login 未标注字段旧语义兼容） | 未标注字段 = 未声明校验（不 422）+ CSV 逗号歧义（均文档化, ADR-0020 §3.5, e2e FM 守护） | — |
| 6 | 文件上传 | UploadFile (read/seek/size/close) | ✅ 全量（决策-46, ADR-0021：file/bytes 声明（`[]`/`=可选`）+ 422 parity（U2 value_error 完整措辞 / U3 string_type 稳定子集 / U4 last-wins / U5 非 multipart 全缺失 / U9 bytes 双路）+ 对象操作（head/range/sha256/save 原子）+ multipart OpenAPI（contentMediaType 四形态 / required 仅当必填字段）；size = 实际字节（U1） | 文档化偏差 ×7（ADR-0021 §3.5：U9 上游 500 不复制 / input 稳定子集 / Body 命名 / save `..` 守卫 / 未声明不校验 / 空默认 = required（上游 optional, p8, 不修）/ missing de-dup） | — |
| 7 | Header | Header(...) | ✅ 全量（**Header 参数精化 决策-53, ADR-0028**：`_reads_headers` 条目扩展 `name`（wire = 逐 `_`→`-` 转换, x_token→x-token, x__token→x--token, P25-1/4）/ `name=alias`（wire = alias **原样不转换**, P25-3; `name=name` = 字面 = `convert_underscores=False` 逃生门, 单声明双语义）；参数键仍 = `header_<name>`（响应/OpenAPI 键 = 声明名, Query alias 同约定）；`_param_descs` → OpenAPI description（决策-43 既有, 查找按声明名）；OpenAPI header 参数 name = wire 名（原始拼写保留, P25-2/3）；CI 匹配 + 多值取首 = bridge `get_header_value_ci` 既有（**FFI diff = 0**）；注册期 `check_header_specs`（至多 1 `=` / 两侧非空 / 可打印非空白 ASCII, 畸形 → 启动 fail-fast, check_ws_specs/check_state_specs/check_openapi_specs 同策略）；demo `/hdr/alias`（`x_token=Token-Literal,client_id`）） | 文档化偏差 ×4（ADR-0028 §3.5：① 缺失 → "" 非 required-422（typed header/约束面 = 下一决策, 矩阵 #2, P25-6..9 已探测备查）② alias 与 convert_underscores = 单声明双语义（上游 alias 本就不转换, 全可达状态均可表达, 无损失）③ schema 无 `title`（F4 基线）④ 422 loc = wire 名随 #1 下一决策对齐） | — |
| 8 | Cookie | Cookie(...) | ✅ | — | — |
| 9 | 依赖注入 | Depends (嵌套/缓存/安全依赖) | ✅ 全量（决策-47, ADR-0022：默认 cached = 每请求 memo 表（菱形/三重菱形 1 次，值同源，P9-1/5）+ `_depends_nocache` = use_cache=False（P9-2/4）+ 嵌套 nocache 结果入库供 cached 引用复用（P9-3）+ 每请求作用域 + `_dep_calls` 观测超集；APIRouter 对称扩展 `base_deps_nocache`/`include_router(deps_nc=)`；FFI diff = 0） | 文档化偏差 ×4（ADR-0022 §3.5：per-name memo vs per-dependant / _dep_calls 超集 / 基础依赖恒 cached / 解析序先 cached 后 nocache） | — |
| 10 | 响应类型 | JSON/HTML/PlainText/File/Streaming/ORJSON/UJSON/Response | ✅ 全量（JSON/HTML/SSE 既有 + **File/Streaming 决策-48, ADR-0023**：FileResponse = Range 7 步顺序解析（>100 段 → 200 quirk）/ 206 单段·suffix·open·clamp / multipart（26-hex boundary + CL 闭式 + 重叠合并）/ 400×4 精确消息 / 416（`bytes */size` 空体）/ 500（无文件头）/ If-Range = ETag\|LM / HEAD 仅头 / CD（attachment\|inline RFC5987）/ etag = md5(f64(mtime)-size) / 64KB 块直发；StreamingResponse = TE chunked（no-CT quirk / 自定义 status / extra 头 / 空体键存在语义）；ORJSON/UJSON ≡ json.mojo（既有 F3 决策）；Rust bridge file_protocol 230 + file_serve 416 + FFI ×2，零新 crate，MD5 K 表 const = libm 零化） | 文档化偏差 ×7（ADR-0023 §3.5：① ORJSON≡json.mojo（既有）② HEAD 仅头 vs 上游 405 quirk（APIRoute methods={GET}，更优）③ GZip 不介入 file/streaming（上游压缩，P2）④ 整秒 mtime etag `"N"` vs 上游 `"N.0"`（opaque；非整秒逐字节相同）⑤ i64 溢出段 → 400 vs 上游 416（>9.2EB 不可达）⑥ `_file_path` 静态目录相对 + extra 不得覆写 CT/ETag（收窄）⑦ INM·IMS 忽略 = parity（列此完备）） | — |
| 11 | response_model | 只返回声明字段 + exclude/include/none | ✅ include+exclude+exclude_none（决策-35/41, ADR-0016：FastAPI 语义对齐，无模型 no-op） | — | — |
| 12 | 状态码 | status_code 声明 | ✅ | — | — |
| 13 | 异常 | HTTPException/RequestValidationError/自定义 handler | ✅ 全量（HTTPException F2 / 422 F1 既有 + **任意异常类型 handler 决策-49, ADR-0024**：字符串 tag 约定 `raise Error("TAG: msg")`（Mojo 1.0.0 仅 Error 类型, P13-M2/M5）+ 声明式表（env `FASTAPI_MOJO_EXCEPTION_HANDLERS` "TAG:STATUS:BODY[:json];…" 全局 / `_exc_handlers` 路由级整体替换超集 / 同 tag 后者胜 P13-2）+ 声明式 raise 钩子 `_exception_raise`（endpoint body 位置）+ 路由级 try/except guard（= 上游 wrap_app_handling_exceptions；查找 精确 tag → `Exception` catch-all（= ServerErrorMiddleware 500/Exception 键, P13-9）→ 默认 500 "Internal Server Error" text/plain（P13-10 逐字 parity）；body 模板 {exc}/{tag} 插值（json 条目 `_json_escape`）；P13-8 日志 quirk 模拟） | 文档化偏差 ×8（ADR-0024 §3.5：① 无类→字符串 tag（无 MRO）② handler=声明式条目非 callable ③ 无 int status 键（HTTPException 非 raised 异常）④ response_started 路径结构性不可达（单发）⑤ 双层 map→单表 ⑥ 日志 quirk 线形模拟 ⑦ per-route=超集 ⑧ 中间件抛出 gap） | — |
| 14 | 中间件 | BaseHTTPMiddleware/GZip/自定义 | ✅ 全量（固定3链 + **GZip ✅ 决策-40 (ADR-0015)** + **用户自定义 ✅ 决策-55 (ADR-0030)**：单一 env `FASTAPI_MOJO_MIDDLEWARE` 声明式动词表（`;` 分中间件 / `,` 分动词 / 位置字段 `:` / 路径表 `|`; 畸形 → `check_mw_spec` fail-fast 服务不启动）；**请求面** (MAP/REQHDR/BLOCK) = Mojo `mw_spec.mojo` 纯函数 outermost→innermost（BLOCK 短路即停）+ dispatch 钩子（路由/OPTIONS 前, FFI `inject_request_header` 注入合成头）；**响应面** (HDR/STATUS/BODY/LOG) = bridge `send_response` 单点 innermost→outermost（env 正序, GZip 前）；栈序 mw1=innermost…mwN=outermost（P-MW-1）；**短路**（BLOCK 于 mwK → 响应仅过 mwK+1..mwN 外层动词, bridge `plan_request_path` 重推导, 零额外 FFI）（P-MW-3）；同名 HDR 后写胜（P-MW-2）；STATUS 重设（P-MW-4）；BODY 换 body + **重算 Content-Length** + text/plain（P-MW-5）；LOG 行用原始 path） | 文档化偏差 ×7（ADR-0030 §3.5/§7.5：① 无用户闭包→声明式动词表（Mojo 1.0.0）② 用户 mw 固定层位 = GZip/CORS env 层之内 ③ scope 边界: WS 帧/101/chunked/静态/预检不 wrap（P-MW-6）, 请求面适用 OPTIONS+WS 升级 GET ④ 不读/改请求 body ⑤ REQHDR 仅请求头参数面, 不影响 bridge 内部探测 ⑥ path 语义不对称: LOG=原始 path vs BODY/BLOCK/响应 path=post-MAP ⑦ BODY 重算 CL = 文档化优于上游（上游 stale-CL → h11 协议破损）） | — |
| 15 | CORS | CORSMiddleware (origins/methods/headers/credentials) | ✅ 声明式 env 等价（决策-42, ADR-0017：ORIGINS/METHODS/HEADERS/CREDENTIALS/MAX_AGE + 普通响应条件附带 + 预检 204/400 动态） | 预检 400 体为本实现 JSON 简化 + 裸 OPTIONS 204 超集（均文档化, e2e 守护） | — |
| 16 | OpenAPI | spec + Swagger + tags/prefix/desc | ✅ 全量（**OpenAPI 精化 决策-52, ADR-0027**：app 级 9 `FASTAPI_MOJO_OPENAPI_*` env（title/version/description/terms/contact/license/servers/tags/external_docs — /openapi.json 请求期读, 畸形 → 省略字段不 500）+ 路由级 8 声明（`_summary` 默认 = name Python title() / `_description` / `_response_description` 默认 "Successful Response" / `_operation_id` 默认 `{name}{path 逐 /{ }→_}_{method}`（P24-6: 上游 `re.sub(\W→_)` 逐字符**无 `_+` 折叠**）/ `_deprecated` / `_include_in_schema`（不进 paths/components 仍可服务）/ `_status_code`="NNN Reason"（wire 仅当结果恰 "200 OK" 覆写 + spec 主键前 3 位）/ `_responses` 额外状态码（重复主键注册期拒绝））；注册期校验 `check_openapi_specs`（check_ws_specs/check_state_specs 同策略 fail-fast）；operation 键序 P24-4（tags? summary? description? operationId ...）+ 根键序 P24-10（openapi, info, servers?, paths, components?, tags?, externalDocs?；externalDocs description 先）；AnyUrl 2.13.5 规范化（contact/license/externalDocs url：host-only 尾 `/`、path 空且有 `?`/`#` 前插 `/`；**servers url 原样透传** = 上游 AnyUrl|str str 优先, P24-12 修正）；3 demo 路由 /meta/{probe,hidden,made}；**FFI diff = 0**（纯 Mojo：openapi_custom.mojo 381 ln + openapi.mojo 497 ln 重写）） | 文档化偏差 ×9（ADR-0027 §3.5：① 3.0.3 vs 上游 3.1.0（200 schema `{type:object}` vs `{}`）② 无运行期可变 spec（请求期声明式再生成；上游 `extra` 本身 no-op）③ _status_code = 全 status line（_stream_status/_file_status 同型）④ app 级 = env 非构造器（畸形省略）⑤ root_path/openapi_url/docs_url/redoc/webhooks 未实现（P24-11: 0.141.1 root_path 对 spec 无影响）⑥ summary = handler.name title()（同字符串约定）⑦ _responses 重复主键注册期拒绝（上游 dict 覆盖）⑧ 路由 tags 不并入根 tags （P24-2 复刻）⑨ servers url 不规范化（上游 AnyUrl|str, parity）） | — |
| 17 | 安全 | HTTPBasic/HTTPBearer/APIKey/OAuth2/JWT/get_current_user | ✅ 全量（决策-34 Basic/Bearer/APIKey + 决策-44 OAuth2/JWT，ADR-0019：/token password grant（宽松 form 422 全收集）+ JWT HS256（alg 白名单 + exp/nbf/sub）+ get_current_user = sub→auth_user + OpenAPI securitySchemes） | 文档化偏差（空 Bearer → 401 非 403；sub 空串也拒；_auth_users CSV = 凭据声明式等价，ADR-0019 §3.5，e2e 守护） | — |
| 18 | APIRouter | include_router(prefix/tags/dependencies) | ✅ include 时合并，dispatch 零改动（决策-37，ADR-0013）；OpenAPI tags + path 分组 | — | — |
| 19 | Lifespan | startup/shutdown (context manager) | ✅ 声明式 env 命令（决策-36，Mojo 无闭包的等价形态）；失败→服务不启动 | — | — |
| 20 | Pydantic | 嵌套模型/Field 约束/validator/enum/自定义类型 | ✅ 嵌套+Field 约束+enum+**pat=REGEX（决策-57, ADR-0032）** + **数组元素级约束（决策-58, ADR-0033）**；**无 validator closure / 自定义类型 = Mojo 无闭包（硬边界, ADR-0014）** | — | — |
| 21 | Enum | 枚举参数/响应 | ✅ query/path/body enum + 422 + OpenAPI enum 数组（决策-38） | — | — |
| 22 | Request 对象 | state/client/url.full_url/query_params | ✅ 全量（**Request.state 决策-50, ADR-0025**：scope 承载 = dispatch 每请求 `Dict[String,String]`（middleware 先写 → endpoint 后读, 每请求隔离 P22-6）；写面 `_state_set = "key:value;…"`（首个 `:` 切分, 值 `{param}` 插值 — 缺失键保留字面量, 注册期校验 `check_state_specs`）+ 读面 `_reads_state` CSV → `state_<name>`（缺失 → "" = F10 约定）+ 3 demo（`/state` · `/state-dyn/{who}` · `/state-missing` 双空 = 跨请求隔离证明）；client/url = request_id/path+query/ServerInfo 既有面） | 文档化偏差 ×7（ADR-0025 §3.5：① 缺失读 → "" 非 500 ② 写 = 路由声明非代码动态写 ③ 值域 String ④ 无属性反射/集合面（in/len/iter/del）⑤ 惰性 property → 每请求显式构造（parity）⑥ 下划线前缀 parity（1.6.0 允许）⑦ 环境项: 本机 dev 透明代理劫持新 bind 首连接 → 测试探针 warm-up + body 校验（CI 不受影响）） | — |
| 23 | WebSocket 进阶 | close(code)/exception_handler/send_text/bytes/json | ✅ 全量（**WS permessage-deflate 决策-59, ADR-0034**：默认 on / off / required 三模式, comma fallback + fixed 15-bit server window; RSV1 首数据帧, 入站压缩 fragmentation → 1MiB cap → 解压后 UTF-8/dispatch, 出站 sync-flush 去尾 `00 00 ff ff` 且不 padding / 不发 pre-close 空帧; 方向正确 takeover — server_no_context=出站 reset, client_no_context=入站 reset; **FFI diff=0**（ws_handshake 3 参 / parser 8 参不变）; fmtool 零依赖 RFC1951 stored+fixed+dynamic inflater + stored 编码, e2e WSD1..6） + **应用子协议矩阵 决策-60, ADR-0035**：ws_sp 多候选 server-preference 协商 + `/ws/jsonrpc`（JSON-RPC 2.0 单请求/notification/error 面）+ `/ws/graphql-ws`（modern + legacy 控制面, next+complete, malformed→4400）+ `/ws/grpc-web`（NUL-safe BINARY transparent bridge）; `_ws_protocol` 数据驱动 + FFI-free `ws_protocols.mojo`, **FFI diff=0**, e2e WSP1..8 + **WebSocket 精化 决策-51, ADR-0026**：声明式指令（`run_ws_message` 单点 dispatch 签名不变, 每消息评估）— `_ws_close=CODE:REASON`（回复后 close + close-wait, P23-1）/ `_ws_raise=msg`（**无回复无 close 帧**立即 EOF = 客户端 1006, log `[ws-exc]`, P23-3）/ `_ws_exc_close=SPEC`（WebSocketException 等价: 无回复 close 帧 + close-wait, P23-4） / `_ws_no_reply` / `_ws_binary`（NUL 保留零拷贝回显 / BINARY 回复, P23-5）/ `_ws_json=<模板>`（compact JSON 原样 TEXT 帧, echo 路径优先, P23-6）；优先级 `_ws_raise` > `_ws_exc_close` > `_ws_close`；**close-wait = bridge 新 phase 5**（close 帧已发后: 数据/ping/pong 全丢弃, 任何 close 帧→静默 close, EOF/协议错误→静默 close; 超时 = `check_deadlines` 新 `WsCloseWaitTimeout`, env `FASTAPI_MOJO_WS_CLOSE_WAIT` 默认 10000 = uvicorn 10.0s parity, 0 = 立即关, AtomicI32 只读一次; 无 keepalive ping 无 idle/408）；close 帧 wsproto 发送侧规范化（1004/1006→1000 / 1005 无 payload / reason 123B codepoint 截断）+ Mojo 侧合法码集 {1000-1003,1007-1015}∪[3000,4999]（1004/1005/1006 拒收, 比 wsproto 发送侧静默改写更严）；FFI diff = +5（ws_send_close_reason / ws_write_binary / ws_write_current_binary / ws_set_closing / get_ws_close_wait_ms; 既有 ws_send_close 保留）；新模块 `ws_directives.mojo`（解析/校验纯函数 + selftest）+ 6 demo 路由（/ws/close · /ws/close/4001 · /ws-exc/boom · /ws-exc/close · /ws/bin · /ws/json, P23 六场景全覆盖）） | 文档化偏差 ×7（ADR-0026 §3.5：① _ws_json = 声明模板非运行期 dumps ② close-wait 分辨率 1s tick + 可配置超集 ③ 声明式每消息 vs endpoint 生命周期 ④ 会话持续（endpoint 返回不断连）既有偏差显式记录 ⑤ 回复值域 = UTF-8 文本 （任意非 UTF-8 不可表达, NUL 保留）⑥ close-wait 协议错误静默 close（不发提示帧）⑦ 异常 = 字符串 tag 非类（决策-49 同款）） | — |
| 24 | 压缩 | GZipMiddleware | ✅ env 声明式（决策-40, ADR-0015：FASTAPI_MOJO_GZIP* + send_response 单点 + flate2 纯 Rust） | — | — |
| 25 | TestClient | 测试客户端 | ✅ 声明式等价（**决策-56, ADR-0031**：fmtool `testclient http`（真实网络 GET/POST + JSON/form + header/param/cookie/jar + 重定向 303/301-302 POST→GET / 307/308 保持 + 退出码 0-6）/ `ws`（host-aware RFC6455 握手 + Sec-WebSocket-Accept 校验 + action 脚本 → JSONL 事件 connect/denial/receive/close/done/error + 退出码 0/4/5/6）/ `run`（spawn server → readiness → JSONL actions → SIGTERM → server_exit=0 断言 = lifespan CM 等价）；**dev 工具不进 runtime binary，FFI diff = 0**；e2e TC-1..9 + fmtool 30 单测） | 文档化偏差 ×6（ADR-0031 §3.9：① 真实 TCP 对真实 binary 非 in-process ASGI（更贴近部署物）② 无 in-process 异常传播（500 面 = raise=False 路径）③ cookie jar = 文件非 RFC domain/expiry 模型 ④ declarative action script 非闭包/portal（Mojo 无闭包同款）⑤ Host = 真实 host:port 非 `testserver`（UA 仍 = `testclient`）⑥ lifespan = spawn/kill 真实 server 非 in-process CM） | — |

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
- 中间件自定义（GZip ✅ 决策-40；**用户自定义 ✅ 决策-55 (ADR-0030): FASTAPI_MOJO_MIDDLEWARE 声明式动词表 + 短路**）
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
| T-P2* | 查询多值/alias ✅（决策-43）、Form 多值/alias ✅（决策-45）、中间件 GZip ✅（决策-40）、CORS 完整 ✅（决策-42）、OAuth2/JWT ✅（决策-44）、UploadFile 对象 API ✅（决策-46）、Depends use_cache ✅（决策-47）、File/Streaming 通用响应 ✅（决策-48）、异常 handler ✅（决策-49）、WS 精化 ✅（决策-51）、OpenAPI tags/prefix/custom ✅（决策-52）、Header alias/转换 ✅（决策-53）、参数约束面 ✅（决策-54）、用户自定义中间件 ✅（决策-55） | P2 | 📋 |

---
*最后更新：2026-09-12（**决策-63 HTTP/2 prior-knowledge h2c 子集**（ADR-0038, Goal-0003 P2 / http2 bead 销账）：纯 Rust std 实现 RFC7540/7541 有界子集 — HPACK 静态/动态/Huffman 请求解码 + literal-only 响应编码 + HEADERS/CONTINUATION/DATA/SETTINGS/PING/WINDOW_UPDATE/RST/GOAWAY + 长度/伪头/connection-specific/Content-Length 防御 + phase6 复用 poll + 串行 dispatch（100 ready/pending cap）+ poll 前主动 drain 已缓冲 stream；**FFI diff=0**（H2Request 适配既有 request globals/body NUL 契约）；修复两处集成风险：response facade 不重入 conn_table lock（413/raw error 回归）与 conn_done 后 buffered multiplex 不等待新 socket 事件；fmtool 零依赖 H2 客户端 → e2e **504→511/511**（H2-1..7）/ bridge **483/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c=34,916.2 req/s）/ binary **4,221,136 B**（≤6 MiB CI 门禁, +36,864 B）/ ldd 仅 libc / env -i 干净启动 / C=Python=orphans 0；边界=无 TLS/ALPN/h1 Upgrade、串行 dispatch、无 trailers/server push/WS-over-H2、仅 connection send window 且窗口不足 fail-fast、响应不建 HPACK 动态表）
下一轮：P1/P2 open beads（upx-revisit / asgi-shim / multi-arch / json-rust / tls-rustls）
*最后更新：2026-09-12（**决策-62 阶段化 OpenTelemetry in-memory traces**（ADR-0037, Goal-0003 observability extension / otel bead 销账）：`FASTAPI_MOJO_OTEL=1` opt-in + `_finish_request` 响应后统一 telemetry hook（access log + optional server span）+ Rust std-only 每 worker 128-span ring + `GET /traces` OTLP JSON resourceSpans（service/scope、32/16 hex ID、HTTP method/path/query/status/duration attrs；先 snapshot 后 self-record，默认关闭恒空）；**FFI diff=+2**（otel_trace_record / get_traces_block, NUL 契约单测）→ e2e **497→504/504**（OT-0..6）/ bridge **472/0/4** / fmtool **35/0** / clippy 0 / bench 6 场景 0 errors（33,863.87 req/s）/ binary **4,184,272 B ≤4.2M** / ldd 仅 libc / env -i 干净启动 / C/Python/orphans=0；边界=阶段化缓冲，非网络 exporter（无跨 worker 聚合/context propagation/采样器）
下一轮：P1/P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / json-rust / tls-rustls）
*最后更新：2026-09-12（**决策-61 递归嵌套 JSON body Schema**（ADR-0036, Goal-0003 矩阵 #4/#20 / json-schema bead 销账）：`obj[]{subspec}` 逐元素递归 `_validate_fields` → 422 loc `["body",field,idx,child]` + missing input=元素对象 + 元素约束/默认值/raw array/扁平 `field_idx_child` 注入；OpenAPI `items` 递归 object schema（properties/required）+ 外层 minItems/maxItems，补 body 标量数值 minimum/maximum 与 3.0 boolean exclusive 键；body schema 路由拆 `body_schema_routes.mojo`、自测拆 `body_validate_test.mojo`（生产/测试均 <500 行），**FFI diff=0 / Rust bridge diff=0** → e2e **479→497/497**（JS-1a..8b）/ body_validate_test 绿 / bridge **470/0/4** / fmtool **35/0** / clippy 0 / bench 6 场景 0 errors / ldd 仅 libc / env -i 干净启动 / binary **4,180,120 B ≤4.2M** / C/Python/orphans=0
下一轮：P1/P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / otel / json-rust / tls-rustls）
*最后更新：2026-09-12（**决策-60 WebSocket 应用子协议矩阵**（ADR-0035, Goal-0003 矩阵 #23 应用协议面增强）：`ws_sp` 多候选 server-preference 精确协商（chat 单候选无回归）+ `/ws/jsonrpc` JSON-RPC 2.0（echo/ping/add, notification 不回复, -32700/-32600/-32602/-32601, id 类型保留）+ `/ws/graphql-ws`（graphql-transport-ws + legacy graphql-ws; init/ack, ping/pong, subscribe/start→next+complete, malformed→4400）+ `/ws/grpc-web`（BINARY NUL-safe transparent bridge, 明确非 protobuf/gRPC 引擎）; **FFI diff=0 / Rust bridge diff=0** → e2e **471→479/479**（WSP1..8）/ ws_protocols unit 绿 / fmtool **35/0** + clippy 0 / ldd 仅 libc / binary **4,171,928 B ≤4.2M** / C=0
下一轮：P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / otel / json-rust / json-schema / tls-rustls）
*最后更新：2026-09-11（**决策-59 WebSocket permessage-deflate**（ADR-0034, Goal-0003 矩阵 #23 压缩面增强）：RFC7692 协商（默认 on / off / required; comma fallback, 未知/重复参数拒 offer, server window 固定 15 且 `<15` fallback, client bits 8..15）+ RSV1（入站 fragmentation/1MiB cap/解压后 UTF-8; 出站 sync-flush 去尾 `00 00 ff ff`, 不 padding, 不发 pre-close 空帧）+ 方向正确 context takeover（server_no_context=出站 reset; client_no_context=入站 reset）+ **FFI diff=0**（ws_handshake 3 参 / ws_parser_feed 8 参不变, ws_session_begin 仅返回值 2=required 无 offer→400）；fmtool 新增零依赖 RFC1951 inflater（stored/fixed/dynamic+持久窗口）与 stored 编码客户端 → e2e **465→471/471**（WSD1..6）/ cargo **470/0/4**（+17）/ fmtool **35/0**（+5）/ clippy 0（双 crate）/ ldd 仅 libc / env -i 干净启动 / binary **4,135,064 B**（≤4.2M, +24,584 B）/ bench 6 场景 0 errors / RSS 平台化 / 孤儿 0
下一轮：P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / otel / json-rust / json-schema / tls-rustls / ws-subprotocol）
2026-09-11（**决策-58 数组元素级约束**（ADR-0033, Goal-0003 矩阵 #4/#20 缺口闭环）：约束词表复用×类型依赖语义 — pat/len 在 str[] 逐元素（剥外层引号 → 长度 / regex FFI, **FFI diff=0**）、ge/le/gt/lt 在 int[]/float[] 逐元素、items 保持数组级；422 loc = `["body",<field>,<idx>]`（复用元素类型错 loc 约定）；**注册期 fail-fast 加强**（key × 类型错配 → 启动即失败, 闭环静默 no-op）；OpenAPI 元素级约束入 items 对象（minLength/maxLength/pattern, minimum/maximum/exclusive*）、minItems/maxItems 留数组层；e2e **454→465**（BP-2a..k）/ cargo **453/0/4 不变** / clippy 0 / ldd 仅 libc / **4,110,480 B ≤4.2M** / env -i 无孤儿；剩余边界 = Pydantic validator closure（Mojo 无闭包 = **硬边界**）+ OpenAPI 3.0.3 vs 上游 3.1.0（P2）；下一轮：P2 开放 beads（http2 / upx-revisit / asgi-shim / ws-deflate / multi-arch / otel / json-rust / json-schema / tls-rustls / ws-subprotocol）
2026-09-11（**决策-57 body pat=REGEX 约束 + PATCH+body 解析**（ADR-0032, Goal-0003 矩阵 #1/#4/#20 缺口闭环）：body 约束词表 + pat=REGEX（复用 bridge/regex.rs FFI regex_match, **FFI diff=0**; str 标量 only, 非-str/数组/enum 注册期 fail-fast; 422 type=string_pattern_mismatch; OpenAPI pattern 键序遵 ADR-0029 §3.5）+ **PATCH+body 解析**（dispatch body 解析 POST/PUT → +PATCH, 1 行, 闭环 ADR-0014 偏差; validate_body_schema 本就接受 PATCH）；e2e **447→454**（BP-1a..e + PATCH-B1a/b）/ cargo **453/0/4 不变** / clippy 0 / ldd 仅 libc / **4,085,904 B ≤4.2M** / env -i 无孤儿；剩余边界 = Pydantic validator closure（Mojo 无闭包 = **硬边界**）+ 元素级约束（P2）+ OpenAPI 3.0.3 vs 上游 3.1.0（P2）；下一轮：P2 开放 beads（http2 / upx-revisit / asgi-shim / ws-deflate / multi-arch / otel / json-rust / json-schema / tls-rustls / ws-subprotocol）2026-09-11（**Goal-0003 全量完成审计**（25/25 逐行证据复核, 矩阵全 ✅ 成立）： 20 行 clean/ADR 文档化偏差 + 5 行复核通过（#1 PATCH：机制全支持, **PATCH+body 不解析 = ADR-0014 文档化偏差** = 唯一 substantive 功能限制; #4/#20 validator-closures/约束词表 = 声明式 spec 等价形态（Mojo 无闭包, ADR-0014, P2 扩充）; #15/#16 文档化 + e2e 守护） → **Goal-0003 完成**（update_goal complete）; 已知边界 = 各 ADR §3.5/§3.9 文档化偏差清单（OpenAPI 3.0.3 vs 上游 3.1.0 / 无 Pydantic validator / body 无 regex pattern 约束 / HTTP2/TLS = P2 open beads）; 下一轮：P2 roadmap（http2 / upx-revisit / asgi-shim / ws-deflate / multi-arch / otel / json-rust / json-schema / tls-rustls / ws-subprotocol open beads）
2026-09-11（**决策-56 TestClient 声明式等价**（ADR-0031, Goal-0003 矩阵 #25 ✅ = **25/25 全量完成**）：
fastapi 0.141.1 / starlette 1.6.0 活体探测 P-TCL-1..16（handshake/accept/UA/事件形态/close 语义/denial/lifespan）
→ **fmtool testclient 三子命令**（**dev 工具不进 runtime binary，FFI diff = 0**）：
`http`（真实网络 GET/POST + `--json`/`--data` + header/param/cookie + `--cookie-jar` 文件 + 重定向循环
（303→GET / 301-302 POST→GET / 307-308 保持, `redirect_method` 纯函数）+ `--json-out` JSONL 事件 +
退出码 0-6）/ `ws`（**host-aware** RFC6455 握手（ws.rs 原 helper 不动, e2e 逐字节不变）+
Sec-WebSocket-Accept 硬校验 + action 脚本（send-text/json/bytes · receive*/close/expect-close）
→ JSONL 事件（connect/denial/receive/close/done/error）+ 控制帧透明（ping→auto-pong / pong 忽略,
starlette parity）+ 退出码 0 done / 4 denial / 5 早断连·mismatch / 6 timeout）/
`run`（spawn server → readiness 轮询（/health 含 healthy）→ JSONL actions 逐行 PASS/FAIL →
SIGTERM（coreutils `kill`, fmtool 零 crate 依赖无 libc）→ `server_exit=0` 断言 = lifespan CM 等价）
→ **实施期修复**（ADR-0031 §7.6）：run 按**最后一个** `--` 切 actions（选项后装饰性 `--` 两写法皆收）/
`--port N` = 两个 argv（单 argv 实测被服务器忽略 → 默认 8000）/ read_response 去 dead timeout 参数
→ **/tc/jar demo 路由**（KIND_ECHO + `_reads_cookies tc` + `_response_headers Set-Cookie: tc=jar1`
= cookie jar 捕获+回放面, hub 文件小增量 <KB）
→ e2e **438→447/447 全绿**（TC-1 json-out 200+healthy / TC-2 POST /items --json 回显解析字段
item_name / TC-3 --cookie 回显 / TC-4 --cookie-jar 捕获+回放 / TC-5 ws echo 往返+done /
TC-6 expect-close 4001:custom reason（WS_CLOSE_WAIT=2000）/ TC-7 run 全生命周期 server_exit=0 /
TC-8 非 WS 路由 denial（WS router 404, exit 4）/ TC-9 404 透传 exit 0）/
cargo **fastapi_mojo_rs 453/0/4 不变** + **fmtool 30/0**（fmtool 首批单测: parse_url/url_encode/
parse_action/CookieJar/redirect_method/build_body）/ clippy **-D warnings 双 crate 0 警告** /
ldd 仅 libc / env -i 干净启动（health 200）/ binary **4,081,808 B**（≤4.2M, +4 KB vs 决策-55）/
bench 6 场景 0 errors（get_root_10k_100c = 34,867 req/s, 32.9k–43.9k 带内）/ 孤儿 0
下一轮：**Goal-0003 全量完成审计**（25/25 逐行证据复核: 每行 e2e 覆盖 + 各 ADR §3.5/§7 文档化偏差;
gap 列 #1 PATCH-via-generic / #4 约束词表扩充 / #20 validator-closures 的 ✅ 需确认为"文档化偏差"
而非"开放 gap"; 通过后 update_goal complete）
2026-09-11（**决策-55 用户自定义中间件声明式落地**（ADR-0030, P2 矩阵 #14 ✅ / 中间件全量）：
fastapi 0.141.1 / uvicorn 0.52.4 活体探测 P-MW-1..7（栈序 mw1=innermost / 响应头同名后写胜 / 短路跳内层+路由 / status 重设 / body 替换但 CL 不重算 → h11 LocalProtocolError（协议级破损）/ WS scope 直通不 wrap / 请求面仅 scope 可改）→ **单一 env 声明式动词表**（ADR-0004 范式, **FFI diff = +2** `set_req_id`/`inject_request_header`）：`FASTAPI_MOJO_MIDDLEWARE="<mw1>;...;<mwN>"`（`;` 分中间件 / `,` 分动词 / 位置字段 `:` / `|` 分路径表; 畸形 → `check_mw_spec` fail-fast, 服务不启动）；**请求面** (MAP/REQHDR/BLOCK) = Mojo `mw_spec.mojo` 纯函数（outermost→innermost, BLOCK 短路）+ dispatch 钩子（路由/OPTIONS 前, FFI 注入合成头, CI 先注入先胜）；**响应面** (HDR/STATUS/BODY/LOG) = bridge `send_response` 单点（innermost→outermost = env 正序, GZip 前, 同名 HDR 原位替换后写胜, BODY 重算 Content-Length = 文档化优于上游 P-MW-5）
→ **实施期修复**：bridge 侧短路重推导 `plan_request_path`（bridge 重跑 Mojo 计划, 响应仅过外层, 零额外 FFI）— `send_text_response_status` 委托 `send_response`
→ e2e **428→438/438**（+MW-1..10: HDR/REQHDR/MAP/LOG/STATUS/BODY/同名 HDR 外层胜/BLOCK 短路 418 仅外层/text/plain/无 env 零回归）/ cargo **453/0/4**（+19 中间件单测）/ clippy **0 警告**（双 crate）/ ldd 仅 libc / binary **4,077,712 B**（+57 KB vs 决策-54, ≤4.2M 预算）/ env -i 干净启动 / bench 6 场景 0 errors（get_root_10k_100c ≈ 31.5k, 32.9k–43.9k 带内）/ 孤儿 0 / `mw_spec.mojo` selftest **10/10** 全绿（FFI-free, CI 普通 mojo run 循环）
下一轮：P2 剩余（TestClient）
2026-09-10（**决策-54 参数约束面统一落地**（ADR-0029, P2 矩阵 #2 ✅ / #3 bool 偏差销账）：
fastapi 0.141.1 / pydantic 2.13.5 活体探测 P26-a..h（约束消息/type/ctx 精确串 /
每字段首违 only + 优先级 mo→ge→gt→le→lt · minl→maxl→pat / multiple_of=0 no-op /
str+数值约束上游 no-op → 本实现注册期拒 / list+约束上游 500 → 本实现 fail-fast /
input 类型化: 在场=raw, 缺失+默认违约=类型化字面量 unquoted, parse 失败=raw）
→ **声明式 + 纯 Mojo 校验 + 自研 regex 引擎**（ADR-0004 范式,
**FFI diff = +1** `regex_match`）：`_param_constraints`（未声明 query 键 =
隐式 str 声明, len/pat only）+ `_header_types` typed header 校验
（缺失→默认值校验→422/注入字面量; 在场→parse→约束→注入 raw; 群序
path→query→header）+ `bridge/regex.rs`（re.search 语义子集, 零第三方,
纯整型运算 → -static-libgcc 守则保持）+ OpenAPI 3.0.3 约束键 + 6 demo
/con/* 路由
→ **实施期修复 ×3**（selftest/e2e 捕获）：① FFI 三态 `extract_request_header`
（0=found / -2=not-found / -1=error; 原 0 缺失/空值不可分 —
CP-12/15/16/20b 根因; F3a 注入语义不变, 缺失仍注入 ""）② OpenAPI alias
约束查找（cons 按声明名 keyed vs param_name=wire 名 — X-Ver schema
退化 {"type":"string"}; query alias 同型）③ `apply_query_extras` 标量
默认注入（200 路径 缺席+默认 → values, 上游形参默认值 parity）
→ e2e **403→428/428**（+CP-1..19, CP-20a/20b, CP-21..24）/ cargo
**434/0/4** / clippy **0 警告**（双 crate）/ ldd 仅 libc / binary
**4,020,232 B**（+205 KB vs 决策-53, ≤4.2M 预算）/ env -i 干净启动 /
bench 6 场景 0 errors（get_root_10k_100c = 35,124, 32.9k–43.9k 带内）/
RSS 平台化 / selftest **10/10** 全绿（JIT stub: `mojo run -Xlinker
jit_regex_stub.so` — LD_PRELOAD 无效, JIT materialization 先于进程
加载; stub abort-if-called, dev-only 不进 binary/CI）
下一轮：P2 剩余（middleware / TestClient）
2026-09-10（**决策-53 Header 参数精化**（ADR-0028, P2 矩阵 #7 ✅）：
fastapi 0.141.1 / uvicorn 0.52.4 活体探测 P25-1..10（alias 原样**不**转换 P25-3 /
逐字符 `_`→`-` P25-4 / CI 匹配 + 多值取首 / default·422·min_length·pattern·int
约束面 P25-6..9 → 下一决策矩阵 #2）→ **声明式映射**（ADR-0004 范式,
**FFI diff = 0** 纯 Mojo, JIT 可达）：`_reads_headers` 条目扩展 `name` /
`name=alias`（至多 1 `=`; 注册期 `check_header_specs` fail-fast, 同策略）+
默认下划线→连字符转换（`x_token`→`x-token`, P25-1/4）+ OpenAPI header
参数名 = wire 名（alias 原样 / 转换, 原始拼写保留, P25-2/3）+ demo
`/hdr/alias`（`x_token=Token-Literal` + `client_id`）
→ e2e **395→403/403**（+OP3-1..8: alias CI 命中 / alias 原始拼写 / 下划线
字面不绑 alias / 默认转换 / 下划线字面不读普通 / `/ctx` 回归 / OpenAPI
wire 名 / 多值取首）/ cargo **431/0/4**（Rust 零改动）/ clippy **0 警告**
（双 crate）/ ldd 仅 libc / binary **3,815,424 B**（+12 KB vs 决策-52,
≤4.2M 预算）/ env -i 干净启动 / bench 6 场景 0 errors
（get_root_10k_100c = 35,765, 32.9k–43.9k 带内）/ 孤儿 0 /
selftest ~22 断言全绿 0 警告
下一轮：P2 剩余（路径参数约束 / typed header 校验 (P25-6..9 已探测) / middleware / TestClient）
2026-09-10（**决策-52 OpenAPI 精化**（ADR-0027, P2 矩阵 #16 ✅）：
fastapi 0.141.1 / pydantic 2.13.5 活体探测 P24-1..15（+ p24e/f/g 勘误：operationId 默认 =
`re.sub(\W→_)` 逐字符**无 `_+` 折叠**（`another_one_a__id__b_post`）；servers.url = `AnyUrl |
str` smart-union str 精确匹配优先 → **不规范化**（`not-a-url` 亦原样）；AnyUrl 2.13.5：
host-only → 尾 `/`、path 空且有 `?`/`#` → 在其前插 `/`（`https://host?x` → `https://host/?x`））
→ **声明式映射**（ADR-0004 范式, **FFI diff = 0** 纯 Mojo, JIT 可达）：app 级 9
`FASTAPI_MOJO_OPENAPI_*` env（/openapi.json 请求期读, 空 = 默认/省略, 畸形 → 省略字段不 500）
+ 路由级 8 声明（`_summary` 默认 = name Python title()（P24-5 全向量）/ `_description` /
`_response_description` 默认 "Successful Response"（P24-8）/ `_operation_id` 默认
`{name}{path 逐 /{ }→_}_{method}`（P24-6）/ `_deprecated` / `_include_in_schema`（不进
paths/components 仍可服务, P24-13）/ `_status_code`="NNN Reason"（wire 仅当 handler 结果恰
"200 OK" 覆写 — 异常/401/405/422 不覆写; spec responses 主键 = 前 3 位, P24-7）/
`_responses`="404:Not found;…"（首 `:` 切, desc 可再含 `:`; 仅 description, P24-9; **与主键
重复 → 注册期拒绝** fail-fast `check_openapi_specs`, check_ws_specs/check_state_specs 同策略））
+ 键序对齐（operation P24-4: tags? summary? description? operationId parameters? requestBody?
responses security? deprecated?；根 P24-10: openapi, info, servers?, paths, components?,
tags?, externalDocs?；**externalDocs description 先**）+ AnyUrl quirk 复刻（见上；terms
无 quirk = 裸 str）+ 3 demo 路由（`/meta/probe` 全 operation 键 / `/meta/hidden` /
`/meta/made` 201）+ 新模块 `openapi_custom.mojo`（381 ln: title_case / default_operation_id /
url_host_quirk / info·servers·root tags·externalDocs JSON / parse_response_entries /
primary_status_key / check_openapi_specs — 纯函数无 FFI）+ `openapi.mojo` 重写（497 ln <500）
→ e2e **383→395/395**（+OP2-1..12: minimal info / full info 精确 / servers / tags+externalDocs /
probe op 精确 / hidden / made 201 / 默认 opid+summary / Successful Response / jsoncheck ×2 /
docs / health 回归）/ cargo **431/0/4**（Rust 零改动）/ clippy **0 警告**（双 crate）/
ldd 仅 libc / binary **3,803,136 B**（+70 KB vs 决策-51, ≤4.2M 预算）/ env -i 干净启动 /
bench 6 场景 0 errors（get_root_10k_100c = 33,590, 32.9k–43.9k 带内）/ 孤儿 0 /
selftest ~60 断言全绿 0 警告
下一轮：P2 剩余（Header alias / 路径参数约束扩充 / 用户自定义 middleware / TestClient）
2026-09-10（**决策-51 WebSocket 精化**（ADR-0026, P2 矩阵 #23 ✅）：
uvicorn 0.52.4 / wsproto 1.3.2 / starlette 1.6.0 活体探测 P23-1..7 + p23i close-wait A..E
（close reason 帧规范化: 1004/1006→1000 / 1005 无 payload / 123B codepoint 截断; close-wait:
数据·ping 丢弃 / 任何 close→静默 close / 10s 定时器; 合法接收码集）→ **声明式映射**
（ADR-0004 范式, `run_ws_message` 单点 dispatch 签名**不变**, 每消息评估, JIT 可达）:
`_ws_close=CODE:REASON`（回复后 close + close-wait; 首个 `:` 切分, 值可再含 `:`, 注册期
`check_ws_specs` 校验合法码集 + spec 形态, 畸形启动即 fail）/ `_ws_raise=msg`（无回复无
close 帧立即 EOF = 客户端 1006, log `[ws-exc] <route>: <msg>`）/ `_ws_exc_close=SPEC`
（无回复 close 帧 + close-wait）/ `_ws_no_reply=1` / `_ws_binary=1`（echo = NUL 保留
零拷贝 BINARY; 非 echo = 回复文本 BINARY）/ `_ws_json=<模板>`（echo 路径优先: JSON 模板
替代回显）；优先级 `_ws_raise` > `_ws_exc_close` > `_ws_close`（前两 pre-reply, 后一
post-reply）
+ **close-wait = bridge 新 phase 5**（`ws_set_closing` 入 phase + `ws_close_at=now`;
`pump_ws_closing`: 数据/ping/pong 丢弃, 任何 close 帧→静默 close（`ws_pump_close_quiet`
= 入队 END + reset_for_close, 无二次 close 帧）, EOF/协议错误→静默 close;
`check_deadlines` 新 `WsCloseWaitTimeout`（超时 = 入队 END + `table.close`, 无 close 帧;
phase 5 无 keepalive ping / 无 idle / 无 408）; env `FASTAPI_MOJO_WS_CLOSE_WAIT`
默认 **10000** = uvicorn 10.0s parity, 0 = 立即关, AtomicI32 sentinel 只读一次
（`get_ws_ping_max` 同款））
+ close 帧内容 = 2B code + reason（`ws_close_reason_payload` 纯函数: 1005→空 payload /
1004·1006→改写 1000 / reason >123B codepoint 边界截断（continuation byte 回退）;
NUL 终止契约决策-20）
+ **新模块 `ws_directives.mojo`（122 行 <500）+ `ws_directives_selftest.mojo`**
+ http_server_final **1551 → 1583**（+32: import + `check_ws_specs(router)` + 6 demo 路由
/ws/close · /ws/close/4001 · /ws-exc/boom · /ws-exc/close · /ws/bin · /ws/json）
**FFI diff = +5**（ws_send_close_reason / ws_write_binary / ws_write_current_binary /
ws_set_closing / get_ws_close_wait_ms; 既有 `ws_send_close(fd, code)` 保留 — 1002/1003/
1007/1008/1009 协议路径继续用）
e2e **383/383**（373 + 10 W: W1 回复后 close 1000 "bye" + close 回显**提前结束** <1s /
W2 无回复 close 4001 "custom reason" + close-wait 保持 ∈[1s,4s)（2s 配置）/
W3 未处理异常**无 close 帧**立即 EOF <1s（1006 parity）/ W4 WebSocketException close
4002 "ws-exc" / W5 binary NUL 保留往返 / W6 compact JSON UTF-8 逐字节
（`separators=(",",":"), ensure_ascii=False` parity）/ W7 close-wait 期 ping 丢弃（无
pong, 超时 EOF）/ W8 close-wait 期数据丢弃（无回复, 超时 EOF）/ W9·W10 server log
`[ws-exc]` ×2）/ cargo **431/0/4**（+22: ws.rs close_reason_payload ×8 + deadlines
phase-5 ×4 + ws_session_ffi ×10）/ clippy 0 警告（双 crate）/ bench 6 场景 **0 errors**
（get_root_10k_100c **34,880 req/s**, 32.9k–43.9k 区间内, vs 决策-50 32,938 噪声带内,
无回归）/ **ldd 仅 libc** / env -i 干净启动 / **3.7M**（3,733,504 B, ≤4.2M, +33 KB vs
决策-50）/ `find src -name '*.c'` = 0 保持 / `mojo run ws_directives_selftest.mojo`
all passed;
实施注记: `_ws_json` 初版仅接线非 echo 路径（smoke 实测 echo 路径仍回显, 已修: echo 路径
JSON 模板优先, 与 ADR §3.1 语义一致）+ 2 处单测断言笔误修复（`raw[4..127]` 帧长 127 /
3 字节 NUL payload 误写 4 字节目标）+ ws_session.mojo 4 处 docstring summary 改 ASCII
`.` 收尾（Mojo 1.0.0 docstring lint 仅对 primary target 生效 — imported 文件不报, 本文件
此前从未作为 primary 编译故未暴露）+ FMTOOL `ws5` 新子命令（10 检查, 复用 ws.rs 帧
handshake/解析）;
下一轮：P2 剩余（OpenAPI tags / Header alias / 约束扩充 / middleware / TestClient）；
2026-09-10（**决策-50 Request.state**（ADR-0025, P2 矩阵 #22 ✅）：
starlette 1.6.0 P22-1..6 探测（scope 承载 property / 属性·dict 双写读面共享 _state（1.6.0 无下划线禁止）/
缺失读 → AttributeError·KeyError → 500 / del-缺失 → KeyError quirk / in·len·iter（**无 __contains__**）/
每请求隔离 ×2 活体）→ **声明式映射**（ADR-0004 范式, **FFI diff = 0** 纯 Mojo, JIT 可达）：写面
`_state_set = "key:value;…"`（首个 `:` 切分, value 可再含 `:`; 值 `{param}` 插值 — 缺失键保留字面量
防静默填空; 评估位置 = 全部注入之后、读面注入之前 = 「middleware 先写、endpoint 后读」声明式等价;
空 key/空条目跳过; **注册期校验 `check_state_specs`**（畸形 spec 启动即 fail, 与 check_body_schemas
同策略））+ 读面 `_reads_state` CSV → `params["state_<name>"]`（F10 header_/cookie_ 完全同范式;
缺失 → "" = F10 既有约定, 上游 500 → §3.5-1）+ 存储 = dispatch 每请求 `Dict[String,String]`
（P22-2/6, 请求结束即弃 — 无跨请求残留）
+ **新模块 `request_state.mojo`（124 行 <500）**（validate/apply/inject/check_state_specs）+
**`request_state_selftest.mojo`**（JIT 可达纯逻辑自检 — set 解析/colon 保留/插值/缺失键字面量/
空条目跳过/读注入/缺失 → ""/trim/注册校验; file_params_selftest 同模式, 不触 run_handler FFI 闭包）+
http_server_final **1509 → 1551**（+42: import + 每请求 state 构造 + 写/读接线（`inject_dep_calls`
之后、`guarded_run_handler` 之前, state 消费后不再用）+ **3 demo 路由** /state · /state-dyn/{who} ·
/state-missing（无 set 读 user,ghost → 双空 = **跨请求隔离证明** — 前一请求写 user=bob 本请求读不到,
P22-6））
e2e **373/373**（366 + 7 XS：/state set+read / /state-dyn/bob 插值 / /state-missing 双空串 /
跨请求隔离（bob、alice 写后独立请求 state 仍空 ×2）/ /health 200 / /errors/99 404（F2）/ /exc/ve 500
（决策-49）回归）/ cargo **409/0/4**（FFI diff = 0）/ clippy 0 警告（双 crate）/ bench 6 场景
**0 errors**（get_root_10k_100c **32,938 req/s**, 32.9k–43.9k 区间内, 无回归）/ **ldd 仅 libc** /
env -i 干净启动（health + /state + /state-dyn/bob 全对）/ **3.7M**（3,700,736 B，≤4.2M，+36 KB vs
决策-49）/ `find src -name '*.c'` = 0 保持 /
**测试基础设施强化（环境项, ADR-0025 §3.5-7）**：本机 dev 环境透明代理劫持新 bind 端口 ~2s 内首连接
（Caddy :80 假空 200 — 真 server 收不到请求, taint = 该 bind 生命周期, 60s+ 不解除, 实测;
干净环境 CI 无此代理）→ e2e 6 副 server 就绪探针 + `fmtool bench` 均 **bind 后 sleep 5s 再首探针**
+ `/health` body 须含 `healthy`（假响应 body 为空）防假 ready（CI 仅多等 5s, 行为不变）;
下一轮：P2 剩余（WS 精化 / OpenAPI tags / Header alias / 约束扩充 / middleware / TestClient）；
2026-09-10（**决策-49 任意异常类型 handler**（ADR-0024, P2 矩阵 #13 ✅）：
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
