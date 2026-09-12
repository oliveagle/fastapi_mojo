# ADR-0048: Starlette `CORSMiddleware` 全量等价（预检 wire + regex/expose/PNA）

**状态**：已接受
**日期**：2026-09-12
**决策**：73（Goal-0003 §1 矩阵 #15 CORS / `fastapi_mojo-utm` bead）

## 1. 背景

决策-42（ADR-0017）落地了 CORS 声明式 env 等价，但相对上游 Starlette 1.6.0
`CORSMiddleware` 仍有**语义偏差**（ADR-0017 §3.2 文档化部分 + 若干未实现配置面）：

| 项 | 本仓库（决策-42） | 上游 Starlette 1.6.0 |
|---|---|---|
| 预检成功 | 204 空体 | **200 + `text/plain; charset=utf-8`** body `OK` |
| 预检失败 | 400 + JSON `{"error":..,"status":..}` | **400 + text/plain** body `Disallowed CORS <failures>`（`origin`/`method`/`headers`/`private-network` 逗号连接） |
| 失败预检头 | 无 | **完整 preflight 头集**仍发出（Allow-Methods/Max-Age/…） |
| `Vary: Origin` | 无 | 预检（explicit）与普通响应（echo）均发 |
| `allow_origin_regex` | 未实现 | `re.fullmatch` 命中 |
| `expose_headers` | 未实现 | 普通响应 `Access-Control-Expose-Headers` |
| `allow_private_network` | 未实现 | `Access-Control-Request-Private-Network` → 放行发 `Access-Control-Allow-Private-Network: true` / 未放行 `disallowed private-network` |
| `allow_methods=["*"]` | 未处理 | → `ALL_METHODS`（`DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT`） |
| `allow_headers=["*"]` | 不镜像 | 预检**镜像**回 `Access-Control-Request-Headers` |
| `allow_headers` 头行 | 仅配置集 | `sorted(SAFELISTED_HEADERS ∪ 配置)`（safelist 永远并入） |
| 普通响应（origin 不被允许） | 完全无 CORS 头 | 仍发静态 `simple_headers`（Credentials / Expose-Headers），无 `Allow-Origin`（上游 quirk） |

**上游实测**（fastapi 0.141.1 + starlette 1.6.0）：

```
OPTIONS /x (Origin ok, ACRM GET) → 200 text/plain "OK"
  vary: Origin; allow-methods: GET; max-age: 600;
  allow-headers: Accept, Accept-Language, Content-Language, Content-Type, X-Foo;
  allow-origin: https://ok.com
OPTIONS /x (bad origin) → 400 text/plain "Disallowed CORS origin" + 同头集（无 allow-origin）
OPTIONS /x (bad method) → 400 "Disallowed CORS method"（含 allow-origin echo）
OPTIONS /x (bad header) → 400 "Disallowed CORS headers"
OPTIONS /x (PNA off)    → 400 "Disallowed CORS private-network"
GET /x (regex hit)      → allow-origin echo + vary: Origin + expose-headers
```

## 2. 目标

1. 真预检（Origin + ACRM 在场）→ 上游 200/400 text/plain wire 逐字节对齐；
2. 补齐 `allow_origin_regex` / `expose_headers` / `allow_private_network`；
3. `*` methods → `ALL_METHODS`；`*` headers → 预检镜像；safelist 并入；
4. `Vary: Origin`（预检 explicit / 普通响应 echo）；
5. **FFI 符号数不变** / 零新依赖 / North Star 不变。

## 3. 决策

### 3.1 `bridge/cors.rs` 重写（上游语义）

- `CorsConfig` 增 `origin_regex` / `expose_headers` / `private_network`。
- env 增 `FASTAPI_MOJO_CORS_ORIGIN_REGEX` / `_EXPOSE_HEADERS` / `_PRIVATE_NETWORK`。
- `is_allowed_origin`：通配 → regex `re.fullmatch`（`regex::rgx_fullmatch` = 包裹
  `^(<pat>)$` 走既有手写引擎）→ 白名单精确匹配。
- `normal_cors_lines`：`simple_headers`（`*` / Credentials / Expose-Headers）恒发 +
  echo 条件（全通配+credentials，或白名单/regex 命中）→ 回显 + `Vary: Origin`。
- `preflight_build(origin, acrm, achr, pna)`：
  - 真预检（Origin + ACRM）→ 静态头集（`Vary`/`*` + Allow-Methods + Max-Age +
    [Allow-Headers=sorted(safelist∪配置)] + [Credentials]）+ 动态（Allow-Origin echo /
    `*` headers 镜像 / PNA）→ 空 failure = 200 `OK`，否则 400 `Disallowed CORS …`；
  - 裸 OPTIONS / 无 ACRM → 保留既有 **204 通配超集**（文档化偏差）。
- `allow_methods` 含 `*` → `ALL_METHODS`；`allow_headers` 含 `*` → `None`（全放行）。
- method 匹配 = **大小写敏感精确**（上游 `requested_method in allow_methods`）。

### 3.2 FFI 契约调整（符号数不变）

- `send_preflight_response(fd)` 返回值语义：**bytes-sent → HTTP 状态码**
  （204 / 200 / 400；-1 失败），供 dispatch 写 access log（`standard_status_line`）。
- H2 路径 `http2_response::send_preflight` 不再复用 `send_response`
  （后者会注入 `normal_cors_lines` → 重复 CORS 头），改直接 `header_frames`；
  非空 body 用 `text/plain; charset=utf-8`（上游 PlainTextResponse）。
- `request.rs` 增 `pna` 全局 + `set_cors_pna` / `current_pna`；
  `io.rs` / `http2_io.rs` 解析 `Access-Control-Request-Private-Network`。

### 3.3 dispatch

`http_server_final.mojo` OPTIONS 分支接收 FFI 状态码 → `standard_status_line(code)`
写日志（`exceptions.mojo` 补 200 / 204 reason phrase）。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 保留 204/JSON 预检 | 拒绝 | 与上游 wire 不一致（真实浏览器/工具按 200 OK 解析） |
| 为 PNA 新增 FFI 导出 | 拒绝 | 走 request 全局（io.rs 解析）→ 符号数不变 |
| H2 复用 send_response | 拒绝 | 会叠加 `normal_cors_lines` → 重复 CORS 头（既有潜伏 bug） |
| 裸 OPTIONS 也改 405 | 拒绝 | 既有 204 通配超集是文档化特性（e2e CRS-1 守护），本轮不翻案 |
| 全量重写 cors.rs + 上游语义 + FFI 返回值调整 | 接受 | wire 逐项对齐, 符号数不变 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `cors` 仅依赖 `regex`；request/response/send/http2 单向依赖 cors |
| 2. 分层向下依赖 | ✅ 遵守 | 纯逻辑 cors → 传输层消费者；无反向 |
| 3. God package 阈值 | ✅ 遵守 | `cors.rs` 367 / `cors_tests.rs` 317（< 500） |
| 4. 主题域边界清晰 | ✅ 遵守 | CORS 策略 = cors 域；PNA 采集 = request/io 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI 符号数不变**（仅 `send_preflight_response` 返回值语义变化）；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | `cors_tests` 重写为上游矩阵 + `response_tests`/`send_tests` 更新 + e2e CRS-1..9 / CRS2-1..4 |

## 6. 验收（2026-09-12）

- e2e **582 → 587/587**（CRS-1..9 + CRS2-1..4）。
- cargo bridge **503/0/4**（cors 测试重写为上游矩阵）；clippy 双 crate 0；fmtool **35/0**。
- canonical `./benchmark.sh` 6 场景 **0 errors**。
- `ldd` 仅 libc；`env -i` 干净启动 200；binary 5,052,840 B（≤6 MiB）；C=Python=orphans 0。
- H2 真预检实测：200 `OK` text/plain + 头集；失败 400 `Disallowed CORS origin`。

## 7. 实现 / 边界

- `src/fastapi_mojo_rs/src/bridge/cors.rs`（重写）+ `cors_tests.rs`（重写）。
- `src/fastapi_mojo_rs/src/bridge/regex.rs`：`rgx_fullmatch`。
- `request.rs` / `io.rs` / `http2_io.rs`：PNA 全局 + 解析。
- `response.rs`（H1 预检字节串）/ `send.rs`（FFI 返回值 + H2 分派）/
  `http2_response.rs`（`send_preflight` 直出 header_frames）。
- `http_server_final.mojo`（日志状态码）/ `exceptions.mojo`（200/204 reason phrase）。
- `scripts/e2e_test.sh`：CRS-1..9 + CRS2-1..4。

边界：**裸 OPTIONS / 无 ACRM 的 OPTIONS 仍返回 204 通配超集**（上游将交 app →
405/404），此为既有文档化特性（ADR-0017 §3.2），本轮不翻案；`allow_origin_regex`
走本仓库手写 regex 子集（`regex.rs` 文档化的受限面：字面量/字符类/量词/组/交替/
锚/字边界；不支持反向引用/环视/命名组/内联标志）；`data`/`Vary` 合并语义（app 已有
Vary 时上游用 `add_vary_header` 追加，本实现直接发 `Vary: Origin`，无 app Vary 场景等价）。
