# ADR-0014: Pydantic 式 body 校验 + Field 约束 + Enum（声明式 spec，统一 FastAPI 422 detail）

- **日期**：2026-09-05
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P1 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-38**）、Goal-0003（T-P1d Pydantic body 校验、
  T-P1e Enum）、F1 类型化参数（决策-24，`_param_types` 机制扩展）、F4 OpenAPI
  （决策-24，components/schemas 生成）、FastAPI/Pydantic v2（422 detail 格式
  语义对标）

## 1. 背景

FastAPI 的 **Pydantic 模型 body 校验**是 Goal-0003 矩阵**第 20 项**（❌ 缺失），
**Enum 参数**是**第 21 项**（❌ 缺失）：

```python
class Item(BaseModel):
    name: str
    price: float = Field(gt=0)
    quantity: int = 10
    mode: Literal["fast", "slow"] = "fast"
    tags: List[str] = Field(min_length=0, max_length=5)
    meta: Meta  # 嵌套模型

@app.post("/validate")
def validate(item: Item): ...
```

- body 参数**类型检查 + 约束（gt/ge/lt/le/len/items）+ 默认值 + 嵌套模型 + 枚举**
- 校验失败 → **422 + 全部错误收集**的 `{"detail":[{"loc","msg","type"}...]}`
  （Pydantic v2 格式，loc 到字段级：`["body","meta","city"]` / `["body","tags",0]`）
- Enum 同时覆盖 **query/path 参数**（`level: Literal["low","medium","high"] = "high"`）

约束（Mojo 1.0.0 + North Star）：
- Mojo 无动态类型 / 无闭包 / 无运行时模型构造 → Pydantic 模型**不能是请求期的
  对象图**，只能是**注册期声明**
- 零 Python：Pydantic 是 Python 库，不能依赖 —— 只能 Mojo 原生实现
- dispatch 主循环已按 `handler.data` 元数据工作（决策-33/34/36/37 模式）；
  body 校验必须延续同一扩展点模式（新增路由 = 加数据，不加 dispatch 分支）

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 请求期模型对象 | 注册时构造「字段对象列表」，请求时逐字段回调校验函数 | ❌ Mojo 无闭包/函数指针；List[Struct-with-String] 不可迭代（Copyable 限制，实测）；请求期分配多 |
| B. **声明式 spec 字符串（本 ADR）** | `_body_schema` 一行 spec（`name:str;price:float|gt=0;...`），注册期语法校验（畸形 spec 启动即 fail），请求期纯字符串解析+校验；与 `_param_types`/`_depends`/`_auth` 同一「handler.data 声明」模式 | ✅ dispatch 零新分支（统一 422 块）；注册期 fail-fast；Mojo 纯字符串操作（无新语言约束）；OpenAPI 从同一 spec 生成（单一事实源） |
| C. JSON 描述文件 | schema 放 JSON 文件，启动时加载 | ❌ 需 JSON 解析（params_json 是 object body 专用）；路由与 schema 分离，注册期一致性差 |

**决策：B** —— 声明式 spec 字符串（决策-38）。

## 3. 决策

1. **spec 文法（body_schema.mojo，注册期解析 + 语法校验）**：
   - `字段:<基础类型>[=默认值][|约束1,约束2]`，字段间 `;`
   - 基础类型：`str/int/float/bool/obj/arr` | `T[]`（数组）| `T[v1,v2]`
     （枚举，空值列表 `T[]` 语义 = 数组）| `obj{子spec}`（嵌套，同一文法递归）
   - 约束：`gt/ge/lt/le=N`（数值）/ `len=N(-M)`（字符串，byte 长度）/
     `items=N(-M)`（数组元素数）
   - 畸形 spec（未知类型/悬空括号/未知约束键）→ `parse_body_schema` **raise**，
     `check_body_schemas(router)` 在 `register_routes` 末尾注册期检查，启动即 fail
2. **两文件拆分（God package 阈值 <500）**：
   - `body_schema.mojo`（315 LOC）= spec 层：`FieldSpec`/`ParsedSchema`/
     `parse_body_schema`/`get_field`/约束词法（`_parse_range`/`fmt_num`）/
     422 错误对象构造（`err_obj`）
   - `body_validate.mojo`（313 LOC）= 校验层：`validate_body_schema`（类型/枚举/
     嵌套/数组元素/约束 → 全错误收集）+ `check_body_schemas`（注册期检查）+
     自测。校验层 import spec 层（单向，P4.4 params_*/body_* 同模式）
3. **统一 422 detail（FastAPI/Pydantic v2）**：
   - 参数校验（`validate_params_collect`，params_typed.mojo）与 body 校验
     （`validate_body_schema`）各自**收集全部错误**（不再首错即返），dispatch
     合并为一个 `detail` 数组：param loc = `["path",x]`/`["query",x]`，
     body loc = `["body",x]`（嵌套 `["body","meta","city"]`，数组元素
     `["body","tags",0]`，body 级 `["body"]`）
   - 输出：`resp_data["detail"] = "__nested__:" + "[" + join(errs) + "]"`
     （`__nested__:` 原始 JSON 直通，复用既有机制）
   - msg/type 对齐 Pydantic v2：`field required`/`missing`、
     `Input should be greater than 0`/`greater_than`、`Input should be 'a' or 'b'`/
     `enum`、`Input should be a valid number...`/`float_parsing`、
     `String should have at least N character(s)`/`string_too_short`、
     `List should have at most N item(s)`/`too_long`、`JSON decode error`/
     `json_invalid` 等
4. **Enum（T-P1e）**：
   - 参数：`_param_types` 扩展 `T[values]` 文法（`level:str[low,medium,high]=high`），
     默认值必须在枚举值内（`set_param_type` 注册期检查）
   - body：spec `T[v1,v2]` 同语义（`mode:str[fast,slow]=fast`）
   - OpenAPI：query/path 参数 schema 与 body 属性均输出 `"enum":[...]`
5. **校验值注入**：校验通过 → 值（含应用的默认值）按 `body_<name>` /
   `<父>_<子>` 注入 `req_params`（KIND_ECHO 可见；handler 无感，与 F1 参数同模式）
6. **OpenAPI（openapi.mojo）**：
   - `requestBody`（`$ref: #/components/schemas/<handler_name>`，仅声明
     `_body_schema` 的 POST/PUT/PATCH）
   - `components.schemas`：object/properties/required/enum/min-maxItems/
     min-maxLength/format/default（从同一 spec 生成，单一事实源；按 handler 名
     去重）
   - 参数 enum：`_openapi_param_schema` 识别 `T[values]` 输出 enum
7. **demo（http_server_final.mojo，注册期 2 路由）**：
   - `/validate`（POST，KIND_ECHO `validate_item`）：完整 spec（嵌套 obj +
     数组 + 枚举 + 约束 + 默认值）
   - `/enum`（GET，KIND_ECHO `enum_demo`）：`_param_types` enum 演示

## 4. 边界与已知限制

- **`len` 用 byte_length**（非 Unicode 码点数）：UTF-8 多字节字符每字节计数
  （Pydantic 按码点；差异仅非 ASCII 字符串，文档标注）。
- **严格模式**：string 不会强制转 number（`"3"` → `float_parsing` 错误），
  与 Pydantic v2 严格/非严格默认行为一致（非严格模式也拒绝 str→int 隐式转换
  于 JSON body，因 JSON 类型已区分）。
- **数组元素**：只校验元素**类型**（+数量 via items 约束）；元素级约束
  （如 `items` 内嵌套 `len`）不做（P2）。
- **嵌套 obj{}**：递归支持（校验 + OpenAPI），demo 一层；深层嵌套按 spec
  文法可行，未做深度上限（恶意 spec 属注册期攻击面，单 binary 本地信任模型内
  可接受）。
- **无 regex `pattern` 约束**（Mojo 1.0.0 无 regex 标准库；P2，需 Rust bridge
  或手写 NFA —— 独立决策）。
- **无 Pydantic validator（@field_validator）/ 自定义类型 / model_serializer**：
  声明式 spec 表达力上限（P2，矩阵 #20 标注「基础：嵌套模型+Field 约束」）。
- **PATCH body**：`validate_body_schema` 接受 PATCH，但 dispatch 的 body 解析
  仅 POST/PUT（既有行为，与 form 解析一致）—— PATCH + body 当前不解析。
- **⚠️ Mojo 1.0.0 `assert` 是 no-op（本 ADR 实测发现）**：`mojo run`（-O0/-O3
  均）下 `assert False, "msg"` **不触发**（probe 证实）。本 ADR 之前所有 `.mojo`
  自测（含决策-37 及更早）的 assert **实际从未生效**，「自测通过」无意义。
  本 ADR 的 body_validate 自测改用 `check(cond, msg)` helper（失败
  `std.os.abort()` → 非零退出）。**遗留**：仓库其余 `.mojo` 自测的 assert 仍
  是 no-op（修复属独立任务，已记录到 AGENTS.md 决议-38 备注）。

## 5. 风险

| 风险 | 缓解 |
|------|------|
| spec 文法与 Pydantic 语义偏差 | msg/type 对齐 Pydantic v2 已知向量；e2e BS 组覆盖 missing/type/constraint/enum/nested/array/json_invalid 全路径 |
| 422 错误收集改变既有 F1 行为（首错即返 → 全收集） | e2e 既有「typed 422」用例更新为 FastAPI 风格 msg 断言；全收集是**超集**（首错仍在，loc 顺序 = 声明顺序），无回归面 |
| 注册期 fail-fast 影响启动 | `check_body_schemas` 仅遍历路由表（33 路由，µs 级）；畸形 spec 本应 fail |
| `__nested__:` detail 注入绕过 JSON 转义 | 错误对象由 `err_obj` 统一构造（`json_escape` 转义 msg），loc 仅含字段名（注册期 spec 来源，可信） |
| OpenAPI 输出非法 JSON（既有风险） | 本 ADR 实测发现并修复 2 处字面量 BUG（`"type":"string}` 缺引号 / `"default":""d""` 双引号）；e2e BS-12 + `python3 json.load` 验证 |

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`http_server_final`（注册 demo + 统一 422 块）→ `body_validate`（校验层）→ `body_schema`（spec 层）；`body_validate` → `params_json`/`handler`/`router`（只读）；`openapi` → `body_schema`（只读 spec）。无回调上溯 |
| 2. 分层向下依赖 | ✅ 遵守 | spec 解析/校验/422 构造 = **纯 Mojo 字符串处理**（零 syscall、零 FFI）；body 字节经既有 bridge `get_body_slice` 进入（FFI 面不变）；校验值注入走既有 `req_params` 路径 |
| 3. God package 阈值 | ✅ 遵守 | `body_schema.mojo` 315 / `body_validate.mojo` 313 / `params_typed.mojo` 431 / `openapi.mojo` 405（均 < 500）；`http_server_final.mojo` 1136（既有超阈值文件，本 ADR 仅 +~45 行：统一 422 块 + 2 demo 路由，无新逻辑分支——dispatch 延续 handler.data 模式） |
| 4. 主题域边界清晰 | ✅ 遵守 | spec 层只管文法（不含校验/序列化）；校验层只管 body（参数校验留 params_typed，统一 422 合并在 dispatch 单点）；OpenAPI 是**文档生成**职责（读 spec，不反向写）；`check()`/`_has()` 等自测 helper 不跨主题 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新 extern "C" 导出，无 bridge/*.rs 改动）；Rust bridge 对 body 校验无感知（body 字节/JSON 解析路径不变）；`cargo clippy -D warnings` 0 警告（零改动验证） |
| 6. 测试文件跟随 | ✅ 遵守 | Mojo：`body_validate.mojo` `main()` 自测（**check() 真断言**，21 项：spec 解析/边界/missing/类型/约束/枚举/嵌套/数组元素/多错误/默认值/json_invalid/GET 跳过）；e2e **BS-1..BS-12 = 205/205 全绿**（23 项新）；`cargo test --release -- --test-threads=1` **307 passed / 0 failed / 4 ignored**（Rust 零改动） |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc；体积 3.1M（≤4.2M）。
2. **e2e 全量不回归**：180 → **205**（+23 BS 项 + 1 既有断言更新）全绿，含：
   - BS-1a..g：200 + 校验值注入（含默认值 `body_quantity:"10"` / `body_mode:"fast"` /
     嵌套默认 `body_meta_zip:"0"` / tags 数组原始 JSON）
   - BS-2a..c：缺必填 → 422 `["body","name"]` + `field required`（全收集 3 错）
   - BS-3a：`float_parsing`；BS-4a：`greater_than`；BS-5a/b：`enum` + 值列表 msg
   - BS-6a：嵌套 loc `["body","meta","city"]`；BS-7a：`too_long` items max
   - BS-8a：`json_invalid`；BS-9a：元素 loc `["body","tags",0]`
   - BS-10a：多错误收集（5 ≥ 3）；BS-11a..c：参数 enum 200/422/`["query","level"]`
   - BS-12a..c：OpenAPI components + `$ref` + `"enum":["low","medium","high"]`
   （openapi.json 经 `python3 json.load` 验证合法）
3. **质量门禁**：`cargo clippy --release --tests -- -D warnings` **0 警告**；
   `cargo test --release -- --test-threads=1` **307 passed / 0 failed / 4 ignored**。
4. **Mojo 自测（真断言）**：`mojo run src/fastapi_mojo/body_validate.mojo` —
   21 项 check() 全过（失败 std.os.abort 非零退出；**首次真正生效**的 Mojo 自测）。
5. **性能**：bench 6 场景 0 errors，get_root_10k_100c ≈ 39.7k req/s
   （历史区间 32.9k–43.9k 内，无回归；body 校验仅在声明路由触发）。

## 8. 补充（2026-09-09, 执行期）

- 本 ADR e2e 验收首跑 203/205: MP4 (256B 全字节 multipart 二进制 roundtrip)
  暴露 DC2 端口 P0 — `finish_header` 在 body 与 header 同 recv 到齐时做 UTF-8
  校验且缺 multipart 豁免 (io.rs phase-1/EOF 两路豁免覆盖不到同包到齐)。
  已由 **决策-39** (`parse::is_multipart_form_data` 纯函数 + finish_header
  豁免 + io.rs 委托) 修复, 修复后 **205/205 复验全绿** (本 ADR 验收项恢复
  有效)。Rust 单测随之 307 → 312 (+5, 决策-39 测试)。
