# src/fastapi_mojo/http_server_final.mojo
#
# Final HTTP server: json.mojo + router.mojo + params.mojo all integrated

from std.ffi import external_call
from json import json_serialize_dict
from router import Router, RouteMatch
from params import parse_path_params, parse_query_params, parse_body_json, ParsedParams


def main() raises:
    print("=== Mojo HTTP Server FINAL ===")

    var router = Router()
    router.add_route("/", "GET", "index")
    router.add_route("/hello", "GET", "hello")
    router.add_route("/items", "GET", "list_items")
    router.add_route("/items", "POST", "create_item")
    router.add_route("/items/{item_id}", "GET", "get_item")
    print("Routes: " + String(router.route_count()))

    var sfd = external_call["create_bound_socket", Int](8000)
    if sfd < 0:
        print("ERROR: bind failed")
        return
    print("Listening on http://127.0.0.1:8000")

    for req_num in range(10):
        var cfd = external_call["accept_connection", Int](sfd)
        if cfd < 0:
            continue

        var n = external_call["recv_and_parse", Int](cfd)
        if n <= 0:
            _ = external_call["close_fd", Int](cfd)
            continue

        # Read method from C bridge (inline FFI)
        var m_len = external_call["get_method_len", Int]()
        var method = String("")
        for i in range(m_len):
            var b = external_call["read_method_byte", Int](i)
            if b >= 0:
                method += chr(b)

        # Read path from C bridge
        var p_len = external_call["get_path_len", Int]()
        var path = String("")
        for i in range(p_len):
            var b = external_call["read_path_byte", Int](i)
            if b >= 0:
                path += chr(b)

        # Read query from C bridge
        var q_len = external_call["get_query_len", Int]()
        var query = String("")
        for i in range(q_len):
            var b = external_call["read_query_byte", Int](i)
            if b >= 0:
                query += chr(b)

        # Read body from C bridge
        var b_len = external_call["get_body_len", Int]()
        var body_str = String("")
        for i in range(b_len):
            var b = external_call["read_body_byte", Int](i)
            if b >= 0:
                body_str += chr(b)

        print("[" + String(req_num + 1) + "] " + method + " " + path + "?" + query)

        # --- Route matching with params (router.mojo) ---
        var route_result = router.match_route_with_params(path, method)

        # --- Query params (params.mojo) ---
        var query_params = parse_query_params(query)

        # --- Body params for POST (params.mojo) ---
        var body_params = ParsedParams()
        if method == "POST" and body_str.byte_length() > 0:
            body_params = parse_body_json(body_str)

        # --- Build response (json.mojo) ---
        var resp_data = Dict[String, String]()
        resp_data["server"] = "Mojo FINAL"
        resp_data["method"] = method
        resp_data["path"] = path
        resp_data["query"] = query
        resp_data["handler"] = route_result.handler_name

        if route_result.matched:
            resp_data["status"] = "200"
            for key in route_result.params:
                resp_data["param_" + key] = route_result.params[key]
        else:
            resp_data["status"] = "404"

        for key in query_params.values:
            resp_data["query_" + key] = query_params.values[key]

        if body_params.param_count > 0:
            resp_data["body_fields"] = String(body_params.param_count)
            for key in body_params.values:
                resp_data["body_" + key] = body_params.values[key]

        var body = json_serialize_dict(resp_data)

        var status_line = "200 OK"
        if not route_result.matched:
            status_line = "404 Not Found"
        _ = external_call["send_simple_response", Int](
            cfd,
            status_line.as_c_string_slice(),
            body.as_c_string_slice(),
        )
        _ = external_call["close_fd", Int](cfd)

    _ = external_call["close_fd", Int](sfd)
    print("Done.")
