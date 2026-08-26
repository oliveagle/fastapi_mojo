# src/fastapi_mojo/http_server_final.mojo
#
# Final HTTP server: json.mojo + router.mojo + params.mojo + middleware + static files
# Features: CORS, graceful shutdown, HEAD support, request ID, timing, static files

from std.ffi import external_call
from json import json_serialize_dict
from router import Router, RouteMatch
from params import parse_path_params, parse_query_params, parse_body_json, ParsedParams
from middleware import Middleware
from string_builder import decode_utf8_bytes, next_codepoint_len


def build_error_response(status: String, message: String) -> Dict[String, String]:
    """Build error response data."""
    var resp = Dict[String, String]()
    resp["error"] = message
    resp["status"] = status
    return resp^


def generate_request_id(req_num: Int) -> String:
    """Generate a simple request ID."""
    return "req-" + String(req_num)


def log_request(req_id: String, method: String, path: String, query: String, status: String):
    """Log request with ID and status."""
    var log = "[" + req_id + "] " + method + " " + path
    if query.byte_length() > 0:
        log += "?" + query
    log += " → " + status
    print(log)


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


def main() raises:
    print("=== Mojo HTTP Server v1.7 ===")

    external_call["set_static_dir", NoneType]("./static".as_c_string_slice())
    external_call["set_max_body_size", NoneType](1048576)

    var router = Router()
    router.add_route("/", "GET", "index")
    router.add_route("/health", "GET", "health")
    router.add_route("/status", "GET", "status")
    router.add_route("/routes", "GET", "routes")
    router.add_route("/hello", "GET", "hello")
    router.add_route("/items", "GET", "list_items")
    router.add_route("/items", "POST", "create_item")
    router.add_route("/items/{item_id}", "GET", "get_item")
    router.add_route("/items/{item_id}", "DELETE", "delete_item")
    print("Routes: " + String(router.route_count()))

    var mw_request_id = Middleware("request_id")
    var mw_logging = Middleware("logging")
    var mw_timing = Middleware("timing")
    print("Middleware: request_id, logging, timing")

    var sfd = external_call["create_bound_socket", Int](8000)
    if sfd < 0:
        print("ERROR: bind failed")
        external_call["bridge_fail", NoneType]()
        return
    print("Listening on http://127.0.0.1:8000")
    print("Press Ctrl+C to stop")

    var start_time = external_call["gettimeofday_ms", Int]()
    var req_num = 0

    for _ in range(2000000000):
        if not external_call["is_running", Int]():
            print("\nShutdown signal received...")
            break

        var cfd = external_call["accept_connection", Int](sfd)
        if cfd < 0:
            continue

        var n = external_call["recv_and_parse", Int](cfd)
        if n < 0:
            # C bridge already sent the appropriate error response:
            # -1 (malloc fail / no data), -2 (413 too large),
            # -3 (400 invalid request-line UTF-8), -4 (400 invalid body UTF-8),
            # -5 (408 request timeout — Slowloris guard)
            _ = external_call["close_fd", Int](cfd)
            continue
        if n == 0:
            _ = external_call["close_fd", Int](cfd)
            continue

        req_num += 1
        var req_id = generate_request_id(req_num)

        # Read request fields as raw bytes, then UTF-8 decode.
        # (chr()-per-byte would both corrupt multi-byte UTF-8 and be O(n^2).)
        var m_len = external_call["get_method_len", Int]()
        var method_bytes = List[Int]()
        for i in range(m_len):
            method_bytes.append(external_call["read_method_byte", Int](i))
        var method = decode_utf8_bytes(method_bytes)

        var p_len = external_call["get_path_len", Int]()
        var path_bytes = List[Int]()
        for i in range(p_len):
            path_bytes.append(external_call["read_path_byte", Int](i))
        var path = decode_utf8_bytes(path_bytes)

        var q_len = external_call["get_query_len", Int]()
        var query_bytes = List[Int]()
        for i in range(q_len):
            query_bytes.append(external_call["read_query_byte", Int](i))
        var query = decode_utf8_bytes(query_bytes)

        var b_len = external_call["get_body_len", Int]()
        var body_bytes = List[Int]()
        for i in range(b_len):
            body_bytes.append(external_call["read_body_byte", Int](i))
        var body_str = decode_utf8_bytes(body_bytes)

        # Handle OPTIONS preflight (CORS)
        if method == "OPTIONS":
            _ = external_call["send_preflight_response", Int](cfd)
            _ = external_call["close_fd", Int](cfd)
            log_request(req_id, method, path, query, "204 No Content")
            continue

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
            _ = external_call["close_fd", Int](cfd)
            log_request(req_id, method, path, query, sl + " (static)")
            continue

        # --- Route matching ---
        var route_result = router.match_route_with_params(path, effective_method)

        var query_params = parse_query_params(query)
        var body_params = ParsedParams()
        if (effective_method == "POST" or effective_method == "PUT") and body_str.byte_length() > 0:
            body_params = parse_body_json(body_str)

        # --- Handler dispatch ---
        var resp_data = Dict[String, String]()
        var status_line = "200 OK"

        if not route_result.matched:
            status_line = "404 Not Found"
            resp_data = build_error_response("404", "Route not found")
        else:
            var handler = route_result.handler_name
            if handler == "index":
                resp_data["message"] = "Welcome to Mojo HTTP Server"
                resp_data["version"] = "1.7.0"
            elif handler == "health":
                resp_data["status"] = "healthy"
                resp_data["uptime"] = "running"
            elif handler == "status":
                var uptime_ms = external_call["gettimeofday_ms", Int]() - start_time
                var uptime_s = uptime_ms // 1000
                resp_data["status"] = "running"
                resp_data["version"] = "1.7.0"
                resp_data["uptime"] = String(uptime_s) + "s"
                resp_data["requests_served"] = String(req_num)
                resp_data["routes"] = String(router.route_count())
                resp_data["middleware"] = "request_id, logging, timing"
            elif handler == "routes":
                resp_data["routes_count"] = String(router.route_count())
                resp_data["GET /"] = "index"
                resp_data["GET /health"] = "health"
                resp_data["GET /status"] = "status"
                resp_data["GET /routes"] = "routes"
                resp_data["GET /hello"] = "hello"
                resp_data["GET /items"] = "list_items"
                resp_data["POST /items"] = "create_item"
                resp_data["GET /items/{id}"] = "get_item"
                resp_data["DELETE /items/{id}"] = "delete_item"
            elif handler == "hello":
                resp_data["message"] = "Hello from Mojo!"
                if "name" in query_params.values:
                    resp_data["greeting"] = "Hello, " + query_params.values["name"] + "!"
            elif handler == "list_items":
                resp_data["items"] = "[]"
                resp_data["message"] = "List all items"
            elif handler == "create_item":
                resp_data["message"] = "Item created"
                for key in body_params.values:
                    resp_data["item_" + key] = body_params.values[key]
            elif handler == "get_item":
                resp_data["message"] = "Get item by ID"
                for key in route_result.params:
                    resp_data[key] = route_result.params[key]
            elif handler == "delete_item":
                resp_data["message"] = "Item deleted"
                for key in route_result.params:
                    resp_data[key] = route_result.params[key]
            else:
                resp_data = build_error_response("500", "Unknown handler: " + handler)
                status_line = "500 Internal Server Error"

        resp_data["method"] = method
        resp_data["path"] = path
        resp_data["handler"] = route_result.handler_name
        resp_data["request_id"] = req_id

        for key in query_params.values:
            resp_data["query_" + key] = query_params.values[key]

        var body = json_serialize_dict(resp_data)

        # Use HEAD response for HEAD requests (headers only, no body)
        if is_head:
            _ = external_call["send_head_response", Int](
                cfd,
                status_line.as_c_string_slice(),
                body.as_c_string_slice(),
            )
        else:
            _ = external_call["send_simple_response", Int](
                cfd,
                status_line.as_c_string_slice(),
                body.as_c_string_slice(),
            )
        _ = external_call["close_fd", Int](cfd)

        log_request(req_id, method, path, query, status_line)

    _ = external_call["close_fd", Int](sfd)
    print("Server stopped gracefully.")
