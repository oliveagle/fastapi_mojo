# ADR-0050: `Depends(yield)` 等价 — 依赖 teardown (声明式 `_dep_teardown`)

**状态**：已接受
**日期**：2026-09-12
**决策**：75（Goal-0003 §1 矩阵 #9 依赖注入 / `fastapi_mojo-dep-teardown-18z` bead）

## 1. 背景

决策-33（ADR-0011）落地了 `Depends()` 声明式等价（`_depends` / `_depends_nocache` +
每请求 memo 表），但只覆盖**依赖的 setup 面**：依赖输出被解析注入后即结束，
**没有 post-response teardown**（上游 FastAPI 的 `Depends(yield)` 生成器 cleanup）。

上游实测（fastapi 0.141.1 + starlette，`/tmp/fm_dep_probe/probe.py`）：

```
get_inner(): log("inner-enter"); yield "inner"; log("inner-exit")
get_outer(a=Depends(get_inner)): log("outer-enter"); yield "outer"; log("outer-exit")
GET /ok (deps + BackgroundTasks.add_task(log "bg")):
    ['inner-enter', 'outer-enter', 'endpoint', 'bg', 'outer-exit', 'inner-exit']
GET /raise (endpoint 抛 HTTPException):
    ['inner-enter', 'outer-enter', 'endpoint-raise']          # 裸后置代码被跳过
```

上游源码（`fastapi/routing.py` `request_response`，0.141.1）证实序：

```python
async with AsyncExitStack() as request_stack:          # ← 生成器依赖挂这里
    scope["fastapi_inner_astack"] = request_stack
    async with AsyncExitStack() as function_stack:     # scope="function" 依赖
        response = await f(request)
    await response(scope, receive, send)               # 发送 + 跑 background tasks
    response_awaited = True                            # ← request_stack 在此之后才关闭
```

即：**（1）teardown 在 background tasks 之后**；**（2）逆进入序**（后进入者先退出 =
LIFO）；**（3）异常时**，异常被 `throw` 进生成器 yield 点 → **裸后置代码被跳过**，
只有 `try/finally` 包裹才保证执行（上游官方推荐写法）。

## 2. 目标

1. 依赖可声明 teardown 命令，**响应 flush 后**执行（对齐上游 ExitStack 关闭时机）；
2. **逆解析序**（LIFO）执行；`use_cache=True` 每请求 teardown 一次；
3. 异常响应后**仍执行**（= 上游 `try/finally` 形式，官方推荐）；
4. **FFI diff = 0 / 零新依赖 / North Star 不变**（复用 `run_command_json`）。

## 3. 决策

### 3.1 声明式 API

- 依赖 handler 新增 `data["_dep_teardown"] = "cmd1\ncmd2"`（换行分隔多命令，
  命令内不含换行 —— 与决策-29 `_background` 同分隔约定）。
- 路由 `_depends` / `_depends_nocache` 引用该依赖时，teardown 自动登记。

### 3.2 登记（`dispatch_dep`）

- `dispatch_dep` / `resolve_depends` 增 `mut teardowns: List[String]` 参数（**内部
  函数签名，非 FFI**）。
- 依赖**实际派发**时（memo 命中不登记 → `use_cache=True` 每请求一次；子依赖先于
  父登记 → 解析完成序）追加其 `_dep_teardown`。

### 3.3 执行（`_run_dep_teardowns`）

- 响应 flush 后**逆序**遍历 collector（LIFO = 上游 ExitStack 关闭序），每条命令
  2000ms timeout + `[dep-teardown]` 日志（复用新提取的 `_exec_one_cmd`，与
  `_background` 共享）。
- 接入点 ×6：正常 JSON 路径（**在 `_run_background` 之后** → background 先于
  teardown，对齐上游）、异常路径、以及 SSE / streaming / File / Redirect 分支。
- 每连接迭代重置 `dep_teardowns`（每请求作用域）。

### 3.4 `_exec_one_cmd` 提取

`_run_background` 的 trim + `run_command_json` FFI + 日志块提取为
`_exec_one_cmd(cmd, timeout_ms, do_log, tag, req_id, method, path)`，供
`_background`（tag=`[bg]`）与 `_dep_teardown`（tag=`[dep-teardown]`）共用（单一
事实源，行为逐字节不变）。

### 3.5 demo + e2e

- `dep_td_inner` / `dep_td_outer`（嵌套 + 各自 `_dep_teardown` echo 到
  `/tmp/fm_dep_td.log`）；`/di-teardown`（+`_background` echo BG）/`/di-teardown-raise`
  （`_exception_raise`）/`/di-teardown-twice`（`_depends=A;A` 缓存）。
- e2e DT-1..4：嵌套输出 / 序 `BG,OUTER,INNER` / 异常后仍 `OUTER,INNER` / 缓存命中
  teardown 一次。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| teardown 在 `_finish_request` 内执行 | 拒绝 | 正常路径 `_run_background` 在其后 → teardown 会先于 background，与上游相反 |
| 只做正常路径 teardown | 拒绝 | 异常/SSE/File/Redirect 分支漏 teardown（parity 缺口） |
| 模拟裸后置代码（异常时跳过） | 拒绝 | 声明式无法表达裸 vs try/finally；`try/finally` 是官方推荐形式 |
| per-name 收集 + 逆序执行（本方案） | 接受 | 对齐上游 ExitStack 语义, FFI diff=0, 面最小 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | teardown 是 dispatch 层逻辑；仅复用既有 `run_command_json` FFI |
| 2. 分层向下依赖 | ✅ 遵守 | 依赖登记（Mojo 协议层）→ 命令执行（bridge cmd 原语）；无反向 |
| 3. God package 阈值 | ✅ 遵守 | `http_server_final.mojo` 既有 >500 豁免文件（本轮净增 ~90 行） |
| 4. 主题域边界清晰 | ✅ 遵守 | 依赖 teardown = DI 域；命令执行 = 既有 `_background` 同族（共享 `_exec_one_cmd`） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出、零新 crate、零新依赖） |
| 6. 测试文件跟随 | ✅ 遵守 | e2e DT-1..4（主 server）；demo 路由 `/di-teardown*` |

## 6. 验收（2026-09-12）

- e2e **591 → 595/595**（DT-1 嵌套输出 / DT-2 序 `BG,OUTER,INNER` /
  DT-3 异常 418 后仍 `OUTER,INNER` / DT-4 缓存 teardown 一次）。
- cargo bridge **505/0/4**（本轮无 Rust 改动）；clippy 双 crate 0；fmtool **35/0**。
- canonical `./benchmark.sh` 6 场景 **0 errors**（get_root_10k_100c ≈ 32.1k req/s）。
- `ldd` 仅 libc；`env -i` 干净启动 200；binary 5,077,416 B（≤6 MiB）；C=Python=orphans 0。

## 7. 实现 / 边界

- `src/fastapi_mojo/http_server_final.mojo`：`_exec_one_cmd`（提取）+
  `_run_dep_teardowns` + `dispatch_dep`/`resolve_depends` 签名 + 6 接入点 + 4 demo 路由。
- `scripts/e2e_test.sh`：DT-1..4。

边界：teardown = **声明式 shell 命令**（非运行期 Python 生成器）；**恒执行**
（= 上游 `try/finally` 形式 —— 上游裸后置代码在异常时被 throw 跳过，本实现不模拟该
分支，视为推荐写法等价）；`_dep_teardown` 不参与 `_dep_calls` 观测；teardown 命令
不支持内嵌换行；未在 SSE/File/Redirect 之外的早返回路径（405/静态/内置）登记
（那些路径在 DI 解析前返回，无依赖）。
