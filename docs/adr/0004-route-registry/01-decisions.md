# ADR-0004: 用户路由注册机制（Handler 类型 + 单点 dispatch）

- **日期**：2026-08-28
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行）
- **关联**：`src/fastapi_mojo/router.mojo`、`src/fastapi_mojo/handler.mojo`（新增）、`http_server_final.mojo`（dispatch 段）、AGENTS.md §6 决议链

## 1. 背景

当前服务器是"demo server"而非"框架"：`http_server_final.mojo` 的 dispatch 段是一个
针对 `handler_name`（字符串）的硬编码 `if/elif` 链（index/health/status/routes/hello/
list_items/create_item/get_item/delete_item 各一个分支）。要新增一条路由，必须同时：
1. 在 `main()` 里 `router.add_route(path, method, "handler_name")`；
2. 在 dispatch 的 `if/elif` 链里加一个分支写业务逻辑。

这违反"框架"的基本诉求：**用户代码应当只声明路由（数据），核心代码应当是通用的
（不含任何 per-handler 业务逻辑）**。本 ADR 决策如何在 Mojo 1.0.0 的现实约束下做到这一点。

## 2. Mojo 1.0.0 的硬约束（已逐一验证）

1. **无一等函数 / 闭包 / 函数指针**：不能把"用户任意 Mojo 函数"存进路由表再回调。
   因此 handler 不能是"任意可调用对象"，只能是**类型 + 数据**。
2. **`match` 语句不可用**（1.0.0 解析报错 `unexpected token in expression`）。dispatch
   只能用 `if/elif`。
3. **模块级 `let` 常量不允许**（`expressions must not appear at file scope`）。
   命名常量用**零参 `def`**（`def KIND_ECHO() -> Int: return 0`）——已验证可行。
4. **`struct` 可持有 `Dict`、可多参 `__init__`、函数可返回 `Tuple`**——均已验证，
   足以表达 `Handler` 类型与 `run_handler`。

结论：可行的最大设计是 **`Handler`（kind + name + data）+ 单一 `run_handler` dispatch
扩展点**。新增"路由"= 纯数据（不改核心）；新增"处理器行为"= 加一个 kind 常量 +
`run_handler` 里加一个 `elif` 分支（**唯一**的、显式的扩展点）。

## 3. 决策

### 3.1 `Handler` 类型定义（接口草案，P4.2 落地）

```mojo
# src/fastapi_mojo/handler.mojo
# 处理器行为常量（零参 def —— 模块级 let 在 1.0.0 不允许）
def KIND_ECHO() -> Int:     return 0   # 回显全部已解析参数（path/query/body）
def KIND_STATIC() -> Int:   return 1   # 返回 handler.data 作为 JSON body
def KIND_STATUS() -> Int:   return 2   # 报告服务器状态（uptime/请求数/路由数）
def KIND_ROUTES() -> Int:   return 3   # 报告路由表
def KIND_TEMPLATE() -> Int: return 4   # data 里的 {占位符} 用参数填充（如 hello）

struct Handler:
    """路由处理器：类型(kind) + 名称(用于 /routes 与日志) + 数据(每个路由的载荷)."""
    var kind: Int
    var name: String
    var data: Dict[String, String]

    def __init__(out self, kind: Int, name: String):
        self.kind = kind
        self.name = name
        self.data = Dict[String, String]()

    def set_data(mut self, key: String, value: String):
        self.data[key] = value

# 服务器状态快照（供 STATUS / ROUTES 这类有状态处理器使用）
struct ServerInfo:
    var version: String
    var middleware: String
    var uptime_s: Int
    var requests_served: Int
    var router: Router

# 单一 dispatch 扩展点 —— 全项目唯一"认识 kind 的地方"。
# 返回 (status_line, resp_data)。
def run_handler(handler: Handler,
                path_params: Dict[String, String],
                query: ParsedParams,
                body: ParsedParams,
                info: ServerInfo) -> Tuple[String, Dict[String, String]]:
    if handler.kind == KIND_ECHO():
        ...  # 回显 path/query/body 全部参数
    elif handler.kind == KIND_STATIC():
        ...  # 返回 handler.data
    elif handler.kind == KIND_STATUS():
        ...  # 从 info 读状态
    elif handler.kind == KIND_ROUTES():
        ...  # 从 info.router 列表
    elif handler.kind == KIND_TEMPLATE():
        ...  # 用参数填充 handler.data 里的 {占位符}
    else:
        return ("501 Not Implemented", build_error_response("501", "Unknown handler kind"))
```

### 3.2 路由注册（用户代码 = 纯数据，不改核心）

```mojo
# 用户代码（例如 register_routes，或用户自己的模块）
def register_routes(router: Router) raises:
    router.add_route("/",        "GET",  Handler(KIND_STATIC(),   "index").with_data(...))
    router.add_route("/health",  "GET",  Handler(KIND_STATIC(),   "health"))
    router.add_route("/status",  "GET",  Handler(KIND_STATUS(),   "status"))
    router.add_route("/routes",  "GET",  Handler(KIND_ROUTES(),   "routes"))
    router.add_route("/hello",   "GET",  Handler(KIND_TEMPLATE(), "hello"))
    router.add_route("/items",   "GET",  Handler(KIND_STATIC(),   "list_items"))
    router.add_route("/items",   "POST", Handler(KIND_ECHO(),     "create_item"))
    router.add_route("/items/{item_id}", "GET",    Handler(KIND_ECHO(), "get_item"))
    router.add_route("/items/{item_id}", "DELETE", Handler(KIND_ECHO(), "delete_item"))
    # ↓ 新增 /echo：一行数据，核心 dispatch 零改动
    router.add_route("/echo",    "GET",  Handler(KIND_ECHO(),     "echo"))
    router.add_route("/echo",    "POST", Handler(KIND_ECHO(),     "echo"))
```

### 3.3 核心 dispatch 的改写

`http_server_final.mojo` 的 dispatch 段从 ~90 行 `if/elif handler_name` 收敛为：

```mojo
var route_result = router.match_route_with_params(path, effective_method)
if not route_result.matched:
    ... 405/404（不变）
else:
    var handler = route_result.handler          # Handler 对象（不再只是字符串名）
    var info = ServerInfo(version, middleware, uptime_s, req_num, router)
    var (status_line, resp_data) = run_handler(handler, route_result.params,
                                                query_params, body_params, info)
    ... 追加 method/path/request_id 等公共字段（不变）
```

核心不再 import 任何 per-handler 业务逻辑；它只调用 `run_handler`。

### 3.4 否决的备选

| 备选 | 否决原因 |
|------|---------|
| 维持字符串 `if/elif`（现状） | 每加一条路由都要改核心，正是本 ADR 要消除的耦合 |
| 一等函数 / 闭包存进路由表 | Mojo 1.0.0 不支持（§2.1）；等上游（见 §3.6 未来路径） |
| C FFI 回调（handler 作为 C 函数指针） | 违背"Mojo 原生 handler"目标（已决策-5/6），且 C 侧无法安全持有 Mojo 对象 |
| 构建期代码生成（生成 dispatch 源码） | 引入构建步骤 + 生成代码难以调试；与"单一 binary 运行时"体验冲突 |
| `match` 语句 dispatch | 1.0.0 不可用（§2.2）；且 `if/elif` 已满足"单点扩展"诉求 |

### 3.5 约束与边界

- **新增路由**（复用已有 kind）= 纯数据，核心零改动 —— 这是本 ADR 的主要目标，
  由 `/echo` 验收（P4.2）。
- **新增处理器行为**（新 kind）= 加一个 `def KIND_x()` 常量 + `run_handler` 一个
  `elif` 分支。这是**唯一**的显式扩展点，集中在一处、有测试覆盖，
  优于散落在核心 dispatch 的 9 个 `elif`。
- `run_handler` 是**同步纯 Mojo**（无 FFI、无 Python），符合 AGENTS.md §3.2
  "handler 业务逻辑由 Mojo 驱动"。
- `Handler.data` 是 `Dict[String, String]`（与现有响应模型一致）；未来若需
  非字符串载荷，在 `run_handler` 内扩展（仍是单点）。

### 3.6 未来路径（不在本 ADR 范围）

- Mojo 1.1+ 若提供一等函数 / 闭包 / `match`，可将 `kind+if/elif` 平滑升级为
  "路由表存可调用对象"，`run_handler` 退化为一次调用；`Handler` 的 `name`/`data`
  字段保留，迁移成本可控。
- 若需真正的用户自定义逻辑（非内置 kind），短期方案是用户模块内自建
  `if/elif` 并在 `main` 前预处理请求（不进入本框架），长期等上游一等函数。

## 4. 决策结果

- 新增 `src/fastapi_mojo/handler.mojo`：`Handler` / `ServerInfo` / kind 常量 /
  `run_handler`（单一 dispatch 扩展点）。
- `router.mojo`：`Route` 的 `handler_name: String` 扩展为携带 `Handler`
  （保持 `handler_name` 兼容字段用于 /routes 与日志）。
- `http_server_final.mojo`：dispatch 段改为调用 `run_handler`；路由表构建改为
  `register_routes()`（用户代码 = 数据）。
- `/echo` 作为验收路由（回显全部参数，注册只需一行数据）。
- 测试：`test_all.mojo` 新增 `run_handler` 各 kind 用例 + `/echo` 端到端；
  `scripts/e2e_test.sh` 新增 `/echo` GET/POST 场景（P4.5）。

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 依赖方向单向：`http_server_final` → `handler` → (`router`, `params`)；`handler` 不反向 import 服务器；`router`/`params` 不 import `handler` |
| 2. 分层向下依赖 | ✅ 遵守 | 业务层（handler 逻辑）→ 路由层（router）→ 参数层（params）；`run_handler` 只依赖下层类型，不依赖 C 桥接/网络 |
| 3. God package 阈值 | ✅ 遵守 | 新增 `handler.mojo` 预计 < 200 行；`http_server_final.mojo` 因 dispatch 收敛反而减少 ~60 行；各 .mojo 均 < 500 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | `handler.mojo` 只含"处理器行为"主题（kind + run_handler + 内置处理器实现），不含路由匹配（router.mojo）/参数解析（params_query.mojo / params_json.mojo）/网络（C 桥接） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | `run_handler` 是唯一的"处理器行为分派"扩展点，显式命名、有 ADR 记录、有测试；不引入隐式回调或字符串魔法（kind 是显式 Int 常量） |
| 6. 测试文件跟随 | ✅ 遵守 | `handler.mojo` 自带 `main()` 自检（各 kind）；`test_all.mojo` 集成 `run_handler` 用例；`/echo` 端到端进 e2e_test.sh（P4.5） |

## 6. 验证方式

1. `mojo run handler.mojo`：`run_handler` 对 5 个 kind 各返回正确 (status, data)；
   未知 kind 返回 501。
2. `mojo run test_all.mojo`：新增 `run_handler` 用例 + 路由注册用例全绿。
3. 单 binary 启动后 `curl /echo?a=1&b=2`、`curl -X POST /echo -d '{"x":3}'`
   均回显全部参数（GET 的 query、POST 的 body）；`/routes` 列出 `/echo`。
4. 新增一个 `/echo` 路由后，`http_server_final.mojo` 的 dispatch 段 diff 为空
   （证明核心零改动）。
5. `./scripts/e2e_test.sh` 全绿（含新增 /echo 场景，P4.5）。
