# src/fastapi_mojo/ws_protocol_routes.mojo
#
# Decision-60 (ADR-0035): application WebSocket subprotocol route registration.
# Splitting these routes from http_server_final keeps the protocol matrix cohesive
# and avoids growing the already-large server registration module.

from handler import Handler, KIND_WS_ECHO
from router import Router


def register_ws_protocol_routes(mut router: Router) raises:
    """Register JSON-RPC, GraphQL WebSocket, and gRPC-Web demo routes."""
    var jsonrpc = Handler(KIND_WS_ECHO(), "ws_jsonrpc")
    jsonrpc.set_data("ws_sp", "jsonrpc,v2.jsonrpc")
    jsonrpc.set_data("_ws_protocol", "jsonrpc")
    router.add_ws_route("/ws/jsonrpc", jsonrpc)

    var graphql = Handler(KIND_WS_ECHO(), "ws_graphql")
    graphql.set_data("ws_sp", "graphql-transport-ws,graphql-ws")
    graphql.set_data("_ws_protocol", "graphql-ws")
    router.add_ws_route("/ws/graphql-ws", graphql)

    var grpc_web = Handler(KIND_WS_ECHO(), "ws_grpc_web")
    grpc_web.set_data("ws_sp", "grpc-web")
    grpc_web.set_data("_ws_protocol", "grpc-web")
    router.add_ws_route("/ws/grpc-web", grpc_web)
