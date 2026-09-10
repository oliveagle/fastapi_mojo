# ADR-0027: OpenAPI 精化 — 顶层 tags/info/servers/externalDocs + 路由级自定义
# （summary/description/response_description/operation_id/deprecated/include_in_schema/status_code/responses）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #16 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-52**）、Goal-0003（矩阵 #16 OpenAPI
  tags/prefix/custom）、ADR-0004（路由 = 数据范式）、F4（决策-24，OpenAPI 3.0
  基座 + Swagger UI）、ADR-0013/决策-37（APIRouter prefix/tags 合并 — 本 ADR
  的「prefix/tags」部分已由 #37 闭环，此处补齐「custom」面）、
  FastAPI 0.141.1 / starlette 1.6.0 / uvicorn 0.52.4（语义对标）

## 1. 背景

Goal-0003 矩阵 #16：`OpenAPI | spec + Swagger + tags/prefix/desc | ✅ | tags/prefix/custom | §P2`。
盘点现状（决策-24 F4 + 决策-37 ADR-0013 之后）：

- ✅ spec 基座（3.0.3）、`/docs` Swagger UI、operation 级 `_tags`（CSV）、
  router prefix/tags/deps include 时合并（#37）、`/openapi.json` 动态生成。
- ❌ 剩余「custom」面（上游 FastAPI 0.141.1 `FastAPI.__init__` + 路由参数）：
  1. **顶层 tag 元数据**：`openapi_tags=[{name, description}]` → spec 根 `tags`
     数组（路由 operation 级 tags 之外的 Swagger 分组描述面）。
  2. **自定义 info**：`description` / `terms_of_service` / `contact`
     （name/url/email）/ `license_info`（name/url）。
  3. **servers** / **externalDocs**（`openapi_external_docs`）。
  4. **路由级**：`summary` / `description` / `response_description` /
     `operation_id` / `deprecated` / `include_in_schema=False` /
     `status_code=`（responses 主键）/ `responses={额外状态码}`。
  5. **默认值面**：operationId 公式、summary 标题化、200 描述
     "Successful Response"（现实现：`<method>_<name>` / 裸名 / "OK" — 偏差）。

**上游探测（P24-1..15, /tmp/exch_probe/p24*.py, fastapi 0.141.1）**：

| # | 实测 |
|---|------|
| P24-1 | `FastAPI(title, description, terms_of_service, contact, license_info, version)` → `info` 键序 `title, description?, termsOfService?, contact?, license?, version`（缺省项省略） |
| P24-2 | `openapi_tags` → 根 `tags` 数组逐元素 `{name, description}`（**原样透传**；路由 tags 不在 openapi_tags 中时**不**并入根 tags — 独立数组） |
| P24-3 | `servers=[{url, description}]` → 根 `servers`（键序 url, description） |
| P24-4 | operation 键序：`tags?, summary?, description?, operationId, (parameters, requestBody), responses, (security), deprecated?`（deprecated 仅 true 时出现；description 缺省省略） |
| P24-5 | **summary 默认 = endpoint 名 Python `str.title()`**（`_`/`-`→空格后：`foo_bar`→"Foo Bar" / `v2api`→"V2Api" / `apiV2`→"Apiv2" / `UPPER`→"Upper" / `a__b`→"A  B"）；显式 `summary=""`（falsy）→ 回落默认 |
| P24-6 | **operationId 默认 = `{funcname}{path 逐字符 / { } → _}_{method小写}`**（上游 = `re.sub(r"\W","_", name+path) + "_" + method`，**无 `_+` 折叠**，0.141.1 `generate_unique_id` 源码实测；`foo_bar` @ `/x/y/{z}` GET → `foo_bar_x_y__z__get`；`another_one` @ `/a/{id}/b` POST → `another_one_a__id__b_post`；`calc` @ `/calc/{a}/{b}` GET → `calc_calc__a___b__get`） |
| P24-7 | `status_code=201` → responses 主键 "201"，description "Successful Response" |
| P24-8 | 200 默认 description = **"Successful Response"**；**上游 0.141.1 输出 OpenAPI 3.1.0**（200 content schema = `{}` 空对象） |
| P24-9 | 额外 `responses` 值**必须是 dict**（字符串 → `AssertionError: An additional response must be a dict`） |
| P24-10 | 根键序：`openapi, info, servers?, paths, (components?), tags?, externalDocs?`；**externalDocs 键序 = description?, url**（url 必填） |
| P24-11 | `root_path` / `root_path_in_servers`（True/False）→ **paths 键不变、无 servers 注入**（0.141.1 无 spec 影响） |
| P24-12 | `extra` 参数 = **no-op**（spec 无新键）；**contact.url / license.url / externalDocs.url 经 pydantic AnyUrl 2.13.5 规范化**：`://` 后 path 为空 → 追加尾 `/`（host-only / host:port）或**在 `?`/`#` 前插入 `/`**（`https://host?x` → `https://host/?x`）；带 path 不变（`https://x.y/a/b`）；无 `://`（mailto:/相对串）不变。**servers.url 不规范化**（`Server.url: AnyUrl | str` — str 精确匹配优先于 AnyUrl 转换，`https://support.example` 原样；`not-a-url` 亦原样） |
| P24-13 | `include_in_schema=False` → 路由**不进 paths**（仍可服务）；`/openapi.json` 自身亦不在 paths |
| P24-14 | `FastAPI.__init__` openapi 相关参数全集：`openapi_url, openapi_tags, servers, docs_url, redoc_url, terms_of_service, contact, license_info, openapi_prefix, root_path, root_path_in_servers, webhooks, openapi_external_docs, extra` |
| P24-15 | 上游 spec 版本 = **3.1.0**（OpenAPI 3.1 pydantic 模型） |

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 运行期可变 spec | `get_openapi()` 覆写 / `app.openapi` 字典运行期修改 | ❌ Mojo 无闭包/无运行期对象修改面；声明式世界观（ADR-0004）不允许运行期改路由元数据 |
| B. **声明式 env + 路由 data（本 ADR）** | app 级 = 9 个 `FASTAPI_MOJO_OPENAPI_*` env（/openapi.json 请求期读取，默认值 = 上游缺省语义）；路由级 = `_summary/_description/_response_description/_operation_id/_deprecated/_include_in_schema/_status_code/_responses` handler.data（ADR-0004 范式，`_tags` 同族）；纯 Mojo，FFI diff = 0 | ✅ 与决策-37/42/45/49/50 同范式；dispatch 零新查找（仅 JSON 分支 status_line 覆写一处 + 注册期校验）；key 序/缺省语义逐 P24 项对齐 |
| C. spec 模板文件 | 用户手写 openapi.json 片段合并 | ❌ 需 JSON 解析器（json.mojo 仅序列化）；与路由表双事实源 |

**决策：B** —— 声明式映射，FFI diff = 0（决策-52）。

## 3. 决策

### 3.1 app 级（env，`/openapi.json` 请求期读取；畸形 → 省略该字段，不 500）

| env | spec 落点 | 格式 | 默认 |
|-----|----------|------|------|
| `FASTAPI_MOJO_OPENAPI_TITLE` | `info.title` | 原文 | `fastapi_mojo API`（F4 既有） |
| `FASTAPI_MOJO_OPENAPI_VERSION` | `info.version` | 原文 | `1.8.0`（F4 既有） |
| `FASTAPI_MOJO_OPENAPI_DESCRIPTION` | `info.description` | 原文（JSON 转义） | 省略 |
| `FASTAPI_MOJO_OPENAPI_TERMS` | `info.termsOfService` | 原文（**无 URL quirk** — 上游为裸 str） | 省略 |
| `FASTAPI_MOJO_OPENAPI_CONTACT` | `info.contact` | `name\|url\|email`（恰好 3 段，`\|` 分；url 经 AnyUrl 尾 `/` quirk） | 省略 |
| `FASTAPI_MOJO_OPENAPI_LICENSE` | `info.license` | `name\|url`（2 段） | 省略 |
| `FASTAPI_MOJO_OPENAPI_SERVERS` | `servers` | `url:desc;url2:desc2`（切分 = `://` 后首个 `:`；紧随段全数字 1-5 位 → 视为端口再找下一个 `:`；无 scheme 相对 url 按首个 `:` 切；desc 可省 → 省略键；**url 原样透传** — 上游 Server.url 为 AnyUrl\|str 不规范化, P24-12） | 省略 |
| `FASTAPI_MOJO_OPENAPI_TAGS` | `tags`（根） | `name:desc;name2:desc2`（desc 可省；**原样透传**，路由 tags 不并入） | 省略 |
| `FASTAPI_MOJO_OPENAPI_EXTERNAL_DOCS` | `externalDocs` | `url\|desc`（desc 可省；键序 description 先；url quirk） | 省略 |

### 3.2 路由级（handler.data，注册期校验 `check_openapi_specs`，畸形启动即 fail）

| key | 语义 | 校验 |
|-----|------|------|
| `_summary` | operation summary；**空/缺失 → 默认 = handler.name 标题化**（Python title() 算法：`_`/`-`→空格，词首字母大写其余小写，数字后字母大写） | 任意串 |
| `_description` | operation description | 任意串（空 → 省略键） |
| `_response_description` | 主 status 响应描述；缺失 → `"Successful Response"` | 任意串 |
| `_operation_id` | operationId 显式；缺失 → 默认公式 `{name}{path /{ }→_}_{method}`（P24-6） | 非空 |
| `_deprecated` | `1` → `"deprecated":true`（false/缺失不输出，P24-4） | ∈ {"","1"} |
| `_include_in_schema` | `0` → 路由不进 spec（仍服务，P24-13） | ∈ {"","0"} |
| `_status_code` | `"NNN Reason"` 全形态（与 `_stream_status`/`_file_status` 同型）→ **wire status 覆写 + spec responses 主键 = 前 3 位**（P24-7） | 3 位数字 100-599 + 空格 + 非空 reason |
| `_responses` | 额外状态码 `404:Not found;418:Teapot`（首 `:` 切 status/desc，desc 可再含 `:`）→ responses 追加（仅 description，P24-9 dict 形态） | 每项 3 位数字 100-599 + 非空 desc；**不得与主键重复**（上游用户 dict 覆盖语义 → 本实现注册期拒绝，偏差 §3.5-8） |

**operation 键序**（P24-4）：`tags?, summary?, description?, operationId,
parameters?, requestBody?, responses, security?, deprecated?`（现实现
operationId-first 重排对齐；security = 决策-44 oauth2 既有）。

**根键序**（P24-10）：`openapi, info, servers?, paths, components?, tags?,
externalDocs?`（现 `openapi, info, paths, components?` 重排对齐）。

**info 键序**（P24-1）：`title, description?, termsOfService?, contact?,
license?, version`。

**contact.url / servers url / externalDocs.url 尾 `/` quirk**（P24-12 复刻）：
scheme 之后第一个 `/`/`?`/`#` 均不存在（host-only）→ 追加 `/`。

**`_status_code` wire 行为**（对齐矩阵 #12 status_code 声明面）：dispatch
JSON 公共分支在 `resp_data = gres.resp_data.copy()` 后覆写
`status_line = _status_code`（SSE/FILE/OAUTH2 分支已各自 continue，不受影响；
`_stream_status`/`_file_status` 既有先例同型）。

### 3.3 FFI

**FFI diff = 0**（纯 Mojo：`openapi_custom.mojo` 新模块 + `openapi.mojo`
重构 + `http_server_final.mojo` 接线；无新导出/无 libm/无新依赖 — ldd 仅
libc 不变）。

### 3.4 demo 路由（http_server_final.mojo）

- `/meta/probe`（GET）：`_tags="probe,custom"`（不在 root tags → 证明不并
  入）+ `_summary="Probe Sum"` + `_description="Probe desc"` +
  `_response_description="probe ok"` + `_operation_id="probe_op"` +
  `_deprecated="1"` + `_responses="418:Teapot custom"` — 单路由覆盖全部
  operation 级键。
- `/meta/hidden`（GET）：`_include_in_schema="0"`（200 可服务 + 不在 spec）。
- `/meta/made`（GET）：`_status_code="201 Created"`（wire 201 + spec 键 201）。

### 3.5 文档化偏差（vs 上游 FastAPI 0.141.1，9 条）

| # | 上游 | 本实现 | 定性 |
|---|------|--------|------|
| 1 | spec 版本 **3.1.0**（200 schema = `{}`） | **3.0.3**（200 schema = `{"type":"object"}`） | F4（决策-24）既定基座；3.1.0 迁移 = 全量 schema 形态变更，另立决策 |
| 2 | `get_openapi()` 覆写 / `app.openapi` 运行期可变 | spec = 请求期声明式再生成，无运行期修改面 | ADR-0004 范式；上游 `extra` 参数本身即 no-op（P24-12） |
| 3 | `status_code=201`（int） | `_status_code="201 Created"`（全 status line，`_stream_status`/`_file_status` 同型） | 项目声明式状态约定（F9/F48）；spec 键取前 3 位等价 |
| 4 | `FastAPI(...)` 构造器参数 | 9 个 `FASTAPI_MOJO_OPENAPI_*` env（请求期读） | ADR-0004；畸形 env → 省略字段（不 500 — env 非注册期数据） |
| 5 | `root_path`/`openapi_prefix`/`openapi_url`/`docs_url`/`redoc_url` | 未实现（`/openapi.json`/`/docs` 固定） | P24-11：0.141.1 root_path 对 spec 无影响 → 无 parity 损失；其余为部署面参数，矩阵 #16 不含 |
| 6 | `webhooks=` 参数 | 未实现 | 矩阵 25 行未含 webhooks；后续单独立项 |
| 7 | summary 默认 = endpoint **函数名** title() | = handler.name title() | 同字符串约定（handler.name = 函数名等价物，决策-37 范式）；算法逐 P24-5 对齐 |
| 8 | 额外 `responses` 键与 status_code 重复 → 用户 dict 覆盖 | 注册期拒绝（check_openapi_specs fail-fast） | 声明式严格化：歧义配置启动即暴露，优于运行期静默覆盖 |
| 9 | 路由 `tags` 与 `openapi_tags` 独立（路由 tags 不入根） | 同款（P24-2 复刻，e2e 守护） | parity（列此完备） |

## 4. 风险

- **R1 key 序变更影响**：operation/根 key 重排 + 默认值变更（"OK" →
  "Successful Response"、operationId 公式、summary 标题化）改变 /openapi.json
  既有字节 — 现有 e2e 全部子串断言（50 处 openapi 引用）经审计无
  operationId/"OK"/summary 精确断言（MP21 jsoncheck 整文档合法性保留）→
  无回归；消费方需知悉 spec 形态更贴上游。
- **R2 env 请求期读取**：`/openapi.json` 每次生成读 9 env（getenv 微秒级，
  仅该端点触发；非热路径）。
- **R3 title() 算法边界**：Mojo 复刻 Python str.title()（字母/数字边界）—
  selftest 用 P24-5 全向量守护（v2api/apiV2/UPPER/a__b 等 8 例）。
- **R4 binary 体积**：纯 Mojo 代码 +~20-30 KB（远小于 ≤4.2M 预算余量）。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`openapi → openapi_custom → {router, json}`；`http_server_final → {openapi, openapi_custom}`；无回边 |
| 2. 模块 < 500 行 | ✅ 遵守 | `openapi_custom.mojo` 381 行；`openapi.mojo` 497 行（< 500，贴线）；`http_server_final.mojo` +59 行（接线/demo, god-file 既有） |
| 3. FFI 表面不变 | ✅ 遵守 | **FFI diff = 0**（无新 `#[no_mangle]` 导出；`send_simple_response_extra` 等既有） |
| 4. 零新依赖 | ✅ 遵守 | 纯 Mojo 标准库（std.os.getenv / 字符串处理）；无 Rust 改动 → ldd 仅 libc 不变；无 libm |
| 5. 单 binary 不变式 | ✅ 遵守 | `build_single.sh` 流程零改动；spec 生成 = 进程内纯函数（启动暂存/dlopen 机制不涉及） |
| 6. 声明式世界观 | ✅ 遵守 | app 级 env + 路由 handler.data（ADR-0004）；注册期 `check_openapi_specs` fail-fast（check_state_specs/check_ws_specs/check_body_schemas 同策略）；无运行期对象修改 |

## 7. 验证方式（实测 2026-09-10）

1. **单 binary 不变式**：`ldd build/fastapi_mojo` = 仅 libc；binary
   **3,803,136 B**（3.7M ≤ 4.2M，vs 决策-51 基线 3,733,504 B **+70 KB** —
   纯 Mojo：openapi_custom.mojo 381 ln + openapi.mojo 497 ln 重写 +
   3 demo 路由 + env 接线；无 Rust/FFI 改动）；`env -i` 干净启动
   （`/health` JSON 200 healthy，等 listener + sleep 5 + body 校验
   防透明代理假 ready）；`find src -name '*.c'` = 0；`find . -name
   '*.py'`（excl .git/docs）= 0；`pgrep -x fastapi_mojo` = 0（SIGTERM
   优雅关停后自行退出，无孤儿）。
2. **质量门禁**：`cargo test --release -- --test-threads=1`
   (fastapi_mojo_rs) = **431 passed / 0 failed / 4 ignored**（纯 Mojo
   决策，Rust 侧零改动）；fmtool `cargo test` = 0 测试 exit 0；
   `cargo clippy --release --tests -- -D warnings` 双 crate = **0
   警告**；`mojo run openapi_custom_selftest.mojo` = all checks passed
   （~60 断言, 0 警告）；`openapi.mojo` / `openapi_custom.mojo`
   `--emit object` = 0 新警告（仅 5 处历史基线警告，决策-23 既有）。
3. **e2e**：383 → **395/395 全绿**（+OP2-1..12：OP2-1 subserver 无
   OPENAPI env 的 minimal info（`title/version` 相邻 `"paths"`，证明
   servers 键省略）；OP2-2 full info 精确串（键序 + terms 无 quirk +
   contact/license url quirk `https://support.example/`）；OP2-3
   servers 位于 info 与 paths 之间；OP2-4 根 tags（`name:desc`，desc
   保 `:`）+ externalDocs 收尾（**description 先**）；OP2-5
   `/meta/probe` operation 精确串（tags/summary/description/
   operationId/responses{200:probe ok + 418:Teapot custom}/deprecated
   全键序）；OP2-6 `/meta/hidden` 200 可服务 + spec 0 出现
   （include_in_schema=0）；OP2-7 `/meta/made` wire **201** + spec
   `"201":{"description":"Successful Response"`；OP2-8 默认
   operationId `health_health_get` + summary 标题化 `Health`；OP2-9
   200 默认描述 "Successful Response"；OP2-10 双 server 完整文档
   fmtool jsoncheck 合法；OP2-11 /docs 200 + title 不变；OP2-12
   /health 200 回归）。
4. **性能**：bench 6 场景 **0 errors**；**get_root_10k_100c = 33,590
   req/s**（32.9k–43.9k 区间内，vs 决策-51 34,880 — 噪声带内，无退化）；
   RSS 平台化（spec 生成 = 请求期 StringBuilder 拼串，无新常驻状态；
   env 请求期读仅 /openapi.json 触发）。
5. **环境注记**：
   - **上游 operationId 公式勘误**：本 ADR 初版 P24-6 笔误
     `another_one_a__id_b_post`（id 后单 `_`）— 对 0.141.1 源码
     （`re.sub(r"\W","_")` 逐字符、无 `re.sub(r"_+","_")` 折叠）
     实测为 `another_one_a__id__b_post`（`id` 两侧各 `__`：`/`+`{` /
     `}`+`/` 各产生一个 `_`）；Mojo 复刻逐字符映射与之逐字节一致
     （selftest 4 向量守护，含 `calc_calc__a___b__get`）。
   - **servers url 规范化修正**：初版将 servers url 套用 AnyUrl 尾 `/`
     quirk — 实测 0.141.1 `Server.url: AnyUrl | str`，smart-union 下
     str 精确匹配优先 → **servers url 原样透传**（含 `not-a-url`）；
     quirk 仅适用 contact/license/externalDocs（纯 AnyUrl）。
   - **AnyUrl 2.13.5 细节**：path 空且有 `?`/`#` → 在其**前**插 `/`
     （`https://host?x` → `https://host/?x`），非「有 ?/# 即不变」；
     无 `://` 的串（mailto:/相对路径）不变。
   - **`_status_code` wire 守卫**：仅当 handler 结果恰为 `"200 OK"`
     时覆写（上游 status_code 声明的是成功态；异常/401/405/422 结果
     不覆写 — 405 flow 的 status_line ≠ "200 OK" 天然安全）。
   - **hidden 路由与 components**：`_include_in_schema="0"` 路由的
     body/form/multipart schema 也不进 components（上游 components 从
     paths 引用图构建，hidden 路由无 $ref 引用 → 无孤儿 schema）。
   - Mojo 1.0.0 老坑照旧：docstring lint 仅对 primary target 生效
     （openapi_custom 作为 import 跳过）；`Tuple`/`Dict` 非
     ImplicitlyCopyable（`parse_response_entries` `return out.copy()`）；
     `Dict` 下标访问需 `raises` 上下文（`_route_hidden` 标 `raises`）。
