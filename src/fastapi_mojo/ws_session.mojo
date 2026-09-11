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
# ADR-0026 (决策-51): handle_ws_data 承载声明式 WS 指令
# (_ws_raise/_ws_exc_close/_ws_close/_ws_no_reply/_ws_binary/_ws_json,
# 解析/校验 = ws_directives.mojo 纯函数; close-wait 状态机 = bridge
# phase 5)。

from std.ffi import external_call, CStringSlice
from handler import Handler, run_ws_message, KIND_WS_ECHO
from params_query import parse_query_params
from string_builder import span_to_str, trim_spaces
from ws_directives import ws_close_spec
from ws_protocols import run_ws_protocol


def ws_select_subprotocol(required: String, offer: String) -> Tuple[Bool, String]:
    """(ok, selected)。required == "" -> 无子协议 (总 ok)。

    Decision-60: required 支持逗号分隔的 server-preferred 候选列表；
    offer 仍是客户端偏好顺序。服务端按自身优先级选择第一个交集，
    这是 WebSocket 子协议协商的合法行为。单候选（如 chat）保持既有语义。
    """
    if required == "":
        return (True, "")
    if offer == "":
        return (False, "")
    var wanted = required.split(",")
    var offered = offer.split(",")
    for i in range(len(wanted)):
        var candidate = trim_spaces(String(wanted[i]))
        if candidate == "":
            continue
        for j in range(len(offered)):
            if trim_spaces(String(offered[j])) == candidate:
                return (True, candidate)
    return (False, "")


def ws_check_token(handler: Handler, query: String) raises -> Bool:
    """WS 鉴权 (ADR-0009): handler 声明 ws_token 时, 升级请求 query 必须带
    token=<ws_token>; 未声明 ws_token 的路由恒通过。纯函数, 可单测."""
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
    400 = 必需子协议未提供 / permessage-deflate required 未提供 (已响应);
    403 = 鉴权失败 (已响应, ADR-0009);
    500 = 握手失败 (已无会话)。
    非 101 时调用方负责 conn_done(cfd, False)."""
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
    var ws_rc = external_call["ws_session_begin", Int](sel[1].as_c_string_slice())
    if ws_rc == 2:
        var deflate_body = "{\"error\": \"permessage-deflate required but not offered\", \"status\": \"400\"}"
        _ = external_call["send_simple_response", Int](
            cfd, "400 Bad Request".as_c_string_slice(), deflate_body.as_c_string_slice())
        return 400
    if ws_rc != 0:
        return 500  # 客户端在握手期间已走: 无会话可移交
    external_call["ws_conn_upgrade", NoneType](cfd)  # 移交: phase 3, 保存 path
    return 101


def _ws_send_close(cfd: Int, spec: String) raises:
    """按 spec 发 close 帧 (code, reason) + 进 close-wait (bridge phase 5);
    ADR-0026。畸形 spec 回退 1002 (注册期已校验, 不应到达)。"""
    var s = ws_close_spec(spec)
    if s[0]:
        _ = external_call["ws_send_close_reason", Int](cfd, s[1], s[2].as_c_string_slice())
    else:
        _ = external_call["ws_send_close", Int](cfd, 1002)
    _ = external_call["ws_set_closing", Int](cfd)


def handle_ws_data(cfd: Int, handler: Handler, params: Dict[String, String],
                   opcode: Int, state: Int) raises -> Int:
    """处理一条数据帧 (opcode 1=text / 2=binary; 控制帧在 C 层已自动处理)。
    返回新的连接级 state。调用方负责随后 ws_message_done(cfd)。
    text: echo 零拷贝回显 (NUL 安全); 其余 handler 解码后 run_ws_message 分派
    (params = 路由 {param} 参数, ADR-0009)。
    binary: echo 零拷贝回显; 其余 (text-only) handler -> close 1003 并结束.

    ADR-0026 (决策-51) 声明式指令 — 优先级 _ws_raise > _ws_exc_close >
    _ws_close (前两 pre-reply, 后一 post-reply); _ws_no_reply/_ws_binary/
    _ws_json 修饰回复:
      _ws_raise=msg       → 无回复; log [ws-exc]; TCP close **无 close 帧**
                             (客户端 1006, P23-3 parity)
      _ws_exc_close=SPEC  → 无回复; log [ws-exc]; close 帧 + close-wait
                             (WebSocketException parity, P23-4)
      _ws_close=SPEC      → 正常回复后 close 帧 + close-wait (P23-1)
      _ws_no_reply=1      → 抑制正常回复 (与 _ws_close 组合 = P23-2 无回复 close)
      _ws_binary=1        → 回复改 BINARY 帧 (P23-5; echo 路径零拷贝)
      _ws_json=<文本>     → 回复 = JSON 模板原样 TEXT 帧 (P23-6; echo 路径替代回显)"""
    # --- 优先级 1: _ws_raise — 无回复, 无 close 帧 (P23-3: 1006) ---
    if "_ws_raise" in handler.data:
        print("[ws-exc] " + handler.name + ": " + handler.data["_ws_raise"])
        external_call["ws_conn_close", NoneType](cfd)
        return state
    # --- 优先级 2: _ws_exc_close — 无回复, close 帧 + close-wait (P23-4) ---
    if "_ws_exc_close" in handler.data:
        print("[ws-exc] " + handler.name + ": " + handler.data["_ws_exc_close"])
        _ws_send_close(cfd, handler.data["_ws_exc_close"])
        return state
    var no_reply = "_ws_no_reply" in handler.data and handler.data["_ws_no_reply"] == "1"
    var binary = "_ws_binary" in handler.data and handler.data["_ws_binary"] == "1"

    # Decision-60: application subprotocol adapters run before generic echo.
    # grpc-web is binary-only and transparent at this layer (NUL-safe echo);
    # JSON protocols use the FFI-free pure functions in ws_protocols.mojo.
    if "_ws_protocol" in handler.data:
        var protocol = handler.data["_ws_protocol"]
        if protocol == "grpc-web":
            if opcode == 2 and not no_reply:
                _ = external_call["ws_write_current_binary", Int](cfd)
            elif opcode != 2:
                _ = external_call["ws_send_close", Int](cfd, 1003)
                external_call["ws_conn_close", NoneType](cfd)
            return state
        if opcode == 2:
            _ = external_call["ws_send_close", Int](cfd, 1003)
            external_call["ws_conn_close", NoneType](cfd)
            return state
        var msg = span_to_str(
            external_call["ws_payload_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
        var protocol_reply = run_ws_protocol(protocol, msg, state)
        if protocol_reply[0] == -1:
            _ws_send_close(cfd, "4400:" + protocol_reply[1])
            return state
        if protocol_reply[0] > 0 and not no_reply:
            var replies = protocol_reply[1].split("\n")
            for i in range(len(replies)):
                var item = String(replies[i])
                if item != "":
                    _ = external_call["ws_write_text", Int](cfd, item.as_c_string_slice())
        return protocol_reply[2]

    if handler.kind == KIND_WS_ECHO():
        var json_spec = ""
        if "_ws_json" in handler.data:
            json_spec = handler.data["_ws_json"]
        if json_spec != "" and not no_reply:
            _ = external_call["ws_write_text", Int](cfd, json_spec.as_c_string_slice())
        elif binary:
            _ = external_call["ws_write_current_binary", Int](cfd)  # 零拷贝 BINARY
        elif not no_reply:
            _ = external_call["ws_write_current", Int](cfd, opcode)  # 原样回显
        if "_ws_close" in handler.data:
            _ws_send_close(cfd, handler.data["_ws_close"])
        return state
    if opcode == 2:
        _ = external_call["ws_send_close", Int](cfd, 1003)  # unsupported data type
        external_call["ws_conn_close", NoneType](cfd)
        return state
    var msg = span_to_str(
        external_call["ws_payload_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
    var r = run_ws_message(handler, opcode, msg, state, params)
    if r[0] > 0 and r[1] != "" and not no_reply:
        var rep = r[1]
        if "_ws_json" in handler.data and handler.data["_ws_json"] != "":
            rep = handler.data["_ws_json"]
        if binary:
            _ = external_call["ws_write_binary", Int](cfd, rep.as_c_string_slice())
        else:
            _ = external_call["ws_write_text", Int](cfd, rep.as_c_string_slice())
    # --- 优先级 3: _ws_close — 正常回复后 close + close-wait (P23-1/2) ---
    if "_ws_close" in handler.data:
        _ws_send_close(cfd, handler.data["_ws_close"])
    return r[2]
