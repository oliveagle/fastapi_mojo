# src/fastapi_mojo/http_server.mojo
#
# Mojo native HTTP server MVP — delegates to C helpers for I/O

from std.ffi import external_call


def main():
    print("Starting Mojo HTTP Server MVP...")

    var port = 8000
    var server_fd = external_call["create_bound_socket", Int](port)
    if server_fd < 0:
        print("ERROR: Failed to bind on port " + String(port))
        return

    print("Listening on http://127.0.0.1:" + String(port))
    print("Ctrl+C to stop")

    # Accept one connection (MVP)
    var client_fd = external_call["accept_connection", Int](server_fd)
    if client_fd < 0:
        print("Failed to accept")
        _ = external_call["close_fd", Int](server_fd)
        return

    print("Client connected (fd=" + String(client_fd) + ")")

    var result = external_call["handle_request", Int](client_fd)
    if result == 0:
        print("Request handled and response sent")
    else:
        print("Error handling request")

    _ = external_call["close_fd", Int](server_fd)
    print("Server stopped.")
