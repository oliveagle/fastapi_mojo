# src/fastapi_mojo/test_all.mojo
#
# 集成测试：验证所有模块

from json import json_serialize, json_serialize_dict, json_escape
from router import Router, RouteMatch
from handler import Handler, ServerInfo, run_handler, KIND_ECHO, KIND_STATIC, KIND_TEMPLATE, KIND_WS_ECHO, KIND_WS_COUNTER, run_ws_message
from params_query import parse_path_params, parse_query_params, ParsedParams, url_decode
from params_json import parse_body_json
from string_builder import decode_utf8_bytes, StringBuilder, span_to_str, trim_spaces
from ws_session import ws_select_subprotocol


def test_json() raises:
    """测试 JSON 序列化."""
    print("=== JSON Tests ===")

    # 字符串
    var s = json_serialize("hello")
    assert s == '"hello"', "String serialize failed"

    # 转义
    var e = json_escape('He said "hi"')
    assert e == 'He said \\"hi\\"', "Escape failed"

    # 整数
    var i = json_serialize(42)
    assert i == "42", "Int serialize failed"

    # 浮点数
    var f = json_serialize(3.14)
    assert f == "3.14", "Float serialize failed"

    # 布尔值
    var b = json_serialize(True)
    assert b == "true", "Bool serialize failed"

    # null
    var n = json_serialize(None)
    assert n == "null", "Null serialize failed"

    # multibyte passthrough (no mojibake)
    var m = json_escape("é😀")
    assert m == "é😀", "Multibyte escape failed"

    # control char -> \u00XX
    var cc = json_escape("ab")
    assert cc == "a\u0001b", "Control char escape failed"

    # 字典
    var d = Dict[String, String]()
    d["name"] = "John"
    d["age"] = "30"
    var dj = json_serialize_dict(d)
    assert '"name": "John"' in dj, "Dict serialize failed"
    assert '"age": "30"' in dj, "Dict serialize failed"

    print("JSON tests passed!")


def test_router() raises:
    """测试路由匹配."""
    print("=== Router Tests ===")

    var router = Router()
    router.add_route("/", "GET", Handler(KIND_STATIC(), "index"))
    router.add_route("/items", "GET", Handler(KIND_STATIC(), "list"))
    router.add_route("/items", "POST", Handler(KIND_ECHO(), "create"))
    router.add_route("/items/{item_id}", "GET", Handler(KIND_ECHO(), "get"))
    router.add_route("/users/{user_id}/items/{item_id}", "GET", Handler(KIND_ECHO(), "user_item"))

    # 精确匹配
    assert router.match_route("/", "GET"), "Exact match failed"
    assert router.match_route("/items", "GET"), "Exact match /items GET failed"
    assert router.match_route("/items", "POST"), "Exact match /items POST failed"

    # Pattern 匹配
    assert router.match_route("/items/42", "GET"), "Pattern match /items/42 failed"
    assert not router.match_route("/items/42", "POST"), "Should not match POST"

    # 不匹配
    assert not router.match_route("/users", "GET"), "Should not match /users"
    assert not router.match_route("/items/42/extra", "GET"), "Should not match extra segments"

    # 参数提取
    var result = router.match_route_with_params("/items/42", "GET")
    assert result.matched, "match_with_params failed"
    assert result.handler.name == "get", "Handler name wrong"
    assert "item_id" in result.params, "item_id not in params"
    assert result.params["item_id"] == "42", "item_id value wrong"

    # 多参数
    var result2 = router.match_route_with_params("/users/123/items/456", "GET")
    assert result2.matched, "Multi-param match failed"
    assert result2.params["user_id"] == "123", "user_id wrong"
    assert result2.params["item_id"] == "456", "item_id wrong"

    print("Router tests passed!")


    # 405 检测：路径存在但方法未注册
    var ms_items = router.methods_for_path("/items")
    assert len(ms_items) == 2, "/items should have 2 methods"
    var ms_item42 = router.methods_for_path("/items/42")
    assert len(ms_item42) == 1, "/items/42 should have 1 method (GET)"
    var ms_root = router.methods_for_path("/")
    assert len(ms_root) == 1, "/ should have 1 method (GET)"
    var ms_users = router.methods_for_path("/users")
    assert len(ms_users) == 0, "/users should have 0 methods (404 not 405)"


def test_params() raises:
    """测试参数解析."""
    print("=== Params Tests ===")

    # Path params
    var p1 = parse_path_params("/items/42", "/items/{item_id}")
    assert p1.param_count == 1, "Path param count wrong"
    assert "item_id" in p1.values, "item_id not in values"
    assert p1.values["item_id"] == "42", "item_id value wrong"

    # 多 path params
    var p2 = parse_path_params("/users/123/items/456", "/users/{user_id}/items/{item_id}")
    assert p2.param_count == 2, "Multi path param count wrong"
    assert p2.values["user_id"] == "123", "user_id wrong"
    assert p2.values["item_id"] == "456", "item_id wrong"

    # Query params
    var q1 = parse_query_params("name=Mojo&age=30")
    assert q1.param_count == 2, "Query param count wrong"
    assert q1.values["name"] == "Mojo", "name wrong"
    assert q1.values["age"] == "30", "age wrong"

    # 空 query
    var q2 = parse_query_params("")
    assert q2.param_count == 0, "Empty query count wrong"

    # Body JSON
    var b1 = parse_body_json('{"name":"John","age":"30"}')
    assert b1.param_count == 2, "Body param count wrong"
    assert b1.values["name"] == "John", "body name wrong"
    assert b1.values["age"] == "30", "body age wrong"

    # 空 body
    var b2 = parse_body_json("")
    assert b2.has_error, "Empty body should have error"

    # 无效 JSON
    var b3 = parse_body_json("not json")
    assert b3.has_error, "Invalid JSON should have error"

    # P4.4 类型化: 值带类型标记
    var bt = parse_body_json('{"i":42,"f":3.14,"s":"hi","b":true,"n":null,"o":{"a":1},"arr":[1,2]}')
    assert bt.type_of("i") == "int" and bt.values["i"] == "42", "type int"
    assert bt.type_of("f") == "float" and bt.values["f"] == "3.14", "type float"
    assert bt.type_of("s") == "string", "type string"
    assert bt.type_of("b") == "bool" and bt.values["b"] == "true", "type bool"
    assert bt.type_of("n") == "null" and bt.values["n"] == "null", "type null"
    assert bt.type_of("o") == "object" and bt.values["o"] == '{"a":1}', "type object raw"
    assert bt.type_of("arr") == "array" and bt.values["arr"] == "[1,2]", "type array raw"
    # query/path 参数隐式为 string
    var qt = parse_query_params("a=1")
    assert qt.type_of("a") == "string", "query type string"
    var pt = parse_path_params("/x/42", "/x/{id}")
    assert pt.type_of("id") == "string", "path type string"

    # UTF-8 percent decode
    var q3 = parse_query_params("msg=%C3%A9%20ok")
    assert q3.values["msg"] == "é ok", "UTF-8 percent decode failed"

    # malformed %XX kept literal
    var q4 = parse_query_params("bad=%zz%41")
    assert q4.values["bad"] == "%zzA", "Malformed %XX failed"

    # surrogate pair -> single codepoint
    var b4 = parse_body_json('{"emoji":"\\uD83D\\uDE00"}')
    assert b4.values["emoji"] == "😀", "Surrogate pair failed"

    # lone surrogate -> U+FFFD
    var b5 = parse_body_json('{"bad":"\\ud800"}')
    assert b5.values["bad"] == "\uFFFD", "Lone surrogate failed"

    print("Params tests passed!")


def test_string_builder() raises:
    """测试线性字符串构建 + UTF-8 解码."""
    print("=== StringBuilder Tests ===")

    # decode UTF-8 bytes (héllo: 68 C3 A9 6C 6C 6F)
    var bs = List[Int]()
    for b in [0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F]:
        bs.append(b)
    assert decode_utf8_bytes(bs) == "héllo", "UTF-8 decode failed"

    # 4-byte codepoint (U+1F600: F0 9F 98 80)
    var bs2 = List[Int]()
    for b in [0xF0, 0x9F, 0x98, 0x80]:
        bs2.append(b)
    assert decode_utf8_bytes(bs2) == "😀", "4-byte UTF-8 decode failed"

    # invalid byte -> U+FFFD
    var bs3 = List[Int]()
    for b in [0x61, 0xFF, 0x62]:
        bs3.append(b)
    assert decode_utf8_bytes(bs3) == "a\uFFFD" + "b", "U+FFFD failed"

    # linear build
    var sb = StringBuilder()
    for _ in range(10000):
        sb.append("abc")
    assert sb.take().byte_length() == 30000, "StringBuilder failed"

    print("StringBuilder tests passed!")


def test_span_to_str() raises:
    """测试 bulk 字节 span → UTF-8 字符串解码."""
    print("=== SpanToStr Tests ===")

    # ASCII
    var s1 = String("hello")
    assert span_to_str(s1.as_c_string_slice().as_bytes()) == "hello", "ASCII failed"
    # 2-byte (é)
    var s2 = String("caf\u00e9")
    assert span_to_str(s2.as_c_string_slice().as_bytes()) == "caf\u00e9", "2-byte failed"
    # 3-byte (世)
    var s3 = String("\u4e16\u754c")
    assert span_to_str(s3.as_c_string_slice().as_bytes()) == "\u4e16\u754c", "3-byte failed"
    # 4-byte (emoji)
    var s4 = String("a\U0001F600b")
    assert span_to_str(s4.as_c_string_slice().as_bytes()) == "a\U0001F600b", "4-byte failed"
    # mixed
    var s5 = String("Hi \u00e9 \u4e16 \U0001F600 end")
    assert span_to_str(s5.as_c_string_slice().as_bytes()) == "Hi \u00e9 \u4e16 \U0001F600 end", "mixed failed"
    # empty
    var s6 = String("")
    assert span_to_str(s6.as_c_string_slice().as_bytes()) == "", "empty failed"
    # 1MB: linear smoke (amortized O(n))
    var big = StringBuilder()
    var i = 0
    while i < 1000000:
        big.append_byte(97)
        i += 1
    var big_s = big.take()
    var r = span_to_str(big_s.as_c_string_slice().as_bytes())
    assert r.byte_length() == 1000000, "1MB length wrong"
    print("SpanToStr tests passed!")


def test_framework() raises:
    """测试路由注册机制 (ADR-0004): /echo 注册 = 数据, 核心 dispatch 通用."""
    print("=== Framework Tests ===")

    # 模拟用户代码: 只加数据, 不碰 dispatch
    var router = Router()
    router.add_route("/echo", "GET", Handler(KIND_ECHO(), "echo"))
    router.add_route("/echo", "POST", Handler(KIND_ECHO(), "echo"))

    keys = List[String]()
    names = List[String]()
    for i in range(router.route_count()):
        keys.append(router.routes[i].method + " " + router.routes[i].path)
        names.append(router.routes[i].handler.name)
    var info = ServerInfo("1.8.0", "test", 1, 1, keys, names)

    # GET /echo?x=1&y=2 -> 回显 query (query_ 前缀由核心公共逻辑加)
    var m1 = router.match_route_with_params("/echo", "GET")
    assert m1.matched, "/echo GET matched"
    var q1 = parse_query_params("x=1&y=2")
    var r1 = run_handler(m1.handler, m1.params, q1, ParsedParams(), info)
    assert r1[0] == "200 OK", "echo GET status"
    assert m1.handler.name == "echo", "echo handler name"

    # POST /echo body {"a":"b","c":"d"} -> 回显 body 参数
    var m2 = router.match_route_with_params("/echo", "POST")
    assert m2.matched, "/echo POST matched"
    var b2 = parse_body_json('{"a":"b","c":"d"}')
    var r2 = run_handler(m2.handler, m2.params, ParsedParams(), b2, info)
    assert r2[1]["a"] == "b", "echo body a"
    assert r2[1]["c"] == "d", "echo body c"

    # /echo/{id} 风格: path 参数回显
    var m3 = router.match_route_with_params("/items/42", "GET")
    # (router 里没有 /items, 用新 router 验证 path 参数)
    var router2 = Router()
    router2.add_route("/items/{item_id}", "GET", Handler(KIND_ECHO(), "get"))
    var m3b = router2.match_route_with_params("/items/42", "GET")
    assert m3b.matched, "pattern matched"
    var r3 = run_handler(m3b.handler, m3b.params, ParsedParams(), ParsedParams(), info)
    assert r3[1]["item_id"] == "42", "echo path param"

    print("Framework tests passed!")


def test_ws() raises:
    """WebSocket 增强 (ADR-0007): 子协议协商 / WS 消息分派 / WS 路由."""
    print("=== WS Tests ===")

    # trim_spaces
    assert trim_spaces("  a  ") == "a", "trim both"
    assert trim_spaces("a") == "a", "trim none"
    assert trim_spaces("   ") == "", "trim all"
    assert trim_spaces("") == "", "trim empty"

    # 子协议协商
    var s1 = ws_select_subprotocol("", "anything")
    assert s1[0] and s1[1] == "", "no required -> ok, empty"
    var s2 = ws_select_subprotocol("chat", "chat")
    assert s2[0] and s2[1] == "chat", "exact offer"
    var s3 = ws_select_subprotocol("chat", "other, chat ,x")
    assert s3[0] and s3[1] == "chat", "offer list with spaces"
    var s4 = ws_select_subprotocol("chat", "")
    assert not s4[0], "required but no offer"
    var s5 = ws_select_subprotocol("chat", "other")
    assert not s5[0], "required not in offer"
    var s6 = ws_select_subprotocol("chat", "chatchat")
    assert not s6[0], "substring is not a match"

    # run_ws_message: echo
    var he = Handler(KIND_WS_ECHO(), "ws_echo")
    var e1 = run_ws_message(he, 1, "hello", 0)
    assert e1[0] == 1 and e1[1] == "hello" and e1[2] == 0, "echo reply"

    # run_ws_message: counter (stateful)
    var hc = Handler(KIND_WS_COUNTER(), "ws_counter")
    var c1 = run_ws_message(hc, 1, "5", 0)
    assert c1[0] == 1 and c1[1] == "sum=5" and c1[2] == 5, "counter 5"
    var c2 = run_ws_message(hc, 1, "3", c1[2])
    assert c2[1] == "sum=8" and c2[2] == 8, "counter cumulative"
    var c3 = run_ws_message(hc, 1, "abc", 8)
    assert c3[1] == "error: expected an integer" and c3[2] == 8, "counter invalid"
    var c4 = run_ws_message(hc, 1, "123456789012345678901", 0)
    assert c4[1] == "error: expected an integer", "counter overflow"
    var c5 = run_ws_message(hc, 1, "", 8)
    assert c5[1] == "sum=8" and c5[2] == 8, "counter empty = 0"

    # 未知 WS kind -> 不回复
    var hq = Handler(999, "bogus")
    var q1 = run_ws_message(hq, 1, "x", 0)
    assert q1[0] == 0 and q1[1] == "", "unknown kind no reply"

    # WS 路由 (精确匹配)
    var router = Router()
    var hws = Handler(KIND_WS_ECHO(), "ws_echo")
    var hchat = Handler(KIND_WS_ECHO(), "ws_chat")
    hchat.set_data("ws_sp", "chat")
    router.add_ws_route("/ws", hws)
    router.add_ws_route("/ws/chat", hchat)
    assert router.ws_route_count() == 2, "ws count"
    var m1 = router.match_ws_route("/ws")
    assert m1.matched and m1.handler.name == "ws_echo", "ws match"
    var m2 = router.match_ws_route("/ws/chat")
    assert m2.matched and m2.handler.data["ws_sp"] == "chat", "ws chat match"
    var m3 = router.match_ws_route("/ws/")
    assert not m3.matched, "ws no trailing slash match"

    print("WS tests passed!")


def main() raises:
    print("Running all tests...")
    test_json()
    test_router()
    test_params()
    test_string_builder()
    print("")
    test_span_to_str()
    test_ws()
    test_framework()


    print("All tests passed!")
