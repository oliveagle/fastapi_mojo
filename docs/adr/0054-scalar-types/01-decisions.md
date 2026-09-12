# ADR-0054: pydantic 内建标量类型参数（uuid/date/datetime/time/timedelta/decimal）（决策-79）

**状态**：已接受
**日期**：2026-09-12
**决策**：79（Goal-0003 P2 矩阵 — 标量类型面 / bead `fastapi_mojo-2wd`）
**关联**：AGENTS.md §3.2/§6（**决策-79**）、决策-38（enum）、决策-43（list）、
决策-45（input/collect-all）、决策-54（numlit / 约束面）、North Star（纯 Mojo 解析；
零新 FFI 符号；ldd 仅 libc）、上游 `fastapi 0.141.1` / `pydantic 2.13.4` /
`pydantic_core 2.46.4`

## 1. 背景（缺口）

本仓库此前只识别四类基础参数类型：`str/int/float/bool`（+ enum `str[a,b]` +
list `int[]`）。**pydantic 内建标量类型**（FastAPI 路由里最常见的
`uuid.UUID` / `datetime.date` / `datetime.datetime` / `datetime.time` /
`datetime.timedelta` / `decimal.Decimal`）**完全不支持**：`set_param_type(...,"uuid")`
在注册期直接 raise（`test_all.mojo` 曾以 `uuid` 为「未知类型」样例），运行期
`/repo/007` 之流原样回显字符串 —— 与上游（pydantic 强制转换 + 校验 + 422）差距明显。

上游行为（`GET /x/{v}` 实测，system python）：

| 类型 | 接受 | OpenAPI schema | 422 `type` | 422 `msg` 前缀 |
|---|---|---|---|---|
| `uuid.UUID` | 连字符/简单/花括号/`urn:uuid:`；输出小写 | `{"type":"string","format":"uuid"}` | `uuid_parsing` | `Input should be a valid UUID, …`（+ ctx.error） |
| `datetime.datetime` | ISO（`T`/空格/`_` 分隔、`Z`、`±HH:MM`）、epoch 数值 | `{"type":"string","format":"date-time"}` | `datetime_from_date_parsing` | `Input should be a valid datetime or date, …`（+ ctx） |
| `datetime.date` | `YYYY-MM-DD` 或零时刻 datetime | `{"type":"string","format":"date"}` | `date_from_datetime_parsing` / `date_from_datetime_inexact` / `date_parsing` | 见 §3.3 |
| `datetime.time` | `HH:MM[:SS[.frac]][tz]` | `{"type":"string","format":"time"}` | `time_parsing` | `Input should be in a valid time format, …`（+ ctx） |
| `datetime.timedelta` | ISO-8601 duration、`[N day[s]][, H:MM:SS]`、`H:MM:SS` | `{"type":"string","format":"duration"}` | `time_delta_parsing` | `Input should be a valid timedelta, …`（+ ctx） |
| `decimal.Decimal` | Python `Decimal(s)` 语法 | `{"anyOf":[{"type":"number"},{"type":"string","pattern":…}]}` | `decimal_parsing`（非有限数 -> `finite_number`） | `Input should be a valid decimal`（**无 ctx**） |

**错误体形状**（house 键序 `loc,msg,type,input[,ctx]`，与决策-45 一致）：

```json
{"type":"uuid_parsing","loc":["path","id"],
 "msg":"Input should be a valid UUID, invalid character: found `n` at 1",
 "input":"nope","ctx":{"error":"invalid character: found `n` at 1"}}
```

## 2. 目标

1. 纯 Mojo 解析六类标量（**零新 FFI 符号**、零第三方 crate、零 C）；
2. 参数面（path/query/list/header/form/body）统一校验：接受/拒绝对齐上游，422
   错误对象 `type/msg/ctx` 对齐（常见分支逐字节）；
3. OpenAPI 3.0 schema 输出 `format`（decimal 用 anyOf）；
4. 保持 North Star（`ldd` 仅 libc、binary ≤ 6 MiB、单二进制）。

## 3. 决策

### 3.1 新模块（纯 Mojo，叶子）

| 模块 | LOC | 职责 |
|---|---|---|
| `date_types.mojo` | ~320 | `DtParse` + `bof`（字节安全取值）+ `parse_datetime`（ISO + epoch）/ `parse_date` / 闰年 / civil_from_days |
| `time_types.mojo` | ~250 | `parse_time` / `parse_timedelta`（ISO duration + 人类格式；`<- date_types`） |
| `scalar_types.mojo` | ~300 | `scalar_canonical`/`is_scalar_type`/`parse_scalar`（dispatch + uuid + decimal）+ `scalar_openapi_schema` + `scalar_error_object` |

依赖方向单向无环：`{params_typed, body, form, openapi} → numlit → scalar_types →
{date_types, time_types, json}`。

`parse_scalar(name, raw) -> ScalarParse{ok, value, err_type, err_msg, err_sub}`：
成功给规范化字面量（uuid 小写）；失败给 422 三字段；`scalar_error_object(loc, raw, r)`
拼完整 JSON 对象（`err_sub != ""` 才带 `ctx.error`，decimal 无 ctx）。

### 3.2 uuid 算法（对齐 pydantic 内建 uuid 解析器）

`{…}` 前缀（offset 1）/ `urn:uuid:` 前缀（offset 9）剥离；逐字符扫描：多字节字符 →
`Char(char, index+offset+1)`（1-based、字节索引）；`-` 计数且记录前 4 个分界；非 hex
ASCII → `Char`。随后：`hyphen==0 && 无前缀 && len==32` → 合法（输出小写）；`hyphen==0
&& 无前缀 && len!=32` → `invalid length: expected length 32 for simple format, found N`；
`hyphen!=4` → `invalid group count: expected 5, found {hyphen+1}`；否则按
`BLOCK_STARTS=[0,9,14,19,24]` / 组长 `[8,4,4,4,12]` 校验，末组 len = `full_len-24`。

### 3.3 date/datetime/time/timedelta

- **datetime**：epoch 数值串（整数/浮点，年份守卫 1..9999）→ `_from_epoch`（Hinnant
  civil_from_days）；否则 ISO：`YYYY-MM-DD`（4-2-2）+ 可选 `T t 空格 _` 分隔 +
  `HH:MM[:SS[.frac]]` + 可选 `Z z` / `±HH[:]MM`。子错误串对齐上游常见分支
  （`input is too short` / `invalid character in year` / `invalid date separator, expected `-`` /
  `month value is outside expected range of 1-12` / `day value is outside expected range` /
  `unexpected extra characters at the end of the input` …）。
- **date**：10 字符纯 `YYYY-MM-DD` 特判（`year==0` → `date_parsing`「year 0 is out of
  range」；月份/日越界 → `date_from_datetime_parsing`）；否则走 datetime，全零时刻 →
  合法，非零 → `date_from_datetime_inexact`。
- **time**：`HH:MM[:SS[.frac]][tz]`，子错误 `invalid character in hour` / `hour value is
  outside expected range of 0-23` / `minute value …` / `second value …` /
  `second fraction digits missing after `.`` / `invalid timezone hour|minute`。
- **timedelta**：ISO duration（`P[nY][nM][nW][nD][T[nH][nM][nS]]`；`P1M`=30d、`P1Y`=365d）
  或人类格式（`[N day[s]][, H:MM:SS]` / `H:MM:SS`）；子错误含 `input is too short` /
  `quantity invalid in date part of duration` / `invalid digit in duration` /
  `"day" identifier in duration not correctly formatted` / `durations may not exceed
  999,999,999 days|hours`。
- **decimal**：可选首尾 ASCII 空白 + 符号 + `digits/underscore` + `.` + 指数；≥1 数字。
  `inf/nan`（带符号/`infinity`）→ `finite_number`「Input should be a finite number」；
  其余非法 → `decimal_parsing`「Input should be a valid decimal」（无 ctx）。

### 3.4 接线（声明式，核心零改动）

1. `numlit.parse_base` 识别六类标量名（别名大小写不敏感，含 `duration`→timedelta）；
   `parse_typed_value` 委派 `parse_scalar`（int/float/bool/str 路径不变）。
2. `params_typed._vpc_one` / `params_query_extra.validate_list_values` /
   `param_constraints_run._hdr_parse_err` / `form_params`（标量 + list 元素）/
   `body_schema._parse_field` + `body_validate`（顶层 + 数组元素）均按 `is_scalar_type`
   分流到 `scalar_error_object`。
3. `openapi_schemas`（param/header/field/array-elem）+ `form_params`（form 字段）
   输出 `format`/anyOf schema。
4. `test_all.mojo`：注册拒绝样例由 `uuid` 改 `nope`，新增 uuid/date 注册成功断言。

### 3.5 已知偏差（相对上游）

| 偏差 | 说明 | 影响 |
|---|---|---|
| handler 回显不归一化 | path/query 校验通过后 handler 仍收到**原始字符串**（既有 int/float house 行为；`/calc/007` 一直回显 `007`） | 与上游 pydantic 强制转换后输出（`7`/小写 uuid）不同；归一化会改动既有 e2e 语义，单列后续决策 |
| path 参数不做 URL 解码 | `parse_path_params` 既有行为（`%7B` 不解码）——非本决策引入 | path 段里的花括号/空格需放 query（已解码）；后续可单独修 |
| 少量 speedate 畸形分支 | `"4 seconds"` 类多词单位、极端 epoch 年份等回退到最近观察行为 | 常见合法/畸形输入逐字节对齐（SC-1..37 覆盖） |
| decimal 非 ASCII 数字 | 上游 Python `Decimal` 接受全角数字等；本实现仅 ASCII | 罕见输入 |
| OpenAPI 参数无 `title` | 既有 house 约定（参数 schema 不带 title） | 非本决策引入 |

## 4. 上游探测证据（fastapi 0.141.1 / pydantic 2.13.4 / pydantic_core 2.46.4）

```
uuid  'nope'        -> uuid_parsing  "…invalid character: found `n` at 1" ctx.error 同
uuid  ''            -> uuid_parsing  "…invalid length: expected length 32 for simple format, found 0"
uuid  '{}'          -> uuid_parsing  "…invalid group count: expected 5, found 1"
uuid  '…-…-…-…-11'  -> uuid_parsing  "…invalid group length in group 4: expected 12, found 11"
date  '2024-01-32'  -> date_from_datetime_parsing "…day value is outside expected range"
date  '0000-01-01'  -> date_parsing        "…valid date in the format YYYY-MM-DD, year 0 is out of range"
date  '2024-01-02T03:04:05' -> date_from_datetime_inexact "Datetimes provided to dates should have zero time - e.g. be exact dates"
dt    'x'           -> datetime_from_date_parsing "…input is too short"
time  '25:00:00'    -> time_parsing "…hour value is outside expected range of 0-23"
td    'x'           -> time_delta_parsing "…invalid digit in duration"
dec   'abc'         -> decimal_parsing "Input should be a valid decimal"（无 ctx）
dec   'nan'         -> finite_number  "Input should be a finite number"
OpenAPI: uuid/date/date-time/time/duration = {"type":"string","format":…};
         decimal = {"anyOf":[{"type":"number"},{"type":"string","pattern":"^(?!^[-+.]*$)[+-]?0*\\d*\\.?\\d*$"}]}
```

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `scalar_types → {date_types, time_types, json}`；`numlit → scalar_types`；`{params_typed, body, form, openapi} → numlit/scalar_types`，单向无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 解析 = 纯 Mojo 域层（无 FFI/无 fd/env）；仅 OpenAPI 片段字符串拼接 |
| 3. God package 阈值 | ✅ 遵守 | `date_types.mojo` 317 / `time_types.mojo` 248 / `scalar_types.mojo` 297 均 <500；`scalar_types_selftest.mojo` 独立自测 |
| 4. 主题域边界清晰 | ✅ 遵守 | date/time/timedelta/uuid/decimal 解析与错误串归 `*_types`；接线（分流 + 错误对象）在各消费模块局部点；OpenAPI 片段归 `scalar_types` |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出/零新 crate/零 C）；Mojo 1.0.0 `String[byte=i]` 在码点内会 assert → `bof()` 经 `as_bytes()` 取原始字节（多字节输入安全） |
| 6. 测试文件跟随 | ✅ 遵守 | `scalar_types_selftest.mojo`（约 60 断言：六类合法/畸形 + 错误 type/msg/ctx + OpenAPI 片段）；e2e `SC-1..SC-37` 覆盖 path/query/list/body/form/header/OpenAPI |

## 6. 验收（2026-09-12）

- Mojo 自测全绿（含新 `scalar_types_selftest`）：json/params_query/params_json/router/
  string_builder/params_query_extra/mw_spec/ws_protocols + `scalar_types_selftest`
  + `params_typed`/`body_validate_test`。
- e2e **609 → 664/664 全绿**（新增 `SC-1..SC-37`：uuid 合法/简单/花括号/urn/错误
  对象、date 闰年/year0/inexact/day-range、datetime ISO/Z/epoch、time、timedelta、
  decimal（无 ctx）、query collect-all + 默认注入、list 标量（带下标 loc）、JSON body
  标量（错误 + 缺失）、form 标量、header 标量、OpenAPI format/anyOf/body 组件）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed / 4 ignored**
  （FFI diff=0，无新 Rust 测试）；fmtool **35/0**；双 crate clippy `-D warnings` = **0**。
- `./benchmark.sh` 6 场景 0 errors（get_root_10k_100c ≈ 32.6k req/s）。
- `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动 health 200；
  binary **5,151,168 B（5.0 MiB，≤ 6 MiB）**；`find src -name '*.c'` = 0；
  `*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。
