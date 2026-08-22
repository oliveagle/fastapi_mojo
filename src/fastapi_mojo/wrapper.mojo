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


# -- .venv 自动发现（已决策-11）-------------------------------------------
# Mojo 用的是系统 Python，为避免污染系统环境，自动把仓库 .venv 的
# site-packages 插到 sys.path[0]，优先于系统包。
def init_python_path() raises:
    """把 .venv/lib/python3.12/site-packages 加入 sys.path[0]（若存在）。"""
    var sys = Python.import_module("sys")
    var os = Python.import_module("os")
    # 候选路径（相对于当前文件：src/fastapi_mojo/wrapper.mojo → repo root/.venv）
    var candidates = List[String]()
    candidates.append(".venv/lib/python3.12/site-packages")
    candidates.append("../.venv/lib/python3.12/site-packages")
    candidates.append("../../.venv/lib/python3.12/site-packages")
    for i in range(len(candidates)):
        var p = candidates[i]
        if os.path.exists(p):
            # 绝对化并插到 sys.path 最前
            sys.path.insert(0, os.path.abspath(p))
            print(t"[wrapper] using venv: {p}")
            return
    print("[wrapper] no .venv found, using system Python")


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
        # 先初始化 .venv 路径（已决策-11），再导入 fastapi
        init_python_path()
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

    # -- Mojo 序列化（已决策-6 + 已决策-10：包 orjson 不自造）--------------
    # JSON 序列化直接用 orjson（Rust 实现，~8M ops/s），Mojo 只负责构造 dict。
    def orjson_dumps(self, data: PythonObject) raises -> String:
        """调用 orjson.dumps(data).decode()，返回 JSON 字符串。"""
        var orjson = Python.import_module("orjson")
        var bytes_obj = orjson.dumps(data)
        return String(bytes_obj.decode())

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

    def register_dict(mut self, path: String, method: String, data: PythonObject) raises:
        """注册一个 handler：Mojo 构造 dict，用 orjson 序列化（已决策-10）。

        例：
            var data = Python.evaluate("dict")
            data["message"] = "Hello from orjson"
            app.register_dict("/", "get", data)
        """
        var json_str = self.orjson_dumps(data)
        self.register_json(path, method, json_str)

    # -- Mojo 参数解析（已决策-8：C4 方案 A）------------------------------
    # Mojo 构造带 Request 注解的 handler，参数解析逻辑由 Mojo 生成。
    def register_query(
        mut self,
        path: String,
        method: String,
        param_name: String,
        default: String,
        message_template: String,
    ) raises:
        """注册一个从 Query 参数取值的 handler。

        例：app.register_query("/hello", "get", "name", "World",
                "Hello {name} from Mojo-parsed query")
        """
        # Mojo 构造带 Request 注解的 handler 源码（参数解析逻辑 Mojo 生成）
        var code = (
            "def _h(request: Request):\n"
            "    return {'message': '" + message_template + "'.replace('{name}', "
            "request.query_params.get('" + param_name + "', '" + default + "'))}\n"
        )
        var builtins = Python.import_module("builtins")
        var ns = Python.evaluate("dict()")
        # 用 fastapi.Request 类注入命名空间，handler 参数注解才能被 FastAPI 识别
        var fastapi = Python.import_module("fastapi")
        ns["Request"] = fastapi.Request
        builtins.exec(code, ns)
        var handler = ns["_h"]
        self.add_route(path, method, handler)
