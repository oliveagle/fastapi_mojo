# fastapi_mojo

> 🎯 **项目本标（North Star）**：**用 Mojo 把代码编译成一个单一 Binary，运行时零外部依赖**（不依赖 Python / pip / .venv / 附带 .so）。
> 详见 `AGENTS.md` §1 与 `docs/adr/0002-single-binary-deployment/`。

用 **Mojo** 实现一套 FastAPI 的实验仓库。

**当前阶段：Phase 3 — 单一 Binary 交付（已达成）**

- ✅ Mojo 原生 HTTP 服务器（C FFI socket 桥接 + Mojo 路由/参数/JSON）
- ✅ **单一二进制**：`./build_single.sh` 产出 `build/fastapi_mojo`，`ldd` 动态依赖仅 libc（外加系统 vdso/ld-linux 内核组件；无 libm/libstdc++/libgcc_s/Python）
- ✅ 干净环境验证：`env -i ./build/fastapi_mojo` 直接启动服务（无 Python、无 LD_LIBRARY_PATH）
- ✅ 性能：单核顺序 ~300 rps（curl 进程开销），hey 16 并发 ~20k rps（GET /health）

## 单一二进制是怎么做到的

Mojo 1.0.0 的运行时只以 3 个共享库分发（`libKGENCompilerRTShared.so`、
`libMSupportGlobals.so`、`libAsyncRTRuntimeGlobals.so`），没有静态库，
`mojo build` 也没有 `--static`。本项目采用的机制（见 `runtime_shim.c`）：

1. `mojo build --emit object` 产出服务器对象（其外部依赖仅为 11 个
   `KGEN_CompilerRT_*` C API 符号 + libc + C 桥接符号）；
2. 3 个运行时 .so 用 `objcopy -I binary` 作为数据嵌入可执行文件；
3. 进程启动时（`main` 之前的 C constructor）把运行时暂存到私有临时目录
   （`/dev/shm` 或 `/tmp`），`dlopen` 并绑定这 11 个符号的转发函数；
4. 退出时（atexit）清理临时目录。

对用户的效果：**scp 一个文件即可运行**，部署目录里没有任何 .so。
运行期临时目录是 dlopen 的硬性要求（Linux 无法从内存 dlopen）。

## 目录结构

```
.
├── build_single.sh                # ★ 单一二进制构建脚本（推荐入口）
├── deploy.sh                      # 构建 + 自包含验证 + 输出 build/deploy/fastapi_mojo
├── bench_native.sh                # curl 快速基准
├── benchmark.sh                   # 固定姿势 benchmark（唯一压测入口，AGENTS.md §4）
├── src/fastapi_mojo/
│   ├── http_server_final.mojo     # HTTP 服务器主程序（路由/handler/日志）
│   ├── http_bridge_final.c        # C FFI 桥接：socket I/O + CORS + 静态文件 + 限流 + 信号
│   ├── runtime_shim.c             # 单一二进制：运行时嵌入/暂存/dlopen/符号转发
│   ├── ws.c                     # WebSocket (RFC 6455) 协议原语：SHA-1/base64/帧编解码/close 码/UTF-8 (ADR-0006/0007)
│   ├── ws_session.mojo          # WebSocket 会话循环：子协议/保活 ping/控制帧/handler 分派 (ADR-0007)
│   ├── router.mojo                # 模式匹配路由（{param} segment）
│   ├── params_query.mojo          # Path/Query 参数解析 + ParsedParams (values + types)
│   ├── params_json.mojo           # Body JSON parser（UTF-8 安全 + 类型标记）
│   ├── json.mojo                  # 线性时间 JSON 序列化
│   ├── string_builder.mojo        # 线性字符串构建 + UTF-8 字节解码
│   ├── middleware.mojo            # 中间件定义
│   ├── test_all.mojo              # 集成测试
│   └── static/                    # 静态文件目录
│       ├── index.html
│       └── test.json
├── docs/adr/                      # 架构决策记录（含 6 条架构隔离约束声明）
├── fastapi/                       # git submodule：bootstrap 时代参考（FastAPI 0.141.1 源码），非运行期依赖
└── .beads/                        # beads-rust 任务管理
```

## 快速开始

```bash
# 依赖：mojo 1.0.0（pip install modular）、gcc、binutils
./build_single.sh
./build/fastapi_mojo          # 监听 http://127.0.0.1:8000
```

端口配置（优先级：CLI > 环境变量 > 默认 8000）：

```bash
./build/fastapi_mojo --port 9000        # CLI（也支持 --port=9000）
FASTAPI_MOJO_PORT=9000 ./build/fastapi_mojo   # 环境变量
```

多 worker 并发（ADR-0005，默认 1 = 单进程）：

```bash
FASTAPI_MOJO_WORKERS=8 ./build/fastapi_mojo --port 8000
# 8 个独立进程共享端口（SO_REUSEPORT，nginx pre-fork 模型）；
# 每个 worker 独立 Mojo 运行时；pkill -x fastapi_mojo 全杀。
# 实测（32 核）：200 并发 125k rps（单进程 36k，3.5x），P99 18ms（单进程 50.8ms）
```

静态文件目录默认为工作目录下的 `./static`，可用环境变量覆盖：

```bash
FASTAPI_MOJO_STATIC_DIR=/opt/static ./build/fastapi_mojo
```

### 部署（单文件）

```bash
./deploy.sh                   # 构建 + 验证，输出 build/deploy/fastapi_mojo
scp build/deploy/fastapi_mojo user@host:/opt/fastapi_mojo/
ssh user@host '/opt/fastapi_mojo'
```

### 测试

```bash
# 单元测试（各模块自检）
cd src/fastapi_mojo
for f in json params_query params_json router string_builder test_all; do mojo run $f.mojo; done

# 集成测试（单一 binary 端到端，56 项检查，CI 可重复，见 .github/workflows/ci.yml）
./scripts/e2e_test.sh
```

## API 路由

| 方法 | 路径 | 描述 |
|------|------|------|
| GET | `/` | 欢迎页面 |
| GET | `/health` | 健康检查 |
| GET | `/status` | 运行状态（uptime/请求数/路由数） |
| GET | `/routes` | 路由表 |
| GET | `/hello?name=Mojo` | 个性化问候（UTF-8 查询参数） |
| GET | `/items` | 获取所有项目 |
| POST | `/items` | 创建项目（JSON body，UTF-8 安全） |
| GET | `/items/{item_id}` | 获取单个项目 |
| DELETE | `/items/{item_id}` | 删除项目 |
| GET | `/ws` | WebSocket (RFC 6455) 升级 → echo（text/binary/ping/pong/close） |
| GET | `/ws/counter` | WebSocket → 有状态计数器（连接级累加和，回复 `sum=<n>`） |
| GET | `/ws/chat` | WebSocket → echo，**必需子协议** `Sec-WebSocket-Protocol: chat`（缺失 → 400） |

其他能力：CORS（含 OPTIONS 预检）、HEAD（无 body）、静态文件（含目录穿越 403 防护）、
body 限流（默认 1MB，超限 413）、非法 UTF-8 请求 400、请求 ID 追踪、优雅关闭（SIGINT/SIGTERM）、
WS 服务端保活 ping（`FASTAPI_MOJO_WS_PING_MAX`，默认 3 次空闲超时后 close 1000）、
WS text UTF-8 校验（非法 → close 1007）、WS close 码校验（非法 → 1002）。

### 示例

```bash
curl http://127.0.0.1:8000/
curl http://127.0.0.1:8000/health
curl "http://127.0.0.1:8000/hello?name=Mojo"
curl -X POST http://127.0.0.1:8000/items -d '{"name":"Widget"}'
curl http://127.0.0.1:8000/items/42
curl -X DELETE http://127.0.0.1:8000/items/42
curl -I http://127.0.0.1:8000/            # HEAD：仅头无 body
```

## 静态文件

**单一 binary 内置了 `src/fastapi_mojo/static/` 下的文件**（objcopy 嵌入，
启动时暂存到私有临时目录；构建时新增/修改 static 文件会自动重新嵌入）。
目录解析优先级：

1. `FASTAPI_MOJO_STATIC_DIR` 环境变量（显式覆盖，任何模式）
2. CWD 下的 `./static`（若存在 — 开发模式）
3. 内置暂存目录（部署模式：scp 单文件到任意目录即可）
4. 回退 `./static`（404，旧行为）

将文件放在静态目录（默认 `src/fastapi_mojo/static/` 或 `FASTAPI_MOJO_STATIC_DIR`），
仅已知扩展名的路径（.html/.css/.js/.json/图片等）走静态服务，API 路由不受影响
（符号链接/目录穿越均 403）：

```bash
curl http://127.0.0.1:8000/test.json
# {"status": "ok"}
```

## 基准测试

```bash
# 快速（curl 顺序）
./bench_native.sh

# 固定姿势（唯一压测入口，AGENTS.md §4；自动写 SQLite 长期跟踪）
./benchmark.sh --server-cmd ../../build/fastapi_mojo --server-dir src/fastapi_mojo
./benchmark.sh --history
```

## 依赖

- [Mojo](https://docs.modular.com/mojo/) 1.0.0（`pip install modular`）
- GCC（编译 C 桥接 + shim）
- binutils（objcopy 嵌入运行时）
- 运行期：仅 glibc 基础运行时。实际 `ldd` 输出为 `libc.so.6` + 系统 `linux-vdso.so.1` / `ld-linux-x86-64.so.2`（内核/加载器组件）；**不依赖** libm / libstdc++ / libgcc_s / Python / .venv

## 架构

```
┌────────────────────────────────────────────────────────┐
│              fastapi_mojo（单一可执行文件）               │
├────────────────────────────────────────────────────────┤
│  http_server_final.mojo                                │
│  ├── 路由匹配 (router.mojo)                            │
│  ├── 参数解析 (params_query/params_json, UTF-8 安全)   │
│  ├── JSON 序列化 (json.mojo, 线性时间)                 │
│  ├── 字符串构建 (string_builder.mojo, 线性时间)        │
│  └── 静态文件 / CORS / 限流 / 日志                     │
├────────────────────────────────────────────────────────┤
│  http_bridge_final.c（C FFI，随 binary 静态打包）        │
│  ├── Socket I/O（read/parse 完整 body）                │
│  ├── UTF-8 校验（非法请求 400）                        │
│  ├── Content-Length 限流（413，先检查后截断）          │
│  └── 信号处理（SIGINT/SIGTERM 优雅关闭）               │
├────────────────────────────────────────────────────────┤
│  ws.c（WebSocket RFC 6455 协议原语）                   │
│  ├── 握手 (SHA-1 + base64 Sec-WebSocket-Accept)        │
│  │        + subprotocol 回显 (RFC 6455 §4.1)           │
│  ├── 帧编解码 (掩码/7|16|64-bit 长度/分片重组/超时细分) │
│  ├── close 码校验 (§7.4.1) + text UTF-8 校验 (§5.6)    │
│  └── 会话编排: ws_session.mojo (Mojo 驱动, ADR-0007)   │
├────────────────────────────────────────────────────────┤
│  runtime_shim.c（单一二进制机制）                        │
│  ├── 嵌入 3 个 Mojo 运行时 .so（objcopy binary 数据）  │
│  ├── constructor：暂存到 /dev/shm|/tmp + dlopen        │
│  ├── 11 个 KGEN_CompilerRT_* 符号转发                  │
│  └── atexit：清理临时目录                              │
└────────────────────────────────────────────────────────┘
        运行期依赖：仅 libc（+ 系统 vdso / ld-linux）
```

## 架构决策记录（ADR）

- **ADR-0001**：Mojo 替换 Python 策略（C1~C4 已落地，C5 经 C FFI 达成）
- **ADR-0002**：项目本标 = 单一二进制零依赖部署
- **ADR-0003**：单一二进制实现机制（运行时嵌入 + 暂存 + dlopen shim）
- **ADR-0004**：用户路由注册机制（Handler 类型 + 单点 dispatch，user code = data）
- **ADR-0005**：并发模型（多进程 worker + SO_REUSEPORT，nginx pre-fork）
- **ADR-0006**：WebSocket (RFC 6455) 支持（C FFI 协议层 + /ws echo 端点）
- **ADR-0007**：WebSocket 增强（多端点路由 + 子协议协商 + 服务端保活 ping + close/UTF-8 校验）

决策链：已决策-5~13 见 `docs/adr/0001-mojo-replacement-strategy/` 与 `AGENTS.md` §6。

## 路线图

- [x] C FFI 桥接（socket I/O）
- [x] JSON 序列化（线性时间）
- [x] 模式匹配路由
- [x] 参数解析（UTF-8 安全）
- [x] REST API（11 个路由 + HEAD/OPTIONS/静态文件）
- [x] CORS 支持
- [x] 优雅关闭（SIGINT/SIGTERM）
- [x] 请求 ID 追踪
- [x] 中间件（request_id / logging / timing）
- [x] **单一二进制打包（Phase 3，本标达成）**
- [x] WebSocket 支持（RFC 6455，C FFI 协议层 ws.c + /ws echo 端点，ADR-0006）
- [x] WebSocket 增强（多端点路由 /ws /ws/counter /ws/chat + 子协议协商 + 服务端保活 ping + close 码/UTF-8 校验，ADR-0007）
