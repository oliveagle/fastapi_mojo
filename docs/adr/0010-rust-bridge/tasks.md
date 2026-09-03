# ADR-0010: Rust bridge（Mojo + Rust only）— 任务清单

> 里程碑依赖：DC1（Phase 4）→ DC2（Phase 5）→ DC3（Phase 6），详见
> `docs/goals/0001-fastapi-parity-and-de-python-toolchain.md` Track C。

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | ADR-0010 决策记录（候选方案 + 6 约束 + 验证方式） | ✅ 完成 | `docs/adr/0010-rust-bridge/01-decisions.md` |
| 2 | Rust crate 骨架：`Cargo.toml`（staticlib + panic=abort + LTO + opt-level=z）+ `src/lib.rs` 导出表 + `rust-toolchain.toml` pin | ✅ 完成 | `cargo build --release` 产出 `target/release/libfastapi_mojo_rs.a`；`rust-toolchain.toml` pin 1.97.1 |
| 3 | `build_single.sh` 接入：`cargo build --release` → `gcc -pie --whole-archive librust_bridge.a`（替代三份 `.o`）；objcopy payload 符号 extern 引用；移除三份 `gcc -c` C 入口 | ✅ 完成 | **已替代 ws.o → librust_bridge.a**；bridge.o / shim.o 待 DC2/DC3。**必须 `-static-libgcc`**：Rust staticlib 默认拉 libgcc_s.so.1（compiler-rt），违反 North Star；静态链接后 ldd 仅 libc |
| 4 | CI（`.github/workflows/ci.yml`）：安装 rust toolchain + `cargo build` + C 清零断言（`find src -name '*.c'` = 0）+ 体积增幅 ≤ +2MB 断言 | ✅ 完成（C 清零断言为终态门禁） | CI 全绿：rustup 安装（pin 1.97.1）+ `cargo test --release -- --test-threads=1` + 体积预算（中间态 ≤ 6M，终态收紧）+ C 计数步骤（Phase 6 前为 INFO，=0 时 PASS） |
| 5 | **DC1** `ws.c` → `ws.rs` (完成, **含端到端质量门禁验证**) | ✅ 完成 | 实现: `src/ws.rs` (382) + `src/ws/parser.rs` (240) + `src/ws/ws_tests.rs` (434), 6 FFI 符号 + WsParser 布局对齐。**质量门禁 (2026-09-04)**:
| | | | 1) **0 BUG** — `cargo test --release` 26/26 绿 (RFC 6455 known vectors); `scripts/e2e_test.sh --port 18888` **79/79 绿** (含 WS 合并帧/10 并发/鉴权/{param}/UTF-8/keepalive) |
| | | | 2) **性能不退化** — `./benchmark.sh` vs commit 29c9def 基线 (35829 rps on `/`) → 当前 **48497 rps (+35%)**, 6 场景全部 0 errors |
| | | | 3) **无内存泄漏** — valgrind 与 Mojo 生成码不兼容 (EVEX), 用 RSS 平台化测试: warmup 50 + 500×4 batch, VmRSS 16456→16800(batch1)→16800(batch2/3/4 严格一致), 无线性增长 |
| | | | 4) **单 binary 不变式** — `ldd` **仅 libc** (`-static-libgcc` 静态链接后 libgcc_s 消失, 满足 CI 断言); 体积 4.8M (基线 2.2M, **+2.6M 超 +2MB 目标**, 见 task 12 后续去 std 瘦身) |
| 6 | **DC2** `http_bridge_final.c` → `bridge.rs`（已拆分 `parse.rs`/`response.rs`/`cmd.rs`/`time_util.rs`/`port.rs`/`signals.rs`/`state.rs`/`socket.rs`/`init_workers.rs`/`conn.rs`+`conn/parse.rs`+**`conn/deadlines.rs`**; 剩余 `recv_and_parse` 状态机 + `pump_conn`/`pump_ws_conn` + poll loop + WS 会话 FFI + `conn_done`; ~40 FFI 出口签名逐一对齐） | 🔶 进行中（11 模块已落地） | **已落地 (2026-09-04, 3 轮累计)**:
- DC2-a 纯逻辑: `bridge/{parse,response,cmd}.rs` (C §511-1775 主体) — 79 单元测试
- DC2-b I/O leaves (time_util/port/signals): C §230-348 + §184-202 — 49 + 3 真信号 raise 测试
- DC2-c 配置 + listen socket + 多进程 worker (本轮): `bridge/{state,socket,init_workers}.rs` — C §210-228 (static_dir), §236-237 (max_body), §259-303 (workers/fork/exec), §350-368 (create_bound_socket + SO_REUSEPORT), §480-495 (setup_conn_fd), §496-516 (init_recv_timeout) + 加 `port::current_configured_port` (供 workers re-exec 读 `--port`). 新增 37 单元测试 (state 22 + workers 8 + socket 5, 含 1 fork `#[ignore]`).
- **累计**: `cargo test --release -- --test-threads=1` **230/230 全绿** (234 项 = 230 通过 + 4 `#[ignore]`; 含 ws.rs 26 + conn 表/解析 50+ + **conn/deadlines 16**); `build_single.sh` 4.8M + ldd **仅 libc** (`-static-libgcc`) + e2e 79/79 绿; binary 体积零增长 (**5,000,720 字节严格不变**, 新增模块全 internal, 无 `#[no_mangle]`, LTO 全 drop)
- **conn 表 + 请求头纯解析 (本轮)**: `bridge/conn.rs` (ConnTable 1024 表 + WsEventQueue + active 跟踪) + `bridge/conn/parse.rs` (finish_header / parse_request_line / parse_content_length / decide_keepalive / check_ws_upgrade 纯逻辑). **修 3 类实测问题**: ① alloc 语义对齐 C (先扫空闲槽复用, 非无脑 append); ② `#[cfg(test)] sys_close` no-op (conn 表测试合成 fd 误关 libtest 捕获管道); ③ conn_tests fd 避开 0/1/2. `cargo test` 因 state_tests env 全局副作用须 `--test-threads=1`
- FFI 包装延迟: 当前 `--whole-archive` 同名符号冲突 → `#[no_mangle] extern "C"` 入口在 `bridge.o` 真正下线时统一加 (9 个模块顶层已就绪, 包装仅是薄壳 + globals 读写)
- **剩余 (I/O 核心, 下轮)**: `recv_and_parse` 外层字节状态机 (phase 0/1/2/3/4 转移 + slowloris 防护) + `pump_conn` / `pump_ws_conn` + poll 事件循环 + WS 会话 FFI (is_ws_upgrade/ws_session_begin/ws_conn_upgrade/ws_payload_slice/ws_last_opcode/ws_message_done/ws_conn_close) + `conn_done` 清理 + build_single.sh 切换 (bridge.o → librust_bridge.a) + 全量 e2e + bench + RSS 泄漏门禁 (**check_deadlines 已落地 deadlines.rs**) |
| 7 | **DC3** `runtime_shim.c` → `shim.rs`：embed/stage/dlopen/符号转发 + 孤儿 stage 清理 + 退出清理（`.init_array` 构造顺序） | ⬜ TODO | `env -i` 干净启动；启动即验证构造顺序 |
| 8 | 删除三份 `*.c` + AGENTS/README/Goal/CI 对齐；C 清零验收 | ⬜ TODO | `find src -name '*.c'` = 0；`git grep -n '\.c\b' -- src/` = 0（业务代码） |
| 12 | **去 std 瘦身** (binary 体积收口): ws.rs 当前用 `format!` + `Vec` + `CStr`, 引入 std 运行时 (~1.5-2MB)。后续改 `core::ffi`/`core::slice` + 手写字节组装 + 栈缓冲 (`[u8; 128]` SHA-1 padding), 目标 binary < 3.0M (Δ vs 基线 < +1MB, 满足 ADR ≤+2MB)。**前置**: 完整回归 (cargo test 26/26 + e2e 79/79 + bench 不退化 + RSS 平台化) | ⬜ TODO | (DC2 后单独执行, 不与 DC1 验证耦合) |
| 9 | Track B 联动：bench.py / e2e_test.sh / build_single.sh 中 python3 清零（与 Rust bridge 并行，独立任务线） | ⬜ TODO | `*.py` = 0；`.venv` 移除 |

## 当前进度 (2026-09-04)

- **DC1 完成** ✅: ws.rs 上线, 26 单元测试绿; build_single.sh 已用
  `--whole-archive librust_bridge.a` 替代 ws.o (e2e 79/79, bench +35%, RSS 平台化)。
- **DC2 进行中** 🔶 (三轮累计):
  - **DC2-a 纯逻辑 (轮 1)**: `bridge/{parse,response,cmd}.rs` — 79 单元测试
  - **DC2-b I/O leaves (轮 2)**: `bridge/{time_util,port,signals}.rs` —
    `now_ms`/`get_configured_port`/信号处理器; 49 单元 + 3 `#[ignore]` 真信号集成
  - **DC2-c 配置 + listen socket + worker (轮 3)**: `bridge/{state,socket,init_workers}.rs` —
    `state` (timeout env 解析 + max_body/static_dir/last_status setters/getters);
    `socket` (create_bound_socket + SO_REUSEADDR/SO_REUSEPORT + bind/listen +
    setup_conn_fd + bound_port); `init_workers` (WorkerMode 单态枚举化 + fork/exec
    re-exec + worker_id), 加 `port::current_configured_port` 供 re-exec 读 `--port`;
    新增 37 单元测试 (state 22 / workers 8 / socket 5, 含 1 fork `#[ignore]`)
  - **累计**: `cargo test --release -- --test-threads=1` **230/230 全绿** (234 项,
    含 ws.rs 26 + signal/fork 集成 4 `#[ignore]` + **conn/deadlines 16**);
    `build_single.sh` 4.8M binary + ldd **仅 libc** (`-static-libgcc`); `e2e 79/79`
    绿; binary 体积零增长 (**5,000,720 字节严格不变**, 新增模块全 internal,
    无 `#[no_mangle]`, LTO 全 drop)
  - **本轮增量 (DC2-d)**: `bridge/conn/deadlines.rs` — 端口 C `check_deadlines`
    (§1028-1067) 的纯逻辑版. `DeadlineAction` 枚举 (None/WsPing/WsClose1000/
    Timeout408/CloseIdle) + `decide(phase, first_data_ms, last_data_ms,
    last_active_ms, &mut ws_strikes, ping_max, now_ms, recv_timeout_ms,
    idle_max_ms, max_request_ms)`. 16 单测覆盖 phase 0/1/2/3/4 各分支 + 阈值
    边界 (`>=`) + ping_max=0 禁用保活 + ping_max=2 进度 (1→Ping, 2→Ping,
    3→Close) + 时钟回拨 saturating_sub 防 underflow.
  - **本轮质量门禁实测**: `./benchmark.sh` run #15 get_root_10k_100c =
    **47281 req/s** vs C-only 基线 (run #13) 35829 req/s = **+32%**, 0 errors;
    RSS 平台化 16720→16208→16208→16208→16208 kB (2500 req), 无线性泄漏.
  - **本轮修复 (2026-09-04 收尾)**: conn 表 `alloc` 语义对齐 C (先扫空闲槽);
    `#[cfg(test)] sys_close` no-op (防测试误关真实 fd); conn_tests fd 避开
    0/1/2; `--test-threads=1` 标准化 (state_tests env 全局副作用).
  - **本轮增量 (DC2-e/f, 2026-09-04)**: `bridge/send.rs` (响应发送层, +13
    单测) + `bridge/ws_session_ffi.rs` (WS 会话 FFI, +15 单测) 落地。
    **send.rs**: send_all/send_response/send_error_json/send_simple_response/
    send_simple_response_allow/send_head_response/send_preflight_response/
    send_html_response/serve_static_file (realpath 防穿越 + O_NOFOLLOW + 1MB
    上限)/send_static_file/send_static_file_head; 真实 socketpair 逐字节验证。
    **ws_session_ffi.rs**: is_ws_upgrade/get_ws_key_slice/get_ws_protocol_offer_slice/
    ws_session_begin (真实 101)/ws_conn_upgrade/ws_event_type/get_ws_path_slice/
    ws_last_opcode/ws_payload_slice/ws_write_current/ws_write_text/ws_send_close/
    ws_message_done/ws_conn_close/get_ws_ping_max。
    **修复 3 个潜在 bug** (0 BUG 门禁):
      a) response.rs 头终止符三连 CRLF (改单 `\r\n`);
      b) send.rs 静态文件读空 (with_capacity len=0 陷阱, 改 vec![0u8; size]);
      c) ws_session_begin 传非 NUL 结尾 key 给 ws_handshake (补 push(0))。
    **实测门禁**: cargo test 269 (265 通过 + 4 #[ignore]); e2e 79/79;
    binary 5,000,720 B 不变; ldd 仅 libc。
  - **剩余 (下一轮)**: `recv_and_parse` 外层字节状态机 (phase 0/1/2/3/4 +
    slowloris) + `pump_conn`/`pump_ws_conn` + poll 事件循环 + `conn_done` +
    `bridge/io.rs` 主循环 + extern "C" FFI 包装 (~40 符号) + build_single.sh
    切换 (bridge.o → librust_bridge.a) + 全量 e2e + bench + RSS 泄漏门禁
    (**check_deadlines 已落 deadlines.rs**)
- **KIND_RUN_CMD 路由**: C 侧 `run_command_json` 已在 HEAD `7b33c26`
  (S253al) 提交 (含 fork+poll+timeout+256KiB cap, +187 LOC); Rust 版
  `bridge::cmd::run_command_json` (整组 SIGKILL 改进版) 已落地且 13 单测绿。
  C 副本待 bridge.o 下线时移除 (Rust 版接管)。
- **质量门禁**: 每轮 cargo test 必绿 + build_single.sh 成功 + e2e 79/79
  (C bridge 当前为生产路径, Rust bridge 暂未接线); 不宣称本轮 Rust
  bridge.rs 的 e2e/bench/leak 结果 (接线后下一轮验证)。

## 后续（不在本 ADR 范围）

- TLS/HTTPS（rustls 静态链接可行性评估，P3 观察）
- gzip 压缩（Rust `flate2` 静态链接评估，P3）
- HTTP/2（远期，不承诺）
- Mojo 工具链若提供静态运行时库（`--static-runtime`），评估 `shim.rs` 进一步收缩
