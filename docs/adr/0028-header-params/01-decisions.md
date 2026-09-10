# ADR-0028: Header 参数精化 — alias + 下划线→连字符转换
# （Goal-0003 P2 矩阵 #7：Header(...) 的 alias 面）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #7 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-53**）、Goal-0003（矩阵 #7 Header
  alias）、ADR-0004（路由 = 数据范式）、F3a（决策-28，`_reads_headers`
  注入面）、决策-43（ADR-0018，Query alias 先例 — header alias 同模式
  独立命名空间）、决策-52（ADR-0027，OpenAPI 精化 — 本 ADR 复用其
  operation parameters 面）、FastAPI 0.141.1 / starlette 1.6.0 /
  uvicorn 0.52.4（语义对标）

## 1. 背景

Goal-0003 矩阵 #7：`Header | Header(...) | ✅ desc（决策-43, _param_descs
→ OpenAPI） | alias | §P2`。盘点现状（F3a 之后）：

- ✅ `_reads_headers` CSV → dispatch `inject_request_headers` 按**字面名**
  从 bridge 读 header → `params["header_<name>"]`（缺失 → ""，F10 约定）；
  OpenAPI parameter `in: "header"`（name = 声明名）；`_param_descs` 可挂
  description（决策-43）。
- ❌ 剩余「alias」面（上游 `Header(...)` 关键行为）：
  1. **alias**：`Header(alias="X-Custom-Thing")` — wire 名 = alias **原样**
     （**不做**下划线转换）；响应/OpenAPI 键 = 原参数名。
  2. **convert_underscores=True（默认）**：无 alias 时 wire 名 = 参数名
     逐 `_` → `-`（`x_token` 读 `x-token`；字面 `x_token` 头**不**匹配）。
  3. **convert_underscores=False**：字面名（含 `_`）不转换。
  4. **大小写不敏感**匹配（HTTP 头语义 / Starlette Headers）。
  5. **多值头** → 第一个值。

**上游探测（P25, /tmp/exch_probe/p25*.py, fastapi 0.141.1 活体 uvicorn）**：

| # | 实测 |
|---|------|
| P25-1 | `x_token: str = Header()` → OpenAPI `name="x-token"`（转换）；发 `X-Token: abc` → 200 `{"x_token":"abc"}`；发字面 `x_token: abc` → **422**（loc `["header","x-token"]`，不匹配） |
| P25-2 | `Header(alias="X-Custom-Thing")` → OpenAPI `name="X-Custom-Thing"`；发**小写** `x-custom-thing` → 200（**大小写不敏感**） |
| P25-3 | `Header(alias="my_header")` → OpenAPI `name="my_header"`（**alias 不转换**）；发字面 `my_header` → 200；发 `my-header` → 422 |
| P25-4 | 逐字符转换：`x__token` → wire `x--token`（发 `x--token` 命中, 发 `x__token` 不中）；`a_b_c` → `a-b-c` |
| P25-5 | 多值头（两个 `X-Token`）→ 取**第一个**值 |
| P25-6 | `Header(default="anon")` → 缺失 200 + 默认值；OpenAPI `required=false` + `default` |
| P25-7 | `Header(min_length=2, max_length=4)` → 422 `string_too_short` "String should have at least 2 characters"（ctx min_length）/ `string_too_long` "String should have at most 4 characters"（ctx max_length）；OpenAPI `minLength`/`maxLength` |
| P25-8 | `Header(pattern=...)` → 422 `string_pattern_mismatch` "String should match pattern '...'"（ctx pattern）；OpenAPI `pattern` |
| P25-9 | `Header(int, default=7)` → 缺失 200 + 7；`"abc"` → 422 `int_parsing` "Input should be a valid integer, unable to parse string as an integer" |
| P25-10 | 多个 Header 参数独立默认值互不干扰；OpenAPI 每参数独立 `name`/`in=header`/`required` |

**范围切分**（矩阵对齐）：本 ADR = **alias + 转换 + OpenAPI 名对齐**
（矩阵 #7 的 gap 字面 = alias）；**P25-6..9（default/required-422/
min_length/max_length/pattern/int 转换）= 参数约束面 → 下一决策（矩阵 #2
路径参数约束 + 全参数类型化约束统一落地）**。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 复用 `_param_aliases` | 让既有 Query alias 表（决策-43）同时作用于 header | ❌ 命名空间冲突（query 参数与 header 参数是独立声明面；同一表双语义 = 歧义）；`_param_aliases` 文档/校验均 query-only |
| B. **`_reads_headers` 条目扩展 `name=alias`（本 ADR）** | 条目 = `name`（wire = name 转换）或 `name=alias`（wire = alias 原样）；参数键仍 = `name`；OpenAPI name = wire | ✅ 最小面（一个既有声明扩一条规则）；alias 天然兼 `convert_underscores=False` 逃生门（`name=name` = 字面）；与 Query alias「响应键 = 原名, wire = alias」约定同构 |
| C. 新 `_header_params` 类型化表 | `name=type[=default][,alias=...][,min_length=...]` 全 Header(...) 面 | ❌ 越界 — default/required/约束 = 下一决策（矩阵 #2）；提前做会拆散约束面的统一设计（path/query/header 一次落地） |

**决策：B** — `_reads_headers` 条目扩展 + 默认转换，FFI diff = 0（决策-53）。

## 3. 决策

### 3.1 wire 名规则（P25-1..5 复刻）

| 条目形态 | wire 名 | 语义 |
|----------|---------|------|
| `name`（无 `=`） | `name` 逐 `_` → `-` | 上游 `convert_underscores=True` 默认（`x_token` → `x-token`；`x__token` → `x--token`） |
| `name=alias` | **`alias` 原样**（不转换） | 上游 `alias=`（`my_header` 别名 → 字面 `my_header`） |
| `name=name` | 字面 `name`（含 `_`） | 上游 `convert_underscores=False` 逃生门（单一声明双语义） |

- **参数键不变**：`params["header_<name>"]`（响应/OpenAPI 键 = 声明名，
  Query alias 同约定）；`_param_descs` 查找键 = 声明名（既有）。
- **大小写**：匹配不敏感（bridge `get_header_value_ci` 既有 — FFI diff = 0）；
  声明/wire 名的原始拼写保留进 OpenAPI（P25-2/3）。
- **多值**：第一个值（bridge 首现扫描 — 既有, P25-5 parity）。

### 3.2 声明 + 注册期校验（`check_header_specs`，同策略 fail-fast）

- `_reads_headers` 每条目（`,` 切 + trim）：
  - 非空（空条目跳过 — 既有行为）；
  - **至多一个 `=`**（≥2 → `Error("header: bad _reads_headers entry
    (need 'name' or 'name=alias'): <piece>")`）；
  - 有 `=` 时 name 与 alias **均非空**；
  - name/alias 内**无空白/控制字符**（header 名合法性最小集 —
    token 字符集粗检：0x21-0x7E 可打印非空白）。
- 注册期调用点 = dispatch 前的 check 簇（`check_body_schemas` /
  `check_state_specs` / `check_ws_specs` / `check_openapi_specs` 之后）。

### 3.3 FFI

**FFI diff = 0**（`extract_request_header` / `get_header_value_slice` 既有；
`get_header_value_ci` 大小写不敏感 + 首现语义 = 上游 parity, 无需改动）。

### 3.4 demo 路由（http_server_final.mojo）

- `/hdr/alias`（GET, ECHO）：`_reads_headers =
  "x_token=Token-Literal,client_id"` —
  - `x_token=Token-Literal`：alias 原样（含大写 + 连字符；**不**转换）；
  - `client_id`：无 alias → wire `client-id`（默认转换）。
  ECHO 响应含 `header_x_token` / `header_client_id`（缺失 → ""）。

### 3.5 文档化偏差（vs 上游 FastAPI 0.141.1，4 条）

| # | 上游 | 本实现 | 定性 |
|---|------|--------|------|
| 1 | `Header()` 缺省 **required**（缺失 → 422 `missing`） | `_reads_headers` = 读到即注入, **缺失 → ""**（F3a/F10 既有约定, Request.headers 式读面）；**required-422/typed header = 下一决策**（矩阵 #2 约束面: default/min_length/max_length/pattern/int 转换, P25-6..9 已探测备查） | 声明式分阶段：本决策 = alias/转换面（矩阵 #7 gap 字面）；约束面统一落地避免半套 |
| 2 | `alias` 与 `convert_underscores` = 两个独立字段 | 单声明双语义：`name=alias` = alias 且**不转换**（P25-3: 上游 alias 本就不转换, 故无损）；`name=name` = 字面（= convert_underscores=False） | 无行为损失（上游两字段组合的全部可达状态均可表达: 转换 = 无 `=` / 不转换 = `n=n` / alias = `n=a`） |
| 3 | OpenAPI parameter.schema 带 `title`（wire 名 title-case, 下划线→空格: "X--Token"/"A B-C"） | schema 无 `title`（F4 既有形态, 决策-24 基座） | 既有偏差（本决策仅对齐 `name` 值, title 面不扩） |
| 4 | 422 loc = `["header", wire名]` | 本决策无 required-422（见 #1）；下一决策对齐 loc = wire 名 | 随 #1 分阶段 |

## 4. 风险

- **R1 既有 `_reads_headers` 路由行为变化**：含 `_` 的声明名 wire 从
  字面变为转换 — 仓库内既有使用仅 `/ctx`（`X-Custom,User-Agent`, 无下
  划线, 零变化）；e2e 全量回归守护。
- **R2 OpenAPI header parameter 名变化**：含 `_` 的头名 spec 值变化 —
  现有 e2e openapi 断言均针对 query/path 头名无下划线（审计: /ctx 的
  `X-Custom`/`User-Agent` 无下划线, 不受影响）。
- **R3 binary 体积**：纯 Mojo +~5 KB（远小于 ≤4.2M 预算余量）。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`http_server_final → header_params`；`openapi → header_params → {router, handler}`；无回边 |
| 2. 模块 < 500 行 | ✅ 遵守 | `header_params.mojo` ≈ 120 行（纯函数）；`http_server_final` +~30 行（demo + 接线）；`openapi.mojo` 497 → ~500 内（仅 2 行改动） |
| 3. FFI 表面不变 | ✅ 遵守 | **FFI diff = 0**（`extract_request_header`/`get_header_value_slice` 既有；`get_header_value_ci` 大小写/首现语义 = 上游 parity 无需改） |
| 4. 零新依赖 | ✅ 遵守 | 纯 Mojo 标准库（字符串处理）；无 Rust/第三方改动 → ldd 仅 libc 不变 |
| 5. 单 binary 不变式 | ✅ 遵守 | `build_single.sh` 流程零改动；声明解析 = 进程内纯函数 |
| 6. 声明式世界观 | ✅ 遵守 | `_reads_headers` 既有声明扩条目形态（ADR-0004）；注册期 `check_header_specs` fail-fast（check_* 同策略）；无运行期对象修改 |

## 7. 验证方式（实测 2026-09-10）

1. **单 binary 不变式**：`ldd build/fastapi_mojo` = 仅 libc；binary
   **3,815,424 B**（3.8M ≤ 4.2M，vs 决策-52 基线 3,803,136 B **+12 KB** —
   纯 Mojo：header_params.mojo 120 ln 新增 + http_server_final 1653 ln
   （+11：import/check 簇/inject 改写/demo）+ openapi 499 ln（+2）；
   **无 Rust/FFI 改动**）；`env -i` 干净启动（`/health` JSON 200
   healthy + `/hdr/alias` 4 形态实值，等 listener + sleep 5 + body
   校验防透明代理假 ready）；`find src -name '*.c'` = 0；`find . -name
   '*.py'`（excl .git/docs）= 0；`pgrep -x fastapi_mojo` = 0（SIGTERM
   优雅关停，无孤儿）。
2. **质量门禁**：`cargo test --release -- --test-threads=1`
   (fastapi_mojo_rs) = **431 passed / 0 failed / 4 ignored**（纯 Mojo
   决策，Rust 侧零改动）；fmtool `cargo test` = 0 测试 exit 0；
   `cargo clippy --release --tests -- -D warnings` 双 crate = **0
   警告**；`mojo run header_params_selftest.mojo` = all checks passed
   （~22 断言: wire 全向量 / 条目形态 / 注册校验 6 畸形 raise，0 警告）；
   `header_params.mojo` / `openapi.mojo` / `http_server_final.mojo`
   `--emit object` = 0 新警告（仅 5 处历史基线警告，决策-23 既有）。
3. **e2e**：395 → **403/403 全绿**（+OP3-1..8：OP3-1 alias wire
   小写 CI 命中（`token-literal: A` → `header_x_token=A`）；OP3-2
   alias 原始拼写（`Token-Literal: B` → B）；OP3-3 下划线字面头
   **不**绑 alias 参数（`x_token: C` → 空, P25-1）；OP3-4 默认
   `_→-` 转换（`client-id: D` → `client_id=D`）；OP3-5 下划线字面
   头不读普通参数（`client_id: E` → 空）；OP3-6 `/ctx` 回归（无下
   划线名 `X-Custom`/`User-Agent` 行为零变化）；OP3-7 OpenAPI
   header 参数名 = wire 名（`"name":"Token-Literal","in":"header"`
   alias 原样 + `"name":"client-id"` 转换）；OP3-8 多值头取首
   （M1/M2 → M1, P25-5））。
4. **性能**：bench 6 场景 **0 errors**；**get_root_10k_100c = 35,765
   req/s**（32.9k–43.9k 区间内，vs 决策-52 33,590 — 噪声带内，无
   退化）；RSS 平台化（header 解析 = 请求期纯函数，无新常驻状态）。
5. **环境注记**：
   - **FFI diff = 0**：`get_header_value_ci`（bridge/parse.rs）本就
     ASCII 大小写不敏感 + 首现扫描 = 上游 Starlette Headers parity，
     `extract_request_header`/`get_header_value_slice` 签名零改动 —
     决策-53 全部语义由 Mojo 层 wire 名计算承载。
   - **OpenAPI 名 = 原始拼写**：alias 与转换名均按声明原样进 spec
     （`Token-Literal` 保大小写, P25-2/3；wire 匹配才做 CI）。
   - **透明代理**：本机 fresh bind 首连偶被 Caddy :80 劫持（假空
     body 200, taint 持续 bind 生命周期）— 冒烟协议 = 等 listener
     + sleep 5 + body 含 `healthy` 才信任, 否则换新端口（本决策
     4 次冒烟首试全部通过, 未触发重试）。
