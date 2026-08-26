# ADR-0003: 单一二进制机制 — 任务清单

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | 验证 `mojo build --emit object` 外部符号面（11 个 KGEN C API） | ✅ 完成 | 反汇编 server.o，U 符号清单 |
| 2 | runtime_shim.c：嵌入/暂存/dlopen/11 符号转发 | ✅ 完成 | src/fastapi_mojo/runtime_shim.c |
| 3 | build_single.sh 构建链路 | ✅ 完成 | ./build_single.sh → build/fastapi_mojo (2.1M) |
| 4 | ldd 自包含验证（仅 libc） | ✅ 完成 | build_single.sh [5/5] 输出 |
| 5 | env -i 干净环境冒烟 | ✅ 完成 | deploy.sh [3/3] + 手工端点测试 |
| 6 | deploy.sh 重写为单文件部署 + 验证 | ✅ 完成 | ./deploy.sh |
| 7 | 全端点回归（含 413/400/HEAD/UTF-8/穿越） | ✅ 完成 | 见提交记录与 ADR §5 |
| 8 | 性能基准（hey 16 并发） | ✅ 完成 | ~20k rps GET /health |
