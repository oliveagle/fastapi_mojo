# src/fastapi_mojo/ws_session.mojo
#
# WebSocket 会话管理 (ADR-0008: poll 循环驱动)
#
# 架构: WS 连接的 I/O 由 bridge 的 poll 循环接管 (与 HTTP 并发, 不阻塞
# dispatch): 帧解析/控制帧 (ping->pong, close 码校验)/保活 ping/UTF-8 校验
# 全部在 C 协议层自动处理 (纯协议, 无业务); Mojo 只做两件事:
#   * run_ws_upgrade — 升级时: 子协议协商 (缺失必需 -> 400) + 101 握手 +
#     连接移交 (ws_conn_upgrade); 此后该连接归 bridge 驱动
#   * handle_ws_data — 每收到一条数据帧事件 (ws_event_type == 1) 处理一条:
#     echo 零拷贝原样回显 / 其余 handler 经 run_ws_message 单点 dispatch
# 会话结束 (close/EOF/保活耗尽) 由 bridge 入队事件 (ws_event_type == 2),
# 主循环清理连接级状态 (fd -> state map)。
#
# FFI 约定见 ADR-0007 §5 (NUL 结尾 / 无符号状态码 / 结构参数位置)。

from std.ffi import external_call, CStringSlice
from handler import Handler, run_ws_message, KIND_WS_ECHO
from params_query import parse_query_params
from string_builder import span_to_str, trim_spaces


def ws_select_subprotocol(required: String, offer: String) -> Tuple[Bool, String]:
    """(ok, selected)。required == "" -> 无子协议 (总 ok)。
    否则 offer (逗号分隔, 允许空白) 必须包含 required, 选中它; 不包含 -> 400。"""
    if required == "":
        return (True, "")
    if offer == "":
        return (False, "")
    var parts = offer.split(",")
    for i in range(len(parts)):
        var part = String(parts[i])
        if trim_spaces(part) == required:
            return (True, required)
    return (False, "")


def ws_check_token(handler: Handler, query: String) raises -> Bool:
    """WS 鉴权 (ADR-0009): handler 声明 ws_token 时, 升级请求 query 必须带
    token=<ws_token>; 未声明 ws_token 的路由恒通过。纯函数, 可单测。"""
    if "ws_token" not in handler.data:
        return True
    var tok = ""
    if query != "":
        var qp = parse_query_params(query)
        if "token" in qp.values:
            tok = qp.values["token"]
    return tok == handler.data["ws_token"]


def run_ws_upgrade(cfd: Int, handler: Handler) raises -> Int:
    """101 升级 + 连接移交。返回:
    101 = 移交成功 (连接已是 WS 会话, 调用方**不得** conn_done);
    400 = 必需子协议未提供 (已响应); 403 = 鉴权失败 (已响应, ADR-0009);
    500 = 握手失败 (已无会话)。
    非 101 时调用方负责 conn_done(cfd, False)。"""
    var required = ""
    if "ws_sp" in handler.data:
        required = handler.data["ws_sp"]
    var offer = span_to_str(
        external_call["get_ws_protocol_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
    var sel = ws_select_subprotocol(required, offer)
    if not sel[0]:
        var body = "{\"error\": \"required subprotocol not offered\", \"status\": \"400\"}"
        _ = external_call["send_simple_response", Int](
            cfd, "400 Bad Request".as_c_string_slice(), body.as_c_string_slice())
        return 400
    # 鉴权 (ADR-0009): 升级请求 query 中的 token 校验 (101 之前)
    var query = span_to_str(
        external_call["get_query_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
    if not ws_check_token(handler, query):
        var body = "{\"error\": \"invalid or missing token\", \"status\": \"403\"}"
        _ = external_call["send_simple_response", Int](
            cfd, "403 Forbidden".as_c_string_slice(), body.as_c_string_slice())
        return 403
    if external_call["ws_session_begin", Int](sel[1].as_c_string_slice()) != 0:
        return 500  # 客户端在握手期间已走: 无会话可移交
    external_call["ws_conn_upgrade", NoneType](cfd)  # 移交: phase 3, 保存 path
    return 101


def handle_ws_data(cfd: Int, handler: Handler, params: Dict[String, String],
                   opcode: Int, state: Int) raises -> Int:
    """处理一条数据帧 (opcode 1=text / 2=binary; 控制帧在 C 层已自动处理)。
    返回新的连接级 state。调用方负责随后 ws_message_done(cfd)。
    text: echo 零拷贝回显 (NUL 安全); 其余 handler 解码后 run_ws_message 分派
    (params = 路由 {param} 参数, ADR-0009)。
    binary: echo 零拷贝回显; 其余 (text-only) handler -> close 1003 并结束。"""
    if handler.kind == KIND_WS_ECHO():
        _ = external_call["ws_write_current", Int](cfd, opcode)  # 原样回显, 零拷贝
        return state
    if opcode == 2:
        _ = external_call["ws_send_close", Int](cfd, 1003)  # unsupported data type
        external_call["ws_conn_close", NoneType](cfd)
        return state
    var msg = span_to_str(
        external_call["ws_payload_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
    var r = run_ws_message(handler, opcode, msg, state, params)
    if r[0] > 0 and r[1] != "":
        _ = external_call["ws_write_text", Int](cfd, r[1].as_c_string_slice())
    return r[2]
