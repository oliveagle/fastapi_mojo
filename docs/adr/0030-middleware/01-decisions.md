# ADR-0030: 用户自定义中间件声明式落地 — `FASTAPI_MOJO_MIDDLEWARE`
# （Goal-0003 矩阵 #14：`BaseHTTPMiddleware` / `@app.middleware("http")` /
# `app.add_middleware` 等价；决策-55）

## 1. 背景

Goal-0003 矩阵 #14：`中间件 | BaseHTTPMiddleware/GZip/自定义 | 🟡 固定3 + GZip ✅
（决策-40 env 声明式） | 用户自定义（Mojo 无闭包：声明式 env / 固定链为等价形态,
扩充 P2）`。盘点现状:

- ✅ **既有面**：
  - 固定 3 中间件链（`middleware.mojo`）：request-id / logging / timing
    （dispatch 钩子 `mw_request_id/mw_timing/mw_logging`, 决策-32 时代）。
  - GZip（决策-40, ADR-0015）：`FASTAPI_MOJO_GZIP*` env, 在 bridge `send_response`
    单点压缩 + `Content-Encoding: gzip`。
  - CORS（决策-42, ADR-0017）：`FASTAPI_MOJO_CORS_*` env, bridge 单点附加头。
- ❌ **缺失（本 ADR）**：**用户自定义**中间件（上游 `@app.middleware("http")`
  装饰器 / `BaseHTTPMiddleware` 子类的 declarative 等价）。

### 1.1 上游活体探测（`/tmp/fm_probe`, fastapi 0.141.1 / uvicorn 0.52.4 /
pydantic 2.13.5, uvicorn 单 worker, 双 `@app.middleware('http')` 探针 app,
port 8752/8756）

| # | 语义 | 实测 |
|---|------|------|
| P-MW-1 | **栈序** | 源码序 = 添加序：先添加 = **innermost**（最内层）, 后添加 = **outermost**。请求侧执行序 = outermost → innermost（`b-in, a-in`）；响应侧 = innermost → outermost（`a-out, b-out`）。`add_middleware` 插栈顶（index 0 = outermost） |
| P-MW-2 | **响应头写入** | 同名 header 后写者胜：响应侧最外层（最后执行）覆写最内层（`X-SAME: from-b` 胜 `from-a`） |
| P-MW-3 | **短路** | `return Response(...)` 不调 `call_next` → 更内层中间件 + 路由全部跳过（innermost 短路时外层仍 wrap —— 短路响应是 `call_next` 的返回值） |
| P-MW-4 | **status 重设** | 响应对象 `status_code` 可变；最终 = 最外层改动（200→201 实测 201） |
| P-MW-5 | **body 替换** | `res.body_iterator = async-gen` 可替换 body 字节；**但 `content-length` 头不重算**（仍 = 原 body 长度, 31 vs 新 6B）→ **h11 `LocalProtocolError: Too little data for declared Content-Length`**（2 次实测）；同步 `iter([str])` 直接 `TypeError`（`async for` 要求 `__aiter__`）。**上游 body 换长 = 协议级破损** |
| P-MW-6 | **scope 边界** | `BaseHTTPMiddleware` 仅处理 http scope；WS 会话（websocket scope）直通不被 wrap；升级 GET 本身是 http scope（可被短路为普通响应） |
| P-MW-7 | **请求面** | 上游中间件**不能**改 `request.headers`（immutable view）；可改 **scope**（`scope["path"]` 重写 = Starlette 文档化手法；`scope["headers"]` 深改理论可行） |

### 1.2 范围切分

- **本 ADR = 用户自定义中间件的声明式等价**（`@app.middleware("http")` /
  `BaseHTTPMiddleware.dispatch` 的能力面：读请求 → 短路 / 改 scope → 改响应
  → 日志）。
- 既有 GZip/CORS/固定3 链**不动**（各自 env / 各自机制）。
- **Mojo 1.0.0 无闭包/用户函数**（P13 同款约束）→ 声明式 env 词表为等价形态
  （决策-40/42/49 先例, ADR-0004 声明式世界观）。

## 2. 候选方案

| # | 方案 | 评估 |
|---|------|------|
| A | **单一 env `FASTAPI_MOJO_MIDDLEWARE` = 声明式动词表**（`;` 分中间件, `,` 分动词, 每动词 = 位置字段 `NAME[:A[:B[:C]]]`；请求面动词 Mojo 侧 dispatch 前应用, 响应面动词 bridge `send_response` 单点应用） | ✅ 上游 `@app.middleware` = app 级链, 单 env 同构; 栈序/短路/响应面语义 P-MW-1..5 全量可表达; 与 GZip/CORS env 先例同款（bridge 单点 + env 一次读取）; 零用户代码 |
| B | 路由级 `data["_mw"]` 键（per-route 中间件） | ❌ 上游无路由级中间件面（`@app.middleware` 仅 app 级; per-route 行为归 Depends/异常面）— 超出对标面, 且声明面膨胀 |
| C | Mojo 用户回调（handler 闭包链） | ❌ Mojo 1.0.0 无闭包/函数指针（P13 同款）; 违反声明式世界观 |

**决策：A** — `FASTAPI_MOJO_MIDDLEWARE` env（决策-55）。

## 3. 决策

### 3.1 Spec 语法

```
FASTAPI_MOJO_MIDDLEWARE="<mw1>;<mw2>;...;<mwN>"
  <mwK>  = "<verb1>,<verb2>,..."          # 动词 `,` 分, 书写序 = 执行序
  <verb> = "NAME[:A[:B[:C]]]"             # `:` 分位置字段
```

- **中间件序**：`mw1` = 先添加 = **innermost** … `mwN` = 后添加 =
  **outermost**（镜像上游源码序; P-MW-1）。
- **请求侧执行序** = outermost → innermost = **env 逆序**（mwN → mw1）;
  单中间件内动词按书写序。
- **响应侧执行序** = innermost → outermost = **env 正序**（mw1 → mwN）;
  同名 HDR 后写胜（P-MW-2）。
- **短路规则**（P-MW-3）：mwK 的 BLOCK 命中 → 响应仅过 mwK+1..mwN（外层）
  响应面动词; **mwK 自身响应动词不执行**（`return Response` 跳过
  `call_next` 之后代码）+ 更内层全跳过。
- **env 空/未设 = 零中间件**（行为零变化）。

### 3.2 动词表

**请求面（Mojo 侧, dispatch 读完全量请求字段后、OPTIONS/WS/路由分派前;
outermost→innermost）：**

| 动词 | 字段 | 语义 |
|------|------|------|
| `MAP:FROM:TO` | FROM/TO = 绝对路径 | 路径重写（P-MW-7 `scope["path"]`）：`path == FROM` → `TO`; `path` 以 `FROM/` 起 → `TO`（TO 非 `/` 尾时补 `/`）+ 剩余段; `/`（根）FROM 不合法 |
| `REQHDR:NAME:VALUE` | NAME = wire 名（非空）, VALUE = 字面量 | 注入合成请求头（P-MW-7 `scope["headers"]` 深改等价）：入 bridge 合成头表, 全体请求头读面可见（`_reads_headers` F3a / typed header / auth `_get_header`; CI, 先注入先胜） |
| `BLOCK:STATUS:BODY:PATHS` | STATUS = 3 位码; BODY = 字面模板（可含 `{method}{path}{query}`）; PATHS = `|` 分列表（`*` = 全部; `P/` = 前缀; 其余精确） | 早期响应（P-MW-3 短路）：text/plain, STATUS 标准行, BODY 插值; 跳过路由 + 更内层; 外层响应动词照过 |

**响应面（bridge `send_response` 单点, GZip 判定前; innermost→outermost）：**

| 动词 | 字段 | 语义 |
|------|------|------|
| `HDR:NAME:VALUE` | NAME 非空（拒 `Content-Length/Content-Type/Transfer-Encoding/Content-Encoding/Connection` — 归 bridge 管理） | 设/追加响应头（P-MW-2：同名行原位替换, 后写胜） |
| `STATUS:FROM:TO` | FROM = 3 位码或 `*`; TO = 3 位码 | 状态重设（P-MW-4）：当前码 == FROM（或任意）→ TO（标准名, bridge 表） |
| `BODY:TEMPLATE` | 模板可含 `{method}{path}{query}{status}{req_id}`（未知 `{..}` 保留字面, house 约定） | 换 body 为 text/plain（**重算 Content-Length** — 修 P-MW-5 h11 协议破损, 文档化优于上游）; HEAD（include_body=false）不发体 |
| `LOG` | — | 响应发送后打印一行 `[mw] <req_id> <METHOD> <path>[?<query>] -> <最终 status>`（多 LOG 去重一行） |

### 3.3 注册期校验（`check_mw_spec`, `check_*` 同策略 fail-fast, 启动期
主进程一次）

- 未知动词名 / 字段数不符 / 值含分隔符（`;` `,` `:` `|`）/ 非 3 位状态码 /
  空 NAME → `Error` + 进程 abort（服务不启动, 同 `check_header_specs` 等）。
- 空 spec（未设 env）= 合法（零中间件）。

### 3.4 FFI diff = +2 新导出（既有导出集不变, ADR-0010 FFI 表面规则）

| 导出 | 方向 | 用途 |
|------|------|------|
| `set_req_id(fmc_slice) -> i32` | Mojo → bridge, 每请求一次（dispatch 生成 req_id 后） | bridge `CurrentRequest.req_id`（NUL 终止, 决策-36 契约）— 供 BODY `{req_id}` 插值 + LOG 行 |
| `inject_request_header(name_fmc_slice, value_fmc_slice) -> i32` | Mojo → bridge, 每 REQHDR 动词 | 入 bridge 合成头表（`CurrentRequest.synthetic_headers: Vec<(Vec<u8>,Vec<u8>)>`, `set_http_fields` 每请求清空）; `extract_request_header` 先查合成表（CI, 先注入先胜）再查原 hdr 块 |

### 3.5 层级与边界（文档化）

- **用户 mw 层位**：响应面动词在 bridge 单点的执行位 = **GZip/CORS env 层之内
  （inner）**（用户动词先执行, GZip 后压缩终态 body, CORS 头最外层附加）;
  上游用户可自选 add 序（可在 GZip 之外）→ 本实现固定序（声明式无 add 调用,
  env 单层）。
- **scope 边界（P-MW-6）**：响应面动词仅作用于 http 单发响应
  （`send_response` 全家：JSON/SSE/text/html/422/error/HEAD）; **不适用**
  chunked streaming（无 Content-Length, body = chunk 流 — 上游 GZip 同款
  绕过, ADR-0023）/ 静态文件 / 预检 / WS 帧与 101 握手。请求面动词对
  OPTIONS 预检与 WS 升级 GET **适用**（均为 http scope, 可 MAP/REQHDR/BLOCK;
  WS 路由查找用重写后 path）。
- **请求面 body 读取**：声明式动词面不读/改请求 body（上游 body 消费 =
  一次性坑; body 消费归路由/handler 单点, ADR-0014/0021 既定）。
- **REQHDR 可见面**：仅请求头参数面（`_reads_headers` / typed header /
  auth）; 不影响 bridge 内部探测（Origin/Accept-Encoding/CORS 三元组直读
  原 hdr 块）。

## 4. 文件面

- **新** `src/fastapi_mojo/mw_spec.mojo`：spec 解析/校验（`check_mw_spec`）+
  纯函数请求面计划（`mw_plan_request` → 重写 path / BLOCK 判定 / REQHDR 对
  收集）+ 插值（`mw_interp`）+ selftest main（FFI-free）。
- **改** `http_server_final.mojo`：main() 读 env + 校验（fail-fast）+ 打印;
  dispatch 钩子（字段读后、OPTIONS 前）：`set_req_id` FFI + 纯计划 +
  REQHDR 注入 FFI + BLOCK 早响应（`send_text_response_status` + 日志 +
  conn_done）。
- **新** `bridge/middleware.rs`（+ tests）：env 一次读取（OnceLock, GZip
  同款）+ 响应面动词应用（`apply_response`）+ 状态名小表 + 合成头存储辅助。
- **改** `bridge/request.rs`：`CurrentRequest` + `req_id`（64B NUL）+
  `synthetic_headers`; `set_http_fields` 复位。
- **改** `bridge/conn.rs`：`extract_request_header` 先查合成表。
- **改** `bridge/send.rs`：`send_response` GZip 判定前插 `middleware::apply_response`
  （STATUS→BODY→HDR/LOG）; 发送成功后 LOG 打印。
- **改** `bridge/ffi.rs` / `mod.rs`：+2 导出 + 模块声明。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | `mw_spec → std`（叶子, 纯 Mojo）; `http_server_final → mw_spec`（单向）; `bridge/middleware.rs → std`（叶子）; 无环 |
| 2. 模块 < 500 行 | ✅ 遵守 | mw_spec.mojo 430 行; bridge/middleware.rs 428 行（+ middleware_tests.rs 238 行独立文件）; 既有文件增量 < 60 行 |
| 3. FFI 表面 | ⚠️ 扩展（声明） | **FFI diff = +2 新导出**（`set_req_id` / `inject_request_header`）; 既有导出集零改动; 签名 = fmc_slice 惯例 |
| 4. 零新依赖 | ✅ 遵守 | 纯 std（Rust）/ 纯 Mojo; ldd 仅 libc（-static-libgcc 守则, 新增代码纯整型/字节操作无 libm/内建函数风险） |
| 5. 单 binary 不变式 | ✅ 遵守 | `build_single.sh` 零改动（新模块进既有 staticlib + mojo 编译单元）; 体积增量 ≈ +30-50KB（≤4.2M 预算内） |
| 6. 声明式世界观 | ✅ 遵守 | `FASTAPI_MOJO_MIDDLEWARE` = 新 env（app 级, ADR-0004）; `check_mw_spec` fail-fast（check_* 同策略）; 运行期无对象修改; handler 无感（请求头表/响应单点） |

## 7. 验收（门禁实测）

- **7.1 单 binary / ldd / env -i**：`./build_single.sh` → `build/fastapi_mojo`
  **4,077,712 B（3.9M, ≤4.2M 预算）**; `ldd` = **仅 libc**（linux-vdso + libc.so.6 +
  ld-linux, 无 libgcc_s/libm, `-static-libgcc` 守则守住）; `env -i ./build/fastapi_mojo
  --port 8791` **干净启动**（/health 200 + `{"status":"healthy",...}`）; `pgrep -x
  fastapi_mojo` = 0（无孤儿）。
- **7.2 质量门禁**：`cargo test --release -- --test-threads=1` = **453 passed / 0
  failed / 4 ignored**（新增 19 中间件单测, 含 bridge 短路重推导 6 测：
  `mw_plan_path_map_exact_and_prefix` / `mw_plan_path_block_star_and_prefix` /
  `mw_plan_path_map_then_block_uses_rewritten_path` / `mw_short_circuit_only_outer
  _response_verbs_apply` / `mw_no_block_all_response_verbs_apply` /
  `mw_short_circuit_body_uses_rewritten_path`）; `cargo clippy --release --tests --
  -D warnings` 双 crate（fastapi_mojo_rs + fmtool）= **0 警告**; `mw_spec.mojo`
  selftest（`mojo run`, FFI-free）= **10/10 全绿**。
- **7.3 e2e MW-\***（4 副 server, port +113..+116 + 主 server）：
  `./scripts/e2e_test.sh` = **438/438 全绿**（基线 428 + 新增 10）——
  - **MW-1** HDR：/health 响应头 `X-Mw: 1`;
  - **MW-2** REQHDR：/mw/reqhdr `_reads_headers` 回显 `header_X-Mw-Inj: injected`;
  - **MW-3** MAP：/mw/map-old → body `message: "mapped here"` + `path: "/mw/map-new"`（post-MAP）;
  - **MW-4** LOG：server stdout `[mw] req-N GET /health -> 200 OK`;
  - **MW-5** STATUS：/health 200 → **201**;
  - **MW-6** BODY：/health body = `GOT GET /health 201 req-N`（{method}{path}{status}{req_id} 插值）+ CT `text/plain`;
  - **MW-7** 同名 HDR（inner/outer）→ **单行** `X-Same: outer`（后写胜, P-MW-2）;
  - **MW-8** BLOCK 短路：418 + body `early-blocked` + **仅 X-Outer**（X-Mid/X-Inner 无, ADR §3.2）;
  - **MW-9** BLOCK 早期响应 CT = `text/plain`（路由被跳过, 非 JSON）;
  - **MW-10** 主 server 无 env → **零行为变更**（无 X-Mw, 零回归）。
- **7.4 性能 / 体积 / RSS**：`./benchmark.sh` **6 场景 0 errors**; get_root_10k_100c ≈
  **31.5k req/s**（vs pre-55 基线 35,124, 单机 100c bench run-to-run 噪声 ±10% 内,
  无回归）; 体积 4,077,712 B（≈ +57KB vs pre-55 4,020,232 B, 纯 std 字节/整型操作,
  ≤4.2M 预算内）。
- **7.5 实施期修复与偏差**：
  1. **Bridge 侧短路重推导**（ADR §3.2 落地, 零额外 FFI）：`plan_request_path(stack,
     path) -> (String, Option<usize>)` 在 bridge 侧重跑 Mojo `mw_plan_request` 算法
     （outermost→innermost, 先 `MAP` 重写, 首个命中 `BLOCK` = blocker index）,
     `apply_response_ctx` 据此跳过 `index <= k` 的中间件响应动词（blocker 自身及更内层）。
     **确认**：`send_text_response_status` 委托 `send_response` → BLOCK 早期响应也过
     mw 钩子, FFI diff 保持 **+2** 不变（设计自洽）。
  2. **Path 语义不对称（文档化）**：LOG 行用**原始 client path**（`ctx.path`, 诊断值
     = 客户端实际请求）; BODY 插值 + 响应 JSON `path` 字段用 **post-MAP path**（`p2`,
     重写后有效路径）。实测：`[mw] req-N GET /mw/map-old -> 200 OK`（原始）而响应
     body 的 `path` = `/mw/map-new`。
  3. **上游 P-MW-5 stale-CL 协议破损已修**：BODY 动词替换 body 后**重算 Content-Length**
     （上游 fastapi 0.141.1 `body_iterator` 替换不重算 CL → h11
     `LocalProtocolError: Too little data for declared Content-Length`, P-MW-5 实测 2 次）。
     本实现 = **文档化优于上游**。
  4. **NUL 终止契约**（决策-36）：`set_req_id` / `inject_request_header` 两新 FFI 走
     fmc_slice 惯例（Mojo `CStringSlice.as_bytes()` 读到首个 NUL）; 回归守护见
     `middleware_tests.rs`。
  5. **C 清零 / 零新依赖**：无新增 C（bridge 100% Rust）; ldd 仅 libc 守住。
