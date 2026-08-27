# src/fastapi_mojo/http_server_final.mojo
#
# Final HTTP server: json.mojo + router.mojo + handler.mojo + params.mojo + static files
# Features: CORS, graceful shutdown, HEAD support, request ID, timing, static files
# Handler dispatch per ADR-0004: the core only calls run_handler(); the route
# table is built by register_routes() (user code = data).

from std.ffi import external_call, c_char, CStringSlice
from json import json_serialize_dict
from router import Router, RouteMatch
from handler import Handler, ServerInfo, run_handler, KIND_ECHO, KIND_STATIC, KIND_STATUS, KIND_ROUTES, KIND_TEMPLATE
from params import parse_path_params, parse_query_params, parse_body_json, ParsedParams
from middleware import MiddlewareChain, Middleware, mw_request_id, mw_timing, mw_logging, now_ms
from string_builder import decode_utf8_bytes, next_codepoint_len, StringBuilder, span_to_str


def build_error_response(status: String, message: String) -> Dict[String, String]:
    """Build error response data."""
    var resp = Dict[String, String]()
    resp["error"] = message
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

    # Listen port: CLI --port N > FASTAPI_MOJO_PORT env > 8000 (C side).
    var port = external_call["get_configured_port", Int]()
    var sfd = external_call["create_bound_socket", Int](port)
    if sfd < 0:
        print("ERROR: bind failed on port " + String(port))
        external_call["bridge_fail", NoneType]()
        return
    print("Listening on http://127.0.0.1:" + String(port))
    print("Press Ctrl+C to stop")

    var start_time = external_call["gettimeofday_ms", Int]()
    var req_num = 0

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
                var resp_data = Dict[String, String]()
                var status_line = "200 OK"
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
                    var info = ServerInfo("1.8.0", "request_id, logging, timing", uptime_s,
                                          req_num, route_keys, route_names)
                    var result = run_handler(route_result.handler, route_result.params,
                                             query_params, body_params, info)
                    status_line = result[0]
                    resp_data = result[1].copy()

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
