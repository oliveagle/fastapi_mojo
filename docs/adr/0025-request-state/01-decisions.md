# ADR-0025: Request.state — 每请求状态存储（声明式 set/read + 参数插值）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #22 落地）
- **关联**：AGENTS.md §3/§6（**决策-50**）、Goal-0003（P2 矩阵 #22：
  Request 对象 — state）、North Star（Mojo + Rust only 单 binary 零依赖 —
  **零新 crate、零新 FFI**；ldd = 仅 libc）、ADR-0004（声明式 handler.data
  范式）、决策-34（Security — auth 身份注入先例）、决策-28/F10（`_reads_*`
  CSV 注入范式：header_<name>/cookie_<name>）、FastAPI 0.141.1 +
  starlette 1.6.0（/tmp/exch_probe p22* 逐条 probe + 源码核对，本 ADR
  §1 证据）

## 1. 背景

Goal-0003 矩阵 #22：`Request` 对象面 = state / client / url.full_url /
query_params — 其中 client / url / query_params 已有对应面（request_id /
path+query 参数注入 / ServerInfo）；缺口 = **`request.state`**（Starlette
每请求可写状态存储：middleware 写入 → endpoint 读取的典型模式）。

**上游实测证据（starlette 1.6.0 源码 + uvicorn 0.52.4 活体，
/tmp/exch_probe p22/p22b）**：

- **P22-1 双写读面**：`State`（datastructures.py:657）= dict 包装 —
  `state.x = v`（`__setattr__` → `self._state[key] = value`）与
  `state["x"] = v`（`__setitem__`）写同一存储；`state.x` / `state["x"]`
  双读面等价（实测 A1/A2：dict 写 → 属性读命中）。**starlette 1.6.0
  无下划线前缀禁止**（`__setattr__` 无 check — 旧版本/其他实现曾有）。
- **P22-2 scope 承载**：`Request.state` 是 **property**（requests.py:189）
  — 首读时 `scope.setdefault("state", {})` + `State(scope["state"])`。
  → **middleware 与 endpoint 共享同一 scope dict**（middleware 写、
  endpoint 读同一实例，实测 B /st-read：middleware 写 user/dep →
  endpoint 读到）；**每请求新 scope = 新 state**（实测 P22b：endpoint
  内写 foo 后，后续独立请求读 foo = 不存在，×2 无残留）。
- **P22-3 缺失读**：`state.missing` → `AttributeError: 'State' object
  has no attribute 'missing'`；`state["missing"]` → `KeyError: 'missing'`
  （实测 A4/A5）；endpoint 内缺失读 → 未处理异常 → **500
  "Internal Server Error"**（text/plain, charset=utf-8）+ 服务端
  traceback（实测 B：/st-missing-attr / /st-missing-dict 均 500；
  走决策-49 之前即有的默认 500 路径）。
- **P22-4 `del` quirk**：`__delattr__` = `del self._state[key]` —
  缺失键 → **KeyError**（非 AttributeError，实测 A6）；`del state.x`
  存在时正常删除。
- **P22-5 集合面**：`len(state)` / `iter(state)`（键）/ `"k" in state`
  可用（**无 `__contains__`** — `in` 经 `__iter__` 协议，实测 A3/A7）。
- **P22-6 每请求隔离（P22b 活体）**：endpoint 内写入同请求内后续读
  可见（`/st-write` 返回 foo_same_req=local-42 + has_foo=true）；
  **独立请求不可见**（`/st-read-foo` → `<absent>`，×2 重复请求无
  残留）→ state 生命周期 = 请求 scope，非连接/进程级。

**约束（Mojo 1.0.0 + 声明式范式）**：Mojo 无 Python 属性反射；
「middleware 代码写 state」在声明式世界 = **路由级声明写入**（本仓库
middleware 链 = 固定内建 logging/timing/request-id，无用户代码面）；
「endpoint 代码读 state」= **声明式读**（`_reads_*` CSV → params 注入，
决策-28 F10 既有范式）。状态存储 = Mojo `Dict[String, String]`
（每请求新建、请求后丢弃），零 FFI（纯 Mojo，JIT 可达）。

## 2. 候选方案

- **A. Rust bridge 承载 state**：❌ state = 纯每请求 KV 存储，无 I/O /
  无系统调用；放 bridge 违反分层向下依赖（§3.5-2 同 ADR-0024 论证）；
  且跨 FFI 传递 dict 每请求 NUL 终止开销 > 收益。
- **B. 声明式 `_state_set` + `_reads_state` + 每请求 Mojo dict**
  （✅ 采纳）：写 = 路由声明 `key:value;…`（值支持 `{param}` 插值 =
  「middleware 从请求计算」的声明式等价）；读 = CSV →
  `params["state_<name>"]`（F10 同范式）；存储 = dispatch 每请求新建
  `Dict[String, String]`（scope 语义，P22-2/6）；零新 FFI/零新 crate；
  注册期校验（畸形 `_state_set` 启动即 fail，与 `_body_schema` 同策略）。
- **C. 仅进程级 app.state 等价（env）**：❌ 矩阵 #22 是 **request**.state
  （每请求）；进程级全局值 = 所有请求共享，语义不同（P22-6 每请求隔离
  是核心语义）；且 env 一次性语义无法表达请求动态值。

## 3. 决策

1. **每请求 state 存储**：dispatch 内建路由分支每请求新建
   `var state = Dict[String, String]()`（= scope["state"] 等价，
   P22-2）；请求结束即弃（无跨请求残留 — P22-6）；值域 = String
   （声明式模板产物；上游值可为任意 Python 对象 — 见 §3.5-3）。
2. **写面 `_state_set`**（handler.data）：`"key:value;key2:value2"` —
   `;` 分条目、**首个 `:`** 分 key/value（value 可再含 `:`）；**值支持
   `{param}` 插值**（复用 `substitute_params`：ctx = path+query+body+
   auth 注入参数；缺失键保留 `{key}` 字面量 — KIND_RUN_CMD 同款语义，
   防静默填空）；评估位置 = auth/header/cookie/form 注入**之后**、
   `_reads_state` 注入之前（= 上游「middleware 先写、endpoint 后读」
   顺序的声明式等价）。空 key / 空条目跳过；**注册期校验**：key 非空
   且不含 `;`（天然，分隔符）/ 不含 `:`（首冒号切分强制）→ 启动 fail
   （与 `set_error_map` / `check_body_schemas` 同策略）。
3. **读面 `_reads_state`**（handler.data）：CSV 键名 →
   `params["state_<name>"]`（与 `_reads_headers` → `header_<name>` /
   `_reads_cookies` → `cookie_<name>` 完全同范式，决策-28）。**缺失键
   → `""`**（与 header/cookie 缺失既有约定一致 — 上游为
   AttributeError/KeyError → 500，见 §3.5-1）。
4. **demo 路由**（register_routes；**KIND_ECHO** — run_handler 的
   path_params 实参 = req_params，故 `state_<name>` 回显进 body，与
   `/ctx` 的 `header_` 同机制；`_` 前缀 data 键不回显）：
   - `/state` GET：`_state_set = "user:alice;dept:eng"` +
     `_reads_state = "user,dept"` → JSON `state_user`/`state_dept`；
   - `/state-dyn/{who}` GET：`_state_set = "user:{who};greeting:hi {who}"`
     + `_reads_state = "user,greeting"` → 参数插值演示（user/greeting
     来自 path 参数）；
   - `/state-missing` GET：无 `_state_set` + `_reads_state =
     "user,ghost"` → `state_user`/`state_ghost` 双空（本请求无写；即使
     前一请求写过 user=bob 也读不到 — **跨请求隔离证明**, P22-6）。
5. **不实现（文档化）**：`app.state`（进程级共享，矩阵 #22 未列；如需 =
   env 一次性值，零新面）；`del state.x` / `len` / `iter` 反射面
   （声明式世界无对等调用点 — §3.5-5）。

## 3.5 与上游的偏差（文档化，7 条）

| # | 上游语义 | 本实现 | 性质 |
|---|----------|--------|------|
| 1 | endpoint 内读缺失 state → AttributeError/KeyError → 500（P22-3） | `_reads_state` 声明式读缺失 → **`""`**（F10 header/cookie 既有约定） | **偏差（声明式约定）**：动态 Python 的异常面在声明式世界 = 缺失值约定；声明的键名在注册期可见（typo 可静态发现），运行期 500 的「保护」价值有限 |
| 2 | middleware/endpoint **代码**动态写 state（任意值、任意时机） | 写面 = **路由声明** `_state_set`（handler 前单点评估 + `{param}` 插值） | **偏差（声明式范式，ADR-0004）**：写入时机固定在 handler 前（无「handler 中途写」面）；但 observable 模式（前置阶段写 → handler 读）完整 |
| 3 | state 值 = 任意 Python 对象（dict/list/实例…） | 值域 = **String**（声明模板产物） | **偏差（类型面收窄）**：结构化值可 JSON 编码进字符串（调用方自行解析）；声明式世界的值域 = 文本 |
| 4 | `state.x` / `state["x"]` 双写读面 + `in`/`len`/`iter`/`del`（P22-1/4/5，含 del-missing → KeyError quirk） | 仅声明式 set/read（无属性反射/集合面） | **偏差（API 面收窄）**：声明式路由表即「静态可见的 state 使用面」，反射 API 无对等调用点 |
| 5 | `Request.state` property 惰性创建 + scope 承载（P22-2） | dispatch 每请求**显式新建** dict（效果等价：middleware↔handler 共享、每请求隔离） | **parity（机制不同，语义相同）** |
| 6 | 下划线前缀属性：1.6.0 **允许**（源码无 check） | 允许（parity）；但 `_state_set` key 以 `:`/`;` 切分，key 内容无额外限制 | **parity**（1.6.0 基线核对） |
| 7 | （无上游语义 — **环境项**）本机 dev 环境 (ole NAS) 的透明代理会劫持新 bind 端口 ~2s 内的首连接（Caddy :80 假空 200，真 server 收不到；taint 持续整个 bind 生命周期，实测） | e2e 6 副 server 就绪探针 + `fmtool bench` = **bind 后 sleep 5s** 再首探针 + `/health` body 须含 `healthy`（假响应 body 为空）防假 ready | **偏差（测试基础设施，环境特定，非语义）**：干净环境 (CI) 无此代理 — 仅多等 5s，body 校验为纯增强（真 `/health` = 含 healthy 的 JSON） |

## 4. 风险

- **R1 插值注入面**：`{param}` 值进入 state 后仅被本请求 handler 读取
  （params 注入，不出网络边界）— 无跨请求/跨客户端通道；值域 String。
- **R2 每请求 dict 开销**：热路径 +1 次空 dict 构造/丢弃（纳秒级，
  bench 区间内验证）。
- **R3 命名冲突**：`state_` 前缀 params key 与用户 query 参数同名时 —
  注入顺序决定（与 F10 header_/cookie_ 前缀同一既有约定，无新冲突面）。

## 5. 六条架构隔离约束声明

| # | 约束 | 状态 | 说明 |
|---|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`request_state → {handler, string_builder}`；`http_server_final → request_state`；handler 不反向引用 — 依赖图零环 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯 Mojo 每请求 dict（零 FFI 新增、零新 crate、零系统调用 — 比 ADR-0024 更轻）；dispatch 单点接线 |
| 3. God package 阈值 | ✅ 遵守 | 新增 `request_state.mojo` 124 行（<500）；`http_server_final.mojo` 1509 → 1551（既有超阈值 — ADR-0023/0024 已标注；本决策 +42 行 = import + state 构造/写/读接线 + 3 demo 路由） |
| 4. 主题域边界清晰 | ✅ 遵守 | request.state = 独立新域；F10 `_reads_headers`/`_reads_cookies` / auth / SSE / WS / 静态域零改动 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | ldd 保持仅 libc（零新 FFI）；`find src -name '*.c'` = 0 保持；binary ≤4.2M 门禁实测 |
| 6. 测试文件跟随 | ✅ 遵守 | `request_state_selftest.mojo`（新 76 行，纯逻辑 JIT 自检 — set 解析/插值/读注入/缺失/注册校验）+ e2e `XS-1..XS-7` — 全部与生产代码同目录 |

## 7. 验证方式（实测 2026-09-10）

1. **单 binary 不变式**：`ldd build/fastapi_mojo` = 仅 libc；binary
   **3,700,736 B**（3.7M ≤ 4.2M，vs 决策-49 基线 3,663,872 B +36 KB）；
   `env -i` 干净启动（`/health` JSON + `/state` + `/state-dyn/bob`
   实测全对，含 §3.5-7 warm-up 协议）；`find src -name '*.c'` = 0；
   `pgrep -x fastapi_mojo` = 0。
2. **质量门禁**：`cargo test --release -- --test-threads=1`
   (fastapi_mojo_rs) = **409 passed / 0 failed / 4 ignored**（零 FFI
   改动 — FFI diff = 0）；`cargo clippy --release --tests --
   -D warnings` 双 crate = **0 警告**；`mojo run
   request_state_selftest.mojo` = all checks passed（0 警告）。
3. **e2e**：366 → **373/373 全绿**（+XS-1..XS-7：`/state` set+read /
   `/state-dyn/bob` 参数插值 / `/state-missing` 双空串（缺失 → ""）/
   **跨请求隔离**（bob、alice 写后独立请求 state 仍空）/ `/health` 200
   / `/errors/99` 404 / `/exc/ve` 500 回归）。
4. **性能**：bench 6 场景 **0 errors**；**get_root_10k_100c =
   32,938 req/s**（32.9k–43.9k 区间内，vs Rust-only 基线 43.9k 噪声
   带内 / vs C-only 基线 35.8k — 无退化）；RSS 无线性泄漏（平台化）。
5. **环境注记**：本机 dev 环境透明代理（§3.5-7）导致的测试基础设施
   强化（e2e ×6 副 server + fmtool bench 各 +5s warm-up）已入库；
   干净环境 (CI) 行为不变，仅多等 5s。
