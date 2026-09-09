# ADR-0020: Form 参数精化 — 多值 List / alias / description + 422 detail parity

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #5 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-45**）、Goal-0003（P2：Form 多值，
  对标矩阵行 #5）、North Star（单 binary 零依赖 — **零新 crate，FFI diff = 0**）、
  ADR-0018（决策-43 query 多值/alias/desc — 本 ADR 的 form 对偶 + 两处更正）、
  决策-38（422 detail Pydantic v2 结构）、决策-44（form body 解析归
  request_response 的分层先例）、FastAPI 0.141.1 + pydantic 2.13.5
  （/tmp/fm_probe 逐条实测，本 ADR §1 证据）

## 1. 背景

Goal-0003 P2 矩阵 #5：`Form(...)` **多值**（`q: List[int] = Form(...)` —
重复 key 收集为 list）+ alias/description（决策-43 已为 query 落地同款语义，
Form 是上游 API 面剩余的一块）。

**实测证据（FastAPI 0.141.1 + pydantic 2.13.5，/tmp/fm_probe 逐条 probe；
raw body 发送以避开 TestClient/httpx 编码差异 — 早期 probe 用 list-of-tuples
data 参数实测发现 httpx 0.28 不再正确编码，FormData 全空，故一律 raw + CT）**：

Form（application/x-www-form-urlencoded）：

- F1 `q: List[str] = Form(...)`：`q=1&q=2&q=3` → 200 `["1","2","3"]`（全部
  occurrence，顺序）；单值 `q=7` → `["7"]`（**wrap 成 list**）
- F2 必填 list 缺失 → 422 `{"type":"missing","loc":["body","q"],
  "msg":"Field required","input":null}`（**F 大写**）
- F3 `q: List[int] = Form(...)`：`q=1&q=a&q=3` → 422
  `{"type":"int_parsing","loc":["body","q",1],"msg":"Input should be a valid
  integer, unable to parse string as an integer","input":"a"}`
- F4 **两个坏元素 → 两个错误全收集**（顺序）：`q=a&q=b` → 两条
  （loc `["body","q",0]` + `["body","q",1]`）
- F5 默认 `Form([])` 缺失 → 200 `[]`
- F6 空串元素（`q=&q=2`，int list）→ 422 int_parsing `input:""`
- F7 **标量重复 key = last-wins**：`a=1&a=2` → `"2"`（Starlette
  MultiDict.get；`request.form()` 实测 getlist_a=["1","2"], get_a="2"）
- F8 `Form(alias='renamed')`：**wire key = alias**；发原始名 → 忽略
  （用默认值，200）
- F9 标量默认：`a: str = Form('dflt')` 缺失 → "dflt"；OpenAPI 单字段
  `{"type":"string","title":"A","default":"dflt"}` /
  `{"type":"integer","title":"B","description":"num b","default":0}`
- F10 OpenAPI：list 字段 `{"items":{"type":"integer"},"type":"array",
  "title":"Q","description":"...","default":[]}`（字段序 items/type/
  title/description/default）；`requestBody` =
  `{"content":{"application/x-www-form-urlencoded":{"schema":{"$ref":
  "#/components/schemas/Body_<fn>_<route>_<method>"}}}}`，**仅当存在必填
  字段时带 `"required":true`**（全默认 → 无 required 字段）

422 detail 全局 parity（query / JSON body，本次 probe 一并核实 — 顺带更正
ADR-0018 两处前提）：

- P1 **query list 多坏元素 = 全收集**：`?q=1&q=zz&q=yy` → 两条
  int_parsing（loc `["query","q",1]` + `["query","q",2]`）— **更正 ADR-0018
  「首个失败即停 = 上游同款」的错误实测结论**（0.141.1 + pydantic 2.13.5
  对 query/body 均为 collect-all）
- P2 query 缺失 → `"msg":"Field required"`（**F 大写**）+ `input:null` —
  本实现决策-38/43 用 "field required"（小写，旧版 FastAPI 措辞）
- P3 JSON body 缺失 → "Field required" + **`input` = 收到的 body 对象**
  （`{}` / `{"c":[1]}`）
- P4 标量 parse 失败 → `input` = 原始字符串（query `?q=zz` / form `b=zz` 均
  实测）
- P5 **所有 422 错误对象均含 `input` 字段**（本实现决策-38/43 的 detail 仅
  loc/msg/type 三字段）
- P6 **float 接受 int 字面量**：`q: float` 发 `q=1` -> 200 (pydantic v2:
  "1" -> 1.0)；本实现 `_is_float_literal`（决策-38 存量）要求小数点/指数
  -> 本决策 parse_typed_value 一并修正
- P7 **/openapi.json 是非法 JSON (P0, 决策-38 起潜伏)**：query 参数 schema
  括号配对错（标量分支不关对象 + `_generate_parameter` 过早关参数对象且
  parameter 级 description 落到对象外）-> 整文不可解析 (Swagger UI 无法
  渲染)；子串 e2e 一直未发现 -> 本决策修正 + `fmtool jsoncheck` 整文
  门禁 (FM-17)

约束（Mojo 1.0.0 + North Star）：Mojo 无闭包 → 声明式数据
（`handler.data`，决策-34/38/43/44 同模式）；FFI 零改动（form 解析纯 Mojo，
`_parse_form_body` 分层先例 = 决策-44）。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. form 多值下推 Rust bridge | bridge 解析 form → multi-map FFI | ❌ `_parse_form_body` 已是纯 Mojo（决策-44 先例）；FFI 面扩张（需 multi-map 编码/解码契约）无收益；违反「纯逻辑归 Mojo」分层 |
| B. **纯 Mojo `form_params` 模块 + 422 parity 修复（本 ADR）** | `form_params.mojo`（validate/apply/openapi，纯函数）+ `request_response.parse_form_multi`（multi-map 解析）+ `params_typed._pe`/`params_query_extra.make_error_json`/`body_validate.err_obj` 加 `input` + 收集语义修正 + dispatch 2 处接线 + 2 条 demo 路由 | ✅ 与决策-43（query）完全对偶；FFI diff = 0；新模块 <500 行；声明式 = 既有模式；`openapi_schemas` 模块抽取使 openapi.mojo 回落到 <500 |
| C. 并入 params_query_extra | 复用 query 机制处理 form | ❌ form 的 loc（body）/取值源（body multi-map）/OpenAPI（requestBody）与 query 本质不同；并入会把 params_query_extra（364）推到 ~500 且混主题，违反 §3.2 主题域边界 |

**决策：B**（决策-45）。

## 3. 决策

1. **`request_response.mojo` 新增 `parse_form_multi(body) ->
   Dict[String, List[String]]`**（`_parse_form_body` 的 multi 姊妹函数，
   决策-44 同位置）：同 key 全部 occurrence 按序 append（Starlette
   getlist 语义）；每 key/value url_decode（percent + '+'）；裸 key（无 '='）
   → 空串元素；与 `_parse_form_body` 相同的宽松规则（空 key 跳过）。
2. **新 `form_params.mojo`（~330 行，纯 Mojo，无 FFI/env/fd）**：
   - `get_form_types`（`_form_types`，**与 `_param_types` 同语法**：
     `items:int[]` 必填 list / `fx:float[]=` 默认空 list / `count:int=0`
     标量默认 / `str[low,high]` enum / `str` / `bool`）/
     `get_form_aliases`（`_form_aliases "name=alias"`，wire key = alias，
     原始名无绑定效力 — 决策-43 alias 语义的 form 对偶）/
     `form_has_declaration`（`_form_fields` 或 `_form_types` 非空）
   - `validate_form_collect(type_spec, aliases, multi) -> (ok, errs)`：
     loc `["body",name(,i)]`；**缺失 → "Field required"（F 大写，0.141.1
     实测）+ input null**；list = 全部 occurrence 逐元素校验
     **（collect-all，F4/P1 实测；上游 0.141.1 query/body 同款）**；
     标量 = last-wins 校验（F7 实测）；enum/str/int/float/bool 消息与
     params 侧同源
   - `apply_form_extras(params, type_spec, aliases, multi, fields_csv)`
     成功路径归一化：list → CSV（缺失 → 默认 CSV；决策-43 内部表示同约定）
     / 标量 → last-wins（缺失 → 默认）/ alias → `form_<内部名>` = 按 alias
     wire key 绑定值 / `_form_fields` 中未声明 `_form_types` 的字段 →
     旧语义（last-wins；缺失 → ""，**向后兼容** /login 等存量路由）
   - `form_openapi_schema(handler, method) -> String`：
     `{"type":"object","title":"Body_<name>_<method>","properties":{...}}`
     — 每字段 F10 字段序（list: items/type/title/description/default；
     标量: type/title/description/default）；description 复用 `_param_descs`
     共享表
   - `check_form_schemas(router)`：注册期校验（`_form_types` 未知类型 /
     坏默认值 → fail-fast，决策-38 `check_body_schemas` 同模式）
3. **422 detail parity（3 个既有 error-object 构造器加 `input`）**：
   - `params_typed._pe(loc,msg,type,input_json)` / `params_query_extra.
     make_error_json(...,input_json)` / `body_validate.err_obj(...,
     input_json)` — 输出字段序 `loc,msg,type,input`（上游序为 type,loc,
     msg,input — **字段序差异文档化**，字段集合一致）；
     missing → `input:null`；parse/enum/元素 → `input:"<raw>"`（json
     转义）；JSON body 缺失 → `input` = 收到的 body JSON（P3 实测；
     解析失败 body → `null`）
   - "field required" → **"Field required"**（params_typed ×2 +
     body_validate ×1；security_jwt 决策-44 已是 F 大写，无需改）
   - `validate_list_values`（query list）**stop-on-first → collect-all**
     （P1 实测更正 ADR-0018；form list 原生 collect-all）
   - `parse_typed_value` 增加 `"str"` 接受（潜在 bug 修复：`parse_base("str")`
     产 type_name="str" 但 parser 只认 "string" — 存量无路由触发，本决策
     form 用 str 前修复）
4. **dispatch 接线（http_server_final，2 处）**：
   - 校验段（`validate_params_collect`/`validate_body_schema` 之后）：
     `Content-Type` 含 `application/x-www-form-urlencoded`（大小写不敏感）
     → `multi = parse_form_multi(body_str)`，否则空 multi-map（**上游同款**：
     非 form body → form 字段全缺失 → 默认/422）；`validate_form_collect`
     错误并入既有 `all_errs`（422 统一出口，零新分支）
   - 注入段：`inject_form_fields`（决策-28）**移除**，替换为
     `apply_form_extras`（单点）— 有 `_form_types` 走新语义，无则
     `_form_fields` 旧语义（向后兼容）
   - demo 路由：`/form-multi`（POST；`_form_types
     "items:int[];tags:str[];count:int=0;fx:float[]=;fb:bool[]="` +
     `_form_fields` 同名 5 字段 + `_param_descs "items=..."`）+
     "_form_types "labels:str[]=;size:int=2"` +
     `_form_aliases "labels=tags"`）
5. **OpenAPI**：`openapi.mojo` 的 `_generate_operation` 在 `_body_schema`
   requestBody 之后加 form 分支（互斥：有 `_body_schema` 不叠加；`_multipart`
   路由跳过 — multipart OpenAPI 独立决策）：`requestBody`（urlencoded
   $ref `Body_<name>_<method>`；**`required:true` 仅当存在无默认
   `_form_types` 字段**，F10 实测）；`generate_openapi` components.schemas
   增 form schema（handler.name+method 去重）。**模块抽取**：
   `_json_str_array/_openapi_default_value/_openapi_field_schema/
   _openapi_object_schema/_json_list_array`（~120 行，决策-38）移入新
   `openapi_schemas.mojo`（同语义纯搬运，使 openapi.mojo 494 → ~400 回落
   阈值内）。
   **附带 P0 修复 (P7)**：query 参数 schema 括号配对自决策-38 起错
   （标量分支不关 schema 对象 + `_generate_parameter` 过早关参数对象且
   parameter 级 description 落到对象外）-> /openapi.json 一直是非法
   JSON (Swagger UI 无法渲染)；本决策修正（schema 对象自关闭 + 参数
   对象统一末尾关闭）+ `fmtool jsoncheck` 整文合法性门禁 (FM-17)。

## 3.5 文档化偏差

1. **detail 字段序** `loc,msg,type,input` vs 上游 `type,loc,msg,input` —
   字段集合/值全等，JSON 对象字段序无语义（OpenAPI/客户端解析不敏感）。
2. **JSON body 缺失 `input`** = 收到的 body JSON 原文（P3 对齐）；但**嵌套
   字段缺失**的 input 上游 = 父对象，本实现 = 同样 body 原文（嵌套层未单独
   追踪父对象 JSON — 顶层语义对齐，嵌套为近似）。
3. **form 标量 bool 消息** = 完整措辞（"Input should be a valid boolean,
   unable to interpret input"）— query 标量 bool 保持决策-38 短消息
   （"Input should be a valid boolean"，QS e2e 守护的存量近似）；list 元素
   bool 两侧均为完整措辞。
4. **OpenAPI schema 命名** `Body_<handler.name>_<method>`（如
   `Body_form_multi_post`）vs 上游 `Body_<fn>_<route>_<method>`（fn =
   Python 函数名，本实现无函数体 — handler.name 为等价锚点）；$ref 名内部
   自洽，无语义影响。
5. **`_form_fields` 未声明 `_form_types` 的字段** = 无类型回显
   （缺失 → ""，不 422）— 决策-28 存量语义保留（/login demo）；上游
   `Form()` 必填会 422 — 本 port 的「未标注 = 未声明校验」约定（同
   _reads_headers/_reads_cookies）。
6. **multipart 路由不出 form requestBody**（`_multipart` 与 `_form_types`
   互斥声明；multipart OpenAPI = 后续独立决策 — 矩阵 #6 UploadFile 对象
   API 一并处理）。
7. **CSV 内部表示的逗号歧义**（list 值含 ',' 与多值 CSV 不可区分）=
   决策-43/ADR-0018 同款既定取舍，form 继承（URL-encoded 值可
   percent-encode ',' 规避歧义 — 解码后歧义仅存在于 handler CSV 视图）。

## 4. 风险

| 风险 | 评估 / 缓解 |
|------|------------|
| collect-all 改变 query 存量行为（ADR-0018 曾 stop-on-first） | 上游 0.141.1 实测就是 collect-all（P1）— 本修正是**去偏差**而非新偏差；QS e2e 断言同步更新（新增 2 坏元素双错误守护）；e2e 79→ 全量回归 |
| "field required" → "Field required" 影响既有 e2e | 仅 2 处断言（BS-2c / QS-11），同步更新；OT-12（决策-44）本就是 F 大写 |
| `input` 字段加入改变 422 响应体（含既有 e2e 的 contains 锚点） | 全量 e2e 回归 + 新增 `input` 存在性断言；detail 是 JSON 数组，`input` 追加在 type 之后，`loc/msg` 前缀 contains 不受影响 |
| http_server_final 继续膨胀（1187 -> 1210） | 既有超阈值文件；本 ADR 接线 = 校验段 ~8 行 + 注入段 ~8 行 + demo 路由 ~17 行（声明式数据，非新逻辑）+ 移除 inject_form_fields -15 行，净 +23（同 ADR-0018/0019 立场：声明式接线） |
| form 校验对非 form CT 请求误 422 | multi 仅 CT=form 时非空；声明 `_form_types` 的路由收 JSON/空 body → 字段缺失 → 默认/422 = **上游同款**（`request.form()` 空）；未声明 `_form_types` 的存量路由行为完全不变（`_form_fields` 旧语义） |
| openapi_schemas 抽取引入回归 | 纯搬运（函数体零改动，只移位置 + import）；OpenAPI e2e（F4/BS-12/QS-13 系列）全量回归守护 |
| params_typed 496 → 超 500 阈值 | `_pe` 签名 + input 参数为同行改动（行数不变）；如超限以注释微调回落（逻辑零增） |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`form_params -> {request_response, params_typed, params_query_extra, json, handler}`；`openapi -> openapi_schemas`（新）+ `form_params`；`http_server_final -> form_params`（无反向）；`request_response` 仅加纯函数（依赖集不变）；依赖图零环 |
| 2. 分层向下依赖 | ✅ 遵守 | form 解析/校验/归一化/OpenAPI = 纯 Mojo 应用/协议层；FFI **零改动**（决策-44 已把 form 解析归纯 Mojo 层）；Rust 零新 crate |
| 3. God package 阈值 | ⚠️ 遵守（带说明） | form_params **493**（新，<500）/ openapi_schemas **140**（新，<500）/ openapi **390**（494 -> 390 抽取回落，<500）/ request_response **299**（258->299，<500）/ params_query_extra **366**（364->366，<500）/ params_typed **499**（496->499，≤500）/ body_validate **337**（313->337，<500）/ **http_server_final 1210**（1187->1210，既有超阈值 — +23 声明式接线，同 ADR-0018/0019 立场） |
| 4. 主题域边界清晰 | ✅ 遵守 | form_params 只管 form（body 侧）参数（query/path 不碰 — 那些归 params_typed/params_query_extra）；openapi_schemas 只管 body schema 构造（form schema 在 form_params — 各管各的声明源）；422 error-object 构造器原位扩展（各模块自己的构造器加 input，不集中化 — 避免新中枢依赖） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新 `extern "C"`；form 纯 Mojo 解析 = 决策-44 分层延续）；零新 crate；ldd 实测仅 libc；binary 预算 ≤4.2M（本 ADR 纯 Mojo 增量 <50 KB） |
| 6. 测试文件跟随 | ✅ 遵守 | form_params 尾部 `mojo run` 纯逻辑自检（~25 check：multi-map/validate/apply/schema，JIT 可达）；e2e 新增 **FM-1..FM-20**（20 项：3-occ/wrap/missing+input null/默认×3/collect-all×3/alias×3/兼容×2/URL 编码/jsoncheck 整文/requestBody×2/query collect-all 守护）；既有 QS/BS 断言同步 parity 更新（F 大写 ×2 + collect-all）；fmtool 新增 `jsoncheck` 子命令（纯 std，整文 JSON 校验） |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc（实测）；binary **3,400,400 B (3.24M)** ≤4.2M（决策-44 基线 3,326,672 B + 增量 ~74 KB）；`env -i` 干净启动（health 200 + /form-multi 200 + /form-alias 200，实测）。
   （决策-44 3,326,672 B 基线 + 本 ADR 增量）；`env -i` 干净启动
   （health 200 + /form-multi 200 + /form-alias 200）。
2. **Rust 质量门禁**：cargo test/clippy 双 crate 不变（FFI 零改动）—
   349/0/4 + 0 警告 保持。
3. **e2e 全量**：274 -> **294**（+20 FM）全绿（实测 0 FAIL）；覆盖 F1-F10
   全语义 + P1-P5 parity（pyjwt 无关 — 本 ADR 纯 form/422）：
   - FM-1..2 多值 list（3-occ CSV / 1-occ wrap）
   - FM-3 missing 422（F 大写 + input null，整对象断言）
   - FM-4..7 默认（count=0 标量 / fx 空 list / fb 空 list / 显式 float）
   - FM-8..10 collect-all（int 2 坏元素双错误 / float input / bool input）
   - FM-11..13 alias（wire key 绑定 / 原始名 -> 默认 / 标量默认）
   - FM-14..15 兼容（/login last-wins + 缺失 -> ""，决策-28 存量语义）
   - FM-16 URL 编码多值
   - FM-17 **openapi.json 整文合法性**（`fmtool jsoncheck` — P7 门禁）
   - FM-18 /form-multi requestBody（required:true + urlencoded $ref）
   - FM-19 /login requestBody 无 required（Body_form_demo_post）
   - FM-20 **query collect-all 守护**（2 坏元素 -> 2 错误 — P1 更正）
4. **Mojo 自检**：`mojo run` 集新增 **form_params**（纯逻辑 ~25 check）；
   既有 8 个 self-test 全绿保持（security.mojo 等零改动）。
5. **性能**：bench 6 场景 0 errors，get_root_10k_100c 历史区间
   （32.9k–43.9k）内（form 路由不在 bench 热路径）。
