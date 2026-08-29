# src/fastapi_mojo/ws_session.mojo
#
# WebSocket 会话循环 (ADR-0007): Mojo 驱动 RFC 6455 会话, 协议原语由
# ws.c / http_bridge_final.c 提供 (显式 FFI, 无隐式回调 — ADR-0006 §3.5 约束)。
#
#   * 子协议协商: 路由声明 ws_sp 而客户端未提供 -> 400 (RFC 6455 §4.1);
#     否则 101 回显选中的子协议
#   * 保活: 空闲超时 (ws_session_read == -2, 流未消耗) -> 发 ping,
#     连续 ping_max 次 (FASTAPI_MOJO_WS_PING_MAX, 默认 3) 无响应 -> close 1000;
#     ping_max = 0 -> 首次空闲超时即 close 1000
#   * 控制帧: ping -> pong (同载荷); pong -> 忽略 (活性证明, 重置保活计数);
#     close -> close (码校验: 合法回显, 空按 1000, 非法按 1002, RFC 6455 §7.4.1)
#   * text: UTF-8 校验 (非法 -> close 1007, RFC 6455 §5.6);
#     KIND_WS_ECHO 零拷贝原样回显; 其余 handler 经 run_ws_message 分派
#   * binary: KIND_WS_ECHO 零拷贝原样回显; 其余 handler -> close 1003

from std.ffi import external_call, CStringSlice
from handler import Handler, run_ws_message, KIND_WS_ECHO
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


def run_ws_session(cfd: Int, handler: Handler) raises -> Int:
    """在 cfd 上运行完整 WS 会话。返回日志状态码 (101/400/500)。
    会话总是结束连接 (无 keep-alive 复用); 调用方负责 conn_done(cfd, False)。"""
    # --- 子协议协商 (101 之前) ---
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

    # --- 101 握手 (key 由 is_ws_upgrade 提取; 子协议为 Mojo 选中值) ---
    if external_call["ws_session_begin", Int](sel[1].as_c_string_slice()) != 0:
        return 500  # 握手发送失败 (客户端已走): 无会话可继续

    var ping_max = external_call["get_ws_ping_max", Int]()
    var strikes = 0
    var state = 0
    for _ in range(1000000):  # 安全阀: 单会话帧数上限
        var rc = external_call["ws_session_read", Int](cfd)
        # unsigned 状态码 (C int 返回经 Mojo i64 零扩展, 不能用负数):
        # 0 = ok, 1 = 错误/EOF (结束), 2 = 空闲超时且流未消耗 (可 ping 重试)
        if rc == 2:
            strikes += 1
            if strikes > ping_max:
                _ = external_call["ws_send_close", Int](cfd, 1000)
                break
            _ = external_call["ws_write_empty", Int](cfd, 9)
            continue
        if rc == 1:
            break  # EOF / 错误 / 超限 / 帧中途超时: 结束会话
        strikes = 0  # 任何数据 (含 pong) 都是活性证明
        var op = external_call["ws_last_opcode", Int]()
        if op == 8:  # close: 回 close (合法回显 code+reason / 空按 1000 / 非法按 1002), 结束
            _ = external_call["ws_reply_close", Int](cfd)
            break
        elif op == 9:  # ping -> pong (同载荷, 零拷贝)
            _ = external_call["ws_write_current", Int](cfd, 10)
        elif op == 10:  # pong -> 忽略
            continue
        elif op == 1:  # text
            if external_call["ws_payload_valid_utf8", Int]() != 1:
                _ = external_call["ws_send_close", Int](cfd, 1007)  # invalid UTF-8
                break
            if handler.kind == KIND_WS_ECHO():
                _ = external_call["ws_write_current", Int](cfd, 1)  # 原样回显, 零拷贝
            else:
                var msg = span_to_str(
                    external_call["ws_payload_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
                var r = run_ws_message(handler, op, msg, state)
                state = r[2]
                if r[0] > 0 and r[1] != "":
                    _ = external_call["ws_write_text", Int](cfd, r[1].as_c_string_slice())
        elif op == 2:  # binary
            if handler.kind == KIND_WS_ECHO():
                _ = external_call["ws_write_current", Int](cfd, 2)  # 原样回显, 零拷贝
            else:
                _ = external_call["ws_send_close", Int](cfd, 1003)  # unsupported data type
                break

    external_call["ws_session_end", NoneType]()
    return 101
