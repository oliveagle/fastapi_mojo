# ADR-0033: 数组元素级约束（Array Element-Level Constraints）

**状态**: 已接受
**日期**: 2026-09-11
**决策**: 58（Goal-0003: 用 mojo 100% 实现 fastapi，所有功能一个不少）

## 1. 背景

ADR-0014（决策-38）body 声明式 spec 只校验数组元素**类型**（+数量 via `items` 约束），
元素级约束缺口文档化（§4:「数组元素：只校验元素**类型**（+数量 via items 约束）；
元素级约束（如 `items` 内嵌套 `len`）不做（P2）」）；ADR-0032（决策-57）闭环
「body 无 regex pattern 约束」与「PATCH+body 不解析」两偏差后，§3.6 仍留有
「无数组元素级约束（本次仅元素类型 + `items` 数量；逐元素 pattern/len 未做）— P2」。

上游 FastAPI/Pydantic v2 语义：字段为 `list[str]` 时，`Field(min_length=2, pattern=…)`
等约束**逐元素**生效（等价于 `List[constr(…)]`）；元素为 `int`/`float` 时
`ge/le/gt/lt` 同理逐元素。422 loc 携带元素下标 `["body", <field>, <idx>]`
（与既有元素类型错 loc 约定相同，e2e BS-9a 守护）。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 新 e- 前缀约束键（`elen`/`epat`/`ege`…） | 独立键区分元素级 | ❌ 词表翻倍、偏离上游命名（上游复用同名键，由元素类型决定作用对象）；解析/OpenAPI/fail-fast 三面新增一套分支 |
| B. **约束词表复用 × 类型依赖语义（本 ADR）** | `pat`/`len` 在 `str[]` 上逐元素；`ge`/`le`/`gt`/`lt` 在 `int[]`/`float[]` 上逐元素；`items` 保持数组级（元素数）；与标量字段同名同语义族 | ✅ 对齐上游（pydantic `constr`/`ConInt` 即同键作用于元素类型）；FFI diff = 0（复用决策-57 `regex_match`）；OpenAPI = 元素级键入 `items` 对象（3.0 标准形态） |
| C. `items{…}` 嵌套子 spec | items 内二级 spec 文法 | ❌ 文法复杂度爆炸（默认值/枚举/嵌套数组均需二级语义），远超实际需求（上游元素级约束 = 扁平键值） |

**决策：B** — 约束词表复用 × 类型依赖语义（决策-58）。

## 3. 决策

1. **语义（body_validate.mojo）**：
   - `pat` / `len` 在 `str[]` 字段上 → **逐元素**：元素 raw 剥外层 JSON 引号
     （`_strip_quotes`，首尾各 1 字节）→ byte 长度 / `_body_rgx_match`
     （bridge/regex.rs，复用决策-57，**FFI diff = 0**）；违约 422
     （type = `string_pattern_mismatch` / `string_too_short` / `string_too_long`，
     msg 对齐 pydantic v2）
   - `ge` / `le` / `gt` / `lt` 在 `int[]` / `float[]` 字段上 → **逐元素**：
     元素 raw 解析为数值（类型检查已过必为数字字面量）比较；违约 422
     （`greater_than` / `greater_than_equal` / `less_than` / `less_than_equal`）
   - `items` 保持**数组级**（元素数）— 不变
   - 元素类型检查失败 → 不再做该元素的约束检查（类型短路，上游同款）
   - `bool` / `obj` / 嵌套数组元素：无元素级约束（上游亦无有意义约束）
2. **422 loc**：`["body",<field>,<idx>]`（复用既有元素类型错 loc 约定）；
   `input` = 元素值（str 元素剥引号后嵌入，保 detail JSON 合法）
3. **注册期 fail-fast 加强（`_check_body_spec`）**：此前仅校验 `pat`，
   其余键与字段类型不匹配时**静默 no-op**（用户误以为约束生效 = 潜伏偏差）；
   现全量校验约束键 × 字段类型，错配 → 注册期 raise（启动即失败，决策-57 同款）：
   - `pat` / `len`：仅 str 标量（非 enum）或 `str[]`（元素级）
   - `gt` / `ge` / `lt` / `le`：仅 int/float 标量或 `int[]` / `float[]`（元素级）
   - `items`：仅数组字段
4. **OpenAPI（openapi_schemas.mojo）**：元素级约束入 **`items` 对象内**：
   str → `"minLength"` / `"maxLength"` / `"pattern"`（键序遵 ADR-0029 §3.5：
   type → [enum] → minLength → maxLength → pattern）；数值 → `"minimum"` /
   `"maximum"` / `"exclusiveMinimum"` / `"exclusiveMaximum"`（3.0 布尔形式 =
   已文档化偏差, ADR-0029 §3.8 ④）；`minItems` / `maxItems` 留数组（外层）
5. **Demo + e2e**：新路由 `/validate/elems`（POST，
   `_body_schema = "items:str[]|items=0-5,len=1-3,pat=^[a-z0-9]+$;nums:int[]|items=0-3,ge=0"`）；
   e2e BP-2a..k = 11 项（valid 200 + echo / pat 422 + loc idx / len 422 / ge 422 /
   OpenAPI items minLength+pattern / items minimum）
6. **spec 文法零改动**：约束仍是单 `|` 引出 CSV（`items=0-5,len=1-3,pat=...`
   逗号分隔）；`parse_body_schema` / `body_schema.mojo` 零改动

## 4. 风险

| 风险 | 缓解 |
|------|------|
| 元素 raw 剥引号边界（内嵌转义引号 `"a\"b"`） | 只剥首尾 1 字节；len 按 byte 计（与字段级 `len` = byte_length 既有约定一致, ADR-0014 §4）；转义序列按 raw 字节计（文档化，仅非 ASCII/转义字符串有 ±1-2 byte 偏差） |
| fail-fast 加强可能拒绝既往接受的 spec | 全部既有路由实测通过：/validate（float gt / str[] items / str 标量 len / 嵌套 len）/ /bs/pat（str 标量 pat）/ /bs/patch（无约束）；新拒绝面仅「约束键 × 类型错配」（原先静默 no-op = 本次闭环的偏差） |
| 元素级 pat 的 DoS（regex 步数） | 引擎内置匹配步数上限（ADR-0029），风险画像同参数面（长期生产验证） |

## 5. 六条架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`http_server_final`（新 /validate/elems demo 路由）→ `body_validate`（元素级校验）→ `body_schema`（spec 层, **零改动**）；`openapi_schemas` → `body_schema`（只读）；无回调上溯 |
| 2. 分层向下依赖 | ✅ 遵守 | 元素级校验 = 纯 Mojo 字符串处理 + 既有 `regex_match` FFI（bridge/regex.rs, ADR-0029/决策-57, **FFI diff = 0**）；无新 syscall |
| 3. God package 阈值 | ✅ 遵守 | `body_validate.mojo` 467 / `openapi_schemas.mojo` 312（均 < 500）；`http_server_final.mojo` 1843（既有超阈值 hub 文件例外, 本次仅 +6 行 = 1 个 demo 路由） |
| 4. 主题域边界清晰 | ✅ 遵守 | spec 层只管文法（零改动）；校验层只管 body 元素级约束（参数面元素校验 = 既有 collect-all, 未动）；OpenAPI = 文档生成（读 spec 出元素级键, 不反向写） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新 extern "C" 导出, 无 bridge/*.rs 改动）；`cargo clippy --release --tests` 0 警告（零改动验证）；`cargo test --release -- --test-threads=1` 453 passed / 0 failed / 4 ignored（Rust 零改动） |
| 6. 测试文件跟随 | ✅ 遵守 | Mojo: `body_validate.mojo` `main()` 自测 +6 项（FFI-free: fail-fast 规则 ×3 + elem len/ge 校验 ×3; pat 匹配行为走 e2e 真服务器, 自测保持 FFI-free 约定）；e2e **BP-2a..k = 11 项**（465/465 全绿, 既有 454 项零回归） |

## 6. 验收

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc；体积 **4,110,480 B**
   （≤4.2M, +24 KB vs 决策-57）；`env -i ./build/fastapi_mojo --port …` 干净启动
   health 200；`pgrep -x fastapi_mojo` = 0（无孤儿）
2. **e2e**：454 → **465/465 全绿**（+11 BP-2 项；既有 454 项零回归）
3. **质量门禁**：cargo test 453/0/4（不变）/ clippy 0（双 crate）/
   `find src -name '*.c'` = 0（保持）
4. **文档化剩余（vs 上游 Pydantic）**：
   - 无 `@field_validator` 闭包 / 自定义类型 / model_serializer
     （Mojo 1.0.0 无闭包 = 硬边界, ADR-0014/0032 同款）
   - 嵌套数组（`arr[]` / `T[][]`）无元素级约束（P2；本次元素级 = 一层）
   - OpenAPI 3.0.3 vs upstream 3.1.0（P2, ADR-0029 §3.8 ④）

## 7. 实现

- `src/fastapi_mojo/body_validate.mojo`（467 行）：`_strip_quotes`（剥外层引号）+
  `_apply_elem_constraints`（pat/len/数值逐元素）+ `_apply_constraints` len
  字段级数组跳过 + `_validate_fields` 数组分支（类型检查通过 → 元素级约束）+
  `_check_body_spec` 全量键×类型 fail-fast + 自测 +6 项
- `src/fastapi_mojo/openapi_schemas.mojo`（312 行）：`_openapi_field_schema`
  数组分支 — 元素级键入 items 对象（str: minLength/maxLength/pattern;
  数值: minimum/maximum/exclusiveMinimum/exclusiveMaximum），minItems/maxItems
  留外层
- `src/fastapi_mojo/http_server_final.mojo`（1843 行）：`/validate/elems`
  demo 路由（+6 行）
- `scripts/e2e_test.sh`：BP-2a..k（+11 项 → 465）
- `.github/workflows/ci.yml`：454→465（3 处文档级引用）
- `AGENTS.md` / `docs/goals/0003-fastapi-full-parity.md`：决策-58 bullet +
  footer 轮转 + 矩阵 #4/#20（元素级缺口销账）
