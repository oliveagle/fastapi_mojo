# ADR-0061: `Body(embed=True)` 请求体嵌入语义（决策-86）

**状态**：已接受
**日期**：2026-09-12
**决策**：86（兑现 ADR-0060 §8 后续缺口 / Goal-0003 §1 矩阵 #4「请求体」剩余面；
bead `fastapi_mojo-280`）
**关联**：AGENTS.md §3.2/§6（**决策-86**）、决策-85（ADR-0060：body CT 分派 +
顶层值语义 + `body_json.mojo`）、决策-38（ADR-0020/0036：声明式 `_body_schema`）、
North Star（纯 Mojo 逻辑；**FFI diff = 0**；zero new crate；zero Rust/C 改动）、
上游 `fastapi 0.141.1`（`fastapi/dependencies/utils.py` `_get_body_field` /
`request_body_to_args`、`fastapi/routing.py`）、`pydantic 2.13.4`

## 1. 背景（缺口）

上游 FastAPI 的 `Body(embed=True)` 把**单一** body 参数包成一个合成单字段模型
`{<param>: Model}`：运行时 `request_body_to_args` 走
`received_body.get(field.alias)` 取值。本实现此前**完全没有** embed 支持
（`grep embed src/fastapi_mojo/*.mojo` = 0），声明式 `_body_schema` 只表达
「body 顶层对象」一种形态。

上游实测（probe app：`def embed(item: Item = Body(embed=True))`，`Item{name:str,
price:float}`）：

| 输入 | 上游响应 |
|---|---|
| `{"item":{"name":"a","price":1.5}}` | 200 `{"name":"a","price":1.5}` |
| `{"name":"a","price":1.5}`（键缺失） | 422 `missing` `["body","item"]` input `null` |
| `{"item":null}` / `{}` | 422 `missing` `["body","item"]` input `null` |
| 无 body / 空 body | 422 `missing` `["body","item"]` input `null` |
| 非 JSON CT（`text/plain`…）+ 合法 JSON body | 422 `missing` `["body","item"]`（原始串无 `.get`） |
| 顶层 `5` / `[1]` / `null` | 422 `missing` `["body","item"]`（**非** `model_attributes_type`） |
| `{"item":"str"}` / `{"item":7}` / `{"item":true}` / `{"item":[1]}` | 422 `model_attributes_type` `["body","item"]` input = 内层值 |
| `{"item":{}}`（内层缺字段） | 422 `missing` `["body","item","name"]` / `["body","item","price"]` input `{}` |
| `{"item":{"name":"a"}}` | 422 `missing` `["body","item","price"]` input `{"name":"a"}` |
| `{"item":{"name":"a","price":1.5},"x":9}` | 200（额外键忽略） |
| `{bad` | 422 `json_invalid` `["body",1]` + `ctx.error` |

关键差异：**顶层非 object 时 embed 报 `missing`（原始值无 `.get`），而非嵌入的
单模型报 `model_attributes_type`**。OpenAPI：`requestBody.$ref =
#/components/schemas/Body_<func>_<param>_<method>`（上游 `model_name = "Body_" +
route.unique_id`），该合成 schema = `{properties:{<param>:$ref <Model>},
type:"object", required:[<param>], title:...}`。

## 2. 目标

`Body(embed=True)` 请求体嵌入语义对齐上游：顶层分派 + 内层模型校验 + 422
`loc`/`type`/`input` + OpenAPI 包裹 schema。非嵌入路径（既有 `_body_schema`）
行为**零改变**。ASCII / 多字节字节安全语义不变。

## 3. 实现（纯 Mojo；核心 `run_handler` / router / FFI 零改动）

1. **声明式键 `_body_embed = "<param>"`**（handler.data；缺省 = 非嵌入）。
   demo 路由 `/validate/embed`（POST，`_body_schema = "name:str;price:float"`，
   `_body_embed = "item"`，`body_schema_routes.mojo`）。
2. **`body_validate.mojo` 新 `_validate_body_embed(...)`**（`validate_body_schema`
   在方法检查后、非嵌入分派前单点分支）：
   - 无 body（`body_str` 空且 `body_params` 平凡）/ 非 JSON CT /
     `validate_body_json` 成功但 `top_kind != "object"` → `missing
     ["body", <param>]` input `null`；
   - 非法 JSON → `json_invalid ["body", pos]` + `ctx.error` + input `{}`
     （复用 `body_json.mojo`，与未嵌入同）；
   - 键缺失 / 值为 `null` → `missing ["body", <param>]`；
   - 键值非 object（str/number/bool/array）→ `model_attributes_type
     ["body", <param>]`（input = 内层原值，`_json_input_frag_typed`）；
   - 键值为 object → `parse_body_json` 后 `_validate_fields(..., loc =
     ["body","<param>", ...], raw_body = 内层对象)`（嵌套 missing input =
     内层对象；注入键仍 `body_<field>`，本层 prefix 空）。
3. **`openapi.mojo`**：`_body_embed` 路由 `requestBody.$ref` → house 命名包裹模型
   `Body_<h.name>_<method>`（对齐 form body 既有 `Body_<name>_<method>` 约定，
   ADR-0020 §3.5-4）；components/schemas 追加包裹 schema
   `{"properties":{<param>:{"$ref":<h.name>}},"type":"object","required":[<param>],
   "title":"Body_<name>_<method>"}`（去重；内层 `<h.name>` schema 照旧生成）。

## 4. 测试

- **Mojo 自测** `body_validate_test.mojo` +14 断言：valid / 键缺失 / nil / 空对象 /
  顶层非 object（数字·数组·null）/ 非 dict 值（串·数·数组·bool）/ 内层嵌套 missing
  loc·input / 非法 JSON pos / 非 JSON CT / 无 body。
- **e2e** `EB-1..EB-18`：valid 200 + `body_<field>`；键缺失/nil/空对象/顶层
  数字·数组·null → `missing ["body","item"]`；非 dict 值（串·数·数组·bool）→
  `model_attributes_type`；内层空对象嵌套 missing locs；内层缺字段 loc/input；
  非法 JSON pos；非 JSON CT → missing；extra keys 200；OpenAPI wrapper `$ref`
  + 包裹 schema 断言。

## 5. 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| 422 对象键序 | `type,loc,msg,input,ctx` | house `loc,msg,type,input,ctx`（`ctx` 末位） | 既有约定（ADR-0029 §3.7） |
| 错误体附加字段 | `{"detail":[...]}` | `detail` 外带 `status/method/path/handler/request_id/duration_ms`（超集） | 既有约定 |
| OpenAPI 包裹 schema 名 | `Body_<func>_<param>_<method>`（route.unique_id） | house `Body_<name>_<method>`（handler.name） | 对齐 form body 既有命名约定 |
| 多 body 参数自动 embed | 2+ body 参数恒 embed（`_should_embed_body_fields`） | 单 `_body_schema` 声明 + 显式 `_body_embed` | 声明式模型承载单模型；多 body 参数 = 文档化边界 |
| embed 参数别名 / 默认 | `Body(alias=..., default=...)` | `_body_embed` = wire 键名 | 常见 `embed=True` 用法覆盖 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `body_validate`（校验层）内部新增 helper，复用既有叶模块 `body_json`/`body_schema`/`body_coerce`；无新跨层边、无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串/字节变换（无 FFI / 无 fd / 无 env）；接线在 `validate_body_schema` 单点；helper 用 `mut` 参数就地填充值/错误表（无跨层向上调用） |
| 3. God package 阈值 | ✅ 遵守 | `body_validate.mojo` 377→**448** < 500；`body_validate_test.mojo` 288→**346** < 500；`body_schema_routes.mojo` 55→**62** < 500；`openapi.mojo` 556→**577**（既有 grandfathered >500，未新增文件） |
| 4. 主题域边界清晰 | ✅ 遵守 | 「body 嵌入校验」归 body 域（`body_validate`）；OpenAPI 包裹 schema 归 `openapi` 域；transport CT 头读取沿用 dispatch 既有 `_get_header` |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出 / 零新 crate / 零 Rust / 零 C）；全部纯 Mojo |
| 6. 测试文件跟随 | ✅ 遵守 | 自测与生产同目录（`body_validate_test.mojo` +14 断言）；e2e `EB-1..EB-18`；无新 mojo 模块（CI mojo 列表不变） |

## 7. 验收（2026-09-12）

- Mojo 自测全绿（含 `body_validate_test` / `params_typed` + 12 模块）。
- e2e **802 → 820/820 全绿**（新增 `EB-1..EB-18`）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed /
  4 ignored**（本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings`
  = **0**。
- `./benchmark.sh` 6 场景 0 errors（get_root_10k_100c ≈ 32.4k req/s，噪声带内）；
  `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动（`/health` 200）；
  binary **5,220,800 B**（≤ 6 MiB）；`find src -name '*.c'` = 0；
  `*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。

## 8. 后续缺口（本决策未覆盖，另立 ADR）

1. 非有限 `inf`/`nan` float JSON 渲染语义（上游 500）。
2. float 格式化边界（CPython repr 之外）。
3. 顶层非 object `input` 的 CPython 反序列化-重序列化规范化。
4. 多 body 参数自动 embed（2+ body 参数）+ `Body(alias=/default=)`。
5. `SecurityScopes` 对象面 / `OAuth2PasswordRequestForm` 对象面。
6. OpenAPI 3.1 vs 3.0.3（本实现仍 emit `3.0.3`）。
7. multi-arch（aarch64）/ asgi-shim（P2 open beads）。
