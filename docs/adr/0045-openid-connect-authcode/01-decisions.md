# ADR-0045: 安全面收敛之二 — OpenIdConnect + OAuth2AuthorizationCodeBearer

**状态**：已接受
**日期**：2026-09-12
**决策**：70（Goal-0003 矩阵 #17 安全面收敛 / `security-openapi-digest` 后续）

## 1. 背景

决策-69（ADR-0044）补齐了 HTTPDigest 运行时 + OpenAPI securitySchemes 全量
（basic/bearer/digest/apikey/oauth2-password）。逐类审计上游 `fastapi.security`
后仍有 2 个公开 security 类无运行时等价：

| 上游类 | 现状 |
|---|---|
| `OpenIdConnect` | ❌ 无 |
| `OAuth2AuthorizationCodeBearer` | ❌ 无（仅有 password 形态的 `_auth=oauth2`） |

**上游实测（fastapi 0.141.1 + starlette 1.6.0，`/tmp/fm_sec2_probe`）**：

- `OpenIdConnect(openIdConnectUrl=...)`：**stub，只校验 `Authorization` 头是否
  存在**；缺失/空 → **401 `{"detail":"Not authenticated"}` + `WWW-Authenticate: Bearer`**；
  存在（任意 scheme，含 `Basic x` / `Bearer tok`）→ 200 且把**整个原始头**作为
  依赖返回值。
- `OAuth2AuthorizationCodeBearer(authorizationUrl=..., tokenUrl=...)`：运行时 =
  与 `OAuth2PasswordBearer` 同族 —— scheme（大小写不敏感）必须为 `bearer`，
  返回 `param`（**允许空**，如 `Bearer` 裸头 → 200 + `""`）；缺失/非 bearer →
  401 `Not authenticated` + `WWW-Authenticate: Bearer`。
- OpenAPI securityScheme：
  - `OpenIdConnect` → `{"type":"openIdConnect","openIdConnectUrl":"<url>"}`
  - `OAuth2AuthorizationCodeBearer` →
    `{"type":"oauth2","flows":{"authorizationCode":{"scopes":{...},"authorizationUrl":"<au>","tokenUrl":"<tu>"}}}`
  - operation security 恒 `[{"<scheme>":[]}]`（无 scope）。

## 2. 目标

1. `_auth="openid"` 运行时 + OpenAPI `openIdConnect` scheme；
2. `_auth="authcode"` 运行时 + OpenAPI `authorizationCode` flow；
3. 两套声明键与既有 password flow **完全隔离**（不得污染 `OAuth2PasswordBearer`
   的 tokenUrl/scopes）；
4. 零新依赖 / FFI diff = 0 / North Star 不变；文件 < 500 行。

## 3. 决策

### 3.1 声明式 surface

| 键 | 语义 | 上游对应 |
|---|---|---|
| `_auth="openid"` | OpenIdConnect stub（只校验 Authorization 头存在） | `Depends(OpenIdConnect(...))` |
| `_openid_url` | OpenAPI `openIdConnectUrl` | `openIdConnectUrl=` |
| `_auth="authcode"` | OAuth2AuthorizationCodeBearer 运行时（Bearer 提取） | `Depends(OAuth2AuthorizationCodeBearer(...))` |
| `_authcode_authorization_url` | OpenAPI `authorizationUrl` | `authorizationUrl=` |
| `_authcode_token_url` | OpenAPI `tokenUrl` | `tokenUrl=` |
| `_authcode_scopes` | OpenAPI `scopes` 对象（`name=desc;...`） | `scopes=` |

默认 securityScheme 名：`openid → OpenIdConnect`、`authcode →
OAuth2AuthorizationCodeBearer`（`_auth_scheme_name` 可覆盖，决策-69）。

### 3.2 运行时映射

- **openid**：`_get_header("Authorization") == ""` → 401 detail `Not authenticated`
  + `WWW-Authenticate: Bearer`；否则 ok 并注入 `auth_credentials` = **原始头**
  （与上游依赖返回值 = 原始 authorization 一致）。
- **authcode**：首个空格切 scheme/param；缺 / scheme 大小写不敏感 ≠ `bearer`
  → 401 + `WWW-Authenticate: Bearer`；否则 ok 并注入 `auth_token` = param
  （param 空 → `auth_token` 为空则不注入，仍 200 = 上游）。

### 3.3 键隔离（防污染）

`_oauth2_scheme_scopes_json(router, code)` 增加 `code` 选择器：

| | password（`code=False`） | authorizationCode（`code=True`） |
|---|---|---|
| scopes 键 | `_oauth2_scopes` | `_authcode_scopes` |
| token url 键 | `_oauth2_token_url`（默认 `"token"`） | `_authcode_token_url`（默认 `""`） |
| authz url 键 | — | `_authcode_authorization_url` |

两套键故意分离，避免同名路由并存时 `tokenUrl`/`scopes` 互相覆盖
（e2e AC-7 守护：password scheme 仍 `tokenUrl":"token"`）。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 复用 `_auth=oauth2` + 标志位区分 flow | 拒绝 | password 与 authorizationCode 是两个 scheme 名，混一会污染去重/名 |
| authcode 复用 `_oauth2_token_url` | 拒绝 | 与 password 路由并存时 last-wins 覆盖 tokenUrl |
| 独立 `_authcode_*` 键 + openid 分支 | 接受 | 键隔离、零 FFI、默认名区分 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `openapi → openapi_security → {router,handler,json}`；无反向 |
| 2. 分层向下依赖 | ✅ 遵守 | 运行时 = `security.mojo`；文档 = `openapi_security.mojo`（只读声明） |
| 3. God package 阈值 | ✅ 遵守 | `openapi_security.mojo` 244；`security.mojo` 472；均 < 500 |
| 4. 主题域边界清晰 | ✅ 遵守 | 新 scheme 全部落在 security/openapi-security 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（复用 `extract_request_header`）；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | e2e OI-1..4 / AC-1..7；canonical mojo 自检不变 |

## 6. 验收（2026-09-12）

- e2e **556 → 567/567**（OI-1..4 + AC-1..7）。
- canonical `./benchmark.sh` 6 场景 **0 errors**。
- cargo bridge **500/0/4**；clippy 双 crate `-D warnings` 0；fmtool **35/0**。
- `ldd build/fastapi_mojo` 仅 libc / loader / vdso；`env -i` 干净启动 200。
- binary ≤6 MiB；C=Python=orphans 0。
- OpenAPI `securitySchemes` 与上游 probe 逐字段/键序一致；password flow 未污染。

## 7. 实现 / 边界

- `src/fastapi_mojo/security.mojo`：`authcode` / `openid` 两个 `check_auth` 分支。
- `src/fastapi_mojo/openapi_security.mojo`：`_default_scheme_name` + authcode/openid；
  `_auth_scheme_json(auth, h)`（openid 需 handler 上 `_openid_url`，改 `raises`）；
  `_oauth2_scheme_scopes_json(router, code)` 键隔离。
- `src/fastapi_mojo/http_server_final.mojo`：`/openid` + `/authcode` demo。
- `scripts/e2e_test.sh`：OI-1..4 / AC-1..7。

边界：openid = 上游 stub（不校验 token）；authcode = 只提取 Bearer（不校验 JWT，
上游同款；本仓库 `_auth=oauth2` 的内建 JWT 校验是既有更强形态）；param 为空时
`auth_token` 不注入（注入约定：空值跳过）。
