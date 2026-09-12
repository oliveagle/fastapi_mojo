# ADR-0042: OAuth2 作用域（Security scopes / SecurityScopes parity）

**状态**：已接受
**日期**：2026-09-12
**决策**：67（Goal-0003 矩阵 #17 OAuth2/JWT 精化 / `oauth2-scopes` bead）

## 1. 背景

决策-44 (ADR-0019) 落地了 OAuth2 password flow + JWT (HS256) + `get_current_user`
等价（`check_oauth2`），但**作用域（scopes）**未实现：ADR-0011 明确记录
「APIKey cookie 位置 + bearer scope / role 校验（P2）」，ADR-0019 亦未纳入。
FastAPI 的 Advanced Security 用法 `Security(get_current_user, scopes=[...])` +
`SecurityScopes` 是上游公开 API 面的一部分（矩阵 #17）。

**上游实测（fastapi 0.141.1 + starlette 1.6.0 + pyjwt，`/tmp/fm_scope_probe/*.py`
逐条 probe）**：

- `OAuth2PasswordBearer(tokenUrl="token", scopes={...})` 的 OpenAPI securityScheme
  = `{"type":"oauth2","flows":{"password":{"scopes":{...},"tokenUrl":"token"}}}`；
  `scopes` 键恒存在（即使空 = `{}`）；键序 `type, flows, password{scopes, tokenUrl}`。
- operation 级 `security` = `[{"OAuth2PasswordBearer":["<scope>",...]}]`
  （按 `Security(..., scopes=[...])` 声明顺序；无 scope = `[]`）。
- 无 Authorization → 401 `{"detail":"Not authenticated"}`，
  `WWW-Authenticate: Bearer`（框架在依赖运行前抛出，**不带** scope 片段）。
- Authorization 存在但 token 无效 → 401 `{"detail":"Could not validate credentials"}`，
  `WWW-Authenticate: Bearer scope="<space-joined required>"`（声明 scope 时）。
- token 有效但缺 scope → 403 `{"detail":"Not enough permissions"}`，
  `WWW-Authenticate: Bearer scope="<space-joined required>"`。
- 教程 `get_current_user` 检查 `security_scopes.scopes` ⊆ token scopes；
  `security_scopes.scope_str` = 空格连接 —— 这属**用户代码**，本仓库的等价物
  是 `check_oauth2`（get_current_user 等价），故作用域校验落在 `check_oauth2`。

## 2. 目标

1. `Security(dep, scopes=[...])` 的 wire 语义（401/403 + WWW-Authenticate scope 片段）；
2. OpenAPI securityScheme = 上游 oauth2 flows 形态（含 scopes + tokenUrl）；
3. operation 级 `security` scope 数组；
4. 默认行为零扰动（未声明 `_auth_scopes` 的路由与既有 token 完全不变）；
5. 零新依赖 / FFI diff = 0 / North Star（Mojo + Rust only 单 binary）不变。

## 3. 决策

### 3.1 声明式 surface（延续 handler.data 范式）

| 键 | 位置 | 语义 |
|---|---|---|
| `_auth_scopes` | `_auth=oauth2` 路由 | 必需 scope（`;` 分隔；scope 名可含 `:`）→ 403 gate + OpenAPI operation security |
| `_jwt_scopes` | `KIND_OAUTH2_TOKEN` token 路由 | 签发 token 的 `scope` claim（声明 `;` 分隔 → claim 用空格 join，RFC 6749） |
| `_oauth2_scopes` | token 路由 | securityScheme scopes 对象（`name=desc;name=desc`） |
| `_oauth2_token_url` | token 路由 | securityScheme `tokenUrl`（默认 `"token"`，对齐上游教程） |

无 `_auth_scopes` = 既有行为（无 scope gate）；无 `_jwt_scopes` = token 不含
`scope` claim（既有 token 形态不变）。

### 3.2 请求期 gate（`check_oauth2`）

- 读 `_auth_scopes` → 必需列表；声明非空时 `scoped_www = Bearer scope="<space-joined>"`。
- 无 Authorization / scheme≠bearer → 401 `Not authenticated`，`WWW-Authenticate: Bearer`（无 scope 片段，对齐上游框架先抛）。
- token 校验失败 → 401 `Could not validate credentials`，`WWW-Authenticate: scoped_www`（声明 scope 时）。
- token 有效但 `scope` claim 未覆盖全部必需 scope → **403 `Not enough permissions`**，`WWW-Authenticate: scoped_www`。
- 成功 → 注入 `auth_user` / `auth_token`（不变）。

### 3.3 OpenAPI

- operation security：`_auth_scopes` → `[{"OAuth2PasswordBearer":[...]}]`；无 = `[]`（既有）。
- securityScheme（存在 oauth2 路由时）：`{"OAuth2PasswordBearer":{"type":"oauth2","flows":{"password":{"scopes":{...},"tokenUrl":"..."}}}}`；
  扫描路由表取 token 路由声明的 `_oauth2_scopes` / `_oauth2_token_url`。
- **修正既有偏差**：决策-44 前的 `type:http`/`bearerFormat:JWT` 形态并非上游
  `OAuth2PasswordBearer` 输出；本轮改为上游 oauth2 flows 形态。

### 3.4 语义边界（文档化偏差）

- 403 body 沿用本仓库 F2 约定 `{"detail":..., "status":"403"}`（上游仅 `{"detail":...}`）。
- 作用域校验内建在 `check_oauth2`（教程里是用户 `get_current_user`）；声明式
  `_depends` 依赖不接收 `SecurityScopes` 对象（Mojo 无闭包，依赖面仍是字符串 tag）。
- `_jwt_scopes` 是静态声明（教程里按用户动态授予）；多用户差异化作用域需扩展声明面。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 完整 `Security(...)` DSL + `SecurityScopes` 对象 | 拒绝 | Mojo 无闭包/对象；与 ADR-0004/0014 声明式范式冲突 |
| 作用域校验放 dispatch 而非 `check_oauth2` | 拒绝 | 教程 `get_current_user` 即本仓库 `check_oauth2`；放此处最贴近上游语义 |
| 保持 securityScheme `type:http` | 拒绝 | 非上游 `OAuth2PasswordBearer` 输出；本决策一并修正 |
| 声明式 `_auth_scopes` 字符串 + check_oauth2 内建校验 | 接受 | 零新 FFI、单一扩展点、默认零扰动 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `security_jwt → security/request_response/json`；`openapi → openapi_custom/json`；无反向依赖 |
| 2. 分层向下依赖 | ✅ 遵守 | 协议层（security_jwt）只做 scope 语义；文档层（openapi）只读声明；无 I/O 交叉 |
| 3. God package 阈值 | ✅ 遵守 | 无新模块；`security_jwt.mojo` / `openapi.mojo` 均在既有规模内，新增函数 <500 行预算 |
| 4. 主题域边界清晰 | ✅ 遵守 | scope 解析/校验归 OAuth2 域；OpenAPI 只管文档生成（读声明，不反向写） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（复用既有 HMAC FFI 与 send 路径）；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | `security_jwt.mojo` `main()` 自检扩 scope 向量；e2e OT-24..OT-33 覆盖真实 binary |

## 6. 验收（2026-09-12）

- Mojo `mojo run security_jwt.mojo` 自检通过（scopes_of / has_scope / claim 解析）。
- e2e **527 → 535/535**（OT-24/25 改为 oauth2 flows + scoped security；新增 OT-26..OT-33）。
- canonical `./benchmark.sh` 6 场景 **0 errors**（get_root_10k_100c = 34,106.41 req/s，噪声区间）。
- `ldd build/fastapi_mojo` 仅 libc / loader / vdso；env-i 干净启动（HTTP 200）。
- binary **4,991,328 B**（≤6 MiB；FFI diff = 0，纯 Mojo 改动）；C=Python=orphans 0。
- cargo bridge **496 passed / 0 failed / 4 ignored**；clippy `--release --tests -D warnings` 0 警告。
- OpenAPI securityScheme / operation security 与上游 probe 逐字段一致。

## 7. 实现 / 边界

- `src/fastapi_mojo/security_jwt.mojo`：`JwtVerify.scopes` + `_check_claims` scope claim；
  `_scopes_of` / `_has_scope`；`check_oauth2` scope gate（401/403 + scoped www）；
  `handle_oauth2_token` 签发 `scope` claim。
- `src/fastapi_mojo/openapi.mojo`：`_split_semi` / `_security_scopes_json` /
  `_oauth2_scheme_scopes_json`；operation security + oauth2 flows securityScheme。
- `src/fastapi_mojo/http_server_final.mojo`：token 路由 `_jwt_scopes` / `_oauth2_scopes` /
  `_oauth2_token_url`；demo `/secure-jwt/items`（需 items:read）/ `/secure-jwt/admin`（需 admin → 403）。
- `scripts/e2e_test.sh`：OT-24..OT-33。
