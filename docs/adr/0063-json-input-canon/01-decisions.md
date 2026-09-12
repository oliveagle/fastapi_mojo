# ADR-0063: body 422 `input` 的 CPython/Starlette 反序列化-重序列化（决策-88）

**状态**：已接受
**日期**：2026-09-13
**决策**：88（兑现 ADR-0060 §5 偏差行「顶层非 object `input` 规范化」+ §8 后续缺口
#3；Goal-0003 §1 矩阵 #4 请求体 422 detail 面）
**关联**：AGENTS.md §3.2/§6（**决策-88**）、决策-85（ADR-0060：body CT 分派 +
顶层值语义 + `body_json.mojo`）、决策-83（ADR-0058：body 422 detail 逐字段对齐）、
决策-87（ADR-0062：`fmt_f64_repr` 复用）、North Star（**FFI diff = 0**；zero new
crate；zero Rust/zero C；纯 Mojo）、上游 `fastapi 0.141.1` / `pydantic 2.13.4`
（Starlette `JSONResponse`）

## 1. 背景（缺口）

上游 FastAPI 的 422 响应由 Starlette `JSONResponse` 渲染：
`json.dumps(content, ensure_ascii=False, separators=(",", ":"), allow_nan=False)`。
pydantic error 的 `input` 是**已反序列化的 Python 对象**（`json.loads` 的结果），
因此会被**重新序列化**：

| JSON body 形态 | 上游 `input` (重序列化) | 本实现 (旧, 原始 span) |
|---|---|---|
| `[1, 2, 3]` | `[1,2,3]` | `[1, 2, 3]` |
| `{ "a" : 1 , "b" : [1, 2] }` | `{"a":1,"b":[1,2]}` | `{ "a" : 1 , "b" : [1, 2] }` |
| `1.50` / `1e2` / `-0` | `1.5` / `100.0` / `0` | `1.50` / `1e2` / `-0` |
| `"caf\u00e9"` / `"\u0041"` / `"a\/b"` | `"café"` / `"A"` / `"a/b"` | 原 span（未解码） |
| `"he said \"hi\""` | `"he said \"hi\""` | 原 span（一致） |

差异**仅形态**（语义等价），但对逐字节对比的 parity 审计是可观测缺口；ADR-0060
明确列为「顶层非 object `input` 规范化」偏差 / 后续缺口 #3。

## 2. 目标

body 422 detail 的 `input` 与上游 **Starlette `json.dumps` 重序列化**逐字节
等价（去空白 / 数字规范化 / 字符串解码重编码 / 重复键后者胜）。合法请求路径
零改变；detail 恒为合法 JSON；非有限 float / 非法 JSON 安全回退。

## 3. 实现（纯 Mojo；**FFI diff = 0**；核心 `run_handler` / router / bridge 零改动）

1. **新叶模块 `json_canon.mojo`（371 LOC）**——单遍递归下降校验 + 重序列化：
   - `canon_json(span)`：合法 JSON 值 span -> Starlette 紧凑等价串；解析失败 /
     非有限 float（上游 `allow_nan=False` -> 500，另立偏差）/ 孤立代理 /
     trailing data -> **原样返回**（安全回退，不破坏 detail JSON 合法性）；
   - `_cpython_escape`：CPython `ensure_ascii=False` 转义（`\" \\ \b \f \n \r \t`
     + `<0x20` -> `\u00XX`；非 ASCII 原样）；
   - `json_string_literal(v)`：已解码串 -> 带引号 JSON 字面量（供
     `_json_input_frag_typed` string 分支 / 非 JSON CT 原始串）；
   - 数字：float 走决策-87 `atof_f64` + `fmt_f64_repr`（`1.50`->`1.5`、
     `1e2`->`100.0`）；整数走 Python int 语义（`-0`->`0`）；对象重复键后者胜。
   - 依赖方向：`json_canon -> float_repr`（叶，单向无环）。
2. **接线**：
   - `body_constraints._json_input_frag`：识别为合法 JSON 值
     （`"`/`{`/`[`/数字/bool/null）-> `canon_json`；裸 token（坏元素 `zz`）->
     转义字符串（不变）；`_json_input_frag_typed` string 分支 -> `json_string_literal`。
   - `body_validate._body_input`（missing 的 input = 收到 body 对象）-> `canon_json`。
   - 非 JSON CT 原始串 input -> `json_string_literal`。

## 4. 测试

- **Mojo 自测** `json_canon_test.mojo`（新增；~30 断言）：空白去除（对象/数组/
  嵌套）/ 数字规范化（`1.50`/`1e2`/`1E+2`/`-0`/`-0.0`/big int）/ 字符串解码重编码
  （`\u00e9`/`\u0041`/`\/`/代理对/`\b`/`\n`/`\"`）/ 重复键后者胜 / 空容器 /
  安全回退（`zz`/`NaN`/`Infinity`/`1e999`/孤立代理/trailing/空）。
- **e2e** `JC-1..JC-12`：顶层数组/字符串串空白紧凑；`1e2`->`100.0`、
  `1.50`->`1.5`；`\u00e9`->`café`、`\u0041`->`A`；嵌套 missing input 紧凑；
  字段 `int_type` 数组/对象 input 紧凑；str 字段控制字符短转义 `"\b"`；
  含空白合法请求仍 200；非规范 input 的 detail `jsoncheck` 合法。
- **差分 fuzz**（上游 `cross_app.py` `/cross` `M{i:int,f:float,b:bool}` vs 本
  `/validate/cross`）：**2961 组非规范 JSON body，`input`/status 0 不一致**。

## 5. 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| 非有限 `inf`/`nan` | `json.dumps allow_nan=False` -> 500 | `input` 回退原 span / 顶层 `NaN`/`Infinity` 转义为字符串 | **另立**既有项（ADR-0060 §5 / ADR-0061 §8 #1），本决策不含 |
| 极冷门 CPython 转义面 | 全 U+0000-U+001F 精确 | 已覆盖 `\b\f\n\r\t` + `\u00XX` | 无已知差异 |
| 422 对象键序 / 错误体超集 | `type,loc,msg,input,ctx` / `{"detail":…}` | house 键序 + 附加字段 | 既有约定（ADR-0029 §3.7 / ADR-0058 §5） |
| `input` 超大对象性能 | CPython 全量反序列化 | 单遍校验+重序列化（同阶） | — |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `json_canon` 新叶（仅 `float_repr`）；`{body_constraints, body_validate} -> json_canon` 单向；无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串/数值变换（无 FFI / 无 fd / 无 env）；全 `as_bytes()` 字节安全；接线在既有 `input` 渲染单点 |
| 3. God package 阈值 | ✅ 遵守 | `json_canon.mojo` **371** + `json_canon_test.mojo` **54**（新文件均 < 500）；`body_constraints.mojo` 198→**206**；`body_validate.mojo` 448→**450** < 500 |
| 4. 主题域边界清晰 | ✅ 遵守 | 「JSON 值 <-> CPython 紧凑串」独占 `json_canon`（叶）；body 校验层仅消费 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出 / 零新 crate / 零 Rust / 零 C）；复用决策-87 的既有 libc `atof`/`strfromd` |
| 6. 测试文件跟随 | ✅ 遵守 | 自测与生产同目录（新 `json_canon_test.mojo`）；e2e `JC-1..JC-12`；CI mojo 列表 +`json_canon_test` |

## 7. 验收（2026-09-13）

- Mojo 自测全绿（CI 列表 11 + `params_typed` + `body_validate_test`；0 警告）。
- e2e **832 → 844/844 全绿**（新增 `JC-1..JC-12`）。
- 差分 fuzz：2961 组非规范 JSON，`input`/status 0 不一致。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed /
  4 ignored**（本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings`
  = **0**。
- `./benchmark.sh` 6 场景 0 errors（get_root_10k_100c ≈ 31.7k req/s，噪声带内）；
  `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动（`/health` 200）；
  binary **5,220,800 B**（≤ 6 MiB）；`find src -name '*.c'` = 0；
  `*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。

## 8. 后续缺口（本决策未覆盖，另立 ADR）

1. 非有限 `inf`/`nan` float JSON 渲染语义（上游 500）。
2. `response_model` `exclude_unset` / `exclude_defaults` / `by_alias`。
3. `SecurityScopes` 对象面 / `OAuth2PasswordRequestForm` 对象面。
4. `fastapi.encoders.jsonable_encoder` 等未验证小公开面。
5. OpenAPI 3.1 vs 3.0.3（本实现仍 emit `3.0.3`）。
6. multi-arch（aarch64）/ asgi-shim（P2 open beads）。
