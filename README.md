# fastapi_mojo

用 **Mojo** 实现一套 FastAPI 的实验仓库。

当前阶段：**通过 Mojo 写一层最薄的 wrapper，直接调用 Python 版 FastAPI 跑通 hello world**，
为后续逐步用 Mojo 原生实现 FastAPI 铺路。

## 目录结构

```
.
├── .gitmodules                 # submodule 配置
├── fastapi/                    # submodule: https://github.com/fastapi/fastapi.git
│   └── fastapi/                #   FastAPI 源码（参考/对照实现）
└── src/fastapi_mojo/
    ├── wrapper.mojo            # 最薄的 Mojo wrapper：持有并转发到 Python FastAPI 实例
    └── hello.mojo              # hello world 入口：注册路由并用 uvicorn 跑起来
```

## 依赖

- [Mojo](https://docs.modular.com/mojo/) 编译器（本仓库在 Mojo 1.0.0 上验证）
- Python 3.12（Mojo 的 Python 互操作会调用系统 Python）
- `pip install fastapi uvicorn`

## 运行

```bash
cd src/fastapi_mojo
mojo run hello.mojo
```

> 注意：Mojo 目前不支持相对路径 import，所以需要先 `cd` 到模块目录再运行。

启动后：

```bash
curl http://127.0.0.1:8000/
# {"message":"Hello World from FastAPI (called via Mojo wrapper)"}

curl "http://127.0.0.1:8000/hello?name=Mojo"
# {"message":"Hello Mojo from FastAPI via Mojo"}

# OpenAPI 文档
# http://127.0.0.1:8000/docs
```

## wrapper 设计（当前阶段）

`wrapper.mojo` 是**最薄的壳**：

- `FastAPIWrapper` 内部只保存一个 `PythonObject`，指向 `fastapi.FastAPI()` 实例；
- `get/post/put/delete` 直接转发到底层 FastAPI 的装饰器；
- 路由 handler 目前用 Python lambda / callable 提供（`Python.evaluate(...)`）；
- 服务器用 Python 侧 uvicorn 拉起。

也就是说：请求链路是 `curl → uvicorn → fastapi(starlette) → Mojo wrapper 注册的 handler`，
真正干活的全是 Python 侧代码，Mojo 侧目前只负责"创建 app、注册路由"。

## 下一步（路线图）

1. 用 Mojo 原生写 handler（不再依赖 Python lambda）；
2. 用 Mojo 实现路由注册表 / 参数解析 / 响应序列化，逐步替换 Python 侧逻辑；
3. 最终用 Mojo 完整实现 FastAPI（此时 submodule 仅作功能对照）。
