# src/fastapi_mojo/wrapper.mojo
#
# 最薄的 Mojo wrapper：
#   直接持有并转发到 Python 的 FastAPI 对象，不重写任何 FastAPI 逻辑。
#
# 本文件只是「薄壳」：真正的 web 框架逻辑全部在 submodule `fastapi/`
# （以及系统安装的 fastapi + uvicorn）中，这里仅仅用 Mojo 的 Python 互操作
# 把它包起来，为后续用 Mojo 原生实现 FastAPI 铺路。
from std.python import Python
from std.python import PythonObject


struct FastAPIWrapper:
    """包装 Python 版 FastAPI 的最薄一层。

    Mojo 侧只保存一个 PythonObject（指向 fastapi.FastAPI 实例），
    所有能力都通过转发调用暴露出来。
    """

    var _app: PythonObject

    def __init__(out self) raises:
        """创建底层 fastapi.FastAPI() 实例。"""
        var py_fastapi = Python.import_module("fastapi")
        self._app = py_fastapi.FastAPI()

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

    # -- Mojo 驱动的 handler 注册（已决策-5：C1 方案 A）--------------------
    # handler 业务逻辑由 Mojo 构造 lambda 源码字符串，Python 只做执行壳。
    def register_handler(self, path: String, method: String, lambda_src: String) raises:
        """注册一个 handler：lambda_src 是 Mojo 构造的 Python lambda 源码。

        例：app.register_handler("/", "get",
                "lambda: {'message': 'Hello from Mojo'}")
        """
        var handler = Python.evaluate(lambda_src)
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

    def register_message(self, path: String, method: String, message: String) raises:
        """便捷注册：返回 {'message': <message>} 的 JSON handler。

        业务数据（message）由 Mojo 侧传入，Mojo 构造 lambda 源码。
        """
        var lambda_src = "lambda: {'message': '" + message + "'}"
        self.register_handler(path, method, lambda_src)
