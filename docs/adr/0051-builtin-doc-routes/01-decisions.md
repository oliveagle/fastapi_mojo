# ADR-0051: FastAPI 默认内置文档路由补全（`/redoc` + `/docs/oauth2-redirect`）

**状态**：已接受
**日期**：2026-09-12
**决策**：76（Goal-0003 §1 矩阵 #16 OpenAPI / `fastapi_mojo-redoc-oauth2-redirect-oxc` bead）

## 1. 背景

上游 FastAPI 实例默认注册 **4 条内置路由**（0.141.1 实测 `app.routes`）：

```
/openapi.json         openapi              GET, HEAD
/docs                 swagger_ui_html      GET, HEAD
/docs/oauth2-redirect swagger_ui_redirect  GET, HEAD
/redoc                redoc_html           GET, HEAD
```

本仓库此前只内置 `/openapi.json` 与 `/docs`（决策-52 精化 OpenAPI 时未补全其余两条）。
实测（当前产物）：

```
GET  /redoc                  -> 404 application/json
GET  /docs/oauth2-redirect   -> 404 application/json
GET  /docs                   -> 200 text/html     (HEAD 归一为 GET, 200)
```

即 FastAPI 默认公开文档面**缺 2 条路由**：ReDoc 交互文档页 与 Swagger UI 的 OAuth2
回调页（后者正是 `/docs` 的 `oauth2RedirectUrl` 目标）。

## 2. 目标

1. 补齐 `/redoc` 与 `/docs/oauth2-redirect`（GET + HEAD，与既有 `/docs` 同归一机制）；
2. HTML 形态对齐上游（ReDoc `spec-url` / Swagger oauth2-redirect 脚本）；
3. 标题与 `/openapi.json`、`/docs` 同源（`FASTAPI_MOJO_OPENAPI_TITLE` env 或默认）；
4. `/docs` 的 SwaggerUIBundle 配置补 `oauth2RedirectUrl`（指向新回调页，上游一致）；
5. **FFI diff = 0 / 零新依赖**（纯 Mojo HTML 构造 + 既有 `send_html_response`）。

## 3. 决策

### 3.1 `openapi.mojo` 新增两个纯函数

- `redoc_html(title, openapi_url)` —— `<title>{title} - ReDoc</title>` +
  `<redoc spec-url="{openapi_url}">` + jsdelivr `redoc@2` standalone bundle +
  upstream 同款 `<noscript>`/favicon/viewport 标记。
- `swagger_ui_oauth2_redirect_html()` —— **逐字对齐**上游
  `get_swagger_ui_oauth2_redirect_html`（无参数；浏览器端 `window.opener.swaggerUIRedirectOauth2`
  回调脚本，含 state 校验 / accessCode / 错误分支 / `window.close()`）。
- `swagger_ui_html` 配置追加 `oauth2RedirectUrl:window.location.origin+"/docs/oauth2-redirect"`
  （上游 `/docs` 同款）。

### 3.2 `http_server_final.mojo` 新增两条内置分支

- 紧邻既有 `/docs` 分支（`effective_method == "GET"`）；
- `/redoc` 标题读 `FASTAPI_MOJO_OPENAPI_TITLE`（与 `/docs`/`/openapi.json` 同源）；
- 均走 `send_html_response` + `_finish_request` telemetry + `conn_done`（与 `/docs` 同型）；
- HEAD 由既有 `is_head`/`effective_method` 归一自动覆盖（无需额外分支）。

### 3.3 e2e

- DOC-1a/1b：`/redoc` 200 + `text/html; charset=utf-8` + `spec-url="/openapi.json"`。
- DOC-2：`/docs/oauth2-redirect` 200 + `swaggerUIRedirectOauth2`。
- DOC-3：`HEAD /redoc` → 200（上游 HEAD parity）。
- DOC-4：`/docs` 含 `oauth2RedirectUrl … /docs/oauth2-redirect`。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 只补 `/redoc` | 拒绝 | `/docs/oauth2-redirect` 是上游默认路由且被 `/docs` 引用，同为缺口 |
| 改 `/docs` 为上游逐字节 HTML | 拒绝 | 既有 `/docs`（unpkg CDN + 精简引导）已 e2e 守护（`SwaggerUIBundle`/title），本轮不翻案以避免回归 |
| 新增 FFI 发送入口 | 拒绝 | 复用既有 `send_html_response`，FFI diff=0 |
| 新增两个纯构造函数 + 两条分支 | 接受 | 面最小, 语义对齐, 零回归 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `openapi` 仅被 `http_server_final` 单向依赖；新函数无新依赖 |
| 2. 分层向下依赖 | ✅ 遵守 | HTML 构造（Mojo 协议层）→ 发送（既有 bridge 原语）；无反向 |
| 3. God package 阈值 | ✅ 遵守 | `openapi.mojo` 净增 ~75 行；`http_server_final.mojo` 既有 >500 豁免 |
| 4. 主题域边界清晰 | ✅ 遵守 | 内置文档页 = OpenAPI/文档域；路由接线 = dispatch 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出、零新 crate、零新依赖） |
| 6. 测试文件跟随 | ✅ 遵守 | e2e DOC-1..4（主 server） |

## 6. 验收（2026-09-12）

- e2e **595 → 600/600**（DOC-1a/1b/2/3/4）。
- cargo bridge **505/0/4**（本轮无 Rust 改动）；clippy 双 crate 0；fmtool **35/0**。
- canonical `./benchmark.sh` 6 场景 **0 errors**（get_root_10k_100c ≈ 31.0k req/s）。
- `ldd` 仅 libc；`env -i` 干净启动 200（且 `/redoc` 200）；binary 5,089,704 B（≤6 MiB）；
  C=Python=orphans 0。
- 实测：`GET/HEAD /redoc` 200 text/html（`spec-url="/openapi.json"`）；
  `GET/HEAD /docs/oauth2-redirect` 200 text/html（`swaggerUIRedirectOauth2`）；
  `/docs` 含 `oauth2RedirectUrl`。

## 7. 实现 / 边界

- `src/fastapi_mojo/openapi.mojo`：`redoc_html` / `swagger_ui_oauth2_redirect_html` +
  `swagger_ui_html` 补 `oauth2RedirectUrl`。
- `src/fastapi_mojo/http_server_final.mojo`：`/redoc`、`/docs/oauth2-redirect` 分支 + import。
- `scripts/e2e_test.sh`：DOC-1..4。

边界：两条内置路由**固定路径**（上游 `FastAPI(docs_url=/redoc_url=None)` 可禁用/改路径，
本仓库未建模该配置面 —— 与既有 `/docs` 固定路径一致，文档化）；HEAD 沿用既有内置分支
行为（发送完整 HTML body，未做 body 抑制；上游 HEAD 长度为 0 —— 既存偏差，`/docs` 同款，
本轮不翻案）；`/redoc`/`/docs` HTML 引用 CDN（离线场景可替换本地 dist，`/docs` 既有注释同款）。
