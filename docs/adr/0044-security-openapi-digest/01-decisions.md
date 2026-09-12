# ADR-0044: 安全 OpenAPI 对齐（securitySchemes 全量 + operation security）+ HTTPDigest

**状态**：已接受
**日期**：2026-09-12
**决策**：69（Goal-0003 矩阵 #17 安全面收敛 / `security-openapi-digest` bead）

## 1. 背景

决策-34 (ADR-0011) 落地了 HTTPBasic / HTTPBearer / APIKey 的**运行时**认证，
决策-44 (ADR-0019) 落地 OAuth2/JWT，决策-67 (ADR-0042) 落地 scopes。
但两个公开 API 面仍未对齐上游：

1. **OpenAPI securitySchemes 只导出 oauth2**：`openapi.mojo` 仅在有
   `_auth=oauth2` 路由时写 `components.securitySchemes.OAuth2PasswordBearer`；
   basic/bearer/apikey 路由**完全不导出** securityScheme 与 operation `security`。
   上游 FastAPI 对每个 `Depends(security)` 依赖都会导出对应 scheme + operation security。
2. **`fastapi.security.HTTPDigest` 无运行时等价**：上游是公开类（stub，只校验
   scheme 不实现完整 digest）。

顺带发现一个 **pre-existing OpenAPI bug**：`paths` 的 method 关键字用**大写**
（`"GET"`）而非 OpenAPI 3.0 规定的固定小写字段（`get`），导致 Swagger UI 无法
渲染任何 operation（`/docs` 一直是空壳）。

**上游实测（fastapi 0.141.1 + starlette 1.6.0，`/tmp/fm_digest_probe` /
`/tmp/fm_sec_probe`）**：

- securityScheme 键名默认 = 类名；JSON 形态：
  - `HTTPBasic` → `{"type":"http","scheme":"basic"}`
  - `HTTPBearer` → `{"type":"http","scheme":"bearer"}`
  - `HTTPDigest` → `{"type":"http","scheme":"digest"}`
  - `APIKeyHeader` → `{"type":"apiKey","in":"header","name":"<n>"}`（键序 type,in,name）
  - `APIKeyQuery` → `{"type":"apiKey","in":"query","name":"<n>"}`
  - `APIKeyCookie` → `{"type":"apiKey","in":"cookie","name":"<n>"}`
- operation security = `[{"<scheme>":[]}]`（无 scopes）；oauth2 带 scope 数组。
- HTTPDigest 运行时：缺 Authorization / scheme（大小写不敏感）≠ digest / 空 credentials
  → **401 `{"detail":"Not authenticated"}` + `WWW-Authenticate: Digest`**；否则返回
  `(scheme 原样大小写, credentials)`。

## 2. 目标

1. HTTPDigest stub parity（`_auth=digest`，401 + `WWW-Authenticate: Digest`，
   注入 `auth_scheme`/`auth_credentials`）；
2. OpenAPI `components.securitySchemes` 全量（basic/bearer/digest/apikey/oauth2）；
3. operation `security` 数组覆盖所有 `_auth` 路由；`_auth_scheme_name` 覆盖默认名
   （上游 `scheme_name=`）；
4. 修复 `paths` method 关键字大写 bug（OpenAPI 3.0 固定小写）；
5. 零新依赖 / FFI diff = 0 / North Star 不变；文件 < 500 行（新模块拆分）。

## 3. 决策

### 3.1 声明式 surface

| 键 | 语义 |
|---|---|
| `_auth="digest"` | HTTPDigest stub 等价（运行时 scheme 校验） |
| `_auth_scheme_name` | 可选，覆盖默认 securityScheme 名（上游 `scheme_name=`） |

默认 scheme 名派生：`basic→HTTPBasic` / `bearer→HTTPBearer` / `digest→HTTPDigest` /
`apikey:header→APIKeyHeader` / `apikey:query→APIKeyQuery` /
`apikey:cookie→APIKeyCookie` / `oauth2→OAuth2PasswordBearer`。

### 3.2 运行时（`security.mojo`）

- 新增 `AuthResult.auth_scheme` / `auth_credentials`。
- `check_auth` 新增 `digest` 分支：`_eq_ci(scheme, "digest")` + 非空 credentials；
  否则 401 `Not authenticated` + `WWW-Authenticate: Digest`（无 realm）；成功注入
  `auth_scheme`（原样大小写）/ `auth_credentials`。
- dispatch 增 `auth_scheme` / `auth_credentials` 注入（与既有 `auth_*` 同型）。

### 3.3 OpenAPI（新模块 `openapi_security.mojo`）

- 从 `openapi.mojo` 拆出（该文件决策-67 后已 513 行，超 God-package 500 阈值）：
  `_split_semi` / `_security_scopes_json` / `_oauth2_scheme_scopes_json` /
  `_default_scheme_name` / `_auth_scheme_name` / `_auth_scheme_json` +
  两个公开入口 `operation_security_json(h)` / `security_schemes_json(router)`。
- `openapi.mojo` 只 import 两个入口，回落到 **444 行**（< 500）。
- **附带修复**：`paths` method 关键字 `lower_ascii(method)`（上游小写）。

### 3.4 语义边界（文档化偏差）

- HTTPDigest 是**上游 stub**：只校验 scheme，不做 RFC 7616 摘要校验（上游同款，
  用户需 self-subclass 实现）——本实现 = 声明式等价，不新增摘要算法。
- `_auth=basic/bearer/apikey` 的运行时语义仍是「白名单校验」（ADR-0011 既有），
  非上游「仅解析」。OpenAPI 形态与上游一致。
- 401 body 沿用本仓库 `{detail,status}`（上游仅 `{detail}`）。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 只加 HTTPDigest 运行时、不动 OpenAPI | 拒绝 | securitySchemes 缺失是真实 parity 缺口 |
| 在 openapi.mojo 内继续堆（>500 行） | 拒绝 | 违反 AGENTS §3.2 God-package 阈值 |
| 拆 `openapi_security.mojo` + digest 运行时 | 接受 | 单一职责、零 FFI、`/docs` 恢复可用 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `openapi → openapi_security → {router,handler,json}`；无反向 |
| 2. 分层向下依赖 | ✅ 遵守 | 运行时 = 协议层 `security.mojo`；文档 = `openapi_security.mojo`（只读声明） |
| 3. God package 阈值 | ✅ 遵守 | `openapi.mojo` 513→444；新模块 212；`security.mojo` 433；均 < 500 |
| 4. 主题域边界清晰 | ✅ 遵守 | securityScheme 生成单独成模块；digest 属 security 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（复用 `extract_request_header`）；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | e2e DG-1..DG-6 / SO-1..SO-5；canonical mojo 自检不变 |

## 6. 验收（2026-09-12）

- e2e **545 → 556/556**（DG-1..6 HTTPDigest 运行时 + SO-1..5 securitySchemes /
  operation security / `_auth_scheme_name` / method 小写）。
- canonical `./benchmark.sh` 6 场景 **0 errors**。
- cargo bridge **500/0/4**；clippy 双 crate `-D warnings` 0；fmtool **35/0**。
- `ldd build/fastapi_mojo` 仅 libc / loader / vdso；`env -i` 干净启动 200。
- binary **5,020,000 B**（≤6 MiB）；C=Python=orphans 0。
- OpenAPI 全文档 `jsoncheck` 通过；securitySchemes 与上游 probe 逐字段一致。

## 7. 实现 / 边界

- `src/fastapi_mojo/security.mojo`：`AuthResult.auth_scheme/auth_credentials`；
  `_eq_ci`；`digest` 分支。
- `src/fastapi_mojo/openapi_security.mojo`（新增 212 行）：scheme 派生 + 两个入口。
- `src/fastapi_mojo/openapi.mojo`：import 入口 + method 小写（513→444 行）。
- `src/fastapi_mojo/http_server_final.mojo`：`auth_scheme/auth_credentials` 注入 +
  `/digest` / `/basic-alt` demo。
- `scripts/e2e_test.sh`：DG-1..6 / SO-1..5；OT-24 断言改序无关。
