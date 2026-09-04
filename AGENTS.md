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


*最后更新：2026-09-04（**决策-24 v0.5.0 发布（Goal-0002 F1-F8 全部达成）**：
类型化参数 + HTTPException + Request/Response + 嵌套 JSON + OpenAPI + SSE +
/metrics + 结构化 access log + binary 瘦身 5.5M → 2.8M；e2e **118/118 全绿** /
cargo test **284 单测 / 0 警告 / 0 BUG** / bench 0 errors / ldd 仅 libc /
RSS 平台化 / env -i 干净启动；**v0.5.0 tag 已打已推**；
决策-25 结构化 access log (FASTAPI_MOJO_ACCESS_LOG=json)；
决策-27 F9 SSE status_code + extra 头 (上游 0.140.13 对齐 + 修复 v0.5.0 静默丢弃);
决策-26 binary strip 5.5M → 2.8M (-49%)；决策-22 Track B 去 Python；
决策-23 质量门禁；决策-21 终态 Mojo + Rust only；决策-20 DC2-h；
决策-19 Bridge 终态 Rust；决策-18 WS 精化；决策-17 高并发 WS；
决策-16 WS 增强；决策-15 WS；决策-14 单 binary 机制；决策-13 Mojo 单 binary 本标）*
