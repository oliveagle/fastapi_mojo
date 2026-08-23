# src/fastapi_mojo/http_server_final.mojo
#
# Final HTTP server: json.mojo + router.mojo + params.mojo all integrated

from std.ffi import external_call
from json import json_serialize_dict
from router import Router
from params import parse_path_params, parse_query_params, ParsedParams


def main() raises:
    print("=== Mojo HTTP Server FINAL ===")

    var router = Router()
    router.add_route("/", "GET")
    router.add_route("/hello", "GET")
    router.add_route("/items", "GET")
    router.add_route("/items", "POST")
    router.add_route("/items/{item_id}", "GET")
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

        # Read method from C bridge
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

        print("[" + String(req_num + 1) + "] " + method + " " + path + "?" + query)

        # --- Route matching (router.mojo) ---
        var matched = router.match_route(path, method)

        # --- Param parsing (params.mojo) ---
        var path_params = parse_path_params(path, "/items/{item_id}")
        var query_params = parse_query_params(query)

        # --- Build response body (json.mojo) ---
        var resp_data = Dict[String, String]()
        resp_data["server"] = "Mojo FINAL"
        resp_data["method"] = method
        resp_data["path"] = path
        resp_data["query"] = query
        resp_data["route_matched"] = String(matched)
        resp_data["path_params_count"] = String(path_params.param_count)
        resp_data["query_params_count"] = String(query_params.param_count)
        if matched:
            resp_data["status"] = "200"
        else:
            resp_data["status"] = "404"

        # json_serialize_dict produces JSON body (json.mojo)
        var body = json_serialize_dict(resp_data)

        # Send via C helper (Mojo builds body, C sends response)
        var status_line = "200 OK"
        if not matched:
            status_line = "404 Not Found"
        _ = external_call["send_simple_response", Int](
            cfd,
            status_line.as_c_string_slice(),
            body.as_c_string_slice(),
        )
        _ = external_call["close_fd", Int](cfd)

    _ = external_call["close_fd", Int](sfd)
    print("Done.")
