# ADR-0011: FastAPI 安全 / 认证（HTTPBasic / HTTPBearer / APIKey）— 声明式 + 单一 dispatch 钩子

- **日期**：2026-09-05
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P0 落地）
- **关联**：AGENTS.md §3/§6（**决策-34**）、Goal-0003（FastAPI 全功能对标 P0）、
  ADR-0004（路由注册「用户代码 = 数据」模式）、`handler.mojo`（run_handler 单一 dispatch
  扩展点）、`http_server_final.mojo`（serve_forever dispatch）、`security.mojo`（新增）、
  `scripts/e2e_test.sh`（SEC-* 13 项）、FastAPI `fastapi.security`（HTTPBasic /
  HTTPBearer / APIKey / SecurityScopes 语义对标）

## 1. 背景

FastAPI 的**安全 / 认证**是最高频使用的能力之一（HTTPBasic / HTTPBearer / APIKey /
OAuth2 / get_current_user 模式）。本项目此前（v0.5.1 + 决策-31/32/33）**完全没有**
任何认证能力 —— 所有路由对所有客户端无差别开放。这是 Goal-0003「FastAPI 全功能
100% 对标，一个不少」矩阵中**第 17 项**（❌ 缺失，核心卖点）。

Goal-0003 将其列为 **P0**（最高优先），因为：
- 使用率最高（生产 API 几乎都要鉴权）
- 与现有「声明式 + 单一 dispatch 扩展点」架构**完全对齐**（无需新 KIND、无需改 handler 行为）
- 可验证性强（401 + WWW-Authenticate / 200 + auth_* 注入，e2e 断言明确）

约束（Mojo 1.0.0 + North Star）：
- Mojo 1.0.0 无闭包/函数一等对象 → handler 仍是「kind + name + data」纯数据
- base64 属**协议层**（归 Mojo），字节级 I/O 才归 Rust bridge（ADR-0010 分层）
- 不引入新 Python 依赖；不引入新的系统动态库（ldd 仅 libc）

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 新建 KIND_AUTH + run_handler 分支 | 把认证当作一种 handler 行为 | ❌ 认证是**请求级 gate**（先于 param 校验 / handler 执行），不是 handler 行为；塞进 run_handler 语义错位，且 401 要在 run_handler 之前短路 |
| B. **声明式 `_auth` + 单一 dispatch 钩子（本 ADR）** | handler.data 声明 `_auth`，dispatch 在 F1 param 校验**之前**做认证 gate，失败 -> 401 + WWW-Authenticate 短路，成功 -> 注入 `auth_*` 参数 | ✅ 与 ADR-0004「用户代码 = 数据」+ 决策-33「_depends 单一钩子」同模式；认证是 gate 语义天然前置；零 KIND 新增；零 FFI 新增（复用 extract_request_header） |
| C. 独立 middleware 层认证 | 把认证做成 BaseHTTPMiddleware 式中间件 | ❌ 本项目 middleware 是「固定三件套」（request_id/logging/timing）且无用户自定义；为认证单开 middleware 层过度设计，且与「声明式路由数据」风格割裂 |

**决策：B** —— 声明式 `_auth` + 单一 dispatch 钩子（决策-34）。

## 3. 决策

1. **声明式 API**（对齐 ADR-0004 数据驱动）：
   - `Handler.data["_auth"]`：`"basic"` / `"bearer"` / `"apikey:header:<name>"` /
     `"apikey:query:<name>"` / `"apikey:cookie:<name>"`
   - `Handler.data["_auth_users"]`：`"user:pass;user2:pass2"`（basic 的凭据对 CSV）
   - `Handler.data["_auth_tokens"]`：`"tok1;tok2"`（bearer/apikey 的合法 token CSV）
   - `Handler.data["_auth_realm"]`：可选，WWW-Authenticate 的 `realm="..."`
2. **语义对齐 FastAPI/Starlette**：
   - 失败 -> **401** + `WWW-Authenticate`（basic: `Basic realm=...`；bearer: `Bearer realm=...`；
     apikey 无 WWW-Authenticate，RFC 无标准）。不区分「缺凭据」与「错凭据」对外一律 401
     （detail 区分，但不泄露认证机制细节给未认证方）。
   - 成功 -> 注入 `auth_user`（basic）/ `auth_token`（bearer）/ `auth_apikey`（apikey）
     到 handler 参数（handler 可读，对齐 get_current_user 模式）。
3. **base64 解码纯 Mojo**（`security.mojo` `b64_decode`）：协议层归 Mojo（ADR-0010 分层），
   手写 6-bit 累加 + 掩码防 64-bit Int 溢出；兼容标准（+ /）与 URL-safe（- _）字母表
   （RFC 4648）；跳过空白与 padding `=`。
4. **UTF-8 边界安全**：凭据可能含 multi-byte UTF-8，按 codepoint 边界找 `:` 切
   user:pass（`next_codepoint_len` 步进），防 `String[byte=j]` 落在续字节上 assert 崩溃
   （实测 catch：`admin:wrong` 触发 `String span index, 8 does not lie on a codepoint boundary`）。
5. **单一 dispatch 钩子**：`security.mojo::check_auth(handler, query_values) -> AuthResult`
   是**唯一**「认识认证」的函数。新增认证类型 = 本函数加一个 elif（对齐 run_handler 模式）。
   dispatch 侧仅 3 行：调用 check_auth，失败设 401 + WWW-Authenticate 短路，成功注入 auth_*。
6. **零 FFI 新增**：复用既有 `extract_request_header` / `get_header_value_slice`（读
   Authorization / X-Api-Key / Cookie 头）；cookie 解析复用本地逻辑。

## 4. 后果与限制（文档化）

- **新增**：`security.mojo`（~360 LOC，< 500 阈值）；`http_server_final.mojo` 加
  import + 4 个 demo 路由 + dispatch 钩子（~30 行）；e2e 加 SEC-* 13 项。
- **401 短路**：认证失败**先于** F1 param 校验 / F2 error_map / F3a 注入 / run_handler
  执行（fail-fast，安全 gate 语义）；由 `do_handler` flag 控制跳过。
- **凭据明文存于 handler.data**：`_auth_users` / `_auth_tokens` 是明文 CSV。生产场景应
  用哈希/环境变量注入（后续 P2 可加 env 读取 + bcrypt）。**当前为 demo 语义**，与
  FastAPI「示例凭据」一致，不是生产就绪的密码学。
- **APIKey 无 WWW-Authenticate**：RFC 9110 未定义 APIKey 的 challenge，故 401 无
  WWW-Authenticate（与 FastAPI 一致）。
- **bearer/apikey 多 token 是 OR 语义**：`_auth_tokens` 是合法 token 白名单（任一命中即
  通过），非「多角色」。OAuth2 的 scope / role 校验是 P1 后续。
- **base64 解码 UTF-8 容器**：`b64_decode` 返回 UTF-8 String，非 UTF-8 凭据字节会被
  替换。HTTPBasic 的 user:pass 语义上是 ASCII，无影响；非 ASCII 凭据是边缘场景（P2 可
  改返回 bytes 列表）。

## 5. 实测教训 / 预期验证点

- **base64 数字字母表陷阱（实测 catch + 修复）**：首版 `_b64_val` 对数字用 `c - 4`
  （错），应为 `c + 4`（0=52,1=53,...,9=61）。**隐蔽性极强**：`user:pass123`（b64
  `dXNlcjpwYXNzMTIz`，无数字字符）全程正确，`admin:secret`（b64 `YWRtaW46c2VjcmV0`，
  含 '4'/'6'）才暴露 —— 表面看像「偶发」，实为字母表 off-by。教训：**base64 必须用
  含数字的已知向量测试**（`YWRtaW46c2VjcmV0` / `Zm9vYmFy`），不能只用无数字向量。
- **64-bit Int 溢出（实测 catch + 修复）**：6-bit 累加 val 无掩码时，>11 字符后溢出
  64-bit。修复：每次出字节后 `val = val & ((1 << bits) - 1)` 只保留 pending bits。
- **UTF-8 续字节崩溃（实测 catch + 修复）**：`cred[byte=j]` 落在 multi-byte 续字节上
  触发 assert。修复：按 codepoint 边界步进找 `:`。

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`http_server_final`（dispatch）→ `security`（check_auth）→ `string_builder`（StringBuilder/next_codepoint_len）+ `handler`（Handler/AuthResult 输入）。无回调上溯；security 不 import http_server_final |
| 2. 分层向下依赖 | ✅ 遵守 | 认证是**协议/业务层**（Mojo，同 F10 cookie/header 注入）；base64 解码是**协议原语**（Mojo 手写，非 Rust）；读请求头是**系统 I/O**（复用 Rust bridge 既有 `extract_request_header` FFI）。分层与 ADR-0010 一致，未新增 Rust 代码 |
| 3. God package 阈值 | ✅ 遵守 | `security.mojo` ~360 LOC（< 500）；dispatch 钩子 ~30 行在 http_server_final（该文件已大，钩子是显式扩展点，同 F10/F11 模式）；base64 / 认证各自函数内聚 |
| 4. 主题域边界清晰 | ✅ 遵守 | `security.mojo` 只做认证（base64 解码 + 3 种校验 + AuthResult），不感知路由/序列化/WS；`http_server_final` 只做「调用 check_auth + 401 短路 + auth_* 注入」，不内嵌认证逻辑 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **零新增 FFI 符号**：复用既有 `extract_request_header` / `get_header_value_slice`（ADR-0010 导出表内，无新增）；FFI 表面 diff = 0；无 Rust 侧改动 |
| 6. 测试文件跟随 | ✅ 遵守 | `security.mojo` 含 `main()` 自测（b64 向量 + 前缀 + 未声明/未知 spec）；e2e SEC-* 13 项（basic 5 + bearer 3 + apikey 5）覆盖 401/WWW-Authenticate/200/auth_* 全路径；Rust `cargo test` 299 不回归；clippy 0 警告 |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动；体积
   2.8M（≤4.2M）。
2. **e2e 全量不回归**：147 → **160**（+13 SEC 项）全绿。
3. **质量门禁**：`cargo clippy --release --tests -- -D warnings` 0 警告；`cargo test
   --release -- --test-threads=1` **299 passed / 0 failed / 4 ignored**。
4. **功能路径**：basic（无/错/对/第二用户）+ bearer（无/错/对）+ apikey header
   （无/错/对）+ apikey query（对/错）全验证；401 带正确 WWW-Authenticate；200 注入
   auth_* 到 handler 参数。
5. **零 FFI diff**：`nm libfastapi_mojo_rs.a` 导出符号清单与决策-34 前一致（无新增）。
