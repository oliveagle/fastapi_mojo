# src/fastapi_mojo/handler.mojo
#
# 用户路由注册机制 (ADR-0004): Handler 类型 + 单点 run_handler dispatch.
#
# Mojo 1.0.0 约束（均已实测验证）:
#   - 无一等函数/闭包 -> handler = kind(Int) + name + data, 不是任意可调用对象
#   - match 语句不可用 -> if/elif dispatch
#   - 模块级 let 常量不允许 -> 零参 def 常量
#   - List 元素须 Copyable 才能 for 迭代 / .copy() -> 路由表用并行 List[String]
#     (String 可复制), 索引访问用 range(len()) (同 router.mojo 现有模式)
#
# 设计: 新增"路由" = 纯数据 (register_routes, 核心零改动);
#       新增"处理器行为" = 1 个 kind 常量 + run_handler 1 个 elif (唯一扩展点).

from std.ffi import external_call, CStringSlice
from string_builder import span_to_str, next_codepoint_len
from params_query import ParsedParams
from params_json import parse_body_json


# ---------- 处理器行为常量 (零参 def) ----------

def KIND_ECHO() -> Int:
    """回显全部已解析参数 (path + body; query 由核心 query_ 公共前缀回显)."""
    return 0


def KIND_STATIC() -> Int:
    """返回 handler.data 作为 JSON body (index/health/list_items)."""
    return 1


def KIND_STATUS() -> Int:
    """报告服务器状态 (uptime/请求数/路由数/中间件)."""
    return 2


def KIND_ROUTES() -> Int:
    """报告路由表 (从 ServerInfo 读取)."""
    return 3


def KIND_TEMPLATE() -> Int:
    """模板渲染: data 里的 {占位符} 用参数填充; 占位符缺失则省略该字段 (hello)."""
    return 4


def KIND_HTML() -> Int:
    """直接以 data["html"] 作为 text/html body 返回 (GET / 等动态前端路由).
    区别于 KIND_STATIC (返回 JSON): KIND_HTML 由 dispatch 检测后走 send_html_response
    (Content-Type: text/html; charset=utf-8). 适合 control-plane / dashboard 类应用."""
    return 5


def KIND_RUN_CMD() -> Int:
    """执行 data["cmd"] shell 命令, 捕获 stdout/stderr + 进程退出码 + timeout.
    返回 JSON: {"rc":N,"ok":bool,"out":"..","err":"..","timeout":bool}.
    data["timeout_ms"] 可选 (默认 15000). cmd 中的 {key} 由 path/query 参数填充;
    缺失参数 -> 占位符保留为字面量 (方便上层 debug).

    用于运营面板 (cron 重启 / 配置切换 / 子进程调用 / SSH 包装脚本) 等
    "HTTP 路由 = 一次 shell 命令" 的场景. run_command_json 在 C 桥实现."""
    return 6


# ---------- WebSocket 处理器行为 (ADR-0007) ----------

def KIND_WS_ECHO() -> Int:
    """WS 回显: text (UTF-8 校验后原样回显) / binary (零拷贝原样回显)."""
    return 100


def KIND_WS_COUNTER() -> Int:
    """WS 计数器 (有状态演示): text-only; 每条整数字消息累加进连接级 state,
    回复 "sum=<累计>"; 非整数 -> "error: expected an integer".
    binary 帧由会话层回 close 1003 (不支持的数据类型)."""
    return 101


def KIND_WS_GREET() -> Int:
    """WS 问候 (ADR-0009 {param} 路由演示): 回复 "hello {name}: {msg}",
    name 来自路由 {name} 参数 (缺失 -> world)."""
    return 102


def KIND_SSE() -> Int:
    """F5: SSE 流式响应. handler.data["_stream_events"] = "msg1|msg2|msg3" 声明要推送的事件.
    dispatch 一次性按 SSE spec 推送所有事件后关连接 (不维护长连接).
    参考 FastAPI 0.140.12 修复: format_sse_event 按行切分 (data 字段内换行 -> 多个 data: 行)."""
    return 200


# ---------- Handler 类型 ----------

struct Handler:
    """路由处理器: kind(行为) + name(用于 /routes 与日志) + data(每个路由的载荷)."""
    var kind: Int
    var name: String
    var data: Dict[String, String]

    def __init__(out self, kind: Int, name: String):
        self.kind = kind
        self.name = name
        self.data = Dict[String, String]()

    def set_data(mut self, key: String, value: String):
        self.data[key] = value

    def copy(self) -> Handler:
        var h = Handler(self.kind, self.name)
        h.data = self.data.copy()
        return h^


# ---------- 服务器状态快照 (供 STATUS / ROUTES 使用) ----------

struct ServerInfo:
    """服务器状态快照. 路由表用并行 List[String] (可复制, 避免非 Copyable struct 入 List)."""
    var version: String
    var middleware: String
    var uptime_s: Int
    var requests_served: Int
    var route_keys: List[String]    # "METHOD /path"
    var route_names: List[String]   # handler 名称 (与 route_keys 平行)

    def __init__(out self, version: String, middleware: String, uptime_s: Int,
                requests_served: Int, route_keys: List[String], route_names: List[String]):
        self.version = version
        self.middleware = middleware
        self.uptime_s = uptime_s
        self.requests_served = requests_served
        self.route_keys = route_keys.copy()
        self.route_names = route_names.copy()


# ---------- 模板渲染 ----------

def render_template(tpl: String, ctx: Dict[String, String]) raises -> Tuple[Bool, String]:
    """填充 {占位符}; 任一占位符缺失 -> (False, ...), 调用方省略该字段."""
    var out = String("")
    var i = 0
    var n = tpl.byte_length()
    while i < n:
        if tpl[byte=i] == '{':
            var j = i + 1
            while j < n and not (tpl[byte=j] == '}'):
                j += 1
            if j < n:
                var key = String(tpl[byte=i + 1 : j])
                if key in ctx:
                    out += ctx[key]
                    i = j + 1
                else:
                    return (False, out)
            else:
                out += String(tpl[byte=i : i + 1])
                i += 1
        else:
            out += String(tpl[byte=i : i + 1])
            i += 1
    return (True, out)


def substitute_params(tpl: String, ctx: Dict[String, String]) raises -> String:
    """填充 {key} -> ctx[key]; 缺失键 -> 保留 '{key}' 字面量 (KIND_RUN_CMD 用:
    让缺失参数可被命令自身读取, 避免静默填空掩盖 typo). 无 {key} -> 原样返回.
    UTF-8 safe: 非 '{{' 路径按整个 codepoint 前进 (旧版逐字节 i+=1 在多字节
    CJK 模板上崩溃 'not a codepoint boundary')."""
    var out = String("")
    var i = 0
    var n = tpl.byte_length()
    while i < n:
        # tpl[byte=i] 仅在 codepoint 边界安全; '{' 是 1 字节 ASCII, 直接比字节
        var cur = tpl[byte=i]
        if cur == '{':
            var j = i + 1
            while j < n and not (tpl[byte=j] == '}'):
                j += 1
            if j < n:
                var key = String(tpl[byte=i + 1 : j])
                if key in ctx:
                    out += ctx[key]
                else:
                    out += String(tpl[byte=i : j + 1])
                i = j + 1
            else:
                var cplen0 = next_codepoint_len(tpl, i)
                out += String(tpl[byte=i : i + cplen0])
                i += cplen0
        else:
            var cplen = next_codepoint_len(tpl, i)
            out += String(tpl[byte=i : i + cplen])
            i += cplen
    return out^


# ---------- 单一 dispatch 扩展点 ----------

def run_handler(handler: Handler,
                path_params: Dict[String, String],
                query: ParsedParams,
                body: ParsedParams,
                info: ServerInfo) raises -> Tuple[String, Dict[String, String]]:
    """全项目唯一"认识 kind"的地方. 返回 (status_line, resp_data).

    新增处理器行为 = 加一个 KIND_x() 常量 + 这里加一个 elif (显式扩展点).
    """
    # ECHO: 回显 data + path 参数 + body 参数
    if handler.kind == KIND_ECHO():
        var resp = Dict[String, String]()
        for k in handler.data:
            if not k.startswith("_"):   # "_" 前缀 = 内部配置, 不回显
                resp[k] = handler.data[k]
        var path_prefix = ""
        if "_path_prefix" in handler.data:
            path_prefix = handler.data["_path_prefix"]
        var body_prefix = ""
        if "_body_prefix" in handler.data:
            body_prefix = handler.data["_body_prefix"]
        for k in path_params:
            resp[path_prefix + k] = path_params[k]
        for k in body.values:
            resp[body_prefix + k] = body.values[k]
        return ("200 OK", resp^)

    # STATIC: 返回 data 作为 body
    elif handler.kind == KIND_STATIC():
        var resp = Dict[String, String]()
        for k in handler.data:
            resp[k] = handler.data[k]
        return ("200 OK", resp^)

    # STATUS: 服务器状态
    elif handler.kind == KIND_STATUS():
        var resp = Dict[String, String]()
        resp["status"] = "running"
        resp["version"] = info.version
        resp["uptime"] = String(info.uptime_s) + "s"
        resp["requests_served"] = String(info.requests_served)
        resp["routes"] = String(len(info.route_keys))
        resp["middleware"] = info.middleware
        return ("200 OK", resp^)

    # ROUTES: 路由表
    elif handler.kind == KIND_ROUTES():
        var resp = Dict[String, String]()
        resp["routes_count"] = String(len(info.route_keys))
        for i in range(len(info.route_keys)):
            resp[info.route_keys[i]] = info.route_names[i]
        return ("200 OK", resp^)

    # TEMPLATE: 用参数填充 data 里的 {占位符}
    elif handler.kind == KIND_TEMPLATE():
        var ctx = Dict[String, String]()
        for k in path_params:
            ctx[k] = path_params[k]
        for k in query.values:
            ctx[k] = query.values[k]
        for k in body.values:
            ctx[k] = body.values[k]
        var resp = Dict[String, String]()
        for k in handler.data:
            var rendered = render_template(handler.data[k], ctx)
            if rendered[0]:
                resp[k] = rendered[1]
        return ("200 OK", resp^)

    # HTML: 由 dispatch 检测后走 send_html_response (Content-Type: text/html).
    # 这里仍返回 dict ({"html": body}); dispatch 用 kind 决定走哪条发送路径.
    elif handler.kind == KIND_HTML():
        var resp = Dict[String, String]()
        resp["html"] = handler.data["html"]
        return ("200 OK", resp^)

    # RUN_CMD: 调 C 桥 run_command_json (shell + timeout + stdout/stderr 捕获)
    # 命令模板的 {key} 由 path/query 参数填充 (缺失 -> 占位符保留).
    elif handler.kind == KIND_RUN_CMD():
        var cmd = handler.data["cmd"]
        var ctx = Dict[String, String]()
        for k in path_params:
            ctx[k] = path_params[k]
        for k in query.values:
            ctx[k] = query.values[k]
        for k in body.values:
            ctx[k] = body.values[k]
        var final_cmd = cmd  # fall back to raw template on substitution error
        try:
            final_cmd = substitute_params(cmd, ctx)
        except e:
            pass
        var timeout_ms: Int = 15000
        if "timeout_ms" in handler.data:
            var tmo_str = handler.data["timeout_ms"]
            timeout_ms = atol(String(tmo_str))
        # C 桥: 返回 fmc_slice = CStringSlice(ptr, len), span_to_str -> Mojo String.
        var slice = external_call["run_command_json", CStringSlice[origin_of(String(""))]](
            final_cmd.as_c_string_slice(), Int64(timeout_ms))
        var json_str = span_to_str(slice.as_bytes())
        # 释放 C 侧 malloc 内存
        _ = external_call["run_command_free", NoneType](slice)
        # parse_body_json 把 {"rc":N,...} 解析成 dict (kind=10 不解析嵌套,
        # 但 RUN_CMD 返回的是顶层 dict, 足以满足 control-plane 调用方).
        var parsed = parse_body_json(json_str)
        var resp = Dict[String, String]()
        for k in parsed.values:
            resp[k] = parsed.values[k]
        # 当 run_command_json 返回非 JSON (例如 spawn 失败) 时, 提供降级字段
        if "rc" not in resp:
            resp["rc"] = "-1"
            resp["ok"] = "false"
            if "err" not in resp:
                resp["err"] = json_str
        # 控制面板需要的额外上下文 (前端 JS 用 d.code/d.ok/d.out/d.err; rc 与 code 同义)
        if "rc" in resp:
            resp["code"] = resp["rc"]
        resp["cmd"] = final_cmd
        return ("200 OK", resp^)

    else:
        var resp = Dict[String, String]()
        resp["error"] = "Unknown handler kind"
        resp["status"] = "501"
        return ("501 Not Implemented", resp^)


# ---------- WS 单点 dispatch 扩展点 (ADR-0007, 镜像 run_handler) ----------

def run_ws_message(handler: Handler, opcode: Int, msg: String, state: Int,
                   params: Dict[String, String]) raises -> Tuple[Int, String, Int]:
    """WS 消息分派 — 全项目唯一"认识 WS kind"的地方.
    返回 (reply_opcode, reply_text, new_state); reply_opcode 0 = 不回复.
    opcode: 1 = text (binary 帧由会话层在到达本函数前处理).
    state: 连接级整型状态 (如计数器累计值), 会话循环持有.
    params: 路由 {param} 参数 (ADR-0009; 无参数路由传空 Dict).
    新增 WS 行为 = 加一个 KIND_WS_x() 常量 + 这里加一个 elif (显式扩展点).
    """
    if handler.kind == KIND_WS_ECHO():
        return (1, msg, state)

    elif handler.kind == KIND_WS_COUNTER():
        var v = 0
        var ok = True
        var n = msg.byte_length()
        var i = 0
        while i < n:
            var d = ord(msg[byte=i])
            if d < 48 or d > 57:
                ok = False
                break
            if i >= 18:  # > 18 位必然超过 Int 范围
                ok = False
                break
            v = v * 10 + (d - 48)
            i += 1
        if not ok:
            return (1, "error: expected an integer", state)
        return (1, "sum=" + String(state + v), state + v)

    elif handler.kind == KIND_WS_GREET():
        var name = "world"
        if "name" in params:
            name = params["name"]
        return (1, "hello " + name + ": " + msg, state)

    else:
        return (0, "", state)


def main() raises:
    print("Testing Mojo handler (run_handler)...")

    var empty_params = ParsedParams()
    var keys = List[String]()
    var names = List[String]()
    keys.append("GET /")
    names.append("index")
    var info = ServerInfo("1.7.0", "request_id, logging, timing", 8, 100, keys, names)

    # STATIC
    var h_static = Handler(KIND_STATIC(), "health")
    h_static.set_data("status", "healthy")
    var r1 = run_handler(h_static, Dict[String, String](), empty_params, empty_params, info)
    assert r1[0] == "200 OK", "static status"
    assert r1[1]["status"] == "healthy", "static body"

    # STATUS
    var r2 = run_handler(Handler(KIND_STATUS(), "status"), Dict[String, String](),
                         empty_params, empty_params, info)
    assert r2[1]["requests_served"] == "100", "status requests"
    assert r2[1]["routes"] == "1", "status route count"

    # ROUTES
    var r3 = run_handler(Handler(KIND_ROUTES(), "routes"), Dict[String, String](),
                         empty_params, empty_params, info)
    assert r3[1]["routes_count"] == "1", "routes count"
    assert r3[1]["GET /"] == "index", "routes entry"

    # ECHO (path + body)
    var path_params = Dict[String, String]()
    path_params["item_id"] = "42"
    var body = ParsedParams()
    body.values["name"] = "widget"
    var h_echo = Handler(KIND_ECHO(), "create_item")
    h_echo.set_data("message", "Item created")
    h_echo.set_data("_body_prefix", "item_")
    var r4 = run_handler(h_echo, path_params, empty_params, body, info)
    assert r4[1]["item_id"] == "42", "echo path"
    assert r4[1]["item_name"] == "widget", "echo body prefix"
    assert r4[1]["message"] == "Item created", "echo data"

    # TEMPLATE (占位符填充 + 缺失省略)
    var h_tpl = Handler(KIND_TEMPLATE(), "hello")
    h_tpl.set_data("message", "Hello from Mojo!")
    h_tpl.set_data("greeting", "Hello, {name}!")
    var query = ParsedParams()
    query.values["name"] = "Mojo"
    var r5 = run_handler(h_tpl, Dict[String, String](), query, empty_params, info)
    assert r5[1]["message"] == "Hello from Mojo!", "tpl static"
    assert r5[1]["greeting"] == "Hello, Mojo!", "tpl filled"
    var r6 = run_handler(h_tpl, Dict[String, String](), ParsedParams(), empty_params, info)
    assert "greeting" not in r6[1], "tpl missing omitted"
    assert r6[1]["message"] == "Hello from Mojo!", "tpl other kept"

    # 未知 kind -> 501
    var r7 = run_handler(Handler(99, "bogus"), Dict[String, String](),
                         empty_params, empty_params, info)
    assert r7[0] == "501 Not Implemented", "unknown kind 501"

    print("Mojo handler test completed!")
