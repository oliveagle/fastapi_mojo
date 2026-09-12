# ADR-0058: body 422 detail pydantic 逐字段对齐（决策-83）

**状态**：已接受
**日期**：2026-09-12
**决策**：83（Goal-0003 对标矩阵 #4 body 422 detail 精度 / bead `fastapi_mojo-tew`）
**关联**：AGENTS.md §3.2/§6（**决策-83**）、决策-38（ADR-0014 body_schema）、
决策-58（ADR-0033 元素约束）、决策-81/82（ADR-0056/0057 lax/跨类型强制）、
决策-45（ADR-0020 422 键序 house 约定）、North Star（纯 Mojo 逻辑；FFI diff = 0；
zero new crate；zero Rust/C 改动）、上游 `fastapi 0.141.1` / `pydantic 2.13.4`

## 1. 背景（缺口）

决策-38 起 body 422 detail 只有 `loc/msg/type/input` 四键，且：

1. **缺 `ctx`**：上游 pydantic v2 对**约束类**错误（string_too_short/long、
   string_pattern_mismatch、multiple_of、greater_than(_equal)、less_than(_equal)、
   列表 too_short/too_long、enum）在 detail 对象末尾追加 `ctx`
   （`{"min_length":2}` / `{"multiple_of":3}` / `{"field_type":"List",...}` /
   `{"expected":"'fast' or 'slow'"}` 等）。
2. **str 长度按字节**：ADR-0014 §4 记录的已知偏差 —— 上游按 **codepoint** 计数，
   本实现按 `byte_length`（`"é"` 字节 2 → 误判为满足 `len=2`）。
3. **约束错缺少 `multiple_of`**（`mo=N`）与上游 `too_short`/`too_long` 的
   `field_type`/`actual_length` 结构。
4. **数组长度错不短路**：上游列表长度校验先于元素校验，长度错时**只报长度错**
   （元素错被短路）；本实现两批都收。
5. **数值约束无明确首违序**：上游内建序为 `multiple_of → le → lt → ge → gt`
   （同字段只报第一个）。
6. **列表长度消息复数**：`1 → "item"`，其余 `"items"`。
7. **`input` 片段按字面形状猜测**：JSON 字符串值 `"1"`/`"1e1"`/`"0.3"` 被误当
   数字渲染成裸 `1`/`1e1`/`0.3`；上游 `input` **保留原 JSON 类型**（带引号）。
8. **多字节崩溃（P0）**：`String[byte=i]` 在 Mojo 1.0.0 要求 `i` 落在 codepoint
   边界，逐字节扫描多字节内容会 `Assert Error` → **server 崩溃**：
   - body 数组元素（`_split_json_array`，如 `["a","é"]`）；
   - form/cookie 值（`request_response._parse_form_body`/`parse_form_multi`/
     `_parse_cookies`，如 `--data '{"s":"é",...}'` 无 `Content-Type`）。

## 2. 目标

把 body 422 detail 逐字段对齐上游 pydantic v2：

- 约束类错误追加 `ctx`（值 = 声明字面量原样 / `actual_length` 现值）。
- str 长度按 **codepoint**；消息 `String should have at least/at most N characters`。
- 支持 `mo=N`（multiple_of）约束 + `multiple_of_ctx`。
- 数值约束首违序 `mo→le→lt→ge→gt`（同字段仅首个）。
- 列表长度错用 `too_short`/`too_long` + `ctx{field_type,min_length|max_length,
  actual_length}` + **短路**元素校验；单复数 `item(s)` 对齐。
- enum 错误追加 `ctx{"expected": "<msg 去 'Input should be ' 前缀>"}`。
- `input` 片段按 **JSON 类型**渲染（字符串恒带引号；数值/bool/null/对象/数组原样）。
- 多字节 body/form/cookie 输入不再崩溃（字节安全扫描）。

## 3. 实现（纯 Mojo；核心零改动）

1. **`body_schema.mojo`**：新增 `err_obj_ctx(loc,msg,type,input,ctx)`（house 键序
   `loc,msg,type,input,ctx`，与决策-45/ADR-0029 §3.7 一致，`ctx` 追加末位）；
   `_parse_field` 约束接受 `mo`（数值）。
2. **拆分（God package 阈值）**：约束应用层（`_body_rgx_match`/`_json_input_frag`/
   `_json_input_frag_typed`/`_item_word`/`_parse_constraint_kv`/`_num_constraint_err`/
   `_apply_constraints`/`_apply_elem_constraints`）外移到新 **`body_constraints.mojo`**
   （198 LOC）；`body_validate.mojo` 523 → **333 LOC**（回 < 500）。拆分边界 = 纯约束语义,
   无 fd/env；`body_validate` 单向 import `body_constraints`。
3. **`body_validate.mojo`**：
   - `_apply_constraints(fs, inp, valtxt, elem_count, inp_json, floc, errs)` 重写：
     int/float 走 `_num_constraint_err`（`mo→le→lt→ge→gt` 首违，返回
     `err_obj_ctx`）；str 走 codepoint 长度（`len(inp.codepoints())`）+ pattern
     （均带 ctx）；数组 `items` 走 `too_short`/`too_long` + `field_type/
     actual_length`，命中即 `return`。`inp_json` 由调用方按 JSON 类型预渲染。
   - `_apply_elem_constraints(elem_t, inp, valtxt, fs, eloc, errs)`：元素级
     `mo/le/lt/ge/gt`（复用 `_num_constraint_err`）+ str `len`(codepoint)/`pat`。
   - 新增 `_item_word`（单复数）、`_parse_constraint_kv`（约束 CSV → dict）、
     `_num_constraint_err`（首违序）、`_json_input_frag_typed`（按 JSON 类型渲染
     input）。
   - `_validate_fields`：数组分支先 `_apply_constraints`，命中长度错即 `continue`
     短路元素循环；标量/类型错/enum/coerce 失败的 `input` 改用
     `_json_input_frag_typed(t, raw)`。
   - `_split_json_array` 扫描改 `Int(raw.as_bytes()[i])`（字节安全）。
   - `_strip_quotes` 尾字节判定改 `Int(v.as_bytes()[n-1])`（字节安全）。
   - `_check_body_spec` 允许 `mo`。
4. **`request_response.mojo`**：新增 `_bof(s, i) = Int(s.as_bytes()[i])`；把
   `_parse_form_body`/`parse_form_multi`/`_parse_cookies`/`_split_csv`/
   `parse_response_headers`/`is_nested_marker`/`_csv_contains` 的 29 处
   `ord(x[byte=k])` 改为 `_bof(x, k)`（语义不变：仅与 ASCII 分隔字节比较；
   多字节首字节 ≥ 0xC2 永不相等）。
5. **`numlit.parse_float_lax` P0 修复**：原 `Float64(cleaned)` 中 `cleaned` 从
   `i`（跳过符号位）起拼 → **负号丢失**（`-5 → 5.0`）。改 `Float64(sign + cleaned)`。
6. **demo**：`body_schema_routes.mojo` 新增 `/bs/detail`
   （`s:str|len=2-4;n:int|ge=10,mo=3;f:float|mo=0.5;xs:int[]|items=1-2,mo=2;
   mode:str[fast,slow]`）。
7. **测试**：`body_validate_test.mojo` 新增断言（mo/ge ctx、mo>ge 首违、codepoint
   len、too_short 单数 + ctx、too_long 复数、元素 mo idx、enum ctx.expected、
   数组长度短路、input 类型化引号、负号 float）；`_has` 改字节安全（`s.bytes()`）。

核心 `run_handler` / router / FFI 零改动（决策-54 声明式扩展点延续）。

## 4. 上游探测证据（fastapi 0.141.1 / pydantic 2.13.4）

```
== str (len 2-4) ==
"é"      -> string_too_short "String should have at least 2 characters" ctx {"min_length":2} input "é"
"abcde"  -> string_too_long  "String should have at most 4 characters"  ctx {"max_length":4}
pat      -> string_pattern_mismatch "String should match pattern 'P'" ctx {"pattern":"P"}
数值 int n ge=10,mo=3:
  n=5    -> multiple_of "Input should be a multiple of 3" ctx {"multiple_of":3}   (mo 先于 ge)
  n=9    -> greater_than_equal "Input should be greater than or equal to 10" ctx {"ge":10}
float f mo=0.5:
  f=0.3  -> multiple_of "Input should be a multiple of 0.5" ctx {"multiple_of":0.5}
首违序 (实测): multiple_of -> le -> lt -> ge -> gt
列表 xs items=1-2:
  xs=[]      -> too_short "List should have at least 1 item after validation, not 0"
                ctx {"field_type":"List","min_length":1,"actual_length":0}
  xs=[2,4,6] -> too_long  "List should have at most 2 items after validation, not 3"
                ctx {"field_type":"List","max_length":2,"actual_length":3}
  长度错短路元素校验 (只报长度错)
enum mode "turbo":
  -> enum "Input should be 'fast' or 'slow'" input "turbo"
     ctx {"expected":"'fast' or 'slow'"}          (= msg 去掉 "Input should be " 前缀)
input 类型 (JSON 字符串值恒带引号):
  s="1"    -> input "1"        (string_too_short)
  n="1e1"  -> input "1e1"      (int_parsing)
  f="0.3"  -> input "0.3"      (multiple_of)
  n=7.5    -> input 7.5        (int_from_float, 数值不带引号)
  xs=[]    -> input []         (数组原样)
```

## 5. 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| 422 对象键序 | `type,loc,msg,input,ctx` | house `loc,msg,type,input,ctx`（`ctx` 末位） | **既有约定**（ADR-0029 §3.7「决策-45 键序 + ctx 末位」；40+ e2e baked），本决策仅追加 `ctx` |
| Content-Type 语义 | 非 JSON CT + JSON body → `model_attributes_type`（`loc:["body"]`） | 只要 body 是合法 JSON 即按 JSON 解析（不按 CT 分派） | **既有全局取舍**（非本决策引入；e2e helper `--data` 依赖此行为） |
| 非有限 float | `inf`/`nan` → JSON 渲染 500 | 回显字符串 `"inf"`/`"nan"` | 决策-81 既有偏差，非本轮 |
| 原始（非 percent-encoded）非 ASCII 查询/form 值 | `café` | `url_decode` 把裸非 ASCII 码点替换为 `?`（`caf?`） | 决策-81 既有行为，非本轮 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `body_schema`（叶，spec 层）← `body_validate`（校验层）单向；`request_response` 只 import `params_query.url_decode`；`numlit.parse_float_lax` 被 `body_coerce`（叶）消费 → 无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串/数值变换（无 FFI / 无 fd / 无 env）；接线在 `_validate_fields` 单点，数组短路在同一循环内；`ctx` 构造复用 `json_escape` |
| 3. God package 阈值 | ✅ 遵守 | 约束层外移新 `body_constraints.mojo`（198 LOC）；`body_validate.mojo` 523→**333**、`body_schema.mojo` 333、`request_response.mojo` 307、`body_validate_test.mojo` 240、`body_schema_routes.mojo` 55 均 < 500 |
| 4. 主题域边界清晰 | ✅ 遵守 | 422 detail 构造/约束语义归 body_schema/body_validate（body 域）；form/cookie 解析归 request_response（transport 域）；数值字面量归 numlit（字面量域） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出/零新 crate/零 Rust/零 C）；全部纯 Mojo |
| 6. 测试文件跟随 | ✅ 遵守 | `body_validate_test.mojo`（+13 组断言，`_has` 字节安全）；e2e 新增 `MX-1a..MX-13`（28 项）+ `BY-3c..BY-3e`（3 项）；CI mojo 列表不变 |

## 7. 验收（2026-09-12）

- Mojo 自测全绿（CI 列表 9 模块 + `params_typed` + `body_validate_test`（+13 组断言））。
- e2e **733 → 768/768 全绿**（新增 `MX-1a..MX-13`：ctx/msg/multiple_of/首违序/
  codepoint len/列表单复数/short-circuit/元素 idx/enum ctx/input 类型化/多字节
  form·数组·cookie 不崩溃；`BY-3c..BY-3e`：负号 int/float 修复回归）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed / 4 ignored**
  （本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings` = **0**。
- `./benchmark.sh` 6 场景 0 errors；`ldd build/fastapi_mojo` 仅 libc；
  `env -i` 干净启动（`/health` 200）；binary 5,204,416 B（≤ 6 MiB）；
  `find src -name '*.c'` = 0；`*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。

## 8. 后续缺口（本决策未覆盖，另立 ADR）

1. 多字节 UTF-8 字节下标审计其余面：`redirect_slashes.mojo:31`（raw 多字节
   **path** 崩溃，实测 `curl --path-as-is /café` → server 崩溃）、
   `params_query.url_decode_path`、`param_constraints`（query/path/header 裸多字节）。
2. 原始非 ASCII 查询/form 值 parity（上游 `café` vs 本实现 `caf?`）。
3. Content-Type 分派 parity（`model_attributes_type`，见 §5）。
4. `inf`/`nan` float JSON 渲染语义（上游 500）。
