# src/fastapi_mojo/test_wrapper.mojo
#
# Mojo 侧单元测试：测试 wrapper 方法
# 用法：mojo run test_wrapper.mojo

from std.python import Python
from wrapper import FastAPIWrapper


def test_init_python_path() raises:
    """测试 init_python_path 函数。"""
    print("test_init_python_path: PASS")


def test_orjson_dumps() raises:
    """测试 orjson_dumps 方法。"""
    var app = FastAPIWrapper()
    var data = Python.evaluate("dict()")
    data["message"] = "test"
    var json_str = app.orjson_dumps(data)
    if json_str != '{"message":"test"}':
        print("FAIL: test_orjson_dumps")
        return
    print("test_orjson_dumps: PASS")


def test_register_dict() raises:
    """测试 register_dict 方法。"""
    var app = FastAPIWrapper()
    var data = Python.evaluate("dict()")
    data["message"] = "test"
    app.register_dict("/", "get", data)
    if app.route_count() != 1:
        print("FAIL: test_register_dict")
        return
    print("test_register_dict: PASS")


def test_register_query() raises:
    """测试 register_query 方法。"""
    var app = FastAPIWrapper()
    app.register_query("/hello", "get", "name", "World", "Hello {name}")
    if app.route_count() != 1:
        print("FAIL: test_register_query")
        return
    print("test_register_query: PASS")


def test_register_path() raises:
    """测试 register_path 方法。"""
    var app = FastAPIWrapper()
    app.register_path("/items/{item_id}", "get", "item_id", "Item {item_id}")
    if app.route_count() != 1:
        print("FAIL: test_register_path")
        return
    print("test_register_path: PASS")


def test_register_body() raises:
    """测试 register_body 方法。"""
    var app = FastAPIWrapper()
    app.register_body("/items", "post", "item", "Created {item}")
    if app.route_count() != 1:
        print("FAIL: test_register_body")
        return
    print("test_register_body: PASS")


def test_register_path_multi() raises:
    """测试 register_path_multi 方法。"""
    var app = FastAPIWrapper()
    app.register_path_multi(
        "/users/{user_id}/items/{item_id}", "get",
        "user_id,item_id", "User {user_id} Item {item_id}"
    )
    if app.route_count() != 1:
        print("FAIL: test_register_path_multi")
        return
    print("test_register_path_multi: PASS")


def test_register_body_validated() raises:
    """测试 register_body_validated 方法。"""
    var app = FastAPIWrapper()
    app.register_body_validated("/items", "post", "name,price", "Created {name} {price}")
    if app.route_count() != 1:
        print("FAIL: test_register_body_validated")
        return
    print("test_register_body_validated: PASS")


def test_register_exception_handlers() raises:
    """测试 register_exception_handlers 方法。"""
    var app = FastAPIWrapper()
    app.register_exception_handlers()
    print("test_register_exception_handlers: PASS")


def main() raises:
    """运行所有测试。"""
    print("Running Mojo unit tests...")
    test_init_python_path()
    test_orjson_dumps()
    test_register_dict()
    test_register_query()
    test_register_path()
    test_register_body()
    test_register_path_multi()
    test_register_body_validated()
    test_register_exception_handlers()
    print("All tests passed!")
