# src/fastapi_mojo/test_all.mojo
#
# 集成测试：验证所有模块

from json import json_serialize, json_serialize_dict, json_escape
from router import Router, RouteMatch
from params import parse_path_params, parse_query_params, parse_body_json, ParsedParams


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

    print("Params tests passed!")


def main() raises:
    print("Running all tests...")
    test_json()
    test_router()
    test_params()
    print("")
    print("All tests passed!")
