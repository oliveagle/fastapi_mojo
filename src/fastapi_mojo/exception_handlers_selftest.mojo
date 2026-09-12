# src/fastapi_mojo/exception_handlers_selftest.mojo
#
# 决策-49 (ADR-0024): exception_handlers 纯逻辑自检 (mojo run — JIT 可达:
# main 只调纯函数, 不触 run_handler FFI 闭包, 同 file_params_selftest 模式).
# 覆盖: _split_exc_msg / _parse_entry / _entry_fields / parse_exc_table
# (后者胜) / _substitute ({exc}/{tag}) / resolve_exception_response
# (精确/catch-all/默认 500/json 转义/路由覆盖/env 表).

import std.os

from exception_handlers import (_split_exc_msg, _parse_entry,
                                _entry_fields, parse_exc_table,
                                _substitute, resolve_exception_response,
                                parse_exc_headers)
from handler import Handler


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing exception handlers (决策-49, ADR-0024)...")

    # ---------- _split_exc_msg ----------
    var (t1, m1) = _split_exc_msg("ValueError: bad value")
    check(t1 == "ValueError" and m1 == "bad value", "split basic")
    var (t2, m2) = _split_exc_msg("no colon here")
    check(t2 == "" and m2 == "no colon here", "split no colon")
    var (t3, m3) = _split_exc_msg("oops: a:b")
    check(t3 == "oops" and m3 == "a:b", "split first colon, msg keeps colons")
    var (t4, m4) = _split_exc_msg(":leading colon")
    check(t4 == "" and m4 == "leading colon", "split empty tag")

    # ---------- _parse_entry / _entry_fields ----------
    check(_parse_entry("ValueError:418:oops {exc}"), "entry basic valid")
    var f1 = _entry_fields("ValueError:418:oops {exc}")
    check(f1[0] == 418 and f1[1] == "oops {exc}" and not f1[2],
          "entry fields basic")
    check(_parse_entry("J:422:{\"detail\":\"bad {exc}\"}:json"),
          "entry json valid")
    var f2 = _entry_fields("J:422:{\"detail\":\"bad {exc}\"}:json")
    check(f2[0] == 422 and f2[1] == "{\"detail\":\"bad {exc}\"}" and f2[2],
          "entry fields json")
    check(not _parse_entry("Bad"), "entry no colon rejected")
    check(not _parse_entry("T:41:short status"), "entry 2-digit status rejected")
    check(not _parse_entry("T:4a8:body"), "entry non-digit status rejected")
    check(not _parse_entry(":418:empty tag"), "entry empty tag rejected")
    check(not _parse_entry("T:418:"), "entry empty body rejected")
    check(not _parse_entry("T:418::json"), "entry body-exactly-:json rejected")
    check(_parse_entry("T:503:body with: colons"), "entry colons-in-body valid")
    var f8 = _entry_fields("T:503:body with: colons")
    check(f8[1] == "body with: colons", "entry fields body keeps colons")

    # ---------- parse_exc_table (tag -> 原条目串) ----------
    check(len(parse_exc_table("")) == 0, "table empty")
    var tb2 = parse_exc_table("A:400:first;B:500:second;A:404:third")
    check(len(tb2) == 2 and tb2["A"] == "A:404:third"
          and tb2["B"] == "B:500:second", "table last-wins per tag")
    var tb3 = parse_exc_table("garbage;T:418:ok")
    check(len(tb3) == 1 and tb3["T"] == "T:418:ok", "table skips bad entry")
    var tb4 = parse_exc_table("Exception:503:down {exc};ValueError:418:oops")
    check(len(tb4) == 2 and "Exception" in tb4 and "ValueError" in tb4,
          "table Exception catchall coexists")

    # ---------- _substitute ----------
    check(_substitute("oops {exc}", "ValueError", "bad") == "oops bad",
          "substitute exc")
    check(_substitute("{tag} said {exc} twice {exc}", "T", "x")
          == "T said x twice x", "substitute multi")
    check(_substitute("no placeholders", "T", "m") == "no placeholders",
          "substitute none")
    check(_substitute("{exc}{tag}{exc}", "", "m") == "mm", "substitute empty tag")

    # ---------- resolve: 路由级 _exc_handlers ----------
    var h1 = Handler(0, "t1")
    h1.set_data("_exc_handlers", "ValueError:418:oops {exc}")
    var r1 = resolve_exception_response("ValueError: boom", h1)
    check(r1.is_exc and r1.status_line == "418 I'm a Teapot"
          and r1.body == "oops boom" and not r1.is_json,
          "resolve exact match text")

    var h2 = Handler(0, "t2")
    h2.set_data("_exc_handlers", "Exception:503:server down {exc}")
    var r2 = resolve_exception_response("Mystery: no specific", h2)
    check(r2.is_exc and r2.status_line == "503 Service Unavailable"
          and r2.body == "server down no specific", "resolve catchall")


    var h4 = Handler(0, "t4")
    h4.set_data("_exc_handlers",
                "ValueError:400:v {exc};ValueError:418:second {exc}")
    var r4 = resolve_exception_response("ValueError: x", h4)
    check(r4.status_line == "418 I'm a Teapot" and r4.body == "second x",
          "resolve route table last-wins")

    var h5 = Handler(0, "t5")
    h5.set_data("_exc_handlers", "ValueError:418:route wins")
    var r5 = resolve_exception_response("ValueError: y", h5)
    check(r5.body == "route wins", "resolve route table (superset)")

    var h6 = Handler(0, "t6")
    h6.set_data("_exc_handlers", "U:422:{\"detail\":\"bad {exc}\"}:json")
    var r6 = resolve_exception_response("U: he said \"hi\"", h6)
    check(r6.is_json and r6.status_line == "422 Unprocessable Entity"
          and r6.body == "{\"detail\":\"bad he said \\\"hi\\\"\"}",
          "resolve json escape")

    var h7 = Handler(0, "t7")
    h7.set_data("_exc_handlers", "P:500:plain")
    var r7 = resolve_exception_response("plain message no colon", h7)
    check(r7.status_line == "500 Internal Server Error"
          and r7.body == "Internal Server Error",
          "resolve untagged msg -> default 500 (no tag match, no catchall)")

    # ---------- env 表 / 默认 500 (互斥: env 存在走 env catchall, 否则默认 500) ----------
    var envx = std.os.getenv("FM_XH_ENV_EXPECT")
    if envx != "":
        var h8 = Handler(0, "t8")
        var r8 = resolve_exception_response("ValueError: from-env", h8)
        check(r8.body == envx, "resolve env table exact (no _exc_handlers)")
        var h9 = Handler(0, "t9")
        var r9 = resolve_exception_response("Mystery: nothing", h9)
        check(r9.status_line == "503 Service Unavailable"
              and r9.body == "env catchall nothing",
              "resolve env table catchall")
    else:
        var h3 = Handler(0, "t3")
        var r3 = resolve_exception_response("Mystery: nothing", h3)
        check(r3.is_exc and r3.status_line == "500 Internal Server Error"
              and r3.body == "Internal Server Error" and not r3.is_json,
              "resolve default 500 (P13-10)")

    # ---------- 决策-74 (ADR-0049): parse_exc_headers ----------
    check(len(parse_exc_headers("")) == 0, "exc headers empty")
    var hp1 = parse_exc_headers("Teapot=X-Reason: tea|WWW-Authenticate: Teapot")
    check(len(hp1) == 1
          and hp1["Teapot"] == "X-Reason: tea\r\nWWW-Authenticate: Teapot",
          "exc headers multi per tag (| 分隔, \r\n 连接)")
    var hp2 = parse_exc_headers("A=One: 1;B=Two: 2;A=Three: 3")
    check(len(hp2) == 2 and hp2["A"] == "Three: 3" and hp2["B"] == "Two: 2",
          "exc headers last-wins per tag")
    var hp3 = parse_exc_headers("garbage;NoColon;=: x;Good: v")
    check(len(hp3) == 0, "exc headers skips bad entries (无 = / 空 tag / 无 ':')")

    # ---------- 决策-74: resolve_exception_response 自定义头 ----------
    var h10 = Handler(0, "t10")
    h10.set_data("_exc_handlers", "Teapot:418:{\"detail\":\"brewing\"}:json")
    h10.set_data("_exc_headers", "Teapot=X-Reason: tea|WWW-Authenticate: Teapot")
    var r10 = resolve_exception_response("Teapot: brewing", h10)
    check(r10.is_exc and r10.status_line == "418 I'm a Teapot"
          and r10.body == "{\"detail\":\"brewing\"}"
          and r10.extra == "X-Reason: tea\r\nWWW-Authenticate: Teapot",
          "resolve route _exc_headers exact tag")

    var h11 = Handler(0, "t11")
    h11.set_data("_exc_handlers", "Exception:503:down {exc}")
    h11.set_data("_exc_headers", "Exception=X-Catch: all")
    var r11 = resolve_exception_response("Mystery: x", h11)
    check(r11.extra == "X-Catch: all", "resolve _exc_headers catch-all")

    if std.os.getenv("FASTAPI_MOJO_EXCEPTION_HEADERS") == "":
        var h12 = Handler(0, "t12")
        h12.set_data("_exc_handlers", "T:418:plain")
        var r12 = resolve_exception_response("T: x", h12)
        check(r12.extra == "", "resolve no _exc_headers -> empty extra (env unset)")

    print("exception_handlers self-test: all checks passed")
