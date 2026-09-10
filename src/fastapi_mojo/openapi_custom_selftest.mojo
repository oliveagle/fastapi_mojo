# src/fastapi_mojo/openapi_custom_selftest.mojo
#
# 决策-52 (ADR-0027): openapi_custom 纯逻辑自检 (mojo run — JIT 可达:
# main 只调纯函数, 不触 run_handler FFI 闭包; ws_directives_selftest /
# request_state_selftest 同模式)。覆盖:
#   title_case (P24-5 全向量) / default_operation_id (P24-6 向量) /
#   url_host_quirk (P24-12) / info·servers·root tags·externalDocs JSON
#   键序 + 畸形省略 / parse_response_entries / primary_status_key /
#   check_openapi_specs 注册校验 (合法通过 + 畸形 raise ×6)。

import std.os

from openapi_custom import (title_case, default_summary, default_operation_id,
                            url_host_quirk, openapi_info_json,
                            openapi_servers_json, openapi_root_tags_json,
                            openapi_external_docs_json, parse_response_entries,
                            primary_status_key, check_openapi_specs)
from router import Router
from handler import Handler, KIND_ECHO


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing OpenAPI custom (决策-52, ADR-0027)...")

    # ---------- title_case (P24-5 全向量, Python str.title() 等价) ----------
    check(title_case("foo_bar") == "Foo Bar", "title foo_bar")
    check(title_case("v2api") == "V2Api", "title v2api (数字后字母大写)")
    check(title_case("apiV2") == "Apiv2", "title apiV2 (其余小写)")
    check(title_case("UPPER") == "Upper", "title UPPER")
    check(title_case("a__b") == "A  B", "title a__b (双空格保留)")
    check(title_case("x-1") == "X 1", "title x-1 (- 同 _)")
    check(title_case("a1_b2") == "A1 B2", "title a1_b2")
    check(title_case("get_foo_bar") == "Get Foo Bar", "title get_foo_bar")
    check(title_case("health") == "Health", "title health")
    check(default_summary("calc") == "Calc", "default_summary calc")

    # ---------- default_operation_id (P24-6 向量) ----------
    check(default_operation_id("foo_bar", "/x/y/{z}", "GET") == "foo_bar_x_y__z__get",
          "opid foo_bar /x/y/{z} GET")
    check(default_operation_id("another_one", "/a/{id}/b", "POST") == "another_one_a__id__b_post",
          "opid another_one /a/{id}/b POST")
    check(default_operation_id("health", "/health", "GET") == "health_health_get",
          "opid health /health")
    check(default_operation_id("calc", "/calc/{a}/{b}", "GET") == "calc_calc__a___b__get",
          "opid calc /calc/{a}/{b}")
    check(default_operation_id("meta_probe", "/meta/probe", "GET") == "meta_probe_meta_probe_get",
          "opid meta_probe")

    # ---------- url_host_quirk (P24-12: AnyUrl host-only 尾 /) ----------
    check(url_host_quirk("https://support.example") == "https://support.example/",
          "quirk host-only 加 /")
    check(url_host_quirk("https://support.example/support") == "https://support.example/support",
          "quirk 带 path 不变")
    check(url_host_quirk("https://support.example:8080") == "https://support.example:8080/",
          "quirk host:port 加 /")
    check(url_host_quirk("https://x.y/a/b") == "https://x.y/a/b", "quirk path 不变")
    check(url_host_quirk("not-a-url") == "not-a-url", "quirk 无 scheme 不变")
    check(url_host_quirk("https://host?x") == "https://host/?x", "quirk ? 前插 /")
    check(url_host_quirk("https://host#frag") == "https://host/#frag", "quirk # 前插 /")
    check(url_host_quirk("mailto:a@b.com") == "mailto:a@b.com", "quirk mailto 不变")

    # ---------- openapi_info_json (P24-1 键序 + 省略 + 畸形) ----------
    check(openapi_info_json("T", "1.0", "", "", "", "") == "{\"title\":\"T\",\"version\":\"1.0\"}",
          "info minimal 键序")
    var full = openapi_info_json("T", "9.9", "d", "tos",
                                 "n|https://c.example|e@f.g", "l|https://l.example")
    check(full == "{\"title\":\"T\",\"description\":\"d\",\"termsOfService\":\"tos\","
                  "\"contact\":{\"name\":\"n\",\"url\":\"https://c.example/\","
                  "\"email\":\"e@f.g\"},\"license\":{\"name\":\"l\",\"url\":\"https://l.example/\"},"
                  "\"version\":\"9.9\"}", "info full 键序 + url quirk")
    check(openapi_info_json("T", "1.0", "", "", "a|b", "") == "{\"title\":\"T\",\"version\":\"1.0\"}",
          "info 畸形 contact (2 段) 省略")
    check(openapi_info_json("T", "1.0", "", "", "|x|y", "") == "{\"title\":\"T\",\"version\":\"1.0\"}",
          "info 空段 contact 省略")
    check(openapi_info_json("a\"b", "1.0", "d\"e", "", "", "") ==
          "{\"title\":\"a\\\"b\",\"description\":\"d\\\"e\",\"version\":\"1.0\"}",
          "info JSON 转义")

    # ---------- openapi_servers_json (P24-3) ----------
    check(openapi_servers_json("") == "[]", "servers 空")
    check(openapi_servers_json("https://s.example/v1:Prod") ==
          "[{\"url\":\"https://s.example/v1\",\"description\":\"Prod\"}]",
          "servers url:desc")
    check(openapi_servers_json("https://s.example:8080") ==
          "[{\"url\":\"https://s.example:8080\"}]", "servers 无 desc (url 原样, 不 quirk)")
    check(openapi_servers_json("https://s.example:8080:Prod") ==
          "[{\"url\":\"https://s.example:8080\",\"description\":\"Prod\"}]",
          "servers 端口后 : 才是 desc 切分")
    check(openapi_servers_json("/v1:Prod") ==
          "[{\"url\":\"/v1\",\"description\":\"Prod\"}]", "servers 相对 url 首 : 切")
    check(openapi_servers_json("https://a.example:one;https://b.example:two") ==
          "[{\"url\":\"https://a.example\",\"description\":\"one\"},"
          "{\"url\":\"https://b.example\",\"description\":\"two\"}]", "servers 多条")
    check(openapi_servers_json(";") == "[]", "servers 空条目跳过")

    # ---------- openapi_root_tags_json (P24-2) ----------
    check(openapi_root_tags_json("") == "[]", "tags 空")
    check(openapi_root_tags_json("items:Item ops;users") ==
          "[{\"name\":\"items\",\"description\":\"Item ops\"},{\"name\":\"users\"}]",
          "tags desc 可省")
    check(openapi_root_tags_json("a:b:c") ==
          "[{\"name\":\"a\",\"description\":\"b:c\"}]", "tags 首个 : 切, desc 保 :")

    # ---------- openapi_external_docs_json (P24-10: description 先) ----------
    check(openapi_external_docs_json("https://d.example/g|Ext docs") ==
          "{\"description\":\"Ext docs\",\"url\":\"https://d.example/g\"}",
          "extdocs 键序 desc 先")
    check(openapi_external_docs_json("https://d.example") ==
          "{\"url\":\"https://d.example/\"}", "extdocs 无 desc + quirk")
    check(openapi_external_docs_json("|y") == "", "extdocs 空 url → 省略")
    check(openapi_external_docs_json("") == "", "extdocs 空 spec → 省略")

    # ---------- parse_response_entries ----------
    var entries = parse_response_entries("404:Not found;418:Teapot: extra")
    check(len(entries) == 2, "responses 2 条目")
    check(entries[0][0] == "404" and entries[0][1] == "Not found", "responses 条目 1")
    check(entries[1][0] == "418" and entries[1][1] == "Teapot: extra",
          "responses desc 保 :")
    check(len(parse_response_entries("")) == 0, "responses 空")
    check(len(parse_response_entries("404")) == 0, "responses 无冒号跳过")

    # ---------- primary_status_key ----------
    var h = Handler(KIND_ECHO(), "t")
    check(primary_status_key(h) == "200", "primary 默认 200")
    h.set_data("_status_code", "201 Created")
    check(primary_status_key(h) == "201", "primary = _status_code 前 3 位")
    var h2 = Handler(KIND_ECHO(), "t2")
    h2.set_data("_status_code", "bad")
    check(primary_status_key(h2) == "200", "primary 非法 _status_code 回落 200")

    # ---------- check_openapi_specs: 合法路由通过 ----------
    var r = Router()
    var ok1 = Handler(KIND_ECHO(), "ok1")
    ok1.set_data("_deprecated", "1")
    ok1.set_data("_include_in_schema", "0")
    ok1.set_data("_responses", "418:Teapot")
    r.add_route("/a", "GET", ok1)
    var ok2 = Handler(KIND_ECHO(), "ok2")
    ok2.set_data("_status_code", "201 Created")
    ok2.set_data("_responses", "404:Nope")
    r.add_route("/b", "GET", ok2)
    var ok3 = Handler(KIND_ECHO(), "ok3")
    ok3.set_data("_summary", "")
    ok3.set_data("_operation_id", "custom_op")
    r.add_route("/c", "GET", ok3)
    check_openapi_specs(r)  # 不应 raise
    check(True, "合法 spec 通过")

    # ---------- check_openapi_specs: 畸形 raise ----------
    var bad = Router()
    var b1 = Handler(KIND_ECHO(), "b1")
    b1.set_data("_deprecated", "2")
    bad.add_route("/x1", "GET", b1)
    var raised1 = False
    try:
        check_openapi_specs(bad)
    except:
        raised1 = True
    check(raised1, "bad _deprecated raise")

    var bad2 = Router()
    var b2 = Handler(KIND_ECHO(), "b2")
    b2.set_data("_include_in_schema", "1")
    bad2.add_route("/x2", "GET", b2)
    var raised2 = False
    try:
        check_openapi_specs(bad2)
    except:
        raised2 = True
    check(raised2, "bad _include_in_schema raise")

    var bad3 = Router()
    var b3 = Handler(KIND_ECHO(), "b3")
    b3.set_data("_status_code", "600 Nope")
    bad3.add_route("/x3", "GET", b3)
    var raised3 = False
    try:
        check_openapi_specs(bad3)
    except:
        raised3 = True
    check(raised3, "bad _status_code (600) raise")

    var bad4 = Router()
    var b4 = Handler(KIND_ECHO(), "b4")
    b4.set_data("_status_code", "21 Short")
    bad4.add_route("/x4", "GET", b4)
    var raised4 = False
    try:
        check_openapi_specs(bad4)
    except:
        raised4 = True
    check(raised4, "bad _status_code (2 digits) raise")

    var bad5 = Router()
    var b5 = Handler(KIND_ECHO(), "b5")
    b5.set_data("_responses", "404:")
    bad5.add_route("/x5", "GET", b5)
    var raised5 = False
    try:
        check_openapi_specs(bad5)
    except:
        raised5 = True
    check(raised5, "bad _responses (empty desc) raise")

    var bad6 = Router()
    var b6 = Handler(KIND_ECHO(), "b6")
    b6.set_data("_status_code", "201 Created")
    b6.set_data("_responses", "201:dup")
    bad6.add_route("/x6", "GET", b6)
    var raised6 = False
    try:
        check_openapi_specs(bad6)
    except:
        raised6 = True
    check(raised6, "_responses 重复主键 raise")

    var bad7 = Router()
    var b7 = Handler(KIND_ECHO(), "b7")
    b7.set_data("_responses", "200:dup200")
    bad7.add_route("/x7", "GET", b7)
    var raised7 = False
    try:
        check_openapi_specs(bad7)
    except:
        raised7 = True
    check(raised7, "_responses 200 (默认主键) raise")

    print("all openapi_custom checks passed")
