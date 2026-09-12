# ADR-0064: response_model `exclude_unset` / `exclude_defaults` / `by_alias`（决策-89）

**状态**：已接受
**日期**：2026-09-13
**决策**：89（兑现 ADR-0062 §8 #3 + ADR-0063 §8 #2；Goal-0003 §1 矩阵 #11
response_model 剩余面）
**关联**：AGENTS.md §3.2/§6（**决策-89**）、ADR-0016（决策-41：response_model
include/exclude/exclude_none，本 ADR 的直系前身）、ADR-0062（决策-87：`fmt_f64_repr`
复用，float 默认值规范化）、ADR-0063（决策-88：body 422 `input`；本 ADR 未改动）、
决策-38（`_body_schema` spec）/ 决策-85（ADR-0060：body CT 分派）、North Star
（**FFI diff = 0**；zero new crate；zero Rust / zero C；纯 Mojo）、上游
`fastapi 0.141.1` / `pydantic 2.13.4`

## 1. 背景（缺口）

决策-41（ADR-0016）落地 response_model 的 include / exclude / exclude_none。
FastAPI 完整 API 面还包括三个序列化参数：

- `response_model_exclude_unset=True` —— 剔除**请求未显式设置**的字段；
- `response_model_exclude_defaults=True` —— 剔除**值等于声明默认值**的字段；
- `response_model_by_alias`（默认 `True`）—— 输出键用 alias 还是字段名。

ADR-0062 §8 #3 / ADR-0063 §8 #2 均把这条列为后续缺口。

### 上游探针（live，fastapi 0.141.1，`/tmp/rmapp.py`）

模型 `Item(name:str, price:float=10.0, tax:float=0.0)`，handler `return item`：

| 请求 | `/rn` plain | `/ru` exclude_unset | `/rd` exclude_defaults |
|---|---|---|---|
| `{"name":"a"}` | `{"name":"a","price":10.0,"tax":0.0}` | `{"name":"a"}` | `{"name":"a"}` |
| `{"name":"a","price":5}` | `{"name":"a","price":5.0,"tax":0.0}` | `{"name":"a","price":5.0}` | `{"name":"a","price":5.0}` |
| `{"name":"a","price":10.0,"tax":0.0}` | 三者全出 | 三者全出 | `{"name":"a"}` |

alias 探针（`Aliased(full_name: str = Field(alias="fullName"), age:int=0)`,
`populate_by_name=True`）：

| 请求 | `/ba` by_alias=True | `/bn` by_alias=False |
|---|---|---|
| `{"full_name":"y"}` | `{"fullName":"y","age":0}` | `{"full_name":"y","age":0}` |
| `{"fullName":"x"}` | `{"fullName":"x","age":0}` | `{"full_name":"x","age":0}` |

推导语义：

1. plain `response_model` **注入声明默认值**（本实现此前只返回 resp_data 里已有的
   字段 —— 缺口）；
2. `exclude_unset` 依据**请求是否显式提供**（显式提供且等于默认值的字段仍保留）；
3. `exclude_defaults` 依据**值是否等于声明默认**（未提供 → 注入默认 → 剔除；
   显式等于默认 → 也剔除）；
4. `by_alias` 决定输出键命名（默认 alias）。

## 2. 目标

用声明式（`handler.data`）补全上述四参数，wire 行为逐条对齐上游探针；
既有 response_model 路线（`/profile*`、`/rm-noop`）零回归；无 `_response_model`
时仍整体 no-op（FastAPI 对齐）。

## 3. 实现（纯 Mojo；**FFI diff = 0**；核心 `run_handler` / router / bridge 零改动）

1. **模型元数据同源 `_body_schema`**：响应模型字段的**类型 + 默认值**直接取自
   `_body_schema`（`parse_body_schema` / `get_field`），不再引入第二套 spec 语言。
   无 `_body_schema` 时无声明元数据（渲染回退 = JSON 字符串，既有行为）。
2. **`response_model_body(handler, resp_data, provided_csv="")`**（`request_response.mojo`，
   单一 dispatch 调用点）：
   - 新声明键：`_response_exclude_unset` / `_response_exclude_defaults` /
     `_response_aliases="name=alias;..."` / `_response_by_alias="false"`（默认 true）；
   - 值解析：优先 `body_<f>`（body 校验注入的**规范值**，含默认注入），再 `<f>`；
   - `present`（请求是否提供）= `f ∈ provided_csv` 或 `f ∈ resp_data`（静态路由回退）；
   - 过滤序：include（`_response_model`）→ exclude → unset/defaults → exclude_none；
   - `exclude_defaults` 比较经 `canonical_default_value`（决策-87 `fmt_f64_repr`）
     规范化，故 `"10"` 与默认 `"10.0"` 等价；
   - 渲染 `_rm_render`：`int`/`float`/`bool`/数组/`obj` → **raw JSON**
     （`__nested__:` 直通 —— float 字段输出 JSON number 而非字符串，对齐 pydantic）；
     `str`/其它 pydantic 标量/未知类型 → JSON 字符串。
3. **`validate_body_schema` 返回值 3 元组 → 4 元组**：新增第 4 元素 `set_csv`
   （**显式提供的顶层字段名**，以 `_body_schema` 字段序拼接；成功与 422 路径均
   回传；embed 路径取内层 `inner.values` 同名集；非 body 路径为空串）。dispatch
   声明 `body_set_csv` 并透传给 `response_model_body` 作为 `provided_csv`。
4. **demo 路由**（`body_schema_routes.mojo`）：`/rm/plain`（默认注入）/
   `/rm/unset` / `/rm/defaults` / `/rm/alias` / `/rm/noalias`。

## 4. 测试

- **Mojo 自测**（`body_validate_test.mojo`，+7 断言）：`set_csv` = 仅提供字段
  （默认不入选）/ 保字段序 / 422 路径仍回传；`canonical_default_value` 的
  float/int/str / 数组直通。
- **e2e**（`RMP-1..3` / `RMU-1..5` / `RMD-1..4` / `RMB-1..3` = 15 例），逐条比对
  上游 `/rn`·`/ru`·`/rd`·`/ba`·`/bn`：默认注入、exclude_unset 剔未提供但保留显式
  默认、exclude_defaults 剔等于默认、by_alias 真/假输出键、float 输出 JSON number。
- **回归**：`RM-1..7`（既有 response_model + no-op）全绿。

## 5. 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| 必填字段缺失 | `ResponseValidationError` → 500 | 跳过该字段（不报错） | demo 不触发；另立 |
| `Field(alias=)` 自动映射 | 模型声明即得 alias | 声明式 `_response_aliases` 表 | 等价形态（house 一贯声明式风格） |
| `exclude_defaults` 与**校验器改值** | 比较的是校验后的值 | 比较规范化后文本 | 无 validator（Mojo 无闭包，硬边界，ADR-0014） |
| 422 对象键序 / 错误体超集 | `type,loc,msg,input,ctx` | house 键序 + 附加字段 | 既有约定（ADR-0029 §3.7 / ADR-0058 §5） |
| 响应模型 ≠ body 模型 | 独立声明 | 需 `_body_schema` 提供类型/默认 | 常见 `return item` idiom 覆盖 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `request_response -> body_schema`（叶，仅 spec 解析）；`body_schema` 不反向依赖；无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 过滤/渲染 = 纯 Mojo 字典/字符串变换（零 FFI / 零 fd / 零 env）；`provided_csv` 为**值参数**（校验结果），不引入回调上溯 |
| 3. God package 阈值 | ✅ 遵守 | `request_response.mojo` 307→**389** < 500；`body_validate.mojo` 464 < 500；`body_schema.mojo` 361 < 500；`body_schema_routes.mojo` 62→**96** < 500 |
| 4. 主题域边界清晰 | ✅ 遵守 | response_model 参数全收敛在 `request_response.response_model_body` 单 helper（新增私有 `_rm_render` / `_rm_canon` / `_parse_alias_table`）；模型元数据仍唯一源 `_body_schema` |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出 / 零新 crate / 零 Rust / 零 C） |
| 6. 测试文件跟随 | ✅ 遵守 | Mojo 自测与生产同目录（`body_validate_test.mojo`）；e2e `RMP/RMU/RMD/RMB`；无新增独立 crate |

## 7. 验收（2026-09-13）

- 上游探针复核（`/rn`·`/ru`·`/rd`·`/ba`·`/bn`）与本实现 `/rm/*` 逐条一致
  （仅空白格式差异，house 既有约定）。
- e2e **844 → 859/859 全绿**（新增 15 例）。
- 13 个 Mojo 自测全绿（含 `body_validate_test` +7 断言）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed /
  4 ignored**（本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings`
  = **0**。
- `./benchmark.sh` 6 场景 0 errors；`ldd build/fastapi_mojo` 仅 libc；
  `env -i` 干净启动（`/health` 200）；binary **5,265,856 B**（≤ 6 MiB）；
  `find src -name '*.c'` = 0；`*.py`（除 docs/.git）= 0；
  `pgrep -x fastapi_mojo` = 0。

## 8. 后续缺口（本决策未覆盖，另立 ADR）

1. 非有限 `inf`/`nan` float JSON 渲染语义（上游 500）。
2. `response_model` 必填字段缺失 → 上游 `ResponseValidationError` 500。
3. 响应模型独立于 `_body_schema` 的完整 schema（当前类型/默认同源 body）。
4. `SecurityScopes` 对象面 / `OAuth2PasswordRequestForm` 对象面。
5. `fastapi.encoders.jsonable_encoder` 等未验证小公开面。
6. OpenAPI 3.1 vs 3.0.3；multi-arch（aarch64）/ asgi-shim（P2 open beads）。
