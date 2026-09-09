# ADR-0019: OAuth2 password flow + JWT (HS256) — Rust crypto 原语 + 纯 Mojo 协议层

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #17 落地 — 对标矩阵最后一项）
- **关联**：AGENTS.md §3.2/§6（**决策-44**）、Goal-0003（P2：OAuth2/JWT，
  对标矩阵行 #17）、North Star（单 binary 零依赖 — **零新增第三方 crate**；
  FFI diff = +2）、ADR-0010（Rust bridge 分层：字节/加密原语归 Rust）、
  决策-34（`_auth` 声明式认证 gate）、决策-38（422 detail Pydantic v2 结构）、
  决策-36（FFI NUL 终止契约）、FastAPI 0.141.1 + pyjwt 2.13.0（/tmp/fm_probe
  逐条实测，本 ADR §1 证据）

## 1. 背景

Goal-0003（FastAPI 100% 对标）P2 矩阵最后一项：**OAuth2 password flow + JWT**。
FastAPI 教程「Security → Simple OAuth2 with Password and Bearer」的标准形态：

1. **`POST /token`**（`OAuth2PasswordRequestForm`）：form 字段
   `grant_type` / `username` / `password` / `scope` / `client_id` /
   `client_secret` → 凭据校验 → 签发 JWT（HS256）→
   `{"access_token": "...", "token_type": "bearer"}`。
2. **`Depends(oauth2_scheme)`**（`OAuth2PasswordBearer(tokenUrl=...)`）+
   `get_current_user`（pyjwt `jwt.decode(token, SECRET, algorithms=["HS256"])`）：
   受保护端点的 Bearer token 校验。

**实测证据（FastAPI 0.141.1 + pyjwt 2.13.0，/tmp/fm_probe 逐条 probe；
本 ADR 期间重新复测修正了 2 处早期设计假设）**：

- `OAuth2PasswordBearer.__call__`（0.141.1 源码 + 行为）：
  - 无 Authorization → **401 "Not authenticated"** + `WWW-Authenticate: Bearer`
  - Authorization 存在但 scheme（**大小写不敏感**）≠ `bearer` → 同上
    （`Basic xxx` / `Junk abc` 均 401 Not authenticated）
  - scheme = `bearer` → 返回 **param = 首个空格后全部内容**（可空）
- `get_current_user`（教程代码 + pyjwt 2.13）对 param 的 `jwt.decode`：
  - **空 token（`Bearer ` / `Bearer`）→ 401 "Could not validate
    credentials"**（`DecodeError: Not enough segments`）— **不是 403**
    （早期 probe 记录的 403 为旧版行为，0.141.1 实测修正）
  - 签名错 / exp 过期 / nbf 未到 / sub 缺失 / alg=none / 2-part / 垃圾串
    → 一律 **401 "Could not validate credentials"**（全部带
    `WWW-Authenticate: Bearer`）
  - 有效 → 200，`sub` 注入
- `OAuth2PasswordRequestForm`（0.141.1 = **宽松** Pydantic 模型）：
  - `grant_type` **可选**（缺省 = None，**不报错** — 早期设计假设 400 被修正）；
    存在时必须匹配 `^password$`，否则 422
    `{"type":"string_pattern_mismatch","loc":["body","grant_type"],
    "msg":"String should match pattern '^password$'",
    "input":"<val>","ctx":{"pattern":"^password$"}}`（紧凑 JSON）
  - `username` / `password` **必填**，缺失 → 422 `{"type":"missing",
    "loc":["body",<name>],"msg":"Field required","input":null}`（全部收集）
  - 凭据错（教程 handler）→ **401 "Incorrect email or password"** +
    `WWW-Authenticate: Bearer`
  - 成功 → `{"access_token":"...","token_type":"bearer"}`
- pyjwt 2.13 独立签发 5 个 fixture（key = `probe-secret-key-42`，与 demo
  `_jwt_secret` 一致）：T1 有效 / T2 过期 / T3 异 secret 签名 / T4 无 sub /
  T5 alg=none — 交叉验证本实现（防系统性 HMAC/b64url 错误）。

约束（Mojo 1.0.0 + North Star + ADR-0010 分层）：
- HMAC-SHA256 / SHA-256 / base64url 属**加密原语**（字节级、无业务语义）→
  Rust bridge（零第三方 crate，手写 FIPS 180-4 / RFC 2104 / RFC 7515）；
  协议语义（3-part 切分 / claims 解析 / form 校验 / 状态映射）→ 纯 Mojo 层
- Mojo 无闭包 / 无 match → 声明式数据（`handler.data`，决策-34/38/42 同模式）
- Mojo 1.0.0 `assert` 是 no-op（决策-38）→ 自检用 `check()` + `abort()`

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 全部内联 dispatch（serve_forever 里写 /token + JWT 校验） | 不新建模块 | ❌ dispatch 已 1148 行（既有超阈值）；协议语义混入主循环，不可独立自测；违反「新行为 = 数据 + 单点」模式（决策-34/38/43） |
| B. **纯 Mojo `security_jwt` 协议模块 + Rust `crypto` 原语 + FFI +2（本 ADR）** | `security_jwt.mojo`（b64url 编码 / 3-part 切分 / JSON claims 扫描 / form 校验 / check_oauth2 / handle_oauth2_token）+ `crypto.rs`（sha256 / hmac_sha256 / b64url_encode/decode，手写）+ `ffi.rs` 2 个 `extern "C"`（`fm_hmac_sha256_b64url[_free]`）+ dispatch 3 处接线 + OpenAPI securitySchemes | ✅ 分层对齐 ADR-0010（原语→Rust，协议→Mojo）；零新增 crate；FFI diff = +2（最小面）；声明式 = 既有模式；security_jwt 纯逻辑部分 `mojo run` 可自测；security.mojo 零改动（JIT 自检不回归） |
| C. JWT 全链路下推 Rust bridge（`fm_jwt_encode/verify`） | bridge 内做 claims 解析 / form 校验 | ❌ 协议语义（状态码映射 / Pydantic detail 格式 / 教程措辞）属应用层，下推违反分层；FFI 面膨胀；Rust 侧无法复用 Mojo 侧 `_parse_form_body` / 422 detail 既有设施 |

**决策：B** —— `security_jwt.mojo`（纯 Mojo 协议层）+ `crypto.rs`（Rust
加密原语）+ 2 FFI 导出（决策-44）。

## 3. 决策

1. **Rust `bridge/crypto.rs`（185 行，零第三方 crate）**：
   - `sha256`（FIPS 180-4，含 >64B 分块）/ `hmac_sha256`（RFC 2104，
     key>64B 先 sha256 压缩）/ `b64url_encode`（RFC 7515 §2.1 无 padding）/
     `b64url_decode`（宽松：忽略 `=`/空白，容忍标准字母表 `+/`，非法字符
     → None；尾 bits 丢弃）
   - known-vector 单测 ×12：SHA-256 ×4（empty/abc/448bit/million-a）/
     HMAC RFC 4231 ×4（含 TC6 长 key）/ b64url RFC 7515 ×7 + 往返 + 宽松
     解码 / **pyjwt-2.13 oracle JWT 签名交叉验证**
2. **FFI（`ffi.rs` §8.5，+2 导出，内存契约 = 决策-36）**：
   - `fm_hmac_sha256_b64url(key, key_len, msg, msg_len) -> CSlice`：
     `malloc(n+1)` + **NUL 终止**（Mojo `CStringSlice.as_bytes()` 按 C 串
     读到 NUL 的硬性契约）；输出 URL-safe 字母表（无内部 NUL 风险）
   - `fm_hmac_sha256_b64url_free(ptr)`：libc free（null 容忍）
   - len 参数语义：`>0` 显式长度（二进制安全）；`==0`/null 回退 NUL 截断
3. **`security_jwt.mojo`（497 行，纯 Mojo 协议层）**：
   - `b64url_encode`（纯 Mojo 编码方向；解码复用 `security.b64_decode`
     — 已兼容 `-_` 字母表）
   - `_jwt_parts`：'.' 切分，恰好 3 段且每段非空（pyjwt "Not enough
     segments" 语义）
   - `_json_field`：flat JSON 手写扫描器（字符串值处理转义 + UTF-8
     多字节经 `decode_utf8_bytes`；number/bool/null 原样）
   - `JwtVerify` + `_check_claims`（纯逻辑，可独立自测）：**alg 必须
     `HS256`**（拒 `none`/`HS512`/垃圾 — pyjwt algorithms 白名单语义）/
     `exp`: `now >= exp` 过期 / `nbf`: `now < nbf` 未生效 / **`sub` 必须
     存在且非空**
   - `jwt_encode_hs256` / `jwt_verify_hs256`（签名 = FFI HMAC 重算 +
     与第 3 段精确比对）
   - `check_oauth2`（OAuth2PasswordBearer + 教程 get_current_user 等价）：
     无头 / scheme≠bearer（大小写不敏感）→ 401 "Not authenticated"
     （www=Bearer+realm）；param（首个空格后全部，可空）→ JWT 校验失败
     （含空 token）→ 401 "Could not validate credentials"（www=Bearer）；
     成功 → `auth_user = sub`、`auth_token = param`
   - `handle_oauth2_token`（/token）：`_parse_form_body`（从
     http_server_final 移入 request_response 共享）→ `_check_form`
     （grant 宽松 / pattern 422 / missing 全收集，Pydantic v2 紧凑格式）
     → `_auth_users`（`u:p;u:p` CSV）凭据错 → 401 "Incorrect email or
     password" + www=Bearer → 签发（claims = `sub`/`username`/`iat`/
     `exp = iat + _jwt_ttl_sec`；`_jwt_secret` / `_jwt_ttl_sec` 声明式，
     ttl 缺省 3600）→ `{"access_token", "token_type":"bearer"}`
4. **dispatch 接线（http_server_final，3 处）**：
   - `/token` + `/token-exp`（ttl=-1 测试钩子）+ `/secure-jwt` 3 条 demo
     路由（`_auth_users admin:s3cret;...` / `_jwt_secret
     probe-secret-key-42` / `_jwt_ttl_sec`）
   - 认证 gate：`_auth == "oauth2"` → `check_oauth2`（其余 →
     `check_auth`）；auth 失败分支 `resp_data["status"]` 从
     `auth.status_line` 前 3 字节推导（不再硬编码 "401"）
   - `KIND_OAUTH2_TOKEN`（201）特例：run_handler 返回占位，dispatch 调
     `handle_oauth2_token(handler, body_str)` 覆写（需 body — SSE 同型
     先例），落到公共 send 块（WWW-Authenticate 头经 `auth_www` 透传）
5. **OpenAPI**：任一路由 `_auth == "oauth2"` →
   `components.securitySchemes.OAuth2PasswordBearer = {"type":"http",
   "scheme":"bearer","bearerFormat":"JWT"}` + 该路由 operation 级
   `"security":[{"OAuth2PasswordBearer":[]}]`（与既有 `components.schemas`
   合并进同一 `components` 对象）

## 3.5 文档化偏差

1. **`sub` 空串也拒**：教程 `get_current_user` 仅查 `username is None`
   （空串 `sub` 会通过）；本实现空串一并拒（更严格，安全方向）。
2. **oauth2 分支放 dispatch 而非 `check_auth`**：`check_auth`（security.mojo）
   若 import `security_jwt`（函数级，函数顶），JIT 会材料化
   `security_jwt` 的 FFI 闭包（`fm_hmac_sha256_b64url` / `gettimeofday_ms`
   / `extract_request_header`…），**破坏 security.mojo 的 `mojo run` 自检**
   （JIT 只链 main 可达符号 — 既有 self-test 集合的边界）；dispatch
   （serve_forever）本身已属 JIT 不可链类别（需完整 bridge），接线此处
   **零回归**。`check_auth` 的「单一函数扩展点」语义保留（oauth2 是
   唯一需要 FFI 的认证类型）。
3. **响应体含服务端公共 meta 字段**（`method`/`path`/`handler`/
   `request_id`/`duration_ms`）+ 冒号后空格 JSON：本 server 全路由统一
   约定（KIND_ECHO 序列化），非 /token 端点可单独控制（与所有既有
   端点同类，FastAPI 精确字节对齐在 JSON 序列化层已文档化偏离）。
4. **`/token-exp`（ttl=-1）为本实现测试钩子**：上游 FastAPI 无对应
   （仅 demo 用途，e2e 用「签发即过期」token 验证 exp 校验）。
5. **`_auth_users`（`u:p;u:p` CSV）= 教程硬编码凭据的声明式等价**
   （North Star：无外部 DB / 无用户存储依赖）。

## 4. 风险

| 风险 | 评估 / 缓解 |
|------|------------|
| 手写 SHA-256/HMAC 实现错误（系统性偏差漏进签名） | 4 组 FIPS/RFC known vectors + **pyjwt-2.13 独立实现 oracle 交叉验证**（同一 signing_input 签名逐字符相等）+ e2e 5 个 pyjwt 签发 fixture（T1..T5，独立生成、固定入库）— 双层独立 oracle |
| base64url 宽松解码接受畸形输入 | 宽松只作用于**解码容错**（padding/空白/`+`/`/`）；**签名比对是精确字符串相等** — 畸形 payload 段要么解码失败（claims 校验失败 → 401）要么 HMAC 不等（401）；安全边界不受宽松解码影响 |
| `_json_field` 非完整 JSON 解析（flat 假设） | payload 由本模块生成（flat object，key 顺序确定）；不可信 token 的 payload 只在**签名校验通过前**被解析 — 签名校验失败即 401，claims 解析结果无安全效力（最坏 = 多一种 401 原因）；`"key"` 前字符限 `{`/`,`（顶层近似） |
| Mojo JIT 自检边界变化 | security_jwt 自检只跑纯逻辑（b64url/切分/claims/form — 无 FFI）；签名路径由 e2e 26 项 OT 在 compiled binary 覆盖；security.mojo **零改动**（其自检保持可用 — 与 HEAD 完全一致） |
| http_server_final 进一步膨胀（1148→1187） | 既有超阈值文件（Phase-4 前就 1148）；本 ADR +39 行（3 路由 + gate 分支 + kind 特例）为声明式接线（非新逻辑）；同时 `_parse_form_body`（32 行）移入 request_response 部分对冲；进一步瘦身 = 独立任务（同 ADR-0018 立场） |
| ffi.rs 超「建议 <500」阈值（580→634） | FFI 包装层性质（每符号 ~20 行模板）；与既有 40+ 符号同构，拆分无收益；建议阈值仅约束逻辑模块（AGENTS.md §3.2「建议」） |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`security_jwt → {security, request_response, json, middleware, handler, string_builder}`；`security` **不** import `security_jwt`（模块级/函数级均无 — §3.5-2）；`http_server_final → security_jwt`（无反向）；`request_response → params_query`（`_parse_form_body` 移入后新增，单向）；依赖图零环 |
| 2. 分层向下依赖 | ✅ 遵守 | 加密原语（sha256/hmac/b64url）= Rust bridge（字节级，ADR-0010）；协议语义（3-part/claims/form/状态码）= 纯 Mojo（应用/协议层）；FFI 面仅 +2（`fm_hmac_sha256_b64url[_free]`，决策-36 NUL 契约）；Rust 侧 **零新 crate**（纯 std） |
| 3. God package 阈值 | ⚠️ 遵守（带说明） | security_jwt **497**（新，<500）/ handler **475**（459→475，<500）/ openapi **494**（480→494，<500）/ request_response **258**（223→258，<500）/ security **388**（不变）/ **http_server_final 1187**（1148→1187，既有超阈值 — +39 声明式接线，同时 -32 行 `_parse_form_body` 移出）/ ffi.rs **634**（580→634，Rust「建议」阈值 — 纯 FFI 包装层，§4 说明） |
| 4. 主题域边界清晰 | ✅ 遵守 | `crypto.rs` 只管加密原语（零协议知识，无 HTTP/OAuth 概念）；`security_jwt` 只管 OAuth2/JWT 协议（不碰 fd / socket / env）；`request_response` 只管 Request/Response 设施（`_parse_form_body` 归位）；dispatch 只接线（3 处，全声明式数据驱动） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | FFI diff = **+2**（唯一新增 `extern "C"`：`fm_hmac_sha256_b64url` / `fm_hmac_sha256_b64url_free`，均 `#[no_mangle]` + 内存契约文档化）；**零新增第三方 crate**（crypto.rs 纯 std 手写）；ldd 实测仅 libc；binary **3,326,672 B（3.17M**，≤4.2M 预算；vs 决策-43 3,277,520 B，+49 KB = crypto.rs + FFI + security_jwt + 路由） |
| 6. 测试文件跟随 | ✅ 遵守 | `crypto_tests.rs`（14 测：known vectors ×12 + pyjwt oracle + FFI 交叉验证 ×2）与 `crypto.rs`/`ffi.rs` 同目录；`security_jwt.mojo` 尾部 `mojo run` 纯逻辑自检（~30 check，JIT 可达子集）；e2e **OT-1..OT-25 = 274/274 全绿**（248→274，+26；含 pyjwt 独立签发 fixture T1..T5 + fmtool raw 空 Bearer 精确字节） |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc（**3,326,672 B =
   3.17M**，≤4.2M；vs 决策-43 3,277,520 B，+49 KB）；`env -i ./build/
   fastapi_mojo --port N` 干净启动（health 200 + /token 签发 172 字符 JWT
   + /secure-jwt 接受 — 实测）。
2. **Rust 质量门禁**：`cargo test --release -- --test-threads=1`
   **349 passed / 0 failed / 4 ignored**（335→349，+14 crypto）；
   `cargo clippy --release --tests -- -D warnings` **0 警告**（双 crate，
   含 fmtool）。
3. **e2e 全量**：248 → **274**（+26 OT 项）全绿，覆盖 FastAPI 0.141.1
   全语义矩阵：
   - OT-1..3 签发：200 + 3-part JWT（`eyJhbGciOiJIUzI1NiIs...` 头）+
     `token_type: bearer`
   - OT-4/5 服务端 token → /secure-jwt 200 + `auth_user: admin`
   - OT-6..8 凭据错 → 401 "Incorrect email or password" + WWW-Authenticate
   - OT-9/10 `grant_type=refresh` → 422 string_pattern_mismatch（紧凑
     Pydantic v2：loc/input/ctx 全字段）
   - OT-11/12 username+password 缺失 → 422 双 missing 全收集
   - OT-13 grant 缺省 → 200（0.141.1 宽松模型）
   - OT-14..17 /secure-jwt：无头 401 "Not authenticated" / Basic 401 /
     **空 Bearer（fmtool raw 精确字节）401 "Could not validate
     credentials"**（0.141.1 修正语义）
   - OT-18..22 pyjwt-2.13 独立签发 fixture：T1 有效 200 / T2 过期 401 /
     T3 异 secret 签名 401 / T4 无 sub 401 / T5 alg=none 401
   - OT-23 /token-exp（ttl=-1 签发即过期）→ /secure-jwt 401
   - OT-24/25 OpenAPI：`securitySchemes.OAuth2PasswordBearer`
     （`bearerFormat: JWT`）+ operation 级 `security` 数组
4. **Mojo 自检**：`mojo run` ×8（json / params_query / params_json /
   router / string_builder / params_typed / params_query_extra /
   **security_jwt**）全绿；security.mojo 与 HEAD 逐字节一致（JIT 自检
   边界不变）。
5. **性能**：bench 6 场景 **0 errors**；get_root_10k_100c **41,237
   req/s**（历史区间 32.9k–43.9k 内；bench 热路径 = / + /hello + /items，
   不受 OAuth2 路由影响）。
