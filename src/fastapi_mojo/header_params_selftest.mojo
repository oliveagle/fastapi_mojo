# src/fastapi_mojo/header_params_selftest.mojo
#
# 决策-53 (ADR-0028): header_params 纯逻辑自检 (mojo run — JIT 可达:
# main 只调纯函数, 不触 FFI 闭包; ws_directives_selftest /
# openapi_custom_selftest 同模式). 覆盖:
#   header_wire_name (P25-1/4 全向量) / parse_header_entry (name /
#   alias / n=n 字面) / check_header_specs (合法通过 + 畸形 raise ×6).

import std.os

from header_params import (header_wire_name, parse_header_entry,
                           check_header_specs)
from router import Router
from handler import Handler, KIND_ECHO


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing header_params (决策-53, ADR-0028)...")

    # ---------- header_wire_name (P25-1/4) ----------
    check(header_wire_name("x_token") == "x-token", "wire x_token")
    check(header_wire_name("x__token") == "x--token", "wire x__token 双下划线")
    check(header_wire_name("a_b_c") == "a-b-c", "wire a_b_c")
    check(header_wire_name("X-Custom") == "X-Custom", "wire 无下划线不变")
    check(header_wire_name("User-Agent") == "User-Agent", "wire User-Agent 不变")
    check(header_wire_name("A") == "A", "wire 单字符")
    check(header_wire_name("_lead") == "-lead", "wire 前导下划线")
    check(header_wire_name("trail_") == "trail-", "wire 尾下划线")

    # ---------- parse_header_entry ----------
    var p1 = parse_header_entry("x_token")
    check(p1[0] == "x_token" and p1[1] == "x-token", "entry 无 = 转换")
    var p2 = parse_header_entry("custom=X-Custom-Thing")
    check(p2[0] == "custom" and p2[1] == "X-Custom-Thing", "entry alias 原样")
    var p3 = parse_header_entry("v=my_header")
    check(p3[0] == "v" and p3[1] == "my_header", "entry alias 含 _ 不转换 (P25-3)")
    var p4 = parse_header_entry("x_token=x_token")
    check(p4[0] == "x_token" and p4[1] == "x_token", "entry n=n 字面 (convert_underscores=False)")
    var p5 = parse_header_entry("User-Agent")
    check(p5[0] == "User-Agent" and p5[1] == "User-Agent", "entry hyphen-only 不变")

    # ---------- check_header_specs: 合法路由通过 ----------
    var r = Router()
    var ok1 = Handler(KIND_ECHO(), "ok1")
    ok1.set_data("_reads_headers", "X-Custom,User-Agent")
    r.add_route("/a", "GET", ok1)
    var ok2 = Handler(KIND_ECHO(), "ok2")
    ok2.set_data("_reads_headers", "x_token=Token-Literal,client_id")
    r.add_route("/b", "GET", ok2)
    var ok3 = Handler(KIND_ECHO(), "ok3")
    ok3.set_data("_reads_headers", "")
    r.add_route("/c", "GET", ok3)
    var ok4 = Handler(KIND_ECHO(), "ok4")
    ok4.set_data("_reads_headers", "a=b, ,c=d")
    r.add_route("/d", "GET", ok4)
    check_header_specs(r)  # 不应 raise
    check(True, "合法 spec 通过")

    # ---------- check_header_specs: 畸形 raise ----------
    var raised1 = False
    var bad1 = Router()
    var b1 = Handler(KIND_ECHO(), "b1")
    b1.set_data("_reads_headers", "a=b=c")
    bad1.add_route("/x1", "GET", b1)
    try:
        check_header_specs(bad1)
    except:
        raised1 = True
    check(raised1, "bad 双 = raise")

    var raised2 = False
    var bad2 = Router()
    var b2 = Handler(KIND_ECHO(), "b2")
    b2.set_data("_reads_headers", "=alias")
    bad2.add_route("/x2", "GET", b2)
    try:
        check_header_specs(bad2)
    except:
        raised2 = True
    check(raised2, "bad 空 name raise")

    var raised3 = False
    var bad3 = Router()
    var b3 = Handler(KIND_ECHO(), "b3")
    b3.set_data("_reads_headers", "name=")
    bad3.add_route("/x3", "GET", b3)
    try:
        check_header_specs(bad3)
    except:
        raised3 = True
    check(raised3, "bad 空 alias raise")

    var raised4 = False
    var bad4 = Router()
    var b4 = Handler(KIND_ECHO(), "b4")
    b4.set_data("_reads_headers", "bad name")
    bad4.add_route("/x4", "GET", b4)
    try:
        check_header_specs(bad4)
    except:
        raised4 = True
    check(raised4, "bad 空格 name raise")

    var raised5 = False
    var bad5 = Router()
    var b5 = Handler(KIND_ECHO(), "b5")
    b5.set_data("_reads_headers", "ok=x bad y")
    bad5.add_route("/x5", "GET", b5)
    try:
        check_header_specs(bad5)
    except:
        raised5 = True
    check(raised5, "bad 空格 alias raise")

    var raised6 = False
    var bad6 = Router()
    var b6 = Handler(KIND_ECHO(), "b6")
    b6.set_data("_reads_headers", "a=b;")
    bad6.add_route("/x6", "GET", b6)
    # ";" 非条目分隔 (仅 ',' 切) — "b;" 含 ';' 仍属可打印, 合法!
    # 换用真正畸形: 控制字符 0x01
    b6.set_data("_reads_headers", "a=bc")
    bad6.add_route("/x6b", "GET", b6)
    try:
        check_header_specs(bad6)
    except:
        raised6 = True
    check(raised6, "bad 控制字符 raise")

    print("all header_params checks passed")
