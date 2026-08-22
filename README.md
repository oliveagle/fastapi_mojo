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

## Benchmark（代码化 + SQLite 长期跟踪）

统一压测入口：`bench.py` 自动完成「启动服务器 → 预热 → 跑场景 → 解析 hey csv → 写入 SQLite → 输出统一 JSON + Markdown 报告」。**所有压测必须通过此脚本运行，禁止手写压测。**

```bash
# 依赖：hey（go install github.com/rakyll/hey@latest 或下载二进制放入 PATH）

# 完整跑一遍（默认 4 个场景，约 1 分钟）——自动记录到 Documents/benchmark.db
python3 bench.py --json Documents/benchmark-results.json --report Documents/Benchmark-Baseline.md

# 查看历史记录（长期跟踪）
python3 bench.py --history
python3 bench.py --history --limit 5

# 服务器已在运行时跳过启停
python3 bench.py --no-server --json out.json

# 自定义场景（JSON 文件：name/url/n/c 列表）
python3 bench.py --scenarios my-scenarios.json --json out.json
```

输出：
- **SQLite**（`Documents/benchmark.db`，随 Git 持续跟踪）：每次运行自动写入 `runs` + `scenarios` 两张表，含环境信息、commit、每个场景的吞吐/延迟分位/错误数，可长期对比趋势；
- **JSON**（`Documents/benchmark-results.json`）：本次运行快照，统一数据格式；
- **Markdown**（`Documents/Benchmark-Baseline.md`）：由同一份 JSON 自动渲染，格式统一。

每次迭代跑同一命令即可得到同构数据，直接对比吞吐与延迟；`--history` 可查看历次记录。

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
