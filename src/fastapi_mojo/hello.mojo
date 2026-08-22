# src/fastapi_mojo/hello.mojo
#
# Hello World：通过最薄的 Mojo wrapper 使用 FastAPI。
# handler 业务逻辑由 Mojo 构造（已决策-5：C1 方案 A）。
# 响应序列化由 orjson 完成（已决策-10：包 orjson 不自造）。
# 路由表由 Mojo 集中管理（已决策-7：C3 方案 A）。
# Python 依赖使用 .venv（已决策-11：不污染系统环境）。
#
# 运行（注意：Mojo 目前不支持相对路径 import，需要进入本目录运行）：
#   cd src/fastapi_mojo
#   mojo run hello.mojo
#
# 然后打开 http://127.0.0.1:8000/ 或：
#   curl http://127.0.0.1:8000/
#   curl http://127.0.0.1:8000/hello?name=Mojo
from std.python import Python

from wrapper import FastAPIWrapper


def main() raises:
    # 1. 用 Mojo wrapper 创建 FastAPI 应用（底层就是 fastapi.FastAPI()）
    var app = FastAPIWrapper()

    # 2. 注册 GET /：Mojo 构造 dict，orjson 序列化（已决策-10）
    var hello_data = Python.evaluate("dict()")
    hello_data["message"] = "Hello World from FastAPI (called via Mojo wrapper)"
    hello_data["serialized_by"] = "orjson"
    app.register_dict("/", "get", hello_data)

    # 3. 注册 GET /hello?name=...：带 Query 参数的 handler（C4）
    #    Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成
    app.register_query(
        "/hello", "get", "name", "World",
        "Hello {name} from Mojo-parsed query",
    )

    # 4. 注册 GET /items/{item_id}：带 Path 参数的 handler（C4）
    #    Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成
    app.register_path(
        "/items/{item_id}", "get", "item_id",
        "Item {item_id} from Mojo-parsed path",
    )

    # 5. 注册 POST /items：带 Body 参数的 handler（C4）
    #    Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成
    app.register_body(
        "/items", "post", "item",
        "Created {item} from Mojo-parsed body",
    )

    # 6. 注册 GET /users/{user_id}/items/{item_id}：带多 Path 参数的 handler（C4 深化）
    #    Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成
    app.register_path_multi(
        "/users/{user_id}/items/{item_id}", "get",
        "user_id,item_id",
        "User {user_id} Item {item_id}",
    )

    # 7. 注册 PUT /items/{item_id}：带 Path + Body 参数的 handler（POST/PUT/DELETE 支持）
    #    Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成
    app.register_path(
        "/items/{item_id}", "put", "item_id",
        "Updated item {item_id}",
    )

    # 8. 注册 DELETE /items/{item_id}：带 Path 参数的 handler（POST/PUT/DELETE 支持）
    #    Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成
    app.register_path(
        "/items/{item_id}", "delete", "item_id",
        "Deleted item {item_id}",
    )

    # 9. 注册 POST /items/validated：带 Body 参数验证的 handler（Body 参数验证）
    #    Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成
    app.register_body_validated(
        "/items/validated", "post", "name,price",
        "Created item with name={name} and price={price}",
    )

    # 10. 批量注册 Mojo 路由表到 FastAPI（C3）
    print(t"Mojo 路由表: {app.route_count()} 条路由")
    app.register_all()

    # 7. 注册全局异常处理器（已决策-12：异常→JSON 响应）
    app.register_exception_handlers()

    # 8. 用 uvicorn 把 app 跑起来（uvicorn 也是 Python 侧的东西）
    var uvicorn = Python.import_module("uvicorn")
    print("FastAPI (via Mojo wrapper) listening on http://127.0.0.1:8000")
    print("Try:  curl http://127.0.0.1:8000/")
    print("Try:  curl 'http://127.0.0.1:8000/hello?name=Mojo'")
    print("Try:  curl http://127.0.0.1:8000/items/42")
    print("Try:  curl -X POST http://127.0.0.1:8000/items -H 'Content-Type: application/json' -d '{\"item\": \"test\"}'")
    print("Try:  curl http://127.0.0.1:8000/nonexistent  # 测试 404")
    uvicorn.run(app.app(), host="127.0.0.1", port=8000)
