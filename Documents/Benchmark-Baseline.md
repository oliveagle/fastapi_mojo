# Baseline Benchmark 报告

- **日期**：2026-08-22
- **Commit**：`977cc34`（baseline: Mojo thin wrapper calling Python FastAPI, hello world works）
- **压测工具**：hey v0.1.5（Go 编译，单二进制）
- **测试目标**：`src/fastapi_mojo/hello.mojo` 启动的 FastAPI 服务（Mojo wrapper → Python FastAPI → uvicorn）

## 1. 测试环境

| 项目 | 值 |
|---|---|
| CPU | AMD RYZEN AI MAX+ 395 w/ Radeon 8060S（16 核 32 线程） |
| 内存 | 124 GiB |
| 内核 | Linux 7.0.0-28-generic |
| Mojo | 1.0.0 (ed45d567) |
| Python | 3.12.3 |
| FastAPI | 0.141.1 |
| uvicorn | 0.52.4 |
| 服务器地址 | http://127.0.0.1:8000 |

## 2. 测试方法

- 启动：`cd src/fastapi_mojo && mojo run hello.mojo`（uvicorn 单进程，默认配置）
- 预热：每轮压测前先发 2000 请求（并发 50）预热
- 压测命令：`hey -n <总数> -c <并发> <url>`
- 所有请求均返回 HTTP 200，无错误响应

## 3. 测试结果

### 3.1 GET /（静态 JSON 响应）

| 指标 | 10k 请求 / 100 并发 | 50k 请求 / 500 并发 | 100k 请求 / 200 并发 |
|---|---|---|---|
| 总耗时 | 2.03 s | 12.05 s | 20.46 s |
| **吞吐量 (req/s)** | **4937.7** | **4149.1** | **4887.2** |
| 平均延迟 | 19.9 ms | 120.2 ms | 40.9 ms |
| 最快延迟 | 1.1 ms | 47.0 ms | — |
| 最慢延迟 | 59.2 ms | 240.0 ms | — |
| 错误 | 0 | 0 | 0 |

### 3.2 GET /hello?name=Mojo（带 Query 参数）

| 指标 | 10k 请求 / 100 并发 |
|---|---|
| 总耗时 | 2.16 s |
| **吞吐量 (req/s)** | **4639.6** |
| 平均延迟 | 21.4 ms |
| 错误 | 0 |

### 3.3 延迟分布（GET /，10k 请求 / 100 并发）

| 百分位 | 延迟 |
|---|---|
| 10% | 15.1 ms |
| 25% | 16.4 ms |
| 50% | 18.3 ms |
| 75% | 20.6 ms |
| 90% | 25.5 ms |
| 95% | 34.6 ms |
| 99% | 48.9 ms |

## 4. 结论

1. **Baseline 吞吐量约 4000–5000 req/s**（单进程 uvicorn + FastAPI + Mojo wrapper 转发）。
2. 高并发（500）下吞吐略降（4149 req/s），延迟上升（平均 120ms），但 **17 万+ 请求零错误**，稳定性良好。
3. 带 Query 参数的路由与静态路由性能接近（4639 vs 4938 req/s），wrapper 转发开销可忽略。
4. 当前瓶颈在 Python 侧（uvicorn/FastAPI/starlette），Mojo wrapper 只是薄壳转发，不是性能热点。

## 5. 后续对比基准

后续用 Mojo 原生实现 FastAPI 时，以本报告数据为对照：

- 目标 1：Mojo 原生路由 + 响应序列化，吞吐 ≥ 本 baseline（~5000 req/s）
- 目标 2：Mojo 原生 HTTP 服务器（替代 uvicorn），吞吐显著超越 baseline
- 每次迭代在相同环境（本机、hey 同参数）下复测，保证可比性

## 6. 复现方法

```bash
# 1. 启动服务
cd src/fastapi_mojo
mojo run hello.mojo

# 2. 压测（另开终端）
hey -n 10000 -c 100 http://127.0.0.1:8000/
hey -n 10000 -c 100 "http://127.0.0.1:8000/hello?name=Mojo"
```
