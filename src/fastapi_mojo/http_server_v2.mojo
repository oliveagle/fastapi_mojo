# src/fastapi_mojo/http_server_v2.mojo
#
# HTTP server v2: router.mojo integration
# C handles I/O + JSON, Mojo handles route matching

from std.ffi import external_call
from router import Router


def main():
    print("=== Mojo HTTP Server v2 ===")

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

    for _ in range(3):
        var cfd = external_call["accept_connection", Int](sfd)
        if cfd < 0:
            continue

        var n = external_call["recv_to_global", Int](cfd)
        if n <= 0:
            _ = external_call["close_fd", Int](cfd)
            continue

        _ = external_call["parse_request_c", Int]()

        # Read method byte-by-byte from C bridge
        var m_len = external_call["get_method_len", Int]()
        var method = String("")
        for i in range(m_len):
            var b = external_call["read_method_byte", Int](i)
            if b >= 0:
                method += chr(b)

        # Read path byte-by-byte from C bridge
        var p_len = external_call["get_path_len", Int]()
        var path = String("")
        for i in range(p_len):
            var b = external_call["read_path_byte", Int](i)
            if b >= 0:
                path += chr(b)

        print("  " + method + " " + path)

        # Route matching via router.mojo
        var matched = router.match_route(path, method)

        # Send response via C
        _ = external_call["send_json_response", Int](cfd, Int(matched))
        _ = external_call["close_fd", Int](cfd)

    _ = external_call["close_fd", Int](sfd)
    print("Done.")
