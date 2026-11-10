# ADR-0072: form 模型 union（Decision-107）

**状态**：已接受
**日期**：2026-11-10
**决策**：107（FastAPI 上游 0.161.0 — 组合 form 模型 union PR #16596；
0.161.1 — standalone nullable form union OpenAPI schema 修复 PR #16598）
**关联**：AGENTS.md §6（**已决策-107**）、docs/upstream-tracking.md A 主题
（0.161.0 / 0.161.1 两行）、ADR-0071（form 参数模型组 —— 本 ADR 把"多分支
判别"落到 form 面组语义上）、ADR-0070（query/header/cookie 参数模型组）、
ADR-0069（AliasChoices 候选语义）、North Star（**FFI diff = 0**；纯 Mojo）

## 1. 背景

FastAPI 0.161.0 起，`Form()` 参数可以声明为 **Pydantic 模型 union**
（`Union[ModelA, ModelB, ...]`）。同一个 form body 里，由**判别字段**
（discriminator）或 pydantic 的 smart union 决定命中哪个分支：

```python
class Cat(BaseModel):
    kind: Literal["cat"]
    meow: str

class Dog(BaseModel):
    kind: Literal["dog"]
    bark: str

@app.post("/pet")
def create(pet: Annotated[Union[Cat, Dog], Form()]): ...
# body: kind=dog&bark=woof  -> 选中 Dog 分支
```

- **0.161.0（组合 form 模型 union）**：union 的每个分支用**该分支自身的字段集**
  重抽 form 值（该分支字段/别名全收，其余键进该分支的 extra 域），再交
  pydantic union 校验（discriminator / smart / left_to_right 策略）；
- **0.161.1（standalone nullable form union OpenAPI 修复）**：union 单独作为
  body 时，OpenAPI schema 形状修正（`allOf` + `not{anyOf required}` /
  `maxProperties:0` 的 nullable 表达）。

fastapi_mojo 在 决策-106（ADR-0071）落地了 form 面的**模型组**（组合 / 可选 /
extra），但**没有 union 概念** —— 多组之间是"并列"，不是"择一"（upstream-tracking
A 主题记 0.161.0 / 0.161.1 为 ❌）。

## 2. 上游语义（已从 fastapi 0.162.2 `fastapi/dependencies/utils.py` 逐行核实）

| 维度 | 上游行为 |
|------|---------|
| `_get_form_union_models` | `Form` 参数注解为 `Union[ModelA, ModelB, ...]`（**>1** 个模型；跳过 `NoneType` / `Annotated` 解包）→ union；**单模型 nullable 走普通 form 模型**（决策-106 已覆盖） |
| `_extract_form_model` | `type(None) in args` 且**没有任何分支** `_is_form_model_supplied` → `Undefined`（不校验 / 不注入默认 / 不报 missing）；**非可选 union 恒校验**（空 body → 422 missing，loc `["body"]`） |
| `_normalize_form_model` | 每个分支用**该分支字段集**重抽 form 值（字段别名全收 + 其余 body 键作该分支的 extra 域）→ pydantic union 校验 |
| discriminator 缺 tag | `union_tag_not_found`，loc `["body"]`，msg = "Unable to extract tag using discriminator '<field>'" |
| discriminator 空串 / 非法值 | `union_tag_invalid`，loc `["body"]`，ctx 含 `discriminator` / `tag`，msg = "Input tag '<v>' found using '<d>' does not match any of the expected tags: ..." |
| 分支字段错误 | loc = `["body", <tag>, <字段>]`（**含判别 tag**）；分支 extra=forbid 的额外键同形 |
| 无 discriminator | 走 pydantic **smart union**（打分）/ `left_to_right`（首个通过即选），结果依 pydantic 版本 |
| OpenAPI | union 分支 schema 以 `anyOf` 表达；有 discriminator 时附 `discriminator.propertyName`；nullable union 走 0.161.1 的 `allOf` + `not{anyOf required}` / `maxProperties:0` 形状 |

## 3. 目标

在**声明式语法**（沿用 `_form_models` / `_form_model_opts`，不引入类型系统）
下表达 form 面的 union：分支声明顺序 = 分支优先级；判别字段；union 级可选；
分支级 extra 策略；422 错误 loc 带 tag；OpenAPI `anyOf` + `discriminator`。
**FFI diff = 0**（纯 Mojo）。

## 4. 决策

1. **家法 union 语法**（在 ADR-0071 的组属性上扩展 3 个 attr）：

   | 声明键 | 语法 | 示例 |
   |--------|------|------|
   | `_form_models` | 同 ADR-0071：`;` 分隔组、`\|` 分隔字段 | `pet_cat=kind:str[cat]\|meow:str;pet_dog=kind:str[dog]\|bark:str` |
   | `_form_model_opts` | 新增 `union=<名>`（把组绑进 union）、`discriminator=<字段>`、`union_optional` | `pet_cat=union=pet,discriminator=kind,union_optional;pet_dog=union=pet` |

   - **绑定**：多个组用**同一个 `union=<名>`** 绑成同一 union；**声明序 = 分支序**；
   - **策略来源**：union 的 `discriminator` / `union_optional` 取**首个分支**的声明
     （其余分支重复声明视为同一 union 的一致声明）；
   - **分支级**：`extra=ignore|allow|forbid` 仍逐分支独立生效；
   - **注入键**：`form_<union>_<字段>`（**用 union 名，不是组名**）；分支
     `extra=allow` 的额外键 `form_<union>_x_<键>`（多值 CSV）。

2. **模块拆分**（解决 ADR-0071 §3 God package 阈值压力）：

   | 模块 | LOC | 职责 |
   |------|-----|------|
   | `form_model_core.mojo`（**新**） | 445 | 共享叶子：组判定（`form_processed_keys` / `form_extra_keys` / `form_field_present` / `form_group_active`）、注入（`canon_form_value` / `canon_form_csv` / `group_inject` / `group_inject_as`）、union 计划（`union_names` / `plan_form_unions` / `_union_tag_not_found` / `_union_tag_invalid` / `_rebase_loc` / `_union_tags`） |
   | `form_models.mojo` | 142（251→142） | 只保留 `get_form_models` / `validate_form_model_groups` / `apply_form_model_extras`（从 core 导入共享叶子） |
   | `form_params.mojo` | 733 | OpenAPI 面：`form_union_groups` / `_form_branch_schema` / `form_union_schemas` |

3. **校验流程**（`plan_form_unions`，纯函数，返回 `(ok, errs, 选中分支下标, tag)`）：

   - **缺席判定**：union 的"已提交" = 任一分支的字段/别名在场 **或**（分支
     `extra ∈ {allow, forbid}` 且该分支的 extra 键非空）；
   - **未提交**：`union_optional` → 整组跳过（不校验 / 不注入，0.161.1 语义）；
     否则 → 422 `missing`，loc `["body"]`；
   - **有 discriminator**：取判别字段的提交值（首个在场候选的末值）→
     缺失 → `union_tag_not_found`；空串 / 不匹配任何分支枚举 → `union_tag_invalid`；
     命中分支 → 用**该分支字段集**校验，错误 loc 重定位为 `["body", <tag>, ...]`；
     分支 `extra=forbid` 的额外键同样带 tag；
   - **无 discriminator**：按分支序逐个用该分支字段集校验，**首个通过即选中**
     （上游 smart union 的确定性近似，见 §5-1）；全不通过 → 报**首个分支**的错误
     （上游 smart union 会报"最优分支"错误，差异见 §5-1）。

4. **注入**（成功路径，`apply_form_model_extras`）：union 选中分支 →
   `form_<union>_<字段>`；分支 `extra=allow` → `form_<union>_x_<键>`。
   非 union 组仍走 ADR-0071 的 `form_<组>_<字段>`。

5. **OpenAPI**（`form_params.mojo`）：
   - union 分支**不摊平**进 `properties`（与 ADR-0071 的"组字段摊平"不同），
     改由 `form_union_schemas` 产出 `{"anyOf":[分支...][,"discriminator":{...}]}`；
   - 分支 schema **inline**（家法无命名模型 → 无 `$ref`），含 `properties` +
     `required`（分支字段无默认者）；
   - 与个体 form 字段并存时 → `{"title":..,"allOf":[<union schema>, <扁平 schema>]}`；
   - `requestBody.required`：union 的 `union_optional` 决定（可选 union → 无
     `required` 键）；分支字段**不**参与 required 摊平判定。

6. **demo 路由**（`http_server_final.mojo`，与生产代码同文件）：
   `/pm/form-union`（无 discriminator，两分支）、`/pm/form-union-disc`
   （`kind` 判别 + `union_optional`）、`/pm/form-union-forbid`
   （分支 `extra=forbid`）。

## 5. 已知偏差

| # | 偏差 | 原因 / 影响 |
|---|------|-------------|
| 1 | **无 smart union 打分** | 无 discriminator 时取**首个校验通过**的分支（上游 smart union 按"最佳匹配"打分、`left_to_right` 亦随 pydantic 版本变化）。本实现是**确定性近似**：分支互斥字段集下与上游一致；字段重叠时可能选中不同分支 |
| 2 | **union 分支 schema inline，无 `$ref`** | 家法无命名模型 → 无法产出 `components.schemas` 引用；OpenAPI 消费者需自行展开 `anyOf` |
| 3 | **无 nullable sentinel** | 上游 0.161.1 的 `allOf` + `not{anyOf required}` / `maxProperties:0` 形状表达 nullable union；本实现以 `union_optional` + `requestBody.required` 表达，无 `maxProperties:0` 哨兵 |
| 4 | **union 分支字段不摊平进 `properties`** | 只走 `anyOf`（与 ADR-0071 的组字段摊平相反）。副作用：分支字段不出现在顶层 `properties`（客户端生成器需读 `anyOf`） |
| 5 | **无嵌套模型 / File 不参与 / 无 per-field media_type** | 与 ADR-0071 §5-2/3/4 同款边界（家法只吃标量/list 类型规格） |
| 6 | **union 组不参与 ADR-0071 的"组字段摊平"required 判定** | 分支 required 只在 `anyOf` 分支内表达；顶层 `requestBody.required` 只看 `union_optional` |
| 7 | **分支 extra 域按分支字段集重算** | 上游每个分支用**自己**的字段集重抽（其余键进该分支 extra）；本实现同款，但"选定分支"的 extra 域在无 discriminator 时取决于选中哪个分支（上游 smart union 同款行为） |

## 6. 六条架构隔离约束声明

| 约束 | 立场 |
|------|------|
| 1. 无循环依赖 | ✅ `form_models` → `form_model_core` →（`param_models` / `form_params` / `alias_choices` / `params_*`）；`form_model_core` **不反向依赖** `form_models`；`form_params` 只依赖 `param_models` + `form_model_core` 的纯叶子，无回边 |
| 2. 分层向下依赖 | ✅ 纯 Mojo 纯函数（无 FFI / 无 fd / 无 env）；dispatch 只做「读值 → 调 `plan_form_unions` → 注入」；**FFI diff = 0**，`bridge/ffi.rs` 导出数保持 87 |
| 3. God package 阈值 | ✅ 新模块 `form_model_core.mojo` 445 LOC < 500；`form_models.mojo` 251→**142**（阈值内）；`form_params.mojo` 639→733、`http_server_final.mojo` 2665→2719（**均在存量超限名单内**，拆分待办继续跟踪） |
| 4. 主题域边界清晰 | ✅ union 语义（分支绑定 / 判别 / tag 定位 / 缺席判定 / 注入键）收敛在 `form_model_core.mojo`；`form_models.mojo` 只做编排；`form_params.mojo` 只做 OpenAPI 投影；字段类型校验**复用** `validate_form_collect` 而非复制 |
| 5. bridge/adapter 显式化 | ✅ **无新增 bridge 符号**；form body 解析复用既有 `parse_form_multi` / `snapshot_mp_parts`；判别值读取复用 `alias_choices.candidates_for` |
| 6. 测试文件跟随 | ✅ demo 路由同文件（`http_server_final.mojo`：`/pm/form-union` / `/pm/form-union-disc` / `/pm/form-union-forbid`）；e2e `PFU-1..PFU-13` 与生产代码同仓库 |

## 7. 验收（2026-11-10 实测）

- `./build_single.sh`：`mojo build --emit object` 通过；binary **5,758,392 B (5.49 MiB)**（≤6M 预算）；`ldd` 仅 libc.so.6 + libm.so.6
- e2e：**963/963 全绿**（950 基线 + PFU-1..13）
- `cargo test --release -- --test-threads=1`（TMPDIR=/tmp）：531 passed / 1 failed
  （`escaping_in_output`：本机 `/bin/sh=bash` 环境依赖，pristine HEAD 既有）/ 4 ignored
- `cargo clippy --release --tests -- -D warnings`（双 crate）：0 警告
- `ldd build/fastapi_mojo`：仅 libc.so.6 + libm.so.6
- `env -i` 干净启动：health 200
- `find src -name '*.c'` = 0；`*.py` = 0

## 8. 上游对照（release 说明 + 源码核实）

| 版本 | 上游改动 | 本实现 |
|------|---------|--------|
| 0.161.0 | ✨ Add support for combining form models into unions（PR #16596） | ✅ `union=<名>` 绑定多分支 + 判别 + 分支 extra + tag 定位（PFU-1..11）；无 discriminator 取首个通过分支（§5-1） |
| 0.161.1 | 🐛 Fix OpenAPI schema for standalone nullable form unions（PR #16598） | 🔶 union 的 `anyOf` + `discriminator` + `requestBody.required` 语义到位（PFU-12）；**nullable sentinel（`maxProperties:0` / `not{anyOf required}`）未复刻**（§5-3） |
