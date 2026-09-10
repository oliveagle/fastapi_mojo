# src/fastapi_mojo/ws_directives_selftest.mojo
#
# 决策-51 (ADR-0026): ws_directives 纯逻辑自检 (mojo run — JIT 可达:
# main 只调纯函数, 不触 run_ws_message FFI 闭包; request_state_selftest
# 同模式).

import std.os

from ws_directives import ws_parse_code, ws_code_valid, ws_close_spec


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing WS directives (决策-51, ADR-0026)...")

    # ---------- ws_parse_code ----------
    check(ws_parse_code("1000") == 1000, "parse 1000")
    check(ws_parse_code("4001") == 4001, "parse 4001")
    check(ws_parse_code("7") == 7, "parse single digit")
    check(ws_parse_code("0") == 0, "parse 0")
    check(ws_parse_code("") == -1, "parse empty -> -1")
    check(ws_parse_code("abc") == -1, "parse letters -> -1")
    check(ws_parse_code("12a4") == -1, "parse mixed -> -1")
    check(ws_parse_code("999999999") == -1, "parse >5 digits -> -1")

    # ---------- ws_code_valid ----------
    check(ws_code_valid(1000) and ws_code_valid(1001)
          and ws_code_valid(1002) and ws_code_valid(1003), "valid 1000-1003")
    check(ws_code_valid(1007) and ws_code_valid(1008) and ws_code_valid(1015),
          "valid 1007-1015")
    check(ws_code_valid(3000) and ws_code_valid(4000) and ws_code_valid(4999),
          "valid 3000-4999")
    check(not ws_code_valid(1004) and not ws_code_valid(1005)
          and not ws_code_valid(1006), "local-only 1004/1005/1006 rejected")
    check(not ws_code_valid(999) and not ws_code_valid(1016)
          and not ws_code_valid(2000) and not ws_code_valid(5000)
          and not ws_code_valid(0) and not ws_code_valid(-1),
          "out-of-range rejected")

    # ---------- ws_close_spec ----------
    var s = ws_close_spec("1000")
    check(s[0] and s[1] == 1000 and s[2] == "", "1000 no reason")
    s = ws_close_spec("1000:bye")
    check(s[0] and s[1] == 1000 and s[2] == "bye", "1000:bye")
    s = ws_close_spec("4001:custom reason")
    check(s[0] and s[1] == 4001 and s[2] == "custom reason", "4001:custom reason")
    s = ws_close_spec("1001:")
    check(s[0] and s[1] == 1001 and s[2] == "", "1001: empty reason ok")
    s = ws_close_spec("1002:a:b")
    check(s[0] and s[1] == 1002 and s[2] == "a:b", "reason keeps colons")
    s = ws_close_spec("3000:policy")
    check(s[0] and s[1] == 3000 and s[2] == "policy", "3000:policy")
    s = ws_close_spec("4999")
    check(s[0] and s[1] == 4999 and s[2] == "", "4999 boundary")
    # reason-without-code = 错误 (wsproto 发送侧 TypeError parity)
    check(not ws_close_spec(":nope")[0], "reason-without-code rejected")
    # local-only / 越界
    check(not ws_close_spec("1004:x")[0], "1004 rejected")
    check(not ws_close_spec("1005")[0], "1005 rejected")
    check(not ws_close_spec("1006:x")[0], "1006 rejected")
    check(not ws_close_spec("999")[0], "999 rejected")
    check(not ws_close_spec("1016")[0], "1016 rejected")
    check(not ws_close_spec("2000")[0], "2000 rejected")
    check(not ws_close_spec("5000")[0], "5000 rejected")
    check(not ws_close_spec("abc")[0], "letters rejected")
    check(not ws_close_spec("")[0], "empty rejected")
    check(not ws_close_spec("12345")[0], "12345 rejected (>4999)")

    print("all ws_directives checks passed")
