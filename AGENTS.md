# fastapi_mojo — Agent 工作指南

> 本文件是 AI Agent 在本仓库工作时的**最高优先级约束**。
> 任何代码修改、任务规划、架构决策都必须与本文件对齐。

---

## 1. 项目本标（North Star）

**最终交付物：用 Mojo + Rust 将代码编译成一个单一 Binary，运行时零外部依赖。**

| 维度 | 目标 |
|------|------|
| 编译产物 | 单个可执行文件（`fastapi_mojo` 或等价命名） |
| 运行时依赖 | **无** — 不依赖 Python、不依赖 pip 包、不依赖系统动态库（除 libc/libm 等基础运行时） |
| 实现语言 | **Mojo + Rust only**：应用/协议层 Mojo 原生，bridge/系统调用层 Rust staticlib（C ABI），**C 代码清零** |
| 部署方式 | `scp` / `docker COPY` 二进制即可运行 |
| 对标体验 | 类似 Go 编译产物：`./fastapi_mojo` 启动即服务 |

### 1.1 本标的约束力

- **任何引入新 Python 依赖的 PR 都是倒退**，必须被拒绝或标记为临时过渡方案。
- **任何依赖系统 Python 运行时的代码路径**，最终都必须被 Mojo 原生实现替换。
- **任何新增或保留的 C 代码路径都是倒退**：bridge 层终态必须是 Rust（staticlib +
  C ABI），`src/` 下 `*.c` 必须归零（ADR-0010，决策-19）。
- 当前 "Mojo wrapper 调 Python FastAPI" 是**引导阶段（bootstrap）**，不是终点；
  当前 "Mojo + C bridge" 是**迁移中间态**，bridge 语言终态是 Rust。

---

## 2. 当前阶段定位

| 阶段 | 状态 | 说明 |
|------|------|------|
| Phase 0: Wrapper 引导 | ✅ 完成 | Mojo 薄壳调 Python FastAPI（已拆除，历史阶段） |
| Phase 1: 核心组件 Mojo 化 | ✅ 完成 | HTTP server（C FFI 桥接）/ JSON / Router / 参数解析 全部原生 |
| Phase 2: 去 Python 化 | ✅ 完成 | 零 Python 运行期依赖；**Track B 工具链也已清零**（决策-22：`*.py`=0、`.venv` 删除、fmtool 替代 bench.py/e2e python 客户端） |
| Phase 3: 单 Binary 交付 | ✅ 已达成 | `./build_single.sh` 产出 `build/fastapi_mojo`，ldd 仅 libc |
| Phase 4: 去 C 化（Rust bridge）| ✅ **完成（Mojo + Rust only）** | `ws.c`（✅ 已删）/ `http_bridge_final.c`（✅ 已迁 Rust）/ `runtime_shim.c`（✅ 已迁 `bridge/shim.rs`，DC3）→ Rust staticlib（ADR-0010）；**`find src -name '*.c'` = 0，C 清零达成** |

**本标已达成（Phase 3）**：单一文件部署（scp 即运行）。实现机制见 `docs/adr/0003-single-binary-mechanism/`
（Mojo 1.0.0 无静态运行时库 → 嵌入 + 启动暂存 + dlopen 符号转发）。

> 注：bootstrap 时代（Phase 0）的 `fastapi/` git submodule（FastAPI 0.141.1 源码
> 参考）**已移除**（Phase 2 完成后不再需要；单一 binary 从未读取它）。
> 后续若需对照 FastAPI 语义，直接查上游仓库即可。
>
> 注2：bridge 层语言正从 C 迁移到 Rust（ADR-0010，决策-19）：FFI 表面（`extern "C"`
> 导出表）与架构分层完全不变，仅实现语言切换；`src/` 下 `*.c` 清零为 Phase 4 红线。

---

## 3. 架构约束（不可违背）

### 3.1 部署约束

- ✅ **允许**：Mojo 标准库、Mojo 社区包（可静态链接）、**Rust staticlib（C ABI，
  随 binary 静态链接；仅 libc/libm 等基础运行时）**
- ❌ **禁止**（最终形态）：Python 运行时、pip 包、`.venv`、系统动态库依赖、
  **C 代码（bridge 层终态必须 Rust）**
- ✅ **已达成**（Phase 4 终态）：bridge 层 100% Rust staticlib，**C 清零**
  （`find src -name '*.c'` = 0）。历史迁移：
  **DC1 ws.c → ws.rs ✅；DC2 http_bridge_final.c → bridge/* 15 子模块 +
  bridge/ffi.rs extern "C" 包装层 ✅；DC3 runtime_shim.c → bridge/shim.rs ✅**
  （embed/stage/dlopen/符号转发/孤儿 stage 清理/atexit）。历史 bootstrap 时代的
  Python interop 已拆除。

### 3.2 代码约束

- 每个 `.mojo` 文件 < 500 行（God package 阈值）；每个 Rust bridge 模块（`*.rs`）
  建议 < 500 行（超限拆子模块，标注拆分边界）
- `src/fastapi_mojo/` 只做 FastAPI 域，不混杂其他主题
- 当前运行期桥接是 **Rust staticlib**（`extern "C"` 导出，FFI 表面与既有 C bridge
  完全一致）：socket I/O / poll 事件循环 / CORS / 静态 / 限流 / 信号 / WS 会话状态
  / WS 协议原语 / 单 binary loader（运行时嵌入/暂存/dlopen 转发）。**C 源文件已
  全部清零**：`http_bridge_final.c` → `bridge/*` 15 子模块 + `bridge/ffi.rs` extern
  "C" 包装层（DC2 ✅）、`runtime_shim.c` → `bridge/shim.rs`（DC3 ✅）、`ws.c` →
  `ws.rs`（DC1 ✅）。Phase 0 的 `wrapper.mojo` 已拆除，未来新能力一律走 Rust
  bridge / Mojo 原生，不再引入 C。
- **build 链接守则（Rust bridge 实战教训）**：Rust staticlib 默认拉入
  `libgcc_s.so.1`（compiler-rt 内建函数如 `__udivti3`），破坏 North Star；`build_single.sh`
  必须用 `gcc -fPIE -pie -O2 -static-libgcc` 静态链接 libgcc_s，使 `ldd` 回归仅
  libc。新增 / 替换 Rust bridge 时若引新依赖，须再次核对 `ldd`。
- **测试 syscall 隔离（Rust bridge 实战教训）**：`bridge::conn` 的 `reset_for_close`
  调用真 `close(fd)`；单元测试必须用 `#[cfg(test)] sys_close` no-op（或同等隔离
  机制），避免合成 fd 误关 libtest 捕获管道 / stdio。
- **FFI NUL 终止契约（Rust bridge 实战教训，决策-36）**：Mojo `CStringSlice
  .as_bytes()` 按 C 串语义**读到首个 NUL，忽略 `fmc_slice.len`**（probe 实测：
  len=28 且无 NUL 的缓冲实读 50 字节，含相邻 static 垃圾）；因此 bridge 返回的
  **每个 `fmc_slice` 缓冲必须 `[len]=0`**。存量 slice 全量审计已 NUL 终止
  （决策-20 的 NUL 修复即此契约）；`run_command_json`（`malloc(n)+memcpy(n)`，
  C bridge 时代潜伏 bug）已修 `malloc(n+1)`+NUL。回归守护：`cargo test
  ffi_run_command_json_nul_terminated`。

- 测试文件与生产代码同目录

### 3.3 依赖方向

```
用户代码 → Mojo 原生实现 → (可选) Rust bridge（staticlib / C ABI）→ 操作系统
```

**Mojo 1.0.0 标准库缺口（socket/网络/静态运行时）由 Rust bridge 承载；桥接语言
终态 = Rust（决策-19）。**

---

## 4. 任务管理

- 使用 **beads-rust (`br`)** 管理任务，数据库在 `.beads/`
- ADR 在 `docs/adr/`，每个 ADR 必须包含 **6 条架构隔离约束声明**
- Benchmark 统一走 `./benchmark.sh`，禁止手写压测脚本
- **CI** (`.github/workflows/ci.yml`) 在每次 push/PR 到 main 时守护本标：
  单一 binary 构建（含 rust toolchain：`cargo build --release` 出 staticlib，
  `-static-libgcc` 静态链接 libgcc_s 保 ldd 干净，见 §3.2）
  + `ldd` 零依赖断言 + 干净环境 (`env -i`) 启动 + 单元测试（含 `cargo test --release
  -- --test-threads=1`，env 全局副作用需单线程）+ e2e (现 802 项, 79 项
  起扩展, 含 WebSocket 增强/并发/精化 + 参数约束面 CP（ADR-0029）+ 用户自定义中间件 MW（ADR-0030）
  + TestClient TC（ADR-0031）) +
  体积预算（中间态 ≤ 6M，终态 ≤ C + 2M）
  + **C 清零步骤**（终态门禁：`find src -name '*.c'` = 0；当前 Phase 4-5 为 INFO）

---

## 5. 关键风险与阻塞

| 风险 | 影响 | 当前状态 |
|------|------|---------|
| Mojo 1.0.0 无 `std.http`/`std.socket`/`std.net` | 无法原生实现 HTTP server | ✅ 已解除：Rust staticlib socket 桥接 + Mojo 原生协议层（C5，ADR-0001 决策-9；桥接语言已定 Rust，ADR-0010） |
| Mojo 无成熟 JSON 库 | 需自研或 FFI | ✅ 已解决：`json.mojo` 原生线性时间序列化，orjson 路径已删除（决策-10） |
| Mojo 异步/并发模型不稳定 | 高并发 HTTP server 实现难度 | ✅ 已解决：多进程 worker + SO_REUSEPORT（nginx pre-fork，ADR-0005） |
| 静态链接可行性未验证 | `mojo build` 是否真能产出无依赖 binary | ✅ 已验证：运行时嵌入 + 启动暂存 + dlopen 符号转发（ADR-0003，决策-14；shim 将迁 Rust） |
| C 清零可行性 | Rust staticlib 能否完全替换三份 C bridge | ✅ **已达成**（DC1/DC2/DC3）：`find src -name '*.c'` = 0；e2e 79/79 + ldd 仅 libc + env -i 干净启动门禁全绿 |

> 注：Mojo 1.0.0 标准库无网络模块的约束经 **Rust 桥接**绕过；单 Binary 零依赖本标
> 已达成（§2 Phase 3）。后续风险以新 ADR 跟踪。

---

## 6. 决议链速查

- **已决策-1~4**：wrapper 基础形态（见 `docs/adr/0001-mojo-replacement-strategy/`）
- **已决策-5 (C1)**：handler 业务逻辑由 Mojo 构造 lambda 源码
- **已决策-6 (C2)**：Mojo 构造 JSON + Response 包装
- **已决策-7 (C3)**：Mojo 路由表 + 批量注册
- **已决策-8 (C4)**：Path/Body 参数解析迁移到 Mojo
- **已决策-9 (C5)**：Mojo HTTP 服务器 — ✅ 达成（socket 桥接 + Mojo 原生协议层；
  Mojo 1.0.0 无网络模块的约束经桥接绕过；桥接语言终态 = Rust，ADR-0010）
- **已决策-10**：不自造 JSON 序列化，直接包 orjson — ✅ **已重审并替换**：json.mojo 原生线性时间序列化（orjson 路径已删除）
- **已决策-11**：.venv 环境隔离 — ✅ **已全部移除**（Track B 决策-22 达成）：服务器侧 + benchmark 工具链均不再需要 Python；仓库 `*.py` = 0，`.venv` 目录已删除
- **已决策-12**：异常 → JSON 响应（orjson 序列化）— ✅ **已替换**：错误响应由 json.mojo 原生构造
- **已决策-13**：**项目本标 = Mojo 单 Binary 零依赖部署**（本文件 §1）
- **已决策-14**：单一二进制实现机制 = 运行时嵌入 + 启动暂存 + dlopen 符号转发（见 ADR-0003）；构建入口 `./build_single.sh`，部署 `./deploy.sh`；shim 将迁 Rust（ADR-0010）
- **已决策-15**：WebSocket (RFC 6455) = 桥接协议层 `ws` + `/ws` echo 端点（见 ADR-0006）；不等待 Mojo 原生网络模块，与 C5 同一桥接绕过模式（语言：C → Rust，ADR-0010）
- **已决策-16**：WebSocket 增强 = Mojo 驱动会话循环 + WS 路由注册（`/ws` echo / `/ws/counter` 有状态 / `/ws/chat` 必需子协议）+ 子协议协商 + 服务端保活 ping（`FASTAPI_MOJO_WS_PING_MAX`）+ close 码校验（1002）/ text UTF-8 校验（1007）（见 ADR-0007）；桥接内 echo 循环（`ws_upgrade_and_echo`）移除，业务分派归 `run_ws_message` 单点 dispatch
- **已决策-17**：高并发 WebSocket = bridge poll 循环驱动 WS 会话（conn 阶段 3/4）+ FIFO 事件队列（数据帧逐条交 Mojo 分派）+ 控制帧/保活/UTF-8 校验桥接层自动处理（见 ADR-0008）；WS 会话不再阻塞 dispatch，多 WS 会话与 HTTP 并发（e2e：10 并发 + 空闲 WS 下探针 <1s）
- **已决策-18**：WebSocket 精化 = 合并帧尾块丢失 P0 修复（feed consumed 语义 + 每连接尾块重放 + `ws_pump_now` 立即重 pump）+ WS `{param}` 路由/参数分派 + 升级 token 鉴权（403）+ 重组缓冲按需增长（4KB→1MB）+ 事件队列结构上不可溢出（1008 防御）（见 ADR-0009）
- **已决策-19**：**Bridge 层语言终态 = Rust（Mojo + Rust only）** — Rust staticlib
  (C ABI) 替代全部 C bridge（`http_bridge_final.c` / `ws.c` / `runtime_shim.c` →
  Rust 模块）；FFI 表面 / 架构分层 / 单 binary 机制不变；`src/` 下 `*.c` 清零为
  Phase 4 验收红线（见 ADR-0010）
- **已决策-20**：**DC2-h `bridge/ffi.rs` extern "C" 包装层 + build 切换 + NUL 终止修复 ×3**
  （ADR-0010 §3 决策-4「FFI 包装延迟」兑现）：
  1. `bridge/ffi.rs`（413 LOC）— 41 个 `#[no_mangle] pub extern "C" fn` 包装层，
     对齐 C ABI（CSlice/fmc_slice、c_long/c_int、*const c_char），全部子模块 `as`
     别名避免与 `extern "C" fn` 同名冲突；`create_bound_socket` 内部调
     `io_set_listen_fd(fd)`（C 语义 `g_listen_fd=fd`），`run_command_json` 走
     `malloc + memcpy` + `run_command_free` 走 libc free（与 C bridge 内存契约一致）。
  2. **`build_single.sh` 已切换**：注释 `gcc -c http_bridge_final.c -o bridge.o` +
     链接行去除 `bridge.o`，`--whole-archive librust_bridge.a` 提供同名 `extern "C"`
     符号，无缝替换 C 实现（**bridge.o 已下线**，C 文本待 DC3 删）。
  3. **NUL 终止修复 ×3（防御 Mojo `CStringSlice.as_bytes()` 读到 NUL 为止的硬性约束）**：
     - `set_http_fields` 写 `g.method[mlen]=0 / g.path[plen]=0 / g.query[qlen]=0`
       + `min(MAX_*-1)` 防 OOB（keep-alive 路径污染修复）；
     - `ws_conn_upgrade` 写 `c.ws_path.push(0)` + slice 剥尾（WS 路由修复）；
     - `get_ws_protocol_offer_slice` 写 `offer.push(0)` + len 不含 NUL +
       **FFI export routing 修正**（原 `get_ws_protocol_slice` 错路由到
       `request::get_ws_protocol_slice` 服务器选中值，正确目标是
       `ws_session_ffi::get_ws_protocol_offer_slice` 客户端 offer，WS 子协议协商 400
       bug 修复）；
     - `apply_request_header` body `resize(content_length + 1)` NUL 槽（POST body
       读越界修复）。
  验收：0 BUG / 0 警告 / **281 cargo 单测全绿（285 含 4 #[ignore]）** / e2e 79/79 绿 /
  bench run#16 = 43,802 req/s（**+22%** vs C-only 基线 35,829） / RSS 平台化
  16624→16972 kB / env -i 干净启动 / binary 5.1M（CI 预算 ≤6M） / ldd 仅 libc；
  C 工作树剩 2169 LOC（http_bridge_final.c 1809 + runtime_shim.c 360，
  bridge.o 已死代码）。
- **已决策-21**：**DC3 `bridge/shim.rs` 端口 `runtime_shim.c` 360 LOC + C 清零**
  （ADR-0010 终态门禁）：
  1. **`bridge/shim.rs`（374 LOC + `build.rs` 80 LOC）** — 端口 runtime_shim.c
     全套：`stage_embedded_statics` / `try_run` / `bind_symbols` / `remove_all_staged`
     / `sweep_orphaned_stages` / `atexit(runtime_cleanup)`。3 个 objcopy payload
     符号（`_binary_payload_{kgen,msupp,asyncrt}_bin_{start,end}`）用
     `extern "C" { static : u8 }` 声明（文件名派生，确定性符号名）；嵌入
     static 文件（index.html / test.json）符号由 **build.rs** 读
     `SHIM_STATIC_N / SHIM_STATIC_<i>_{NAME,START,END}` env 变量（build_single.sh
     注入），生成 `$OUT_DIR/shim_static_gen.rs`（extern 声明 + `embedded_static_files()`
     fn 返回 `Vec<(&str, *const u8, *const u8)>`）。11 个 `KGEN_CompilerRT_*` 转发函数
     用 macro 批量定义（`#[no_mangle] pub unsafe extern "C" fn ...`），6-register
     SysV ABI-safe（与 C 6-register forwarder 等价）。
  2. **构造函数**：`#[used] #[link_section = ".init_array"] static SHIM_BOOTSTRAP: unsafe extern "C" fn() = kgen_runtime_bootstrap`
     （实测 server.o 无 .init_array / 无 .preinit_array，Mojo KGEN 调用为 lazy，
     在 main 首次 dispatch 才触发，故 shim 在 .init_array 即可保证早于 KGEN 首次引用）。
  3. **孤儿 stage 目录 self-heal 修复**：原 C 版 `unlink + 一级 rmdir` 对含 `static/`
     子目录的孤儿清理失败（残留 `static/`）；Rust 版改用 `fs::remove_dir_all` 一次性
     递归清干净（实测：22 孤儿 → 0，atexit 后再 → 0）。
  4. **`build_single.sh` 切换**：移除 `gcc -fPIC -O2 -Wall -c "$SRC/runtime_shim.c" -o "$BUILD/shim.o"` +
     链接行去除 `"$BUILD/shim.o"`；`env SHIM_STATIC_* cargo build` 注入 static 符号名。
  5. **C 清零达成**：`git rm src/fastapi_mojo/{http_bridge_final,runtime_shim}.c`，
     `find src -name '*.c'` = 0；**终态 Mojo + Rust only**。
  6. **单测隔离**：shim.rs 用 `#[cfg(test)] mod test_payload_stubs` 提供 6 个
     `#[no_mangle] static _binary_payload_*_bin_{start,end}: u8 = 0` stub 满足链接器；
     `#[cfg(not(test))]` 守住构造函数不注册到 .init_array（避免单测触发真实 staging）。
  验收：0 BUG / 0 警告 / **281 cargo 单测全绿（285 含 4 #[ignore]）** / e2e 79/79 绿 /
  bench run#18 = 43,878 req/s（vs C-only 基线 35,829 = **+22%**，无回归） / RSS 平台化
  16528→16868 kB / env -i 干净启动 / binary 5.2M（CI 预算 ≤6M） / ldd 仅 libc /
  `find src -name '*.c'` = **0** / **orphan sweep: 22 → 1 → 0**（启动扫 + atexit 清）。

---

- **已决策-22**：**Track B 工具链全链路去 Python（e2e + bench + build 全部达成）** —
  `fmtool`（`src/fmtool/` 独立 Rust crate，零第三方依赖，panic="abort"，opt-level="z"，
  与 fastapi_mojo_rs 同 pin 1.97.1）替代原 e2e/bench 的 Python socket + WS 客户端：
  1. **`scripts/e2e_test.sh`**（T2）: 0 处 `python3` 执行调用（原 17 处）；shell
     `head -c … | tr '\0' x` 生成大 payload；`printf … | od -An -tx1 -v | tr -d ' \n'`
     生成畸形字节 hex（**od 必须 `-v`**，否则 17KB 重复行被 `*` 压缩导致 hex 损坏）；
     `fmtool raw/cont100/keepalive/headbody/ws1..ws4/slowloris` 替代原 Python 客户端；
     e2e 79/79 全绿（实测 ~23s，零 Python）。
  2. **`benchmark.sh`**（T1）: `git rm bench.py`，改调 `fmtool bench`；内置 Rust WS
     负载（`wsbench` 子命令独立输出 hey-csv 同构行；e2e 与 bench 共用 `ws.rs`
     handshake + 帧解析 + SHA-1/base64/掩码/xorshift PRNG）；hey csv 解析 + 统计 +
     JSON/Markdown 输出 + **JSONL 历史**（`docs/reports/auto/benchmark.jsonl`，
     替代原 SQLite `benchmark.db`，零第三方依赖）；实测 6 场景 0 errors，
     get_root_10k_100c ≈ 39.5k req/s（无回归）。
  3. **`build_single.sh`**（T3）: shell-only auto-detect `$MODULAR_LIB`
     （PEP 370 + pip --user + system + conda + bounded `find` 兜底，`python3 -c
     'import modular'` 路径删除）。
  4. **`.venv/` 删除** + `docs/reports/auto/benchmark.db` `git rm`（SQLite 历史停更，
     JSONL 接管）。
  5. **`src/fmtool` 子 crate**（pure std）：`net.rs` TCP helpers / `ws.rs`
     （SHA-1/base64/xorshift/WS 帧）/ `csv.rs` 极小 CSV 解析（hey csv 适配）/
     `json.rs` 手写最小 JSON 解析+序列化（scenarios 输入 + 自有 JSON/Markdown 输出）/
     `e2e.rs`（10 个 e2e 子命令）/ `bench.rs`（server 生命周期 / hey 调起 / 统计 /
     JSON/Markdown / JSONL 历史）；`fmtool` ldd 仅 libc+libgcc_s（**dev tool，非运行期
     交付物**，libgcc_s 可接受；`build/fastapi_mojo` ldd 仍仅 libc）。
  6. **CI**: e2e step 自动 build fmtool（`scripts/e2e_test.sh` 内 `cargo build --release`）；
     `Export MODULAR_LIB` step 保留（CI ubuntu setup-python 装 modular 到
     `/opt/hostedtoolcache/…` 不在 auto-detect 候选，属工具链安装合法用法，
     "CI 里 Mojo 安装仍可借 python-pip"）；`git grep python3` 仅剩路径字符串/注释。
  验收：e2e 79/79 绿 / bench 0 errors / ldd 仍仅 libc / env -i 干净启动 /
  `find . -name "*.py"`（excl `.git docs`）= 0 / `.venv` 不存在 / `src/` 下 `*.c` = 0 /
  `build/fastapi_mojo` 仍 5.2M。
- **已决策-23**：**质量门禁 0 警告 0 BUG 闭环（fmtool + fastapi_mojo_rs 全量 clippy -D warnings + SHA1 级联 BUG 修复）**：
  1. **fmtool 22→0 警告**（决策-22 后剩余 clippy lint）：
     - 前序 47 处 `io::Error::new(ErrorKind::Other, x)` → `io::Error::other(x)` 已完成；
     - 本轮补齐 22 条 —— redundant_closure x7（main.rs `|p| e2e::fn(p)` → `e2e::fn`）+
       vec![] 替代 push x2 + explicit_counter_loop x2 + match→unwrap_or_default +
       type alias x2（`WsConnectResult` / `HandshakeResult`）+ is_multiple_of +
       div_ceil（base64 容量）+ iter_mut enumerate（SHA1）+ match→? + strip_prefix +
       Display format + `let mut root` → `let root`。
  2. **fastapi_mojo_rs 69→0 警告**（首次对 bridge crate 跑 clippy 暴露的存量）：
     - **lib 根 `#![allow(clippy::not_unsafe_ptr_arg_deref)]` 38 条**：本 crate 的 `pub` 函数
       绝大多数是 `#[no_mangle] extern "C"` 导出（~40 个，与原 C bridge 同名对齐），
       指针有效性由 Mojo C ABI 调用契约保证；按 FFI glue 标准做法（libc / nix 等同模式）
       在 lib 根 allow 而非逐函数标 `unsafe`（后者会污染 50+ 个 Rust 单测调用点）。
     - doc 注释 x13（mod.rs/send.rs 列表项续行缩进 + io.rs sys_recv/sys_accept 返回码
       改 backtick inline code + response.rs/request.rs 边界修正）；
     - impl Default for ConnTable/WsEventQueue/WsParser（避免重写 new() 逻辑）；
     - 机械：is_ascii_uppercase / while_let→for / `c"..."` 字面量（shim.rs:327）/
       `add(len)` 替代 `offset(len as isize)` / range contains x3 / collapsible_if x2 /
       needless_range_loop x2；测试 3 条（needless_borrow / `<= MAX-1` → `< MAX` /
       expect(&format!) 拆局部变量）。
  3. **🔴 SHA1 顺序依赖 BUG（实测 catch + 修复）**：clippy 让 SHA1 `w[16..80]` 循环
     改 iter_mut 时遇到借用冲突，本想用预计算 + 回写绕过（`new_w[k] = w[i-3] ^ ...`
     全用旧 w），跑测试立刻 FAIL —— `sha1_abc` / `sha1_fox` / `sha1_empty` /
     `compute_accept_rfc6455_example` / `ws_session_begin_sends_101` 共 5 个测试红。
     **根因**：w[i] 依赖 w[i-3]，而 i ≥ 19 时 w[i-3] 是**刚算的新值**，原预计算用旧
     值导致语义丢失。**修复**：级联预计算，每次 w[i-3] 优先读 new_w（已算）否则 w（未算）；
     `if k >= 3 { new_w[k-3] } else { w[k+13] }`（k = i-16），保持原算法语义同时满足
     borrow checker。**5 测试重测全绿**。**教训**：clippy 重构会改变算法"算法等价"
     假设 → 必须用真实向量测试覆盖（RFC 6455 known vectors、abc/fox/empty）。
  4. **验收门禁实测**：
     - `cargo clippy --release --tests -D warnings` 双 crate = **0 警告** ✅
     - `cargo test --release -- --test-threads=1` (fastapi_mojo_rs) = **281 passed / 0 failed / 4 ignored**（0.22s）
     - `cargo build --release --tests -D warnings` = 0 警告 ✅
     - `./scripts/e2e_test.sh` = **79/79 全绿** ✅
     - `./benchmark.sh` = 6 场景 **0 errors**；get_root_10k_100c ≈ 39.4k req/s
       （vs Rust-only 基线 43.9k 噪声内 / vs C-only 基线 35.8k = +10%；无退化）
     - `ldd build/fastapi_mojo` 仅 libc；`env -i ./build/fastapi_mojo` 干净启动 health 200
     - RSS 平台化 17024→17064→17080→17080→**17080 kB**（1000 req，round3 起稳定 +0 kB，
       无线性泄漏）
     - `pgrep -x fastapi_mojo = 0`（无孤儿 server）
  5. **质量闭环意义**：clippy -D warnings + cargo test + e2e + bench + RSS + ldd + env-i
     七门禁全部实测达成；本 goal 北极星（Mojo + Rust only 单 binary 零依赖）= **可发布
     状态**（tag 待发）。建议下一版本为 **v0.4.0**（minor bump：Mojo+Rust only 框架
     终态 + 质量门禁闭环，控制面仍可锁 v0.3.1 互不影响）。

- **已决策-24**：**Goal-0002 全部 8 项 F1-F8 达成，v0.5.0 可发布**
  （FastAPI 语义对标切片 v0.5.0）：
  - **F1 类型化 Path/Query 参数 + 422 校验**：int/float/bool 转换 + 默认值 + 必填缺失→422；e2e 87/87
  - **F2 HTTPException + 统一 `{detail,status}` 错误体**：exceptions.mojo + dispatch error_map；e2e 93/93
  - **F3 Request/Response + 嵌套 JSON + 修复 405 body hang**（response.rs 头部终止符 BUG）：e2e 101/101
  - **F4 OpenAPI 3.0 + Swagger UI**（/docs 内嵌）：openapi.mojo 自动从路由表+类型标注生成 spec；e2e 107/107
  - **F5 Streaming Response / SSE**（`format_sse_event` 行切分合规）：streaming.mojo + send_sse_response FFI；e2e 112/112
  - **F6 /metrics Prometheus 文本**：bridge/metrics.rs 原子计数器（无锁、无第三方）+ text/plain；e2e 117/117
  - **F7 结构化 access log**：见决策-25
  - **F8 Binary 体积瘦身**：见决策-26
  - **总 e2e：117/117 → 118/118 全绿**（F7 新增 1 例）；**bench run#N** = 0 errors，get_root_10k_100c ≈ 32.9k req/s
- **已决策-25**：**结构化 access log (JSON 行)** — `FASTAPI_MOJO_ACCESS_LOG=json`
  env 一次性读取（OnceLock 缓存），Mojo 侧 `_json_escape()` 转义 `\` / `"` /
  `
` / `
` / `	` / 控制字符，输出单行 JSON `{req_id,method,path,status,duration_ms}`，
  兼容现有 text 模式（默认）；bridge `get_access_log_mode()` FFI 导出；
  e2e 新增 1 例（副 server + 验证 JSON 行 schema）= 118/118 全绿
- **已决策-26**：**Binary 体积瘦身（strip 路线，优于去 std 化）** —
  `strip --strip-unneeded` 接入 `build_single.sh` 第 5/6 阶段。
  - **5,492,408 B → 2,809,736 B**（**-49%，远低于 ≤4.2M 目标 33% 余量**）
  - `.text`/.rodata`/`.data` 体积无变化（payload 不变，1.95 MB Mojo runtime）；
  - 仅删除 ELF `.symtab` / `.strtab` / `.debug_*` 节
  - **未触发任何回退**：ldd 仍仅 libc；env -i 仍干净启动；e2e 118/118 全绿
  - **为何选 strip 而非去 std 化**：bridge 已零第三方依赖（SHA-1/base64/UTF-8 手写），
    core::ffi 是 noop 替换；strip 直接去 ELF 元数据是 -49% 的零代码改动路径。
  - **未来仍有 -200 KB 空间**：UPX 压缩（额外启动时解压开销 ~10 ms），待 v0.5.1 评估。

- **已决策-27**：**F9 SSE 自定义 status_code + extra 头（v0.5.1，对齐上游 FastAPI 0.140.13 PR #15937）**：
  1. **上游 bug**：SSE/JSONL streaming 端点忽略路由声明的 `status_code`，永远返回 200，
     与 OpenAPI 文档矛盾。PR #15937 by @SAURBHSALVE 用 `_build_response_args(status_code, solved_result)`
     透传状态码（2026-07-28 merge）。
  2. **Rust 新 API**：`send_sse_response_extra(fd, status, body, extra)` —— 与
     `send_simple_response_extra` 同一签名风格（status + extra 头统一透传）；
     `send_sse_response(fd, body)` 保留为 v0.5.0 兼容入口（硬编码 200 OK）。
  3. **Mojo dispatch 扩展点**：
     - `data["_stream_status"] = "201 Created"` —— handler 声明式自定义 status_code
     - `data["_response_headers"] = "Cache-Control: no-cache;X-Accel-Buffering: no"`
       —— 多头用 `;` 分隔（对齐 `parse_response_headers` 文档约定）
  4. **额外收益 —— 修复 v0.5.0 静默丢弃缺陷**：原 `_response_headers` 被 dispatch 解析
     成 `sse_extra` 但**从未发送**（注释承认"退化跳过"）。F9 一并修复，demo `/sse/created`
     实测响应头含 `Cache-Control: no-cache` + `X-Accel-Buffering: no`。
  5. **质量门禁实测**：Rust bridge **287 单测 / 0 BUG**（F9 新增 4 测：自定义 status 201 /
     自定义 status 202 / extra 头透传 / 旧入口仍 200 兼容）；clippy `-D warnings --tests` **0 警告**；
     e2e **124/124 全绿**（v0.5.0 118 + F9 新增 6 测：201 status / content-type / Cache-Control /
     X-Accel-Buffering / body intact / 默认 200 回归）；bench 6 场景 0 errors；ldd 仅 libc；
     env -i 干净启动；binary **2.7M**（≤4.2M 目标）；RSS 平台化 3 rounds 无线性泄漏。



- **已决策-28**：**F10 Header/Cookie/Form 参数注入（v0.5.1，对标矩阵 P3 缺口闭环）**：
  1. **F10a Cookie 参数（dispatch 接线 `_reads_cookies`）**：v0.5.0 已实现 `_parse_cookies` +
     `_collect_reads` 但 dispatch 从未调用（dead code）。本改动新增 `inject_request_cookies`
     并接线到 dispatch（`_reads_cookies` CSV → `params["cookie_<name>"]`），复用
     `extract_request_header("Cookie")` FFI（已有）+ 本地 `_parse_cookies`（RFC 6265 简化：
     `;` 分隔 `=` 切，去前导空格）。**Bug 修复**：初版 `start = i + 1` 放在 while-loop 顶层
     而非 `if is_sep:` 内，导致 `start` 始终 > `i`、`i > start` 永远 false，注入空跑。
     移到 `if is_sep:` 内并加显式 if/elif 替代 `or` 短路后修复。
  2. **F10b Form 参数（application/x-www-form-urlencoded body 解析）**：新增 `inject_form_fields`
     + `_parse_form_body`（`&` 分隔 `=` 切，复用 `url_decode` 处理 `%XX` + `+` → space）；
     与 `inject_request_cookies` 同模式（CSV split → dict lookup）。兼容裸 key（无 `=`，值空串，
     FastAPI 一致）与 URL-encoded 值（`pass%40word` → `pass@word`）。
  3. **F3a Header 参数**：v0.5.0 已实现 `inject_request_headers`（`_reads_headers` CSV →
     `params["header_<name>"]`），无需新增。
  4. **demo + 路由**：`/cookies`（GET，Cookie 演示）+ `/login`（POST，Form 演示）+ 既有
     `/ctx`（GET，Header 演示）。三者覆盖 P3 缺口。
  5. **质量门禁实测**：Rust bridge **287 单测 / 0 BUG**（F10 复用既有 helpers，无新单测）；
     clippy `-D warnings --tests` **0 警告**；e2e **133/133 全绿**（v0.5.0 118 + F9 6 + F10a 5
     + F10b 4 = 133）；bench 6 场景 0 errors；ldd 仅 libc；env -i 干净启动；binary **2.7M**
     （≤4.2M）。
- **已决策-29**：**F11 BackgroundTasks（v0.5.1，进程内队列）**：
  1. **语义对齐 FastAPI/Starlette**：Starlette `BackgroundTask(func, *args)` 在响应已
     flush 后在同一 event loop await func；本实现响应已 flush 后同步执行 shell 命令
     （复用 `run_command_json` FFI，fork+poll+timeout 已在 bridge/cmd.rs），客户端已收到响应。
  2. **API（声明式，延续 handler.data 模式）**：
     - `data["_background"] = "cmd1\ncmd2"`（换行分隔，命令内不允许含换行）
     - `data["_background_timeout_ms"] = "2000"`（单条命令 timeout，默认 2000ms）
     - `data["_background_log"] = "false"`（默认 true：`[bg]` 日志输出 stdout/stderr/rc）
  3. **实现**：`_run_background` helper + dispatch 主 JSON 分支 hook（响应已 flush 后、
     conn_done 前）；不 fork/zombie —— 同步执行符合 Starlette 语义，pre-fork 多 worker +
     SO_REUSEPORT 隔离 worker 阻塞，timeout 防无限挂。命令切分按 `\n`（与 SSE `|` /
     header `,` 分隔约定一致）。
  4. **demo**：`/bg-write` 响应立即返回（HTTP_TIME 0.3ms），后台 `date` 写 /tmp/bg_test.log。
  5. **质量门禁实测**：e2e **136/136**（+3：响应立即 / bg 命令在响应后执行 / server log 含 `[bg]`）；
     cargo test 287 单测 / 0 BUG；clippy `-D warnings --tests` 0 警告；bench 0 errors；
     ldd 仅 libc；binary 2.7M（≤4.2M）。

- **已决策-30**：**UPX 压缩评估（v0.5.1 G3 调研，结论 = 不进默认构建，仅作可选手动部署；2026-09-12 复评见决策-65）**：
  1. **实测数据**（UPX 5.2.1，`-9` best 压缩）：
     - **2,850,696 B → 1,011,584 B（-64.5%，1.01 MB）**
     - 启动时间：13-16ms baseline → 22-29ms compressed（**+10ms，+65%**，一次性 UPX 解压成本）
     - e2e 136/136 全绿（功能无差异）
     - **致命问题**：`ldd build/fastapi_mojo` 输出 `not a dynamic executable`，
       破坏 CI 的 North Star ldd 门禁（CI `.github/workflows/ci.yml` 要求 `libc.so` 行）。
  2. **决策**：**不进入 `./build_single.sh` 默认构建**。新增 `./compress_upx.sh` 作为可选
     手动部署脚本（仅当手动部署到磁盘极紧张场景），备份原文件到 `build/fastapi_mojo.pre-upx`。
  3. **理由**：
     - ldd 门禁是 North Star 核心验收（AGENTS.md §1 零依赖本标），不可妥协。
     - +10ms 启动对单 binary 服务器（启动一次、长期运行）无感，但 ldd 门禁是硬约束。
     - 1.01 MB 已经足够小（远低于"4.2M 目标 76% 余量"），无强需求做 UPX。
     - 可选部署路径保留：用户在 CI 之外手动 `./compress_upx.sh` 仍可拿到 1MB binary。
  4. **替代方案对比**：
     - **strip（当前默认）**：5.5M → 2.7M（-49%），ldd 仍正常工作（已采纳，决策-26）。
     - **UPX**：2.7M → 1.0M（额外 -64%），但 ldd 失效。性价比不抵破坏 CI 门禁。
     - 未来如需进一步压缩：考虑 `--gc-sections`（裁剪未用节，~10-30KB），不破坏 ldd。


- **已决策-31**：**G3 生产化交付（Docker + systemd + nginx）**：
  `Dockerfile`（ubuntu:24.04 nonroot，host glibc 2.39 binary 直跑）/
  `Dockerfile.full`（容器内构建路径：mojo==1.0.0 pip wheel + rust 工具链）/
  `docker-compose.yml`（端口 8080→8000，/dev/shm:exec tmpfs 128M，JSON access
  log，restart unless-stopped）/ `systemd/fastapi_mojo.service`（硬化 unit：
  NoNewPrivileges / ProtectSystem / ProtectHome / LimitNOFILE 65536 /
  Restart=on-failure）/ `docs/deploy-nginx.md`（反代 + SSE `proxy_buffering off`
  + WS `Connection upgrade` + 5 项常见坑）。关键修复：glibc 2.36（distroless
  cc-debian12）无法加载 Rust std `pidfd_spawnp` 符号 → runtime 改 ubuntu:24.04；
  Mojo 1.0.0 包名实为 `mojo==1.0.0` wheel（`modular==0.10.1` 已下线）；Docker
  默认 /dev/shm noexec 致 Mojo runtime dlopen 失败 → compose tmpfs exec 消除。
- **已决策-32**：**Multipart/form-data 文件上传（Rust bridge parser，G3-v0.7）**：
  `bridge/multipart.rs`（`&[u8]` body 解析：parts/name/filename/content_type/
  body/body_b64）+ io.rs multipart-aware 解析（RFC 2046/7578：multipart body
  跳过 UTF-8 校验）+ ffi.rs `mp_*` 导出 + `/upload` dispatch
  （`inject_multipart_fields`：文本字段 → `form_<name>`，文件字段 →
  `file_<name>_filename/_size/_content_type/_body_b64`）；二进制/非法 UTF-8 文件
  body 保留，中文文件名/文本字段走 `decode_utf8_bytes`。修复尾行 trim bug
  （trim 掉文件自身合法的尾部 \n 破坏 b64 往返，MP1 catch）。e2e MP1..MP7。
- **已决策-33**：**Depends 嵌套依赖解析（F-DI）**：`_collect_reads` 支持多层
  依赖（如 `get_auth_get_config_version`）；handler.data 中非 `_` 前缀字段
  即依赖注入段；递归依赖解析（循环检测）；dispatch 在触发 handler 前调用
  `resolve_depends` 解析 `_depends` 注入（对齐 FastAPI Depends 嵌套/共享状态）。
- **已决策-34**：**FastAPI 安全/认证（HTTPBasic/HTTPBearer/APIKey）— 声明式 +
  单一 dispatch 钩子**（ADR-0011，Goal-0003 P0）：
  1. 声明式：`_auth`（basic/bearer/apikey:header|query|cookie:<name>）+
     `_auth_users`（user:pass CSV）+ `_auth_tokens`（token CSV）+ `_auth_realm`。
  2. 语义对齐 FastAPI/Starlette：失败 → 401 + `WWW-Authenticate`（basic/bearer；
     apikey 无）；成功 → 注入 `auth_user` / `auth_token` / `auth_apikey`。
  3. base64 解码纯 Mojo（`security.mojo`：6-bit 累加 + 掩码防 64-bit Int 溢出；
     RFC 4648 标准/URL-safe 双字母表）；UTF-8 边界安全（codepoint 边界找 `:`）。
  4. 单一 dispatch 钩子：`check_auth(handler, query_values) -> AuthResult`
     是唯一「认识认证」的函数（F1 类型化参数校验**之前**短路）。
  验收：e2e SEC-* 13 项；零新增 FFI（复用 `extract_request_header`）。
- **已决策-35**：**response_model 响应字段过滤（基础版）**：声明式
  `_response_model = "f1,f2"`（CSV，与 `_split_csv` 同 sep），响应仅保留声明
  字段（过滤 meta 字段与未声明字段）；`/profile` demo；未声明时保持原样
  （含 meta，回归 RM-4）。exclude/include/none 精化归 P2。
- **已决策-36**：**Lifespan（startup/shutdown）= 声明式 env 命令 + FFI NUL
  终止契约（发现并修复）**（ADR-0012，Goal-0003 P1 T-P1c）：
  1. **声明式 API**：`FASTAPI_MOJO_LIFESPAN_STARTUP` / `..._SHUTDOWN`（换行
     分隔 shell 命令）+ `..._TIMEOUT_MS`（默认 30000）；经 `run_command_json`
     FFI 执行（与 F11 同一机制：/bin/sh -c + fork/poll + 进程组 timeout kill）。
  2. **语义对齐 FastAPI/uvicorn**：startup 在 bind 后、serve 前（任一命令
     rc≠0 → `bridge_fail`，服务不启动）；shutdown 在 `serve_forever` 返回后
     （失败只记日志）；多 worker 仅主进程执行（`worker_id=0`，nginx master
     init 语义；re-exec worker 跳过，避免 N 倍重复执行）。
  3. **🔴 NUL 终止契约（probe 发现 + 修复 ×2）**：Mojo `CStringSlice
     .as_bytes()` 按 C 串语义读到首个 NUL、**忽略 `fmc_slice.len`**（实测
     len=28 无 NUL 实读 50 字节含相邻 static 垃圾）→ bridge 返回的每个
     fmc_slice 缓冲必须 `[len]=0`。存量 slice 全量审计已 NUL 终止（决策-20）；
     **修复**：`run_command_json` `malloc(n)` → `malloc(n+1)`+NUL（C 时代潜伏
     bug：F11 `out=` 日志尾部一直带堆垃圾）+ lifespan env 串尾 NUL
     （`OnceLock<Vec<u8>>`，len 不含 NUL）。回归守护：`cargo test
     ffi_run_command_json_nul_terminated`。
  4. **布局**：Rust `bridge/lifespan.rs`（env OnceLock + 3 新 FFI 导出
     `get_lifespan_startup_slice` / `get_lifespan_shutdown_slice` /
     `get_lifespan_timeout_ms`）+ Mojo `lifespan.mojo`（140 LOC：rc 解析 /
     命令切分执行 / 失败短路 / main() 自测）；核心 `http_server_final` 仅
     +1 import + 2 调用点（`main()` bind 后 / serve 后），**dispatch 零改动**。
  验收：e2e **168/168**（+LS-1..4）/ cargo test **307 passed / 0 failed /
  4 ignored** / clippy `-D warnings` 0 警告 / 多 worker 8 轮 stress（startup
  恰好 1 次、无崩溃、命令零损坏、无孤儿）/ ldd 仅 libc / binary 2.9M（≤4.2M）。

- **已决策-37**：**APIRouter = prefix/tags/dependencies + include_router
  （include 时合并，dispatch 零改动）**（ADR-0013，Goal-0003 P1 T-P1b）：
  1. **API**（router.mojo）：`Router` 扩展 `prefix` / `tags`（CSV）/
     `base_deps`（';'-CSV，与 `_depends` 同格式）+ setter；
     `include_router(sub, prefix="", tags="", deps="") raises` 把 sub 的
     HTTP 路由 + WS 路由 + 依赖表合并进 self。
  2. **三层合并（FastAPI 叠加序）**：path = `_join_path(include_prefix,
     sub.prefix, route.path)`（前导 / 保证、无 `//`、尾 / 去除、根路由 `/`
     归一到 prefix）；tags = include `,` router `,` 路由 `_tags`（CSV）；
     deps = include `;` router `;` 路由 `_depends`（';'-CSV）→ 全写入
     `handler.data`，**dispatch 主循环零改动**（决策-33 `_depends` 机制自动
     注入 `<depname>_<key>`）。
  3. **OpenAPI 配套**（openapi.mojo）：操作级 `"tags":["a","b"]` 输出 +
     **path 分组**（同 path 多 method 合并进单个 key）—— 修复**既有**重复
     key 产生非法 JSON 的 bug（`/items` GET+POST 原输出两个 `"/items":` key）。
  4. **demo**（http_server_final.mojo）：`items_api`（prefix `/api/items` +
     tags + base dep `api_env`）/ `v1_api`（include 级 prefix `/v1`）/
     `ws_api`（WS prefix → `/api/ws/echo`）；路由用 **KIND_ECHO**（ECHO 过滤
     `_` 前缀内部字段，避免 `_tags`/`_depends` 泄漏响应体；KIND_STATIC 全量
     dump 为既有行为，不在本决策改动——`__nested__:` 前缀同样以 `_` 开头，
     naive 过滤不可行）。
  5. **零 FFI 改动**：全部合并逻辑在 Mojo 注册期完成，Rust bridge 对
     APIRouter 无感知（FFI diff = 0）。
  验收：e2e **180/180**（+AR-1..8 共 12 项：状态码/body/base 依赖注入/根路由
  归一/include prefix/无前缀回归/OpenAPI tags/`/items` key 分组 = 1/WS 端到端）/
  cargo test **307 passed / 0 failed / 4 ignored** / clippy `-D warnings` 0 警告 /
  bench 6 场景 0 errors（get_root_10k_100c ≈ 37.9k req/s，无回归）/
  ldd 仅 libc / binary 2.9M（≤4.2M）/ router.mojo 472 LOC（<500）。

- **已决策-38**：**Pydantic 式 body 校验 + Field 约束 + Enum（声明式 spec，
  统一 FastAPI 422 detail）**（ADR-0014，Goal-0003 P1 T-P1d+T-P1e）：
  1. **`_body_schema` 声明式 spec**（body_schema.mojo 315 LOC = spec 层）：
     `字段:type[=默认][|约束]`，类型 str/int/float/bool/obj/arr + `T[]`
     （数组）+ `T[v1,v2]`（enum）+ `obj{子spec}`（嵌套递归同一文法）；
     约束 `gt/ge/lt/le=N` / `len=N-M` / `items=N-M`；畸形 spec 注册期
     `check_body_schemas` fail-fast（启动即 fail）。
  2. **统一 422 detail（FastAPI/Pydantic v2，全错误收集）**（body_validate.mojo
     313 LOC = 校验层 + 21 项 `check()` 真断言自测）：参数校验改 collect 模式
     （`validate_params_collect`，loc `["path"/"query",x]`）+ body 校验
     （loc `["body",x]` / 嵌套 `["body","meta","city"]` / 元素
     `["body","tags",0]`）→ dispatch 单点合并 `{"detail":[{loc,msg,type}...]}`
     （`__nested__:` 直通，复用既有机制）；msg/type 对齐 Pydantic v2
     （field required/greater_than/enum/float_parsing/string_too_short/
     too_long/json_invalid...）。
  3. **Enum 参数（T-P1e）**：`_param_types` 支持 `T[values](=default)`
     （query/path 枚举校验 + 422 + OpenAPI parameter `"enum":[...]`）。
  4. **OpenAPI 扩展（F4）**：requestBody `$ref` → `components/schemas/<handler>`
     （自动从同一 spec 生成 object schema：type/format/enum/min-max-
     Length/Items/default/required；单一事实源）+ 修复既有 2 处字面量 BUG
     （`"type":"string}` 缺引号 / `"default":""d""` 双引号，openapi.json
     非法 JSON）。
  5. **🔴 Mojo 1.0.0 `assert` 是 no-op（本 ADR 实测发现）**：`mojo run`
     （-O0/-O3 均）下 `assert False` **不触发** → 此前所有 `.mojo` 自测的
     assert **从未生效**；body_validate 自测改用 `check(cond,msg)`（失败
     `std.os.abort()`）。**遗留**：仓库其余 `.mojo` 自测 assert 仍是 no-op
     （独立任务）。
  验收：e2e **205/205**（+23 项 BS-1..12 + 1 既有断言更新；205 达成依赖
  决策-39 修复，见 §8 补充）/ cargo test **312/0/4** / clippy `-D warnings`
  0 警告 / mojo 自测 21 check 全过 / bench 6 场景 0 errors（get_root_10k_100c
  41.9k req/s 无回归）/ ldd 仅 libc / env -i 干净启动 / binary **3.1M**
  （≤4.2M）/ **FFI diff = 0**。

- **已决策-39**：**finish_header multipart/form-data UTF-8 豁免（P0 修复，
  DC2 端口遗漏）**：
  1. **BUG**：`conn/parse.rs finish_header` 在 body 与 header **同 recv 到齐**
     （`copy >= content_length`，小 body 必然，256B 文件一次到齐）时做 body
     UTF-8 校验且**无 multipart 豁免**；io.rs phase-1/EOF 两路的
     `hdr_is_multipart` 豁免只覆盖分片 body。后果：256B 全字节（0..255）
     multipart 文件（e2e MP4）误 400 `Invalid UTF-8`，二进制 roundtrip 破；
     300KB（MP5）因分片幸免（掩盖 P0）。
  2. **修复**：`parse.rs` 新增纯函数 `is_multipart_form_data`（Content-Type
     值前缀 `multipart/form-data`，大小写不敏感，复用 `get_header_value_ci`）；
     `finish_header` 加同一豁免；io.rs `hdr_is_multipart` 委托纯函数
     （消除双份扫描，FFI 面不变）。
  3. **教训**：RFC 7578 豁免必须覆盖 **body 到齐的所有路径**（header 内到齐 /
     phase-1 收齐 / EOF 短 body），port C→Rust 时逐路径核对豁免一致性。
  验收：cargo test **312/0/4**（+5：is_multipart_form_data x3 +
  fh_multipart_binary_body_in_hdr_ok / fh_non_multipart_binary_body_in_hdr_400）/
  clippy `-D warnings` 0 警告 / e2e **205/205**（MP4 恢复绿）/ ldd 仅 libc /
  env -i 干净启动 / bench 0 errors（41.9k req/s 无回归）/ binary 3.1M。

- **已决策-40**：**GZip 响应压缩（Starlette GZipMiddleware 声明式 env 等价，
  Rust bridge flate2 纯 Rust）**（ADR-0015，Goal-0003 P2 矩阵 #24）：
  1. **env API（默认关 = FastAPI 对齐）**：`FASTAPI_MOJO_GZIP=1` /
     `FASTAPI_MOJO_GZIP_MIN_SIZE`（500, 对齐 Starlette）/
     `FASTAPI_MOJO_GZIP_MAX_SIZE`（1MiB 内存保护）；进程启动一次读取
     （`Mutex<Option>` 缓存，非 OnceLock — 提供 `#[cfg(test)]` 重置钩子隔离
     env 全局副作用，conn `sys_close` no-op 同模式）。
  2. **压缩条件（Starlette 对齐）**：client `Accept-Encoding` 含**裸 token**
     gzip/x-gzip（**不支持 q** — 上游 quirk）+ include_body + body 非空 +
     min/max 窗口 + 非 304 + extra 无 Content-Encoding（头名判定）。
  3. **钩子 = `send_response` 单点**（所有响应类型必经）：body 换 gzip 字节
     （level 6 对齐 Starlette）+ 响应头追加 `Content-Encoding: gzip`（extra
     行 `\r\n` 合并）+ Content-Length = 压缩后长度 + Content-Type 不变。
  4. **client 判定走 request 全局**：io.rs 解析 header 时
     `set_accepts_gzip(parse::accepts_gzip)`（CurrentRequest 新字段 +
     reset）—— worker 单请求串行模型内，**FFI diff = 0**。
  5. **依赖**：Cargo.toml 唯一第三方 = **flate2（纯 Rust miniz_oxide 后端，
     无 C 路径，静态链接）** — 本 ADR 是其首个落地用途（ws-deflate 预置的
     同一依赖）；**实测 ldd 仍仅 libc**（3,207,192 B = 3.1M）。
  验收：e2e **210/210**（+GZ-1..5：默认关/启用 gzip 头/无 AE identity/
  min_size 门/gunzip roundtrip 逐字节）/ cargo test **323/0/4**（+9+1：
  should_gzip 矩阵 / env 读取 / text+binary 0..255 roundtrip / accepts_gzip
  x4 / request set-reset / send socketpair 全链路）/ clippy `-D warnings`
  0 警告 / ldd 仅 libc / env -i 干净启动 / bench 6 场景 0 errors
  （get_root_10k_100c 39.2k req/s，历史区间内无回归）。

- **已决策-41**：**response_model 精化（exclude / exclude_none，FastAPI/
  Pydantic 语义，声明式单 helper）**（ADR-0016，Goal-0003 P2 矩阵 #11）：
  1. **声明式 API**：`_response_model`（include, 决策-35 既有）+
     `_response_exclude`（从**模型字段**剔除）+ `_response_exclude_none=
     "true"`（剔除 null 值字段 — 扁平 string dict 等价：空串 /
     `__nested__:null`；普通值 `"null"` 是 JSON 字符串不算 null）。
  2. **FastAPI 语义对齐**：include → exclude → exclude_none 应用序；
     **无 `_response_model` 时三参数全 no-op**（上游同款：无 model 时
     include/exclude 不影响响应）— /rm-noop demo + RM-7 e2e 固化。
  3. **单一 helper**：`request_response.mojo::response_model_body(handler,
     resp_data) -> String`（215 LOC 文件内）；dispatch 原 14 行 inline 块
     → 1 行调用（**dispatch 净减行**，延续「新行为 = 数据 + 单点」模式）。
  4. **demo**：/profile（4 字段模型 + exclude secret）/ /profile-none
     （exclude_none 剔除空 note）/ /profile-keep（对照保留）/ /rm-noop
     （KIND_ECHO 无模型 no-op）。
  验收：e2e **213/213**（RM-1/2 语义更新 + RM-5/6/7 新增）/ cargo **323/0/4**
  （Rust 零改动）/ clippy 0 警告 / bench 6 场景 0 errors（get_root_10k_100c
  42.2k req/s，历史区间内）/ ldd 仅 libc / env -i 干净启动 / **FFI diff = 0** /
  binary 3.1M（≤4.2M）。

- **已决策-42**：**CORS 完整配置（Starlette CORSMiddleware 声明式 env 等价，
  零新增依赖）**（ADR-0017，Goal-0003 P2 矩阵 #15）：
  1. **env API（默认 = C 时代线上行为 + Starlette max_age）**：
     `FASTAPI_MOJO_CORS_ORIGINS`（CSV 或 `*`，**默认 `*`**）/ `_METHODS`
     （默认 7 方法）/ `_HEADERS`（CSV 或 `*`，默认 Content-Type,
     Authorization；**未设置 ≠ `*`**）/ `_CREDENTIALS`（默认 false）/
     `_MAX_AGE`（默认 **600** = Starlette；C 时代 86400 → 对齐上游）；
     进程一次读取 `Mutex<Option>` + `#[cfg(test)]` reset/clear 钩子
     （GZip 同模式，三测试文件共享 `__test_clear_env()`）。
  2. **普通响应（`build_response_headers` 单点, Starlette 对齐）**：仅当
     请求带**被允许** Origin 时附带 CORS 头 — 通配且无 credentials → `*`；
     白名单命中或 credentials → **回显** origin（`*`+credentials 非法 →
     回显, 上游同款）；credentials → `+ Allow-Credentials: true`；
     不允许/无 Origin → **不带任何 CORS 头**（C 时代「每响应必带 `*`」
     **偏差移除**, 文档化；浏览器只在带 Origin 的跨源响应上读 CORS 头）。
  3. **预检（FFI `send_preflight_response(fd)` 签名不变, 204/400 动态）**：
     origin 不在白名单 → 400；ACRM ∉ methods（大小写不敏感）→ 400；
     ACHR ⊄ headers（`*` 放行）→ 400（JSON 错误体, Starlette
     `_build_pre_response` 400 语义）；通过 → 204 + [ACAO 回显/`*`] +
     [ACAC] + [ACAM] + [ACAH] + Max-Age；裸 OPTIONS（无 Origin, C 时代
     行为）→ 204 通配超集（文档化超集, e2e 守护）。
  4. **request 全局（FFI NUL 终止契约, 决策-36）**：CurrentRequest 新增
     origin[256]/acrm[64]/achr[256]+lens（截断+`[len]=0`）；io.rs 两个
     `set_http_fields` 调用点写三元组（`get_header_value_ci` 纯函数）；
     `CORS_HEADERS` 常量删除 → `cors::normal_cors_lines` 动态行。
     **FFI diff = 0, 零新增 Cargo 依赖（std only）**。
  验收：e2e **221/221**（+CRS-1..8：裸 OPTIONS/通配/回显+credentials/
  不允许无头/预检 204 全头集/ACRM 400/origin 400/ACHR 400）/ cargo
  **335/0/4**（323 → +12：cors_tests 10 + response 净增 2）/ clippy
  `-D warnings` 0 警告 / bench 6 场景 0 errors（get_root_10k_100c 36.0k
  req/s, 历史区间内无回归）/ ldd 仅 libc / env -i 干净启动 /
  binary **3.1M**（3,228,368 B, ≤4.2M）。

- **已决策-43**：**查询参数精化（List 多值 / alias / description，声明式纯
  Mojo，FFI diff = 0）**（ADR-0018，Goal-0003 P2 矩阵 #3）：
  1. **语法扩展（`_param_types` 向后兼容；决策-38 判据：空括号 = list，
     非空 = enum）**：`T[]` = 必填 list；`T[]=` = 可选（默认空 list，
     FastAPI `Query([])` 的 String 世界等价 = `""`）；`T[]=1,2` = 带默认
     list（CSV）。注册期 `set_param_type` 校验 list 默认值逐元素
     （int/float/bool 必须可解析，否则 raise）+ **拒绝 enum-list**
     （`str[low][]` 不可表达）。
  2. **alias（`_param_aliases = "name=alias;..."`，query-only，path
     豁免）**：FastAPI `Query(alias=...)` 语义 — **查询 key = alias**，
     原始 name 无绑定效力；校验按 alias key 取值（缺失 → 默认/422）；
     成功路径 `values[name]` **恒覆写**为绑定值（请求含 alias key →
     last-wins 值；否则 → 默认值）；OpenAPI `parameter.name` = alias
     （`alias` 是 Mojo 关键字 → 标识符用 `alias_name`）。
  3. **description（`_param_descs`）**：OpenAPI parameter 级 + schema 级
     **双处** description（上游 `Query(description=...)` 同款）；
     path/header 循环同样支持。
  4. **请求侧归一化（`apply_query_extras`，dispatch 成功路径单点）**：
     list = 全部 occurrence 的 **CSV**（内部表示 = CSV 字符串，handler
     读 `query_<key>` 得 "a,b"）/ 缺失 → 默认 CSV；alias 按 §2；path
     跳过。**标量多值保持 last-wins**（Starlette `MultiDict.get`，上游
     同款；`multi_values` 新增字段，`values` 行为不变，QS-R1 回归守护）。
  5. **list 校验（`validate_list_values`，首败即停 = FastAPI 0.141.1
     实测）**：逐元素复用决策-38 `parse_typed_value`；loc 带数组下标
     `["query","n",1]`；int/float/bool 完整 pydantic v2 措辞（list 元素
     bool 用完整句）；缺失 → `field required`（决策-38 既有小写，e2e
     固化）。
  6. **OpenAPI 扩展**：list → `{"type":"array","items":{"type":"t"},
     "default":[...]}`（仅显式 `=` 带 default；数字裸值/string 引号）；
     query 参数 name = alias。
  7. **新纯模块 `params_query_extra`（364 行）+ `parse_table` 泛化**
     （统一 alias/desc/types 声明表解析）；依赖图 `params_typed →
     params_query_extra → params_query` **无环**（`validate_list_values`
     函数级 back-import，调用时两侧模块已完全加载，实测可用）；demo
     `/query-extra`（list×2 + alias×2 + desc×4）+ `/query-req`
     （必填 list）。
  8. **文档化偏差（ADR-0018 §3.5）**：裸 `n: list[int]` 上游 = body vs
     本实现 `T[]` = query-list；CSV 逗号歧义（与既有 CSV 声明同类
     取舍）；标量 bool 短消息 vs list 元素完整消息；http_server_final
     **1173 行既有超阈值**（HEAD 1148，本 ADR 仅 +25 行接线，瘦身 =
     独立任务）。
  验收：e2e **248/248**（221 + 27 QS 项：多值 CSV / 单值 wrap / 空默认×2 /
  int list / 非法元素 422×2（loc 下标）/ alias×3 / 必填缺失 422 /
  必填正常 / OpenAPI×4 / last-wins 回归）/ cargo **335/0/4**（Rust
  零改动）/ clippy `-D warnings` 0 警告 / bench 6 场景 0 errors
  （get_root_10k_100c 37.3k req/s，历史区间内）/ ldd 仅 libc /
  env -i 干净启动 / **FFI diff = 0** / binary **3.12M**（3,277,520 B，
  ≤4.2M；vs 决策-42 +49 KB）。

- **已决策-44**：**OAuth2 password flow + JWT（HS256）— Rust crypto 原语
  + 纯 Mojo 协议层，对标矩阵最后一项**（ADR-0019，Goal-0003 P2 矩阵 #17）：
  1. **Rust `bridge/crypto.rs`（185 行，零第三方 crate，纯 std 手写）**：
     SHA-256（FIPS 180-4）/ HMAC-SHA256（RFC 2104，>64B key 先 sha256）/
     base64url（RFC 7515 §2.1；decode 宽松：忽略 `=`/空白、容忍 `+/`、
     非法字符 None、尾 bits 丢弃）；known vectors ×12 + **pyjwt-2.13
     独立实现 oracle 交叉验证**（同一 signing_input 签名逐字符相等）。
  2. **FFI +2（最小面，决策-36 NUL 契约）**：`fm_hmac_sha256_b64url(key,
     key_len, msg, msg_len) -> CSlice`（malloc(n+1)+NUL；len>0 显式长度
     二进制安全，=0/null 回退 NUL 截断）+ `fm_hmac_sha256_b64url_free`
     （libc free）。
  3. **`security_jwt.mojo`（497 行，纯 Mojo 协议层）**：b64url 编码 /
     3-part 切分（恰 3 段非空）/ flat JSON claims 扫描（转义 + UTF-8）/
     `check_oauth2`（OAuth2PasswordBearer 等价：无头/非 bearer scheme
     （大小写不敏感）→ 401 "Not authenticated"；param = 首个空格后全部
     （可空）→ 校验失败（含空 token）→ 401 "Could not validate
     credentials"；成功 → auth_user=sub）/ `handle_oauth2_token`
     （0.141.1 宽松 form 模型：grant_type 可选（存在须 `^password$`
     否则 422 pattern mismatch）、username/password 必填（422 missing
     全收集）、凭据错 401 "Incorrect email or password"、成功签发
     `{sub,username,iat,exp}` HS256 JWT）。
  4. **0.141.1 语义修正 ×2（本 ADR probe 复测，推翻早期假设）**：
     grant_type **缺省 → 200**（宽松模型，非 400）；空 Bearer → **401
     "Could not validate credentials"**（非 403 — pyjwt DecodeError 统一
     映射）。
  5. **dispatch 3 处接线**：`/token` + `/token-exp`（ttl=-1 测试钩子）+
     `/secure-jwt` 路由；auth gate `_auth=oauth2` → `check_oauth2`
     （放 dispatch 而非 check_auth：避免 FFI 闭包破坏 security.mojo 的
     JIT 自检，ADR-0019 §3.5-2）；`KIND_OAUTH2_TOKEN`（201）特例覆写
     （需 body，SSE 同型）；auth 失败 `resp_data["status"]` 从
     status_line 推导（不再硬编码 401）。
  6. **OpenAPI**：oauth2 路由 → `components.securitySchemes.
     OAuth2PasswordBearer`（`{type:http,scheme:bearer,bearerFormat:JWT}`）
     + operation 级 `security:[{OAuth2PasswordBearer:[]}]`（与既有
     components.schemas 合并）。
  7. **文档化偏差（ADR-0019 §3.5）**：sub 空串也拒（更严格）/ oauth2
     分支位置（JIT 边界）/ 响应含服务端公共 meta 字段（全路由统一约定）/
     `_auth_users` CSV = 教程硬编码凭据的声明式等价。
  验收：e2e **274/274**（248 + 26 OT 项：签发×3 / 服务端 token 可用×2 /
  凭据错 401×3 / 422 pattern+missing×4 / grant 宽松 / gate×4（含 fmtool
  raw 空 Bearer）/ pyjwt fixture T1..T5×5 / ttl=-1 / OpenAPI×2）/
  cargo **349/0/4**（335 → +14 crypto）/ clippy `-D warnings` 0 警告
  （双 crate）/ bench 6 场景 0 errors（get_root_10k_100c 41.2k req/s，
  历史区间内）/ ldd 仅 libc / env -i 干净启动（含 /token 签发 +
  /secure-jwt 接受）/ binary **3.17M**（3,326,672 B，≤4.2M；
  vs 决策-43 +49 KB）。

- **已决策-45**：**Form 多值/alias/desc + 422 detail parity（ADR-0020，Goal-0003
  P2 矩阵 #5 — 对标矩阵 #5 🟡→✅）**：
  1. **`form_params.mojo`（493 行，纯函数模块，FFI diff = 0）**：
     `parse_form_multi`（request_response 姊妹：同 key 全部 occurrence 按序 +
     url_decode + 裸 key→""）/ `validate_form_collect`（必填缺失 →
     "Field required"（F 大写）+ input null；list = 全部 occurrence
     逐元素 **collect-all**（F4/P1 实测，上游 0.141.1 query/body 同款）；标量 =
     last-wins；loc ["body",name(,i)]）/ `apply_form_extras`（list→CSV / 标量
     last-wins / alias wire key 绑定（原始名无效力）/ 未标注 _form_fields 字段
     旧语义（缺失→""，/login 向后兼容））/ `form_openapi_schema`（F10 字段序
     items/type/title/description/default）/ `form_request_body_required`
     （仅当存在无默认 _form_types 字段时 required:true）。
  2. **422 detail 全局 parity（P1-P5，FastAPI 0.141.1 + pydantic 2.13.5 probe）**：
     3 个既有构造器（`params_typed._pe` / `params_query_extra.make_error_json` /
     `body_validate.err_obj`）加 `input`（字段序 loc,msg,type,input；上游序
     type,loc,msg,input — 差异文档化）；"field required" → "Field required"；
     `validate_list_values` stop-on-first → **collect-all**（更正 ADR-0018
     「首个失败即停 = 上游同款」— 0.141.1 对 query/body 均 collect-all）；
     `parse_typed_value` float 接受 int 字面量（P6：pydantic v2 "1" → 1.0）+
     接受 "str"（潜在 bug 修复）。
  3. **dispatch 接线（http_server_final 2 处）**：校验段（validate_body_schema
     后）：CT 含 urlencoded（大小写不敏感）→ `parse_form_multi(body_str)`，否则
     空 multi（**上游同款**：非 form body → 字段全缺失 → 默认/422）；错误并入
     既有 all_errs（422 统一出口零新分支）。注入段：`inject_form_fields`
     （决策-28）移除 → `apply_form_extras` 单点；demo：`/form-multi`（POST；
     "items:int[];tags:str[];count:int=0;fx:float[]=;fb:bool[]=" +
     _param_descs）+ `/form-alias`（POST；"labels:str[]=;size:int=2" +
     _form_aliases labels=tags）。
  4. **OpenAPI**：`_generate_operation` form requestBody（与 _body_schema 互斥；
     _multipart 跳过）+ components form schema（Body_<name>_<method>，命名
     偏差 §3.5）；**附带 P0 修复（P7）**：query 参数 schema 括号配对自
     决策-38 起错（标量分支不关对象 + `_generate_parameter` 过早关参数对象
     且 description 落到对象外）→ /openapi.json 一直是非法 JSON（Swagger UI
     无法渲染；子串 e2e 从未发现）— 修正 + `fmtool jsoncheck` 整文合法性
     门禁（fmtool 新增纯 std 子命令）。
  5. **文档化偏差（ADR-0020 §3.5 ×7）**：detail 字段序 / 嵌套缺失 input
     近似 / bool 消息（query 短、form 完整）/ Body 命名 / 未标注字段 =
     未声明校验 / multipart 互斥 / CSV 逗号歧义。
  验收：e2e **294/294**（274 + 20 FM：多值 3-occ/wrap / missing F 大写 +
  input null / 默认×3 / collect-all×3（int 双错误 + loc idx）/ alias×3
  （wire/raw→默认/标量默认）/ /login 兼容×2 / URL 编码多值 / openapi.json
  jsoncheck 整文 / requestBody×2（required:true / 无 required）/ query
  collect-all×2（P1 更正））/ cargo **349/0/4**（FFI 零改动）/ clippy
  `-D warnings` 0 警告（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c
  34.2k req/s，历史区间内）/ ldd 仅 libc / env -i 干净启动（health +
  /form-multi + /form-alias 200）/ binary **3.24M**（3,400,400 B，≤4.2M；
  vs 决策-44 +74 KB）。
- **已决策-46**：**UploadFile 对象 API — 文件字段声明 / 422 parity / 对象操作 /
  multipart OpenAPI（ADR-0021，Goal-0003 P2 矩阵 #6 — 对标矩阵 #6 ✅ 全量）**：
  1. **Rust bridge（`multipart.rs` 重构 +249/-146 净 -28；`ffi.rs` +`mp_part_save`；
     零新 crate）**：解析 helper 提取 `pub(crate)`（boundary/attr/header 线）+
     新增 `b64_decode` / `to_hex` / **`sha256_hex_of`（lock-free 纯 std 手写，
     ADR-0010 SHA-1 同先例）** / **`part_save`（原子 `.tmp`→rename，无半文件）**；
     parts getter **field 5 = sha256hex（解析期预算 — 🔴 修复读路径非重入 Mutex
     自锁死锁隐患**）；`part_sha256_hex` `#[cfg(test)]`（dead-code 清零）；测试
     拆出 `multipart_tests.rs`（17 = 原 12 平移 + 5 新）；`mp_part_save` C ABI
     （NUL 契约决策-36；**`..` 穿越守卫在 Mojo 层** `_path_safe`）。
  2. **Mojo 新模块 ×4（纯逻辑零 FFI，均 <500 行）**：`file_params`（427：
     `MpParts` parallel lists / `_file_types` `file|bytes`+`[]`+`=` 声明 /
     `_file_aliases` / `validate_file_collect`（**U2 value_error**（上游完整
     措辞 "Expected UploadFile, received: <class 'str'>"）/ **U4 last-wins** /
     **U5 非 multipart 全缺失** / unknown_type）/ `_decl_of`（声明名或 alias 值
     命中）/ `apply_file_extras`（`file_<声明名>_*` key：**size = 实际字节
     U1** / text → 声明 **bytes** 字段（U9 双路）/ text → form（U8）/
     list → `_count`+`_list_json`））+ `file_form_check`（126：**U3
     string_type**（input = 稳定子集 `{filename,size,headers}`）+ 声明 file
     字段 claim 的 part 不参与）+ `file_ops_ffi`（195：`snapshot_mp_parts`
     **单一 FFI 快照点**（失败 = 空 = U5）/ `_file_ops` `head:N|range:S:L|
     sha256|save:PATH`（alias-aware，输出 key = 声明名））+ `openapi_multipart`
     （145：**U7 四形态 schema**（字段序 type/contentMediaType/title/
     description；optional anyOf-null；list items）+ **key 序
     properties/type/required/title** + required 仅当必填字段 +
     `Body_<handler.name>_<method>`）。
  3. **422 parity（FastAPI 0.141.1 + pydantic 2.13.5 p1–p8 逐条实测）**：文本 →
     UploadFile = U2 value_error（input = 原文）；文件 → 声明 `str` form =
     **单条** U3 string_type（p7：file-then-text → 200 文本；list = 逐
     occurrence loc idx）；非 multipart CT（无 CT/urlencoded/json）= 所有文件
     字段 missing 422（U5）；**de-dup（p7 presence 胜）**：form 字段有 file
     part → 其 canonical missing 422 **整串精确匹配**丢弃（只丢同字段 missing）。
  4. **dispatch 接线（`http_server_final` 1210 → 1238，净 +28）**：决策-32 旧
     注入（`_mp_read_field`/`inject_multipart_fields`）移除 → CT 检测 →
     `snapshot_mp_parts` → filtered text map（multipart，file 声明名/alias
     不进 map）/ `parse_form_multi`（urlencoded）/ 空（U5）→
     `validate_file_collect` **恒执行** → 422 de-dup → 成功路径
     `apply_file_extras` + `apply_file_ops`（conn 仍活跃，快照重读安全）；
     OpenAPI：`_generate_operation` multipart 分支（与 `_body_schema` 互斥；
     urlencoded 分支保留回归）+ components 按 `multipart_route` 分流。
     demo：`/upload-file`（`doc:file` + alias `docfile` + `opt:file=` +
     `docs:file[]` + `note:str` 必填 + `_file_ops doc:sha256` + `_param_descs`）
     / `/upload-bytes`（`raw:bytes=` + `small:bytes=` 全 optional + ops
     `head:4`/`range:1:3`/`save`）。
  5. **文档化偏差（ADR-0021 §3.5 ×7）**：U9 上游 500 不复制（bytes 接受
     text/file 双路）/ string_type input 稳定子集（上游 `_file/_max_mem_size`
     等 env 细节排除）/ `Body_` 命名（上游 fn+route+method）/ save `..`
     守卫 = 安全超集 / 未声明字段不校验（决策-32 兼容）/ **`name:type=` =
     required**（上游 `Form("")`/`Form(None)` = optional，p8 — 本决策不修，
     ripple 决策-43/45 面）/ U3 missing de-dup（presence 胜）。
  验收：e2e **312/312**（294 + 18 MP8–MP23b：sha256 vs `sha256sum` / head+range
  b64 / save roundtrip `cmp` / all-optional 非 CT 200 / required-missing ×2 /
  value_error alias / string_type 稳定子集 / list count+顺序 / bytes-text /
  bytes-file / no-CT ×3 / urlencoded ×2 / openapi 子串 / jsoncheck 整文 /
  text→form / alias ×2）+ MP4 语义修正（size = 实际字节 U1，256 非 b64 长 344）/
  cargo **354/0/4**（+5 净）/ clippy `-D warnings` 0 警告（双 crate）/ bench 6
  场景 0 errors（get_root_10k_100c 34.3k req/s，历史区间内）/ ldd 仅 libc /
  env -i 干净启动（health + /upload-file + /upload-bytes 200）/ binary **3.4M**
  （3,531,472 B，≤4.2M；vs 决策-45 +131 KB）/ `find src -name '*.c'` = 0 保持。
- **已决策-47**：**Depends use_cache — 每请求 memo 表（cached / nocache
  双语义，ADR-0022，Goal-0003 P2 矩阵 #9 — 对标矩阵 #9 ✅ 全量）**：
  1. **`dep_cache.mojo`（106 行，纯数据层，FFI diff = 0）**：`DepCache`
     memo 表（parallel Lists；**append-only**：每次实际派发一条，
     `find` 取**最新条** = P9-3 覆写语义）+ `find` / `append` /
     `inject`（memo 重注入 = 与首次注入完全一致）/ `calls_of`（memo
     条数 = 实际派发次数，P9 计数）/ `unique_names` + `inject_dep_calls`
     （`_dep_calls=true` 声明门控 → `<dep>_calls` 注入）。
  2. **上游语义逐条对齐（FastAPI 0.141.1 + starlette 1.6.0 probe P9-1..P9-5）**：
     **默认 = cached**（upstream `use_cache=True`）：菱形 / 三重菱形共享
     dep 每请求**仅派发 1 次**，所有引用值同源（P9-1/P9-5；决策-33「各
     路径独立解析」收紧 — 向上游对齐）；**`_depends_nocache`（新增）=
     `use_cache=False`**：恒重新派发（route 级 / 嵌套级均可，P9-2/P9-4）；
     **P9-3 关键 nuance**：nocache 派发的结果**同样入库**（写入无条件，
     False 仅跳过查找）→ 后续 cached 引用直接复用（P9-3 实测 calls==1）；
     **每请求作用域**（P9-1 第二请求再派发）。
  3. **dispatch 接线（`http_server_final` 1238 → 1332，+94）**：
     `dispatch_dep` 加 `nocache: Bool` + `mut cache: DepCache`（子依赖
     递归处理 `_depends` + `_depends_nocache` 双表；visited 环检测优先
     于 memo）；`resolve_depends` 加第二循环（**解析序：先 cached CSV
     后 nocache CSV** — 确定性）；dispatch 每请求创建单一 memo 表 +
     `inject_dep_calls`（未声明 = no-op，既有 `/di`、`/api/*` 响应体零
     变化）。
  4. **APIRouter 对称扩展（`router.mojo` 495 ≤500）**：`base_deps_nocache`
     + `set_base_deps_nocache` + `include_router(deps_nc=)`（与
     `_depends`/`_tags` 三层合并同构，WS 同步）。demo：`dc_tick` /
     `dc_auth`（默认 cached）/ `dc_auth2`（嵌套 nocache）+ `/di-cache`
     （菱形）/ `/di-nocache` / `/di-mix`（均 `_dep_calls=true`）。
  5. **文档化偏差（ADR-0022 §3.5 ×4）**：per-name memo vs per-dependant
     （声明式等价 — dep 无 per-reference 参数面）/ `_dep_calls` =
     observability 超集（上游无此面）/ APIRouter 基础依赖恒 cached（无
     per-base-dep nocache 声明面）/ 解析序 = 先 cached 后 nocache
     （上游 = 参数声明序；dep 集合相同时结果等价）。
  验收：e2e **319/319**（312 + 7 DC：菱形 1 次（P9-1）/ 值同源 / route
  nocache 2 次（P9-2）/ 嵌套 nocache 1 次（P9-3）/ 每请求作用域 / `/di`
  回归 / APIRouter 回归）/ cargo **354/0/4**（FFI 零改动）/ clippy
  `-D warnings` 0 警告（双 crate）/ `dep_cache_selftest` 16 check 全绿 /
  bench 6 场景 0 errors（get_root_10k_100c 34.8k req/s，历史区间内）/
  ldd 仅 libc / env -i 干净启动（health + /di-cache 200）/ binary **3.4M**
  （3,556,048 B，≤4.2M；vs 决策-46 +25 KB）/ `find src -name '*.c'` = 0
  保持。
- **已决策-48**：**FileResponse / StreamingResponse — Rust bridge 协议层
  （ADR-0023，Goal-0003 P1 矩阵 #10 — 对标矩阵 #10 ✅ 全量）**：
  1. **`file_protocol.rs`（230 行，纯函数，零 I/O）**：`parse_range_header`
     （**顺序敏感**：无 `=` → 400；单位≠bytes → 400；**>100 段 → `[]`
     → 200 quirk**（starlette `max_ranges=100`）；逐段解析（空/`-`/无
     `-`/非数字跳过；suffix `-N` / open `S-` / **end≥size clamp**）；
     0 有效段 → 400；**start 越界 → 416（先于 start≥end → 400）**；
     单段直返；多段排序 + 重叠合并）+ `fmt_rfc1123`（civil_from_days）
     + `rfc5987_quote` / `build_content_disposition`（quote 变化 →
     `filename*=utf-8''{q}`）+ `apply_charset_rule`（`text/*` + 无
     `charset=` → 追加）+ `etag_from_mtime_size`（`"md5(f64Display(
     mtime) + "-" + size)"`）+ `multipart_content_length`（闭式公式，
     p10c MP2 锚定 242）+ `generate_boundary`（xorshift32 ×6 取前 26
     小写 hex，`secrets.token_hex(13)` parity）。
  2. **`file_serve.rs`（416 行，I/O 层，FFI ×2）**：`LinuxStat`
     **144B glibc `struct stat` 布局**（`stat(2)` 整写 — 128B 缓冲 =
     栈 OOB 写；偏移守护测试）+ **`S_IFMT = 0o170000`**（初版
     `0o070000` 少一位八进制 → REG 恒 false 全 500，🔴 实测 catch）
     + 64KB 块 lseek/read/send 直发（上游 `chunk_size`）+
     **`send_file_response`（单点 FFI）**：200 全量 / 206 单段
     （`Content-Range bytes s-e/size`）/ 206 multipart（头无 CR）/
     If-Range = ETag 或 Last-Modified（字符串相等）才用 Range / HEAD
     仅头 / 400×4 精确消息 / 416（`bytes */size` + CL 0 + 空体）/ 500
     （缺失/非普通文件，**无文件头**）+ **`send_streaming_response`**
     （TE chunked `{len:x}\r\n{data}\r\n…0\r\n\r\n`；media 空 =
     **无 CT quirk**；status/extra 透传，F9 同机制）。
  3. **Mojo 接线（声明式，SSE 分支同型）**：`KIND_FILE = 300`
     （`handler.mojo` 495 ≤500；声明面 `_file_path`（静态目录相对/
     绝对）/ `_file_media`（空 = guess + charset 规则）/ `_file_name` /
     `_file_cdt`（空 = attachment）/ `_file_status`（默认 `200 OK`）/
     `_response_headers`（不得覆写 CT/ETag））+ dispatch FILE 分支
     （`http_server_final` 1332 → 1444：cfd 透传 + `continue`）+
     **8 个 demo 路由**（`/file` / `/file-name` / `/file-inline` /
     `/file-missing` / `/file-201` / `/stream` / `/stream-json` /
     `/stream-empty`）+ `static/filedemo.bin`（30B，build 自动嵌入）。
  4. **MD5（`crypto.rs`，RFC 1321）+ libm 零化**：K 表 **const 嵌入**
     （`K[i] = floor(2^32 × |sin(i+1)|)`；(i+1) **本身是弧度** — 初版
     `to_radians()` 双转换 = 系统性错表，🔴 实测 catch；两个「RFC
     向量」凭记忆抄错，一律以 md5sum/hashlib oracle 为准）。运行时
     `f64::sin` 会链入 `libm.so.6` **破坏 CI ldd 门禁**（ci.yml 禁
     libm.so）→ const 256B `.rodata`，值由 glibc 正确舍入 sin 逐位
     导出，`md5_k_table_matches_sin_derivation` 测试守护 const ≡
     派生 → **ldd 保持仅 libc**（此前决策-48 构建曾回归 libm，本项
     修闭）。
  5. **上游语义锚点（starlette 1.6.0 源码 + uvicorn 0.52.4 活体，
     /tmp/fresp_probe p10*）**：**HEAD → 405 quirk**（`APIRoute`
     methods = `{GET}` 不含 HEAD — 与 starlette 内置 Route /
     `/openapi.json`（`{GET, HEAD}`）不同；带 Range 也 405）→ 本
     实现 HEAD = 仅头（200/206，RFC 9110 语义，更优）；**101+ 段
     quirk → 200 全量**；**end≥size clamp → 206**（`bytes=0-30` 对
     30B 非 416）；重叠段合并（`0-1,1-3` → `0-3`）；**If-None-Match /
     If-Modified-Since 上游 FileResponse 同样不处理**（忽略 = 200
     全量，parity 非偏差）；multipart boundary = `token_hex(13)`
     （26 小写 hex，浏览器 95-96 bit 熵对齐）；400/416/500 = 全新
     PlainTextResponse（无文件头，`Internal Server Error` = 21B）。
  6. **文档化偏差（ADR-0023 §3.5 ×7）**：① ORJSON/UJSON ≡ 原生
     json.mojo（既有 F3 决策，列此完备）；② HEAD 仅头 vs 上游 405
     quirk（**更优**）；③ GZip（决策-40）不介入 file/streaming
     （上游 starlette 1.6.0 压缩它们 — body iterator 包装，本实现
     GZip 在 send_response 单点；P2 剩余面）；④ **整秒 mtime 的
     ETag**：上游 `str(N.0) = "N.0"` vs 本实现最短 Display `"N"`
     （opaque token，稳定性/条件匹配不受影响；**非整秒 mtime 与
     上游逐字节相同** — 活体交叉验证）；⑤ i64 溢出 Range 段 →
     跳过（全跳 → 400）vs 上游无界 int → 416（仅 >9.2 EB 可触发）；
     ⑥ `_file_path` = 静态目录相对声明面 + extra 头不得覆写
     已计算 CT/ETag（上游 `headers=` 可覆写 CT — 收窄，防 MIME
     混淆，P2 剩余面）；⑦ If-None-Match / If-Modified-Since 忽略
     = parity（非偏差，列此完备）。
  验收：e2e **351/351**（319 + 32 FR：200 精确体 / 头（LM vs
  `date -u -R`）/ **ETag = md5(f64repr(mtime)-size) 独立交叉验证**
  （fmtool f64repr × md5sum oracle）/ 201 / CD attachment + RFC5987
  inline / 500 无文件头 / 206 单段·suffix·open·**clamp** / 416
  （`bytes */30` CL 0）/ 400×4 精确消息 / 101 段 quirk → 200 /
  merge 重叠 / **multi-range 精确体**（boundary 抽取 + printf +
  cmp，CL = 246 闭式手算，26-hex，头无 CR）/ If-Range ETag·LM·
  stale / INM·IMS 忽略 / HEAD 200·206 **raw-socket 线级空体** /
  chunked×3（no-CT quirk / 202+X-Custom / 空体）/ **raw-socket
  chunked 帧级**（`6\r\nhello ` / `3\r\n中` / `0\r\n\r\n`）/
  ×10 稳定）/ cargo **407/0/4**（354 + 53：file_protocol 30 +
  file_serve 15 + MD5 8）/ clippy `-D warnings` 0 警告（双
  crate）/ bench 6 场景 0 errors（get_root_10k_100c **37,665
  req/s**，历史区间 32.9k–43.9k 内）/ **ldd 仅 libc**（libm 零化）/
  env -i 干净启动（health + /file 200 30B + /stream 200 14B）/
  binary **3.5M**（3,631,104 B，≤4.2M；vs 决策-47 +75 KB）/
  `find src -name '*.c'` = 0 保持

- **已决策-49**：**任意异常类型 handler — 字符串 tag 约定 + 声明式处理表
  + 路由级 try/except guard（ADR-0024，Goal-0003 P2 矩阵 #13 — 对标矩阵
  #13 ✅ 全量）**：
  1. **Mojo 1.0.0 异常面探测（P13-M1..M8，/tmp/mojo_exc）**：异常类型
     **仅一个 = `Error`**（ValueError/IndexError/KeyError/RuntimeError/
     `Exception` 全部 unknown declaration，无子类/类型别名/内省 — 无 MRO
     可走）；`try/except` 语法；**`String(e)` 返回被捕获 Error 的
     message**（未捕获顶层 = "Unhandled exception" + exit 1）；
     `std.os.getenv` 原生可读（全局表无需 FFI）；try 块内声明变量 except
     不可见；含 String 字段 struct 须显式 `__init__`。
  2. **字符串 tag 约定**：`raise Error("TAG: message")`（第一个 `:`
     切分；无 `:` = 未分类）— 异常"类型"的承载（上游类层级的可观测行为
     等价）。
  3. **声明式处理表**（同 TAG **后者胜**，上游 P13-2）：
     - **全局**：env `FASTAPI_MOJO_EXCEPTION_HANDLERS =
       "TAG:STATUS:BODY[:json];…"`（`;` 分隔条目；STATUS = 3 位数字；
       第 4 段 `:json` = application/json 发送，否则 text/plain;
       charset=utf-8）；
     - **路由级**：`handler.data["_exc_handlers"]` = 同格式（**整体替换**
       全局表 — 上游无 per-route 面, 超集, ADR-0024 §3.5-7）；
     - **声明式 raise 钩子**：`handler.data["_exception_raise"] =
       "TAG: msg"`（评估位置 = Depends 之后、run_handler 之前 = 上游
       endpoint body 抛异常位置, P13-9 分层定案）。
  4. **`guarded_run_handler`（新模块 `exception_handlers.mojo` 254 行
     <500）**：路由级 try/except（= 上游 route
     `wrap_app_handling_exceptions`）；捕获任意 `Error` →
     `resolve_exception_response`（`String(e)` 取 message）：查找顺序
     **精确 tag → `Exception` catch-all（= 上游 ServerErrorMiddleware
     500/Exception 键, P13-9 双层 map 单表化）→ 默认 500
     "Internal Server Error"（text/plain; charset=utf-8, P13-10 逐字
     parity）**；body 模板 `{exc}`/`{tag}` 插值（json 条目先
     `_json_escape`，复用 middleware.mojo）；**P13-8 日志 quirk 模拟**
     （具体命中 → 单行 `[exc] <tag> handled`；catch-all/未处理 → 完整
     message 行）。
  5. **接线 + FFI**：dispatch 单点接线（`http_server_final`
     1444 → 1509：异常响应分支 = SSE 同型 cfd 透传 + `continue`，
     绕过 response_model 原样发送）+ **新 FFI
     `send_text_response_status`**（send.rs + ffi.rs；复用
     `send_response` 核心 — 零新依赖/零 libm/NUL 契约不变；
     `send_text_response`（200 硬编码, F6 metrics）保留）+
     `standard_status_line` +418（Teapot）+ **7 demo 路由**
     （`/exc/ve` / `/exc/unicorn`（上游文档 UnicornException 例名）/
     `/exc/unhandled` / `/exc/raise-plain` / `/exc/ve2` /
     `/exc/override` / `/exc/dup`）。
  6. **`exception_handlers_selftest.mojo`**（JIT 可达纯逻辑自检,
     file_params_selftest 同模式）：28 checks（split/entry 解析/
     后者胜/插值/resolve 全分支/json 转义/env 表）。
  7. **文档化偏差（ADR-0024 §3.5 ×8）**：① 无类 → 字符串 tag（**无 MRO
     走查** — 层级不可表达）；② handler = 声明式条目（status + body
     模板）非 `(conn, exc) -> Response` callable；③ **无 int status 键
     面**（本实现 HTTPException 是声明式 struct, F2 路径, 从不以 Mojo
     异常抛出）；④ **`response_started` RuntimeError 路径结构性不可达**
     （dispatch 单发模型, 无"响应已发出后" Mojo 代码段 — P13-6/11 状态
     永不进入）；⑤ 双层 map（ServerErrorMiddleware/ExceptionMiddleware）
     → 单表（`Exception` tag = 500/Exception 键；可达结果集相同）；
     ⑥ 日志 quirk 线形模拟（Mojo 无 traceback 机制）；⑦ per-route
     `_exc_handlers` = **超集**（上游拒绝该 kwarg, P13-3）；⑧ 中间件抛出
     异常 = gap（当前中间件链无 raise 面；未捕获 → worker 终止, P13-M4）。
  验收：e2e **366/366**（351 + 15 XH：默认 500 ×4 + CT / 正常路由 +
  _error_map 回归 ×2 / 精确 tag 418 / 自定义 tag 418 / catch-all 503 /
  json 422 / 路由级覆盖 429 / 同 tag 后者胜 404 / 无 tag 消息 / 有表正常
  路由）/ cargo **409/0/4**（407 + 2）/ clippy `-D warnings` 0 警告
  （双 crate）/ bench 6 场景 0 errors（get_root_10k_100c **37,216
  req/s**, 历史区间内）/ **ldd 仅 libc** / env -i 干净启动（health 200
  + /exc/ve 500）/ binary **3.5M**（3,663,872 B，≤4.2M；vs 决策-48
  +32 KB）/ `find src -name '*.c'` = 0 保持

- **已决策-50**：**Request.state — 每请求状态存储（声明式
  `_state_set`/`_reads_state` + `{param}` 插值）（ADR-0025，Goal-0003
  P2 矩阵 #22 — 对标矩阵 #22 ✅ 全量）**：
  1. **上游探测（starlette 1.6.0 源码 + uvicorn 活体, P22-1..6）**：
     `State` = dict 包装（属性/dict 双写读面共享 `_state`; **1.6.0 无
     下划线前缀禁止**）; `Request.state` = **property**（lazy
     `scope.setdefault("state", {})` — middleware 与 endpoint 共享同一
     scope dict）; 缺失读 → AttributeError/KeyError → 500; `del`-缺失
     → KeyError quirk; `in`/`len`/`iter` 可用（**无 `__contains__`**
     — `in` 经 `__iter__`）; **每请求隔离**（endpoint 写仅同请求可见,
     独立请求干净, ×2 活体）。
  2. **声明式映射（ADR-0004 范式, 零 FFI）**：
     - **写面** `_state_set = "key:value;key2:value2"`（`;` 分条目,
       **首个** `:` 分 key/value, value 可再含 `:`）; **值支持
       `{param}` 插值**（复用 `substitute_params`; ctx = 全部已注入
       参数 = path+query+body+auth; 缺失键保留 `{key}` 字面量 —
       KIND_RUN_CMD 同款语义, 防静默填空）; 评估位置 = 全部注入之后、
       `_reads_state` 注入之前（= 上游「middleware 先写, endpoint 后
       读」顺序的声明式等价）; 空 key/空条目跳过; **注册期校验**
       （畸形 spec 启动即 fail — `check_state_specs`, 与
       `check_body_schemas` 同策略）。
     - **读面** `_reads_state` CSV → `params["state_<name>"]`（F10
       `_reads_headers`/`_reads_cookies` 完全同范式）; **缺失键 →
       `""`**（F10 既有约定; 上游为 500 → 偏差 §3.5-1）。
  3. **存储 = dispatch 每请求 `Dict[String, String]`**（每请求新建、
     请求结束即弃 = scope 语义 P22-2/6）; **FFI diff = 0**（纯 Mojo,
     JIT 可达 — 比决策-49 更轻, 无新 FFI/无新 crate）。
  4. **接线（http_server_final 1509 → 1551, +42 行）**：import + 每
     请求 state 构造 + 写/读注入（dispatch 主 JSON 分支,
     `inject_dep_calls` 之后、`guarded_run_handler` 之前; state 被消费
     后不再使用, 对后续分支零影响）+ **3 demo 路由**（`/state`
     set+read / `/state-dyn/{who}` 参数插值 / `/state-missing` 无 set
     读 `user,ghost` → 双空 = **跨请求隔离证明** — 即使前一请求写
     user=bob 本请求也读不到, P22-6）+ `check_state_specs` 注册期检查。
  5. **`request_state.mojo`（124 行 <500）** +
     **`request_state_selftest.mojo`**（JIT 可达纯逻辑自检: set 解析 /
     value 保冒号 / `{param}` 插值 / 缺失键字面量 / 空条目跳过 / 读
     注入 / 缺失 → "" / trim / 注册校验 — file_params_selftest 同
     模式, 不触 run_handler FFI 闭包）。
  6. **文档化偏差（ADR-0025 §3.5 ×7）**：① 缺失键读 → `""`（F10
     约定）vs 上游 500; ② 写面 = 路由声明（handler 前单点评估）vs 代码
     动态写; ③ 值域 = String vs 任意对象（结构化值可 JSON 编码进
     字符串）; ④ 无属性反射/集合面（`in`/`len`/`iter`/`del`）; ⑤
     惰性 property → 每请求显式构造（parity, 语义相同）; ⑥
     下划线前缀属性 1.6.0 允许（parity）; ⑦ **（环境项）本机 dev
     环境透明代理**劫持新 bind 端口 ~2s 内首连接（Caddy :80 假空
     200, 真 server 收不到, taint = 该 bind 生命周期, 实测）→ e2e
     6 副 server + `fmtool bench` 就绪探针 **bind 后 sleep 5s 再首
     探针** + `/health` body 须含 `healthy`（假响应 body 为空）防假
     ready — 干净环境 (CI) 不受影响, 仅多等 5s。
  验收：e2e **373/373**（366 + 7 XS：/state set+read /
  /state-dyn/bob 插值 / /state-missing 双空串 / **跨请求隔离**（bob、
  alice 写后独立请求 state 仍空）/ health 200 / errors/99 404 /
  exc/ve 500 回归）/ cargo **409/0/4**（FFI diff = 0）/ clippy
  `-D warnings` 0 警告（双 crate）/ bench 6 场景 0 errors
  （get_root_10k_100c **32,938 req/s**, 历史区间内）/ **ldd 仅
  libc** / env -i 干净启动（health + /state + /state-dyn/bob 全对）/
  binary **3.7M**（3,700,736 B，≤4.2M；vs 决策-49 +36 KB）/
  `find src -name '*.c'` = 0 保持

- **已决策-51**：**WebSocket 精化 — close(code,reason) / exception_handler /
  send_bytes / send_json 声明式指令 + close-wait phase 5（ADR-0026, Goal-0003
  P2 矩阵 #23 — 对标矩阵 #23 ✅ 全量）**：
  1. **上游探测（uvicorn 0.52.4 + wsproto 1.3.2 + starlette 1.6.0 活体,
     P23-1..7 + p23i A..E）**：`close(code, reason)` 帧 = 2B code + reason
     （1004/1006 → 改写 1000 / 1005 → 无 payload / reason 123B codepoint
     安全截断 — wsproto frame_protocol.py:589）; close-wait = uvicorn
     硬编码 `close_timeout=10.0`（close 帧已发后: 数据/ping 全丢弃, 任何
     close → 静默 close, 10s 超时 → transport.close; p23i A..E 实测）;
     `WebSocketException` → close(code, reason)（无回复）; 未处理异常 →
     **无 close 帧** TCP EOF（客户端 1006）; `send_json` = compact
     `separators=(",",":"), ensure_ascii=False`; `send_bytes` = BINARY。
  2. **声明式映射（ADR-0004 范式, `run_ws_message` 单点 dispatch 签名不变,
     每消息评估, JIT 可达）**：`_ws_close=CODE:REASON`（回复后 close +
     close-wait; 首个 `:` 切分, 值可再含 `:`; 注册期 `check_ws_specs` 校验
     合法码集 {1000-1003,1007-1015}∪[3000,4999] + spec 形态 — 1004/1005/1006
     拒收（比 wsproto 发送侧静默改写更严）, 畸形启动即 fail）/ `_ws_raise=msg`
     （无回复, **无 close 帧**立即 EOF = 客户端 1006, log
     `[ws-exc] <route>: <msg>`）/ `_ws_exc_close=SPEC`（WebSocketException
     等价: 无回复 close 帧 + close-wait）/ `_ws_no_reply=1` / `_ws_binary=1`
     （echo = NUL 保留零拷贝 BINARY; 非 echo = 回复文本 BINARY）/
     `_ws_json=<模板>`（compact JSON 原样 TEXT 帧, **echo 路径优先** =
     替代回显）; 优先级 `_ws_raise` > `_ws_exc_close` > `_ws_close`
     （前两 pre-reply, 后一 post-reply）。
  3. **close-wait = bridge 新 phase 5**（`ws_set_closing` 入 phase +
     `ws_close_at=now`; `pump_ws_closing`: 数据/ping/pong 丢弃, 任何
     close 帧 → 静默 close（`ws_pump_close_quiet` = 入队 END +
     reset_for_close, **无二次 close 帧**）, EOF/协议错误 → 静默 close;
     `check_deadlines` 新 `WsCloseWaitTimeout`（超时 = 入队 END +
     `table.close` 无 close 帧; phase 5 无 keepalive ping / 无 idle /
     无 408）; env `FASTAPI_MOJO_WS_CLOSE_WAIT` 默认 **10000** =
     uvicorn 10.0s parity, 0 = 立即关, AtomicI32 sentinel 只读一次
     （`get_ws_ping_max` 同款）; 1s poll tick → 实际关闭 ∈ [wait,
     wait+1s)（文档化偏差 ②）。
  4. **新 FFI（+5 导出, 既有 `ws_send_close` 保留 — 1002/1003/1007/
     1008/1009 协议路径继续用）**：`ws_send_close_reason`（256B 栈缓冲 +
     NUL 契约 决策-20; 帧内容 = 纯函数 `ws_close_reason_payload`）/
     `ws_write_binary` / `ws_write_current_binary`（NUL 安全零拷贝）/
     `ws_set_closing` / `get_ws_close_wait_ms`（测试/诊断）。
  5. **接线（http_server_final 1551 → 1583, +32 行）**：import +
     `check_ws_specs(router)` + **6 demo 路由**（`/ws/close` echo +
     1000:"bye" / `/ws/close/4001` 无回复 + 4001 / `/ws-exc/boom`
     `_ws_raise="kaboom"` / `/ws-exc/close` 4002:"ws-exc" / `/ws/bin`
     binary NUL 保留 / `/ws/json` compact JSON UTF-8）— P23 六场景
     全覆盖; **新模块 `ws_directives.mojo`（122 行 <500）+
     `ws_directives_selftest.mojo`**（纯函数解析/校验自检, 0 警告）。
  6. **文档化偏差（ADR-0026 §3.5 ×7）**：① `_ws_json` = 声明模板（非
     运行期 dumps; JSON 合法性 = 声明者责任）② close-wait 分辨率 = 1s
     tick + 可配置超集（0 = 立即）③ 声明式每消息 vs 上游每连接 endpoint
     生命周期 ④ 回复后会话继续（既有偏差显式记录）⑤ 回复值域 = UTF-8
     文本（任意非 UTF-8 不可表达, NUL 保留）⑥ close-wait 协议错误 →
     静默 close（不发提示帧）⑦ 异常 = 字符串 tag 非类（决策-49 同款）。
  验收：e2e **383/383**（373 + 10 W：回复后 close 提前结束 <1s /
  无回复 close + close-wait 保持 ∈[1s,4s) / 异常无 close 帧立即 EOF <1s /
  4002 ws-exc / binary NUL 往返 / compact JSON UTF-8 逐字节 /
  close-wait 期 ping 丢弃（无 pong）/ 数据丢弃 / server log [ws-exc] ×2）/
  cargo **431/0/4**（+22: ws.rs close_reason_payload ×8 + deadlines
  phase-5 ×4 + ws_session_ffi ×10）/ clippy `-D warnings` 0 警告（双
  crate）/ bench 6 场景 0 errors（get_root_10k_100c **34,880 req/s**,
  32.9k–43.9k 区间内, vs 决策-50 32,938 无回归）/ **ldd 仅 libc** /
  env -i 干净启动 / binary **3.7M**（3,733,504 B，≤4.2M；vs 决策-50
  +33 KB）/ `find src -name '*.c'` = 0 保持 / `mojo run
  ws_directives_selftest.mojo` all passed

- **已决策-52**：**OpenAPI 精化 — 顶层 tags/info/servers/externalDocs + 路由级
  summary/description/operation_id/deprecated/include_in_schema/status_code/
  responses（ADR-0027, Goal-0003 P2 矩阵 #16 — 对标矩阵 #16 ✅ 全量）**：
  1. **上游探测（fastapi 0.141.1 / pydantic 2.13.5 活体, P24-1..15 + p24e/f/g
     勘误）**：info 键序 `title, description?, termsOfService?, contact?,
     license?, version`（缺省省略）；operation 键序 `tags?, summary?,
     description?, operationId, parameters?, requestBody?, responses,
     security?, deprecated?`；根键序 `openapi, info, servers?, paths,
     components?, tags?, externalDocs?`（**externalDocs: description 先**）；
     **operationId = `re.sub(\W→_)` 逐字符、无 `_+` 折叠**（`foo_bar_x_y__z__get`
     / `another_one_a__id__b_post` / `calc_calc__a___b__get` — 0.141.1
     `generate_unique_id` 源码 + 活体双重确认）；summary = 函数名 Python
     `str.title()`（`_`/`-`→空格, P24-5 全向量）；**AnyUrl 2.13.5 规范化**：
     contact/license/externalDocs url — host-only → 尾 `/`, path 空且有
     `?`/`#` → 在其前插 `/`（`https://host?x` → `https://host/?x`）；
     **servers.url = `AnyUrl | str`，str 精确匹配优先 → 不规范化**（含
     `not-a-url` 原样, P24-12 修正）；`include_in_schema=False` → 不进
     paths（仍可服务, P24-13）。
  2. **声明式映射（ADR-0004 范式, **FFI diff = 0**, JIT 可达）**：app 级
     9 `FASTAPI_MOJO_OPENAPI_*` env（TITLE/VERSION/DESCRIPTION/TERMS/
     CONTACT/LICENSE/SERVERS/TAGS/EXTERNAL_DOCS — /openapi.json 请求期
     读, 空 = 默认/省略, 畸形 → 省略字段不 500）+ 路由级 8 handler.data
     声明（`_summary` 默认 = name title() / `_description` /
     `_response_description` 默认 "Successful Response"（P24-8）/
     `_operation_id` 默认公式（P24-6）/ `_deprecated` / `_include_in_schema`
     （不进 paths/components, 仍可服务）/ `_status_code`="NNN Reason"
     （**wire 仅当 handler 结果恰 "200 OK" 时覆写** — 异常/401/405/422
     不覆写; spec responses 主键 = 前 3 位, P24-7）/ `_responses`（额外
     状态码, 首 `:` 切, **与主键重复 → 注册期拒绝**））；注册期校验
     `check_openapi_specs`（check_ws_specs/check_state_specs/check_body_
     schemas 同策略 fail-fast, 畸形启动即 fail）。
  3. **接线（http_server_final 1583 → 1642, +59 行）**：import（getenv +
     check_openapi_specs）+ `check_openapi_specs(router)` + **3 demo 路由**
     （`/meta/probe` 单路由覆盖全部 operation 级键 / `/meta/hidden` /
     `/meta/made` 201）+ /openapi.json 调用点读 9 env（TITLE/VERSION 默认
     保持 `fastapi_mojo API`/`1.8.0`）+ /docs 标题同源 + 主 JSON 分支
     `_status_code` wire 覆写; **新模块 `openapi_custom.mojo`（381 行
     <500, 纯函数: title_case / default_operation_id / url_host_quirk /
     info·servers·root tags·externalDocs JSON 构造 / parse_response_entries
     / primary_status_key / check_openapi_specs）+
     `openapi_custom_selftest.mojo`（~60 断言, 0 警告）**；`openapi.mojo`
     重写（497 行 <500: operation 键序重排 P24-4 + 根键序 P24-10 +
     hidden 路由跳过 paths/components）。
  4. **文档化偏差（ADR-0027 §3.5 ×9）**：① 3.0.3 vs 上游 3.1.0（200 schema
     `{type:object}` vs `{}`）② 无运行期可变 spec（请求期声明式再生成;
     上游 `extra` 参数本身 no-op）③ _status_code = 全 status line
     （`_stream_status`/`_file_status` 同型）④ app 级 = env 非构造器
     （畸形省略）⑤ root_path/openapi_url/docs_url/redoc_url/webhooks 未
     实现（P24-11: 0.141.1 root_path 对 spec 无影响）⑥ summary =
     handler.name title()（同字符串约定）⑦ _responses 重复主键注册期
     拒绝（上游用户 dict 覆盖）⑧ 路由 tags 不并入根 tags（P24-2 复刻）
     ⑨ servers url 不规范化（上游 AnyUrl|str, parity 列此完备）。
  验收：e2e **395/395**（383 + 12 OP2：subserver minimal info / full info
  精确串（terms 无 quirk + contact/license url quirk）/ servers 位置 /
  根 tags + externalDocs（desc 先）/ `/meta/probe` op 精确串 /
  `/meta/hidden` 可服务 + spec 缺席 / `/meta/made` wire 201 + spec 主键 /
  `/health` 默认 opid `health_health_get` + summary `Health` /
  "Successful Response" 默认 / 双 server jsoncheck 完整合法 / /docs 标题
  不变 / /health 回归）/ cargo **431/0/4**（Rust 零改动）/ clippy
  `-D warnings` 0 警告（双 crate）/ `mojo run openapi_custom_selftest.mojo`
  all passed 0 警告 / bench 6 场景 0 errors（get_root_10k_100c **33,590
  req/s**, 32.9k–43.9k 区间内, vs 决策-51 34,880 无回归）/ **ldd 仅 libc** /
  env -i 干净启动 / binary **3.7M**（3,803,136 B，≤4.2M；vs 决策-51 +70 KB
  — 纯 Mojo）/ `find src -name '*.c'` = 0 保持 / `pgrep -x fastapi_mojo` = 0

- **已决策-53**：**Header 参数精化 — `_reads_headers` 条目 name=alias +
  默认下划线→连字符转换 + OpenAPI 头名对齐（ADR-0028, Goal-0003 P2 矩阵
  #7 — 对标矩阵 #7 ✅ 全量）**：
  1. **上游探测（fastapi 0.141.1 / uvicorn 0.52.4 活体, P25-1..10）**：
     `Header()` 默认 `convert_underscores=True` — wire 名 = 参数名**逐**
     `_`→`-`（`x_token`→`x-token` / `x__token`→`x--token` / `a_b_c`→`a-b-c`；
     字面 `x_token` 头**不**匹配 → 422 loc `["header","x-token"]`,
     P25-1/4）；`Header(alias=)` → wire = alias **原样不转换**（`my_header`
     alias 发 `my-header` → 422, P25-3）；匹配 ASCII **大小写不敏感**
     （小写 `x-custom-thing` 命中 `X-Custom-Thing`, P25-2）；多值头取**第一**
     （P25-5）；default/422/min_length/max_length/pattern/int 约束面
     （P25-6..9, 精确 422 消息已探测备查）→ **下一决策**（矩阵 #2 路径
     参数 + typed header 约束统一落地）。
  2. **声明式映射（ADR-0004 范式, FFI diff = 0, JIT 可达）**：
     `_reads_headers` 既有 CSV 条目扩展两形态 — `name`（wire = 逐 `_`→`-`
     转换）/ `name=alias`（wire = alias 原样；`name=name` = 字面 =
     `convert_underscores=False` 逃生门 — 单声明双语义, 上游 alias 本就不
     转换故无损, 全可达状态均可表达）；参数键仍 = `header_<name>`
     （响应/OpenAPI 键 = 声明名, Query alias 同约定）；读取走既有 bridge
     `get_header_value_ci`（ASCII CI + 首现 = 上游 parity, **零 Rust/FFI
     改动**）；OpenAPI header 参数 name = wire 名（原始拼写保留, P25-2/3）
     + `_param_descs` → description（决策-43 既有, 查找按声明名）。
  3. **接线（http_server_final +12 行 / openapi.mojo +2 行 = 499 行 <500）**：
     import（parse_header_entry/check_header_specs）+ `check_header_specs
     (router)` 注册期校验簇（至多 1 `=` / 两侧非空 / 可打印非空白 ASCII
     0x21-0x7E, 畸形启动即 fail, check_ws_specs/check_state_specs/
     check_openapi_specs 同策略）+ `inject_request_headers` 改写（每条目 →
     parse_header_entry → wire 读取）+ demo `/hdr/alias`
     （`x_token=Token-Literal,client_id`）；**新模块 `header_params.mojo`
     （120 行 <500, 纯函数: header_wire_name / parse_header_entry /
     check_header_specs）+ `header_params_selftest.mojo`（~22 断言,
     0 警告）**。
  4. **文档化偏差（ADR-0028 §3.5 ×4）**：① 缺失 → ""（F3a/F10 既有约定）
     非 required-422（typed header = 下一决策, 矩阵 #2）② alias 与
     convert_underscores = 单声明双语义（无行为损失）③ schema 无 `title`
     （F4 基线）④ 422 loc = wire 名随 #1 下一决策对齐。
  验收：e2e **403/403**（395 + 8 OP3：alias CI / alias 原始拼写 /
  下划线字面不绑 alias / 默认转换 / 下划线字面不读普通 / `/ctx` 回归 /
  OpenAPI wire 名（Token-Literal + client-id）/ 多值取首）/ cargo
  **431/0/4**（Rust 零改动）/ clippy `-D warnings` 0 警告（双 crate）/
  `mojo run header_params_selftest.mojo` all passed 0 警告 / bench 6 场景
  0 errors（get_root_10k_100c **35,765 req/s**, 32.9k–43.9k 区间内,
  vs 决策-52 33,590 无回归）/ **ldd 仅 libc** / env -i 干净启动 /
  binary **3.8M**（3,815,424 B，≤4.2M；vs 决策-52 +12 KB — 纯 Mojo）/
  `find src -name '*.c'` = 0 保持 / `pgrep -x fastapi_mojo` = 0

- **已决策-54**：**参数约束面统一落地 — `_param_constraints` 声明
  （gt/ge/lt/le/mo/len/pat）+ typed header 校验（`_header_types`）+
  自研 regex 引擎（ADR-0029, Goal-0003 P2 矩阵 #2 — 对标矩阵 #2 ✅
  全量, #3 bool 偏差销账）**：
  1. **上游探测（fastapi 0.141.1 / pydantic 2.13.5 活体, P26-a..h）**：
     约束 422 = house 键序 + `ctx` 末位（ctx 键上游拼写, 值 = 声明
     字面量原样 ⑦）；每字段仅首违（数值 mo→ge→gt→le→lt / 字符串
     minl→maxl→pat, P26-c/d/e）；`multiple_of=0` = no-op；str+数值
     约束 = 上游静默 no-op（本实现注册期拒, 优于上游）；list+数值
     约束 = 上游运行时 500（本实现 fail-fast, 优于上游）；**input
     类型化**：在场值 = raw 串, 缺失+默认违约束 = 类型化字面量
     unquoted（int → JSON 数字, P26-b-8）, parse 失败 = raw；
     collect-all 群序 path→query→header（P26-b-10）。
  2. **声明式映射（ADR-0004 范式, FFI diff = +1）**：
     `_param_constraints` = `name=gt=3,le=10` CSV（条目 `;` 分, 键
     首个 `=` 分）；**未声明 query 键 = 隐式 str 声明**（len/pat only;
     数值键拼写错误仍经 type-mismatch 拒; 纯 len/pat 拼写错误 =
     每请求 422 missing 自证 — 优于上游静默忽略）；
     `check_param_constraints` 注册期 fail-fast（未知键 / 非数字字面量
     / len 形态 / type-mismatch / list+约束 / `_header_types` 未声明 /
     pattern 编译校验, check_* 同策略 — 坏配置启动即暴露）；
     `_header_types` 校验（`validate_headers_collect`）：缺失 → 有
     默认 = 校验默认值（违 → 422 input = 类型化字面量; 过 → 注入
     默认）/ 无默认 = 422 `Field required`（input null, loc = wire）
     / 在场 → parse（完整消息, bool 三面对齐 = 矩阵 #3 销账）→
     约束 → 注入 raw（handler 无感, F1 String dict）。
  3. **自研 regex 引擎（`bridge/regex.rs`, FFI +1 `regex_match`）**：
     `re.search` 语义（literal/escape/字符类/量词/组/alternation/锚/
     `\b`）；**不支持** 反向引用/环视/命名组/内联标志（声明式词表,
     矩阵 #4 同款定性）；匹配步数上限防 pathological DoS；零第三方,
     纯整型运算 → ldd 仅 libc 保持（-static-libgcc 守则, 无 libm）；
     已知向量对拍（Python re 活体生成, RFC 6455 SHA1 级联教训同款
     回归守护）。JIT 自测解耦：`check_str_constraints` =
     `check_str_len_constraints`（pure）+ `check_str_pattern`（FFI）
     组合 — Mojo 1.0.0 JIT 按 call-graph closure materialize
     external_call, JIT env 无 bridge lib（LD_PRELOAD 无效,
     `mojo run -Xlinker jit_regex_stub.so` 唯一有效; stub
     abort-if-called = dev-only, 不进 binary/CI; `dev/jit_regex_stub.rs`
     + `scripts/jit_stub.sh`）。
  4. **实施期修复 ×3（selftest/e2e 捕获）**：① FFI 三态
     `extract_request_header`（0 = found / -2 = 未找到 / -1 = 出错;
     原 0 = found/missing 不可分 → 缺失被当"在场空值" —
     CP-12/15/16/20b 根因; F3a 注入语义不变: 缺失仍注入 ""）②
     OpenAPI alias 约束查找（cons 表按**声明名** keyed vs
     `_generate_parameter` 按 param_name = **wire 名**查 → alias
     header/query 约束全丢, schema 退化 `{"type":"string"}`; 修复 =
     openapi 本地 dict 注入 `cons[wire] = cons[declared]` 别名条目）
     ③ `apply_query_extras` 标量默认注入（200 路径 缺席+默认 →
     `query.values`, 上游形参默认值 parity — 200 回显/请求读取可见
     默认, 422 路径先于此不受影响）。
  5. **OpenAPI 3.0.3 约束键（ADR-0029 §3.5, 偏差 ④⑥⑦）**：gt →
     `"minimum":N,"exclusiveMinimum":true`（3.0 布尔形式, 3.1 数字
     形式不适用 3.0.3）/ le → `maximum` / mo → `multipleOf`（字面量
     原样）/ len → `minLength`/`maxLength` / pat → `pattern`;
     键序 type→minLength→maxLength→pattern→multipleOf→minimum→
     exclusiveMinimum→maximum→exclusiveMaximum→default→description;
     隐式 str schema 恒带 `type` 键（上游无, 信息超集 ⑥）。
  6. **模块形态**：`param_constraints.mojo` 464 ln（spec/注册/OpenAPI
     fragment）+ `param_constraints_run.mojo` 152 ln（运行期 collect,
     500 行规则拆分边界）+ `numlit.mojo` 279 ln（F1 type-spec 原语
     抽出）+ `param_constraints_selftest.mojo`（10/10 节）+
     6 demo 路由 /con/*（§3.7 计划五路由 + /con/all 群序断言）；
     http_server_final 1762→~1790 ln, openapi.mojo <500。
  验收：e2e **428/428**（403 + 25 CP: CP-1..19 约束面 / CP-20a 群序
  path→query→header / CP-20b 默认违约 input = unquoted 2 / CP-21..23
  OpenAPI schema / CP-24 消息回归）/ cargo **434/0/4** / clippy
  `-D warnings` 0 警告（双 crate）/ `param_constraints_selftest.mojo`
  **10/10** 全绿 / bench 6 场景 0 errors（get_root_10k_100c
  **35,124 req/s**, 32.9k–43.9k 区间, vs 决策-53 35,765 无回归）/
  **ldd 仅 libc** / env -i 干净启动 / binary **3.9M**（4,020,232 B,
  ≤4.2M；vs 决策-53 +205 KB = regex + 纯 Mojo）/ `find src -name
  '*.c'` = 0 保持 / `find . -name '*.py'`（excl .git/docs）= 0 /
  `pgrep -x fastapi_mojo` = 0

- **已决策-55**：**用户自定义中间件声明式落地 — `FASTAPI_MOJO_MIDDLEWARE` 单一 env
  动词表（ADR-0030, Goal-0003 P2 矩阵 #14 — 对标矩阵 #14 ✅ 全量, 中间件全闭环：
  固定3 + GZip(决策-40) + 用户自定义）**：
  1. **Spec 语法**：`<mw1>;...;<mwN>`（mw1=先添加=**innermost**…mwN=**outermost**,
     P-MW-1）；`<mwK>`=动词 `,` 分（书写序=执行序）；`<verb>`=`NAME[:A[:B[:C]]]` 位置字段
     `:`；路径表 `|`。分隔符集 `;`/`,`/`:`/`|` 值内禁用（解析期 fail-fast, `check_mw_spec`
     同策略, 服务不启动）。
  2. **请求面**（Mojo dispatch, outermost→innermost, 全量字段读后、OPTIONS/WS/路由前）：
     `MAP:FROM:TO`（exact / `-prefix`→TO+rest / `/`-suffix 防双斜杠, P-MW-7 `scope["path"]`
     等价）/ `REQHDR:NAME:VALUE`（合成请求头 FFI `inject_request_header`, CI 先注入先胜,
     仅 `_reads_headers`/typed header/auth 可见, 不影响 bridge 内部 Origin/Accept-Encoding/
     ws_protocol 探测）/ `BLOCK:STATUS:BODY:PATHS`（`*`=全部 / `prefix/` / exact, 早期
     text/plain 响应 + 短路, P-MW-3）。
  3. **响应面**（bridge `send_response` 单点, innermost→outermost=**env 正序**, GZip 前）：
     `HDR:NAME:VALUE`（同名行原位替换, **后写胜**, P-MW-2）/ `STATUS:FROM:TO`（FROM 可
     `*`, P-MW-4）/ `BODY:TEMPLATE`（{method}{path}{query}{status}{req_id} 插值 +
     **重算 Content-Length** + CT→text/plain, P-MW-5）/ `LOG`（发送成功后一行
     `[mw] <req_id> <METHOD> <path>[?<q>] -> <status>`）。
  4. **短路**（ADR §3.2）：BLOCK 于 mwK（0-based env 序）→ 响应**仅过 mwK+1..mwN 外层**
     动词（blocker 自身及更内层跳过）；由 bridge `plan_request_path` **重跑** Mojo
     `mw_plan_request` 算法判定（**零额外 FFI**, diff 仍 = +2）；确认 `send_text_response_status`
     委托 `send_response` → BLOCK 早期响应也经 mw 钩子（设计自洽）。
  5. **文件面**：新 `src/fastapi_mojo/mw_spec.mojo`（430 ln：解析/校验 + 纯函数
     `mw_plan_request` + 插值 + selftest 10/10 FFI-free）+ `bridge/middleware.rs`（428 ln）
     + `middleware_tests.rs`（238 ln, 19 测）；改 `http_server_final.mojo`（main env
     fail-fast + dispatch 钩子 + 3 demo 路由 /mw/hdr·/mw/reqhdr·/mw/map-new）/
     `bridge/{mod,request,conn,send,ffi}.rs`（**FFI +2** `set_req_id`/`inject_request_header`；
     `CurrentRequest` + req_id(64B NUL) + 合成头表（每请求清）；`extract_request_header`
     先查合成表再查原 hdr 块）。
  6. **Path 语义不对称（ADR §7.5 文档化）**：LOG 行 = **原始 client path**（诊断值）；
     BODY 插值 + 响应 JSON `path` 字段 = **post-MAP path**（重写后有效路径）。
  7. **文档化优于上游**：上游 fastapi 0.141.1 body 替换不重算 CL → h11 `LocalProtocolError:
     Too little data for declared Content-Length`（P-MW-5 实测 2 次）；本实现重算 CL。
  验收：e2e **428→438/438**（+MW-1..10: HDR /health X-Mw / REQHDR /mw/reqhdr 回显 /
  MAP /mw/map-old→/mw/map-new（post-MAP path）/ LOG 行 / STATUS 200→201 / BODY 替换 +
  text/plain / 同名 HDR 外层胜 / BLOCK 短路 418 仅 X-Outer / BLOCK text/plain / 无 env
  零回归）/ cargo **453/0/4**（+19 中间件单测, 含 bridge 短路重推导 6）/ clippy
  `-D warnings` 0 警告（双 crate）/ `mw_spec.mojo` selftest **10/10**（FFI-free, CI 普通
  mojo run 循环）/ bench 6 场景 0 errors（get_root_10k_100c ≈ 31.5k req/s, 32.9k–43.9k
  带内, vs 决策-54 35,124 噪声内无回归）/ **ldd 仅 libc** / env -i 干净启动 / binary
  **4.0M**（4,077,712 B, ≤4.2M; +57 KB vs 决策-54 = 纯 std 字节/整型）/ `find src -name
  '*.c'` = 0 保持 / `pgrep -x fastapi_mojo` = 0

- **已决策-56**：**TestClient 声明式等价 — fmtool `testclient` 三子命令（ADR-0031,
  Goal-0003 矩阵 #25 ✅ = **25/25 全量完成**；dev 工具不进 runtime binary, FFI diff = 0）**：
  1. **设计**（活体 P-TCL-1..16, fastapi 0.141.1 / starlette 1.6.0）：候选
     A=声明式 fmtool 子命令 ✅ / B=in-binary test mode ❌（污染交付物）/
     C=Mojo 客户端 ❌（Mojo 1.0.0 无 socket）；Track B 先例（决策-22）—— TestClient
     是 **dev 工具**（`src/fmtool/` 独立 crate, pure std），runtime binary 仅加
     `/tc/jar` demo 路由（KIND_ECHO + `_reads_cookies tc` + `_response_headers
     Set-Cookie: tc=jar1`, <KB）供 cookie 捕获/回放 e2e。
  2. **`testclient http`**：真实网络 GET/POST + `--json`（parse 后规范化 compact,
     P-TCL-4）/ `--data`（含 `=`/`&` → form 编码, 否则 raw, P-TCL-5）+
     `--header/--param/--cookie` + `--cookie-jar FILE`（Set-Cookie 捕获 →
     `name=value` 文件 → 次轮回放, LRU 序）+ 重定向循环（303→GET / 301-302
     POST→GET / 307-308 保持, `redirect_method` 纯函数；`--no-follow/--max-hops`
     防循环）+ `--json-out`（status_code/reason/headers/cookies/url/body|b64）+
     退出码 0 响应 / 1 connect / 2 timeout / 3 协议 / 4 redirect loop。
  3. **`testclient ws`**：**host-aware** RFC6455 握手（ws.rs 原 helper 硬编码
     `127.0.0.1` **不动** → e2e ws1..5 逐字节不变；testclient/ws.rs 自带握手,
     复用同一 SHA-1/base64/make_frame/recv_frame/expected_accept 原语）+
     Sec-WebSocket-Accept **硬校验** + `--subprotocol`（协商回显）+ action 脚本
     （`send-text/send-json/send-bytes` · `receive*/receive-text/receive-bytes/
     receive-json` · `close:CODE[:REASON]` · `expect-close:CODE[:REASON]`）→
     **JSONL 事件流**（`connect{subprotocol}` / `denial{status,reason,body}` /
     `sent{value}` / `receive{value}` / `close{code,reason,initiator}` /
     `done` / `error{message}`）+ 控制帧透明（ping→auto-pong / pong 忽略,
     starlette parity, 不产生事件）+ 分片重组 + 脚本结束自动 close 1000 +
     退出码 0 done / 4 denial / 5 早断连·mismatch / 6 timeout。
  4. **`testclient run`**（lifespan CM 等价, P-TCL-10）：
     `[--port N] [--timeout-ms N] [--readiness PATH] [--max-wait N]
     <server-cmd...> -- <actions.jsonl>`（按**最后一个** `--` 切分, 选项后
     装饰性 `--` 两写法皆收）→ spawn（`--port N` 注入为**两个 argv**）→
     readiness 轮询（/health 含 "healthy", 默认 10s, 新 bind 先等 3s 防
     Caddy 污染）→ actions 逐行执行（`op:http` expect_status/expect_body /
     `op:ws` actions）PASS/FAIL → **SIGTERM（coreutils `kill`** — fmtool 零
     crate 依赖无 libc; `Child::kill()` = SIGKILL 不可用）→ wait ≤5s（否则
     SIGKILL）→ `run: N passed, M failed; server_exit=...`，**exit 0 仅当全
     通过 + server_exit=0**（服务器 SIGTERM = 优雅退出 0, 已验证）。
  5. **文档化偏差 ×6**（ADR-0031 §3.9）：① 真实 TCP 对真实 binary 非 in-process
     ASGI（更贴近部署物, 可视为优于上游）② 无 in-process 异常传播（500 面 =
     `raise_server_exceptions=False` 路径）③ cookie jar = 文件非 RFC
     domain/path/expiry 模型 ④ declarative action script 非闭包/portal（Mojo
     无闭包同款约束）⑤ UA=`testclient` 但 Host = 真实 host:port（非 `testserver`）
     ⑥ lifespan = spawn/kill 真实 server 非 in-process CM。
  6. **实施期修复**（ADR-0031 §7.6）：`--port N` 单 argv 被服务器忽略（→
     两个 argv, 实测 catch）/ SIGTERM 走 coreutils `kill`（`Child::kill()`
     = SIGKILL）/ `run` 按最后一个 `--` 切分（两写法兼容）/ ws 握手新建
     testclient/ws.rs（ws.rs 不动）/ `read_response` 去 dead timeout 参数。
  验收：e2e **438→447/447 全绿**（TC-1..9：json-out 200+healthy / POST /items
  --json 回显解析字段 item_name / --cookie 回显 / --cookie-jar 捕获+回放 /
  ws /ws echo 往返+done / expect-close 4001:custom reason（WS_CLOSE_WAIT=2000）/
  run 全生命周期 server_exit=0 / 非 WS 路由 denial（WS router 404, exit 4）/
  404 透传 exit 0）/ cargo **fastapi_mojo_rs 453/0/4 不变** + **fmtool 30/0**
  （fmtool 首批单测：parse_url/url_encode/parse_action/CookieJar/redirect_method/
  build_body）/ clippy **`-D warnings` 0**（双 crate）/ ldd 仅 libc / env -i
  干净启动 / binary **4,081,808 B**（≤4.2M, +4 KB vs 决策-55）/ bench 6 场景
  0 errors（get_root_10k_100c = 34,867 req/s, 32.9k–43.9k 带内）/
  `find src -name '*.c'` = 0 / `pgrep -x fastapi_mojo` = 0。
- **已决策-57**：**body pat=REGEX 约束 + PATCH+body 解析**（ADR-0032, Goal-0003 矩阵 #1/#4/#20 缺口闭环; ADR-0014 两偏差闭环）：body 约束词表 + pat=REGEX（复用 bridge/regex.rs FFI `regex_match`, FFI diff=0, str 标量 only + 注册期 fail-fast, 422 type=string_pattern_mismatch, OpenAPI pattern）+ **PATCH+body 解析**（dispatch body POST/PUT→+PATCH 1 行）；e2e 447→454（BP-1a..e + PATCH-B1a/b）/ cargo 453/0/4 不变 / clippy 0 / ldd 仅 libc / binary 4,085,904 B ≤4.2M / env -i 无孤儿；剩余 = validator closure（Mojo 无闭包=硬边界）+ 元素级（P2）+ OpenAPI 3.0.3 vs 3.1.0（P2）
- **已决策-58**：**数组元素级约束**（ADR-0033, Goal-0003 矩阵 #4/#20 缺口闭环; ADR-0032 §3.6 / ADR-0014 元素级偏差闭环）：约束词表复用×类型依赖语义 — pat/len 在 str[] 上逐元素（剥外层引号 → byte_length / `regex_match` FFI, FFI diff=0）、ge/le/gt/lt 在 int[]/float[] 上逐元素；items 保持数组级（元素数）；422 loc = `["body",<field>,<idx>]`（复用元素类型错 loc 约定, type = string_pattern_mismatch / string_too_short / string_too_long / greater_than…）；**注册期 fail-fast 加强**（约束 key × 字段类型错配 → 启动即失败, 闭环旧静默 no-op 偏差: pat/len 仅 str 标量或 str[], gt.. 仅 int/float 标量或 int[]/float[], items 仅数组）；OpenAPI 元素级约束入 items 对象（minLength/maxLength/pattern / minimum/maximum/exclusiveMinimum/exclusiveMaximum）、minItems/maxItems 留数组层；e2e 454→465（BP-2a..k）/ cargo 453/0/4 不变 / clippy 0 / ldd 仅 libc / binary 4,110,480 B （≤4.2M, +24 KB）/ env -i 干净启动 / 无孤儿；剩余 = validator closure（Mojo 无闭包=硬边界）+ OpenAPI 3.0.3 vs 3.1.0（P2）
- **已决策-59**：**WebSocket permessage-deflate（RFC 7692）**（ADR-0034, Goal-0003 #23 / `ws-deflate` open bead 销账）：env 三模式 `FASTAPI_MOJO_WS_DEFLATE=on(default)/off/required` + comma fallback（未知/重复参数拒 offer; server window 固定 15, `<15` fallback; client bits 8..15）；RSV1 首数据帧 — 入站支持压缩 fragmentation（wire/展开 1MiB cap, bad data→1002, 超限→1009, 解压后再 UTF-8/dispatch），出站 level6 `Z_SYNC_FLUSH` 后去尾 `00 00 ff ff`（不 4 字节 padding、不发 pre-close 空压缩帧）；**方向正确 context takeover**：`server_no_context_takeover`=服务端出站 reset, `client_no_context_takeover`=客户端出站/服务端入站 reset；**FFI diff=0**（`ws_handshake` 3 参、`ws_parser_feed` 8 参、所有 extern "C" 签名不变; `ws_session_begin` 仅扩展返回 2=required 无 offer→Mojo 400）；bridge 直接 `miniz_oxide 0.8`（pure Rust, 该版本已由 flate2 传入链接）；fmtool 保持零依赖，手写 RFC1951 stored/fixed/dynamic inflater + persistent window 与 stored 编码 WSD 客户端；e2e 465→471（WSD1..6）/ cargo 470/0/4（+17）/ fmtool 35/0（+5）/ clippy 0（双 crate）/ ldd 仅 libc / env -i 干净启动 / binary 4,135,064 B（≤4.2M）/ bench 6 场景 0 errors / RSS 平台化无线性泄漏 / 孤儿 0

- **已决策-60**：**WebSocket 应用子协议矩阵**（ADR-0035, Goal-0003 P2 / `ws-subprotocol` bead 销账）：`ws_sp` 从单候选扩展为 comma-separated **server-preference** 列表（offer 仍 trim/精确匹配, 单候选 chat 语义不变, 无交集仍 400）；新增 `/ws/jsonrpc`（`jsonrpc,v2.jsonrpc`, JSON-RPC 2.0 echo/ping/add + notification 不回复 + -32700/-32600/-32602/-32601, String/Number/Null id 类型保留）、`/ws/graphql-ws`（modern `graphql-transport-ws` + legacy `graphql-ws` fallback; connection_init→ack, ping→pong, subscribe/start→next(query echo)+complete, complete/stop/terminate 静默, malformed→close 4400）、`/ws/grpc-web`（必需 `grpc-web`, BINARY NUL-safe zero-copy transparent bridge, TEXT→1003; **不伪装 protobuf/gRPC 引擎**）；实现为 route 数据 `_ws_protocol` + **FFI-free** `ws_protocols.mojo`（163 LOC, 避免扩 495 LOC handler God file）+ session 单点 dispatch，**FFI diff=0 / Rust bridge diff=0**；e2e 471→479（WSP1..8）/ Mojo ws_protocols unit 绿 / fmtool 35/0 + clippy 0 / binary 4,171,928 B（≤4.2M）/ ldd 仅 libc / C=0

- **已决策-61**：**递归嵌套 JSON body Schema**（ADR-0036, Goal-0003 #4/#20 / `json-schema` bead 销账）：`obj[]{subspec}` 不再 opaque——每个数组元素递归 `_validate_fields`，支持 child 必填/类型/默认值/`len/pat/gt/ge/lt/le` 与外层 `items`，422 loc=`["body",field,idx,child]`、missing input=**元素对象**；成功保留 raw array + 注入 `body_<field>_<idx>_<child>`；OpenAPI `items` 递归 object schema（properties/required）+ 外层 min/maxItems，并补 body 标量数值 `minimum/maximum`、`gt/lt` 3.0 boolean exclusive 键、obj/arr type 映射；body demo 路由拆 `body_schema_routes.mojo`、body 自测拆同目录 `body_validate_test.mojo`（生产/测试均 <500 行, server hub 净减 23 行），**FFI diff=0 / Rust bridge diff=0**；e2e 479→497（JS-1a..8b）/ body_validate_test 绿 / bridge 470/0/4 / fmtool 35/0 / clippy 0 / bench 6 场景 0 errors / binary 4,180,120 B（≤4.2M）/ ldd 仅 libc / env -i 干净启动 / C=Python=orphans 0；边界=T[][]、opaque obj、validator closure（既有 ADR）

- **已决策-62**：**阶段化 OpenTelemetry in-memory traces**（ADR-0037, Goal-0003 observability extension / `otel` bead 销账）：`FASTAPI_MOJO_OTEL=1` opt-in，`_finish_request` 成为响应后统一 telemetry hook（access log + optional server span，覆盖路由/错误/中间件/static/OpenAPI/docs/metrics、`/traces`/SSE/file/WS upgrade 边界）；Rust std-only 有界 ring（**每 worker 128 spans**、超限淘汰最旧、method/path/query/status 长度+NUL 防御）+ `GET /traces` 导出 OTLP JSON `resourceSpans`（`service.name=fastapi_mojo`、scope=`fastapi_mojo.bridge`、SERVER span、32/16 hex trace/spanId、HTTP method/path/query/status/duration 属性）；`/traces` 先 snapshot 后记录自身 span；默认关闭恒空导出；**FFI diff=+2**（`otel_trace_record` / `get_traces_block`, 返回 slice NUL 终止）→ e2e **497→504/504**（OT-0..6）/ bridge **472/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c=33,863.87 req/s）/ binary **4,184,272 B ≤4.2M** / ldd 仅 libc / env -i 干净启动 / C=Python=orphans 0；边界=无网络 exporter、无跨 worker 聚合、无 context propagation/采样器，ID 为单调序列固定宽度 hex（后续 exporter 决策）

- **已决策-63**：**HTTP/2 prior-knowledge h2c 有界子集**（ADR-0038, Goal-0003 P2 / `http2` bead 销账）：纯 Rust std RFC7540/7541 实现 — HPACK 静态/动态/Huffman 请求解码 + literal-only 响应编码，HEADERS/CONTINUATION/DATA/SETTINGS/PING/WINDOW_UPDATE/RST_STREAM/GOAWAY，padding/pseudo-header/connection-specific/Content-Length/长度与整数防御；`Conn.h2` + phase6 复用既有 poll，H2Request 适配 method/path/query/header/body 请求全局并保持 NUL 契约，串行 dispatch + 100 ready/pending cap，`recv_and_parse` 在阻塞 poll 前主动 drain 已缓冲 stream；**FFI diff=0**；关键修复：active-request H2 标记避免 response facade 重入 `conn_table` lock（否则 HTTP/1 413/raw malformed 会死锁），conn_done 后 buffered multiplex 不等待新 socket 事件；fmtool 新增零依赖 H2 客户端 → e2e **504→511/511**（H2-1..7）/ bridge **483/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c=34,916.2 req/s）/ binary **4,221,136 B**（≤6 MiB CI 门禁, +36,864 B）/ ldd 仅 libc / env -i 干净启动 / C=Python=orphans 0；边界=无 TLS/ALPN/h1 Upgrade、串行 dispatch、无 trailers/server push/WS-over-H2、仅 connection send window 且窗口不足 fail-fast、响应不建 HPACK 动态表

- **已决策-64**：**原生 TLS/HTTPS = opt-in rustls + 纯 Rust RustCrypto provider**（ADR-0039, `tls-rustls` bead 销账）：`FASTAPI_MOJO_TLS_CERT/KEY` 成对设置启用、`FASTAPI_MOJO_TLS_ALPN` 默认 `h2,http/1.1`，证书/私钥/ALPN 错误启动 fail-closed；依赖收敛为 `rustls=0.23.42` + `rustls-rustcrypto=0.0.2-alpha`（双方 default features 关闭，rustls `tls12` 未启用），**不使用 ring/aws-lc/OpenSSL**，enabled normal+build 闭包 79 crate 且 C/asm 源=0；TLS 1.3-only，provider 上游标注 alpha/非生产；实现为 `fd→ServerConnection` per-process session 表 + `tls::recv/send_all/close` transport adapter，HTTP/1、WS、SSE 与 H2 状态机不感知 TLS，**FFI diff=0**；修复 Mojo 64-bit Int 读取 C int `-1` 变 `4294967295` 的 bind 失败哨兵漏判（原 TLS 配置失败后空 poll 假活）；e2e openssl/curl 仅 dev 工具生成自签证书并验证 TLS-0..9 → e2e **511→521/521** / bridge **486/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c=32,372.94 req/s）/ binary **4,954,416 B**（≤6 MiB，+733,280 B）/ ldd 仅 libc / env -i HTTP+TLS health 200 / 多 worker + keep-alive + ALPN h2 + 明文拒绝实测通过 / C=Python=orphans 0；边界=alpha provider、TLS1.2/mTLS/加密 key 密码/热加载/OCSP/SNI 多证书/session ticket 调优均不支持，公网生产建议反代终结
- **已决策-65**：**UPX 复评：仍为 opt-in 手动部署副本，不用 readelf 替代 ldd**（ADR-0040, upx-revisit bead 销账）：当前 TLS 产物 4,954,416 B 用 UPX 5.2.1 `-9` → **1,718,420 B（-65.32%）**，冷启动均值 12.1→31.6ms、RSS 持平；`--brute` 仅再省 191,248 B 但冷启动约 95ms，拒绝；UPX 副本 e2e **521/521**、bench 6 场景 0 errors（get_root_10k_100c=30,120.48 req/s，单机噪声区间）、`upx -t` / env-i health 200 / 无孤儿；实测压缩 stub 无 `INTERP`/`NEEDED`，**readelf 不能恢复原 ELF 依赖元数据，不能替代未压缩产物 ldd North Star 门禁**，未来若发布压缩副本只能采用“未压缩 ldd 先行 + 压缩副本 upx-test/smoke”双产物验证；决策保持 UPX 不进默认 build/CI 主产物。`compress_upx.sh` 强化：压缩前动态 PIE + ldd 白名单预检、临时文件 UPX `-9`、`upx -t`、默认 env-i `/health` smoke、通过后保存 `.pre-upx` 并替换、已有备份拒绝二次压缩、`--restore` 回滚后复验 ldd；恢复后正常 binary 4,954,416 B / ldd 仅 libc / C=Python=0。

- **已决策-66**：**大响应 JSON 序列化 opt-in Rust 加速（response-only，默认 Mojo 不变）**（ADR-0041, json-rust bead 销账）：`FASTAPI_MOJO_JSON_SERIALIZER=rust` + `FASTAPI_MOJO_JSON_RUST_MIN_BYTES`（默认 65,536 输入字节，非法/非正回退默认）在 `response_model_body` 单点分流；Rust std-only 手写 `JsonObjectWriter` 承担 byte-heavy escape/缓冲，Mojo `Dict` 继续拥有字段顺序，输出与 `json.mojo` 字节兼容（`", "` 分隔 / `": "` / `__nested__` raw passthrough / 控制字符契约一致），FFI +4（`fm_json_object_begin/add/finish/free`，显式输入长度，输出 `malloc(n+1)+NUL`），失败回退 Mojo；配套 `span_to_str` ASCII fast path 批量构造，避免 Rust 输出再被 Mojo byte-loop 抵消；fmtool bench 新增 `data_file`→`hey -D` 以支持 >128KiB body（避开 `E2BIG`）。实测 escape 密集 1,000,014B JSON request（1,000,000 个待 escape 引号，n=200/c=1，两组均值）：**91.27→113.35 req/s（+24.19%）**、平均延迟 10.96→8.83ms、P50 10.70→8.50ms；canonical bench 6 场景 0 errors（get_root_10k_100c=34,722.22 req/s）；e2e **521→527/527**（JR-1..6，主 server 全程 Rust path 回归）/ bridge **496/0/4**（+10）/ fmtool **35/0** / clippy 0（双 crate）/ string_builder 自检绿 / binary **4,962,656 B**（≤6 MiB，+8,240 B）/ ldd 仅 libc / env-i 默认+opt-in health 200 / C=Python=orphans 0。边界：request body 解析仍在 Mojo，仅 flat response dict object；`__nested__` raw JSON 有效性由调用方保证；当前 per-worker 串行 dispatch 依赖 global writer，未来 bridge 内并发 response dispatch 需 session-handle FFI。

- **已决策-67**：**OAuth2 作用域（Security scopes / SecurityScopes parity）**（ADR-0042, `oauth2-scopes` bead 销账）：声明式 `_auth_scopes`（`_auth=oauth2` 路由, `;` 分隔, scope 名可含 `:`）→ 必需 scope gate；`_jwt_scopes`（token 路由）签发 RFC 6749 `scope` claim（空格 join）；`check_oauth2`（get_current_user 等价）在 token 有效后校验 scope 覆盖，缺 scope → **403 `Not enough permissions`** + `WWW-Authenticate: Bearer scope="<space-joined>"`，坏 token → 401 + 同样 scope 片段，无 Authorization → 401 `Bearer`（无 scope 片段, 框架先抛 parity）；OpenAPI **securityScheme 修正为上游 oauth2 flows 形态**（`type:oauth2` + `flows.password.{scopes,tokenUrl}`, 声明 `_oauth2_scopes`/`_oauth2_token_url`）+ operation `security` scope 数组（`_auth_scopes`）；**FFI diff = 0**（复用 HMAC FFI）；`mojo run security_jwt.mojo` 自检扩 scope 向量；e2e **527→535/535**（OT-24/25 改 oauth2 flows + scoped security + OT-26..OT-33）；binary ≤6 MiB；ldd 仅 libc；env-i 干净启动；C=Python=orphans 0。边界：403 body 沿用 `{detail,status}`（上游仅 detail）；scope 校验内建在 `check_oauth2`（上游是用户 get_current_user）；`_jwt_scopes` 静态声明（上游按用户动态授予）；`_depends` 依赖不接收 SecurityScopes 对象。
- **已决策-68**：**RedirectResponse 等价（307/303/301/308 + Location）**（ADR-0043, `redirect-response` bead 销账）：`fastapi.responses.RedirectResponse` 补齐 —— 新增 `KIND_REDIRECT()` + dispatch 特例 + Rust bridge `send_redirect_response` FFI（**FFI +1**）；声明 `_redirect_url` + 可选 `_redirect_status`（默认 `"307 Temporary Redirect"`，支持 303/301/308）。wire 逐字段对齐上游 Starlette：**无 Content-Type**（`media_type=None`）、`Content-Length: 0`、`Location: <quoted url>`、空 body；URL 按上游 safe set `:/%#?=@[]!$&'()*+,;`（+ `_.-~` + alnum）百分号编码（空格→`%20`，非 ASCII 逐字节 `%XX`）；HTTP/2 走 HEADERS-only 帧（无 content-type, `content-length: 0`, END_STREAM）。纯函数 `redirect_quote` / `build_redirect_headers` + `send_tests.rs` 4 单测（quote/头装配/真 socket 字节/status 透传）；e2e **535→545/545**（RD-1..RD-10：307 默认/无 CT/CL:0/空 body/303/301/308/URL quote/testclient --no-follow/testclient follow）/ bridge **500/0/4**（+4）/ fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary **4,999,520 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0。边界：非路由自动尾斜杠重定向（`redirect_slashes` 单独跟踪）；redirect 无 body 故不触发 GZip/用户中间件 response 面（与 streaming 同型）。
- **已决策-69**：**安全 OpenAPI 对齐（securitySchemes 全量 + operation security）+ HTTPDigest**（ADR-0044, `security-openapi-digest` bead 销账）：补齐上游安全面两处缺口 ——（1）**HTTPDigest stub parity**：新增 `_auth="digest"` 分支（`security.mojo` `_eq_ci` 大小写不敏感 + 非空 credentials；缺/非 digest → **401 `Not authenticated` + `WWW-Authenticate: Digest`**；成功注入 `auth_scheme`（原样大小写）/`auth_credentials`）；（2）**OpenAPI securitySchemes 全量**：basic/bearer/digest → `{"type":"http","scheme":...}`、apikey → `{"type":"apiKey","in":...,"name":...}`（键序 type,in,name）、oauth2 flows；operation `security:[{"<scheme>":[...]}]` 覆盖所有 `_auth` 路由；新增 `_auth_scheme_name` 覆盖默认 scheme 名（上游 `scheme_name=`）。**从 `openapi.mojo`（决策-67 后 513 行超阈值）拆出 `openapi_security.mojo`（212 行）**，openapi.mojo 回落 **444 行**；（3）**附带修复 pre-existing bug**：OpenAPI `paths` method 关键字大写 `"GET"` → 小写 `"get"`（OpenAPI 3.0 固定字段；此前 `/docs` Swagger UI 无法渲染任何 operation）。**FFI diff = 0**（复用 `extract_request_header`）；e2e **545→556/556**（DG-1..6 + SO-1..5）/ bridge **500/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary **5,020,000 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0。边界：HTTPDigest = 上游 stub（不做 RFC 7616 摘要校验）；basic/bearer/apikey 运行时仍是白名单校验（ADR-0011 既有）；401 body 沿用 `{detail,status}`。
- **已决策-70**：**安全面收敛之二 — OpenIdConnect + OAuth2AuthorizationCodeBearer**（ADR-0045, `fastapi_mojo-cz1` bead 销账）：补齐上游 `fastapi.security` 剩余两类 ——（1）**OpenIdConnect stub parity**：`_auth="openid"` + `_openid_url` → **只校验 Authorization 头存在**（任意 scheme，含 `Basic x`）—— 缺失/空 → **401 `Not authenticated` + `WWW-Authenticate: Bearer`**；存在 → ok 并注入 `auth_credentials` = **原始头**（上游依赖返回值 = 原始 authorization）；OpenAPI `{"type":"openIdConnect","openIdConnectUrl":"<url>"}`；（2）**OAuth2AuthorizationCodeBearer**：`_auth="authcode"` + `_authcode_authorization_url` / `_authcode_token_url` / `_authcode_scopes` → 运行时首个空格切 scheme/param，scheme 大小写不敏感 `bearer`（param 可空）→ 200 + `auth_token`；缺失/非 bearer → 401 + `WWW-Authenticate: Bearer`；OpenAPI `{"type":"oauth2","flows":{"authorizationCode":{"scopes":{...},"authorizationUrl":"..","tokenUrl":".."}}}`；（3）**键隔离**：`_oauth2_scheme_scopes_json(router, code)` 增加选择器 —— password 用 `_oauth2_*`、authorizationCode 用 `_authcode_*`，**两套键故意分离**避免并存时 tokenUrl/scopes 互相覆盖（e2e AC-7 守护）。**FFI diff = 0**（复用 `extract_request_header`）；e2e **556→567/567**（OI-1..4 + AC-1..7）/ bridge **500/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary **5,024,096 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0。边界：openid = 上游 stub（不校验 token）；authcode = 只提取 Bearer（不校验 JWT，上游同款）；param 空 → `auth_token` 不注入（注入约定：空值跳过）。
- **已决策-71**：**Starlette `redirect_slashes` 等价（默认尾斜杠 307）**（ADR-0046, `fastapi_mojo-kvd` bead 销账）：实现 Starlette Router 默认路由行为 —— 请求路径未匹配时，把尾部斜杠取反（`/a/b` ↔ `/a/b/`，`rstrip` 去全部尾斜杠）再试；命中（**path 命中即可，method 无关**，上游 `match != NONE`/PARTIAL 同型）→ **307 Temporary Redirect** 到**绝对 URL** `scheme://host<alt>?<query>`；根路径 `/` 不重定向；否则维持 404。新增纯逻辑模块 `redirect_slashes.mojo`（`alt_slash_path` + `build_redirect_location` + `mojo run` 自检）；dispatch 在「未匹配」分支接线，**复用决策-68 `send_redirect_response`（wire 形态一致：无 Content-Type + `Content-Length: 0` + `Location` + 空 body）**，scheme 取 TLS env（同 OpenAPI servers）、host 取 `Host` 头（缺失兜底 `127.0.0.1:<port>`）。**支撑修复**：fmtool testclient `Host` 此前无端口 → 绝对 Location 丢端口、follow 连错口；改为非默认端口带端口（对齐 httpx / 既有 WS testclient `parts.addr()`）。**FFI diff = 0**；e2e **567→577/577**（SL-1..SL-10）/ bridge **500/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary ≤6 MiB / ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0。边界：内置 `/openapi.json`/`/docs`/`/metrics`/`/traces` 走 router 前特判，未纳入 slash-redirect。
- **已决策-72**：**SSE `ServerSentEvent` 字段等价（event / id / retry / comment）**（ADR-0047, `fastapi_mojo-sdo` bead 销账）：对齐上游 FastAPI 0.140+ `fastapi.sse.format_sse_event(*, data_str, event, id, retry, comment)` —— `streaming.mojo` 重写（150 LOC）为全字段序列化，**字段序 = comment（逐行 `: <line>`）→ event → data（逐行 `data: `）→ id → retry，末尾 `\n\n`**；行切分 `_split_sse_lines`（`\r\n`/`\r` → `\n`，**split 保留尾空串** —— `data="tail\n"` → `data: tail\ndata: \n\n`）；`data` = 上游 `raw_data`（**原样，不 JSON 编码**，既有语义保持）。dispatch `KIND_SSE` 分支新增读 `_sse_event`/`_sse_id`/`_sse_retry`/`_sse_comment`（路由级字段，施加到该路由每个事件）→ `build_sse_body_fields(...)`；旧入口 `build_sse_body`/`format_sse_event(data)` 零行为变化（向后兼容）。**FFI diff = 0**（纯逻辑模块，零新依赖）；e2e **577→582/582**（SF-1..SF-5：content-type / 全字段序逐字节 / comment 每事件 / 尾空串保留 / data raw）；bridge **500/0/4** / fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary **5,044,576 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0。边界：字段为**路由级**（每事件同字段），非上游逐事件异构 `ServerSentEvent(event=.., id=..)`（声明式模型承载不到；常见 SSE 用法覆盖）。
- **已决策-73**：**Starlette `CORSMiddleware` 全量等价（预检 wire + regex/expose/PNA）**（ADR-0048, `fastapi_mojo-utm` bead 销账）：决策-42 CORS 基础上对齐上游 starlette 1.6.0 —— **真预检（Origin+ACRM）成功 = 200 + `text/plain; charset=utf-8` body `OK`**（原 204 空体）/ **失败 = 400 + text/plain `Disallowed CORS <origin,method,headers,private-network>`**（原 JSON），两种情况都带**完整 preflight 头集**（`Vary: Origin`/`*` + Allow-Methods + Max-Age + [Allow-Headers] + [Credentials] + 动态 Allow-Origin / 镜像 / PNA）；补齐 `FASTAPI_MOJO_CORS_ORIGIN_REGEX`（`re.fullmatch`，走手写 regex 引擎 `rgx_fullmatch`）/ `_EXPOSE_HEADERS`（`Access-Control-Expose-Headers`）/ `_PRIVATE_NETWORK`（PNA）；`FASTAPI_MOJO_CORS_METHODS=*` → `ALL_METHODS`（DELETE 起头）/ `_HEADERS=*` → 预检**镜像**请求头；`allow_headers` 头行 = `sorted(SAFELISTED_HEADERS ∪ 配置)`；method 匹配**大小写敏感**；普通响应 `simple_headers` 恒发（含 origin 不被允许时仍发 Credentials/Expose-Headers，上游 quirk）+ echo 时 `Vary: Origin`；PNA 头走 request 全局（io.rs 解析）→ **FFI 符号数不变**（仅 `send_preflight_response` 返回值 = HTTP 状态码，供 access log）；H2 预检改直出 `header_frames`（修既有 `normal_cors_lines` 叠加重复头 bug）。e2e **582→587/587**（CRS-1..9 + CRS2-1..4）/ bridge **503/0/4**（cors 测试重写为上游矩阵）/ fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary **5,052,840 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0。边界：裸 OPTIONS / 无 ACRM → 仍 204 通配超集（既有文档化特性，ADR-0017 §3.2，本轮不翻案）；`allow_origin_regex` 受限于手写 regex 子集。
- **已决策-74**：**`HTTPException(..., headers=...)` / 异常 handler 自定义响应头等价**（ADR-0049, `fastapi_mojo-0n1` bead 销账）：补齐决策-49 异常面唯一缺口 —— 异常响应可携带自定义头。**Rust bridge**：`send_text_response_status_extra(fd, status, body, extra)`（text/plain，extra 空→与 `send_text_response_status` 字节一致）+ `ffi.rs` 同名 `#[no_mangle] extern "C"` 导出（**+1 FFI 符号**，对齐既有 `send_simple_response_extra` 风格，JSON 面复用后者）。**Mojo 声明式头表**：`exception_handlers.mojo` 增 `_has_colon` / `parse_exc_headers`（`;` 分隔 `TAG=H1|H2`，`|` 分隔多头，`:` 校验，非法条目静默跳过 + 同 tag 后者胜，与 `parse_exc_table` 同款容错）/ `load_exc_headers`（路由级 `_exc_headers` 整体替换 env `FASTAPI_MOJO_EXCEPTION_HEADERS`，§3.5-7 同款）；`GuardResult` 增 `extra: String`（`\r\n` 分隔头行）；`resolve_exception_response` 命中 tag（或 `Exception` catch-all）时填 `out.extra`；demo `/exc/headers`（`Teapot:418:{"detail":"brewing"}:json` + `X-Reason: tea|WWW-Authenticate: Teapot` = 上游 `HTTPException(418, headers)` 语义）。e2e **587→591/591**（XH-14 路由头 / XH-15 env 精确 tag / XH-16 catch-all / XH-17 路由覆盖 env）/ bridge **505/0/4**（send_tests +2）/ fmtool **35/0** / clippy 0（双 crate）/bench 6 场景 0 errors / binary **5,065,128 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0；边界=声明式头表（非运行期 `headers=` dict）、头值不支持内嵌 `|`/`;`、未命中 tag（默认 500）无头。
- **已决策-75**：**`Depends(yield)` 等价 — 依赖 teardown（声明式 `_dep_teardown`）**（ADR-0050, `fastapi_mojo-dep-teardown-18z` bead 销账）：补齐决策-33/47 依赖注入唯一缺口 post-response teardown。**上游实测**（fastapi 0.141.1 `request_response`：`AsyncExitStack` 包 `await response(...)`）→ teardown **在 background tasks 之后**、**逆进入序 LIFO**、异常时裸后置代码被跳过（仅 `try/finally` 保证）。**声明式 API**：依赖 handler `data["_dep_teardown"] = "cmd1\ncmd2"`（与 `_background` 同换行分隔）；`dispatch_dep`/`resolve_depends` 增 `mut teardowns: List[String]`（**内部签名，非 FFI**），依赖**实际派发**时登记（memo 命中不登记 → `use_cache=True` 每请求一次；子依赖先于父 = 解析完成序）；`_run_dep_teardowns` 响应 flush **后逆序**执行（LIFO = 上游 ExitStack），命令 2000ms + `[dep-teardown]` 日志（复用新提取 `_exec_one_cmd`，与 `_background` 共享）；接入点 ×6（正常 JSON 路径在 `_run_background` **之后** → bg 先于 teardown / 异常 / SSE / streaming / File / Redirect）；每请求 collector 重置。demo `dep_td_inner`/`dep_td_outer`（嵌套）+ `/di-teardown`(+`_background`) / `/di-teardown-raise` / `/di-teardown-twice`。e2e **591→595/595**（DT-1 嵌套输出 / DT-2 序 `BG,OUTER,INNER` / DT-3 异常 418 后仍 `OUTER,INNER` / DT-4 缓存 teardown 一次）/ bridge **505/0/4**（**FFI diff=0**，本轮无 Rust 改动）/ fmtool **35/0** / clippy 0（双 crate）/bench 6 场景 0 errors / binary **5,077,416 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0；边界=声明式 shell 命令（非运行期生成器）、teardown **恒执行**（= 上游 `try/finally` 形式；裸后置异常跳过不模拟）、命令不含换行。
- **已决策-76**：**内置文档路由补全 —— `/redoc` + `/docs/oauth2-redirect`**（ADR-0051, `fastapi_mojo-redoc-oauth2-redirect-oxc` bead 销账）：补齐上游 FastAPI 默认 4 条内置路由中缺失的 2 条（此前仅 `/openapi.json` + `/docs`）。**上游实测**（fastapi 0.141.1 `app.routes`）默认注册 `/openapi.json` / `/docs` / `/docs/oauth2-redirect` / `/redoc`（均 GET+HEAD）。**`openapi.mojo` 新增两个纯函数**：`redoc_html(title, openapi_url)`（`<title>{title} - ReDoc</title>` + `<redoc spec-url="…">` + jsdelivr `redoc@2` standalone bundle + upstream noscript/favicon/viewport）+ `swagger_ui_oauth2_redirect_html()`（逐字对齐上游 `get_swagger_ui_oauth2_redirect_html`：`window.opener.swaggerUIRedirectOauth2` + state 校验/accessCode/错误分支/`window.close()`，无参数）；`swagger_ui_html` 补 `oauth2RedirectUrl:window.location.origin+"/docs/oauth2-redirect"`（上游 `/docs` 同款）。**`http_server_final.mojo` 新增两条内置分支**（紧邻 `/docs`）：`/redoc`（标题读 `FASTAPI_MOJO_OPENAPI_TITLE`，与 `/docs`/`/openapi.json` 同源）+ `/docs/oauth2-redirect`，均走 `send_html_response` + `_finish_request` telemetry + `conn_done`；HEAD 由既有 `is_head`/`effective_method` 归一自动覆盖。**FFI diff = 0**（零新导出/零新 crate/零新依赖）。e2e **595→600/600**（DOC-1a/1b `/redoc` 200 + text/html + `spec-url="/openapi.json"` / DOC-2 `/docs/oauth2-redirect` 200 + `swaggerUIRedirectOauth2` / DOC-3 `HEAD /redoc` 200 / DOC-4 `/docs` 含 `oauth2RedirectUrl`）/ bridge **505/0/4**（本轮无 Rust 改动）/ fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary **5,089,704 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动（`/redoc` 200）/ C=Python=orphans 0；边界=两条内置路由**固定路径**（未建模 `docs_url=/redoc_url=None` 配置面，与既有 `/docs` 一致）、HEAD 沿用内置分支行为（发送完整 HTML body；上游 HEAD 长度 0 = 既存偏差，`/docs` 同款，本轮不翻案）、HTML 引用 CDN（离线可替换本地 dist，`/docs` 既有同款）。
- **已决策-77**：**HEAD 请求统一仅头无体（桥接层 request 全局抑制）**（ADR-0052, `fastapi_mojo-ki9` bead 销账）：修复 HEAD 响应把完整体字节留在 keep-alive 连接上的协议脱轨 bug，对齐上游 FastAPI HEAD 语义（响应头与 GET 相同、`Content-Length` = 完整体长度、body 为空；RFC 9110 §9.3.2）。**上游实测**（fastapi 0.141.1）：4 条内置路由注册 GET+HEAD（HEAD → 200 无体）；改前本仓库 `/docs`/`/redoc`/`/docs/oauth2-redirect`/`/openapi.json`/KIND_HTML/streaming 的 HEAD 仍发完整体（用户 JSON 路由早已正确）。**`send_response` 单点抑制**（`include_body = include_body && !current_method_is_head()`）覆盖内置 doc 路由 / KIND_HTML / JSON / static / SSE / error / 404 / 405（H1+H2 同享；GZip 以 include_body 为门 → HEAD 不压缩）；**`send_streaming_response` HEAD 仅头**（H1 发头后直接返回；H2 `http2_response::send_streaming` → HEADERS 带 END_STREAM、跳过 DATA）；判定复用既有 `request::current_method_is_head()`（`file_serve` HEAD 分支同 helper）。**FFI diff = 0**（零新导出/零新 crate/零 io.rs 改动）。fmtool `headbody <port> [path]`（可选路径 + `Connection: close`）。e2e **600→604/604**（HD-1 `/docs` / HD-2 `/redoc` / HD-3 `/docs/oauth2-redirect` / HD-4 `/openapi.json`：body 0 且 CL == GET 长度）/ bridge **507/0/4**（send_tests +2）/ fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors / binary **5,089,704 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动（/redoc 200）/ C=Python=orphans 0；边界=用户 GET 路由 HEAD 仍 200（既有文档化超集，上游 405；本轮只保证 HEAD 无体语义正确）、非 FastAPI 内置路由（/metrics、/traces）HEAD 亦随单点抑制无体。
- **已决策-78**：**GZip 中间件 Starlette 1.6.0 全量对齐**（ADR-0053, `fastapi_mojo-mxs` bead 销账；**取代 ADR-0015 §3/§7**）：实读上游 `starlette/middleware/gzip.py`（1.6.0）+ ASGI 原始 message 探测（fastapi 0.141.1）逐项修正决策-40 的五处偏差 —— ① **`Vary: Accept-Encoding` 在可压响应上恒加**（上游 `IdentityResponder` 亦然：未接受 gzip 的客户端也收到 Vary；小体/排除/206/有 CE/HEAD 则不加）；② client 判定 = **大小写敏感子串** `"gzip" in Accept-Encoding`（`GZIP`/`Gzip` 不命中，`x-gzip`/`gzip;q=0` 命中）；③ **默认排除表 13 项**（`application/zip`/`image/{gif,png,jpeg,webp,avif}`/`font/woff{,2}`/`text/event-stream`/`video/*`/`audio/*` …）；④ **streaming 可压**（`more_body` 分支，不受 min_size 门；压则删 CL）；⑤ **FileResponse 可压**（≥ min_size）；`compresslevel` 6→**9**。**实现**：`bridge/gzip.rs` 重写（`DEFAULT_EXCLUDE` + `GzipConfig` + `plan()→GzipPlan{vary,compress}` + `media_type_excluded`/`extra_has_content_encoding`/`extra_add_lines`/`merge_extra`）+ `parse::accepts_gzip` 改大小写敏感子串 + 三发送点接线（`send_response` 单点 / `send_streaming_response`（合并体→单 gzip chunk）/ `file_serve::send_full`（`read_all` ≤4 MiB + CL=压缩长度））+ `http2_response::send_streaming` 改收 `&[u8]`；**FFI diff = 0**（无签名变更/无新符号/零新 crate）。**上游实测**（system python ASGI 捕获）：`/json ae=gzip → CE+Vary；ae=None → Vary identity；ae=GZIP → Vary identity`；`/small → 无 Vary`；`/f30 → 无 Vary`；`/f2000 ae=gzip → CE+Vary+CL=35`。cargo **509→516/0/4**（+7）/ fmtool **35/0** / clippy 0（双 crate）/ e2e **604→609/609**（GZ-1..GZ-10）/ bench 6 场景 0 errors / binary **5,093,824 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0。边界=大 FileResponse（≥64 KiB）上游 streaming（无 CL）本实现单 body（有 CL）；streaming 压缩 = 上游逐块 `Z_SYNC_FLUSH` vs 本实现合并 gzip（解压等价）；`FASTAPI_MOJO_GZIP_MAX_SIZE` 为非上游内存保护扩展；flate2 vs zlib 输出非逐字节相同（解压一致）。
- **已决策-79**：**pydantic 内建标量类型全量对齐（uuid/date/datetime/time/timedelta/decimal）**（ADR-0054, `fastapi_mojo-2wd` bead 销账）：补齐此前仅 `str/int/float/bool`（+ enum/list）的参数类型面 —— 6 类 pydantic 内建标量 path/query/header/body/form/list 全场景强制转换 + 422 校验。**纯 Mojo（零新 FFI/零新 crate/零 C）**：`date_types.mojo`（317）/`time_types.mojo`（248）/`scalar_types.mojo`（297）（`parse_date` / `parse_datetime`（ISO + epoch，Hinnant civil-from-days）/ `parse_time` / `parse_timedelta`（ISO-8601 duration + `[N day[s]][, H:MM:SS]`）/ `_parse_uuid`（连字符/简单/花括号/`urn:uuid:`，输出小写）/ `_parse_decimal`（Python `Decimal(s)` 语法 + 有限数检查））。**422 parity**：`type`/`msg`/`ctx`/`input` 逐字段对齐上游 pydantic_core 2.46.4（uuid_parsing / date_parsing / date_from_datetime_inexact / datetime_from_date_parsing / time_parsing / time_delta_parsing / decimal_parsing / finite_number）。**OpenAPI**：uuid→`string/uuid`、date→`date`、datetime→`date-time`、time→`time`、timedelta→`duration`、decimal→`anyOf[number, string/pattern]`。**Mojo 1.0.0 踩坑**：`String[byte=i]` 在多字节码点内部会 assert → 新增 byte-safe `bof(s,i)=Int(s.as_bytes()[i])`（全部 `ord(x[byte=…])` 机械重写为 `bof`）。接线：`numlit.parse_base` 接受 6 标量名（别名大小写不敏感，`duration`→timedelta）+ 标量 list + 拒标量 enum 括号，`parse_typed_value` 委派 `parse_scalar`；`params_typed`/`params_query_extra`/`param_constraints_run`/`form_params`/`body_schema`/`body_validate`/`openapi_schemas` 按 `is_scalar_type` 分流到 `scalar_error_object`；11 demo 路由 `/scalar/*`；`scalar_types_selftest.mojo`（~60 断言，入 CI 列表）。e2e **609→664/664**（SC-1..SC-37）/ bridge **516/0/4**（本轮无 Rust 改动）/ fmtool **35/0** / clippy 0（双 crate）/ bench 6 场景 0 errors（get_root_10k_100c≈32.6k req/s）/ binary **5,151,168 B**（≤6 MiB）/ ldd 仅 libc / env-i 干净启动 / C=Python=orphans 0；边界=uuid 仅字符串形态、decimal 无精度/位数限制、path 参数不 URL 解码、handler 回显不归一化、少量 speedate 畸形分支（ADR-0054 §3.5）
- **已决策-80**：**请求 path 百分号解码（uvicorn 等价）**（ADR-0055, `fastapi_mojo-v50` bead 销账）：补矩阵 #2 路径参数取值规范化 —— uvicorn 在 Starlette 路由**之前**对 request target 做百分号解码。此前 `/items/a%20b` 原样回显 `"a%20b"`；现 `var raw_path = get_path_slice; var path = url_decode_path(raw_path)`（新纯函数 `params_query.url_decode_path`：`%XX`→单字节 / `+` **不**转空格 / 畸形 `%` 保留字面量 / 解码字节 `decode_utf8_bytes` → 非法 UTF-8 = U+FFFD，等价 `unquote(errors="replace")`）。**全链路一致**（解码后 path 供 router/static/param/访问日志/OTel/WS-upgrade 使用）：`a%20b`→`a b`、`%7Bx%7D`→`{x}`、`%E4%B8%AD`→`中`、`a+b`→`a+b`、**`a%2Fb`→404**（解码后分段）、`%FF`→`�`、`%`→`%`、`%25`→`%`、编码 `../` 静态 403；redirect Location 用 wire `raw_path` 拼装（等价上游 `URL(scope)` 重编码）。**FFI diff = 0**（纯 Mojo，零 Rust/零 C 改动）；e2e **664→676/676**（PD-1..PD-11）/ bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary ≤6 MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0；边界=WS 数据帧路径仍 wire（升级匹配已解码）/ `%00` NUL FFI 截断 / Location 不重编码（ADR-0055 §3.5）
- **已决策-81**：**lax 标量强制转换 + 规范化回显（int/float/bool）**（ADR-0056, `fastapi_mojo-vg4` bead 销账）：pydantic v2 lax 语义 —— 此前类型化 int/float/bool 成功路径原样回显请求串（`/calc/007/4`→`"007"`）；现 path/query/header/form/body JSON model 全场景按 lax 解析 + 回写规范化值。纯 Mojo：`numlit.parse_int_lax`（`007`→7 / `+5`→5 / `-0`→0 / `-0007`→-7 / `1_0`→10 / **整值小数 `2.0`→2、`12.00`→12**；`2.5`/`2.`/`1e2`/`0x10`→int_parsing）+ `numlit.parse_float_lax`（`1.50`→1.5 / `1e3`→1000.0 / `007.0`→7.0 / `-0.0`→-0.0 / `1.`→1.0 / `.5`→0.5 / `1_0.5`→10.5 / 纯 int→`42.0`；`Float64`→String = CPython repr）+ `parse_bool_literal` pydantic lax 集（yes/y/t/on/1/TRUE→true；no/n/f/off/0/OFF→false）；新 `params_typed.canonicalize_typed_values` 在 `apply_query_extras` 后回写（path/query + alias 双键 + list 逐元素 CSV）；`form_params.apply_form_extras` / `param_constraints_run.validate_headers_collect` / `body_validate._validate_fields`（含 JSON string→int/float/bool lax：`"007"`→7 / `"9.50"`→9.5）同款；str/enum/标量类型保持 raw（决策-79 echo 契约）。**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **676→709/709**（CX-1..CX-21 + JS-3 改写）/ bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0；偏差=body JSON float/bool→int 严格 / 非有限 float 渲染 / 回显 JSON 类型（ADR-0056 §3.5）
- **已决策-82**：**body JSON 跨类型标量强制转换（pydantic model lax）**（ADR-0057, `fastapi_mojo-g3p` bead 销账）：补齐矩阵 #4 body model 字段取值规范化最后一维 —— 此前 body JSON int/float/bool 字段只收「同族」JSON 类型（`int` 字段收 JSON float `7.0` → 422 int_parsing）；现按 pydantic v2 model lax **跨 JSON 类型**强制：`int` ← JSON float 整值（`7.0`→7 / `1e2`→100 / `-3.0`→-3）/ bool（`true`→1 / `false`→0）/ string（`parse_int_lax`），非整 float → `int_from_float`，`null`/`{}`/`[]` → 裸 `int_type`；`float` ← JSON int/bool（`1`→1.0 / `true`→1.0）/ string，`null` → `float_type`；`bool` ← JSON 0/1/-0.0/1.0（`1`→true / `0`→false），其它数值 → `bool_parsing`，`null` → `bool_type`；数组元素（`int[]`/`float[]`/`bool[]`）逐元素同规则 + 规范化 JSON 文本重建（`[7.0,1e2,true,"7"]`→`[7,100,1,7]`）。新 `body_validate._coerce_body_scalar`（单一跨类型强制点）/ `_elem_json_type` / `_elem_type_err`；`_type_err` int/float/bool 改裸 `*_type`（仅完整类型不匹配/null）；嵌套/obj[] 经同一 `_validate_fields` 自动继承。**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **709→733/733**（BY-1a..BY-9b 24 项）/ bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0；偏差=string→int 非整仍 int_parsing / 回显 JSON 类型 / 非有限 float（ADR-0057 §3.5）
- **已决策-83**：**body 422 detail pydantic 逐字段对齐 + 多字节 body/form 崩溃修复**（ADR-0058, `fastapi_mojo-tew` bead 销账）：body 422 detail 逐字段对齐上游 pydantic v2 —— 约束类错误追加 `ctx`（`min_length`/`max_length`/`pattern`/`multiple_of`/`gt|ge|lt|le`/`field_type+min|max_length+actual_length`/`expected`；house 键序 `loc,msg,type,input,ctx` ctx 末位 = ADR-0029 §3.7）；新增 `mo=N`（multiple_of）+ 数值首违序 `mo→le→lt→ge→gt`（同字段仅首个）；str 长度改 **codepoint** 计数（`String should have at least/at most N characters`，修 ADR-0014 §4 字节计数偏差）；列表长度错 `too_short`/`too_long` + `actual_length` + 单复数 `item(s)` + **短路**元素校验；enum 带 `ctx.expected`；**`input` 片段按 JSON 类型渲染**（JSON 字符串值恒带引号：`"1"`/`"1e1"`/`"0.3"` 不再被误当数字）。**附带 P0 修复**：① `numlit.parse_float_lax` 丢负号（`-5`→`5.0`）；② Mojo `String[byte=i]` 码点内部 assert 致 **server 崩溃** —— form/cookie 值（`request_response._bof` 字节安全）+ body 数组元素（`_split_json_array`）（实测 `--data '{"s":"é",...}'` / `["a","é"]` / multibyte Cookie 均崩溃 → 修复）。约束应用层拆到新 `body_constraints.mojo`（198 LOC；`body_validate.mojo` 523→333，回 <500 阈值）。**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **733→768/768**（MX-1a..MX-13 28 项 + BY-3c..BY-3e 3 项）/ bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary 5,204,416 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0；偏差=house 键序 / CT 不参与 JSON 分派 / 非有限 float / 裸非 ASCII 查询值（ADR-0058 §5）
- **已决策-84**：**多字节 / 非法字节 raw wire 输入字节安全（全请求面）**（ADR-0059, `fastapi_mojo-multibyte-wire-byte-safety-led` bead 销账）：兑现 ADR-0058 §8 后续缺口 #1 —— 原始（非 curl 重编码）多字节/非法字节 wire 输入在 path/query/header/auth/WS-subprotocol/body/access-log 全请求面触发 Mojo 1.0.0 `String[byte=i]` 码点边界 `Assert Error` → **server 进程 abort（可远程 DoS）**。修复：`string_builder.trim_spaces`/`next_codepoint_len` 字节安全 + `span_to_str` 非 ASCII 分支重写为全边界+continuation 校验（非法 lead `0xF5..0xFF`/截断 → U+FFFD，消除越界读）；`redirect_slashes.alt_slash_path` / `params_query.url_decode_path`+`_hexval` / `params_json` 标量扫描 / `params_query_extra.split_csv` / `form_params.lower_ascii` / `numlit._lower_ascii` / `openapi_custom._lower_ascii` / `date_types._lower` / `middleware._json_escape`（codepoint-aware）/ `security`（`_bt`+`_starts_with`/`b64_decode`/`_split_csv`/`_trim`/digest+authcode 空格扫描）/ `security_jwt`（`_bt`+`b64url_encode`/`_jwt_parts`/`_json_field`/`_int_or`/`_has_scope`/`check_oauth2`）全部改 `as_bytes()` 字节安全。**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **768→785/785**（MB-1..MB-15 raw wire + MB-16/17 JSON access log 多字节）；raw fuzz 3602 请求 0 crash / bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary 5,188,032 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0；偏差=裸非 ASCII 查询值 '?' + 非法字节头回显 U+FFFD（ADR-0059 §5）
- **已决策-85**：**body 解析 Content-Type 分派 + 顶层值语义 parity**（ADR-0060, `fastapi_mojo-body-content-type-dispatch-iyj` bead 销账）：兑现 ADR-0058 §5 偏差行「Content-Type 语义」+ §8 后续缺口 #3 —— 此前**不按 CT 分派**（只要 body 是合法 JSON 即解析）；现对齐上游 `strict_content_type=True` 默认（`fastapi/routing.py:395-455`）：**仅 `application/json` 或 `application/*+json`（ci，忽略 `;` 参数）触发 JSON 解析**，否则 body 作为**原始字符串** → `model_attributes_type` `["body"]`（input 带引号原始串）。附修**顶层值语义**：无 body / JSON `null` → `missing` `["body"]` input null；JSON 数组/字符串/数字/bool → `model_attributes_type`（input 原值）；非法 JSON → `json_invalid` `["body", pos]` + `ctx.error` + input `{}`（此前 `loc` 无 pos、无 ctx，且 **`input` 回显裸文本 → detail 非法 JSON 的真 BUG**）。新叶模块 `body_json.mojo`（378 LOC，零 import，全 `as_bytes()` 字节安全）递归下降复刻 CPython `json` 首个错误位置+消息（Expecting value / property name / `:` / `,` delimiter / Extra data / Unterminated string / Invalid \escape / Invalid \uXXXX escape / Invalid control character）+ 数字文法 + allow_nan 常量；`content_type_is_json` 分派判定；同目录 `body_json_test.mojo`（85 LOC）自测。`validate_body_schema` +`content_type` 形参（默认 json）；dispatch 透传 `_get_header("Content-Type")`；e2e helper JSON-ish body 自动加 JSON CT。**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **785→802/802**（CT-1..CT-17）/ bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary 5,204,416 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0；偏差=input 规范化/键序/错误体超集（ADR-0060 §5）
- **已决策-86**：**`Body(embed=True)` 请求体嵌入语义 parity**（ADR-0061, `fastapi_mojo-280` bead 销账）：兑现 ADR-0060 §8 / Goal-0003 §1 矩阵 #4 请求体剩余面 —— 此前无 embed 支持（`grep embed src/fastapi_mojo/*.mojo` = 0）。上游 `Body(embed=True)` 把单一 body 模型包成单字段模型 `{<param>: Model}`，运行期即 `received_body.get(<param>)` 语义（fastapi 0.141.1 实测）：**顶层非 object**（无 body / 非 JSON CT 原始字符串 / JSON `null` / 数组 / 数字 / bool）或 **键缺失 / nil** → `missing ["body", <param>]` input null（**注意**：非嵌入时顶层非 object 报 `model_attributes_type`，embed 则报 `missing` —— 原始值无 `.get`）；键值非 dict（str / number / bool / array）→ `model_attributes_type ["body", <param>]`（input = 内层原值）；键值 dict → 内层模型校验（loc 前缀 `["body", <param>]`，嵌套 missing input = 内层对象）；非法 JSON 仍 `json_invalid ["body", pos]` + ctx。声明式 `_body_embed = "<param>"`；`body_validate.mojo` 新 `_validate_body_embed`（非嵌入路径零改动）；OpenAPI `requestBody.$ref → Body_<name>_<method>` 包裹 schema `{<param>: $ref <name>}`（house 命名 = form body）。**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **802→820/820**（EB-1..EB-18：valid / 键缺失 / nil / 空对象 / 顶层非 object（数字·数组·null）/ 非 dict 值（串·数·数组·bool）/ 内层嵌套 missing / 非法 JSON / 非 JSON CT / extra keys / OpenAPI wrapper `$ref`+schema）/ bridge 516/0/4（无 Rust 改动，+14 Mojo 自测断言）/ fmtool 35/0 / clippy 0（双 crate）/ 12 Mojo 自测全绿 / bench 6 场景 0 errors / binary 5,220,800 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0
- **已决策-87**：**float 正确舍入解析 + CPython `repr` 等价格式化**（ADR-0062, Goal-0003 §1 矩阵 #4 请求体数值面 / 兑现 ADR-0061 §8 #2）：修 Mojo 1.0.0 两个真原语缺陷 —— **Bug A** `Float64(String)` 整数部分按 int64 累加 → >~20 位有效数字/长整数部分**抛错**，把 float64 范围内合法十进制（`12345678901234567890.0`）误判 `float_parsing` 422（上游 = `1.2345678901234567e+19`）；**Bug B** `String(Float64)` 偶发**非最短/不往返**（`String(7.531168259201221e+16)`=`"7.53116825920122e+16"`，15 位）。新叶模块 `float_repr.mojo`（194 LOC，纯 Mojo + 既有 libc 符号 `atof`/`strfromd`，**零新 crate/Rust/C**）：`atof_f64`（`strtod` 正确舍入）/ `fmt_f64_repr`（**CPython `repr(float)` 等价**：最小 p∈1..17 往返位数 + Python 记法 `decpt<=-4||decpt>16` 科学记数否则定点 + 整值补 `.0` + `-0.0`）/ `is_dec_f64_syntax`（文法门，**必要**：`atof` 对垃圾串返回 0.0 不能当合法性依据；比 Mojo `Float64` 严，后者把 `"1.2.3"` 误收 `1.23`）。接线 `numlit`（`parse_float_lax`/`parse_f64`/`fmt_num`）+ `body_schema`（`_parse_f64`/`fmt_num`）。原型 Python 侧 499,756 随机 double + 边界 0 不一致；上线 5857 输入自有 server 0 不一致。**FFI diff=0**；e2e **820→832/832**（LF-1..LF-12：长字面量/30 位/往返回归/记法阈值 1e16·1e15·1e-4·1e-5/负号/float[] 元素/垃圾串 422/`"1.2.3"` 422/约束消息 `multiple of 0.5`）/ bridge 516/0/4（无 Rust 改动，+14 Mojo 自测断言）/ fmtool 35/0 / clippy 0（双 crate）/ 12 Mojo 自测全绿 / bench 6 场景 0 errors / binary 5,200,320 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0
*最后更新：2026-09-12（**决策-87 float 正确舍入解析 + CPython repr 等价格式化**（ADR-0062, Goal-0003 §1 矩阵 #4）：修 Mojo `Float64(String)` 长字面量抛错（误判 float_parsing 422）+ `String(Float64)` 非最短不往返；新叶 `float_repr.mojo`（libc `atof`/`strfromd`，**FFI diff=0**，零新 crate/Rust/C）：`atof_f64` 正确舍入 + `fmt_f64_repr`（CPython repr 等价：最小往返位数 + Python 记法阈值 + `-0.0`）+ `is_dec_f64_syntax` 文法门；接线 `numlit`/`body_schema`；499,756 随机 double 0 不一致；e2e **820→832/832**（LF-1..LF-12）/ bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,200,320 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（非有限 float 渲染 / 顶层非 object input 规范化 / response_model exclude_unset / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / OpenAPI 3.1 / multi-arch / asgi-shim）
*最后更新：2026-09-12（**决策-86 Body(embed=True) 请求体嵌入语义**（ADR-0061, fastapi_mojo-280）：单 body 模型包裹在 `_body_embed` 键下；顶层非 object / 键缺失 / nil → `missing ["body",<param>]`（非嵌入为 model_attributes_type）；键值非 dict → `model_attributes_type`；内层 loc `["body",<param>...]`；OpenAPI `Body_<name>_<method>` 包裹 `$ref`；**FFI diff=0**（纯 Mojo）；e2e **802→820/820**（EB-1..EB-18）/ bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,220,800 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（非有限 float 渲染 / float 格式化边界 / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集 / multi-arch / asgi-shim）
*最后更新：2026-09-12（**决策-85 body Content-Type 分派 + 顶层值语义**（ADR-0060, fastapi_mojo-body-content-type-dispatch-iyj）：上游 strict_content_type 默认（仅 application/json 或 application/*+json 解析 JSON，否则原始字符串 → model_attributes_type）；顶层 null/非 object/非法 JSON pos+ctx 对齐；`body_json.mojo`（CPython json 位置/消息复刻）；**FFI diff=0**（纯 Mojo）；e2e **785→802/802**（CT-1..CT-17）/ bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,204,416 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（非有限 float 渲染 / float 格式化边界 / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集 / multi-arch / asgi-shim）
*最后更新：2026-09-12（**决策-84 多字节 raw wire 输入字节安全**（ADR-0059, fastapi_mojo-multibyte-wire-byte-safety-led）：全请求面 `String[byte=i]` 码点边界崩溃修复（path/query/header/auth/WS-subprotocol/body/access-log）；`as_bytes()` 字节安全 + `span_to_str` 越界解码兜底 + codepoint-aware `_json_escape`；**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **768→785/785**（MB-1..MB-17）+ raw fuzz 3602 请求 0 crash / bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,188,032 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
*最后更新：2026-09-12（**决策-83 body 422 detail pydantic 逐字段对齐**（ADR-0058, fastapi_mojo-tew）：约束类错误追加 `ctx`（ctx 末位）+ `mo=N` + 数值首违序 mo→le→lt→ge→gt + str **codepoint** 长度 + 列表 `too_short`/`too_long`+`actual_length`+单复数+短路 + enum `ctx.expected`；**`input` 按 JSON 类型渲染**（字符串恒带引号）；附带 P0：`parse_float_lax` 丢负号 + `String[byte=]` 多字节崩溃（form/cookie/body 数组）；约束层拆 `body_constraints.mojo`（body_validate 523→333）；**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **733→768/768**（MX-1a..MX-13 + BY-3c..BY-3e）/ bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,204,416 B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（非有限 float 渲染 / 多字节 path·query 字节下标审计 / Content-Type 分派 parity / float 格式化 / multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-82 body JSON 跨类型标量强制转换**（ADR-0057, fastapi_mojo-g3p）：pydantic v2 model lax —— body int/float/bool 字段及数组元素跨 JSON 类型强制 + 规范化回显（`7.0`→7 / `1e2`→100 / `true`→1 / `7.5`→int_from_float / `null`→int_type/float_type/bool_type）；数组 `[7.0,1e2,true,"7"]`→`[7,100,1,7]`；**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **709→733/733**（BY-1a..BY-9b）/ bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（float 格式化 / 非有限 float 渲染 / multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-81 lax 标量强制转换 + 规范化回显**（ADR-0056, fastapi_mojo-vg4）：pydantic v2 lax —— int/float/bool path/query/header/form/body 全场景解析 + 规范化回写（`007`→7 / `1.50`→1.5 / `yes`→true；整值小数 `2.0`→2、`12.00`→12）；str/enum/标量类型保持 raw（决策-79 echo 契约）；**FFI diff=0**（纯 Mojo，零 Rust/零 C）；e2e **676→709/709**（CX-1..CX-21 + JS-3 改写）/ bridge 516/0/4（无 Rust 改动）/ fmtool 35/0 / clippy 0（双 crate）/ bench 6 场景 0 errors / binary ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（float 格式化 / 非有限 float 渲染 / body JSON float→int / multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-80 请求 path 百分号解码**（ADR-0055, fastapi_mojo-v50）：uvicorn 等价 —— `url_decode_path` 纯 Mojo（`%XX` 单字节 / `+` 非空格 / 畸形 `%` 保留 / 非法 UTF-8→U+FFFD），`get_path_slice` 后单点解码；`a%20b`→`a b` / `%7Bx%7D`→`{x}` / `a%2Fb`→404（分段）/ `%FF`→`�`；静态编码 `../` 403；redirect Location 用 wire raw_path；**FFI diff=0**；e2e **664→676/676**（PD-1..PD-11）/ bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（int/float 强制转换+回显 / float 格式化 / multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-79 pydantic 内建标量类型全量对齐**（ADR-0054, fastapi_mojo-2wd）：uuid/date/datetime/time/timedelta/decimal 6 类标量 path/query/header/body/form/list 全场景；纯 Mojo 解析器（date_types/time_types/scalar_types）+ byte-safe `bof()` 规避 `String[byte=]` 多字节 assert；422 `type`/`msg`/`ctx`/`input` 逐字段对齐上游 pydantic_core 2.46.4；OpenAPI format/anyOf 对齐；**FFI diff=0**；e2e **609→664/664**（SC-1..SC-37）/ bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,151,168B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（int/float 强制转换+回显 / path URL 解码 / float 格式化 / multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-78 GZip Starlette 1.6.0 全量对齐**（ADR-0053, fastapi_mojo-mxs；取代 ADR-0015 §3/§7）：Vary 恒加于可压响应（未接受 gzip 也加；小体/排除/206/HEAD 不加）+ client 判定大小写敏感子串（GZIP 不命中）+ 13 项默认排除表（text/event-stream/image/*/video/*…）+ streaming/FileResponse 可压 + compresslevel 9；`bridge/gzip.rs` 重写 `plan()` 判定 + 三发送点接线；**FFI diff=0**；e2e **604→609/609**（GZ-1..GZ-10）/ bridge 516/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,093,824B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-77 HEAD 统一仅头无体**（ADR-0052, fastapi_mojo-ki9）：修复 HEAD 响应携带 body 的 keep-alive 脱轨 bug（内置 doc 路由/KIND_HTML/streaming）—— `send_response` 单点 `include_body && !current_method_is_head()`（覆盖内置 doc/HTML/JSON/static/SSE/error/404/405, H1+H2）+ `send_streaming_response` HEAD 仅头（H2 END_STREAM）；对齐上游（HEAD 头同 GET、`Content-Length` = 完整体长度、body 空）；**FFI diff=0**；fmtool `headbody [path]`；e2e **600→604/604**（HD-1..4）/ bridge 507/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,089,704B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-76 内置文档路由补全**（ADR-0051, fastapi_mojo-redoc-oauth2-redirect-oxc）：补齐上游 FastAPI 默认 4 条内置路由中缺失的 2 条 —— `/redoc`（ReDoc 页 `spec-url="/openapi.json"`）+ `/docs/oauth2-redirect`（Swagger OAuth2 回调页 `swaggerUIRedirectOauth2`）；`openapi.mojo` 增 `redoc_html`/`swagger_ui_oauth2_redirect_html` + `swagger_ui_html` 补 `oauth2RedirectUrl`；`http_server_final.mojo` 两条内置 GET 分支（HEAD 归一自动覆盖）+ import；**FFI diff=0**；e2e **595→600/600**（DOC-1..4）/ bridge 505/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,089,704B ≤6MiB / ldd libc-only / env-i 干净（/redoc 200）/ C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-75 Depends(yield) teardown**（ADR-0050, fastapi_mojo-dep-teardown-18z）：依赖声明式 `_dep_teardown`（换行分隔命令）+ 实际派发登记（memo 命中不登记）+ 响应 flush **后逆序**执行（LIFO = 上游 request `AsyncExitStack`），在 background tasks 之后（正常路径）/ 异常响应后仍执行（= 上游 `try/finally` 形式）；接入点 ×6（`(exc)`/`(stream)`/`(sse)`/`(file)`/`(redirect)`/主路径）；`_exec_one_cmd` 提取与 `_background` 共享；**FFI diff=0**；demo `/di-teardown` `/di-teardown-raise` `/di-teardown-twice`；e2e **595/595**（DT-1..4）/ bridge 505/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,077,416B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / OAuth2PasswordRequestForm 对象面 / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-74 HTTPException 自定义响应头**（ADR-0049, fastapi_mojo-0n1）：异常响应声明式自定义头 —— Rust `send_text_response_status_extra`（+1 FFI）+ Mojo `parse_exc_headers`/`load_exc_headers`（`;` 分隔 `TAG=H1|H2`，`|` 多头，路由 `_exc_headers` 覆盖 env `FASTAPI_MOJO_EXCEPTION_HEADERS`）+ `GuardResult.extra`；JSON 面复用 `send_simple_response_extra`；demo `/exc/headers` = `HTTPException(418, headers)` 语义；e2e **591/591**（XH-14..17）/ bridge 505/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,065,128B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / Depends yield teardown / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-73 CORSMiddleware 全量等价**（ADR-0048, fastapi_mojo-utm）：真预检 200 text/plain `OK` / 400 `Disallowed CORS …` + 完整头集（Vary/Allow-Methods/Max-Age/Allow-Headers/Credentials/echo/镜像/PNA）；新增 `_ORIGIN_REGEX`（re.fullmatch）/ `_EXPOSE_HEADERS` / `_PRIVATE_NETWORK`；`*` methods→ALL_METHODS / `*` headers→镜像；safelist 并入；普通响应 simple_headers 恒发 + echo `Vary`；PNA 走 request 全局（FFI 符号数不变）；H2 预检修重复头 bug；e2e **587/587**（CRS-1..9 + CRS2-1..4）/ bridge 503/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,052,840B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / Depends yield teardown / CORS 裸 OPTIONS 超集）
*最后更新：2026-09-12（**决策-72 SSE ServerSentEvent 字段**（ADR-0047, fastapi_mojo-sdo）：`format_sse_event` 全字段逐字节对齐上游 —— 字段序 comment(`: `)→event→data(逐行)→id→retry + `\n\n`；`_split_sse_lines` `\r\n`/`\r`→`\n` 且保留尾空串；data=raw_data（不 JSON 编码）；dispatch 读 `_sse_event`/`_sse_id`/`_sse_retry`/`_sse_comment`（路由级）；`streaming.mojo` 重写 150 LOC + 兼容旧入口；**FFI diff=0**；e2e **582/582**（SF-1..5）/ bridge 500/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,044,576B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / Depends yield teardown / CORS preflight 偏差）
*最后更新：2026-09-12（**决策-71 redirect_slashes**（ADR-0046, fastapi_mojo-kvd）：Starlette 默认尾斜杠 307 —— 未匹配时 alt 路径命中（method 无关）→ 绝对 URL `scheme://host<alt>?<query>`，rstrip 全部尾斜杠，根 `/` 除外；`redirect_slashes.mojo` 纯逻辑 + dispatch 接线 + 复用 `send_redirect_response`；fmtool testclient Host 端口修复；FFI diff=0；e2e 577/577（SL-1..10）/ bridge 500/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / Depends yield teardown）
*最后更新：2026-09-12（**决策-70 OpenIdConnect + OAuth2AuthorizationCodeBearer**（ADR-0045, fastapi_mojo-cz1）：openid stub（只校验 Authorization 头存在，401 `WWW-Authenticate: Bearer`，注入原始头）+ authcode（Bearer scheme 大小写不敏感提取 → auth_token）；OpenAPI openIdConnect + authorizationCode flow；`_authcode_*` 键与 `_oauth2_*` 隔离；FFI diff=0；e2e 567/567（OI-1..4 + AC-1..7）/ bridge 500/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,024,096B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim / SecurityScopes 对象 / redirect_slashes）
*最后更新：2026-09-12（**决策-69 安全 OpenAPI + HTTPDigest**（ADR-0044, security-openapi-digest bead 销账）：HTTPDigest stub parity（`_auth=digest`，大小写不敏感 scheme + 非空 credentials，401 `Not authenticated` + `WWW-Authenticate: Digest`，注入 auth_scheme/auth_credentials）+ OpenAPI securitySchemes 全量（HTTPBasic/HTTPBearer/HTTPDigest/APIKeyHeader/Query + oauth2 flows）与 operation security（`_auth_scheme_name` 覆盖默认名）；拆出 `openapi_security.mojo`（openapi.mojo 513→444）；修复 `paths` method 关键字大写 bug（→ 小写 `get`，恢复 Swagger UI）；FFI diff=0；e2e 556/556（DG-1..6 + SO-1..5）/ bridge 500/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 5,020,000B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim）
*最后更新：2026-09-12（**决策-68 RedirectResponse**（ADR-0043, redirect-response bead 销账）：`KIND_REDIRECT` + `_redirect_url`/`_redirect_status` → Rust `send_redirect_response`（FFI +1）；上游 Starlette wire parity：无 Content-Type + Content-Length: 0 + Location（safe set `:/%#?=@[]!$&'()*+,;` 百分号编码）+ 空 body，默认 307，支持 303/301/308；HTTP/2 HEADERS-only；4 单测 + e2e 545/545（RD-1..10）；bridge 500/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / binary 4,999,520B ≤6MiB / ldd libc-only / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim）
*最后更新：2026-09-12（**决策-67 OAuth2 作用域**（ADR-0042, oauth2-scopes bead 销账）：`_auth=oauth2` 路由声明 `_auth_scopes` → 必需 scope gate；token 路由 `_jwt_scopes` 签发 RFC 6749 `scope` claim；缺 scope → 403 `Not enough permissions` + `WWW-Authenticate: Bearer scope="..."`，坏 token 401 同 scope 片段，无 Authorization 401 `Bearer`（框架 parity）；OpenAPI securityScheme 修正为上游 `type:oauth2` + password flow scopes/tokenUrl，operation security scope 数组；**FFI diff=0**；自检扩 scope 向量；e2e 535/535（OT-24/25 改 + OT-26..33）/ ldd libc-only / binary ≤6MiB / env-i 干净 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim）
（ADR-0041, json-rust bead 销账）：默认 Mojo serializer 不变，`FASTAPI_MOJO_JSON_SERIALIZER=rust` 仅对 ≥阈值（默认 64KiB 输入估算）的 response JSON object 启用 Rust std-only writer；输出字节兼容 + FFI NUL 契约 + 失败回退；ASCII span fast path 消除 Mojo byte-loop 瓶颈；escape 密集 1MiB 端到端两组均值 **+24.19% req/s / -19.44% avg latency**；e2e 527/527 / bridge 496/0/4 / fmtool 35/0 / clippy 0 / bench 6 场景 0 errors / binary 4,962,656B ≤6MiB / ldd libc-only / env-i 默认+opt-in health 200 / C=Python=orphans 0）
下一轮：P1/P2 open beads（multi-arch / asgi-shim）
*最后更新：2026-09-12（**决策-65 UPX 复评**（ADR-0040, upx-revisit bead 销账）：默认交付物不变，UPX 5.2.1 `-9` 仍仅 opt-in 手动部署；4,954,416→1,718,420 B（-65.32%），冷启动 12.1→31.6ms，RSS 持平；`--brute` 95ms 拒绝；UPX 副本 e2e 521/521 + bench 0 errors + upx-test + env-i health；压缩 stub 无 INTERP/NEEDED → readelf 不等价 ldd，CI 主门禁继续跑未压缩产物；compress_upx.sh 增加 ldd 预检 / 候选 smoke / 备份保护 / --restore → 恢复后 4,954,416B + ldd libc-only + C=Python=orphans=0）
下一轮：P1/P2 open beads（multi-arch / json-rust / asgi-shim）
*最后更新：2026-09-12（**决策-63 HTTP/2 prior-knowledge h2c 子集**（ADR-0038, http2 bead 销账）：Rust std RFC7540/7541 有界子集 + HPACK 请求解码/literal 响应 + phase6 poll 集成 + 串行 buffered multiplex drain; FFI diff=0 → e2e 504→511/511（H2-1..7）/ bridge 483/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / 4,221,136B（≤6MiB）/ ldd libc-only / env-i clean / C=Python=orphans 0
下一轮：P1/P2 open beads（upx-revisit / asgi-shim / multi-arch / json-rust / tls-rustls）
*最后更新：2026-09-12（**决策-62 阶段化 OpenTelemetry traces**（ADR-0037, otel bead 销账）：FASTAPI_MOJO_OTEL=1 + 每请求 SERVER span + 每 worker 128 ring + /traces OTLP JSON resourceSpans; 先 snapshot 后 self-record, 默认关闭; FFI +2/Rust std-only → e2e 497→504/504 / bridge 472/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / 4,184,272B ≤4.2M / ldd libc-only / env-i clean / C=Python=orphans 0
下一轮：P1/P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / json-rust / tls-rustls）
*最后更新：2026-09-12（**决策-61 递归嵌套 JSON body Schema**（ADR-0036, json-schema bead 销账）：obj[]{} 元素级递归校验 + loc/input 语义 + OpenAPI recursive object items/数值约束补齐; FFI/Rust diff=0 → e2e 479→497/497 / bridge 470/0/4 / fmtool 35/0 / clippy 0 / bench 0 errors / 4,180,120B ≤4.2M / ldd libc-only / env-i clean / C=Python=orphans 0
下一轮：P1/P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / otel / json-rust / tls-rustls）
*最后更新：2026-09-12（**决策-60 WebSocket 应用子协议矩阵**（ADR-0035, Goal-0003 P2 / ws-subprotocol bead 销账）：ws_sp 多候选 server-preference 协商 + `/ws/jsonrpc`（JSON-RPC 2.0 单请求/notification/error 面）+ `/ws/graphql-ws`（graphql-transport-ws + legacy graphql-ws 控制面/next+complete）+ `/ws/grpc-web`（NUL-safe BINARY transparent bridge, 非 protobuf 引擎）; `_ws_protocol` 数据驱动 + FFI-free ws_protocols 纯模块, **FFI diff=0 / Rust bridge diff=0** → e2e **471→479/479**（WSP1..8）/ ws_protocols unit 绿 / fmtool **35/0** + clippy 0 / ldd 仅 libc / binary **4,171,928 B ≤4.2M** / C=0
下一轮：P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / otel / json-rust / json-schema / tls-rustls）
*最后更新：2026-09-11（**决策-59 WebSocket permessage-deflate**（ADR-0034, Goal-0003 #23 / ws-deflate bead 销账）：RFC7692 协商（默认 on / off / required; comma fallback + fixed 15-bit server window）+ RSV1 压缩 fragmentation（wire/展开 1MiB cap, 解压后 UTF-8/dispatch）+ 出站 sync-flush 去尾 `00 00 ff ff`（不 padding / 不发 pre-close 空帧）+ 方向正确 no-context（server=出端, client=入端）+ **FFI diff=0**；fmtool 零依赖 RFC1951 inflater/stored encoder → e2e **465→471/471**（WSD1..6）/ cargo **470/0/4**（+17）/ fmtool **35/0**（+5）/ clippy **0**（双 crate）/ ldd 仅 libc / env -i 干净启动 / binary **4,135,064 B**（≤4.2M, +24,584 B）/ bench 6 场景 0 errors / RSS 平台化 / 孤儿 0
下一轮：P2 open beads（http2 / upx-revisit / asgi-shim / multi-arch / otel / json-rust / json-schema / tls-rustls / ws-subprotocol）
2026-09-11（**决策-58 数组元素级约束**（ADR-0033, Goal-0003 矩阵 #4/#20 缺口闭环, ADR-0032 §3.6 / ADR-0014 元素级闭环）：
约束词表复用（类型依赖语义）：pat/len 在 str[] 逐元素（剥外层引号 → byte_length / `regex_match` FFI, **FFI diff = 0**）、ge/le/gt/lt 在 int[]/float[] 逐元素、items 保持数组级（元素数）→ 422 loc = `["body",<field>,<idx>]`（复用元素类型错 loc 约定）/ **注册期 fail-fast 加强**（key × 类型错配 → 启动即失败: pat/len=str 标量|str[], gt..=int/float 标量|int[]|float[], items=仅数组, 闭环旧静默 no-op 偏差）/ **OpenAPI 元素级约束入 items 对象**（str: minLength/maxLength/pattern; 数值: minimum/maximum/exclusiveMinimum/exclusiveMaximum; minItems/maxItems 留数组层）→ e2e **454→465/465**（BP-2a..k）/ cargo **453/0/4** 不变 / fmtool **30/0** 不变 / clippy **0**（双 crate）/ ldd 仅 libc / env -i 干净启动 / binary **4,110,480 B**（≤4.2M, +24 KB）/ 孤儿 0
剩余缺口：validator-closures（Mojo 1.0.0 无闭包 = 硬边界, ADR-0014/0032 已文档化偏差）；OpenAPI 3.0.3 vs upstream 3.1.0（P2）；P2 open beads: http2 / upx-revisit / asgi-shim / ws-deflate / multi-arch / otel / json-rust / json-schema / tls-rustls / ws-subprotocol
2026-09-11（**决策-57 body pat=REGEX 约束 + PATCH+body 解析**（ADR-0032, Goal-0003 矩阵 #1/#4/#20 缺口闭环）：
body 约束词表新增 pat=REGEX（复用 bridge/regex.rs FFI `regex_match`, FFI diff = 0; str 标量 only, 注册期 fail-fast, 422 type=string_pattern_mismatch, OpenAPI 3.0 `pattern`）；dispatch body 解析 POST/PUT→+PATCH 1 行（ADR-0014 两偏差闭环）→ e2e **447→454/454**（BP-1a..e + PATCH-B1a/b）/ cargo **453/0/4** 不变 / fmtool **30/0** 不变 / clippy **0**（双 crate）/ ldd 仅 libc / env -i 干净启动 / binary **4,085,904 B**（≤4.2M, +4 KB）/ bench 6 场景 0 errors（get_root hot-path 未动, 带内）/ 孤儿 0
剩余缺口：validator-closures（Mojo 1.0.0 无闭包 = 硬边界, ADR-0014 已文档化偏差）；数组元素级约束（P2）；OpenAPI 3.0.3 vs upstream 3.1.0（P2）
2026-09-11（**决策-56 TestClient 声明式等价**（ADR-0031, Goal-0003 矩阵 #25 ✅ = **25/25 全量完成**）：
fmtool `testclient` 三子命令（**dev 工具不进 runtime, FFI diff = 0**, binary 仅加 /tc/jar demo 路由）：
`http`（真实网络 GET/POST + JSON/form + header/param/cookie + cookie-jar 文件 + 重定向
（303/301-302 POST→GET, 307/308 保持）+ --json-out + 退出码 0-6）/
`ws`（host-aware RFC6455 握手（ws.rs 原 helper 不动, e2e 逐字节不变）+ Sec-WebSocket-Accept 硬校验
+ action 脚本 → JSONL 事件（connect/denial/receive/close/done/error）+ 控制帧透明 + 退出码 0/4/5/6）/
`run`（spawn（--port 两 argv）→ readiness → JSONL actions PASS/FAIL → SIGTERM（coreutils kill）
→ server_exit=0 断言 = lifespan CM 等价）
→ 实施期修复（ADR-0031 §7.6）：--port 单 argv 被忽略（→两 argv, 实测 catch）/ SIGKILL vs SIGTERM /
run 按最后一个 -- 切分（两写法兼容）/ read_response 去 dead timeout
→ e2e **438→447/447**（TC-1..9）/ cargo **453/0/4**（rs 不变）+ **30/0**（fmtool 首批单测）/
clippy **0**（双 crate）/ ldd 仅 libc / env -i 干净启动 / binary **4,081,808 B**（≤4.2M, +4 KB）/
bench 6 场景 0 errors（get_root_10k_100c = 34,867, 带内）/ 孤儿 0
下一轮：**Goal-0003 全量完成审计**（25/25 逐行证据复核：每行 e2e 覆盖 + 各 ADR §3.5/§7 文档化偏差;
gap 列 #1 PATCH-via-generic / #4 约束词表扩充 / #20 validator-closures 的 ✅ 需确认为"文档化偏差"
而非"开放 gap"; 通过后 update_goal complete）
2026-09-11（**决策-55 用户自定义中间件声明式落地**（ADR-0030, Goal-0003 P2 矩阵 #14 ✅ 全量）：
fastapi 0.141.1 / uvicorn 0.52.4 活体 P-MW-1..7（栈序 mw1=innermost / 响应头同名后写胜 /
短路跳内层+路由 / status 重设 / body 替换但 CL 不重算 → h11 协议破损 / WS scope 直通 /
请求面仅 scope 可改）→ **单一 env 声明式动词表**（ADR-0004 范式, **FFI diff = +2**
`set_req_id`/`inject_request_header`）：`FASTAPI_MOJO_MIDDLEWARE`（`;`/`,`/`:`/`|` 分隔;
畸形 → `check_mw_spec` fail-fast）；请求面 MAP/REQHDR/BLOCK = Mojo `mw_spec.mojo` 纯函数
（outermost→innermost, BLOCK 短路）+ dispatch 钩子（路由/OPTIONS 前, FFI 注入合成头）；
响应面 HDR/STATUS/BODY/LOG = bridge `send_response` 单点（innermost→outermost = env 正序,
GZip 前, 同名 HDR 原位替换后写胜, BODY 重算 CL = 文档化优于上游 P-MW-5）
→ 实施期修复：bridge 侧短路重推导 `plan_request_path`（响应仅过外层, 零额外 FFI）
→ e2e **428→438/438**（+MW-1..10）/ cargo **453/0/4**（+19 中间件单测）/ clippy **0**
（双 crate）/ ldd 仅 libc / binary **4,077,712 B**（+57 KB, ≤4.2M）/ env -i / bench
0 errors（≈31.5k req/s, 带内）/ 孤儿 0 / `mw_spec.mojo` selftest **10/10**（FFI-free）
下一轮：P2 剩余（TestClient）
2026-09-10（**决策-54 参数约束面统一落地**（ADR-0029, Goal-0003 P2 矩阵 #2 ✅, #3 bool 销账）：
fastapi 0.141.1 / pydantic 2.13.5 活体 P26-a..h（ctx 键序 / 首违 only
+ 优先级 / mo=0 no-op / str+数值上游 no-op → 注册期拒 / list+约束上游
500 → fail-fast / input 类型化: 在场=raw · 缺失+默认=字面量 unquoted ·
parse=raw / 群序 path→query→header）→ **声明式映射**（ADR-0004 范式,
**FFI diff = +1** `regex_match`）：`_param_constraints`（未声明 query
键 = 隐式 str 声明, len/pat only）+ `_header_types` typed header 校验
（默认值校验 / missing 422 / parse→约束→raw 注入）+ `bridge/regex.rs`
自研 backtracking（re.search 子集, 步数上限, 零第三方）+ OpenAPI
3.0.3 约束键（3.0 bool exclusive / type 恒带 / 字面量原样）+ 6 /con/*
demo → 实施修复 ×3：FFI 三态 `extract_request_header`（缺失 vs 空值,
CP-12/15/16/20b 根因; F3a 注入不变）/ OpenAPI alias 约束查找（cons
声明名 keyed vs wire 名）/ `apply_query_extras` 标量默认注入（200 路径
缺席+默认 → values）→ e2e **403→428/428**（+CP-1..19, 20a/20b,
21..24）/ cargo **434/0/4** / clippy **0**（双 crate）/ ldd 仅 libc /
binary **4,020,232 B**（+205 KB, ≤4.2M）/ env -i / bench 0 errors
（35,124 req/s, 带内）/ 孤儿 0 / selftest **10/10**（JIT stub:
`mojo run -Xlinker jit_regex_stub.so` — LD_PRELOAD 无效, stub
abort-if-called dev-only）
下一轮：P2 剩余（middleware / TestClient）
2026-09-10（**决策-53 Header 参数精化**（ADR-0028, Goal-0003 P2 矩阵 #7 ✅）：
fastapi 0.141.1 / uvicorn 0.52.4 活体 P25-1..10（alias 原样**不**转换 P25-3 /
逐 `_`→`-` P25-4 / CI + 多值取首 / 约束面 P25-6..9 → 下一决策）→ **声明式映射**
（ADR-0004 范式, **FFI diff = 0** 纯 Mojo）：`_reads_headers` 条目 `name`
（wire = 转换）/ `name=alias`（wire = alias 原样; `n=n` = 字面逃生门）+
注册期 `check_header_specs` fail-fast + OpenAPI header 参数名 = wire 名
（原始拼写）+ demo `/hdr/alias`（x_token=Token-Literal + client_id）
→ e2e **395→403/403**（+OP3-1..8）/ cargo **431/0/4**（Rust 零改动）/
clippy **0**（双 crate）/ ldd 仅 libc / binary **3,815,424 B**（+12 KB,
≤4.2M）/ env -i / bench 0 errors（35,765 req/s, 带内）/ 孤儿 0 /
selftest ~22 断言全绿
下一轮：P2 剩余（路径参数约束 / typed header 校验 (P25-6..9 已探测) / middleware / TestClient）
2026-09-10（**决策-52 OpenAPI 精化**（ADR-0027, Goal-0003 P2 矩阵 #16 ✅）：
fastapi 0.141.1 / pydantic 2.13.5 活体 P24-1..15（+ p24e/f/g 勘误：operationId 无 `_+`
折叠；servers.url = AnyUrl|str str 优先不规范化；AnyUrl 2.13.5 path 空 + `?`/`#` → 前插 `/`）
→ **声明式映射**（ADR-0004 范式, **FFI diff = 0** 纯 Mojo）：app 级 9
`FASTAPI_MOJO_OPENAPI_*` env（请求期读, 畸形省略不 500）+ 路由级 8 声明
（`_summary`/`_description`/`_response_description`/`_operation_id`/`_deprecated`/
`_include_in_schema`/`_status_code`="NNN Reason"（wire 仅 "200 OK" 覆写 + spec 主键前 3
位）/`_responses`（重复主键注册期拒绝））+ 键序 P24-4/P24-10（externalDocs desc 先）+
AnyUrl quirk（contact/license/externalDocs; servers 原样）+ 3 demo 路由
（/meta/probe · /meta/hidden · /meta/made）+ 新模块 openapi_custom.mojo（381 ln）+
openapi.mojo 重写（497 ln <500）+ `check_openapi_specs` 注册期校验
→ e2e **383→395/395** / cargo **431/0/4**（Rust 零改动）/ clippy **0**（双 crate）/
ldd 仅 libc / binary **3,803,136 B**（+70 KB, ≤4.2M）/ env -i / bench 0 errors
（33,590 req/s, 带内）/ 孤儿 0 / selftest ~60 断言全绿
下一轮：P2 剩余（Header alias / 路径参数约束扩充 / 用户自定义 middleware / TestClient）
2026-09-10（**决策-51 WebSocket 精化**（ADR-0026, Goal-0003 P2 矩阵 #23 ✅）：
uvicorn 0.52.4 / wsproto 1.3.2 / starlette 1.6.0 活体 P23-1..7 + p23i A..E（close reason
规范化 1004/1006→1000 / 1005 无 payload / 123B codepoint 截断; close-wait: 数据·ping 丢弃 /
任何 close → 静默 close / 10s 定时器）→ **声明式映射**（ADR-0004 范式, `run_ws_message`
签名**不变**, 每消息评估）: `_ws_close=CODE:REASON`（回复后 close + close-wait, 注册期
check_ws_specs 校验合法码集, 1004/1005/1006 拒收）/ `_ws_raise`（无回复无 close 帧, 立即
EOF = 1006, log [ws-exc]）/ `_ws_exc_close`（WebSocketException 等价）/ `_ws_no_reply` /
`_ws_binary`（NUL 保留零拷贝）/ `_ws_json`（compact JSON, echo 路径优先）; 优先级
`_ws_raise` > `_ws_exc_close` > `_ws_close`
+ **close-wait = bridge 新 phase 5**（数据/ping/pong 丢弃, 任何 close → 静默 close（无二次
帧）, EOF/协议错误 → 静默 close; 超时 = check_deadlines WsCloseWaitTimeout, env
FASTAPI_MOJO_WS_CLOSE_WAIT 默认 10000 = uvicorn parity, 0 = 立即, 1s tick 分辨率）
+ **新 FFI ×5**（ws_send_close_reason / ws_write_binary / ws_write_current_binary /
ws_set_closing / get_ws_close_wait_ms; 既有 ws_send_close 保留）+ 新模块
ws_directives.mojo(122<500) + selftest + 6 demo 路由（P23 全覆盖）+ FMTOOL ws5 新子命令
（10 检查, 复用 ws.rs 帧 handshake/解析）;
文档化偏差 ×7（ADR-0026 §3.5: ① _ws_json = 声明模板 ② close-wait 1s tick + 可配置超集
③ 声明式每消息 vs endpoint 生命周期 ④ 回复后会话继续（既有, 显式）⑤ 回复值域 = UTF-8
文本（NUL 保留）⑥ close-wait 协议错误静默 close ⑦ 异常 = 字符串 tag（决策-49 同款））;
验收: e2e **383/383**（373+10 W, 含提前结束 <1s / close-wait 保持 ∈[1s,4s) / 无 close 帧
EOF / NUL 往返 / compact JSON UTF-8 / ping·数据丢弃）/ cargo **431/0/4**（+22）/ clippy
0 警告(双 crate) / bench 6 场景 0 errors（get_root_10k_100c 34,880 req/s, 区间内）/ ldd 仅
libc / env -i 干净启动 / **3.7M**（3,733,504 B, ≤4.2M, +33 KB vs 决策-50）/ C 清零保持;
2026-09-10（**决策-50 Request.state**（ADR-0025, Goal-0003 P2 矩阵 #22 ✅）：
starlette 1.6.0 P22-1..6 探测（scope 承载 property / 属性·dict 双面 / 缺失读 500 / del quirk /
无 __contains__ / 每请求隔离 ×2 活体）→ **声明式映射**（零 FFI, 纯 Mojo）：写面 `_state_set =
"key:value;…"`（首个 `:` 切分; 值 `{param}` 插值 — 缺失键保留字面量; 评估 = 全部注入之后 =
「middleware 先写」声明式等价; 注册期校验 check_state_specs）+ 读面 `_reads_state` CSV →
`state_<name>`（缺失 → "" = F10 约定, 上游 500 → §3.5-1）+ 存储 = dispatch 每请求
Dict[String,String]（P22-2/6, 请求结束即弃）+ **FFI diff = 0**;
新模块 request_state.mojo(124<500) + request_state_selftest.mojo(JIT 纯逻辑) + http_server_final
1509→1551(+42: import + 每请求 state + 写/读接线 + 3 demo /state·/state-dyn/{who}·/state-missing
(无 set, user,ghost 双空 = 跨请求隔离证明));
文档化偏差 ×7（ADR-0025 §3.5: ① 缺失读 → "" 非 500 ② 写 = 声明非代码 ③ 值域 String ④ 无反射/集合面
⑤ 惰性→显式构造(parity) ⑥ 下划线 parity ⑦ 环境项: 本机 dev 环境透明代理劫持新 bind 首连接
(Caddy :80 假空 200, taint = bind 生命周期) → e2e 6 副 server + fmtool bench 就绪探针
bind 后 sleep 5s 再首探针 + /health body 须含 healthy 防假 ready（CI 不受影响, 仅 +5s））;
验收: e2e **373/373**（366+7 XS, 含跨请求隔离）/ cargo **409/0/4**（FFI diff = 0）/ clippy
0 警告(双 crate) / bench 6 场景 0 errors（get_root_10k_100c 32,938 req/s, 区间内）/ ldd 仅
libc / env -i 干净启动(health+/state+/state-dyn) / **3.7M**（3,700,736 B, ≤4.2M, +36 KB vs
决策-49）/ C 清零保持;
2026-09-10（**决策-49 任意异常类型 handler**（ADR-0024, Goal-0003 P2 矩阵 #13 ✅）：
Mojo 1.0.0 异常面探测（仅 Error 类型/String(e)=message/std.os.getenv 原生/try-scope 规则）→
**字符串 tag 约定** `raise Error("TAG: msg")` + **声明式处理表**（env FASTAPI_MOJO_EXCEPTION_HANDLERS
"TAG:STATUS:BODY[:json];…" 全局, 同 tag 后者胜 / `_exc_handlers` 路由级整体替换超集）+
**声明式 raise 钩子** `_exception_raise` + **路由级 try/except guard**（= 上游 wrap_app_handling_exceptions；
精确 tag → Exception catch-all → 默认 500 "Internal Server Error" text/plain, P13-10 逐字 parity；
body {exc}/{tag} 插值, json 条目 _json_escape；P13-8 日志 quirk 模拟）+
新模块 exception_handlers.mojo(254<500) + guarded_run_handler dispatch 单点(1444→1509) +
**新 FFI send_text_response_status**（复用 send_response, 零新依赖/零 libm）+ 7 demo 路由 +
standard_status_line +418 + exception_handlers_selftest.mojo(JIT 28 checks);
文档化偏差 ×8（ADR-0024 §3.5: ① 无类→tag（无 MRO）② handler=声明式条目 ③ 无 int status 键
④ response_started 结构性不可达（单发）⑤ 双层 map→单表 ⑥ 日志 quirk 线形 ⑦ per-route=超集
⑧ 中间件抛出 gap）;
验收: e2e **366/366**（351+15 XH）/ cargo **409/0/4**（407+2）/ clippy 0 警告(双 crate) /
bench 0 errors(37.2k req/s, 区间内) / ldd 仅 libc / env -i 干净启动(health+/exc/ve 500) /
**3.5M**(3,663,872 B, ≤4.2M, +32 KB vs 决策-48) / C 清零保持;
2026-09-10（**决策-48 FileResponse/StreamingResponse**（ADR-0023, Goal-0003 P1 矩阵 #10）：
Rust bridge 文件/流式协议层（file_protocol 230 纯函数: Range 7 步顺序解析（>100 段 → 200 quirk）/RFC1123/RFC5987/CD/charset/etag/multipart CL 闭式/26-hex boundary + file_serve 416: 144B glibc stat/64KB 块直发/单点 FFI×2: send_file_response + send_streaming_response）+
Mojo 声明式 KIND_FILE=300（handler 495 ≤500）+ dispatch FILE 分支（1332→1444）+ 8 demo 路由 + filedemo.bin(30B) build 自动嵌入 +
**MD5 K 表 const 嵌入 = libm 零化**（运行时 f64::sin 链入 libm.so.6 破 CI ldd 门禁 → const 256B .rodata, glibc 正确舍入 sin 逐位导出, md5_k_table_matches_sin 守护 ≡ 派生 → ldd 回归仅 libc）;
文档化偏差 ×7（ADR-0023 §3.5: ① ORJSON≡json.mojo（既有）② HEAD 仅头 vs 上游 405 quirk（APIRoute methods={GET}, 更优）③ GZip 不介入 file/streaming（上游压缩, P2 剩余）④ 整秒 mtime etag "N" vs 上游 "N.0"（opaque; 非整秒逐字节相同）⑤ i64 溢出段 → 400 vs 上游 416（>9.2EB 不可达）⑥ _file_path 静态目录相对 + extra 不得覆写 CT/ETag（收窄）⑦ INM·IMS 忽略 = parity（列此完备））;
验收: e2e **351/351**（319+32 FR, 含 multi-range 精确体 CL 246 / If-Range×3 / HEAD raw-socket 线级空体 / raw-socket chunked 帧级 / etag = md5(f64repr- size) md5sum 交叉验证）/ cargo **407/0/4**（354+53: file_protocol 30 + file_serve 15 + MD5 8）/ clippy 0 警告(双 crate) / bench 0 errors(37.7k req/s, 历史区间内) / ldd 仅 libc(libm 零化) / env -i 干净启动(health+/file 30B+/stream 14B) / **3.5M**(3,631,104 B, ≤4.2M, +75 KB vs 决策-47) / C 清零保持;
2026-09-10（**决策-47 Depends use_cache**（ADR-0022, Goal-0003 P2 矩阵 #9）：
每请求 memo 表 dep_cache(106, append-only, find 取最新条 = P9-3 覆写语义, calls_of = 实际派发次数) +
dispatch_dep/resolve_depends 加 nocache/cache 参数（子依赖递归双表: _depends = 默认 cached
（upstream use_cache=True, 菱形/三重菱形每请求 1 次 — 决策-33「各路径独立」收紧对齐）/ _depends_nocache
= use_cache=False（route/嵌套级, P9-2/4）+ P9-3 关键 nuance（nocache 派发结果同样入库, 写入无条件）+
每请求作用域（P9-1 第二请求））+ _dep_calls=true 声明门控注入 <dep>_calls（observability 超集）+
router.mojo base_deps_nocache + include_router(deps_nc=) 对称扩展（495 ≤500）
+ demo /di-cache（菱形）/ /di-nocache / /di-mix（嵌套 nocache）+ dc_tick/dc_auth/dc_auth2
+ 文档化偏差 ×4（ADR-0022 §3.5: per-name memo vs per-dependant（声明式等价）/ _dep_calls 超集 /
基础依赖恒 cached / 解析序先 cached 后 nocache）
验收: e2e **319/319**（312+7 DC, 含 P9-1/2/3 三语义 + 每请求作用域 + /di 与 APIRouter 零泄漏回归）/
cargo **354/0/4**（FFI diff = 0）/ clippy 0 警告(双 crate) / dep_cache_selftest 16 check /
bench 0 errors(34.8k req/s, 历史区间内) / ldd 仅 libc / env -i 干净启动(health+/di-cache 200) /
**3.4M**(3,556,048 B, ≤4.2M, +25 KB) / C 清零保持;
2026-09-10（**决策-46 UploadFile 对象 API**（ADR-0021, Goal-0003 P2 矩阵 #6）：
Rust bridge multipart.rs 重构（helpers pub(crate) + b64_decode/to_hex/sha256_hex_of lock-free 纯 std +
part_save 原子 .tmp→rename + getter field 5=sha256hex 解析期预算 — 修复非重入 Mutex 读路径自锁死锁隐患 +
multipart_tests.rs 拆分 17 测）+ FFI +1 mp_part_save（NUL 契约；.. 守卫在 Mojo _path_safe）
+ 纯 Mojo 新模块 ×4（file_params 427: _file_types file|bytes/[]/= + U2 value_error(上游完整措辞)/U4
last-wins/U5 非 multipart 全缺失/apply_file_extras(size=实际字节 U1, alias→声明名, text→bytes U9/text→form
U8, list _count+_list_json) / file_form_check 126: U3 string_type 稳定子集(上游 env 细节排除) /
file_ops_ffi 195: snapshot_mp_parts 单一 FFI 快照点 + head/range/sha256/save / openapi_multipart 145:
U7 四形态 schema(字段序 type/contentMediaType/title/description, key 序 properties/type/required/title,
required 仅当必填字段)）
+ dispatch（决策-32 旧注入移除 → CT 检测 → snapshot → filtered text map(U8)/parse_form_multi(urlencoded)/空(U5) →
validate_file_collect 恒执行 → 422 de-dup(p7 presence 胜, 整串精确匹配) → 成功路径 apply_file_extras/ops）
+ demo /upload-file（alias docfile + opt:file= + docs:file[] + note:str 必填 + ops sha256 + descs）/ /upload-bytes
（raw:bytes= + small:bytes= 全 optional + ops head/range/save）+ OpenAPI multipart requestBody（与 _body_schema
互斥；urlencoded 保留）
+ 文档化偏差 ×7（ADR-0021 §3.5: U9 上游 500 不复制 / input 稳定子集 / Body_<handler.name>_<method> 命名 /
save .. 守卫安全超集 / 未声明字段不校验 / name:type= = required（上游 Form("") = optional, p8 — 不修, ripple
决策-43/45）/ U3 missing de-dup（presence 胜））
验收: e2e **312/312**（294+18 MP8–MP23b, 含 MP4 size→实际字节修正 344→256）/ cargo **354/0/4**（+5 净:
b64 decode ×2 / sha256 向量 / save ×2）/ clippy 0 警告(双 crate) / bench 0 errors(34.3k req/s, 历史区间内) /
ldd 仅 libc / env -i 干净启动(health+/upload-file+/upload-bytes 200) / **3.4M**(3,531,472 B, ≤4.2M, +131 KB) /
C 清零保持;
2026-09-10（**决策-45 Form 多值/alias/desc + 422 detail parity**（ADR-0020, Goal-0003
P2 矩阵 #5）: 纯 Mojo form_params(493: parse_form_multi multi-map 全部 occurrence/validate_form_collect
collect-all/apply_form_extras alias wire key/legacy 兼容/form_openapi_schema F10 字段序) + request_response.
parse_form_multi + 422 全局 parity(3 构造器加 input: missing=null/parse=raw/JSON body 缺失=body 对象; "field required" → "Field required";
validate_list_values stop-on-first → collect-all — 更正 ADR-0018 错误实测; float 接受 int 字面量 P6;
parse_typed_value 接受 str 潜在 bug 修复) + dispatch 2 点接线(非 form CT → 空 multi = 上游同款; inject_
form_fields 移除 → apply_form_extras 单点) + /form-multi + /form-alias demo + form requestBody OpenAPI
(required:true 仅当无默认字段; Body_<name>_<method>); 附带 P0 修复(P7): /openapi.json 自决策-38 起非法
JSON(参数 schema 括号配对错 + _generate_parameter 过早关对象, 子串 e2e 从未发现) — 修正 + fmtool
jsoncheck 整文门禁(纯 std 新子命令); FFI diff = 0, 零新 crate;
验收: e2e **294/294**（274+20 FM, 含 jsoncheck 整文 + collect-all×2 守护）/ cargo **349/0/4** /
clippy 0 警告(双 crate) / bench 0 errors(34.2k req/s, 历史区间内) / ldd 仅 libc / env -i 干净启动
(health+/form-multi+/form-alias 200) / **3.24M**(3,400,400 B, ≤4.2M, +74 KB);
2026-09-10（**决策-44 OAuth2 password flow + JWT HS256**（ADR-0019, Goal-0003
P2 矩阵 #17 — 对标矩阵最后一项）: Rust bridge crypto.rs 纯 std 手写 SHA-256/HMAC-SHA256/
base64url(零第三方 crate, known vectors×12 + pyjwt-2.13 oracle 交叉验证) + FFI +2
(fm_hmac_sha256_b64url[_free], 决策-36 NUL 契约) + 纯 Mojo security_jwt(497: b64url 编码/
3-part 切分/flat JSON claims/check_oauth2/handle_oauth2_token); FastAPI 0.141.1 逐条 probe
对齐(宽松 form 模型: grant_type 可选(存在须 ^password$ 否则 422 pattern mismatch)/
username+password 必填(422 missing 全收集)/凭据错 401 "Incorrect email or password";
gate: 无头/非 bearer scheme 401 "Not authenticated"/校验失败(含空 Bearer)401
"Could not validate credentials" — 修正早期 403 假设); /token + /token-exp(ttl=-1) +
/secure-jwt 路由 + KIND_OAUTH2_TOKEN(201) dispatch 特例 + OpenAPI securitySchemes.
OAuth2PasswordBearer(bearerFormat:JWT); FFI diff = +2, 零新 crate;
验收: e2e **274/274**(248+26 OT, 含 pyjwt 独立签发 fixture T1..T5 + fmtool raw 空 Bearer)/
cargo **349/0/4**(+14 crypto) / clippy 0 警告(双 crate) / bench 0 errors(41.2k req/s,
历史区间内) / ldd 仅 libc / env -i 干净启动(含 /token+/secure-jwt) / **3.17M**(3,326,672 B,
≤4.2M, +49 KB);
2026-09-10（**决策-43 查询参数精化**（ADR-0018, Goal-0003 P2 矩阵 #3）：
List 多值（_param_types 语法扩展: T[] 必填 / T[]= 可选空 list / T[]=csv 带默认, 空括号 = list
非空 = enum 决策-38; 内部表示 = 全部 occurrence 的 CSV, handler 读 query_<key> 得 "a,b";
缺失 → 默认 CSV; 非法元素 422 首败即停 loc ["query",name,i] pydantic v2 完整措辞）
+ alias（_param_aliases, query-only path 豁免: 查询 key = alias, 原始 name 无绑定效力 —
校验按 alias key, 成功路径 values[name] 恒覆写绑定值, OpenAPI parameter.name = alias）
+ description（_param_descs → OpenAPI parameter 级 + schema 级双处, path/header 同样支持）;
纯 Mojo params_query_extra(364) + parse_table 泛化, 依赖图 params_typed → params_query_extra
→ params_query 无环(validate_list_values 函数级 back-import 实测可用);
标量多值保持 last-wins(Starlette MultiDict.get, QS-R1 回归守护); FFI diff = 0(Rust 零改动);
验收: e2e **248/248**（+27 QS）/ cargo **335/0/4** / clippy 0 警告 / bench 0 errors
（37.3k req/s）/ ldd 仅 libc / env -i 干净启动 / **3.12M**（3,277,520 B, ≤4.2M）；
2026-09-10（**决策-42 CORS 完整配置**（ADR-0017, Goal-0003 P2 矩阵 #15）：
Starlette CORSMiddleware 声明式 env 等价（FASTAPI_MOJO_CORS_ORIGINS CSV/`*` 默认 `*` +
_METHODS 7 方法 + _HEADERS CSV/`*` 默认 Content-Type,Authorization + _CREDENTIALS 默认 false +
_MAX_AGE 默认 600 = Starlette）；普通响应仅当请求带被允许 Origin（通配 → `*` / 白名单或
credentials → 回显 / 不允许 → 无头 — C 时代「每响应必带 `*`」偏差移除, 文档化）；
预检 204/400 动态（越界 → 400 JSON, 裸 OPTIONS → 204 通配超集）, FFI `send_preflight_response`
签名不变（**FFI diff = 0**, 零新增依赖 std only）；
验收: e2e **221/221**（+CRS-1..8）/ cargo **335/0/4** / clippy 0 警告 / bench 0 errors
（36.0k req/s）/ ldd 仅 libc / env -i 干净启动 / **3.1M**（≤4.2M）；
2026-09-09（**决策-41 response_model 精化**（ADR-0016, Goal-0003 P2 矩阵 #11）：
FastAPI/Pydantic exclude/exclude_none 声明式三参数（_response_model include + _response_exclude 剔除模型字段 + _response_exclude_none 剔除 null）;
应用序 include→exclude→exclude_none; 无模型时 no-op (FastAPI 对齐, /rm-noop demo + RM-7 固化);
单一 helper response_model_body (request_response.mojo) — dispatch 14 行 inline 块 → 1 行调用 (净减行, FFI diff = 0);
e2e **213/213** / cargo 323/0/4 / clippy 0 警告 / bench 0 errors (42.2k req/s) / ldd 仅 libc / env -i 干净启动 / 3.1M；
2026-09-09（**决策-40 GZip 中间件**（ADR-0015, Goal-0003 P2 矩阵 #24）：
Starlette GZipMiddleware 声明式 env 等价 (默认关 = FastAPI 对齐; MIN_SIZE 500 / MAX_SIZE 1MiB; 裸 token 判定, 不支持 q, 上游 quirk 对齐);
钩子 = send_response 单点 (所有响应类型必经): gzip level 6 + Content-Encoding: gzip + Content-Length 更新 + Content-Type 不变;
client 判定走 request 全局 (io.rs set_accepts_gzip, FFI diff = 0); flate2 纯 Rust miniz_oxide 后端 (无 C 路径, 静态, ldd 仍仅 libc 实测);
e2e **210/210** (+GZ-1..5) / cargo **323/0/4** / clippy 0 警告 / bench 0 errors (39.2k req/s) / env -i 干净启动 / **3.1M** (≤4.2M)；
2026-09-09（**决策-38 Pydantic 式 body 校验 + Field 约束 + Enum**（ADR-0014, Goal-0003 P1 T-P1d+T-P1e 全部达成）：
`_body_schema` 声明式 spec (str/int/float/bool/obj/arr + T[](数组) + T[values](enum) + obj{嵌套}; gt/ge/lt/le/len/items 约束; 注册期 fail-fast);
统一 422 detail (FastAPI/Pydantic v2 loc/msg/type, 参数+body 全错误收集, __nested__: 直通) + Enum 参数 (query/path T[values]) +
OpenAPI components/schemas 自动生成 (requestBody $ref, 单一事实源, 修复既有 2 处字面量 BUG); 两文件拆分 (spec 315/校验 313, 均 <500);
🔴 实测发现 Mojo 1.0.0 assert 是 no-op (此前 .mojo 自测 assert 从未生效; 本 ADR 首用 check() 真断言, 遗留修复独立任务);
**决策-39 P0 修复**：finish_header 在 body 与 header 同 recv 到齐 (小 body 必然) 时 UTF-8 校验缺 multipart 豁免 →
256B 全字节 multipart 文件误 400 (MP4); parse.rs 纯函数 is_multipart_form_data + finish_header 豁免 + io.rs 委托 (FFI 面不变);
验收: e2e **205/205** / cargo **312/0/4** / clippy 0 警告 / mojo 自测 21 check / bench 0 errors (41.9k req/s) / ldd 仅 libc / env -i 干净启动 / **3.1M** (≤4.2M);
2026-09-05（**决策-37 APIRouter**（ADR-0013, Goal-0003 P1 T-P1b）：
APIRouter prefix/tags/dependencies + include_router (include 时合并, dispatch 零改动: path 前缀拼接 + _tags CSV + _depends ';' -CSV 三层合并 + WS prefix + 依赖表合并);
OpenAPI 操作级 tags 输出 + path 分组 (修复既有重复 key 非法 JSON bug, /items GET+POST 同 key); KIND_ECHO demo 避免 _字段泄漏 (KIND_STATIC 全量 dump 为既有行为, 不动);
零 FFI 改动 (FFI diff = 0)；e2e 180/180 (+AR-1..8) / cargo 307/0/4 / clippy 0 警告 / bench 0 errors / ldd 仅 libc / 2.9M；
2026-09-05（**决策-36 Lifespan + FFI NUL 终止契约**（ADR-0012, Goal-0003 P1）：
声明式 env 命令 (STARTUP/SHUTDOWN 换行分隔 + TIMEOUT_MS) / 语义对齐 FastAPI-uvicorn (startup 失败 → 服务不启动; 多 worker 仅主进程) /
🔴 probe 发现 Mojo CStringSlice.as_bytes() 按 C 串语义读 NUL 忽略 slice.len → bridge fmc_slice 缓冲必须 [len]=0 契约
(存量审计 OK; 修复 run_command_json malloc(n+1) NUL — C 时代潜伏 bug, F11 out= 日志垃圾根因; +lifespan env 尾 NUL)；
补记 决策-31 G3 生产化 / 决策-32 multipart / 决策-33 DI / 决策-34 安全 / 决策-35 response_model；
e2e 168/168 / cargo 307/0/4 / clippy 0 警告 / ldd 仅 libc / 2.9M；
2026-09-04（**决策-24 v0.5.0 发布（Goal-0002 F1-F8 全部达成）**：
类型化参数 + HTTPException + Request/Response + 嵌套 JSON + OpenAPI + SSE +
/metrics + 结构化 access log + binary 瘦身 5.5M → 2.8M；e2e **118/118 全绿** /
cargo test **284 单测 / 0 警告 / 0 BUG** / bench 0 errors / ldd 仅 libc /
RSS 平台化 / env -i 干净启动；**v0.5.0 tag 已打已推**；
决策-25 结构化 access log (FASTAPI_MOJO_ACCESS_LOG=json)；
决策-30 UPX 评估 (不进默认; ldd 门禁失效 vs 1MB 体积收益不划算);
决策-29 F11 BackgroundTasks (响应后同步执行声明命令);
决策-28 F10 Header/Cookie/Form 参数注入 (F10a Cookie + F10b Form; 决策-27 F9 SSE status_code + extra 头 (上游 0.140.13 对齐 + 修复 v0.5.0 静默丢弃);
决策-26 binary strip 5.5M → 2.8M (-49%)；决策-22 Track B 去 Python；
决策-23 质量门禁；决策-21 终态 Mojo + Rust only；决策-20 DC2-h；
决策-19 Bridge 终态 Rust；决策-18 WS 精化；决策-17 高并发 WS；
决策-16 WS 增强；决策-15 WS；决策-14 单 binary 机制；决策-13 Mojo 单 binary 本标）*
