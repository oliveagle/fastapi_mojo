# fastapi_mojo

> 🎯 **项目本标（North Star）**：**用 Mojo 把代码编译成一个单一 Binary，运行时零外部依赖**（不依赖 Python / pip / .venv）。
> 详见 `AGENTS.md` §1 与 `docs/adr/0002-single-binary-deployment/`。当前 "Mojo wrapper 调 Python FastAPI" 仅是引导阶段（Phase 0）。

用 **Mojo** 实现一套 FastAPI 的实验仓库。

当前阶段：**通过 Mojo 写一层最薄的 wrapper，直接调用 Python 版 FastAPI 跑通 hello world**，
为后续逐步用 Mojo 原生实现 FastAPI 铺路。

## 目录结构

```
.
├── .gitmodules                 # submodule 配置
├── fastapi/                    # submodule: https://github.com/fastapi/fastapi.git
│   └── fastapi/                #   FastAPI 源码（参考/对照实现）
├── docs/
│   └── adr/                    # 架构决策记录（ADR）
└── src/fastapi_mojo/
    ├── wrapper.mojo            # 最薄的 Mojo wrapper：持有并转发到 Python FastAPI 实例
    ├── hello.mojo              # hello world 入口：注册路由并用 uvicorn 跑起来
    └── test_wrapper.mojo       # Mojo 侧单元测试
```

## 依赖

- [Mojo](https://docs.modular.com/mojo/) 编译器（本仓库在 Mojo 1.0.0 上验证）
- Python 3.12（Mojo 的 Python 互操作会调用系统 Python）
- `.venv` 虚拟环境（优先使用，避免污染系统环境）
- `pip install fastapi uvicorn orjson`

## 运行

```bash
cd src/fastapi_mojo
mojo run hello.mojo
```

> 注意：Mojo 目前不支持相对路径 import，所以需要先 `cd` 到模块目录再运行。

启动后：

```bash
curl http://127.0.0.1:8000/
# {"message":"Hello World from FastAPI (called via Mojo wrapper)","serialized_by":"orjson"}

curl "http://127.0.0.1:8000/hello?name=Mojo"
# {"message":"Hello Mojo from Mojo-parsed query"}

curl http://127.0.0.1:8000/items/42
# {"message":"Item 42 from Mojo-parsed path"}

curl -X POST http://127.0.0.1:8000/items -H "Content-Type: application/json" -d '{"item": "test"}'
# {"message":"Created {'item': 'test'} from Mojo-parsed body"}

# OpenAPI 文档
# http://127.0.0.1:8000/docs
```

## Benchmark（固定脚本 + SQLite 长期跟踪）

**唯一入口：`./benchmark.sh`**（固定姿势，反复跑同一套流程）。所有压测必须通过它运行，禁止手写压测。

```bash
# 完整跑一遍（固定场景 benchmark-scenarios.json，约 1 分钟）
# 自动：启动服务器 → 预热 → 跑场景 → 写入 SQLite → 更新 JSON + Markdown 报告
./benchmark.sh

# 查看历史记录（长期跟踪）
./benchmark.sh --history
./benchmark.sh --history --limit 5

# 服务器已在运行时
./benchmark.sh --no-server
```

固定文件：
- `benchmark.sh` — 固定入口脚本（前置检查 + 固定输出路径 + 透传参数）
- `benchmark-scenarios.json` — 固定场景配置（name/url/n/c/method/data）
- `bench.py` — 底层 runner（启动/预热/采集/统计/SQLite/报告）

输出：
- **SQLite**（`docs/reports/auto/benchmark.db`，随 Git 持续跟踪）：每次运行自动写入 `runs` + `scenarios` 两张表，含环境信息、commit、每个场景的吞吐/延迟分位/错误数，可长期对比趋势；
- **JSON**（`docs/reports/auto/benchmark-results.json`）：本次运行快照，统一数据格式；
- **Markdown**（`docs/reports/auto/Benchmark-Baseline.md`）：由同一份 JSON 自动渲染，格式统一。

每次迭代跑 `./benchmark.sh` 即可得到同构数据，直接对比吞吐与延迟；`--history` 可查看历次记录。

## wrapper 设计（当前阶段）

`wrapper.mojo` 是**最薄的壳**：

- `FastAPIWrapper` 内部只保存一个 `PythonObject`，指向 `fastapi.FastAPI()` 实例；
- `get/post/put/delete` 直接转发到底层 FastAPI 的装饰器；
- 路由 handler 目前用 Python lambda / callable 提供（`Python.evaluate(...)`）；
- 服务器用 Python 侧 uvicorn 拉起。

也就是说：请求链路是 `curl → uvicorn → fastapi(starlette) → Mojo wrapper 注册的 handler`，
真正干活的全是 Python 侧代码，Mojo 侧目前只负责"创建 app、注册路由"。

### Mojo 已接管的能力

- **JSON 序列化**：使用 orjson（Rust 实现，~8M ops/s，10x 快于 stdlib json）
- **路由表管理**：Mojo 侧集中管理 Route 列表，启动时批量注册到 FastAPI
- **参数解析**：Path/Query/Body 参数解析由 Mojo 构造 handler 源码
- **错误处理**：全局异常处理器（404/500/通用异常 → JSON 响应）

### .venv 环境隔离

Mojo 使用系统 Python，为避免污染系统环境，自动把仓库 `.venv` 的 `site-packages` 插到 `sys.path[0]`，优先于系统包。

## 架构决策记录（ADR）

本项目使用 ADR 记录重要技术决策。所有决策记录位于 `docs/adr/` 目录。

### 决策链

- **已决策-5（C1）**：handler 业务逻辑由 Mojo 构造 lambda 源码
- **已决策-6（C2）**：Mojo 构造 JSON + Response 包装
- **已决策-7（C3）**：Mojo 路由表 + 批量注册
- **已决策-8（C4）**：Path/Body 参数解析迁移到 Mojo
- **已决策-9（C5）**：Mojo HTTP 服务器（替代 uvicorn）— 阻塞
- **已决策-10**：不自造 JSON 序列化，直接包 orjson
- **已决策-11**：.venv 环境隔离
- **已决策-12**：异常 → JSON 响应（orjson 序列化）
- **已决策-13**：项目本标 = Mojo 单 Binary 零依赖部署（ADR-0002）

详见 `docs/adr/0001-mojo-replacement-strategy/` 与 `docs/adr/0002-single-binary-deployment/`。

## 下一步（路线图）

1. 用 Mojo 原生写 handler（不再依赖 Python lambda）；
2. 用 Mojo 实现路由注册表 / 参数解析 / 响应序列化，逐步替换 Python 侧逻辑；
3. 最终用 Mojo 完整实现 FastAPI（此时 submodule 仅作功能对照）。
