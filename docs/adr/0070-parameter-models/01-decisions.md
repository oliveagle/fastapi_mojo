# ADR-0070: 参数模型组（Decision-105）

**状态**：已接受
**日期**：2026-11-10
**决策**：105（FastAPI 上游 0.157.0 / 0.159.0 / 0.160.0 —
组合参数模型 PR #16573、可选参数模型 PR #16584、模型 extra 策略 PR #16594）
**关联**：AGENTS.md §6（**已决策-105**）、docs/upstream-tracking.md A 主题
（0.157.0 / 0.159.0 / 0.160.0 三行）、ADR-0069（AliasChoices，字段级多候选；
本 ADR 的组字段沿用其候选语义）、North Star（**FFI diff = 0**；纯 Mojo）

## 1. 背景

FastAPI 0.157.0 起允许把 **Pydantic 模型**直接声明为 `Query()` / `Header()` /
`Cookie()` 参数 —— 一个模型即一组同名空间参数，字段逐个成为该 location 的参数：

```python
class Filters(BaseModel):
    model_config = ConfigDict(extra="allow")
    term: str
    page: int = 2

class Pagination(BaseModel):
    model_config = ConfigDict(extra="allow")
    limit: int = 10

@app.get("/items")
def read(filters: Annotated[Filters, Query()],
         pagination: Annotated[Pagination, Query()]): ...
# ?term=hello&limit=2 -> filters.term=hello, filters.page=2,
#                        pagination.limit=2, 且 filters 收到 extra {"limit": "2"}
```

- **0.157.0（组合模型）**：同一 location 可声明**多个**参数模型，各自独立校验；
- **0.159.0（可选模型）**：`Optional[Model] = None` —— 请求里该模型的字段**一个都不出现**
  时模型为 `None`（不报 missing、不注入字段默认值）；
- **0.160.0（extra 策略，breaking）**：每个模型的 `extra` 配置作用于该 location 的
  **未处理键** —— 不只是"模型外的前缀冲突"，还包括**兄弟模型的字段**；
  `forbid` 时逐键 422。

fastapi_mojo 此前**没有模型概念**（扁平声明式 `_param_types` / `_reads_headers` /
`_reads_cookies`），所以这三条全部缺失（upstream-tracking 记为 ❌/🔶/❌）。

## 2. 上游语义（已从 `fastapi/dependencies/utils.py` 逐行核实）

`_request_param_model_to_args(model_field, model, received_params)`：

| 维度 | 上游行为 |
|------|---------|
| 逐字段取值 | `aliases = _get_param_aliases(field)`；`alias, request_alias = next((pair for pair in aliases if pair[1] in received_params), aliases[0])` —— 命中**首个在场候选**，都不在场取第一个（= 决策-104 语义） |
| `own_names` | 每个字段的**全部**请求别名（header 面小写） |
| `processed_keys` | 每个字段的**选中别名**（`request_alias`）；header 面额外把**未转换的字段名**（`x_id`）也计入（源码注释 "Do not accept an unconverted field name as an extra header"） |
| 未处理键 | `for key in received_params: if key not in processed_keys` → 交给模型的 extra 策略 |
| 模型缺席 | `if field_info.annotation is not model and not (own_names ∩ received_params or (extra in ("allow","forbid") and params_to_process)): value = Undefined` —— **只有可选模型**才会缺席；**非可选模型恒校验**（`params_to_process = {}` → 逐字段 missing 422，collect-all） |
| `forbid` | pydantic `extra_forbidden`：每键一条，`msg` = "Extra inputs are not permitted"，`loc` = `(location, 键)`，`input` = 原值 |
| header `convert_underscores` | 模型级默认 `True`：字段 `x_id` → header `x-id`；`AliasChoices` 候选是**字面名**，不做转换 |
| header 错误 loc | `loc_by_alias` 默认 True：报告 **HTTP header 名**（决策-103 已在个体参数面实现） |
| OpenAPI | 模型字段**摊平**进该 location 的 `parameters`；可选模型的字段 `required=false` |

## 3. 目标

以**声明式语法**（延续 `_param_types` 家族，不引入模型/类概念）表达上述三件事，
query / header / cookie 三面语义与上游逐条对齐；**FFI diff = 0**（纯 Mojo）；
畸形声明注册期 fail-fast。

## 4. 决策

1. **新增两个声明面（组）**，沿用既有键值 CSV 风格：

   | 声明键 | 语法 | 示例 |
   |--------|------|------|
   | `_param_models` / `_param_model_opts` | query 面组 | `filters=term:str\|page:int=2;pagination=limit:int=10` + `filters=extra=allow;pagination=extra=forbid` |
   | `_header_models` / `_header_model_opts` | header 面组 | `ident=x_id:str\|x_trace:str=tr` + `ident=extra=forbid` |
   | `_cookie_models` / `_cookie_model_opts` | cookie 面组 | `sess=session:str\|theme:str=light` + `sess=extra=allow` |

   - `;` 分隔组、`|` 分隔组内字段、字段 = `名字:类型规格`（规格语法与 `_param_types`
     **完全一致**，含默认值 `=2` / 枚举 `[a,b]` / list `[]`）；
   - 属性 CSV：`extra=ignore|allow|forbid`、`optional`（= 上游 `Optional[Model]`）；
   - **组字段的别名/描述/约束复用该 location 既有共享表**（`_param_aliases` /
     `_param_descs` / `_param_constraints`；header 面 wire 名取 `_reads_headers` 条目，
     cookie 面名 = 字段名原样）。

2. **新增 3 个叶子模块（纯函数，零 FFI / 零 fd / 零 env）**：
   - `param_models.mojo`（358 LOC）—— `ParamModelGroup` + `parse_param_models`
     （畸形即 raise）+ 查询/判定原语：`group_selected_alias`（选中别名，决策-104 语义）/
     `group_field_present`（own_names 判定）/ `group_processed_keys` /
     `group_extra_keys`（未处理键，保持提交序）/ `model_group_active`（缺席判定）/
     `extra_forbidden_json` / `model_group_key` / `model_extra_key`；
   - `header_models.mojo`（115 LOC）—— header / cookie 面运行期：
     `validate_model_groups`（校验 + 注入）+ `apply_model_group_extras`（allow 收集）+
     `group_identity_aliases`（组请求键恒等映射，见 §4.6）；
   - `param_models_check.mojo`（52 LOC）—— 注册期 fail-fast：语法、query 组字段与
     `_param_types` 重名、header 组字段未在 `_reads_headers` 声明 / 与 `_header_types`
     重名。

3. **query 面接线**：`params_typed.mojo::validate_model_params_collect`（组字段逐个
   走既有 `_vpc_one` → 类型/枚举/约束/默认 + 422 loc `["query", 字段]`；forbid 逐键
   `extra_forbidden`）+ `params_query_extra.mojo::apply_model_extras`（成功路径注入组字段
   （list → CSV、int/float/bool 规范化）+ allow 额外键；**缺席可选组整组不注入**）。

4. **header / cookie 面接线**：`header_models.mojo` 复用
   `param_constraints_run.mojo::validate_headers_collect`（故组字段语义与个体 typed
   header **完全一致**），cookie 面传 `loc_kind="cookie"`；dispatch 只把 Cookie 头
   解析一次（等价 `_reads_cookies` 的 `_parse_cookies`）。

5. **注入键（handler 可见）**：`query_<组>_<字段>` / `header_<组>_<字段>` /
   `cookie_<组>_<字段>`；extra=allow 的额外键 `<face>_<组>_x_<键>`。

6. **loc 与请求键的两个空间**（实测踩坑，本 ADR 固化）：`read_headers_present` 的
   `present` 以**声明名**为键（命中 wire 名另存 loc 表），故组存在性 / 未处理键判定
   必须用**恒等映射**（`group_identity_aliases`）；`reads`（声明名 → wire 名）**只**用于
   422 loc 命名。首版误把 `reads` 当别名表，导致 header 面组存在性判定恒为假
   （missing 不报、字段不注入）—— e2e PM-9/PM-10 捕获并修复。

7. **OpenAPI 摊平**：`openapi.mojo` 把三面的组字段追加进对应 location 的
   `parameters`；`required = 字段无默认 且 组非 optional`（可选模型字段 required=false）；
   query 面参数名取候选首个、header 面取 HTTP header 名、cookie 面原样。

## 5. 已知偏差

| 偏差 | 上游行为 | 本实现 |
|------|---------|--------|
| 声明方式 | `BaseModel` 类 + `Annotated[Model, Query()]` | 扁平声明表 `_param_models` / `_header_models` / `_cookie_models`（无模型/类概念，North Star：纯声明式） |
| **header 面 extra 域** | 请求的**全部** header | **该路由 `_reads_headers` 声明且在场**的 header（Rust bridge 无「枚举全部请求 header」导出；不为测试性语义新增 FFI） |
| extra=allow 多值 | 上游 `getlist` → 单值取标量、多值取 list | query 面多值 → CSV（既有 `_apply` 家族约定）；header/cookie 面取首/取末值 |
| 组内嵌套模型 / 嵌套校验器 | 支持嵌套 BaseModel 字段 | 不支持（字段类型 = 既有标量/list 规格） |
| 模型级 `alias_generator` / `populate_by_name` | 支持 | 无模型概念 → 不适用（沿用 `_param_aliases` / `_reads_headers`） |
| 可选模型默认值 | `Optional[Model] = Model(...)` 可给实例默认 | 只支持「缺席」语义（`optional` 属性）；不给实例默认 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 |
|------|------|
| 1. 无循环依赖 | ✅ 三个新模块为单向叶子：`param_models` ← `header_models` / `param_models_check`；`param_models` ← `params_typed` / `params_query_extra` / `openapi`。`header_models` 依赖 `param_constraints_run`（既有），无回边 |
| 2. 分层向下依赖 | ✅ 纯 Mojo 纯函数（无 FFI / 无 fd / 无 env）；dispatch 只做「读值 → 调校验 → 注入」；**FFI diff = 0**，`bridge/ffi.rs` 导出数保持 87 |
| 3. God package 阈值 | ✅ 新模块 358 / 115 / 52 LOC 均 < 500；改动使 `http_server_final.mojo` 2522→2654、`openapi.mojo` 636→704（**均在存量超限名单内**，另立拆分待办） |
| 4. 主题域边界清晰 | ✅ 组语义（解析 / 缺席判定 / 未处理键 / loc）全部收敛在 `param_models.mojo`；各面只做接线；`validate_headers_collect` 复用而非复制 |
| 5. bridge/adapter 显式化 | ✅ **无新增 bridge 符号**；Cookie 头复用既有 `extract_request_header` + `get_header_value_slice` |
| 6. 测试文件跟随 | ✅ demo 路由同文件（`http_server_final.mojo`）；e2e `scripts/e2e_test.sh` PM-1..PM-19 与生产代码同仓库 |

## 7. 验收（2026-11-10 实测）

| 门禁 | 结果 |
|------|------|
| e2e `./scripts/e2e_test.sh` | **936 passed / 0 failed**（917 基线 + PM-1..PM-19） |
| bridge `cargo test --release -- --test-threads=1`（`TMPDIR=/tmp`） | **531 passed / 1 failed / 4 ignored**；唯一失败 `bridge::cmd_tests::escaping_in_output` 为 **pristine HEAD 既有**且**本机环境依赖**（`/bin/sh` = bash，`printf` 转义语义与 dash 不同），CI 不受影响 |
| 双 crate `cargo clippy --release --tests -- -D warnings` | **0 警告**（fastapi_mojo_rs + fmtool） |
| `ldd build/fastapi_mojo` | 仅 `libc.so.6` + `libm.so.6`（vdso / ld-linux 为系统组件） |
| `env -i ./build/fastapi_mojo` | health **200**；无孤儿进程 |
| binary 体积 | **5,586,360 B（5.33 MiB）** ≤ 6M 预算 |
| 红线 | `find src -name '*.c'` = **0**；`*.py` = **0**；无 `.venv` |

**upstream-tracking.md**：A 主题 ✅ 3→6 / 🔶 3→2 / ❌ 6→4；合计 **41 行 = ✅14 / 🔶7 / ❌8 / ➖12**。
**God package**：新增 358 / 115 / 52 LOC 均 < 500；改动使 `http_server_final.mojo` 2522→2654、
`openapi.mojo` 636→704（存量超限名单内，拆分待办延续）。
