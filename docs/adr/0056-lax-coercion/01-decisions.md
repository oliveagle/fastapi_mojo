# ADR-0056: lax 标量强制转换 + 规范化回显（决策-81）

**状态**：已接受
**日期**：2026-09-12
**决策**：81（Goal-0003 对标矩阵 #2 参数取值规范化 / bead `fastapi_mojo-vg4`）
**关联**：AGENTS.md §3.2/§6（**决策-81**）、决策-45/54（numlit / 类型化参数）、
决策-79（标量类型 echo 契约）、决策-80（path 解码）、North Star
（纯 Mojo 逻辑；FFI diff = 0；zero new crate；zero Rust/C 改动）、
上游 `fastapi 0.141.1` / `pydantic 2.13.x`

## 1. 背景（缺口）

此前本仓库对类型化参数（int/float/bool）只做**合法性校验**，成功路径**原样回显
请求字符串**（`/calc/007/4` → `{"a": "007"}`）。上游 pydantic v2 默认 **lax
模式**：把字符串强制转换为目标标量类型再回显（`/calc/007/4` → `{"a": 7}`，
路径/查询/header/form/body 一致）。缺失这一维 = 「类型化参数的取值规范化」。

## 2. 目标

对所有类型化输入面（path / query / header / form / body JSON model 字段）的
`int` / `float` / `bool` 参数，用 pydantic v2 lax 语义解析，并把**规范化后的
值**回写，使 handler 与响应注入（`query_*` / `form_*` / `header_*` / `body_*`）
看到与上游等价的取值：
- `int`：`007`→`7`、`+5`→`5`、`-0`→`0`、`-0007`→`-7`、`1_0`→`10`（`_` 数字
  分隔）、**整值小数** `2.0`→`2`、`12.00`→`12`；拒绝 `1e2` / `0x10` / `2.5` /
  `2.` → `int_parsing`。
- `float`：`1.50`→`1.5`、`1e3`→`1000.0`、`007.0`→`7.0`、`-0.0`→`-0.0`、
  `1.`→`1.0`、`.5`→`0.5`、`1_0.5`→`10.5`、纯 int `42`→`42.0`；非有限
  `inf`/`nan` 解析成功（渲染偏差见 §3.5）。
- `bool`：pydantic lax 集（大小写不敏感）`true/t/yes/y/on/1` → true；
  `false/f/no/n/off/0` → false；`2`/`+1` → `bool_parsing`。
- `str` / enum / 标量类型（uuid/date/datetime/time/timedelta/decimal）**保持
  raw 回显** —— 决策-79 标量 echo 契约不变（如 SC-26 大写 UUID 原样）。

## 3. 实现（纯 Mojo；核心零改动）

1. **`numlit.parse_int_lax(s)`（新）**：`[+-]?` + 数字（`_` 必须夹在数字之间）+
   可选**全零小数**（`.` 后 ≥1 位且全为 `0`）；规范化去 `+` / 前导零 / `-0`→`0`
   / 丢全零小数。
2. **`numlit.parse_float_lax(s)`（新）**：可选符号 + `inf/infinity/nan`
   （大小写不敏感，带符号）+ 十进制文法（前导/尾随点、`_`、指数）或纯 int；
   规范化 = `Float64` → `String`（实测与 CPython `repr` 逐字节一致：`1000.0` /
   `1e+16` / `1e-05` / `-0.0` / `0.3333333333333333`）。
3. **`numlit.parse_bool_literal` 扩集**：改为 pydantic lax 集（大小写不敏感，
   经私有 `_lower_ascii`）。
4. **`numlit.parse_typed_value` 委派**：`int`→`parse_int_lax`，
   `float`→`parse_float_lax`（`bool`→扩集后的 `parse_bool_literal`）。
5. **`params_typed.canonicalize_typed_values`（新）**：dispatch 成功路径在
   `apply_query_extras` **之后**调用，把 int/float/bool 的规范化值回写
   `route_result.params`（path）与 `query_params.values`（query，含 alias key
   `key` 与原始名 `k` 两处；list 逐元素规范化 CSV）。
6. **`form_params.apply_form_extras`**：form 标量 last-wins + list CSV 逐元素
   规范化（int/float/bool）；`str`/标量类型跳过。
7. **`param_constraints_run.validate_headers_collect`**：typed header 在场值 /
   list header 注入规范化值（缺失+默认本就走 `parse_typed_value`，已是规范值）。
8. **`body_validate._validate_fields`**：int/float/bool 标量 model 字段接受
   JSON string（pydantic lax，`"007"`→`7`），写入 `parse_typed_value` 结果；
   解析失败 → 与上游同款 `int/float/bool_parsing`；int/float/bool 数组元素
   重建 JSON 文本时逐元素规范化。
9. **`param_constraints.parse_constraint_entry`**：约束数值字面量用
   `parse_int_lax/parse_float_lax` 校验（注册期，接受 `+3`/`1_0` 等）。
10. **OpenAPI 默认值**（`openapi_schemas`）经 `parse_typed_value` 自动规范化。

核心 `run_handler` / router / FFI 零改动（决策-54 声明式扩展点延续）。

### 3.5 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| body JSON **float/bool → int** | `int` 字段收到 JSON `7.0` → 7；`7.5` → `int_from_float`；`true` → 1 | `ok_t` 仅接受 JSON `int`/`string`（`7.0` 仍 422 `int_parsing`） | 罕见；JSON 数字用整值写即可 |
| body JSON **float/bool → float** | `float` 字段收到 `true` → 1.0 | 仅接受 JSON `int`/`float`/`string` | 罕见 |
| body JSON **int → bool** | `bool` 字段收到 `1` → true | 仅接受 JSON `bool`/`string` | 罕见 |
| 非有限 float 渲染 | `inf`/`nan` → JSON 渲染 500 | 解析成功，回显字符串 `"inf"`/`"nan"` | 非有限值不可 JSON 序列化；上游 500 |
| 回显 JSON 类型 | 数字/布尔为 JSON number/bool（`{"a":7}`） | String-dict 世界回显为字符串（`{"a":"7"}`） | **全局既有取舍**（String-dict 响应模型），非本决策引入 |
| 约束错误 `input` | 原值 | 原值（String 化），`"007"` 等 stringified number 可能渲染为裸 token | 仅约束错误 detail 的极端输入 |
| int `_` 小数 | `1_0.5` 对 int → `int_parsing` | 同（小数非全零拒绝） | 无 |

## 4. 上游探测证据（fastapi 0.141.1 / pydantic 2.13.x）

```
== int path (probe2) ==
1_0  -> 200 {"v":10}        %2B5 -> 200 {"v":5}      +5 -> 200 {"v":5}
-0   -> 200 {"v":0}         007  -> 200 {"v":7}      -3 -> 200 {"v":-3}
2.0  -> 200 {"v":2}         12.00-> 200 {"v":12}     2.5 -> 422 int_parsing
2.   -> 422 int_parsing     .0   -> 422 int_parsing
0x10 -> 422 int_parsing     1e2  -> 422 int_parsing

== int/query/bool (probe) ==
/typed?count=007&verbose=true  -> 200 {"count":7,"verbose":true}
/typed?count=%2B5&verbose=false-> 200 {"count":5,"verbose":false}
/typed?count=-0&verbose=1      -> 200 {"count":0,"verbose":true}
/typed?count=1e2&verbose=yes   -> 422 int_parsing
/typed?count=0x10&verbose=on   -> 422 int_parsing

== float ==
1.50->1.5   1e3->1000.0   007.0->7.0   -0.0-> -0.0   1.->1.0   .5->0.5   42->42.0
1_0.5->10.5   inf/nan -> 解析成功但 JSON 渲染 500     abc -> 422 float_parsing

== bool (probe2) ==
yes/no/on/off/t/f/y/n/TRUE/1/0 -> 200;  "+1"/"2" -> 422 bool_parsing

== list ==
/list?tags=01            -> 200 {"tags":[1]}
/list?tags=1&tags=2      -> 200 {"tags":[1,2]}

== body (model 字段, pydantic) ==
{"q":"007","f":"1.50","b":"true"}    -> {"q":7,"f":1.5,"b":true}
{"id":"7"} (int field)               -> 7   (string -> int lax)
{"q":"abc"}                          -> 422 int_parsing
```

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `parse_*_lax` 在 numlit（叶子）；`canonicalize_typed_values` 在 params_typed（已 import params_query_extra，`join_values` 无环）；form/header/body 消费点单向 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串/数值变换（无 FFI / 无 fd / 无 env）；接线在 dispatch 成功路径单点 |
| 3. God package 阈值 | ✅ 遵守 | 无新文件；`numlit`(+~40) / `params_typed`(+~55) / `form_params`(+~20) 均 < 500 |
| 4. 主题域边界清晰 | ✅ 遵守 | 字面量原语归 numlit；回写归一化归 params_typed；form/header/body 各域自持 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出/零新 crate/零 Rust/零 C）；全部纯 Mojo |
| 6. 测试文件跟随 | ✅ 遵守 | `params_typed.main()` 新增 20+ 断言；`test_all.mojo` 更新；e2e 新增 `CX-1..CX-21`（+ JS-3 改写）；CI mojo 列表不变 |

## 6. 验收（2026-09-12）

- Mojo 自测全绿（CI 列表 9 模块 + `params_typed`（+20 断言）/`body_validate_test`）；
  新增 lint 零（`router.mojo` 既有 warning 非本轮引入）。
- e2e **676 → 709/709 全绿**（新增 `CX-1..CX-21`：int/float/bool path/query/
  header/form/body/list 规范化；`2.0`/`7.5` 整值小数边界；`1e2`/`0x10` 422 回归；
  JS-3 改写为 lax 接受 + 真 `int_parsing`）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed / 4 ignored**
  （本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings` = **0**。
- `./benchmark.sh` 6 场景 0 errors。
- `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动（`/health` 200）；binary ≤ 6 MiB；
  `find src -name '*.c'` = 0；`*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。
