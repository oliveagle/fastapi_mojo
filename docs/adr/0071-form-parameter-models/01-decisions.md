# ADR-0071: form 参数模型组（Decision-106）

**状态**：已接受
**日期**：2026-11-10
**决策**：106（FastAPI 上游 0.158.0 / 0.158.1 / 0.158.2 —
组合 form 模型 PR #16577、OpenAPI form media types 保留 PR #16579、
可选 form 模型 PR #16582）
**关联**：AGENTS.md §6（**已决策-106**）、docs/upstream-tracking.md A 主题
（0.158.0 / 0.158.1 / 0.158.2 三行）、ADR-0070（query/header/cookie 参数模型组；
本 ADR 把同一组语义落到 **form 面**）、ADR-0069（AliasChoices 候选语义）、
North Star（**FFI diff = 0**；纯 Mojo）

## 1. 背景

FastAPI 0.158.0 起允许把 **Pydantic 模型**声明为 `Form()` 参数 —— 模型的字段
逐个成为 form body 字段；同一路由可声明**多个** form 模型（组合），也可以把模型
声明为 `Optional[...]`（可选 form 模型）：

```python
class Filters(BaseModel):
    model_config = ConfigDict(extra="allow")
    term: str
    page: int = 2

class Pagination(BaseModel):
    model_config = ConfigDict(extra="allow")
    limit: int = 10

@app.post("/items")
def create(filters: Annotated[Filters, Form()],
           pagination: Annotated[Pagination, Form()]): ...
# body: term=hello&limit=2
#   -> filters.term=hello, filters.page=2 (默认), pagination.limit=2
#   -> filters 收到 extra {"limit": "2"}; pagination 收到 extra {"term": "hello"}
```

- **0.158.0（组合 form 模型）**：同一 body 可声明多个 form 模型，各自独立校验；
- **0.158.1（OpenAPI form media types）**：form 模型路由的 `requestBody.content`
  必须保留 form media type（不得回落到 JSON）；
- **0.158.2（可选 form 模型）**：`Optional[Model]` —— body 里该模型字段**一个都
  不出现**且无 extra 收集值时为 `None`（不报 missing、不注入字段默认值）。

fastapi_mojo 此前只有**扁平 form 声明**（`_form_fields` / `_form_types`），
没有"模型组"概念，三条全部缺失（upstream-tracking 记为 ❌/❌/🔶）。

## 2. 上游语义（已从 fastapi 0.162.2 `fastapi/dependencies/utils.py` 逐行核实）

| 维度 | 上游行为 |
|------|---------|
| `_get_form_models` | `Form` + `not embed` + 非 JSON → 单模型 `[model]` 或 union 的模型列表（union 见 0.161.x，未在本 ADR 范围） |
| `_extract_form_items` | ① 逐字段按候选序取值，**首个有值**的候选 `yield` 后 break（其余候选不产出）；② 再 `yield` **所有不在 `field_aliases` 里的 body 键**（`field=None` = extra 域） |
| `field_aliases` | 每个字段的**全部候选别名**（`for alias, _ in _get_param_aliases(field)`，无论是否有值）→ 空标量既不成为字段值、也不落入 extra（`_get_multidict_value` 空串视为 Undefined） |
| `_is_form_model_supplied` | `own_names ∩ received_body` **或**（`extra in (allow, forbid)` 且 body 非空） |
| `_extract_form_model` | `Optional[Model]` 且无模型被提交 → `Undefined`（不校验 / 不注入默认 / 不报 missing）；**非可选模型恒校验**（空 body → 逐字段 missing 422） |
| extra 域 | **同一 body 里不属于该模型任何字段/别名的键**（含**兄弟模型的字段**） |
| `forbid` | pydantic `extra_forbidden`：每键一条，msg = "Extra inputs are not permitted"，loc = `["body", 键]`，input = 原值（多值 → 数组） |
| OpenAPI | 组字段**摊平**进 `components/schemas/Body_<name>_<method>` 的 `properties`；`requestBody.required` 反映「字段无默认且组非 optional」；media type 保留 form 类型 |
| bool 缺省 | 0.162.0 起**不再**把省略的 boolean form 字段推断为 `False`（默认值 / missing 错误），本实现同 0.162.0 终态 |

**与决策-105（query/header/cookie）的差异（上游本意，非偏差）**：form 面的
`field_aliases` 收集**全部候选别名**，而 query/header/cookie 面的 `processed_keys`
只收**选中别名**（`next(pair for pair in aliases if pair[1] in received_params)`）。
因此 form 面「空标量」既不成为字段值也不进 extra 域（直接丢弃），query/header/cookie
面则可能把未选中的候选键当 extra（取决于 extra 策略）。

## 3. 目标

以**声明式语法**（与 `_param_models` 完全同构，不引入模型/类概念）表达 form 面的
组合 / 可选 / extra 三件事；form 字段类型/枚举/约束/默认复用既有
`validate_form_collect`；**FFI diff = 0**（纯 Mojo）。

## 4. 决策

1. **新增两个声明面**（form 面组）：

   | 声明键 | 语法 | 示例 |
   |--------|------|------|
   | `_form_models` | `;` 分隔组、`\|` 分隔字段、字段 = `名字:类型规格` | `filters=term:str\|page:int=2;page2=limit:int=10` |
   | `_form_model_opts` | 组属性：`extra=ignore\|allow\|forbid`、`optional` | `filters=extra=allow;page2=optional` |

   - 类型规格语法与 `_form_types` **完全一致**（默认值 `=2` / 枚举 `[a,b]` / list `[]`）；
   - 组字段的别名/描述/约束复用该路由既有共享表（`_form_aliases` / `_param_descs`，
     别名语义 = 决策-104 多候选）；
   - 注入键：`form_<组>_<字段>`；`extra=allow` 的额外键 `form_<组>_x_<键>`（多值 CSV）。

2. **新增 `form_models.mojo`（251 LOC）** 承载组语义：
   `get_form_models` / `form_group_active` / `validate_form_model_groups` /
   `apply_form_model_extras` + 内部 `_form_processed_keys` / `_form_extra_keys` /
   `_form_field_present` / `_group_inject` / `_canon_form_value` / `_canon_form_csv` /
   `_form_extra_input_json`。

3. **dispatch 接线**（`http_server_final.mojo`）：
   - 校验阶段：`validate_form_model_groups(fmodels, fal, fmulti)`，错误并入
     `all_errs`（与个体 form / file 错误同批 422，collect-all）；
   - 成功路径：`apply_form_model_extras(req_params, fmodels, fal, fmulti)` 注入；
   - `fmulti` 复用既有解析（urlencoded `parse_form_multi` / multipart 文本 part
     过滤），**不新增 FFI**。

4. **OpenAPI 接线**（`form_params.mojo`）：
   - `form_has_declaration` 计入 `_form_models` → 有 form 模型的路由产出
     `requestBody.content["application/x-www-form-urlencoded"]`（0.158.1 语义）；
   - 组字段追加进 `form_field_names_ordered`，schema 复用
     `_openapi_form_field_schema`（类型 / 标题 / 默认值）；
   - `form_request_body_required` 计入非 optional 组里无默认的字段。

5. **组件顺序与错误语义**：组校验与个体字段校验**各自独立**（同 location 可混用），
   错误按「个体 form → 组 → 文件」顺序追加（collect-all 语义，最终按
   `all_errs` 原序输出）。

## 5. 已知偏差

| # | 偏差 | 原因 / 影响 |
|---|------|-------------|
| 1 | **无模型 union**（`Union[ModelA, ModelB]`，上游 0.161.0 / 0.161.1） | 家法无类型系统；union 需"同组多候选 schema + 判别"设计，另立决策（upstream-tracking A 主题仍记 ❌） |
| 2 | **无嵌套模型** | 组字段只有标量/list 类型规格（与 `_form_types` 同边界） |
| 3 | **File 字段不参与组** | 上游 `File` 字段独立成 file 参数；本实现 `fmulti` 已剔除被 file 声明占用的键（决策-102 语义），组只吃文本 form 字段 |
| 4 | **无 per-field `Form(media_type=...)`** | 家法无字段级 media type；路由级 media type = multipart（有 file 声明）/ urlencoded（否则），与 0.158.1 的"保留 form media type"结果一致 |
| 5 | **properties 不输出 `required` 数组** | 与项目既有 form/body schema 一致：required 只在 `requestBody.required` 表达（记录为存量 OpenAPI 偏差，非本决策新增） |
| 6 | **模型级 validator / 默认工厂** | 上游模型可带 pydantic validator；家法无模型概念，字段级约束走既有 `_form_types` 语法 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 |
|------|------|
| 1. 无循环依赖 | ✅ `form_models` 是单向叶子：依赖 `param_models`（组解析）/ `form_params`（字段校验）/ `alias_choices` / `params_*`；`form_params` 只依赖 `param_models`，无回边 |
| 2. 分层向下依赖 | ✅ 纯 Mojo 纯函数（无 FFI / 无 fd / 无 env）；dispatch 只做「读值 → 调校验 → 注入」；**FFI diff = 0**，`bridge/ffi.rs` 导出数保持 87 |
| 3. God package 阈值 | ✅ 新模块 251 LOC < 500；`form_params.mojo` 586→639、`http_server_final.mojo` 2654→2665（**均在存量超限名单内**，拆分待办继续跟踪） |
| 4. 主题域边界清晰 | ✅ 组语义（解析 / 缺席判定 / 未处理键 / 注入键 / loc）全部收敛在 `form_models.mojo`；`form_params` 只补 OpenAPI 与 required 判定；校验复用 `validate_form_collect` 而非复制 |
| 5. bridge/adapter 显式化 | ✅ **无新增 bridge 符号**；form body 解析复用既有 `parse_form_multi` / `snapshot_mp_parts` |
| 6. 测试文件跟随 | ✅ demo 路由同文件（`http_server_final.mojo`：`/pm/form-allow` / `/pm/form-optional` / `/pm/form-forbid`）；e2e `PMF-1..PMF-14` 与生产代码同仓库 |

## 7. 验收（2026-11-10 实测）

- `./build_single.sh`：`mojo build --emit object` 通过；binary **5.4M**（≤6M 预算）
- e2e：**950/950 全绿**（936 基线 + PMF-1..14）
- `cargo test --release -- --test-threads=1`（TMPDIR=/tmp）：531 passed / 1 failed
  （`escaping_in_output`：本机 `/bin/sh=bash` 环境依赖，pristine HEAD 既有）/ 4 ignored
- `cargo clippy --release --tests -- -D warnings`（双 crate）：0 警告
- `ldd build/fastapi_mojo`：仅 libc.so.6 + libm.so.6
- `env -i` 干净启动：health 200
- `find src -name '*.c'` = 0；`*.py` = 0

## 8. 上游对照（release 说明 + 源码核实）

| 版本 | 上游改动 | 本实现 |
|------|---------|--------|
| 0.158.0 | ✨ Add support for combining form models（PR #16577） | ✅ `_form_models` 多组 + 组级 extra / 注入（PMF-1/2/6/7/11） |
| 0.158.1 | 🐛 Preserve form media types in OpenAPI（PR #16579） | ✅ form 模型路由 requestBody 保留 urlencoded media type（PMF-13）；per-field media_type 无对应面（§5-4） |
| 0.158.2 | ✨ Add support for optional form models（PR #16582） | ✅ `optional` 组缺席不校验/不注入/不报 missing（PMF-3/4/5） |
