# fastapi_mojo

> 🎯 **项目本标（North Star）**：**用 Mojo 把代码编译成一个单一 Binary，运行时零外部依赖**（不依赖 Python / pip / .venv）。
> 详见 `AGENTS.md` §1 与 `docs/adr/0002-single-binary-deployment/`。

用 **Mojo** 实现一套 FastAPI 的实验仓库。

**当前阶段：Phase 1 — Native Mojo HTTP Server**

Mojo 原生 HTTP 服务器，零 Python 依赖，支持：
- 7 个 REST API 路由（GET/POST/DELETE）
- 模式匹配路由（`/items/{item_id}`）
- Query/Path/Body 参数解析
- JSON 序列化
- CORS 支持
- 静态文件服务
- 优雅关闭（SIGINT/SIGINT）
- 请求 ID 追踪

## 目录结构

```
.
├── src/fastapi_mojo/
│   ├── http_bridge_final.c      # C FFI 桥接：socket I/O + CORS + 静态文件
│   ├── http_server_final.mojo   # HTTP 服务器主程序
│   ├── json.mojo                # JSON 序列化
│   ├── router.mojo              # 模式匹配路由
│   ├── params.mojo              # 参数解析
│   ├── test_all.mojo            # 集成测试
│   ├── static/                  # 静态文件目录
│   │   ├── index.html
│   │   └── test.json
│   └── libhttp_bridge_final.so  # C 桥接库
├── deploy.sh                    # 编译 + 打包部署脚本
├── bench_native.sh              # 原生服务器基准测试
├── docs/adr/                    # 架构决策记录
└── .beads/                      # 任务管理
```

## 快速开始

### 编译运行

```bash
cd src/fastapi_mojo

# 编译 C 桥接
gcc -shared -fPIC -o libhttp_bridge_final.so http_bridge_final.c -lc

# 运行服务器
mojo run -Xlinker -L. -Xlinker -lhttp_bridge_final http_server_final.mojo
```

### 部署

```bash
# 编译 + 打包（输出到 build/deploy/）
./deploy.sh

# 部署到远程
scp -r build/deploy/ user@host:/opt/fastapi_mojo/
```

## API 路由

| 方法 | 路径 | 描述 |
|------|------|------|
| GET | `/` | 欢迎页面 |
| GET | `/health` | 健康检查 |
| GET | `/hello?name=Mojo` | 个性化问候 |
| GET | `/items` | 获取所有项目 |
| POST | `/items` | 创建项目 |
| GET | `/items/{item_id}` | 获取单个项目 |
| DELETE | `/items/{item_id}` | 删除项目 |

### 示例

```bash
# 欢迎页面
curl http://127.0.0.1:8000/
# {"message": "Welcome to Mojo HTTP Server", "version": "1.4.0", ...}

# 健康检查
curl http://127.0.0.1:8000/health
# {"status": "healthy", "uptime": "running", ...}

# 个性化问候
curl "http://127.0.0.1:8000/hello?name=Mojo"
# {"message": "Hello from Mojo!", "greeting": "Hello, Mojo!", ...}

# 创建项目
curl -X POST http://127.0.0.1:8000/items -d '{"name":"Widget"}'
# {"message": "Item created", "item_name": "Widget", ...}

# 获取项目
curl http://127.0.0.1:8000/items/42
# {"message": "Get item by ID", "item_id": "42", ...}

# 删除项目
curl -X DELETE http://127.0.0.1:8000/items/42
# {"message": "Item deleted", "item_id": "42", ...}
```

## 静态文件

将文件放在 `static/` 目录，服务器会自动服务：

```bash
mkdir -p static
echo '<h1>Hello</h1>' > static/index.html

curl http://127.0.0.1:8000/index.html
# <h1>Hello</h1>
```

支持的文件类型：
- HTML/CSS/JS
- JSON/XML
- 图片（PNG/JPG/GIF/SVG/ICO）
- 字体（WOFF/WOFF2）
- PDF

## 基准测试

```bash
# 运行基准测试（默认 100 请求，5 并发）
./bench_native.sh

# 自定义请求数和并发数
./bench_native.sh 1000 10
```

## 依赖

- [Mojo](https://docs.modular.com/mojo/) 1.0.0+
- GCC（编译 C 桥接）
- Bash

## 架构

```
┌─────────────────────────────────────────────────────┐
│                    Mojo Server                       │
├─────────────────────────────────────────────────────┤
│  http_server_final.mojo                             │
│  ├── 路由匹配 (router.mojo)                         │
│  ├── 参数解析 (params.mojo)                         │
│  ├── JSON 序列化 (json.mojo)                        │
│  └── 静态文件服务                                    │
├─────────────────────────────────────────────────────┤
│  http_bridge_final.c                                │
│  ├── Socket I/O                                     │
│  ├── CORS 头部                                      │
│  ├── Content-Type 检测                              │
│  └── 信号处理 (SIGINT/SIGTERM)                      │
└─────────────────────────────────────────────────────┘
```

## 架构决策记录（ADR）

本项目使用 ADR 记录重要技术决策。所有决策记录位于 `docs/adr/` 目录。

### 决策链

- **已决策-5（C1）**：handler 业务逻辑由 Mojo 构造 lambda 源码
- **已决策-6（C2）**：Mojo 构造 JSON + Response 包装
- **已决策-7（C3）**：Mojo 路由表 + 批量注册
- **已决策-8（C4）**：Path/Body 参数解析迁移到 Mojo
- **已决策-9（C5）**：Mojo HTTP 服务器（替代 uvicorn）— 已实现
- **已决策-10**：不自造 JSON 序列化，直接包 orjson
- **已决策-11**：.venv 环境隔离
- **已决策-12**：异常 → JSON 响应（orjson 序列化）
- **已决策-13**：项目本标 = Mojo 单 Binary 零依赖部署（ADR-0002）

详见 `docs/adr/0001-mojo-replacement-strategy/` 与 `docs/adr/0002-single-binary-deployment/`。

## 路线图

- [x] C FFI 桥接（socket I/O）
- [x] JSON 序列化
- [x] 模式匹配路由
- [x] 参数解析
- [x] REST API（7 个路由）
- [x] CORS 支持
- [x] 静态文件服务
- [x] 优雅关闭
- [x] 请求 ID 追踪
- [ ] 中间件支持
- [ ] WebSocket 支持
- [ ] 单一二进制打包（Phase 2）
