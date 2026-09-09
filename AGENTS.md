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
  -- --test-threads=1`，env 全局副作用需单线程）+ e2e (79 项起，含
  WebSocket 增强/并发/精化，扩展中) + 体积预算（中间态 ≤ 6M，终态 ≤ C + 2M）
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

- **已决策-30**：**UPX 压缩评估（v0.5.1 G3 调研，结论 = 不进默认构建，仅作可选手动部署）**：
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
*最后更新：2026-09-10（**决策-47 Depends use_cache**（ADR-0022, Goal-0003 P2 矩阵 #9）：
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
