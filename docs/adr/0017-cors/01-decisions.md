# ADR-0017: CORS 完整配置（Starlette CORSMiddleware 声明式 env 等价）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #15 落地）
- **关联**：AGENTS.md §3.1/§6（**决策-42**）、Goal-0003（P2：CORS 完整配置）、
  North Star（单 binary 零依赖 — **零新增依赖**，std only，ldd 仅 libc）、
  Starlette `CORSMiddleware`（allow_origins/methods/headers/credentials/
  max_age=600 / `_build_pre_response` 400 语义）、决策-36（env 声明式横切
  配置模式 + FFI NUL 终止契约）、决策-40（GZip 同模式先例）

## 1. 背景

C 端口时代 CORS 是**固定常量**（`response.rs::CORS_HEADERS`）：每个响应都带
`Access-Control-Allow-Origin: *` + 7 方法 + 2 头 + `Max-Age: 86400`；预检
（OPTIONS）恒定 204。相对 Starlette `CORSMiddleware` 这是**偏差**：

1. **普通响应**：Starlette 只在请求带**被允许的 Origin** 时才附加 CORS 头
   （`allow_all_origins` 且无 credentials → `*`；否则**回显**具体 origin；
   credentials → `+ Access-Control-Allow-Credentials: true`）；Origin 不被
   允许或无 Origin → **不带任何 CORS 头**（浏览器自行拦截）。
2. **预检**（OPTIONS + Origin + ACRM）：origin 不在白名单 / ACRM ∉
   allow_methods / ACHR ⊄ allow_headers → **400**（`_build_pre_response`）；
   通过 → 204 + 动态头集 + `max_age`（**默认 600**，本实现 C 时代 86400）。

约束（Mojo 1.0.0 + North Star）：
- Mojo 无闭包 / 无中间件对象 → 横切配置一律**声明式 env**（lifespan /
  access-log / GZip 同模式，决策-36/40 先例）
- header 解析 / 响应装配已在 Rust bridge（Mojo std 缺口归属层，§3.3）；
  CORS 判定 = 同一层纯函数
- **零新增依赖**：CORS 是纯字符串逻辑（std only），不引入任何第三方
  （对比 GZip 需要 flate2）

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. Mojo 侧 CORS | Mojo 读 env + 解析 Origin 头 | ❌ Mojo 1.0.0 env/网络在 bridge；头解析已在 Rust；拆两层重复 parse；与 GZip「判定走 request 全局」同层原则冲突 |
| B. **Rust bridge `cors.rs` + env 声明式（本 ADR）** | `bridge/cors.rs`（config/origin 判定/行装配，纯函数）+ request 全局三元组（io.rs 解析 header 时写入）+ `build_response_headers` / `build_preflight_response` 单点消费 | ✅ FFI diff = 0（无新 extern "C"）；零新依赖；声明式 = 既有模式；钩子单点（所有响应必经 `build_response_headers`） |
| C. 新增 FFI 导出（`cors_set_*` 等） | Mojo 启动时逐项传配置 | ❌ 破坏「进程级声明式 env 一次读取」模式（GZip/lifespan 先例）；FFI 面 +5；配置非请求态，无 per-request 数据通道必要 |

**决策：B** —— Rust bridge `cors.rs` + 声明式 env（决策-42）。

## 3. 决策

1. **env API（声明式；进程启动一次读取，`Mutex<Option>` 缓存 +
   `#[cfg(test)]` reset 钩子 — GZip 同模式）**：
   - `FASTAPI_MOJO_CORS_ORIGINS` —— CSV 白名单 或 `*`（**默认 `*`** = 既有行为）
   - `FASTAPI_MOJO_CORS_METHODS` —— CSV（**默认** GET, POST, PUT, DELETE,
     HEAD, OPTIONS = C 时代 7 方法集）
   - `FASTAPI_MOJO_CORS_HEADERS` —— CSV 或 `*`（**默认** Content-Type,
     Authorization = C 时代；未设置 ≠ `*`，显式 `*` 才通配）
   - `FASTAPI_MOJO_CORS_CREDENTIALS` —— 1/true/yes/on（**默认 false**）
   - `FASTAPI_MOJO_CORS_MAX_AGE` —— 秒（**默认 600** = Starlette；C 时代
     86400 → 对齐上游）
2. **普通响应（`build_response_headers` 单点，所有响应类型必经）**：
   仅当请求带 Origin 且被允许时输出 CORS 头 ——
   - 通配且 credentials 关 → `Access-Control-Allow-Origin: *`
   - 白名单命中 **或** credentials 开 → **回显**具体 origin
     （`*` + credentials 按 RFC 非法 → 回显，Starlette 同款）
   - credentials → `+ Access-Control-Allow-Credentials: true`
   - Origin 不被允许 / 无 Origin → **不带任何 CORS 头**
   - 📌 **偏差移除（文档化）**：C 时代「每个响应必带 `*`」偏差移除 ——
     无 Origin 的响应不再带 CORS 头。浏览器 CORS 检查只发生在带 Origin
     的跨源响应上，无 Origin 请求方不受影响；这是向 Starlette 的收敛。
3. **预检（`build_preflight_response`，FFI `send_preflight_response(fd)`
   签名不变 — **FFI diff = 0**）**：
   - Origin 不在白名单 → **400** `{"error":"origin not allowed",...}`
   - ACRM 在场且 ∉ methods（大小写不敏感）→ **400** `method not allowed`
   - ACHR 在场且任一请求头 ∉ headers（`*` 放行全部；大小写不敏感）→
     **400** `requested header not allowed`
   - 通过 → **204** + [ACAO 回显/`*`] + [ACAC] + [ACAM（ACRM 在场时）] +
     [ACAH（ACHR 在场时）] + Max-Age
   - 裸 OPTIONS（无 Origin，C 时代既有行为）→ 204 通配超集
     （**文档化超集**：Starlette 把非预检 OPTIONS 交 app，本实现统一 204；
     浏览器预检必带 Origin + ACRM，行为无差异；e2e CRS-1 守护）
4. **request 全局（FFI NUL 终止契约，决策-36）**：`CurrentRequest` 新增
   `origin[256]` / `acrm[64]` / `achr[256]` + lens（截断 + `[len]=0`）；
   io.rs 在**两个** `set_http_fields` 调用点（body-in-first-recv /
   常规）调 `set_cors_request(get_header_value_ci ×3)`（纯函数扫描，
   与 `set_accepts_gzip` 同位）；`reset_request_fields` 复位。
   **worker 单请求串行模型内，FFI diff = 0。**
5. **`CORS_HEADERS` 常量删除**（response.rs）→ `cors::normal_cors_lines`
   动态行（0..2 行）；预检字节串 → 动态装配（204/400 两路）。
6. **e2e 零 python3（Track B 决策-22）**：CRS-1..8 全 curl（`-D` 抓头 +
   grep -Ei）+ 400 body grep；副 server（PORT+102）origins 白名单 +
   credentials + MAX_AGE=120。

## 4. 风险

| 风险 | 缓解 |
|------|------|
| 「每响应必带 `*`」→ 条件附带，既有客户端受影响？ | 浏览器只在带 Origin 的跨源响应上读 CORS 头；无 Origin 请求方完全不受影响；**默认 env = 通配 `*`**，带 Origin 的请求响应字节与 C 时代一致（除 Max-Age 位置/预检头集）；偏差方向是**向上游收敛** |
| `Max-Age` 86400 → 600：预检缓存缩短（1 天 → 10 分钟） | Starlette 默认对齐（上游部署同款）；部署方可 env 改回任意值 |
| 预检 204 → 400（越界场景） | 仅影响越界预检（origin/method/header 不在声明集）— 这正是 CORS 的安全语义（上游同款）；合法预检行为不变；e2e CRS-6/7/8 固化 |
| env 进程级一次读取 | 与 GZip/lifespan/access-log 同一声明式 trade-off（Mojo 无闭包）；改配置 = 重启（部署文档化） |
| 每响应 +1 次 Mutex lock（config） | 单线程 worker 无竞争（GZip 同款已验证）；bench 6 场景 0 errors，get_root_10k_100c 36.0k req/s（历史区间 32.9k–43.9k 内，无回归；bench 客户端不发 Origin → 判定 = origin_len==0 短路） |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`cors` 只依赖 std（env/sync，零 crate 内 import）；`request` 只依赖 std；`io` → `request`（setter）+ `parse`（`get_header_value_ci` 纯函数）；`response` → `cors` + `request`（纯函数消费）；无环 |
| 2. 分层向下依赖 | ✅ 遵守 | CORS 配置/判定 = 横切纯逻辑，归 Rust bridge（§3.3 Mojo std 缺口归属层 — header 解析本就在此层）；**Mojo 侧零代码改动**（纯 env 声明，dispatch 零分支 — 与 GZip/lifespan/access-log 同一声明式模式） |
| 3. God package 阈值 | ✅ 遵守 | cors.rs **223**（新模块）/ request.rs **494**（+105 → 压缩至 <500：`copy_field` + `field_str` 共享 helper）/ response.rs **159** / io.rs **830**（既有超阈值文件，本 ADR +16 行均为 setter 调用，无新分支）；cors_tests.rs 251 |
| 4. 主题域边界清晰 | ✅ 遵守 | cors.rs 只管「config 解析 + origin 判定 + 行装配」纯函数（输入全参数化：`origin_allowed(cfg, origin)` / `normal_cors_lines(origin)` / `preflight_build(origin, acrm, achr)` — 不碰 fd / 不读 request 全局 / 不锁 I/O）；request 全局只管三元组存储（NUL 终止）；io 只管「何时写」；response 只管「何时用」 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新 extern "C" 导出；`set_cors_request` / `current_origin` / `current_cors_request` / `config` / `normal_cors_lines` / `preflight_build` 全是 crate 内 Rust API）；**零新增 Cargo 依赖**（std only）；ldd 实测仍仅 libc（3,228,368 B = 3.1M） |
| 6. 测试文件跟随 | ✅ 遵守 | `cors_tests.rs` 10 测（env 解析 4 / origin 矩阵 / 普通行矩阵 / 预检 204×2 + 400×2 + 边界）+ `response_tests` 3 测重写（动态普通头 / 预检 bare/204/400）+ `send_tests`（真 fd keep-alive 全链路 CORS 行）+ 共享 `__test_clear_env()` 钩子（三测试文件 env 隔离，断言 panic 跳过清理的防御纵深）；e2e **CRS-1..8 = 221/221 全绿** |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc（**3,228,368 B =
   3.1M**，≤4.2M；vs 决策-41 后 3,207,192 B，+21 KB = cors 模块）；
   `env -i ./build/fastapi_mojo --port N` 干净启动（health 200）。
2. **e2e 全量不回归**：213 → **221**（+8 CRS 项）全绿：
   - CRS-1 裸 OPTIONS（无 Origin）→ 204 + `ACAO: *`（C 时代行为回归守护）
   - CRS-2 默认通配 + Origin → `ACAO: *`
   - CRS-3 白名单命中 + credentials → **回显** origin + `Allow-Credentials: true`
   - CRS-4 白名单未命中 → **无**任何 CORS 头
   - CRS-5 预检通过 → 204 + 回显 + credentials + 7 方法 + 2 头 + `Max-Age: 120`
   - CRS-6 ACRM PATCH（越界）→ 400 `method not allowed`
   - CRS-7 Origin evil.com（越界）→ 400 `origin not allowed`
   - CRS-8 ACHR X-Nope（越界）→ 400 `requested header not allowed`
3. **质量门禁**：`cargo clippy --release --tests -- -D warnings` **0 警告**；
   `cargo test --release -- --test-threads=1` **335 passed / 0 failed /
   4 ignored**（323 → +12：cors_tests 10 + response_tests 净增 2）。
4. **手动全链路**（本 ADR 执行期实测，双 server）：默认通配 server（M1/M2）
   + 白名单/credentials/120 server（S1..S7）9 点矩阵全符合上表；400 body
   JSON schema 与既有 error 响应一致。
5. **性能**：bench 6 场景 **0 errors**；get_root_10k_100c **36,023 req/s**
   （历史区间 32.9k–43.9k 内；bench 客户端不发 Origin，热路径 = 一次
   `origin_len == 0` 短路比较）。
