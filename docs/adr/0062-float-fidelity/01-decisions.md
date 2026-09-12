# ADR-0062: float 正确舍入解析 + CPython `repr` 等价格式化（决策-87）

**状态**：已接受
**日期**：2026-09-12
**决策**：87（兑现 ADR-0061 §8 后续缺口 #2「float 格式化边界」+ 附带修复
`Float64(String)` 长字面量误判，Goal-0003 §1 矩阵 #4 请求体数值面）
**关联**：AGENTS.md §3.2/§6（**决策-87**）、决策-81（ADR-0056：lax 标量强制
转换 + 规范化回显，其 float 路径 `Float64`→`String` 假定 = CPython repr）、
决策-83（ADR-0058：body 422 detail `fmt_num`）、North Star（libc `atof`/`strfromd`
= 既有基础运行时符号；**FFI diff = 0**；zero new crate；zero Rust/zero C）、
上游 `fastapi 0.141.1` / `pydantic 2.13.4`（CPython `float()` + `repr()`）

## 1. 背景（缺口 / 真 BUG）

上游 pydantic v2 的 float 解析/渲染 = CPython 语义：
- **解析**：`float(s)` = `strtod`，**正确舍入（round-to-nearest-even）**；
- **渲染**：`repr(float)` = **最短且往返**（round-trip）的十进制串 + Python 记法
  （`decpt <= -4 || decpt > 16` 用科学记数，否则定点；整值补 `.0`）。

Mojo 1.0.0 两个原语都不满足：

| # | 原语 | 缺陷 | 实例 |
|---|---|---|---|
| A | `Float64(String)` | 整数部分按 **int64 累加** → >~20 位有效数字 / 长整数部分**抛错** | `Float64("12345678901234567890.0")` 失败 → 我们把 float64 范围内合法十进制误判 `float_parsing` 422；上游返回 `1.2345678901234567e+19` |
| B | `String(Float64)` | 偶发**非最短 / 不往返** | `String(7.531168259201221e+16)` = `"7.53116825920122e+16"`（15 位，回读不等）；上游 `repr` = `"7.531168259201221e+16"` |

实测（上游 `/model` `M{x:float}` vs 本实现 `/validate/cross`）：3553 比对，
**18 处不一致**（全部 Bug B 的 15 位平局）+ 若干 Bug A 的 422。

## 2. 目标

float ↔ 十进制字符串原语与 CPython 等价：解析 = 正确舍入（长字面量不再失败）；
格式化 = 最短往返 + Python 记法阈值。**FFI 表面不变**（不新增导出）；ASCII /
多字节字节安全语义不变；非 float 路径（int/bool/str/约束消息整值）零改变。

## 3. 实现（纯 Mojo + 既有 libc 符号；核心 `run_handler` / router / bridge 零改动）

1. **新叶模块 `float_repr.mojo`（194 LOC）**——零新 crate / 零 Rust / 零 C：
   - `atof_f64(s)`：`external_call["atof", Float64](slice)`（= `strtod(nptr, NULL)`，
     libc 既有符号，正确舍入）；
   - `_sfmt_e(v, sig)`：`strfromd(buf, 64, "%.{sig-1}e", v)`（libc 既有符号，
     正确舍入，两位指数）；
   - `fmt_f64_repr(v)`：**CPython `repr(float)` 等价**——取最小 `p∈1..17` 使
     `atof_f64` 回读 `== v` 的 `%.{p-1}e` 串，再按 Python 记法规则排版
     （`decpt<=-4 || decpt>16` 科学记数，否则定点；整值补 `.0`；`-0.0`→`"-0.0"`；
     `nan`/`inf`/`-inf` 直通）；
   - `is_dec_f64_syntax(s)`：**文法合法性判定**（`[+-]? (digits ('.' digits*)? |
     '.' digits+) ([eE][+-]? digits+)?` + inf/infinity/nan 家族，大小写不敏感、
     可带符号）。**必要**：`atof` 对垃圾串返回 `0.0`，不能当合法性依据；
     且比 Mojo `Float64` 更严（后者把 `"1.2.3"` 误收为 `1.23`）。
2. **`numlit.mojo`**：删本地 `atof_f64` 副本；`parse_float_lax` 走
   `atof_f64` + `fmt_f64_repr`；`parse_f64` 走 `is_dec_f64_syntax` 门 +
   `atof_f64`；`fmt_num` 非整值走 `fmt_f64_repr`。
3. **`body_schema.mojo`**：`_parse_f64` 同款（`is_dec_f64_syntax` 门 +
   `atof_f64`）—— 保 `_is_num_lit` / schema 约束数值校验语义；`fmt_num`
   非整值走 `fmt_f64_repr`。
4. **依赖方向**：`{numlit, body_schema} -> float_repr`（叶，单向无环）。

**原型验证**：该 repr 算法在 Python 侧对 **499,756 个随机 double + 边界** 与
`repr()` 比对 **0 不一致**；本实现上线后对自有 server 5857 输入（4000 随机 bit
`repr()` + 2000 长数字十进制）**0 不一致**。

## 4. 测试

- **Mojo 自测** `body_validate_test.mojo` +14 断言：repr 基本/记法阈值
  （`1e16`→`1e+16` / `1e15`→`1000000000000000.0` / `1e-4`→`0.0001` /
  `1e-5`→`1e-05`）/ `-0.0` / 往返回归（`7.531168259201221e+16`）/ `atof` 长字面量 /
  body `12345678901234567890.0`→`1.2345678901234567e+19` / 30 位→
  `1.2345678901234568e+29` / `is_dec_f64_syntax` 正反例 / `_is_num_lit` 文法门。
- **e2e** `LF-1..LF-12`：长字面量 body 解析 200 + repr；30 位；往返回归；
  记法阈值（1e16/1e15/1e-4/1e-5）；负号长字面量；float[] 元素长字面量；
  `float[]` 垃圾字符串 422 `float_parsing`（文法门）；字符串 `"1.2.3"` 422；
  约束消息非整值数字格式（`multiple of 0.5`）。

## 5. 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| 极病理输入的末位 ULP | CPython `repr` 最短往返 | 同一算法（最小往返位数）；499,756 随机 double + 5857 实测输入 0 不一致 | 未观测到差异；理论上极端平局可能不同（出范围） |
| 非有限值渲染 | `inf`/`nan` 参与 JSON 序列化 → 上游 500 | 直接回显 `"inf"`/`"nan"` | **另立**既有项（ADR-0061 §8 #1），本决策不含 |
| 语法门比 Mojo `Float64` 严 | `float("1.2.3")` → `ValueError` | `is_dec_f64_syntax` 同拒 | 是**修正**（Mojo 原误收 `1.2.3`→`1.23`）；JSON/字符串路径上游本就拒绝，无用户可见偏差 |
| `atof` 依赖 C locale | CPython `float()` 恒 `C` locale | 同（进程未设 locale） | 无 |
| 422 对象键序 / 错误体超集 | `loc,msg,type,input,ctx` / `{"detail":…}` | house 键序 + 附加字段 | 既有约定（ADR-0029 §3.7） |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `float_repr` 新叶模块（仅 `std.ffi`）；`{numlit, body_schema} -> float_repr` 单向；无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串/数值原语（无 fd / 无 env / 无路由）；仅 libc 既有符号 `atof`/`strfromd`（North Star 允许的基础运行时）；接线在 `numlit`/`body_schema` 数值解析点 |
| 3. God package 阈值 | ✅ 遵守 | `float_repr.mojo` **194** < 500（新文件）；`numlit.mojo` 458→**461**；`body_schema.mojo` 336→**339**；`body_validate_test.mojo` 375→**385** |
| 4. 主题域边界清晰 | ✅ 遵守 | 「float ↔ 十进制字符串原语」独占 `float_repr`（叶）；`numlit`/`body_schema` 仅消费，不重复实现 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出 / 零新 crate / 零 Rust / 零 C）；复用的 `atof`/`strfromd` 均为既有 libc 符号 |
| 6. 测试文件跟随 | ✅ 遵守 | 自测与生产同目录（`body_validate_test.mojo` +14 断言）；e2e `LF-1..LF-12`；无新 mojo 自测模块（CI 列表不变） |

## 7. 验收（2026-09-12）

- Mojo 自测全绿（12 模块含 `body_validate_test` / `params_typed` / …；0 警告）。
- e2e **820 → 832/832 全绿**（新增 `LF-1..LF-12`）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed /
  4 ignored**（本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings`
  = **0**。
- `./benchmark.sh` 6 场景 0 errors（get_root_10k_100c ≈ 31.1k req/s，噪声带内）；
  `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动（`/health` 200）；
  binary **5,200,320 B**（≤ 6 MiB）；`find src -name '*.c'` = 0；
  `*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。
- 上游对齐抽查（`/model` vs `/validate/cross`）：长字面量 / 30 位 / 往返回归 /
  记法阈值逐项一致。

## 8. 后续缺口（本决策未覆盖，另立 ADR）

1. 非有限 `inf`/`nan` float JSON 渲染语义（上游 500；我们回显 `"inf"`/`"nan"`）。
2. 顶层非 object `input` 的 CPython 反序列化-重序列化规范化。
3. `response_model` `exclude_unset` / `exclude_defaults` / alias（仅 include/exclude/exclude_none 已实现）。
4. `SecurityScopes` 对象面 / `OAuth2PasswordRequestForm` 对象面。
5. OpenAPI 3.1 vs 3.0.3（本实现仍 emit `3.0.3`）。
6. multi-arch（aarch64）/ asgi-shim（P2 open beads）。
