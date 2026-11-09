# ADR-0065: 上游引擎转发（KIND_UPSTREAM + 长度前缀 JSON over TCP）（决策-90）

**状态**：已接受
**日期**：2026-11-09
**决策**：90
**关联**：AGENTS.md §1（North Star：**运行时零 Python**；引擎是**另一个进程**，
不是本 binary 的运行期依赖）、§3.2（代码约束：新行为 = 1 个 `KIND_*` 常量 +
`run_handler` 1 个 `elif`；Mojo 文件 <500 行 / Rust 模块 <500 行）、ADR-0004
（路由注册 = 纯数据）、ADR-0010（Rust bridge）、ADR-0023（FILE/SSE 同型发送特例）、
决策-36（slice 契约：NUL 终止 + 线程局部缓冲）

## 1. 背景（缺口）

项目此前只能返回**自己算出来的**响应：ECHO/STATIC/TEMPLATE/HTML/RUN_CMD/SSE/
FILE/REDIRECT 都在本进程内完成。真实部署里有一类服务长这样：

```
HTTP 语义（方法/状态码/头/CORS/keep-alive/限额）   ← 本该由本项目承担
业务计算（模型推理、需要 Python/CUDA 的引擎）      ← 只能在另一个进程里
```

把「模型进程」直接换成 FastAPI/uvicorn 是现状（可行但慢）：uvicorn 单进程在
并发 ≥8 时被 GIL 拖成 ~17 rps（见 §6 实测），而 HTTP 层本身只占 1.4ms。

要解决的是：**HTTP 层 100% 留在这里（零 Python），业务计算外置成引擎侧车**，
并且这条通道的开销要小到能从「框架省下的时间」里赚回来。

## 2. 决策

新增 `KIND_UPSTREAM()`（id 301）+ `run_handler` 一个 `elif`：
把**原始请求体字节**转发给引擎侧车，把**上游响应体字节**原样回传。

### 2.1 传输：长度前缀 JSON over TCP（刻意不用 HTTP）

```
请求帧: [u32 大端 total][u8 path_len][path bytes][body bytes]
响应帧: [u32 大端 total][u16 大端 status][payload]      total = 2 + len(payload)
```

为什么不是 HTTP：上游是引擎，不需要 HTTP 语义（状态码/头/cookie/CORS 都在本进程
完成）；一帧 JSON 足够。引擎侧因此**不必起 HTTP 框架**（无 uvicorn/FastAPI/
ASGI/pydantic），每请求 Python 开销从「框架解析 + 模型校验」降到「读 4 字节 +
一次 `json.loads`」。Rust 侧解析成本 = 读长度 + 读 N 字节，不做头扫描，也没有
chunked/keep-alive 歧义。请求帧里带 `path`（1 字节长度前缀）是为了同一端口能
服务多个端点（`/health`、`/v1/systemone`、未来 `/metrics`），而不必把 path 塞进
JSON body 二次编码。

### 2.2 FFI（`bridge/ffi.rs` §56，std-only，零新 crate）

| 函数 | 语义 |
|---|---|
| `upstream_call(host, ports_csv, path, path_len, payload, payload_len, timeout_ms, pin) -> c_long` | 返回响应体长度；`-1` = 失败 |
| `upstream_reply_slice() -> CSlice` | 上次响应体（线程局部缓冲，NUL 终止） |
| `upstream_error_slice() -> CSlice` | 上次错误文本（同上） |
| `upstream_status() -> c_long` | 上次上游状态码（0 = 传输失败） |

`payload` 用 `(ptr, len)` 传，**不假设 NUL 终止**（请求体可能含任意字节）；
`MAX_FRAME = 64MiB`、`MAX_PATH = 255`。

### 2.3 连接复用（实测必需）

引擎侧车是「每连接一个线程」；每请求新建 TCP 连接会让引擎为新线程付
CUDA/线程局部初始化。实测**每请求 +2.2ms**（28.4 → 30.6ms）。故 Rust 侧按
**线程局部**缓存一条到 `(host, port)` 的连接（keep-alive 帧通道），对端关闭/出错
则丢弃缓存并**重连一次**（= 一次透明重试）。修完 e2e p50 回到 28.6ms。

### 2.4 多副本：worker 绑定 + failover

- `ports_csv` 支持多副本（`18410,18412,18413`），`pin >= 0` 时固定取
  `ports[pin % n]`，`pin < 0` 轮转。
- `_upstream_worker_pin="true"` 时 Mojo 侧传 `worker_id` ⇒ **每个前端 worker 绑一个
  引擎副本**（1:1）。这不是为了分摊负载，而是为了**让每个引擎同时只有 1 个在飞
  请求**：引擎侧 GIL 在并发下互相打转（实测单引擎 c=8 反而掉到 17 rps，串行 35 rps）。
- 绑定副本失败 → 按环序**依次尝试其余副本**（failover）。实测杀掉 1/4 引擎后
  80/80 请求仍全绿。

### 2.5 响应：`__raw__` 原样通道

`run_handler` 返回 `("200 OK"|"502 Bad Gateway", {"__raw__": <上游字节>})`；
dispatch 在**注入 `method/path/handler/request_id/query_*` 之前**判定
`KIND_UPSTREAM()`，直接 `send_simple_response`（Content-Type: application/json）
后 `continue` —— 与 KIND_HTML 同位的发送特例，跳过 `response_model_body`。
上游状态码映射：`400/404/422/503/5xx` 原样透传，未知码降级 200（ADR-0023 §3.5 同款
「声明式 + 已知面透传」策略）。

### 2.6 生产 app 路由表（env 开关）

demo 路由表有 110 条演示路由（文件服务/上传/OAuth2/静态目录），不该出现在绑定
`0.0.0.0` 的生产前端上。故 `main()` 按 `FASTAPI_MOJO_APP` 选表：

```
FASTAPI_MOJO_APP=soft_decider
  POST /v1/systemone   -> 上游 path "/v1/systemone"（timeout 60s，worker 绑定）
  GET  /health         -> 上游 path "/health"（timeout 5s）
  GET  /v1/health      -> 同上（别名）
引擎地址: FASTAPI_MOJO_UPSTREAM_HOST（默认 127.0.0.1）
          FASTAPI_MOJO_UPSTREAM_PORTS（"18410,18412,..."）
```

默认（无该 env）= 原 demo 路由表，**e2e parity 不变**（回归验证见 §5）。

## 3. 实现

| 文件 | 变更 |
|---|---|
| `src/fastapi_mojo_rs/src/bridge/upstream.rs` | 新增（帧编解码 / 连接缓存 / `port_ring` failover 环序 / 线程局部 reply/error/status） |
| `src/fastapi_mojo_rs/src/bridge/upstream_tests.rs` | 新增 14 个测试（echo、path 帧序、空 body、拒连、不可解析 host、超长 payload/path、连接复用、stale 重连、`pick_port` 轮转/绑定、`port_ring` 环序、NUL 契约） |
| `src/fastapi_mojo_rs/src/bridge/ffi.rs` | §56 四个 `extern "C"` 函数 |
| `src/fastapi_mojo/handler.mojo` | `KIND_UPSTREAM()` + 1 个 `elif`（取 `get_body_slice` 原始字节 → `upstream_call` → `__raw__`） |
| `src/fastapi_mojo/http_server_final.mojo` | dispatch 发送特例（3 行判定 + `continue`）、`register_soft_decider_routes`、`main()` 选表 |

## 4. 验证

- `cargo test --release -- --test-threads=1 upstream`：**14 passed / 0 failed**
- bridge 全量：**528 passed / 2 failed / 4 ignored**（较改动前 514 passed 多出 14 项 =
  新增 upstream 测试；同两个失败项在 **pristine HEAD 复现**，与本改动无关：
  `cmd_tests::escaping_in_output` 依赖 `/bin/sh` 转义行为、
  `send_tests::static_file_traversal_returns_403` 依赖 static dir 状态）
- `scripts/e2e_test.sh`：**859 passed / 0 failed**（demo 路由表 parity 无回归）
- 回归：默认 app（demo 路由表）`/health` → `{"status":"healthy",...}`、`POST /echo`
  → 回显 + meta 字段，与改动前一致。
- 端到端（真实 soft-decider-421m 引擎，同 GPU、同请求体）：
  - `POST /v1/systemone` 响应体与 FastAPI 版**逐字节一致**（去掉 `usage.latency_ms`）
  - 坏 JSON → `422 {"detail":...}`；未知 path → `404`；引擎全挂 → `502 {"detail":...}`
- 二进制：`5,283,256 B`、`ldd` 仅 `libc/libm`（仍 libc-only、零 Python 运行时）

## 5. 偏差 / 已知限制

1. 引擎侧车的 `/health` 是**本进程**就绪度，不聚合上游；前端 `/health` 命中绑定副本
   （failover 后命中其余副本）—— 上游全挂时返回 502 而非 `{"status":"error"}`。
2. 响应只透传 body + 状态码，**不透传上游响应头**（引擎协议不含头；需要时给
   `_response_headers` 声明即可）。
3. `MAX_FRAME=64MiB`：引擎侧原子返回超大 JSON 会被拒（返回 `-1` / 502）。
4. 连接缓存是**线程局部**：多线程调用方（如自建线程池）会各持一条连接。
5. 生产 app 选表用 env 开关（`FASTAPI_MOJO_APP`），未做编译期裁剪（单 binary 仍带
   demo 路由表的代码体积）。

## 6. 实测（soft-decider-421m，单卡 CMP 170HX，同机同请求体）

| 场景 | FastAPI/uvicorn | 本方案（1 worker + 1 引擎） | 倍数 |
|---|---|---|---|
| c=1 | 30.0ms / 33.2 rps | 28.6ms / 34.8 rps | 1.05× |
| c=8 | 472ms / 17.0 rps | 231ms / 34.4 rps | **2.03×** |
| c=16 | 1101ms / 14.5 rps | 431ms / 34.5 rps | **2.37×** |

归因（同一进程内基准 p50 = 26.8-27.6ms）：
HTTP 框架只占 **~1.4ms**（两边相同）—— 差距全部来自**并发时的 GIL 行为**：
uvicorn 把 sync endpoint 丢进 anyio 线程池，多请求在 Python 侧互相打转；本方案的
前端是单线程 dispatch，天然只让引擎看到 1 个在飞请求，引擎因此跑在满速。

> 结论：换框架的收益不在单请求（1.05×），而在**并发吞吐**（2.0-2.4×），并且
> 前端 worker 数 × 引擎副本数可以线性叠加（4 卡单端口实测 95-109 rps）。
