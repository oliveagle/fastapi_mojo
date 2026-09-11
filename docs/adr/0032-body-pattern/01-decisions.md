# ADR-0032: body pat=REGEX 约束 + PATCH+body 解析 — body 校验词表扩充（决策-57）
# （Goal-0003 矩阵 #1（PATCH+body）+ #4/#20（body 约束词表: regex pattern）；闭环 ADR-0014 文档化偏差）

## 1. 背景

ADR-0014（决策-38）落地 Pydantic 式 body 校验（`_body_schema` 声明式 spec），但明确记录两处
文档化偏差（§3.5 / §4）：
- **无 regex `pattern` 约束**（「Mojo 1.0.0 无 regex 标准库；P2，需 Rust bridge」）— body 字段
  约束词表仅有 gt/ge/lt/le/len/items；
- **PATCH + body 不解析**（「`validate_body_schema` 接受 PATCH，但 dispatch 的 body 解析仅
  POST/PUT（既有行为，与 form 解析一致）—— PATCH + body 当前不解析」）。

Pydantic `Field(pattern=...)` 是 FastAPI 声明式校验的核心字符串约束（OpenAPI `pattern` 键）。
决策-54（ADR-0029）已为参数面手写 `bridge/regex.rs`（re.search 语义：literal/escape/类/量词/
组/alternation/锚/\b，无反向/环视，步数 DoS 上限；FFI `regex_match`，长期生产验证）。
本决策（**决策-57**）复用同一引擎把 `pat=` 落到 body 面，并同时闭环 PATCH+body 偏差
（一行方法集扩展），使「body 约束词表 + PATCH body」更贴近上游。

## 2. 候选方案

| 方案 | 说明 | 判定 |
|------|------|------|
| A. 引入 regex crate（fancy-regex / regex-lite） | 快，但违反「零第三方」红线，ldd/static-libgcc 风险 | ❌ 拒（零依赖 North Star, §1/§3.1） |
| B. Mojo 内手写 NFA | Mojo 1.0.0 无闭包/复杂控制流，成本高；ADR-0029 已有 Rust 引擎 | ❌ 重复造 |
| C. 复用 `bridge/regex.rs` FFI（参数面同款） | 零新 FFI 导出（复用 ADR-0029 `regex_match`）、零新依赖、与参数面语法对称 | ✅ 采纳 |

## 3. 决策

### 3.1 body 约束词表：`pat=REGEX`（仅 str 标量）
- spec：`name:str|pat=<regex>`（与 gt/len/items 同 k=v CSV；值可含 `=`/`{}`，`,` = 歧义，
  文档化 —— 与参数面同款 `_split_top` 括号深度切分）。
- 运行期：`_apply_constraints` 增 `pat` 分支 — 仅对 `str` 标量生效（非 array/enum/obj）；
  `_body_rgx_match(pat, raw)` FFI（bridge/regex.rs）→ 0 = 不匹配 → 422 detail
  （loc/msg/type/input，**type = `string_pattern_mismatch`**，msg =
  `String should match pattern '<pat>'` — Pydantic v2 上游消息措辞）。
- FFI 返回 -1（编译失败）→ 跳过（防御；编译错误 pattern 由注册期 fail-fast 拦截）。

### 3.2 注册期 fail-fast
- `check_body_schemas` → `_check_body_spec`（递归进嵌套 obj）：`pat=` 用于非-str / 数组 / enum
  → 启动即 fail（`body_schema: pat= 约束要求 str 标量字段`）（check_* 同 fail-fast 策略，
  不带入请求路径）。
- `_parse_field` 约束语法检查把 `pat` 加入已知键集（空 pattern → `bad`）。

### 3.3 OpenAPI
- `_openapi_field_schema`（body）对 str 字段发 `pattern` — **位于 minLength/maxLength 之后**，
  键序遵 ADR-0029 §3.5（type, [enum], minLength, maxLength, pattern, …）；值经 `json_escape`。

### 3.4 PATCH + body
- dispatch body 解析 `if (method == "POST" or method == "PUT")` → `or method == "PATCH"`（1 行）。
- `validate_body_schema` 本就接受 POST/PUT/PATCH（ADR-0014）；值注入（`body_<name>`）
  非方法门控 → **PATCH+body 闭环**。
- form/multipart 路径不变（PATCH 带 form 罕见，文档化）。

### 3.5 FFI 表面 = **不变（diff 0）**
- 复用既有 `regex_match(pattern, s) -> i32` 导出（ADR-0029 新增）；零新导出；
  `build_single.sh` 零改动。

### 3.6 文档化剩余（vs 上游 Pydantic）
- **无 `@field_validator` 闭包 / 自定义类型 / model_serializer**：Mojo 1.0.0 无闭包/函数指针
  （ADR-0014 §3 同款）— P2，硬边界。
- **无数组元素级约束**（本次仅元素类型 + `items` 数量；逐元素 pattern/len 未做）— P2。
- **array/enum/obj 上无 pattern**（本决策 pat = str 标量 only，非-str 注册期拒）— P2。

## 4. 风险

- regex 引擎 = ADR-0029 的 backtracking 子集（无反向/环视），DoS 上限已内置；body pat 复用
  → 风险画像同参数面（参数面长期生产验证）。
- PATCH+body 扩展仅影响 PATCH 请求路径（e2e 454/454 验证无回归）。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | body_validate → {body_schema, handler, router, params_*, json, std.ffi}（既有边）；无新模块边（FFI = 既有 bridge 符号）；无环 |
| 2. 模块 < 500 行 | ✅ 遵守 | body_validate 373 / body_schema 322 / openapi_schemas 286（均 <500）；http_server_final 1837 = 已接受 hub-file 例外（+11 行, 2 demo 路由） |
| 3. FFI 表面 | ✅ 不变（diff 0） | 复用 ADR-0029 `regex_match` 导出；零新导出；PATCH+body = 纯 Mojo 条件改动（零 FFI） |
| 4. 零新依赖 | ✅ 遵守 | regex = 既有手写 Rust std 引擎（无 regex crate）；零新 crate；ldd 仍仅 libc（无新内建函数） |
| 5. 单 binary 不变式 | ✅ 遵守 | `build_single.sh` 零改动；ldd 仅 libc；env -i 干净启动（health 200, 无孤儿）；binary 4,085,904 B ≤ 4.2M（+4KB vs 决策-56） |
| 6. 声明式世界观 | ✅ 遵守 | `pat=` = `_body_schema` 内声明式数据（ADR-0004 范式）；注册期 fail-fast；无闭包/函数指针（Mojo 1.0.0 同款）；handler 无感（String dict 注入） |

## 7. 验收（门禁实测，2026-09-11）

- **7.1 单 binary / ldd / env -i**：`./build_single.sh`（零改动）→ `build/fastapi_mojo`
  = **4,085,904 B**（≤4.2M）；`ldd` = **仅 libc**；
  `env -i PATH=/usr/bin:/bin ./build/fastapi_mojo --port N` **干净启动**
  （health 200 `{"status":"healthy",...}`，SIGTERM 优雅退出，**无孤儿**）。
- **7.2 质量门禁**：`cargo test --release -- --test-threads=1` =
  **fastapi_mojo_rs 453 passed / 0 failed / 4 ignored（不变）**；
  `cargo clippy --release --tests -- -D warnings` 双 crate = **0 警告**。
- **7.3 e2e（BP-\* / PATCH-B\*）**：`./scripts/e2e_test.sh` —
  BP-1a 有效 `{"code":"abc123"}` → 200 + `"body_code": "abc123"` ✅；
  BP-1c 无效 `{"code":"ABC!"}` → **422** ✅；
  BP-1d 422 detail **type = `string_pattern_mismatch`** ✅；
  BP-1e `/openapi.json` 含 **`"pattern":"^[a-z0-9]+$"`** ✅；
  PATCH-B1a `PATCH /bs/patch {"note":"hello"}` → 200 + `"body_note": "hello"` ✅（PATCH+body 闭环）；
  **e2e 总数 447 → 454（454 passed / 0 failed，无回归）**。
- **7.4 性能**：`get_root` 热路径不变（body 解析条件仅增 PATCH 分支，GET 不受影响）；
  bench 非 CI 门禁（决策-22 Track B = fmtool），本轮未重跑 — CI e2e + 体积预算守护。

## 8. 实现期修复（本 ADR 落地偏差记录）

1. `as_c_string_slice` 是 mutating 方法 → 先拷贝到局部再调用（与 param_constraints `_rgx_match` 同款）。
2. `external_call` / `CStringSlice` 需 `from std.ffi import`（body_validate 首次用 FFI）。
3. `_parse_field` 约束语法检查须把 `pat` 加入已知键集（否则注册期报 `unknown constraint 'pat'`）。
