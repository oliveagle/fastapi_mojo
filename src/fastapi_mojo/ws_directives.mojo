# src/fastapi_mojo/ws_directives.mojo
#
# 决策-51 (ADR-0026, Goal-0003 矩阵 #23): WebSocket 精化 —
# close(code, reason) / exception_handler / send_bytes / send_json.
#
# 上游 (uvicorn 0.52.4 wsproto 1.3.2 + starlette 1.6.0, /tmp/exch_probe
# p23/p23h/p23i 活体 probe + 源码核对, ADR-0026 §1):
#   - close(code, reason) → close 帧 + 10s close-wait (wsproto_impl
#     硬编码); close-wait 期间: close 回显 → 立即关, 数据/ping → 丢弃,
#     超时 → 静默关
#   - 未处理异常 → 无 close 帧, TCP 关 (客户端 1006)
#   - WebSocketException(code, reason) → wire 行为 = close
#   - send_bytes → BINARY 帧; send_json → compact JSON TEXT 帧
#     (json.dumps separators=(",",":"), ensure_ascii=False)
# 声明式映射 (本仓库范式, ADR-0004; 决策-49 _exception_raise /
# 决策-50 _state_set 同款「路由 data 承载意图」):
#   _ws_close     = "CODE[:REASON]" — 正常回复后发 close + close-wait (P23-1)
#   _ws_no_reply  = "1"             — 抑制正常回复 (正交; 与 _ws_close 组合
#                                     = 无回复直接 close, P23-2)
#   _ws_exc_close = "CODE[:REASON]" — 无回复; 日志; close + close-wait (P23-4)
#   _ws_raise     = "msg"           — 无回复; 日志; TCP close 无 close 帧 (P23-3)
#   _ws_binary    = "1"             — 回复改 BINARY 帧 (P23-5; 正交)
#   _ws_json      = "<JSON 文本>"   — 回复 = 该模板 TEXT 帧原样发送 (P23-6)
# 优先级 (每消息): _ws_raise > _ws_exc_close > _ws_close (前两 pre-reply);
# _ws_no_reply / _ws_binary / _ws_json 修饰回复。run_ws_message 签名不变,
# 指令处理全在 handle_ws_data (ADR-0007 单点扩展点)。
# close code 合法集 = {1000,1001,1002,1003,1007..1015} ∪ [3000,4999]
# (wsproto 接收侧合法集; 1004/1005/1006 = RFC local-only, MUST NOT 置入
# close 帧 — 注册期拒绝; reason-without-code = 错误 — wsproto 发送侧
# TypeError parity)。
# 本模块 = 纯解析/校验 (JIT 可达, 零 FFI); close-wait 状态机 = bridge
# phase 5 (ADR-0026 §3.2)。

from handler import Handler
from router import Router


def ws_parse_code(s: String) -> Int:
    """全数字串 → Int; 空 / 非数字 / >5 位 → -1."""
    var n = s.byte_length()
    if n == 0 or n > 5:
        return -1
    var v = 0
    var i = 0
    while i < n:
        var d = ord(s[byte=i])
        if d < 48 or d > 57:
            return -1
        v = v * 10 + (d - 48)
        i += 1
    return v


def ws_code_valid(code: Int) -> Bool:
    """close code 合法集 (wsproto 1.3.2 接收侧; ADR-0026 §3.1):
    {1000,1001,1002,1003,1007..1015} ∪ [3000,4999]。
    1004/1005/1006 = RFC local-only (MUST NOT 置入 close 帧) → 拒绝。"""
    if code == 1000 or code == 1001 or code == 1002 or code == 1003:
        return True
    if code >= 1007 and code <= 1015:
        return True
    if code >= 3000 and code <= 4999:
        return True
    return False


def ws_close_spec(spec: String) -> Tuple[Bool, Int, String]:
    """解析 "CODE" / "CODE:REASON" → (ok, code, reason).
    - 无 ':' → 仅 code, reason = ""
    - 首个 ':' 切分 (reason 可再含 ':')
    - reason-without-code (":msg") → (False,0,"") (wsproto 发送侧
      TypeError parity)
    - code 非数字 / 越界 → (False,0,"")"""
    var n = spec.byte_length()
    var ci = -1
    var i = 0
    while i < n:
        if ord(spec[byte=i]) == 58:
            ci = i
            break
        i += 1
    var code_str = spec  # 无 ':' → 整串 = code
    var reason = ""
    if ci >= 0:
        if ci == 0:
            return (False, 0, "")
        code_str = String(spec[byte=0:ci])
        if n > ci + 1:
            reason = String(spec[byte=ci + 1:n])
    var code = ws_parse_code(code_str)
    if code < 0 or not ws_code_valid(code):
        return (False, 0, "")
    return (True, code, reason)


def check_ws_specs(router: Router) raises:
    """注册期 `_ws_*` 指令语法检查 (决策-51): 畸形 spec 启动即 fail,
    不带入请求路径 (check_state_specs / check_body_schemas 同策略)。
    空值 = 未使用 (跳过); 非空 = 必须合法。"""
    var n = router.ws_route_count()
    var i = 0
    while i < n:
        var h = router.ws_routes[i].handler.copy()
        if "_ws_close" in h.data and h.data["_ws_close"] != "":
            if not ws_close_spec(h.data["_ws_close"])[0]:
                raise Error("ws_directives: bad _ws_close spec in "
                            + h.name + ": " + h.data["_ws_close"])
        if "_ws_exc_close" in h.data and h.data["_ws_exc_close"] != "":
            if not ws_close_spec(h.data["_ws_exc_close"])[0]:
                raise Error("ws_directives: bad _ws_exc_close spec in "
                            + h.name + ": " + h.data["_ws_exc_close"])
        if "_ws_raise" in h.data and h.data["_ws_raise"] == "":
            raise Error("ws_directives: empty _ws_raise in " + h.name)
        if "_ws_no_reply" in h.data and h.data["_ws_no_reply"] != "1" \
                and h.data["_ws_no_reply"] != "":
            raise Error("ws_directives: bad _ws_no_reply (need \"1\") in "
                        + h.name + ": " + h.data["_ws_no_reply"])
        if "_ws_binary" in h.data and h.data["_ws_binary"] != "1" \
                and h.data["_ws_binary"] != "":
            raise Error("ws_directives: bad _ws_binary (need \"1\") in "
                        + h.name + ": " + h.data["_ws_binary"])
        i += 1
