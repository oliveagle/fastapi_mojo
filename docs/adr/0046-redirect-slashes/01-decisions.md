# ADR-0046: Starlette `redirect_slashes` 等价（默认尾斜杠 307 重定向）

**状态**：已接受
**日期**：2026-09-12
**决策**：71（Goal-0003 路由面收敛 / `fastapi_mojo-kvd` bead）

## 1. 背景

Starlette `Router` 默认 `redirect_slashes=True`：请求路径未匹配任何路由时，会把
尾部斜杠取反（`/a/b` ↔ `/a/b/`）再试一遍，命中则返回 **307 Temporary Redirect**
到绝对 URL。这是 Starlette/FastAPI 的**默认路由行为**，此前本仓库未实现（矩阵
中记为「非路由自动尾斜杠重定向单独跟踪」）。

**上游实测（fastapi 0.141.1 + starlette 1.6.0，`/tmp/fm_slash_probe`）**：

| 请求 | 结果 |
|---|---|
| `GET /items`（注册 `/items/`） | 307 `Location: http://testserver/items/` |
| `GET /items?x=1&y=2` | 307 `Location: http://testserver/items/?x=1&y=2`（query 保留） |
| `POST /create/`（注册 `POST /create`） | 307 `Location: http://testserver/create` |
| `GET /create/`（method 不匹配 alt） | 307（**method 无关**：`match != NONE`，PARTIAL 也重定向） |
| `HEAD /items` | 307（HEAD 视为 GET） |
| `GET /items//` | **404**（`rstrip("/")` 去掉**全部**尾斜杠 → `/items` 不存在） |
| `GET /nope` / `GET /nope/` | 404 |

上游 `starlette/routing.py`：

```python
if scope["type"] == "http" and self.redirect_slashes and route_path != "/":
    redirect_scope = dict(scope)
    if route_path.endswith("/"):
        redirect_scope["path"] = redirect_scope["path"].rstrip("/")
    else:
        redirect_scope["path"] = redirect_scope["path"] + "/"
    for route in self.routes:
        match, child_scope = route.matches(redirect_scope)
        if match != Match.NONE:
            response = RedirectResponse(url=str(URL(scope=redirect_scope)))
            ...
```

- `route_path != "/"` → 根路径不重定向。
- `Location` = `URL(scope=redirect_scope)` = **绝对 URL** `scheme://host<alt>?<query>`
  （scheme/host 取自 ASGI scope，host 来自 Host 头）。
- 响应 = `RedirectResponse`（继承决策-68 wire 形态：无 Content-Type +
  `Content-Length: 0` + `Location` + 空 body）。
- method 无关：`route.matches` 只要求 path 命中（FULL 或 PARTIAL）。

## 2. 目标

1. 未匹配路径 → alt 路径命中（method 无关）→ 307 绝对 URL；否则保持 404；
2. 复用决策-68 `send_redirect_response`（wire 形态零新增 FFI）；
3. `rstrip` 全部尾斜杠语义；根路径 `/` 不重定向；
4. 零新依赖 / **FFI diff = 0** / North Star 不变。

## 3. 决策

### 3.1 纯逻辑模块 `redirect_slashes.mojo`

| 函数 | 语义 |
|---|---|
| `alt_slash_path(path)` | `/a/b` → `/a/b/`；`/a/b/` → `/a/b`（rstrip **全部**尾斜杠）；`/` 或空 → `""` |
| `build_redirect_location(scheme, host, path, query)` | `scheme://host<path>[?<query>]` |

含 `main()` 自检（`mojo run redirect_slashes.mojo`），dispatch 侧零逻辑。

### 3.2 dispatch 接线

在 `http_server_final.mojo` 的「未匹配」分支（原本 405/404 判定处）：
- `alt = alt_slash_path(path)`；`alt != ""` 且 `router.methods_for_path(alt)` 非空
  （path 命中，method 无关）→ 发送 307：
  - scheme：`FASTAPI_MOJO_TLS_CERT/KEY` 均置 → `https`，否则 `http`（与 OpenAPI servers 同源）。
  - host：`Host` 头；缺失 → `127.0.0.1:<get_configured_port>`（上游 scope server 兜底）。
  - `send_redirect_response(cfd, "307 Temporary Redirect", location)`（决策-68 复用，
    内部按上游 safe set quote）。
  - `_finish_request(... "307 Temporary Redirect (slash-redirect)")` + `conn_done` + `continue`。
- 否则维持既有 404。

### 3.3 支撑修复：fmtool testclient Host 端口

fmtool testclient 此前把 `Host: <host>`（**无端口**）发给服务器，导致绝对
`Location` 丢端口（`http://127.0.0.1/slash/` 而非 `:PORT`），follow 时连到错误端口。
**修复**：`Host` 对齐真实客户端/httpx —— 非默认端口带端口
（`port == 80 ? host : host:port`），与既有 WS testclient（`parts.addr()`）一致。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 在 router 匹配层内置 alt 尝试 | 拒绝 | dispatch 已掌控 405/404 判定，就地加即可；router 保持纯匹配 |
| 只做相对 Location（`/items/`） | 拒绝 | 上游是绝对 URL，破坏 wire parity |
| 不改 fmtool Host | 拒绝 | follow 测试无法覆盖绝对 Location（连错端口） |
| 纯逻辑模块 + dispatch 接线 + Host 修复 | 接受 | 零 FFI、wire 一致、dev 工具回归真实客户端 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `redirect_slashes` 无 import；dispatch 单向依赖它 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯逻辑模块 → dispatch 使用者；无反向 |
| 3. God package 阈值 | ✅ 遵守 | `redirect_slashes.mojo` ~70；`http_server_final.mojo` 既有超阈值文件（grandfathered） |
| 4. 主题域边界清晰 | ✅ 遵守 | 路由斜杠归一 = routing 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（复用 `send_redirect_response`）；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | `redirect_slashes.mojo` 自检 + e2e SL-1..SL-10；fmtool 35 单测保持 |

## 6. 验收（2026-09-12）

- e2e **567 → 577/577**（SL-1..SL-10）。
- canonical `./benchmark.sh` 6 场景 **0 errors**。
- cargo bridge **500/0/4**；clippy 双 crate `-D warnings` 0；fmtool **35/0**。
- `ldd build/fastapi_mojo` 仅 libc / loader / vdso；`env -i` 干净启动 200。
- binary ≤6 MiB；C=Python=orphans 0。

## 7. 实现 / 边界

- `src/fastapi_mojo/redirect_slashes.mojo`（新增）：纯逻辑 + 自检。
- `src/fastapi_mojo/http_server_final.mojo`：import + 未匹配分支接线 + `/slash/`、`/slashpost` demo。
- `src/fmtool/src/testclient/http.rs`：Host 端口修复。
- `scripts/e2e_test.sh`：SL-1..SL-10。

边界：内置文档/指标特殊路径（`/openapi.json`、`/docs`、`/metrics`、`/traces`）走
router **之前**的特判，未纳入 slash-redirect（声明式路由才是本决策覆盖面）；
redirect 无 body，故不触发 GZip/用户中间件 response 面（与决策-68 同型）。
