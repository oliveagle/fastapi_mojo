# src/fastapi_mojo/test_all.mojo
#
# 集成测试：验证所有模块

from json import json_serialize, json_serialize_dict, json_escape
from router import Router, RouteMatch
from params import parse_path_params, parse_query_params, parse_body_json, ParsedParams, url_decode
from string_builder import decode_utf8_bytes, StringBuilder, span_to_str


def test_json() raises:
    """测试 JSON 序列化。"""
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
    """测试路由匹配。"""
    print("=== Router Tests ===")

    var router = Router()
    router.add_route("/", "GET", "index")
    router.add_route("/items", "GET", "list")
    router.add_route("/items", "POST", "create")
    router.add_route("/items/{item_id}", "GET", "get")
    router.add_route("/users/{user_id}/items/{item_id}", "GET", "user_item")

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
    assert result.handler_name == "get", "Handler name wrong"
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
    """测试参数解析。"""
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
    """测试线性字符串构建 + UTF-8 解码。"""
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
    """测试 bulk 字节 span → UTF-8 字符串解码。"""
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


def main() raises:
    print("Running all tests...")
    test_json()
    test_router()
    test_params()
    test_string_builder()
    print("")
    test_span_to_str()

    print("All tests passed!")
