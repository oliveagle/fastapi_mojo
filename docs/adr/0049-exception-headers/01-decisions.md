# ADR-0049: `HTTPException(..., headers=...)` / 异常 handler 自定义响应头等价

**状态**：已接受
**日期**：2026-09-12
**决策**：74（Goal-0003 §1 矩阵 #13 异常处理 / `fastapi_mojo-0n1` bead）

## 1. 背景

决策-49（ADR-0024）落地了"任意异常类型 handler"（字符串 tag 约定 + 声明式表
`_exc_handlers` / `FASTAPI_MOJO_EXCEPTION_HANDLERS` + 声明式 raise 钩子
`_exception_raise`），但**异常响应无法携带自定义响应头**：

- 上游 FastAPI `HTTPException(status_code, detail, headers={...})` 会把
  `headers` 透传到响应（Starlette `ExceptionMiddleware` 构造
  `PlainTextResponse(..., headers=exc.headers)`，`fastapi` 再包装为
  `JSONResponse({"detail": detail}, headers=...)`）。
- 上游 `@app.exception_handler(409)` 返回任意 `Response`（含
  `PlainTextResponse("...", status_code=..., headers={...})`）时同样带自定义头。

**上游实测**（fastapi 0.141.1 + starlette 1.6.0，`/tmp/fm_exc_probe/probe.py`）：

```
GET /tea   (HTTPException(418, "brewing", headers={"x-reason":"tea","www-authenticate":"Teapot"}))
  → 418  body {"detail":"brewing"}  content-type application/json
         x-reason: tea   www-authenticate: Teapot

GET /c409  (@app.exception_handler(409) -> PlainTextResponse("custom-409", 409, headers={"X-Custom":"yes"}))
  → 409  body custom-409  content-type text/plain; charset=utf-8
         x-custom: yes
```

本仓库既有异常响应路径（`resolve_exception_response` → `send_simple_response` /
`send_text_response_status`）**没有任何自定义头通道**：`GuardResult` 只有
status/body/is_json，FFI 入口也只有 (fd, status, body) 三参。

## 2. 目标

1. 让声明式异常响应能携带自定义头（**JSON 与 text/plain 两条路径都要**）；
2. 头表可声明：路由级 `_exc_headers` 优先，全局 env
   `FASTAPI_MOJO_EXCEPTION_HEADERS` 兜底（与 `_exc_handlers` 同款"路由级=整体替换"）；
3. 头按**命中 tag** 选择（精确 tag → `Exception` catch-all），与 body 表选择一致；
4. **零新依赖 / North Star 不变**（新增 1 个 text 路径 FFI 导出，与既有
   `send_simple_response_extra` 同签名风格）。

## 3. 决策

### 3.1 Rust bridge：新增 text 路径 extra 头入口

- `bridge/send.rs`：`send_text_response_status_extra(fd, status, body, extra)` —
  `extra` 为空 → `None`（与 `send_text_response_status` 字节一致）；非空 →
  `send_response(..., Some(extra))`（`text/plain; charset=utf-8`）。
  JSON 路径复用既有 `send_simple_response_extra`（决策-27 引入）。
- `bridge/ffi.rs`：`#[no_mangle] pub extern "C" fn send_text_response_status_extra(..)`，
  对齐 C ABI（`c_int` / `*const c_char` / `c_long`，`c_str_lossy` / `c_str_bytes`）。

### 3.2 Mojo：声明式头表

- `exception_handlers.mojo`：
  - `GuardResult` 增 `var extra: String`（`\r\n` 分隔 "Name: value" 行；空=无）；
  - `_has_colon(s)` / `parse_exc_headers(spec)` —— `;` 分隔 `TAG=H1|H2`
    （`|` 分隔多头，`:` 校验头行）→ `tag -> "\r\n"` 拼接串；非法条目静默跳过
    （与 `parse_exc_table` 同款容错：无 `=` / 空 tag / 头无 `:`）；同 tag 后者胜；
  - `load_exc_headers(handler)` —— `_exc_headers` 存在时整体替换 env
    `FASTAPI_MOJO_EXCEPTION_HEADERS`（与 `load_exc_table` 同款 §3.5-7）；
  - `resolve_exception_response` 命中 tag（或 catch-all）时从同一头表取
    `out.extra`。
- `http_server_final.mojo`：异常响应分支——`gres.extra` 非空 → JSON 走
  `send_simple_response_extra` / text 走 `send_text_response_status_extra`；空 →
  维持原入口（零行为变化）。
- 头值内含 `|` / `;` 不支持（文档化；声明式 spec 分隔符约束，与 `_exc_handlers`
  的 body 分隔约定同族）。

### 3.3 demo + e2e

- 新 demo 路由 `/exc/headers`（`_exception_raise="Teapot: brewing"` /
  `_exc_handlers="Teapot:418:{\"detail\":\"brewing\"}:json"` /
  `_exc_headers="Teapot=X-Reason: tea|WWW-Authenticate: Teapot"`）—— 上游 probe
  的 `HTTPException(418, headers)` 语义。
- e2e XH-14..17：路由级头（主 server）/ env 精确 tag（副 server）/ catch-all 头 /
  **路由级覆盖 env**（route wins）。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 复用 JSON 入口发 text 头 | 拒绝 | content-type 错误（异常 text 面须 text/plain） |
| 异常路径改用 `send_response` 直调 | 拒绝 | 绕过既有 status/close 语义，回归面大 |
| 头表与 body 表合并成一条 spec | 拒绝 | 破坏 `_exc_handlers` 既有 wire（body 可含 `|`/`=`），且语义耦合 |
| 全局 env 优先于路由级 | 拒绝 | 与 `_exc_handlers`（路由级=超集）不一致 |
| 新增 text extra FFI（1 符号）+ 路由/env 两级头表 | 接受 | wire 对齐上游, 复用既有 extra 发送语义, 面最小 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `exception_handlers` 仅依赖 handler/params_query/exceptions/middleware |
| 2. 分层向下依赖 | ✅ 遵守 | Rust send 层新增纯发送原语 → Mojo 协议层消费；无反向 |
| 3. God package 阈值 | ✅ 遵守 | `exception_handlers.mojo` 346 / `send.rs` 536（< 500）；`send_tests.rs` 595（既有测试文件，HEAD 已 565） |
| 4. 主题域边界清晰 | ✅ 遵守 | 异常头解析 = exception_handlers 域；发送原语 = send 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **新增 1 个 FFI 导出**（`send_text_response_status_extra`，与 `send_simple_response_extra` 同型）；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | `send_tests` 新增 2 测 + `exception_handlers_selftest` 扩 `parse_exc_headers`/extra 向量 + e2e XH-14..17 |

## 6. 验收（2026-09-12）

- e2e **587 → 591/591**（XH-14 路由头 / XH-15 env 精确 tag / XH-16 catch-all / XH-17 路由覆盖 env）。
- cargo bridge **505/0/4**（send_tests +2）；clippy 双 crate 0 警告；fmtool **35/0**。
- canonical `./benchmark.sh` 6 场景 **0 errors**。
- `ldd` 仅 libc；`env -i` 干净启动 200；binary 5,065,128 B（≤6 MiB）；C=Python=orphans 0。
- `mojo run exception_handlers_selftest.mojo` 绿（含 `parse_exc_headers` 多/后胜/跳非法 + extra 命中/覆盖/空）。

## 7. 实现 / 边界

- `src/fastapi_mojo_rs/src/bridge/send.rs` + `ffi.rs`（新导出）+ `send_tests.rs`。
- `src/fastapi_mojo/exception_handlers.mojo`（头表 + `GuardResult.extra`）+ `_selftest.mojo`。
- `src/fastapi_mojo/http_server_final.mojo`（异常分支 extra + `/exc/headers` demo）。
- `scripts/e2e_test.sh`：XH-14..17。

边界：头表是**声明式**（非运行期 `headers=` dict 对象）；头值不支持内嵌 `|` / `;`
（spec 分隔符）；`Exception` catch-all 头与精确 tag 头同表（同 tag 后者胜）；
未命中 tag（走默认 500）无头（上游默认 ServerErrorMiddleware 500 亦无自定义头）。
