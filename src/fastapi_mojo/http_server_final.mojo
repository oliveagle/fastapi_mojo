# src/fastapi_mojo/http_server_final.mojo
#
# Final HTTP server: json.mojo + router.mojo + handler.mojo + params.mojo + static files
# Features: CORS, graceful shutdown, HEAD support, request ID, timing, static files
# Handler dispatch per ADR-0004: the core only calls run_handler(); the route
# table is built by register_routes() (user code = data).

from std.ffi import external_call, c_char, CStringSlice
from json import json_serialize_dict
from router import Router, RouteMatch
from handler import Handler, ServerInfo, run_handler, KIND_ECHO, KIND_STATIC, KIND_STATUS, KIND_ROUTES, KIND_TEMPLATE, KIND_HTML, KIND_RUN_CMD, KIND_WS_ECHO, KIND_WS_COUNTER, KIND_WS_GREET
from params_query import parse_path_params, parse_query_params, ParsedParams
from params_json import parse_body_json
from params_typed import validate_params, get_param_types, TypedError
from exceptions import build_exception_body, match_error_map, HTTPExceptionSpec, standard_status_line
from request_response import nest_dict, nest_list, nest_raw, parse_response_headers
from middleware import MiddlewareChain, Middleware, mw_request_id, mw_timing, mw_logging, now_ms
from string_builder import decode_utf8_bytes, next_codepoint_len, StringBuilder, span_to_str
from ws_session import run_ws_upgrade, handle_ws_data


def inject_request_headers(mut params: Dict[String, String], header_names_csv: String):
    """F3a: 把 _reads_headers 声明的 header 名按名从 C 桥读出, 注入 params.
    key 前缀 header_<name>; 缺失 -> 空串. 保持 String-only (与现有 handler 兼容)."""
    var n = header_names_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(header_names_csv[byte=i]) == 44)  # ','
        if is_sep:
            if i > start:
                var name = String(header_names_csv[byte=start:i])
                # trim
                var b = 0
                var e = name.byte_length()
                while b < e and (ord(name[byte=b]) == 32 or ord(name[byte=b]) == 9):
                    b += 1
                while e > b and (ord(name[byte=e - 1]) == 32 or ord(name[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    var clean = String(name[byte=b:e])
                    var v = String("")
                    var rc = external_call["extract_request_header", Int](
                        clean.as_c_string_slice())
                    if rc == 0:
                        var sl = external_call["get_header_value_slice", CStringSlice[origin_of(String(""))]]()
                        v = span_to_str(sl.as_bytes())
                    params["header_" + clean] = v
            start = i + 1
        i += 1

def build_error_response(status: String, message: String) -> Dict[String, String]:
    """Build error response data. FastAPI 语义: 统一 {detail, status} (Goal-0002 F2).
    向后兼容: e2e 只检查状态码, 不检查 body 字段名."""
    var resp = Dict[String, String]()
    resp["detail"] = message
    resp["status"] = status
    return resp^


def is_static_path(path: String) -> Bool:
    """Check if path should be served as a static file.

    Only paths with a known file extension are treated as static, so API
    routes (e.g. /hello, /items/42) are never misrouted. Previously ANY path
    containing a dot was treated as static (bug).
    """
    # Find the LAST dot (boundary-aware; '.' is ASCII so codepoint steps
    # always land on boundaries).
    var idx = -1
    var i = 0
    var n = path.byte_length()
    while i < n:
        if path[byte=i] == '.':
            idx = i
        i += next_codepoint_len(path, i)
    if idx < 0:
        return False
    var ext = path[byte=idx:]
    var known: List[String] = [
        ".html", ".htm", ".css", ".js", ".mjs", ".json", ".xml", ".txt",
        ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".webp",
        ".woff", ".woff2", ".pdf", ".map", ".css.map",
    ]
    for k in known:
        if ext == k:
            return True
    return False


# 路由表 (用户代码 = 纯数据, ADR-0004): 新增路由不需要改动核心 dispatch.
def register_routes(mut router: Router) raises:
    var index_h = Handler(KIND_STATIC(), "index")
    index_h.set_data("message", "Welcome to Mojo HTTP Server")
    index_h.set_data("version", "1.8.0")
    router.add_route("/", "GET", index_h)

    var health_h = Handler(KIND_STATIC(), "health")
    health_h.set_data("status", "healthy")
    health_h.set_data("uptime", "running")
    router.add_route("/health", "GET", health_h)

    router.add_route("/status", "GET", Handler(KIND_STATUS(), "status"))
    router.add_route("/routes", "GET", Handler(KIND_ROUTES(), "routes"))

    var hello_h = Handler(KIND_TEMPLATE(), "hello")
    hello_h.set_data("message", "Hello from Mojo!")
    hello_h.set_data("greeting", "Hello, {name}!")
    router.add_route("/hello", "GET", hello_h)

    var list_h = Handler(KIND_STATIC(), "list_items")
    list_h.set_data("items", "[]")
    list_h.set_data("message", "List all items")
    router.add_route("/items", "GET", list_h)

    var create_h = Handler(KIND_ECHO(), "create_item")
    create_h.set_data("message", "Item created")
    create_h.set_data("_body_prefix", "item_")
    router.add_route("/items", "POST", create_h)

    var get_h = Handler(KIND_ECHO(), "get_item")
    get_h.set_data("message", "Get item by ID")
    router.add_route("/items/{item_id}", "GET", get_h)

    var delete_h = Handler(KIND_ECHO(), "delete_item")
    delete_h.set_data("message", "Item deleted")
    router.add_route("/items/{item_id}", "DELETE", delete_h)

    # 验收路由 (ADR-0004 §4): 回显全部参数 — 注册 = 两行数据, 核心零改动
    router.add_route("/echo", "GET", Handler(KIND_ECHO(), "echo"))
    router.add_route("/echo", "POST", Handler(KIND_ECHO(), "echo"))

    # F1 类型化参数 demo (Goal-0002 §1.1): 声明式类型标注.
    #   /calc/{a}/{b}: a,b 必须为 int (path 参数强制必填).
    #   /typed?count=N&verbose=true: count int=5 (query 默认值), verbose bool (可选).
    var calc_h = Handler(KIND_ECHO(), "calc")
    calc_h.set_data("message", "Typed calc")
    calc_h.set_data("_param_types", "a:int;b:int")
    router.add_route("/calc/{a}/{b}", "GET", calc_h)

    var typed_h = Handler(KIND_ECHO(), "typed")
    typed_h.set_data("message", "Typed query")
    typed_h.set_data("_param_types", "count:int=5;verbose:bool")
    router.add_route("/typed", "GET", typed_h)

    # F2 声明式异常映射 demo (Goal-0002 §1.1): Handler.data["_error_map"]
    #   /errors/{item_id}: item_id=99 -> 404 (Item not found); 其它 int -> 422 (Invalid ID).
    #   命中时直接返回 {status, detail}, 不进 run_handler (FastAPI HTTPException 语义).
    var errors_h = Handler(KIND_ECHO(), "errors_demo")
    errors_h.set_data("message", "Error map demo")
    errors_h.set_data("_error_map", "item_id=99:404:Item not found;item_id=*:422:Invalid ID")
    router.add_route("/errors/{item_id}", "GET", errors_h)

    # F3 Request/Response + 嵌套 JSON demo (Goal-0002 §1.1):
    #   /ctx: 读 X-Custom header, 回显到 JSON 字段; 设 X-Handler: ctx 响应头; data 是嵌套 dict.
    #   /tags: tags 字段是嵌套 list.
    var ctx_h = Handler(KIND_ECHO(), "ctx")
    ctx_h.set_data("message", "ctx demo")
    ctx_h.set_data("_reads_headers", "X-Custom,User-Agent")
    ctx_h.set_data("_response_headers", "X-Handler: ctx;X-Server: fastapi_mojo")
    router.add_route("/ctx", "GET", ctx_h)

    # 嵌套 JSON demo: KIND_ECHO 自动把 resp_data 序列化, 我们构造 resp_data 注入嵌套.
    # 但 KIND_ECHO 当前直接 dict copy 不支持嵌套. 改用 KIND_STATIC + 预构造的 body
    # (用 nest_dict / nest_list 构造的 __nested__: 前缀字符串).
    var tags_h = Handler(KIND_STATIC(), "tags")
    # KIND_STATIC 直接以 handler.data 作为 JSON body 输出. 我们手工构造一个含嵌套的 dict
    # 通过 handler.data + nest_*; 但 handler.data 是 Dict[String,String], 仍受 String 约束.
    # 解决: 在 dispatch 里, KIND_STATIC + 包含 "__nested__:" value 的 dict 走 nest 序列化.
    # 这里简单: tags_h.data["tags"] = nest_list(["a", "b", "c"])
    var tag_items = List[String]()
    tag_items.append("a")
    tag_items.append("b")
    tag_items.append("c")
    var meta_d = Dict[String, String]()
    meta_d["user"] = "1"
    meta_d["role"] = "admin"
    tags_h.set_data("name", "demo")
    tags_h.set_data("tags", nest_list(tag_items))
    tags_h.set_data("meta", nest_dict(meta_d))
    router.add_route("/tags", "GET", tags_h)

    # WebSocket 端点 (ADR-0007): user code = data, 同 HTTP 路由注册模式。
    # 行为由 handler.kind 决定 (KIND_WS_*); "ws_sp" 数据项 = 必需子协议。
    router.add_ws_route("/ws", Handler(KIND_WS_ECHO(), "ws_echo"))

    var ws_counter_h = Handler(KIND_WS_COUNTER(), "ws_counter")
    router.add_ws_route("/ws/counter", ws_counter_h)

    var ws_chat_h = Handler(KIND_WS_ECHO(), "ws_chat")
    ws_chat_h.set_data("ws_sp", "chat")  # 客户端必须提供 Sec-WebSocket-Protocol: chat
    router.add_ws_route("/ws/chat", ws_chat_h)

    # ADR-0009: {param} 路由 + 鉴权 (升级 query token)
    router.add_ws_route("/ws/greet/{name}", Handler(KIND_WS_GREET(), "ws_greet"))
    router.add_ws_route("/ws/room/{room}", Handler(KIND_WS_ECHO(), "ws_room"))

    var ws_private_h = Handler(KIND_WS_ECHO(), "ws_private")
    ws_private_h.set_data("ws_token", "secret")  # 升级 query 必须带 token=secret
    router.add_ws_route("/ws/private", ws_private_h)


def serve_forever(router: Router, mw_chain: MiddlewareChain) raises:
    """HTTP event loop (poll + dispatch + WS), reusable across applications.
    Routes come from the caller-supplied router (cp_app.mojo plugs in app routes).
    Returns when a shutdown signal is received.
    """
    var start_time = external_call["gettimeofday_ms", Int]()
    var req_num = 0

    # 连接级 WS 状态 (ADR-0008): fd -> 状态值 (如计数器累计); 会话结束事件清理
    var ws_state = Dict[Int, Int]()

    for _ in range(2000000000):
        if not external_call["is_running", Int]():
            print("\nShutdown signal received...")
            break

        # v11: the C bridge owns the socket I/O — a poll() event loop over
        # the listen socket plus every active connection. It blocks until
        # one request is fully parsed, then returns its fd (the fields are
        # in the bridge globals, exposed by get_*_len/read_*_byte). Keep-
        # alive works because idle connections no longer block the loop.
        # 0 = nothing to do right now: a connection was closed (client EOF,
        # idle timeout, Slowloris 408, or an error response) — loop again.
        var cfd = external_call["recv_and_parse", Int]()
        if cfd <= 0:
            continue

        # --- WS 事件 (ADR-0008): bridge poll 循环驱动会话, Mojo 逐条处理 ---
        var ws_ev = external_call["ws_event_type", Int]()
        if ws_ev == 1:
            # 数据帧就绪 (text/binary): 按连接 path 查 WS 路由并分派
            var ws_path = span_to_str(
                external_call["get_ws_path_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
            var ws_match = router.match_ws_route(ws_path)
            if ws_match.matched:
                var ws_op = external_call["ws_last_opcode", Int]()
                var ws_st = 0
                if cfd in ws_state:
                    ws_st = ws_state[cfd]
                ws_st = handle_ws_data(cfd, ws_match.handler, ws_match.params, ws_op, ws_st)
                ws_state[cfd] = ws_st
            external_call["ws_message_done", NoneType](cfd)
            external_call["ws_pump_now", NoneType](cfd)  # 尾块/新帧立即处理 (不等 poll)
            continue
        if ws_ev == 2:
            # WS 会话结束 (close/EOF/保活耗尽): 清理连接级状态
            if cfd in ws_state:
                _ = ws_state.pop(cfd)
            continue

        req_num += 1
        var req_id = mw_request_id(mw_chain, req_num)
        var start_ms = now_ms()

        # Request fields are transferred from the C bridge in bulk as
        # CStringSlice (pointer + length) and UTF-8 decoded here in
        # amortized O(n) (the C side already validated the UTF-8).
        var method = span_to_str(external_call["get_method_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
        var path = span_to_str(external_call["get_path_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
        var query = span_to_str(external_call["get_query_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
        var body_str = span_to_str(external_call["get_body_slice", CStringSlice[origin_of(String(""))]]().as_bytes())

        # Handle OPTIONS preflight (CORS)
        if method == "OPTIONS":
            var duration_ms = mw_timing(mw_chain, start_ms)
            _ = external_call["send_preflight_response", Int](cfd)
            mw_logging(mw_chain, req_id, method, path, query, "204 No Content", duration_ms)
            external_call["conn_done", NoneType](cfd, False)  # preflight response announces Connection: close
        elif external_call["is_ws_upgrade", Int]() == 1:
            # WebSocket upgrade (RFC 6455, ADR-0006/0007/0008): WS route lookup +
            # 101 handshake + hand the connection to the bridge poll loop
            # (control frames / keepalive / UTF-8 handled in C; data frames are
            # dispatched one at a time via the ws_event_type branch above —
            # sessions no longer block dispatch, ADR-0008).
            var ws_match = router.match_ws_route(path)
            if ws_match.matched:
                var ws_status = run_ws_upgrade(cfd, ws_match.handler)
                var duration_ms = mw_timing(mw_chain, start_ms)
                if ws_status == 101:
                    ws_state[cfd] = 0  # 移交成功: 连接现为 WS 会话 (不 conn_done)
                    mw_logging(mw_chain, req_id, method, path, query, "101 Switching Protocols", duration_ms)
                    continue
                var ws_sl = "400 Bad Request"
                if ws_status == 403:
                    ws_sl = "403 Forbidden"
                elif ws_status == 500:
                    ws_sl = "500 Internal Server Error"
                mw_logging(mw_chain, req_id, method, path, query, ws_sl, duration_ms)
                external_call["conn_done", NoneType](cfd, False)
            else:
                var ws_resp = build_error_response("404", "Route not found")
                var ws_body = json_serialize_dict(ws_resp)
                _ = external_call["send_simple_response", Int](
                    cfd, "404 Not Found".as_c_string_slice(), ws_body.as_c_string_slice())
                var duration_ms = mw_timing(mw_chain, start_ms)
                mw_logging(mw_chain, req_id, method, path, query, "404 Not Found", duration_ms)
                external_call["conn_done", NoneType](cfd, False)
        else:
            # Handle HEAD method (same as GET but no body)
            var is_head = method == "HEAD"
            var effective_method = method
            if is_head:
                effective_method = "GET"


            # Try static file serving for GET/HEAD requests
            if (effective_method == "GET") and is_static_path(path):
                if is_head:
                    # HEAD: headers only, no body (a body would violate HTTP)
                    _ = external_call["send_static_file_head", Int](
                        cfd,
                        path.as_c_string_slice(),
                    )
                else:
                    _ = external_call["send_static_file", Int](
                        cfd,
                        path.as_c_string_slice(),
                    )
                # Log the REAL status (the C side may have answered 403/404/413
                # for the static request).
                var sl_len = external_call["get_last_status_len", Int]()
                var sl = String("")
                for i in range(sl_len):
                    var sb = external_call["read_last_status_byte", Int](i)
                    if sb >= 0:
                        sl += chr(sb)

                var duration_ms = mw_timing(mw_chain, start_ms)
                mw_logging(mw_chain, req_id, method, path, query, sl + " (static)", duration_ms)

                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
            else:
                # --- Route matching ---
                var route_result = router.match_route_with_params(path, effective_method)

                var query_params = parse_query_params(query)
                var body_params = ParsedParams()
                if (effective_method == "POST" or effective_method == "PUT") and body_str.byte_length() > 0:
                    body_params = parse_body_json(body_str)

                # --- Handler dispatch ---
                # (both branches below assign resp_data/status_line before use)
                var resp_data: Dict[String, String]
                var status_line: String
                var is_405 = False
                var allow_methods = List[String]()

                if not route_result.matched:
                    # Path exists but method not registered -> 405 + Allow (RFC 7231).
                    # Path does not exist at all -> 404.
                    allow_methods = router.methods_for_path(path)
                    if len(allow_methods) > 0:
                        is_405 = True
                        status_line = "405 Method Not Allowed"
                        resp_data = build_error_response("405", "Method not allowed")
                    else:
                        status_line = "404 Not Found"
                        resp_data = build_error_response("404", "Route not found")
                else:
                    # ADR-0004: 核心只调用 run_handler (单一 dispatch 扩展点).
                    # 新增路由 = register_routes 里加数据; 新增行为 = handler.mojo
                    # 加一个 KIND_x + run_handler 一个 elif.
                    var uptime_ms = external_call["gettimeofday_ms", Int]() - start_time
                    var uptime_s = uptime_ms // 1000
                    var route_keys = List[String]()
                    var route_names = List[String]()
                    for i in range(router.route_count()):
                        route_keys.append(router.routes[i].method + " " + router.routes[i].path)
                        route_names.append(router.routes[i].handler.name)
                    for i in range(router.ws_route_count()):
                        route_keys.append("WS " + router.ws_routes[i].path)
                        route_names.append(router.ws_routes[i].handler.name)
                    var info = ServerInfo("1.8.0", "request_id, logging, timing", uptime_s,
                                          req_num, route_keys, route_names)

                    # F1: 类型化参数校验 (Goal-0002 §1.1). 校验失败 -> 422 + detail.
                    # 校验通过 -> 继续 run_handler (handler 无感, ParamDict 仍是 String).
                    # 这是 dispatch 唯一一处"认识类型化"的代码; 新增类型化路由 = 仅在
                    # register_routes 用 set_data("_param_types", "name:type;name:type").
                    var type_spec = get_param_types(route_result.handler)
                    var type_err = validate_params(type_spec, route_result.params, query_params.values)
                    if type_err.has_error:
                        status_line = type_err.status_line
                        resp_data = Dict[String, String]()
                        resp_data["detail"] = type_err.detail
                        resp_data["status"] = "422"
                    else:
                        # F2: 声明式异常映射 (Goal-0002). 命中 -> 直接返回错误响应,
                        # 不进 run_handler. 这是 dispatch 唯一一处"认识 _error_map"的代码.
                        var exc = match_error_map(route_result.handler,
                                                  route_result.params, query_params.values)
                        if exc.status_code > 0:
                            status_line = exc.status_line
                            resp_data = build_exception_body(exc.detail, exc.status_code)
                        else:
                            # F3a: Request 读 headers (Goal-0002). 声明式 _reads_headers CSV.
                            # 注入 route_result.params 前缀 header_<name>; handler 直读.
                            var req_params = route_result.params.copy()
                            if "_reads_headers" in route_result.handler.data:
                                inject_request_headers(req_params, route_result.handler.data["_reads_headers"])
                            var result = run_handler(route_result.handler, req_params,
                                                     query_params, body_params, info)
                            status_line = result[0]
                            resp_data = result[1].copy()

                # KIND_HTML: 直接以 text/html 发送 (动态前端页 / 运营面板).
                # 走 send_html_response (Content-Type: text/html), 不再包 JSON.
                if route_result.handler.kind == KIND_HTML():
                    var html_body = ""
                    if "html" in resp_data:
                        html_body = resp_data["html"]
                    var duration_ms = mw_timing(mw_chain, start_ms)
                    if is_head:
                        _ = external_call["send_html_response", Int](
                            cfd, status_line.as_c_string_slice(), html_body.as_c_string_slice())
                    else:
                        _ = external_call["send_html_response", Int](
                            cfd, status_line.as_c_string_slice(), html_body.as_c_string_slice())
                    mw_logging(mw_chain, req_id, method, path, query, status_line, duration_ms)
                    if external_call["get_close_after_response", Int]() != 0:
                        external_call["conn_done", NoneType](cfd, False)
                    else:
                        external_call["conn_done", NoneType](cfd, True)
                    continue

                resp_data["method"] = method
                resp_data["path"] = path
                resp_data["handler"] = route_result.handler.name
                resp_data["request_id"] = req_id

                for key in query_params.values:
                    resp_data["query_" + key] = query_params.values[key]

                var duration_ms = mw_timing(mw_chain, start_ms)
                if duration_ms >= 0:
                    resp_data["duration_ms"] = String(duration_ms)

                var body = json_serialize_dict(resp_data)

                # Use HEAD response for HEAD requests (headers only, no body);
                # 405 carries the Allow header.
                if is_head:
                    _ = external_call["send_head_response", Int](
                        cfd,
                        status_line.as_c_string_slice(),
                        body.as_c_string_slice(),
                    )
                elif is_405:
                    var allow_str = ", ".join(allow_methods)
                    _ = external_call["send_simple_response_allow", Int](
                        cfd,
                        status_line.as_c_string_slice(),
                        body.as_c_string_slice(),
                        allow_str.as_c_string_slice(),
                    )
                else:
                    # F3b: 自定义响应头 (Goal-0002). 声明式 _response_headers = "Name:value;Name:value".
                    # 命中 -> 用 send_simple_response_extra, 多行头用 \r\n 分隔 (build_response_headers
                    # 内部追加末尾 CRLF).
                    var extra = ""
                    if "_response_headers" in route_result.handler.data:
                        var hdrs = parse_response_headers(route_result.handler)
                        if len(hdrs) > 0:
                            extra = "\r\n".join(hdrs)
                    if extra != "":
                        _ = external_call["send_simple_response_extra", Int](
                            cfd,
                            status_line.as_c_string_slice(),
                            body.as_c_string_slice(),
                            extra.as_c_string_slice(),
                        )
                    else:
                        _ = external_call["send_simple_response", Int](
                            cfd,
                            status_line.as_c_string_slice(),
                            body.as_c_string_slice(),
                        )


                mw_logging(mw_chain, req_id, method, path, query, status_line, duration_ms)

                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)

    external_call["server_shutdown", NoneType]()
    print("Server stopped gracefully.")

def main() raises:
    print("=== Mojo HTTP Server v1.8 ===")

    external_call["set_static_dir", NoneType]("./static".as_c_string_slice())
    external_call["set_max_body_size", NoneType](1048576)

    var router = Router()
    register_routes(router)   # 用户代码 = 数据 (ADR-0004)
    print("Routes: " + String(router.route_count()))

    var mw_chain = MiddlewareChain()
    mw_chain.add(Middleware("request_id"))
    mw_chain.add(Middleware("logging"))
    mw_chain.add(Middleware("timing"))
    print("Middleware: request_id, logging, timing")

    # Worker processes (ADR-0005): FASTAPI_MOJO_WORKERS=N (default 1 = single
    # process). Must run before create_bound_socket (SO_REUSEPORT binding).
    external_call["init_workers", NoneType]()

    # Listen port: CLI --port N > FASTAPI_MOJO_PORT env > 8000 (C side).
    var port = external_call["get_configured_port", Int]()
    var sfd = external_call["create_bound_socket", Int](port)
    if sfd < 0:
        print("ERROR: bind failed on port " + String(port))
        external_call["bridge_fail", NoneType]()
        return
    var worker_id = external_call["get_worker_id", Int]()
    if worker_id > 0:
        print("Worker #" + String(worker_id) + " (multi-worker mode, ADR-0005)")
    print("Listening on http://127.0.0.1:" + String(port))
    print("Press Ctrl+C to stop")

    serve_forever(router, mw_chain)
