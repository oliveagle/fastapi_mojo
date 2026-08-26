# ADR-0002: 单二进制部署 — 任务清单

> 关联：`AGENTS.md` §1（本标）、`docs/adr/0002-single-binary-deployment/01-decisions.md`（决策）、
> `docs/adr/0003-single-binary-mechanism/`（实现机制）

## 任务列表

### Epic: Phase 1 — 核心组件 Mojo 化

| # | 任务 | 状态 | 关联 |
|---|------|------|------|
| 1 | 验证 `mojo build` 静态链接可行性 | ✅ 已验证（纯静态不可行 → ADR-0003 嵌入机制） | C5 前置 |
| 2 | C5 解除阻塞：Mojo 原生 HTTP server（替代 uvicorn） | ✅ 完成（C FFI socket 桥接 + Mojo 原生协议处理） | 已决策-9 |
| 3 | Mojo 原生 JSON 序列化（替代 orjson） | ✅ 完成（json.mojo，线性时间） | 已决策-10 重审 |
| 4 | Mojo 原生 Router（替代 FastAPI 路由表） | ✅ 完成（router.mojo pattern matching） | 已决策-7 重审 |
| 5 | Mojo 原生参数解析（替代 FastAPI Depends） | ✅ 完成（params.mojo，UTF-8 安全 JSON parser） | 已决策-8 重审 |
| 6 | HTTP 协议层（替代 Starlette ASGI） | ✅ 完成（等价形态：C 桥接 read/parse/限流 + Mojo 路由分发） | C6 |

### Epic: Phase 2 — 去 Python 化

| # | 任务 | 状态 | 关联 |
|---|------|------|------|
| 7 | 移除 Python interop（Phase 2 拆除 wrapper） | ✅ 完成（服务器代码路径零 Python） | 已决策-11 退役 |
| 8 | 移除 .venv 依赖 | ✅ 完成（服务器零依赖；.venv 仅保留给 benchmark 工具链 bench.py，非运行期） | 已决策-11 退役 |
| 9 | 异常处理改用 Mojo 原生实现（移除 orjson） | ✅ 完成（错误响应由 json.mojo 原生构造） | 已决策-12 重审 |

### Epic: Phase 3 — 单 Binary 交付

| # | 任务 | 状态 | 关联 |
|---|------|------|------|
| 10 | `mojo build` 产出独立可执行文件 | ✅ 完成（build_single.sh → build/fastapi_mojo，ldd 仅 libc） | 本标 |
| 11 | 干净环境部署验证（无 Python/pip） | ✅ 完成（env -i 冒烟 + 全端点回归） | 本标 |
| 12 | 部署文档与脚本（`./build.sh` + `./fastapi_mojo`） | ✅ 完成（build_single.sh + deploy.sh + README） | 本标 |

## 验收标准（Phase 3 终点）— 全部达成

1. ✅ 构建产出单个可执行文件（ldd 无 .so 依赖，除 libc 基础运行时）
2. ✅ 干净环境（env -i，无 Python/pip/LD_LIBRARY_PATH）运行二进制，服务正常启动
3. ✅ benchmark 在 binary 上跑通（hey 16 并发 ~20k rps，无退化）
4. ✅ `AGENTS.md` §1 描述的本标全部达成
