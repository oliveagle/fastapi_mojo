# ADR-0024: 任意异常类型 handler — 字符串 tag 约定 + 声明式处理表（Mojo 1.0.0 异常面约束下）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #13 落地）
- **关联**：AGENTS.md §3/§6（**决策-49**）、Goal-0003（P2 矩阵 #13：任意异常
  类型 handler — 上游 `app.add_exception_handler(cls, fn)` /
  `@app.exception_handler(cls)`）、North Star（Mojo + Rust only 单 binary 零
  依赖 — **零新 crate**；ldd = 仅 libc；Rust bridge 仅 +1 纯 FFI 包装，零新
  依赖）、ADR-0022/0023（声明式 handler.data 接线先例）、F2 决策-12/BS
  （`_error_map` 声明式异常映射 — 本 ADR 与其互补：_error_map = raise 侧
  参数条件→HTTP 错误；本 ADR = catch 侧异常类型→响应）、FastAPI 0.141.1 +
  starlette 1.6.0 + uvicorn 0.52.4（/tmp/exch_probe p13a-g 逐条 probe +
  源码核对，本 ADR §1 证据）

## 1. 背景

Goal-0003 矩阵 #13：「HTTPException/RequestValidationError/自定义 handler」
— HTTPException（F2）与 RequestValidationError（F1 422）已有专用路径；
缺口 = **任意自定义异常类型的 handler**（上游 FastAPI 文档
"Handling Errors" 示例：`class UnicornException(Exception)` +
`@app.exception_handler(UnicornException)` → 418 JSON）。

**上游实测证据（fastapi 0.141.1 / starlette 1.6.0 / uvicorn 0.52.4，
/tmp/exch_probe p13a-g 活体 + 源码逐行核对；关键项全部复跑验证）**：

- **P13-1 查找 = MRO 走查**（`starlette/_exception_handler.py:
  _lookup_exception_handler`）：`for cls in type(exc).__mro__: if cls in
  exc_handlers` — 最特化优先（实测：SubCustomExc→410 覆盖 CustomExc→466）。
- **P13-2 同类重复注册 = 后者胜**（dict 覆盖；p13a 实测第 2 次
  `add_exception_handler` 替换第 1 次 handler）。
- **P13-3 handler 签名 `(conn, exc) -> Response`**：sync 走
  `run_in_threadpool`，async 直接 await（`is_async_callable`）；返回 None
  则不发响应；**per-route `exception_handlers` 不支持**（FastAPI 装饰器
  拒绝 kwarg — p13b 实测 TypeError）。
- **P13-4 `add_exception_handler` 双面**（`middleware/exceptions.py:36`）：
  int 键 → `status_handlers[status]`（仅对 HTTPException 生效，且**先于
  MRO 查找** — `_exception_handler.py:46-50`）；类键 →
  `_exception_handlers[cls]`（assert issubclass Exception）。
- **P13-5 默认表**：Starlette = `{HTTPException: PlainTextResponse,
  WebSocketException: websocket_exception}`；FastAPI setdefault 覆盖
  HTTPException → JSON `{"detail":...}`，+ RequestValidationError → 422
  JSON + WebSocketRequestValidationError（p13f 实测 router scope map =
  `[HTTPException, WebSocketException, RequestValidationError,
  WebSocketRequestValidationError, <user-added>]`）。
- **P13-6 `response_started` 护栏**（`_exception_handler.py:56`）：响应已
  发出后抛出的**已处理**异常 → `RuntimeError("Caught handled exception,
  but response already started.")` 重新抛出（handler 不被调用）。
- **P13-7 用户中间件异常**（ExceptionMiddleware 之外抛出）：不被 map 处理
  → uvicorn **500 "Internal Server Error"**（text/plain; charset=utf-8）
  + 服务端 traceback（p13b /mw-raise 实测）。
- **P13-8 日志 quirk**（starlette 1.6.0 实测 p13c）：被**具体类** handler
  捕获 → **无**服务端 traceback；被 **`Exception` 基类** handler 捕获 →
  uvicorn **仍打印** "Exception in ASGI application" 全 traceback（客户端
  两种情况都收到 handler 的响应）；完全未处理 → traceback + uvicorn 500。
- **P13-9 双 map 分层（源码定案）**：`Starlette.build_middleware_stack`
  （applications.py）组装栈（外→内）= **ServerErrorMiddleware**（handler =
  `exception_handlers` 中 `500`/`Exception` 键的条目 — `key in (500,
  Exception)` 特判；默认 = 打 traceback + PlainText 500）→
  [RequestBodyLimit] → **用户中间件** → **ExceptionMiddleware**（map =
  Starlette 默认 + FastAPI setdefault + 用户注册的非 500/Exception 类/int
  键；`__call__` 写入 `scope["starlette.exception_handlers"]`）→ **Router**
  → 每 route `wrap_app_handling_exceptions`（**读同一 scope map**）。
  `@app.exception_handler(cls)` 装饰器 ≡ `add_exception_handler`（
  applications.py:4729/109，同一 dict，P13-2 后者胜）。
- **P13-10 未处理端点异常（活体 p13g）**：ValueError / KeyError（无自定义
  handler）→ **500 `text/plain; charset=utf-8` body = "Internal Server
  Error"**（21B）+ 服务端 traceback。
- **P13-11 流中抛已处理异常（活体 p13g）**：StreamingResponse 中途抛
  CustomExc（有 418 handler）→ 走 P13-6 RuntimeError；**客户端收到 15B
  部分体（"first-chunk-OK\n"）后连接被切断**（http.client 抛
  IncompleteRead）；服务端 traceback（含 "Caught handled exception, but
  response already started."）。

**Mojo 1.0.0 异常面探测（/tmp/mojo_exc p1-p12，编译 + 运行双验证）**：

- **P13-M1**：`fn` 关键字已移除（用 `def`）；`do … catch` 不是语句（parse
  error）；异常捕获语法 = `try: … except [e]:`（本仓库既有代码已用，
  handler.mojo:321 / body_validate.mojo:305 / test_all.mojo:487）。
- **P13-M2**：**异常类型仅一个 = `Error`**。`ValueError` / `IndexError` /
  `KeyError` / `OSError` / `RuntimeError` / `Exception` 全部 "use of
  unknown declaration"。
- **P13-M3**：捕获绑定 `e` **无类型内省**：无 `type()` 内置、`Error` 无
  `.message` 属性（`'Error' value has no attribute 'message'`）。
- **P13-M4**：**`String(e)` 返回被捕获 Error 的 message 文本**（实测：
  `raise Error("visible msg?")` → `String(e)` = `visible msg?`）；未捕获
  Error 到顶层 → "Unhandled exception caught during execution: <msg>" +
  进程 exit 1（**worker 死亡**）。
- **P13-M5**：**无用户自定义异常类型**：无类型别名（`type X = Y` /
  `def X = Y` parse error）；`def error X: pass` 可 parse 但 `X` 不可
  raise（unknown declaration）→ 异常"类"层级不存在。
- **P13-M6**：**`try` 块内声明的变量在 `except` 块与 try 之后的代码均不
  可见**（implicit-declaration warning）→ 跨块变量必须在 try 前声明
  （与仓库既有 try 用法模式一致）。
- **P13-M7**：**`std.os.getenv(name) -> String` 存在**（未设置 = 空串，
  实测）→ Mojo 原生可读 env，全局声明式配置无需新增 FFI。
- **P13-M8**：含条件 raise 的函数若未显式标注返回类型会推断为 Optional
  （`boom(2) -> Int?` 编译错）；`run_handler` 已有显式
  `-> Tuple[String, Dict[String, String]]`，guard 包装下行为不变。

**结论**：上游"任意异常**类型** handler" 的 type 语义在 Mojo 1.0.0 无法
逐字复现（无类、无 MRO、无内省）；但**可观测行为面**（按异常类别分派到
自定义 status + body 的响应）可用「字符串 tag + 声明式处理表 + 路由级
try/except guard」完整承载，与仓库既有声明式范式（`_error_map` /
`_stream_status` / `_background` / CORS/GZip env）完全同构。

## 2. 候选方案

- **A. Mojo 原生异常类型**（真类 + MRO）：❌ P13-M2/M5 — 1.0.0 只有
  `Error`，无子类型/别名/内省；等 Mojo 语言演进（不可控）。
- **B. 字符串 tag 约定 + 声明式处理表 + 路由级 guard**（✅ 采纳）：
  `raise Error("TAG: msg")`；全局 env 表（`FASTAPI_MOJO_EXCEPTION_HANDLERS`）
  + 路由级覆盖（`_exc_handlers`）+ 声明式 raise 钩子（`_exception_raise`）；
  解析顺序 = 精确 tag → `Exception` catch-all → 默认 500（模拟 P13-9
  双层 map 的可达结果集）；响应 = status + body 模板（`{exc}`/`{tag}`
  插值，text/plain 或 application/json）。零新 crate、零新 FFI 依赖面
  （+1 纯包装 fn）、env 经 std.os.getenv 原生读取（P13-M7）。
- **C. bridge（Rust）侧捕获**：❌ Mojo 异常发生在 Mojo 运行时域，Rust FFI
  边界无法捕获/转换；且 bridge 不应知晓 handler 业务语义（分层向下依赖
  约束，ADR-0010 §3）；FFI 失败（写错误）是另一故障类（与上游 P13-7 的
  中间件异常同域，本 ADR 不覆盖，见 §3.5-8）。
- **D. 仅保留 `_error_map`**：❌ 矩阵 #13 明确缺口 — _error_map 是
  raise 侧（参数条件→HTTP 错误码），无法表达"handler 抛出某类异常 →
  自定义 handler 响应"；上游核心 API（`add_exception_handler`）无对应物。

## 3. 决策

1. **tag 约定**（异常"类型"的承载）：`raise Error("<TAG>: <message>")`。
   dispatch 在**第一个 `:`** 切分：前段 = tag（可含任意字符除 `:`/`;`），
   后段 = message；消息无 `:` → tag = `""`（未分类，走未处理路径）。
   选择第一个冒号而非最后一个：tag 在消息最前（约定优先位置），message
   自由文本（可再含冒号，如 `"oops: a:b"` → tag=oops, msg="a:b"）。
2. **全局处理表**（app 级 = 上游 `add_exception_handler` 同域）：env
   `FASTAPI_MOJO_EXCEPTION_HANDLERS`，格式
   `"TAG:STATUS:BODY[:json];TAG2:STATUS2:BODY2"` — 条目以 `;` 分隔；
   每条目 ≥3 段冒号字段（TAG / STATUS / BODY…）；**第 4 段恰为 `json`**
   → body 以 application/json 发送（否则 text/plain; charset=utf-8，
   上游 PlainTextResponse parity）；**同 TAG 后者胜**（P13-2）。
   STATUS = 3 位数字（注册/解析期校验，非数字即忽略该条目 — 与
   `set_error_map` 校验风格一致）。**一次性进程级**：env 在异常发生时
   读取解析（P13-M7 `std.os.getenv`；异常 = 错误路径，无热路径成本；
   改表 = 重启，与全部 `FASTAPI_MOJO_*` env 一致）。
3. **路由级覆盖（超集）**：`handler.data["_exc_handlers"]` = 同格式表；
   存在时**整体替换**全局表（非合并 — 上游无 per-route 面，P13-3；
   整体替换 = 语义可预测，见 §3.5-7）。
4. **声明式 raise 钩子**：`handler.data["_exception_raise"] = "TAG: msg"`
   — dispatch 在**参数校验/Depends 之后、run_handler 之前**评估
   （= 上游 endpoint body 抛异常的位置）：`raise Error(<值>)`。值本身
   遵循 tag 约定（含 `:`）或无 `:`（未分类）。
5. **`guarded_run_handler`**（新模块 `exception_handlers.mojo`，Mojo
   原生 try/except — P13-M1/M6）：`try { raise-hook; r = run_handler(...)
   return (False, r) } except e { msg = String(e) → resolve }`。
   resolve 顺序（模拟 P13-9 双层 map 的可达结果集）：
   **(a)** 精确 tag 命中 → 该条目（status + body）；
   **(b)** 未命中但表含 **`Exception`** 条目 → 该条目（= 上游
   ServerErrorMiddleware 的 `Exception`/500 键，P13-9）；
   **(c)** 均未命中 → **默认 500 "Internal Server Error"**（text/plain;
   charset=utf-8 — P13-10 逐字 parity）+ 日志输出完整 message。
6. **响应发送**：json 条目 → 既有 `send_simple_response(cfd, status,
   body)`（CT application/json）；text 条目/默认 500 → **新 FFI
   `send_text_response_status(fd, status, body)`**（CT
   `text/plain; charset=utf-8`，`send_response` 核心复用 — 与
   `send_text_response`（200 硬编码）同款加 status 参数，
   PlainTextResponse(status_code) parity）。body 模板插值：`{exc}` →
   message（无 `:` 时 = 全消息）、`{tag}` → tag；**json 条目先
   `_json_escape`**（复用 exceptions.mojo）再插值，保证 body 是合法 JSON。
   访问日志行 = `<status> (exc)`（与 `(sse)` / `(stream)` / `(static)`
   既有标注同型）。
7. **日志 quirk 模拟（P13-8）**：具体 tag 命中 → 单行
   `[exc] <tag> handled -> <status>`（无 traceback — Mojo 无 traceback
   可打，见 §3.5-6）；`Exception` catch-all 命中 或 未处理 → 完整行
   `[exc] <tag-or-untagged> -> <status> | msg: <message>`（= 上游
   "仍打全 traceback" 的线形对等）。
8. **demo 路由**（`register_routes`，KIND_STATIC 载体 + `_exception_raise`
   数据 — 与 F2 `_error_map` demo 同构）：`/exc/ve`（ValueError:
   bad value from handler）/ `/exc/unicorn`（UnicornException: rainbow
   lost — 上游文档例名）/ `/exc/unhandled`（MysteryFailure: no entry
   for this）/ `/exc/raise-plain`（plain message no colon — 无 tag 路径）
   / `/exc/ve2`（JsonExc: boom — json 条目）/ `/exc/override`（ValueError
   + 路由级 `_exc_handlers` 覆盖）/ `/exc/dup`（Dup — 同 tag 后者胜）。

**Bug 修复记录（勿回退）**：本决策无存量 bug 修复（纯新增能力面）；
`send_text_response`（200 硬编码）保留为 F6 metrics 兼容入口，不改行为。

## 3.5 与上游的偏差（文档化，8 条）

| # | 上游语义 | 本实现 | 性质 |
|---|----------|--------|------|
| 1 | 异常 = 真类层级，MRO 走查最特化优先（P13-1） | 异常"类型" = **字符串 tag**（P13-M2/M5 无类）；查找 = **精确 tag 匹配**，无层级 | **偏差**（语言约束）：子类覆盖父类 handler 的层级语义不可表达；用户可用多个显式 tag 枚举（超集能力：任意字符串 tag，上游仅限 Exception 子类） |
| 2 | handler = `(conn, exc) -> Response` 可调用对象，可任意构造响应（含 headers/动态 status）（P13-3） | handler = **声明式表条目**（status + body 模板 `{exc}`/`{tag}` 插值；CT = json/text 二选一） | **偏差**（声明式范式）：无法在 handler 内执行任意逻辑/发送 extra 头；body 模板是唯一表达面（与仓库 `_error_map`/`_stream_status` 声明式范式一致，ADR-0004） |
| 3 | int status 键 handler（`add_exception_handler(404, h)`）仅对 HTTPException 生效且先于 MRO（P13-4） | **无 int 键面**：本实现 HTTPException 是声明式 struct（F2 `_error_map`/404/405/422 专用路径），从不以 Mojo 异常抛出 → 无挂接对象 | **偏差（对象缺失）**：两个世界的 HTTPException 不是同一实体；F2 路径行为不变 |
| 4 | `response_started` 护栏：流中抛已处理异常 → RuntimeError 重抛、客户端得部分体 + 断连（P13-6/11） | **路径不存在**：dispatch 单发模型（每连接每请求一个响应；SSE/streaming/file = 一次性 FFI 发送，无"发送中途" Mojo 代码段）→ 结构性不可达 | **偏差（结构对等）**：本实现从不进入该状态（等价于"已处理异常永远在响应前抛出"） |
| 5 | 双 map 分层：ServerErrorMiddleware（500/Exception 键）与 ExceptionMiddleware（其余类/int 键）是**两个 map**（P13-9） | **单表**：`Exception` tag 条目 = 500/Exception 键的等价物；精确 tag = ExceptionMiddleware 域；可达结果集相同 | **偏差（简化）**：仅当"用户中间件抛异常"（P13-7）时两实现分叉 — 见 #8 |
| 6 | 日志 quirk：具体 handler 捕获 → 无 traceback；`Exception` handler 捕获 / 未处理 → uvicorn 全 traceback（P13-8） | 线形日志模拟：具体命中 → 单行 `[exc] <tag> handled`；catch-all/未处理 → 完整 message 行 | **偏差（对等模拟）**：Mojo 无 traceback 机制（P13-M4：未捕获只有一行 "Unhandled exception caught during execution"）；信息量对等（tag + status + message），格式不同 |
| 7 | per-route `exception_handlers` **不支持**（FastAPI 拒绝 kwarg，P13-3） | **支持**路由级 `_exc_handlers`（整体替换全局表） | **超集**：便于 demo/路由域隔离；默认行为（未声明）与上游一致 |
| 8 | 用户中间件（ExceptionMiddleware 之外）抛异常 → 不被 map 处理 → uvicorn 500 + traceback（P13-7） | 中间件链（logging/timing/request-id）之外的抛出不在 guard 覆盖域 → **worker 进程终止**（P13-M4：顶层未捕获 = exit 1） | **偏差（gap）**：当前中间件集无 raise 面（纯函数包装）；若未来中间件引入 raise 需扩展 guard 域（记录为已知边界） |

## 4. 风险

- **R1 tag 歧义**：message 含 `:` 时按第一个 `:` 切分（tag 必须在前）—
  文档化约定，e2e 覆盖（`/exc/raise-plain` 无冒号路径 + body 含冒号
  插值测试）。
- **R2 体积**：新增 ~250 LOC Mojo 模块 + 1 FFI 包装 → KGEN .text 增长；
  预算 ≤4.2M（当前 3,631,104 B，余量 ~570 KB）— 门禁实测。
- **R3 env 一次性语义**：改表需重启（与全部 `FASTAPI_MOJO_*` 一致，
  非回归）。
- **R4 `String(e)` 成本**：仅在异常路径（错误路径）触发，热路径零成本
  （guard 函数本体 = 1 次 if 检查 + 1 次函数调用）。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`exception_handlers → {handler, exceptions, std.os}`；`http_server_final → exception_handlers`；handler/exceptions 不反向引用 — 依赖图零环 |
| 2. 分层向下依赖 | ✅ 遵守 | 异常捕获/表解析/插值 = Mojo 原生（P13-M1/M4/M6/M7，try/except + String(e) + std.os.getenv，零 FFI 新增依赖面）；bridge 仅 +1 纯 FFI 包装 `send_text_response_status`（复用 `send_response` 核心，零新系统调用/零新 crate/零 libm） |
| 3. God package 阈值 | ⚠️ 遵守（带说明） | 新增 `exception_handlers.mojo` **254 行**（<500）+ selftest 140 行；`http_server_final.mojo` 1444 → **1509**（**既有超阈值** — ADR-0023 已标注；本决策 +65 行 = dispatch guard 接线 ~26 + demo 路由 ~37 + import 1 + 418 status 行在 exceptions.mojo） |
| 4. 主题域边界清晰 | ✅ 遵守 | 异常 handler = 独立新域（exception_handlers.mojo）；F2 `_error_map`（raise 侧参数条件）/F1 422/HTTPException 声明式路径零改动；WS/静态/SSE/鉴权域零改动 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | `ldd` 保持仅 libc（新 FFI 仅复用 send_response → 无新动态符号）；`find src -name '*.c'` = 0 保持；`-static-libgcc` 守则不触发（零新依赖）；binary ≤4.2M 门禁实测 |
| 6. 测试文件跟随 | ✅ 遵守 | Mojo：`exception_handlers_selftest.mojo`（新，28 checks，JIT 可达 — main 只调纯函数不触 run_handler FFI 闭包，file_params_selftest 同模式）+ `exceptions.mojo` 仅 +418 status 行；Rust：`send_text_response_status` 单测 ×2 进 send_tests（同 crate）；e2e `XH-1..XH-13b` 15 项（351 → 366）— 全部与生产代码同目录/同 crate |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` = **仅 libc**
   （vdso/ld-linux 内核组件）— 新 FFI 仅复用 `send_response` 核心，无新
   动态符号，零 libm；binary **3,663,872 B (3.5M)** ≤4.2M（+32,768 B vs
   决策-48）；`env -i` 干净启动实测（health 200 + `/exc/ve` 500
   "Internal Server Error"）；`find src -name '*.c'` = 0；
   `pgrep -x fastapi_mojo` = 0（worker 随父进程退出）。
2. **质量门禁**：`cargo test --release -- --test-threads=1` =
   **409/0/4**（407 + 2：`send_text_response_status_custom_status_and_ct`
   / `send_text_response_status_default_500_parity`）；
   `cargo clippy --release --tests -- -D warnings` 双 crate（
   fastapi_mojo_rs + fmtool）= **0 警告**；Mojo 侧
   `exception_handlers_selftest.mojo` **28 checks 全绿**（JIT 双模式：
   无 env / `FASTAPI_MOJO_EXCEPTION_HANDLERS` + `FM_XH_ENV_EXPECT` env 表
   各跑一遍）。
3. **e2e 全量**：351 → **366/366**（+15 XH）全绿（实测 0 FAIL）：
   - XH-1..4（主 server，无表）：`/exc/ve` / `/exc/unicorn` /
     `/exc/unhandled` / `/exc/raise-plain` → **500 "Internal Server
     Error"**（P13-10 逐字）
   - XH-1b：Content-Type = `text/plain; charset=utf-8`（PlainTextResponse
     parity）
   - XH-5/6（回归）：`/health` 200 正常路由不受影响；`/errors/99` 404
     （F2 声明式 `_error_map` 路径不受影响）
   - XH-7/8（副 server，env 表）：精确 tag → **418 "oops bad value from
     handler"** / 自定义 tag → **418 "rainbow rainbow lost"**（上游文档
     UnicornException 例名）
   - XH-9：未匹配 tag → **`Exception` catch-all 503**（P13-9 双层 map
     单表化）
   - XH-10：json 条目 → **422 application/json** `{"detail":"bad boom"}`
     （`_json_escape` 后合法 JSON）
   - XH-11：`_exc_handlers` 路由级 → **429**（整体替换全局表，超集）
   - XH-12：同 tag 后者胜 → **404 "second d"**（P13-2）
   - XH-13a/b：无 `:` 消息（tag=""）落 catch-all **503**；有表时正常路由
     200 不受影响
4. **性能**：bench 6 场景 **0 errors**；get_root_10k_100c =
   **37,216.23 req/s**（历史区间 32.9k–43.9k 内；vs 决策-48 37,665 噪声
   内 — 热路径零新开销：正常请求仅 +1 次 dict 检查（`_exception_raise`
   不存在）+ 1 次结构体构造）。
5. **零依赖红线**：`find src -name '*.c'` = 0；`find . -name '*.py'`
   （excl .git/docs）= 0；`.venv` 不存在；fmtool 未改动。
