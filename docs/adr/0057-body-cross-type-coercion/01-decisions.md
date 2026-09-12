# ADR-0057: body JSON 跨类型标量强制转换（决策-82）

**状态**：已接受
**日期**：2026-09-12
**决策**：82（Goal-0003 对标矩阵 #4 body model 字段取值规范化 / bead `fastapi_mojo-g3p`）
**关联**：AGENTS.md §3.2/§6（**决策-82**）、决策-81（ADR-0056 lax 标量强制）、
决策-38/61（body_schema / 递归 model 校验）、决策-79（标量类型 echo 契约）、
North Star（纯 Mojo 逻辑；FFI diff = 0；zero new crate；zero Rust/C 改动）、
上游 `fastapi 0.141.1` / `pydantic 2.13.x`

## 1. 背景（缺口）

决策-81（ADR-0056）把 int/float/bool 的 **string → 标量** lax 强制铺到全部输入面，
但 **body JSON model 字段**仍只接受「同族」JSON 类型：`int` 字段只收 JSON
`int`/`string`，收到 JSON float `7.0` 或 bool `true` 直接 422 `int_parsing`。
上游 pydantic v2 的 **model lax** 会**跨 JSON 类型**强制（`7.0`→7、`1e2`→100、
`true`→1、`7.5`→`int_from_float`、`null`→`int_type`），数组元素亦逐元素同规则。
这是「body model 字段取值规范化」的最后一维。

## 2. 目标

对 body JSON model 的 `int` / `float` / `bool` 标量字段**及数组元素**，用
pydantic v2 model lax 语义跨 JSON 类型强制，并把规范化值回写（handler 与
`body_*` 注入看到上游等价取值）：

- `int` ← JSON float **整值**（`7.0`→`7` / `1e2`→`100` / `-3.0`→`-3`）/
  JSON bool（`true`→`1` / `false`→`0`）/ JSON string（`parse_int_lax`）。
  非整 float → **`int_from_float`**（`Input should be a valid integer, got a
  number with a fractional part`）；`null` / `{}` / `[]` → **`int_type`**。
- `float` ← JSON int / bool（`1`→`1.0` / `true`→`1.0`）/ string；`null` →
  **`float_type`**。
- `bool` ← JSON int/float 的 `0`/`1`（`1`→true / `0`→false / `1.0`→true /
  `-0.0`→false）；其它数值（`2`/`2.0`/`-1`）→ **`bool_parsing`**；
  `null` → **`bool_type`**；JSON bool/string 走 lax 集。
- 数组元素（`int[]`/`float[]`/`bool[]`）**逐元素**同规则；规范化后重建 JSON
  文本回显（`[7.0,1e2,true,"7"]` → `[7,100,1,7]`）。

## 3. 实现（纯 Mojo；核心零改动）

1. **`body_coerce.mojo`（新文件，111 LOC）**：拆出 `_coerce_body_scalar` /
   `_elem_type_err` / `_elem_json_type`（保持 `body_validate.mojo` < 500 God 阈值：
   拆分边界 = 纯字符串/数值变换，无 FFI / fd / env）。
   **`_coerce_body_scalar(tn, t, raw)`**：单一跨类型强制点。
   `tn` = 目标类型；`t` = 元素/字段 JSON 类型标签（`params_json` 同规则）；
   `raw` = JSON 值文本（string 已 unquote）。返回 `(ok, canonical, msg, type)`。
   - `int`：JSON bool → `1`/`0`；JSON float → `_parse_f64` + `Int()` +
     `Float64(iv)==f` 整值判定（成功 → `String(iv)`，否则 `int_from_float`）；
     其余 → `parse_typed_value("int", raw)`（失败 → `int_parsing`）。
   - `float`：JSON bool → `1.0`/`0.0`；其余 → `parse_typed_value("float", raw)`
     （失败 → `float_parsing`）。
   - `bool`：JSON int/float → `0`/`1` 判定（`num==0.0`→`false` / `num==1.0`→
     `true`，否则 `bool_parsing`）；其余 → `parse_typed_value("bool", raw)`。
2. **`body_validate._type_err` 裸类型错**：int/float/bool 的 message/type 改为
   裸 `int_type`/`float_type`/`bool_type`（仅用于**完整 JSON 类型不匹配 /
   null / object / array**；parse 失败仍走 `*_parsing`）。
3. **`_validate_fields` 标量分支**：`ok_t` 放宽（int ← int/float/bool/string；
   float ← int/float/bool/string；bool ← bool/int/float/string），改调
   `_coerce_body_scalar`，成功写 `out[key]`，失败追加 `err_obj(loc, msg, type,
   _json_input_frag(raw))`。
4. **数组元素**：新增 `_elem_json_type(e)`（与 `params_json._parse_value_raw`
   同规则的 JSON 类型标签）与 `_elem_type_err(elem_t)`（裸类型错）；
   在 `is_scalar_type` 分支后插入 int/float/bool 元素跨类型强制分支
   （`null`/object/array/unknown → 裸 `*_type`；string → 先 `_strip_quotes`），
   `_apply_elem_constraints` 作用于**规范化后的值**；末尾 JSON 文本重建改用
   `_coerce_body_scalar` 逐元素规范化。
5. **嵌套/obj[] 路径**：经同一 `_validate_fields` 递归，自动继承标量跨类型强制。
6. **无 `try`（Mojo `Int(Float64)` 不 raises）**：实测整值精确、非整/超界/NaN
   截断或饱和 → `Float64(iv)==f` 为 false → 直接转换，避免「try body doesn't
   raise」警告。

核心 `run_handler` / router / FFI 零改动（决策-54 声明式扩展点延续）。

### 3.5 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| int ← JSON float 机制 | pydantic 内部 `int_from_float` 判定 | `_parse_f64` + `Int()` + 整值比较（语义等价；超界/NaN → `int_from_float`） | 罕见 |
| string → int 非整 | `"7.5"` → `int_parsing`（`unable to parse string as an integer`） | 同（string 走 `parse_int_lax`，不触发 `int_from_float`） | 无 |
| 回显 JSON 类型 | 数字/布尔为 JSON number/bool（`{"i":7}`） | String-dict 世界回显为字符串（`{"i":"7"}`） | **全局既有取舍**（String-dict 响应模型），非本决策引入 |
| 非有限 float | `inf`/`nan` → JSON 渲染 500 | 解析成功，回显字符串 `"inf"`/`"nan"` | 决策-81 既有偏差，非本轮 |
| 数组元素 JSON 文本 | 规范化后按 JSON number/bool 重新序列化 | 重建为 `[7,100,true]` 文本（String-dict `body_*` 值） | 同上 |

## 4. 上游探测证据（fastapi 0.141.1 / pydantic 2.13.4）

```
== 标量 model 字段 (cross_probe*.py) ==
int   : 7.0->7 | -3.0->-3 | 1e2->100 | true->1 | false->0 | "7.0"->7
        7.5 -> ERR int_from_float "Input should be a valid integer, got a number
               with a fractional part"
        null -> ERR int_type "Input should be a valid integer"
float : 1->1.0 | true->1.0 | false->0.0 | "1.0"->1.0 | null -> ERR float_type
bool  : 1->true | 0->false | 1.0->true | -0.0->false | "1"->true | "0"->false
        2/2.0/-1 -> ERR bool_parsing
        null -> ERR bool_type

== 数组元素 (arrprobe.py) ==
{"ints":[7.0,1e2,true,"7",-3.0]} -> [7, 100, 1, 7, -3]
{"ints":[7.5]}   -> ERR ['ints',0] int_from_float
{"ints":[null]}  -> ERR ['ints',0] int_type
{"ints":[{}]}    -> ERR ['ints',0] int_type
{"ints":[[]]}    -> ERR ['ints',0] int_type
{"floats":[1,true,"1.0"]}        -> [1.0, 1.0, 1.0]
{"floats":[null]}                -> ERR ['floats',0] float_type
{"bools":[1,0,1.0,-0.0,"1","0"]} -> [true,false,true,false,true,false]
{"bools":[2]}                    -> ERR ['bools',0] bool_parsing
{"bools":[null]}                 -> ERR ['bools',0] bool_type
```

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `body_coerce.mojo`（叶）只消费 `numlit.parse_typed_value` + `body_schema._parse_f64/_is_int_lit/_is_num_lit`；`body_validate` 单向 import `body_coerce`；body_schema 不 import 二者 → 无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串/数值变换（无 FFI / 无 fd / 无 env）；接线在 `_validate_fields` 单点，数组在同一循环内 |
| 3. God package 阈值 | ✅ 遵守 | 新增 `body_coerce.mojo`（111 LOC）承载跨类型强制（`body_validate.mojo` 触及 500 阈值 → 按拆分边界外移）；`body_validate.mojo` 437 / `body_validate_test.mojo` 175 / `body_schema_routes.mojo` 49 均 < 500 |
| 4. 主题域边界清晰 | ✅ 遵守 | 跨类型强制归 body_validate（body 域）；JSON 类型标签复用 params_json 规则；不改 params_json 本体 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出/零新 crate/零 Rust/零 C）；全部纯 Mojo |
| 6. 测试文件跟随 | ✅ 遵守 | `body_validate_test.mojo` 新增 10 组断言（标量 + 数组 + null）；e2e 新增 `BY-1a..BY-9b`（24 项）；CI mojo 列表不变 |

## 6. 验收（2026-09-12）

- Mojo 自测全绿（CI 列表 9 模块 + `params_typed` + `body_validate_test`（+10 组断言））；
  新增 lint 零（`body_validate.mojo:64` 的「try body doesn't raise」警告已消除）。
- e2e **709 → 733/733 全绿**（新增 `BY-1a..BY-9b`：int←float/bool/string、
  float←int/bool、bool←int/float/string；`int_from_float`/`bool_parsing`/裸
  `int_type`/`float_type`/`bool_type`；数组跨类型规范化重建 + 逐元素错误定位）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed / 4 ignored**
  （本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings` = **0**。
- `./benchmark.sh` 6 场景 0 errors；`ldd build/fastapi_mojo` 仅 libc；
  `env -i` 干净启动（`/health` 200）；binary ≤ 6 MiB；
  `find src -name '*.c'` = 0；`*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。
