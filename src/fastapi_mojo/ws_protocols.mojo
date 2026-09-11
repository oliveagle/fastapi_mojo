# src/fastapi_mojo/ws_protocols.mojo
#
# Decision-60 (ADR-0035): WebSocket application subprotocol matrix.
#
# This module stays FFI-free and protocol-pure:
#   * jsonrpc     - JSON-RPC 2.0 request/notification semantics
#   * graphql-ws  - graphql-transport-ws + legacy graphql-ws control messages
#   * grpc-web    - binary transport is handled by the session layer
#
# Return convention from run_ws_protocol:
#   (1, reply, state) - one TEXT reply
#   (2, replies, state) - zero or more newline-separated TEXT replies
#   (0, "", state) - notification / intentionally no reply
#   (-1, reason, state) - protocol violation; close 4400:<reason>

from json import json_serialize
from numlit import fmt_num, parse_f64
from params_json import parse_body_json


def _typed_json(value: String, kind: String) -> String:
    """Serialize a parse_body_json value using its preserved JSON type."""
    if kind == "string":
        return json_serialize(value)
    if kind == "object" or kind == "array":
        return value
    return value  # int, float, bool, and null are already valid JSON.


def _id_json(values: Dict[String, String], types: Dict[String, String], key: String) raises -> String:
    """Render an id while preserving String/Number/Null JSON type."""
    if key not in values:
        return "null"
    return _typed_json(values[key], types[key])


def _jsonrpc_result(id_json: String, result_json: String) -> String:
    return '{"jsonrpc": "2.0", "id": ' + id_json + ', "result": ' + result_json + '}'


def _jsonrpc_error(id_json: String, code: Int, message: String) -> String:
    return '{"jsonrpc": "2.0", "id": ' + id_json + ', "error": {"code": ' + String(code) \
        + ', "message": ' + json_serialize(message) + '}}'


def _jsonrpc_message(msg: String, state: Int) raises -> Tuple[Int, String, Int]:
    var parsed = parse_body_json(msg)
    var unknown_id = "null"
    if parsed.has_error:
        return (1, _jsonrpc_error(unknown_id, -32700, "Parse error"), state)
    if "jsonrpc" not in parsed.values or parsed.values["jsonrpc"] != "2.0":
        return (1, _jsonrpc_error(unknown_id, -32600, "Invalid Request"), state)
    if "method" not in parsed.values or parsed.type_of("method") != "string":
        return (1, _jsonrpc_error(unknown_id, -32600, "Invalid Request"), state)

    var is_notification = "id" not in parsed.values
    var id_json = "null"
    if not is_notification:
        var id_kind = parsed.type_of("id")
        if not (id_kind == "string" or id_kind == "int" or id_kind == "float" or id_kind == "null"):
            return (1, _jsonrpc_error(unknown_id, -32600, "Invalid Request"), state)
        id_json = _typed_json(parsed.values["id"], id_kind)
    if is_notification:
        return (0, "", state)

    var method = parsed.values["method"]
    if method == "ping":
        return (1, _jsonrpc_result(id_json, json_serialize("pong")), state)

    if method == "echo":
        if "params" not in parsed.values:
            return (1, _jsonrpc_result(id_json, "null"), state)
        var kind = parsed.type_of("params")
        if not (kind == "object" or kind == "array"):
            return (1, _jsonrpc_error(id_json, -32602, "Invalid params"), state)
        return (1, _jsonrpc_result(id_json, _typed_json(parsed.values["params"], kind)), state)

    if method == "add":
        if "params" not in parsed.values or parsed.type_of("params") != "object":
            return (1, _jsonrpc_error(id_json, -32602, "Invalid params"), state)
        var params = parse_body_json(parsed.values["params"])
        if params.has_error or "a" not in params.values or "b" not in params.values:
            return (1, _jsonrpc_error(id_json, -32602, "Invalid params"), state)
        var pa = parse_f64(params.values["a"])
        var pb = parse_f64(params.values["b"])
        if not (pa[0] and pb[0]):
            return (1, _jsonrpc_error(id_json, -32602, "Invalid params"), state)
        return (1, _jsonrpc_result(id_json, fmt_num(pa[1] + pb[1])), state)

    return (1, _jsonrpc_error(id_json, -32601, "Method not found"), state)


def _graphql_reply(kind: String, id_json: String, payload: String) -> String:
    if id_json == "":
        return '{"type": ' + json_serialize(kind) + '}'
    return '{"type": ' + json_serialize(kind) + ', "id": ' + id_json \
        + ', "payload": ' + payload + '}'


def _graphql_message(msg: String, state: Int) raises -> Tuple[Int, String, Int]:
    var parsed = parse_body_json(msg)
    if parsed.has_error or "type" not in parsed.values or parsed.type_of("type") != "string":
        return (-1, "invalid GraphQL WS message", state)
    var kind = parsed.values["type"]
    var id_json = ""
    if "id" in parsed.values:
        var id_kind = parsed.type_of("id")
        if not (id_kind == "string" or id_kind == "int" or id_kind == "float"):
            return (-1, "invalid operation id", state)
        id_json = _typed_json(parsed.values["id"], id_kind)

    if kind == "connection_init":
        return (1, '{"type": "connection_ack"}', state)
    if kind == "ping":
        return (1, '{"type": "pong"}', state)
    if kind == "complete" or kind == "stop" or kind == "connection_terminate":
        return (0, "", state)

    if kind == "subscribe" or kind == "start":
        if id_json == "" or "payload" not in parsed.values or parsed.type_of("payload") != "object":
            return (-1, "invalid subscribe message", state)
        var payload = parse_body_json(parsed.values["payload"])
        if payload.has_error or "query" not in payload.values or payload.type_of("query") != "string":
            return (-1, "invalid operation payload", state)
        var next = _graphql_reply(
            "next", id_json,
            '{"data": {"query": ' + json_serialize(payload.values["query"]) + '}}',
        )
        var complete = '{"type": "complete", "id": ' + id_json + '}'
        return (2, next + "\n" + complete, state)

    return (-1, "unsupported GraphQL WS message", state)


def run_ws_protocol(protocol: String, msg: String, state: Int) raises -> Tuple[Int, String, Int]:
    """Dispatch one application-level WebSocket protocol message (FFI-free)."""
    if protocol == "jsonrpc":
        return _jsonrpc_message(msg, state)
    if protocol == "graphql-ws":
        return _graphql_message(msg, state)
    return (0, "", state)


def main() raises:
    var echo = run_ws_protocol(
        "jsonrpc", '{"jsonrpc":"2.0","id":7,"method":"echo","params":{"text":"hi"}}', 0)
    assert echo[0] == 1
    assert echo[1] == '{"jsonrpc": "2.0", "id": 7, "result": {"text":"hi"}}'

    var notify = run_ws_protocol(
        "jsonrpc", '{"jsonrpc":"2.0","method":"ping"}', 3)
    assert notify[0] == 0 and notify[2] == 3

    var bad = run_ws_protocol("jsonrpc", "{oops", 0)
    assert bad[0] == 1 and bad[1].find("-32700") >= 0

    var gql = run_ws_protocol(
        "graphql-ws",
        '{"type":"subscribe","id":"op1","payload":{"query":"{ hello }"}}', 0)
    assert gql[0] == 2
    assert gql[1].find('"type": "next"') >= 0 and gql[1].find('"type": "complete"') >= 0

    print("Mojo ws_protocols test completed!")
