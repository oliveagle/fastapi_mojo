# src/fastapi_mojo/wrapper.mojo
#
# 最薄的 Mojo wrapper：
#   直接持有并转发到 Python 的 FastAPI 对象，不重写任何 FastAPI 逻辑。
#
# 本文件只是「薄壳」：真正的 web 框架逻辑全部在 submodule `fastapi/`
# （以及系统安装的 fastapi + uvicorn）中，这里仅仅用 Mojo 的 Python 互操作
# 把它包起来，为后续用 Mojo 原生实现 FastAPI 铺路。
#
# 已决策链：
#   - 已决策-5（C1）：handler 业务逻辑由 Mojo 构造 lambda 源码
#   - 已决策-6（C2）：Mojo 构造 JSON + Response 包装
#   - 已决策-7（C3）：Mojo 路由表 + 批量注册
from std.python import Python
from std.python import PythonObject


struct Route:
    """Mojo 侧路由表条目（已决策-7：C3 方案 A）。

    path/method 由 Mojo 管理，handler 是 Python callable（执行壳）。
    """

    var path: String
    var method: String
    var handler: PythonObject

    def __init__(out self, path: String, method: String, handler: PythonObject):
        self.path = path
        self.method = method
        self.handler = handler


struct FastAPIWrapper:
    """包装 Python 版 FastAPI 的最薄一层。

    Mojo 侧保存：
      - _app：PythonObject（指向 fastapi.FastAPI 实例）
      - _routes：List[Route]（Mojo 侧路由表，启动时批量注册）
    """

    var _app: PythonObject
    var _routes: List[Route]

    def __init__(out self) raises:
        """创建底层 fastapi.FastAPI() 实例。"""
        var py_fastapi = Python.import_module("fastapi")
        self._app = py_fastapi.FastAPI()
        self._routes = List[Route]()

    # -- 转发到底层 Python app --------------------------------------------
    def app(self) -> PythonObject:
        """返回底层 FastAPI 应用对象（需要时直接使用）。"""
        return self._app

    def get(self, path: String) raises -> PythonObject:
        """等价于 @app.get(path)：返回 FastAPI 的装饰器，再把它当函数调用即可注册路由。"""
        return self._app.get(path)

    def post(self, path: String) raises -> PythonObject:
        return self._app.post(path)

    def put(self, path: String) raises -> PythonObject:
        return self._app.put(path)

    def delete(self, path: String) raises -> PythonObject:
        return self._app.delete(path)

    # -- 便捷注册：handler 是 Python callable（lambda / def / callable 对象）--
    def route(self, path: String, handler: PythonObject, methods: PythonObject) raises:
        """直接调用 app.add_api_route(path, handler, methods=...) 注册一个路由。"""
        var kwargs = Python.evaluate("dict")
        kwargs["methods"] = methods
        self._app.add_api_route(path, handler, kwargs)

    # -- Mojo 路由表（已决策-7：C3 方案 A）--------------------------------
    # Mojo 侧集中管理 Route 列表，启动时批量注册到 FastAPI。
    def add_route(mut self, path: String, method: String, handler: PythonObject) raises:
        """向 Mojo 路由表添加一条路由（不立即注册，register_all 时批量注册）。"""
        self._routes.append(Route(path, method, handler))

    def register_all(self) raises:
        """把 Mojo 路由表批量注册到 FastAPI。"""
        for i in range(len(self._routes)):
            # 直接访问字段，避免拷贝 Route（含 PythonObject 不可隐式拷贝）
            var path = self._routes[i].path
            var method = self._routes[i].method
            var handler = self._routes[i].handler
            if method == "get":
                var decorator = self._app.get(path)
                decorator(handler)
            elif method == "post":
                var decorator = self._app.post(path)
                decorator(handler)
            elif method == "put":
                var decorator = self._app.put(path)
                decorator(handler)
            elif method == "delete":
                var decorator = self._app.delete(path)
                decorator(handler)
            else:
                raise Error("不支持的 HTTP method: " + method)

    def route_count(self) -> Int:
        """返回 Mojo 路由表大小。"""
        return len(self._routes)

    # -- Mojo 驱动的 handler 注册（已决策-5：C1 方案 A）--------------------
    # handler 业务逻辑由 Mojo 构造 lambda 源码字符串，Python 只做执行壳。
    def register_handler(mut self, path: String, method: String, lambda_src: String) raises:
        """注册一个 handler：lambda_src 是 Mojo 构造的 Python lambda 源码。

        例：app.register_handler("/", "get",
                "lambda: {'message': 'Hello from Mojo'}")
        """
        var handler = Python.evaluate(lambda_src)
        self.add_route(path, method, handler)

    def register_message(mut self, path: String, method: String, message: String) raises:
        """便捷注册：返回 {'message': <message>} 的 JSON handler。

        业务数据（message）由 Mojo 侧传入，Mojo 构造 lambda 源码。
        """
        var lambda_src = "lambda: {'message': '" + message + "'}"
        self.register_handler(path, method, lambda_src)

    # -- Mojo 序列化（已决策-6：C2 方案 A）--------------------------------
    # Mojo 拼接 JSON 字符串，handler 返回 Response(content=json_str)，
    # FastAPI 对 Response 对象原样返回，不二次序列化。
    def json_response(self, json_str: String) -> PythonObject:
        """构造 FastAPI Response 对象（content=json_str, media_type=application/json）。"""
        var responses = Python.import_module("fastapi.responses")
        return responses.Response(content=json_str, media_type="application/json")

    def register_json(mut self, path: String, method: String, json_str: String) raises:
        """注册一个返回 Mojo 构造 JSON 字符串的 handler。

        例：app.register_json("/", "get", '{"message": "Hello from Mojo"}')
        """
        # Mojo 构造 lambda 源码：返回 Response(content=<json_str>)
        var lambda_src = (
            "lambda: __import__('fastapi').responses.Response("
            "content='" + json_str + "', media_type='application/json')"
        )
        self.register_handler(path, method, lambda_src)
