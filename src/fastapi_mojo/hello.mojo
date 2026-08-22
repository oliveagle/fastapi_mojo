# src/fastapi_mojo/hello.mojo
#
# Hello World：通过最薄的 Mojo wrapper 使用 FastAPI。
# handler 业务逻辑由 Mojo 构造（已决策-5：C1 方案 A）。
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

    # 2. 注册 GET /：handler 由 Mojo 构造 lambda 源码（业务数据在 Mojo 侧）
    #    C2：Mojo 拼接 JSON 字符串，返回 Response 对象（FastAPI 原样返回）
    var hello_msg = "Hello World from FastAPI (called via Mojo wrapper)"
    var hello_json = '{"message": "' + hello_msg + '", "serialized_by": "mojo"}'
    app.register_json("/", "get", hello_json)

    # 3. 注册 GET /hello?name=...：带 Query 参数的 handler
    #    Mojo 构造 lambda 源码，业务逻辑（默认值、拼接）由 Mojo 控制
    var greet_src = "lambda name='World': {'message': f'Hello {name} from FastAPI via Mojo'}"
    app.register_handler("/hello", "get", greet_src)

    # 4. 用 uvicorn 把 app 跑起来（uvicorn 也是 Python 侧的东西）
    var uvicorn = Python.import_module("uvicorn")
    print("FastAPI (via Mojo wrapper) listening on http://127.0.0.1:8000")
    print("Try:  curl http://127.0.0.1:8000/")
    print("Try:  curl 'http://127.0.0.1:8000/hello?name=Mojo'")
    uvicorn.run(app.app(), host="127.0.0.1", port=8000)
