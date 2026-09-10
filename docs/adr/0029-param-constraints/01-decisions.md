# ADR-0029: 参数约束面统一落地 — path/query/header 约束 + typed header
# （Goal-0003 P2 矩阵 #2：`{param}` + 类型 + 约束（gt/lt/regex）；ADR-0028
# 分阶段留存的 typed header 面）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行, Goal-0003 P2 矩阵 #2 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-54**）、Goal-0003（矩阵 #2/#3/#7）、
  ADR-0004（路由 = 数据范式）、F1（决策-24, 类型化 path/query 基础）、
  决策-38（ADR-0014, body 约束词表 gt/ge/lt/le/len — 本 ADR 参数面同款
  词表扩展）、决策-43（ADR-0018, query alias/多值）、决策-45（ADR-0020,
  422 错误对象形态）、决策-53（ADR-0028, header wire/alias — 本 ADR 的
  typed header 以其 `_reads_headers` wire 为单一事实源）、FastAPI
  0.141.1 / starlette 1.6.0 / pydantic 2.13.5（语义对标）

## 1. 背景

Goal-0003 矩阵 #2：`路径参数 | {param} + 类型 + 约束 | ✅ 类型化 |
约束(gt/lt/regex) | §P2`。盘点现状（F1/决策-43/决策-53 之后）：

- ✅ `_param_types` 类型化 path/query（int/float/bool/str[enum]/[] list +
  默认值 + 缺失 422 + 422 错误对象 loc/msg/type/input, collect-all）。
- ❌ 约束面缺失（上游 `Path/Query/Header` 关键行为）：
  1. **数值约束**：`gt/ge/lt/le/multiple_of`（int/float）。
  2. **字符串约束**：`min_length/max_length/pattern`（str/隐式 str）。
  3. **typed header**（ADR-0028 分阶段留存, P25-6..9 已探测）：`Header()`
     缺省 **required**（缺失 → 422 `missing`）/ `Header(default=)`（缺失 →
     默认值）/ 类型转换（int/float/bool parse）/ 约束。
  4. **OpenAPI**：约束 → schema 键（gt/ge/lt/le/multipleOf/
     minLength/maxLength/pattern）+ `required`/`default`。

**上游探测（P26-a..g, /tmp/exch_probe/p26*.py, fastapi 0.141.1 /
pydantic 2.13.5 / uvicorn 0.52.4 活体）**：

| # | 实测 |
|---|------|
| P26-a | 数值 422 精确串 + ctx：gt `greater_than` "Input should be greater than N" / ge `greater_than_equal` / lt `less_than` / le `less_than_equal` / multiple_of "Input should be a multiple of N"；ctx = `{"gt":N}` 等（**上游拼写**: multiple_of/min_length/max_length）。字符串：min_length `string_too_short` "String should have at least N characters" / max_length `string_too_long` "...at most N characters" / pattern `string_pattern_mismatch` "String should match pattern '...'"（P25-7/8 复现） |
| P26-a | **path 参数不能带默认值**（`Path(default=5)` → build 期 `AssertionError: Path parameters cannot have a default value`）→ 本实现 path 恒 required, 默认值语义不存在 |
| P26-b | header 422 **loc = wire 名**（alias 原样 `X-Mix` / 转换名 `x-token`, P25-1 同源）；缺失 → `{"type":"missing","msg":"Field required","input":null}` |
| P26-b | **默认值在字段缺失时被校验**（default="abc"+min_length=10 缺失 → 422 string_too_short, input="abc"；default=5+lt=3 缺失 → 422 less_than, **input=5 数字**）— 但**不**在 app build 期 fail（`app built OK`）→ 运行期 422 语义 |
| P26-b | collect-all 顺序 = **path → query → header**（单 detail 数组, P26-b-10） |
| P26-c | parse 消息（pydantic 2.13.5 精确串）：bool `bool_parsing` "Input should be a valid boolean, **unable to interpret input**" / float `float_parsing` "Input should be a valid number, unable to parse string as a number" / int `int_parsing` "Input should be a valid integer, unable to parse string as an integer" |
| P26-c/d/e | **每字段仅报首个违规约束**（非全部）；优先级实测：数值 **multiple_of → ge → gt → le → lt**（n=1 mo+gt 双违 → multiple_of；4 ge+gt 双违 → ge；10 le+lt 双违 → le）；字符串 **min_length → max_length → pattern**（AB min+pat 双违 → string_too_short；ABCDE max+pat → string_too_long） |
| P26-f | str 参数 + 数值约束（`x: str = Query(gt=0)`）= 上游**放行**（app build OK；OpenAPI string schema 带 `"gt":0`；运行时 no-op）— 宽容 quirk；无标注 path 参数 + `Path(min_length=2)` = 隐式 str 可用（OpenAPI schema **无 type 键**, 仅 minLength/maxLength/title） |
| P26-g | **`List[int] = Query(ge=0)` → 运行时 500**（`TypeError: Unable to apply constraint 'ge' to supplied value [5]` — 约束作用于 list 整体而非元素, 上游崩溃） |

**范围切分**（矩阵对齐）：本 ADR = **path/query/header 三面的约束统一落地
+ typed header**（矩阵 #2 gap 字面 gt/lt/regex + ADR-0028 留存的 typed
header 面）；pattern 经**自研 regex 引擎**（bridge/regex.rs, 零第三方,
SHA-1/base64/UTF-8 手写先例同款）支撑。list 元素约束 = 上游本身 500
（P26-g）→ 本实现注册期拒绝（优于上游, 非缺失）；body 字段约束词表扩充
（mo/pat）= 矩阵 #4 面, 未来决策（本 ADR 词表与其兼容）。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. `_param_types` 条目内嵌约束（`int\|gt=3`） | 类型 token 语法重载 | ❌ `[]` 已被 enum/list 占用, `\|` 仅 body 面在用; 类型解析器复杂度上升; 既有 `_param_types` 声明零改动要求被破坏风险 |
| B. **独立声明 `_param_constraints` + `_header_types`（本 ADR）** | 约束 = 独立 data 键（`name=k=v,k=v` CSV, `;` 分条, 同 body 面 `k=v` 词表: gt/ge/lt/le + len=N(-M) + 新 mo/pat）; typed header = 独立键 `_header_types`（`_param_types` 同款类型语法, wire 取自 `_reads_headers`） | ✅ ADR-0004 一功能一键范式; body/参数词表统一（决策-38 先例）; 既有 `_param_types`/`_reads_headers` 声明**零改动**（纯增量）; 三面统一一处校验 |
| C. 单一大表（name:type:constraints 合并） | 一个键表达类型+默认+约束 | ❌ 重构既有 `_param_types`/`_form_fields` 全部声明面, 回归面过大; 与 F3a/决策-43/45 的键分工断裂 |

**决策：B** — `_param_constraints` + `_header_types`（决策-54）。

## 3. 决策

### 3.1 声明语法

- **`_param_constraints = "name=k=v,k=v;name2=..."`**（条目 `;` 分;
  条目首个 `=` 切 name 与约束 CSV; 约束 `k=v`, CSV 逗号切）:
  | 键 | 语义 | 适用 |
  |----|------|------|
  | `gt`/`ge`/`lt`/`le` | 数值边界（值 = 数字字面量, 消息/OpenAPI 原样保留） | int/float 类型化参数 |
  | `mo` | multiple_of（数值） | int/float |
  | `len=N(-M)` | min_length=N / max_length=M（同 body 面 `len=N-M` 区间语法） | str/隐式 str |
  | `pat=REGEX` | pattern（首个 `=` 切; 值可含 `=`; 含 `,` = CSV 歧义, 文档化） | str/隐式 str |
- **`_header_types = "name:type=default;..."`**（`_param_types` 同款语法:
  int/float/bool/str[enum]/[] list + `=` 默认）; **name 必须在
  `_reads_headers` 声明**（wire/alias 单一事实源, 决策-53）; 否则注册期
  拒绝。list 类型 header 允许（多值取首后按元素类型校验, 标量语义）。
- **类型匹配规则**（注册期强制, §3.2）：数值键（gt/ge/lt/le/mo）仅
  int/float; `len`/`pat` 仅 str/隐式 str; bool 不接受任何约束。
- **隐式 str 参数**（未标注类型但声明约束: path 段名 / query 键）:
  仅 `len`/`pat` 有效（数值键 → 注册期拒绝）。
- **path 参数**: 恒 required（上游 assert 无默认, P26-a）; `_param_types`
  若给 path 段声明默认值 = 沿用既有行为（值恒来自 URL, 默认不触发,
  OpenAPI required 恒 true）。

### 3.2 注册期校验（`check_param_constraints`, check_* 同策略 fail-fast）

- 条目语法: 空条目跳过; 未知约束键 → `Error("constraints: unknown key ...")`;
  数值键值非数字字面量 → 拒; `len` 值非 `N(-M)` 形态 / 负数 → 拒。
- 约束目标必须可解析: name 是 path 段 / 在 `_param_types` / 在
  `_reads_headers` / 在 `_header_types`; **未声明 query 键 = 隐式 str
  声明**（仅 len/pat 约束; 数值键拼写错误仍经 type-mismatch 规则拒;
  纯 len/pat 拼写错误 = 每请求 422 missing 自证 — 优于上游静默忽略）。
- 类型失配（§3.1 规则）→ 拒（**优于上游 P26-f 宽容放行: 上游对 str+gt
  静默 no-op, 本实现启动即暴露**）。
- **list 类型参数 + 任何约束 → 拒**（P26-g: 上游运行时 500; 本实现
  fail-fast, 优于上游）。
- `_header_types` name 不在 `_reads_headers` → 拒; header list 类型 +
  约束 → 拒（同 P26-g 面）。
- pattern 编译校验: `regex_match(pat, "")` 编译错误 → 拒（启动即暴露
  坏正则, 不带到请求期）。

### 3.3 运行期语义（dispatch）

- **path/query**（`validate_params_collect` 扩展, 签名 +constraints 参数）:
  类型解析成功后逐参数查约束; **每字段仅报首个违规**（优先级: 数值
  mo→ge→gt→le→lt; 字符串 minl→maxl→pat, P26-c/d/e 实测）; 422 对象 =
  既有 house 形态（loc,msg,type,input, 决策-45）+ **`ctx`**（约束键用
  **上游拼写**: gt/ge/lt/le/multiple_of/min_length/max_length/pattern;
  数值 = JSON 数字, pattern = 字符串; ctx 置于 input 之后 — 唯一结构
  增量, §3.5 ①）。**input 类型化（P26-b-8, 与 header bullet 同规则）**:
  在场值 → raw 字符串（含空值）; **缺失+默认违约束 → 类型化字面量**
  （int → JSON 数字 unquoted, bool → true/false, str → 引号字符串）;
  parse 失败 → raw 字符串原样。
- **隐式 str**（path 段/query 键, 未类型化但声明 len/pat）: dispatch 级
  独立 pass（值恒 str, 与解析态无交互）; 同样 collect-all + 首违 + ctx。
- **typed header**（新 `validate_headers_collect` 编排, http_server_final
  FFI 读值 + param_constraints 纯校验）: 逐 `_header_types` 声明序:
  - **缺失**: 有默认 → **校验默认值**（类型 + 约束, P26-b-7/8: 默认违
    约束 → 422, **input = 默认值类型化**（int → 数字, str → 字符串,
    bool → true/false）; 通过 → 注入默认字面量）; 无默认 → 422
    `missing` "Field required" input null（loc = ["header", wire]）。
  - **在场**: 类型解析（int/float/bool/**str**; parse 失败 → 422 完整
    消息 §3.4）→ 约束（同优先级）→ 注入**原始字符串**（handler 无感,
    String dict, 既有 F1 约定）。
  - 422 并入主 all_errs: **path/query 错误之后、body 错误之前**
    （P26-b-10 顺序）。
  - 未类型化的 `_reads_headers` 条目: 保持既有字符串注入, 不受影响。
- **pattern 匹配**: bridge `regex_match(pattern, s) -> i32`（1 = match /
  0 = no match / -1 = 编译失败; 每请求单次调用 = 编译+匹配+释放,
  短 pattern/短值场景编译开销可忽略; FFI diff = +1）。

### 3.4 消息统一（矩阵 #3 偏差解决）

- `params_typed` 标量 bool parse 消息 "Input should be a valid boolean"
  → **完整上游串** "Input should be a valid boolean, unable to interpret
  input"（P26-c-1/11; form/list 面本就完整 — 三面对齐; 矩阵 #3 的
  「标量 bool 短消息」偏差项销账, CSV 逗号歧义偏差保留）。e2e 无消息
  文本断言（仅 `"type":"bool_parsing"` 类型断言 — 审计通过）。

### 3.5 OpenAPI（3.0.3, 3.0 风格约束键）

- **参数 schema 键**（键序: type, minLength, maxLength, pattern,
  multipleOf, minimum, exclusiveMinimum, maximum, exclusiveMaximum,
  default, description）:
  | 约束 | 3.0 编码 |
  |------|----------|
  | gt=N | `"minimum":N,"exclusiveMinimum":true` |
  | ge=N | `"minimum":N` |
  | lt=N | `"maximum":N,"exclusiveMaximum":true` |
  | le=N | `"maximum":N` |
  | mo=N | `"multipleOf":N` |
  | minl=N | `"minLength":N` |
  | maxl=N | `"maxLength":N` |
  | pat | `"pattern":"..."` |
  （数值字面量原样进 JSON; int 不带小数点, float 带）
- **header 参数**（`_header_types`）: schema type（integer/number/
  boolean/string; 未类型化 = string）+ `required` = **无默认?** +
  `default`（类型化字面量: int/float → 数字, bool → true/false, str →
  字符串）+ 约束键; name = wire 名（决策-53, 原始拼写）。
- **path 参数**: required 恒 true; 约束键同上; 既有 type/default 行为
  不变（list/enum 保持）。
- **query 参数**: required = 无默认?（既有）+ 约束键。
- **3.0 vs 3.1**（ADR-0027 偏差 ① 延伸）: 上游 3.1.0 用**数值**
  `exclusiveMinimum/exclusiveMaximum`; 本 spec 3.0.3 用 **boolean**
  `exclusiveMinimum/exclusiveMaximum` + minimum/maximum（3.0 合法编码,
  语义等价）。

### 3.6 regex 引擎（bridge/regex.rs, 零第三方）

- 手实现 backtracking 引擎（Rust, 无 crate — SHA-1/base64/UTF-8 手写
  先例同款）; FFI `regex_match(pattern, s) -> i32`（1/0/-1, §3.3）。
- **支持面**（Python `re` 常用子集, 文档化）: 字面量 / `.` / 转义
  `\d\w\s\D\W\S\n\t\r\b\f` / 字符类 `[a-z0-9]`（含 `^` 否定、`]` 转义）
  / 量词 `* + ? {n} {n,} {n,m}` / 组 `(...)`（非捕获）/ 交替 `|` /
  锚 `^ $` / 空交替项。
- **不支持**（文档化偏差, 上游 re 超集）: 反向引用 `\1` / 环视
  `(?=) (?!)? (?<=) (?<!)` / 命名组 `(?P<name>)` / 内联标志
  `(?i)`（大小写不敏感需显式字符类）。
- 测试: Python `re` 生成已知向量（/tmp/fm_probe 活体对拍）+ 编译失败
  用例（未闭合类/量词/括号）。

### 3.7 demo 路由（http_server_final）

- `/con/path/{n}`（GET, ECHO）: `_param_types n:int` +
  `_param_constraints n=gt=3,le=10` — 数值边界面。
- `/con/str/{s}`（GET, ECHO）: `_param_constraints s=len=2-4,pat=^[a-z]+$`
  — 隐式 str 面。
- `/con/query`（GET, ECHO）: `_param_types q:int=5` +
  `_param_constraints q=ge=0,lt=100;r=len=1-3` — query 类型化 + 隐式
  str 混合。
- `/con/hdr`（GET, ECHO）: `_reads_headers x_token,x-app` +
  `_header_types x_token:int;x-app:bool=true` — required int（缺失 422
  / "abc" int_parsing）+ bool 默认（缺失 200 true / "xyz" bool_parsing
  完整消息）。
- `/con/hdr2`（GET, ECHO）: `_reads_headers x-ver=X-Ver,tag` +
  `_header_types x-ver:int=1;tag:str=ab` + `_param_constraints
  x-ver=ge=1,le=3,mo=1;tag=len=1-2,pat=^[0-9a-z]+$` — header 约束面
  （alias wire + 默认 + 数值/字符串约束混合）。

### 3.8 文档化偏差（vs 上游 FastAPI 0.141.1）

| # | 上游 | 本实现 | 定性 |
|---|------|--------|------|
| 1 | 422 对象键序 `type,loc,msg,input,ctx` | house 键序 `loc,msg,type,input` + **ctx 追加末位**（决策-45 既有键序约定; 本 ADR 仅加 ctx） | 既有 house 约定（40+ e2e 断言 baked）; ctx 为本 ADR 唯一结构增量, 位置末位 vs 上游 input 之后 |
| 2 | str 参数 + 数值约束 = 放行（OpenAPI 带 gt, 运行时 no-op, P26-f） | 注册期拒绝 | **优于上游**（启动即暴露配置错误, 不带到请求期静默失效） |
| 3 | `List[...]` 参数 + 数值约束 = **运行时 500**（P26-g, 约束误作用 list 整体） | 注册期拒绝 | **优于上游**（fail-fast vs 崩溃） |
| 4 | OpenAPI 3.1.0 数值 `exclusiveMinimum/exclusiveMaximum` | 3.0.3 boolean 形式 + minimum/maximum（§3.5） | ADR-0027 偏差 ①（3.0.3 vs 3.1.0）的约束键延伸; 3.0 合法且语义等价 |
| 5 | pattern = Python `re` 全功能 | 自研 backtracking 子集（§3.6: 无反向引用/环视/命名组/内联标志） | 零第三方依赖约束下的等价形态（声明式词表先例, 矩阵 #4 同款定性）; 常用子集全覆盖（e2e 向量对拍） |
| 6 | 无标注 path 参数 + 约束 → schema **无 type 键**（P26-f） | schema 恒带 `"type":"string"` | 更显式, 3.0 合法; 信息超集 |
| 7 | 数字字面量消息 = 解析后数值（"03" → 3） | 声明字面量原样（"03" → "03"） | 边缘 case（规范书写下行为一致）; 避免二次解析歧义 |
| 8 | body 字段约束词表（决策-38）= gt/ge/lt/le/len/items, 无 mo/pat | 本 ADR 仅动参数面; body 面词表扩充（mo/pat + 消息对齐）= 矩阵 #4 未来决策 | 面隔离（矩阵 #4 gap 原文: "声明式约束词表为等价形态（扩充 P2）"）; 本 ADR 词表与其兼容（同 k=v 语法） |

## 4. 风险

- **R1 regex 引擎正确性**: backtracking 引擎有指数爆炸面（pathological
  pattern）— 缓解: 输入短（header/query/path 值 <<100B）+ 匹配步数上限
  （超限 = no match, 防 DoS）+ 已知向量对拍（Python re 活体生成）。
- **R2 `validate_params_collect` 签名扩展**: 既有调用点（http_server_final
  dispatch + params_typed selftest main）需同步 +空约束参数 — 无约束
  路由零行为变化（e2e 全量回归守护）。
- **R3 bool 消息统一**: 既有 e2e 仅断言 type（审计通过）; 用户侧若对
  旧短消息有断言 = 行为变更（AGENTS.md 决议链公告）。
- **R4 binary 体积**: Rust bridge +regex（估 15-25 KB stripped）+ 纯
  Mojo ~15 KB → 总计 +~40 KB（3.8M → ~3.85M, ≤4.2M 预算余量充足）。
- **R5 行数预算**: params_typed 499 ln → 抽出 numlit 原语（-~60）+
  约束接线（+~15）≈ 455 <500; openapi 499 → 移 `_generate_parameter`
  至 openapi_schemas（-16）+ 头部接线（+~8）≈ 491 <500;
  param_constraints 新模块 <500; bridge/regex.rs <500。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | `param_constraints → {numlit, router, handler}`; `params_typed → numlit`（原语抽出, 回边消除）; `http_server_final → param_constraints`; `openapi → openapi_schemas → param_constraints`; `bridge/regex.rs → std`（叶子）; 无环 |
| 2. 模块 < 500 行 | ✅ 遵守 | param_constraints 464 / param_constraints_run 152（运行期 collect 拆分）/ numlit 279 / params_typed 318 / openapi_schemas 279 / openapi 445 / params_query_extra 373 / bridge/regex.rs 498（+regex_tests 119 独立文件）|
| 3. FFI 表面 | ⚠️ 扩展（声明） | **FFI diff = +1 新导出**（`regex_match(pattern, s) -> i32`; 既有导出集不变）+ **1 行为修正**（`extract_request_header` 三态 0/-2/-1, 签名不变 — §7.6⑦; F3a 注入语义保持）; 其余约束/typed header 语义 = 纯 Mojo（零新 FFI）|
| 4. 零新依赖 | ✅ 遵守 | regex = Rust std 手实现（无 regex crate）; ldd 仅 libc 不变（-static-libgcc 守则, 新增内建函数风险 = 0, regex 纯整型运算无 libm）|
| 5. 单 binary 不变式 | ✅ 遵守 | `build_single.sh` 零改动（regex 进既有 staticlib）; 编译期编译校验 = 启动期 FFI 调用 |
| 6. 声明式世界观 | ✅ 遵守 | `_param_constraints` / `_header_types` = 新声明键（ADR-0004）; `check_param_constraints` fail-fast（check_* 同策略）; 运行期无对象修改; handler 无感（String dict 注入, F1 约定） |

## 7. 验证方式（实测 2026-09-10）

### 7.1 单 binary 不变式
- `build_single.sh` **零改动**（regex 进既有 Rust staticlib; -static-libgcc
  守则保持 — regex 纯整型运算, 无 libm/新 libgcc 内建函数风险）
- `ldd build/fastapi_mojo` = **仅 libc**（linux-vdso + ld-linux = 标准）
- Binary = **4,020,232 B**（3.9M 显示; ≤4.2M 目标 / CI ≤6M 预算）

### 7.2 质量门禁
- **7 模块 0 新增警告**（Mojo 基线 4 保持: http_server_final:271/281
  dispatch_dep Bool-unused / handler:354 doc / security:223 — 全部
  存量, 刻意不"修"）
- `cargo test --release -- --test-threads=1`（fastapi_mojo_rs）=
  **434 passed / 0 failed / 4 ignored**（1.04s）
- `cargo clippy --release --tests -- -D warnings` = **0 警告**
  （fastapi_mojo_rs + fmtool 双 crate）
- `param_constraints_selftest.mojo` = **10/10 节全绿**（t_parse /
  t_len / t_num / t_str(len) / t_fragments / t_get / t_reads /
  t_headers / t_implicit / t_params）

### 7.3 e2e
- `./scripts/e2e_test.sh` = **428/0 全绿**（403 预-54 基线 + 25 CP:
  CP-1..19, CP-20a/20b, CP-21..24）
- 关键断言: CP-8 query 默认注入（200 body `query_` 回显）/
  CP-12 header missing input=null / CP-15 在场+默认注入 200 /
  CP-16 双默认过约束 / CP-20a 三错群序 path→query→header /
  CP-20b 默认违约束 input=类型化字面量（unquoted 2）/
  CP-22 OpenAPI typed header schema（alias 约束查找修复, 见 7.6）/
  CP-23 隐式 str schema 恒带 type 键

### 7.4 性能
- `./benchmark.sh` = 6 场景 **0 errors**;
  get_root_10k_100c = **35,124 req/s**（32.9k–43.9k 带内, 无回归）
- RSS 平台化 17,080 kB（3 rounds 稳定, 无线性泄漏）
- `env -i` 干净启动 / `pgrep -x fastapi_mojo` = 0 孤儿

### 7.5 环境注记 — JIT regex stub
- **根因**: Mojo 1.0.0 JIT 按 **call-graph closure** materialize
  `external_call` 符号; JIT env 无 bridge lib → 任何可达 `regex_match`
  的模块 `mojo run` 即 "Symbols not found: [regex_match]"
- **LD_PRELOAD 无效**（materialization 先于进程加载）;
  **`mojo run -Xlinker <stub.so>` 是唯一有效路径**（stub .so 作 link 输入）
- `dev/jit_regex_stub.rs` + `scripts/jit_stub.sh`（rustc cdylib →
  /tmp/jit_regex_stub.so）: `#[no_mangle] pub extern "C" fn
  regex_match(*const i8, *const i8) -> i32` — **body abort-if-called**
  （纯链接符号, 不进 binary / build_single）。使用面: (a) 本地
  `param_constraints_selftest.mojo`（dev-only, 约束用例无 pat → 桩永不被
  调用）; (b) **CI「Run unit tests」step** — 决策-54 后 `params_typed`
  （CI 循环内生产模块自测）import param_constraints, JIT 闭包需该符号,
  CI 以 `-Xlinker` 注入桩（其 main 只走 int/bool/enum/list/alias 路径,
  constraints="", 从不触发 pattern 分支 → 桩安全; 其余 6 模块实测不达
  FFI 不需桩）
- **check_str split**: `check_str_constraints` = `check_str_len_constraints`
  （pure）+ `check_str_pattern`（FFI）组合 — JIT 隔离; 生产调用者仍走
  组合入口, 行为等价

### 7.6 实施偏离记录（vs 本 ADR 前文）
- **模块拆分**: 计划单文件 ~300 → 实际 `param_constraints.mojo` 464 ln
  （spec/注册/OpenAPI）+ `param_constraints_run.mojo` 152 ln
  （运行期 collect, 500 行规则拆分边界: spec 面 vs 运行期面）
- **numlit.mojo 279 ln**: 含 type-spec 原语（parse_type_spec /
  parse_base / parse_typed_value / enum_in）— F1 重构后实际形态,
  超出 §3 原文范围
- **第 6 demo 路由 /con/all**（§3.7 计划五路由之外）: collect-all
  群序断言路由（path+query+header 三错同 422, 类型化 input 验证）
- **excl2 bug（selftest 捕获修复）**: `constraint_schema_fragments`
  初版 le 误映射 `exclusiveMaximum:true`（le = inclusive, 只出
  maximum; exclusive 标志属 gt/lt）
- **from_default unquoted input（P26-b-8）泛化**: 原设计仅 header 面,
  实施中 query/path 面同款（§3.3 已并入正文）
- **OpenAPI alias 约束查找修复**: `_generate_parameter` 按 param_name
  （wire 名）查 cons 表, 但 cons 表按**声明名** keyed → alias header
  （X-Ver）/ alias query 的约束全部丢失（schema 退 {"type":"string"}）。
  修复: openapi.mojo header/query 循环注入 `cons[wire] = cons[declared]`
  别名条目（本地 dict, 零 FFI）
- **FFI 三态契约（既有导出行为变更, FFI diff 仍 = +1）**:
  `extract_request_header` 原 0 = found/missing 不可分（missing 写
  空 slice）→ 现 **0 = found（值可空）/ -2 = 未找到 / -1 = 出错**
  （无 active conn）。Mojo `read_headers_present` 借此区分缺失 vs
  在场空值（缺失+默认 → 校验默认; 在场空值 → parse 失败 422）—
  CP-12/15/16/20b 根因; F3a `inject_request_headers` 保持
  缺失→空串注入（rc≠-1 即读 slice）。
