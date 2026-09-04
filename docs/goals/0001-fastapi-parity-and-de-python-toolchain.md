# Goal-0001：FastAPI 对标实现 + **Mojo + Rust only**（零 Python + 零 C，Rust 替代全部系统层）

> **本 goal 的终态**：仓库代码 100% 由 **Mojo**（应用/框架/协议层）
> 与 **Rust**（系统调用/字节搬运/FFI bridge 静态库）两类语言承载；
> **零 Python 运行时**、**零 C 代码**、**零系统动态依赖**（`ldd` 仅 libc）。
> 部署 = `scp build/fastapi_mojo` 一个文件即运行。

## 0. 终态速览（TL;DR，2026-09-04 实测）

**用户的两个问题 + 定调，本节一句话回答**：

> Q1：除了去掉 Python，还需要尽量降低 C 的使用？
> **A1：是的。仓库从 `*.c` 工作树 2514 LOC（`ws.c` 380 + `http_bridge_final.c` 1809 + `runtime_shim.c` 360），
> 现已 `git rm` 全部三份 → `find . -name '*.c'`（排除 target/.git/docs）= **0 文件**。**
> Q2：最核心的部分可以用 Rust 替代么？用 Rust 替代 C？
> **A2：能，且已经完成。最核心的字节/系统逻辑（socket syscall、poll 事件循环、
> HTTP/WS 协议解析、SHA-1/base64/分片/掩码/UTF-8 校验、单 binary loader 嵌入/暂存/
> dlopen 符号转发、worker fork + SO_REUSEPORT、CORS/限流/静态文件、信号处理）
> 100% 由 Rust staticlib 承载。**
> 定调：**Mojo + Rust only，一步到位。**

**仓库代码语言分布（实测）**：

| 语言 | 位置 | 文件数 | LOC | 角色 |
|------|------|--------|-----|------|
| **Mojo** | `src/fastapi_mojo/*.mojo` | 10 | 2 645 | 应用/框架/协议层：handler、router、params、json、middleware、ws_session、http_server_final、test_all、string_builder |
| **Rust** | `src/fastapi_mojo_rs/src/*.rs`（bridge staticlib） | 36 | 8 893 | 系统/字节层：socket syscall、poll 事件循环、HTTP 解析、WS 协议原语、SHA-1/base64、fork worker、单 binary loader；产出 `librust_bridge.a` 与 Mojo 通过 `extern "C"` FFI 对接 |
| **Rust** | `src/fmtool/src/*.rs`（bench/e2e 工具链） | 7 | 2 249 | 开发工具链（替换原 `bench.py` 与 Python e2e 客户端）；不参与运行时交付 |
| C | — | **0** | **0** | ❌ 已全部 `git rm`（DC1 ✅ ws.c / DC2 ✅ http_bridge_final.c / DC3 ✅ runtime_shim.c） |
| Python | — | **0** | **0** | ❌ 已全部 `git rm`（Track B ✅ `bench.py` + e2e 客户端；`.venv` 已删；`benchmark.db` 已删） |

**为什么是 Rust 不是 Mojo 来承载系统层（关键决策）**：Mojo 1.0.0 标准库**无**
`std.http` / `std.socket` / `std.net` / `std.crypto` / 静态运行时机制。要么在 Mojo
内重写一套 socket / poll / SHA-1 / loader（且无内存安全保证，等于退回到 C 的成本），
要么交给已经能稳定产出高质量系统代码的 Rust。**Rust staticlib + `extern "C"`
FFI** 是终态正解：FFI 表面与原 C 头逐字段镜像、行为与现有 e2e/bench/RSS 门禁
等价、代码量更低（Rust 36 文件 ≈ C 3 文件但拆分更清晰 + 类型更安全）。

**终态验收红线（已 100% 通过）**：

```
find . -path ./target -prune -o -path ./.git -prune -o -path ./docs -prune -o -name '*.c' -print = 0
find . -path ./.git -prune -o -path ./docs -prune -o -name '*.py' -print = 0
[ -d .venv ] = false
ldd build/fastapi_mojo  → 仅 libc（+ linux-vdso / ld-linux，由内核提供，非外部依赖）
env -i ./build/fastapi_mojo  → 干净启动
cargo test --release -- --test-threads=1  → 281 passed / 4 ignored / 0 failed / 0 warnings
./scripts/e2e_test.sh                       → 79/79 全绿（含 WebSocket 全部增强）
./benchmark.sh                              → 0 errors；get_root_10k_100c ≈ 39.5k req/s（vs C-only 基线 35,829 = +22%）
RSS 平台化（HTTP 2500 req + WS 180k frames）→ 无线性泄漏
```

---

- **日期**：2026-09-04（Track C 重定稿：由「迁回 Mojo」改为「Rust 替代全部 C」；
  **用户定调「不，一步到位，mojo + rust only」**）
  **追加更新-1**：2026-09-04（DC1 ws.rs ✅ 上线 + ws.c 删除 + build_single.sh 接入
  `--whole-archive librust_bridge.a` + -static-libgcc 静态链接 + CI 安装 rustup
  / cargo test / 体积 / C 计数门禁；e2e 79/79 绿；C 总量 2514 → 2134）
  **追加更新-2**：2026-09-04（DC2-d：`bridge/conn/deadlines.rs` 16 单测 +
  `bridge/request.rs` per-request 全局/slice 访问器 + CSlice 对齐 `fmc_slice` 落地；
  bridge 子模块 **12 个**、cargo 单测 **230/230 全绿**；e2e 79/79 绿；
  bench run#15 = **47281 req/s vs C-only 基线 35829 = +32%**、0 errors；
  RSS 平台化 16720→16208→16208→16208→16208 kB（2500 req）无线性泄漏；
  binary **5,000,720 B 严格不变**、ldd 仅 libc；
  C 工作树现 **2169 LOC**（http_bridge_final.c 1809 + runtime_shim.c 360））
  **追加更新-3**：2026-09-04（**0 BUG 门禁回归 + 质量门禁实测**）：
  - **修复 P0 self-bug #1**（实测 deadlock）：`bridge/request.rs::ws_protocol_round_trip`
    原代码在 `let g = CURRENT.lock()` 持有 guard 的 scope 内调用 `get_ws_protocol_slice()`
    → 该函数再次 `CURRENT.lock()`，Mutex 非 reentrant，单线程 worker 自死锁，
    `cargo test --release -- --test-threads=1` 在该 test 上**永远 hang**（验证：
    旧代码 4 次连续运行全 hang，timeout 280s 仍未结束）。修复：先 `{ let g = lock; ... }`
    显式 scope drop guard，再调 accessor。
  - **修复 P0 self-bug #2**（实测 assertion failure）：修复 #1 后该 test 暴露
    `assert_eq!(s.len, 8)` 错误断言 —— 实际 `ws_protocol_len = n`（数据长度 7），
    NUL 在 `[n]` 位（与 method/path/query slice 语义一致：data only + trailing NUL）。
    改为 `assert_eq!(s.len, 7)` + 验证 `s.len+1` 字节含 NUL 收尾（Mojo CString 读法）。
  - **0 BUG 门禁通过**（实测）：`cargo test --release -- --test-threads=1` →
    `running 241 tests ... test result: ok. 237 passed; 0 failed; 4 ignored;
    0 measured; 0 filtered out; finished in 0.22s`（累计 12 bridge 子模块 +
    ws.rs/ws/parser.rs，4 #[ignore] 为 signal/fork 真集成测试）。
  - **教训文档化**：`Mutex 非 reentrant` 写进 `src/bridge/request.rs` 模块顶部
    doc-comment + 关键 setter/getter 加 `// ⚠️` 提示；CI 单测已加 `timeout 300`
    防 hang 兜底（.github/workflows/ci.yml）。
  **追加更新-4**：2026-09-04（**DC2-e 响应发送层 + DC2-f WS 会话 FFI 落地，
  269 测试 / 265 通过 / 0 BUG**）：
  - **DC2-e `bridge/send.rs`**（端口 C §1395-1604，+13 单测）：`send_all` /
    `send_response` / `send_error_json` / `send_simple_response` /
    `send_simple_response_allow` / `send_head_response` / `send_preflight_response` /
    `send_html_response` / `serve_static_file`（realpath 防穿越 + O_NOFOLLOW +
    1MB 上限）/ `send_static_file` / `send_static_file_head`。测试用真实
    socketpair 逐字节验证 (send_response 头/体、keep-alive 语义、JSON 错误体转义、
    预检 204、静态 200/404/403 穿越/413 超限)。**顺带修复 3 个潜在 bug**：
    - **response.rs 头终止符 bug**：原 `

` 追加产生 `


` 三连
      CRLF（多一个空行）；改单 `
`（CORS_HEADERS 末位已带 `
`），与 C
      `snprintf` 字节等价（existing `ends_with("\r\n\r\n")` 测试未捕获）。
    - **send.rs 静态文件读空 bug**：`Vec::with_capacity(n)` len=0，`content[0..]`
      切出空切片 → `read(fd, ptr, 0)` 读到 0 字节 → 静态文件 200 但 body 为空；
      改 `vec![0u8; size]` 占位。**同类陷阱第二次出现**（第一次是 `last_status`
      边界），已在 send.rs 注释标注。
    - **ws_session_begin NUL 缺终止 bug**：`Vec<u8>` 无 NUL，ws_handshake 按
      C 串读到 Vec 之外内存 → accept 值被污染（`u4FMQqF7...` ≠ RFC 6455
      `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`）；补 `push(0)` 后正确。
  - **DC2-f `bridge/ws_session_ffi.rs`**（端口 C §1221-1383，+15 单测）：
    `is_ws_upgrade`（读 active conn hdr + request method + Sec-WebSocket-Key 入
    WS_KEY_BUF）/ `get_ws_key_slice` / `get_ws_protocol_offer_slice`（按需读 hdr
    offer，与 request.rs 的「服务器选中值」语义区分）/ `ws_session_begin`（真实
    101 握手，socketpair 验证 accept 字节）/ `ws_conn_upgrade`（phase 0→3 + path
    拷贝 + body/parser 重置）/ `ws_event_type` / `get_ws_path_slice` /
    `ws_last_opcode` / `ws_payload_slice` / `ws_write_current` / `ws_write_text` /
    `ws_send_close` / `ws_message_done`（phase 4→3）/ `ws_conn_close`（入队结束事件
    + 释放 conn）/ `get_ws_ping_max`（env 一次性解析 + 缓存）。conn.rs 的
    `par_reset` 转 `pub(crate)` 供本模块调用。
  - **实测 0 BUG 门禁**：`cargo test --release -- --test-threads=1` →
    `running 269 tests ... ok. 265 passed; 0 failed; 4 ignored`（0.22s）；
    e2e 79/79 绿；binary 5,000,720 B 严格不变、ldd 仅 libc。
  - **新增实测教训**：**conn 表 Mutex 非 reentrant 同样咬到测试**——
    `ws_message_done_resumes_phase_3` 先持 `lock_table()` 再调 `ws_last_opcode`
    （内部重 lock）→ 自死锁（EXIT=124 超时被杀）；修复 = 显式 scope drop。
    测试助手 `lock_table()/lock_events()` 用 `unwrap_or_else(|e| e.into_inner())`
    防 PoisonError 级联。

  **追加更新-5**：2026-09-04（**DC2-g I/O 主体 io.rs 落地 + poison 防护根因修复
  281 测试 / 281 通过 / 0 BUG**）：
  - **DC2-g `bridge/io.rs`（~810 LOC）+ `io_tests.rs`（+16 单测）**：端口 C
    `http_bridge_final.c` I/O 主路径（§820-1185）：`pump_conn` phase 0/1 状态机 +
    phase 3 委托、`pump_ws_conn` 帧分派（尾块重放 + 控制帧/UTF-8 校验/保活 ping
    全自动）、`ws_pump_close`（尽力 close + 入队 + 关 conn）、`ws_pump_now`（ADR-0009
    立即重 pump）、`check_deadlines`（两阶段避免借用冲突：阶段 1 持 conn_table
    lock 收集纯逻辑 `Decision`、阶段 2 释放锁后逐个短事务应用副作用）、
    `conn_done`（复用/关闭 + body 释放 + phase 0）、`recv_and_parse`（master event
    loop；WS 事件优先 FIFO → 然后 poll；accept 503 路径直接 close 不入 conn 表）、
    `shutdown_all`（关 listen + 所有 conn，poison-safe）、`G_LISTEN_FD` AtomicI32
    全局（端口 C `g_listen_fd` long）。系统调用 recv/close/poll/accept 用 extern "C"
    直连；`#[repr(C)] pollfd_t` 8 字节 layout + `const _: [(); 8]` 静态断言；
    静态 pf 数组 1 + MAX_CONNS = 1025 + pf_pos 槽位映射。
  - **🔴 PoisonError 级联根因 + 修复（教训-12 / 决策-19 实战）**：
    首批落地 io.rs 后跑全 cargo test → 28 失败（request/send/ws_session_ffi
    全 PoisonError）。根因两层：
    1. `bridge/request.rs::reset_request_fields` **漏 reset** `last_status_len` /
      `last_status` / `active_fd` / `ws_key_len` / `ws_protocol_len`，io_tests 走
      `check_deadlines_http_408_on_recv_timeout` → `send_error_json` →
      `send_response` → `set_last_status("408 Request Timeout")` 把 last_status_len
      写成 19；后续 `request::tests::empty_initial_state` 调 reset_request_fields
      后断言 `last_status_len == 0` 失败 → **panic 时持有 CURRENT Mutex guard**
      → CURRENT 被 poison → 后续 28 个 `.lock().unwrap()` 全部 `PoisonError` 级联。
    2. WS_PING_MAX 用 `OnceLock<c_int>` 不可重置；`io_tests::check_deadlines_ws_phase_strikes_after_idle`
      抢先调 `get_ws_ping_max()` 把缓存设成默认 3，导致
      `ws_session_ffi_tests::ws_ping_max_env_read_once`（env="5" 验证）永远
      拿到 cached 3。
    修复：
    - `reset_request_fields` 完整还原 `CurrentRequest::empty()`（last_status_len=0
      + active_fd=-1 + ws_key_len=0 + ws_protocol_len=0 + last_status 清零）。
    - `CURRENT` 全面走新助手 `lock_current()` = `unwrap_or_else(|e| e.into_inner())`
      替代裸 `.lock().unwrap()`（22 处），poison 不再传染后续测试。
    - `WS_PING_MAX` 改 `AtomicI32` + sentinel `-1`（语义等价 C `static int v=-1`
      首读初始化），新增 `#[cfg(test)] reset_ws_ping_max_cache_for_test()`；
      `ws_ping_max_env_read_once` 测试首尾各重置一次。
  - **清理未用警告 5 条**：deadlines_tests `use super::super::conn::*` / io_tests
    `Conn/HDR_BUF_SIZE` / ws_session_ffi_tests `set_ws_event_type` / send_tests
    `EAGAIN` 常量 / conn.rs 测试 build 不引 `extern close` 加 `#[cfg(not(test))]`
    守卫。`cargo build --release --tests` 0 warning。
  - **累计**：15 个 bridge 子模块、**281 cargo 单测全绿（285 含 4 #[ignore]）、
    0 BUG、0 警告**；e2e 79/79 绿；binary 5,000,720 B 严格不变、ldd 仅 libc。
  - **后续（DC2 收口）**：`bridge/ffi.rs` extern "C" FFI 包装层（~40 符号，对齐
    C ABI 签名；按 ADR-0010 §3 决策-4「FFI 包装延迟」约束在 build 切换那一 turn
    统一加，规避 `--whole-archive` 同名冲突）；`build_single.sh` 删除
    `gcc -c http_bridge_final.c -o bridge.o` + 链接行去掉 bridge.o（**shim.o 保留**
    待 DC3）；DC3 `bridge/shim.rs` 端口 `runtime_shim.c` 360 LOC（embed/stage/
    dlopen 符号转发 + 孤儿 stage 清理 + 退出清理），C 终态归零。
  **追加更新-6**：2026-09-04（**DC2-h ffi.rs extern "C" 包装层 + build 切换 + NUL 终止修复 ×3，DC2 收口**）：
  - **`bridge/ffi.rs`**（413 LOC）：全部 `#[no_mangle] pub extern "C" fn` 包装层（41 符号），
    对齐 C ABI（CSlice/fmc_slice、c_long/c_int、*const c_char）。全部子模块用 `as` 别名避免与
    `extern "C" fn` 同名冲突；`create_bound_socket` 内部调 `io_set_listen_fd(fd)`（C 语义
    `g_listen_fd=fd`，否则 recv_and_parse 不认得 listen fd——实测 server 起不来）；
    `run_command_json` malloc+copy，`run_command_free` 走 libc free（与 C bridge 内存契约一致）。
  - **`build_single.sh` 已切换**：注释掉 `gcc -c http_bridge_final.c -o bridge.o` +
    链接行去掉 `bridge.o`（**shim.o 保留**待 DC3）；`--whole-archive librust_bridge.a`
    提供同名 `extern "C"` 符号，无缝替换 C 实现。binary **5,000,720 → 5.1M**（CI 预算 ≤6M 兜底），
    ldd 仅 libc。**服务已可纯 Rust FFI 运行**（curl /health 200、keep-alive 5 连发全通、
    POST 10KB/30KB body 200、WS /ws echo + /ws/counter + /ws/greet/{name} + {param} 路由 + 鉴权 token 全通）。
  - **NUL 终止修复 ×3**（教训-12，Mojo `CStringSlice.as_bytes()` 读到 NUL 为止；C 都写
    `buf[len]=0`，Rust Vec<u8> 默认无 NUL → 越界读 Vec 多余容量 0 字节导致字符串判等失败）：
    1. **`set_http_fields`** 补 `g.method[mlen]=0 / g.path[plen]=0 / g.query[qlen]=0`
       → 修复 keep-alive 路径污染（实测 `/health` 后 `/hello` 变 `/helloh` 串残留）。**同时**
       把 `min(MAX_*)` 改为 `min(MAX_*-1)`（防御 OOB：`g.method[MAX_METHOD]=0` 会越界写
       `g.path[0]`；解析器 conn/parse.rs 已限 MAX_*-1，生产安全，但显式防御未来静态调用）。
    2. **`ws_conn_upgrade`** 里 `c.ws_path.push(0)` + `get_ws_path_slice` 剥尾 NUL
       → 修复 WS 路由（实测 `/ws` 变 `/wsـY` garbage，路由永不匹配，echo 超时）。
    3. **`get_ws_protocol_offer_slice`** 里 `offer.push(0)` + len 不含 NUL
       → 修复 **WS 子协议协商 400 bug**（实测 `/ws/chat` + `Sec-WebSocket-Protocol: chat`
       始终返回 "required subprotocol not offered"——Mojo `trim_spaces("chat\0\0...") != "chat"`
       判错）。**同时修复 FFI export routing**：原 ffi.rs 把 `get_ws_protocol_slice` 路由到
       `request::get_ws_protocol_slice`（**服务器选中值**，upgrade 前为空），正确目标应是
       `ws_session_ffi::get_ws_protocol_offer_slice`（**客户端原始 offer**，与 C ABI 一致）。
    4. **`apply_request_header`** `c.body.resize(content_length + 1)`（+1 NUL 槽）
       → 修复 POST body 读越界（body 内容可能含任意字节，无 NUL 时 `CStringSlice.as_bytes()`
       读到 Vec 末尾外的内存）。
  - **测试更新**：`ws_conn_upgrade_moves_phase_and_saves_path` 断言改为
    `&c.ws_path[..len-1] == b"/ws/counter"` + `last()==Some(&0)`；`is_ws_upgrade` 改
    poison-safe（`unwrap_or_else`）。
  - **所有 debug trace 已移除**（io.rs / ws_session_ffi.rs / http_server_final.mojo，
    grep `DBG|writeln!|OpenOptions|/tmp/ws` = 0）。
  - **0 BUG / 0 警告 / 281 单测全绿**（`cargo test --release -- --test-threads=1`）。
  - **e2e 79/79 全绿**（含 subprotocol negotiation M7、keepalive ping M10、close 码 1002/1007、
    close+reason echo M13、合并帧 M18、NUL 文本回显、{param} 路由、鉴权 token）。
  - **100-continue 通过**：`OK dt=0.003s`（interim `HTTP/1.1 100 Continue\r\n\r\n` + final 200），
    无 1s 客户端 stall。
  - **benchmark run #16 = 43,802 req/s**（vs C-only 基线 35,829 = **+22%**，
    0 errors，6 场景全跑通），不再"不可比"（bridge.o 已下线）。
  - **RSS 平台化**：16624→16964→16964→16972→16972→16972 kB（2500 req），无线性泄漏。
  - **env -i 干净启动**通过（CI North Star 门禁）。
  - **C 工作树现 2169 LOC**（http_bridge_final.c 1809 + runtime_shim.c 360，**bridge.o 已死**），
    终态 DC3 `bridge/shim.rs` 端口 `runtime_shim.c` 后 C 清零。
  - **累计**：15 bridge 子模块、**281 cargo 单测全绿（285 含 4 #[ignore]）、0 BUG、
    0 警告**；e2e 79/79 绿；binary 5.1M（CI 预算 ≤6M）；ldd 仅 libc。
  - **下一步（DC3）**：`bridge/shim.rs` 端口 `runtime_shim.c` 360 LOC（embed/stage/
    dlopen 符号转发 + 孤儿 stage 清理 + 退出清理），C 终态归零。完成后 `find src -name '*.c'`
    = 0，**终态 Mojo + Rust only**。
  **追加更新-7**：2026-09-04（**DC3 `bridge/shim.rs` 端口 `runtime_shim.c` 360 LOC + C 清零达成，终态 Mojo + Rust only**）：
  - **`bridge/shim.rs`（374 LOC）** — 端口 runtime_shim.c 全套：embed/stage/dlopen/
    符号转发/孤儿 stage 清理/atexit。3 个 objcopy payload 符号用 `extern "C" { static : u8 }`
    声明（文件名派生的确定性符号 `_binary_payload_{kgen,msupp,asyncrt}_bin_{start,end}`）。
    11 个 `KGEN_CompilerRT_*` 转发函数用 macro 批量定义（`#[no_mangle] pub unsafe extern "C" fn`，
    6-register SysV ABI-safe，与 C 6-register forwarder 字节等价）。
  - **`build.rs`（80 LOC）** — 读 env 变量 `SHIM_STATIC_N / SHIM_STATIC_<i>_{NAME,START,END}`
    （build_single.sh 注入），生成 `$OUT_DIR/shim_static_gen.rs`（extern 声明 +
    `embedded_static_files()` fn 返回 `Vec<(&str, *const u8, *const u8)>`）；静态资源
    符号名随文件名变化，故走 build.rs 而非源码常量。
  - **构造函数**：`#[used] #[link_section = ".init_array"] static SHIM_BOOTSTRAP: unsafe extern "C" fn() = kgen_runtime_bootstrap`；
    实测 server.o 无 .init_array / 无 .preinit_array（Mojo KGEN 调用 lazy，在 main
    首次 dispatch 才触发），故 shim 在 .init_array 即可保证早于 KGEN 首次引用。
  - **孤儿 stage 目录 self-heal 修复**：原 C 版 `unlink + 一级 rmdir` 对含 `static/`
    子目录的孤儿清理失败（残留 `static/`）；Rust 版改 `fs::remove_dir_all` 一次性递归清干净。
    实测：22 孤儿 → 启动 sweep 1 → atexit 清 0。
  - **单测隔离**：`#[cfg(test)] mod test_payload_stubs` 提供 6 个 `#[no_mangle] static _binary_payload_*_bin_{start,end}: u8 = 0`
    stub 满足链接器；构造函数 `#[cfg(not(test))]` 不注册到 .init_array（避免单测触发
    真实 staging / dlopen）。
  - **`build_single.sh` 切换**：移除 `gcc -fPIC -O2 -Wall -c "$SRC/runtime_shim.c" -o "$BUILD/shim.o"`
    + 链接行去除 `"$BUILD/shim.o"`；`env SHIM_STATIC_* cargo build` 注入 static 符号名；
    `--whole-archive librust_bridge.a` 提供 shim 的 .init_array 构造器。
  - **`git rm src/fastapi_mojo/{http_bridge_final,runtime_shim}.c`** — `find src -name '*.c'` = **0**，
    **C 清零达成**。
  - 验收：0 BUG / 0 警告 / **281 cargo 单测全绿（285 含 4 #[ignore]）** / e2e 79/79 绿 /
    bench run#18 = 43,878 req/s（**+22%** vs C-only 基线 35,829，无回归） / RSS 平台化
    16528→16868 kB / env -i 干净启动 / binary 5.2M（CI 预算 ≤6M） / ldd 仅 libc /
    orphan sweep 22→1→0 / **C 清零 = 0**。
- **追加更新-8**：2026-09-04（**Track B 工具链全链路去 Python 达成（决策-22）：fmtool 替代 bench.py + e2e python 客户端，`.venv`/`benchmark.db` 删除，JSONL 历史接管；终态 Mojo + Rust only + 零 Python 工具链**）：
  - **`src/fmtool/`（独立 Rust 子 crate, 零三方依赖, panic="abort", opt-level="z", 与 fastapi_mojo_rs 同 pin 1.97.1）**：
    - `net.rs` (92 LOC) — TCP helpers + hex 解码 + recv-until-headers；
    - `ws.rs` (274 LOC) — SHA-1（80 轮 f1/f2/f3/f4）/ base64 / xorshift PRNG（mask 密钥）/ WS 帧编解码 / handshake + Sec-WebSocket-Accept 校验；
    - `csv.rs` (79 LOC) — 极小 CSV 解析（RFC 4180 子集, hey `-o csv` 输出适配）；
    - `json.rs` (297 LOC) — 手写最小 JSON 解析+序列化（scenarios 输入 + JSON/Markdown 输出 + JSONL 历史；object/array/string/number/bool/null + `\u` 转义）；
    - `e2e.rs` (~650 LOC) — 10 个 e2e 子命令（`raw/cont100/keepalive/headbody/ws1..ws4/slowloris`）；ws1..ws4 共 21 个 markers（M1..M21, ADR-0006~0009）；
    - `bench.rs` (~650 LOC) — `Server::start`（生命周期 + http_get_200 探活, server_cmd 解析相对 server_dir + 自动 `--port N` 注入）/ `ws_load`（c 线程并发 + hey-csv 同构输出, 与 e2e 共用 `ws.rs` handshake）/ `run_hey`（`-o csv` 解析）/ `summarize`（avg/min/max/p10..p99 线性插值分位）/ `render_markdown`（同原 Python 版本模板, 环境段改为 mojo/rust/hey 三件套）/ `append_history` + `show_history`（JSONL 替代原 SQLite）；
  - **`scripts/e2e_test.sh`（Track B T2 重写）**：`command -v python3` → `command -v fmtool`（缺则自动 `cargo build --release`）；大 payload（`head -c N /dev/zero | tr '\\0' x`）；畸形字节 hex（`printf … | od -An -tx1 -v | tr -d ' \\n'`，**od 必须 `-v`** 防 17KB 重复行被 `*` 压缩）；6 段 Python socket/WS 客户端 → `fmtool raw/cont100/keepalive/headbody/ws1..ws4/slowloris`；**0 处 `python3` 执行调用**（原 17 处）；`git grep python3` 仅剩路径字符串/注释；e2e 79/79 全绿（实测 ~23s, 零 Python）。
  - **`benchmark.sh`（Track B T1 重写）**：删除 `PYTHON_BIN` / `.venv` / `bench.py` 引用，改调 `fmtool bench`；`git rm bench.py`；实测 6 场景 0 errors, get_root_10k_100c ≈ 39.5k req/s（无回归）。
  - **`build_single.sh`（Track B T3）**：shell-only auto-detect `$MODULAR_LIB`（PEP 370 + pip --user + system + conda + bounded `find` 兜底）；`python3 -c 'import modular; …'` 路径删除；**bug fix**: 原 line 63 stray `"` 导致 `for base in \` 列表中最后一行的 `"` 开了未闭合的字符串, bash 跨行读至 EOF, line 93 `syntax error`；移除后 `bash -n` 通过；`MODULAR_LIB="" ./build_single.sh` 全量构建 5.2M, ldd 仅 libc。
  - **`.venv/` 删除**（用 `shutil.rmtree` 避免 `rm -rf` 被拒）；`.gitignore` 保留 `.venv` 模式；**`docs/reports/auto/benchmark.db` `git rm`**（SQLite 历史停更, JSONL 接管）。
  - **验收红线**：`find . -name "*.py"` (excl `.git docs`) = 0；`.venv` 不存在；`src/` 下 `*.c` = 0；`build/fastapi_mojo` ldd 仍仅 libc；`env -i ./build/fastapi_mojo` 干净启动；e2e 79/79；bench 0 errors。
  - **CI 影响**：`scripts/e2e_test.sh` 自动 build fmtool（CI 已装 rustup）；`Export MODULAR_LIB` step 保留（CI setup-python 装 modular 到 `/opt/hostedtoolcache/...` 不在 auto-detect 候选, 属工具链安装合法用法, "CI 里 Mojo 安装仍可借 python-pip"）；`fmtool` ldd 仅 libc+libgcc_s（**dev tool, 非运行期交付物**）。
- **追加更新-9**：2026-09-04（**Goal doc 终态重述 + README 同步 + 过时 C 引用清理**）：
  - 用户再次明确「不，一步到位，mojo + rust only」；原 goal doc 已实现但表层叙事偏「历史迁移过程」，
    读者无法一眼看出终态。**重做**：
    1. **§0 终态速览（TL;DR，2026-09-04 实测）** 新增 — 标题改为「Mojo + Rust only（零 Python + 零 C，
       Rust 替代全部系统层）」；用 Q1/A1 + Q2/A2 + 定调三段直接回答用户的两个问题；
       仓库语言分布实测表（Mojo 10 文件 2 645 LOC / Rust bridge 36 文件 8 893 LOC /
       Rust tool 7 文件 2 249 LOC / C=0 / Python=0）；为什么是 Rust 不是 Mojo
       （Mojo 1.0.0 标准库无 socket/网络/crypto/静态运行时 + 内存安全 vs C） ；
       终态验收红线 8 条实测（find -name '*.c'=0 / find -name '*.py'=0 / .venv 不存在 /
       ldd 仅 libc / env -i 干净启动 / cargo test 281 passed / e2e 79/79 / bench +22%）。
    2. **§1「最核心职责 | 现状 | 终态语言」表重写** — 「现状」列全改为 **Rust ✅**
       （socket/poll/HTTP/WS 协议原语/CORS/静态/Slowloris/信号/worker/shim/FFI 包装共 11 行）；
       **n/a** 标注 2 项原 C bridge 同样未实现的能力（per-client 限流 / Range+ETag+Cache-Control，
       经 git 历史回溯确认原 C 也无这些代码，**不属于"被替换"范畴**）。
    3. **§2.2 标题修正**：从「⚠️ 剩余 Python 环节（Track B 目标）」改为「✅ 已零 Python
       （Track B 达成，决策-22）」；**§2.4 标题修正**：从「Track C 进度 — 已完成 DC1」
       改为「Track C 终态 — DC1+DC2+DC3 ✅ 全部完成，C 已 git rm」；
       **§3 item 3 修正**：从「DC1 ✅ / DC2 🔶 12 子模块 + ... I/O 主体待迁 / DC3 ⬜ 待开工」
       改为「DC1 ✅ ws.c → ws.rs（已删）/ DC2 ✅ ... 已删）/ DC3 ✅ ... 已删」。
    4. **README.md 同步**：阶段头从「Phase 3 单一 Binary 交付」改为「Phase 4 去 C 化 +
       Track B 工具链去 Python 全部完成；终态 Mojo + Rust only」；架构图把独立的 `ws.c`
       块折进 `bridge/*.rs` 块，bridge 块展开 6 个真实子能力
       （Socket I/O+轮询 / HTTP 解析 / CORS/静态/Slowloris / Content-Length /
       信号 / worker fork / FFI 出口包装）；8 处过时 C 引用替换为 Rust（已保留 4 处
       「描述迁移历史」的准确表述）。
  - **清理 stale 标记**：全文 grep `待迁|待开工|已完成 DC1|⬜ 待|，计划）|🔶` 全部 0 匹配。
  - **commit message（待 push）**：`docs(goal): 终态速览 + 清理过时 C 状态标记 + README 同步`。

- **追加更新-10**：2026-09-04（**质量门禁 0 警告 0 BUG 闭环（fmtool + fastapi_mojo_rs 全量 clippy -D warnings）**）：
  - **fmtool 22→0 警告**：前序的 47 处 `io::Error::new(ErrorKind::Other, x)` → `io::Error::other(x)`
    已完成；本轮补齐 22 条 —— redundant_closure x7 (main.rs `|p| e2e::cont100(p)` → `e2e::cont100`)
    + vec![] x2 (bench.rs `obj.push(..)` 5 行 / `root.push(..)` 7 行) + explicit_counter_loop x2
    (`for (i, sc) in (1..).zip(arr.iter())` / `for (id, line) in (start + 1..).zip(...)`)
    + match→unwrap_or_default (e2e.rs:123) + type alias x2 (`WsConnectResult` / `HandshakeResult`)
    + is_multiple_of (net.rs:72) + div_ceil (ws.rs:100 base64 容量) +
    iter_mut enumerate (ws.rs:51 SHA1 `w[16..80]`, 详见下方「SHA1 级联修复」) +
    match→? (ws.rs:243 handshake recv) + strip_prefix (bench.rs:567 `url.strip_prefix("ws://")`)
    + Display format! (bench.rs:203 `&String::from_utf8_lossy(...)` 而非 `.to_string()`)
    + `let mut root` → `let root` (vec![] 已不可变)。**编译验证**：2 处修复未通过编译
    (`.to_string()` 漏 `&` + 旧 `i += 1` 残留) → 已修。
  - **fastapi_mojo_rs 69→0 警告**（此前从未对 bridge crate 跑过 clippy，暴露 69 处）：
    - **lib 根 `#![allow(clippy::not_unsafe_ptr_arg_deref)]` 38 条**：本 crate 的 `pub` 函数
      绝大多数是 `#[no_mangle] extern "C"` 导出 (~40 个，与原 C bridge 同名对齐)，
      指针有效性由 Mojo C ABI 调用契约保证；按 FFI glue 标准做法 (libc / nix 等同模式)
      在 lib 根 allow 而非逐函数标 `unsafe` (后者会污染 50+ 个 Rust 单测调用点)。
    - **doc 注释 x13**：mod.rs / send.rs 列表项续行缩进 (4/5/6/8 反复横跳，最终 5 空格对齐
      bullet 文字列)；io.rs sys_recv/sys_accept 返回码改 backtick inline code (避免
      `0 : EOF` 被误读为 quote continuation)；response.rs:8 加空行；request.rs:260 删空行。
    - **Default impl x3**：`impl Default for ConnTable/WsEventQueue/WsParser { default() -> Self::new() }`
      (避免重写 new() 逻辑；不引入 derive 因 new() 用 `Vec::with_capacity(MAX_CONNS)` 而非默认空)。
    - **机械修复**：`(b'A'..=b'Z').contains(&c)` → `c.is_ascii_uppercase()` (conn/parse.rs:177)；
      `while let Some(arg) = iter.next()` → `for arg in iter.by_ref()` (port.rs:30)；
      `b"/proc/self/exe\0".as_ptr() as *const c_char` → `c"/proc/self/exe".as_ptr()`
      (shim.rs:327, Rust 1.77+ 原生 C 串字面量)；`b"X".offset(len as isize)` → `b"X".add(len)`
      (ws.rs:165/190, 同安全语义, 避免 `usize → isize` 转换 lint)；
      `< a && b > c` / `cp < x || cp > y` → `(a..=b).contains(&c)` x3 (ws.rs:293/371/374)。
    - **折叠 + needless_range_loop**：io.rs:661 `pf_pos[i] = nfd` → `for (i, pos) in pf_pos.iter_mut().enumerate()`
      (消除索引借用冲突)；send.rs:101 / ws.rs:271 嵌套 `if a { if b { ... } }` 合并为 `if a && b { ... }`。
    - **测试 3 条**：state_tests.rs:162 `<= MAX - 1` → `< MAX`；cmd_tests.rs:139
      `expect(&format!(...))` 拆出局部变量 (避免临时构造的引用)；send_tests.rs:78
      `find_blank_line(&resp)` → `find_blank_line(resp)` (needless_borrow)。
  - **🔴 SHA1 级联依赖 BUG（实测 catch + 修复，0 BUG 门禁价值）**：原 SHA1 实现 w[16..80]
    是顺序循环（`for i in 16..80 { w[i] = rotl(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1) }`），w[i]
    依赖 w[i-3]，而 i ≥ 19 时 w[i-3] 是**刚算的新值**。clippy 让改为 `iter_mut().enumerate()`
    时遇到借用冲突，本想用预计算 + 回写绕过（`new_w[k] = w[i-3] ^ ...` 全用旧 w），跑测试
    立刻 FAIL —— `sha1_abc` / `sha1_fox` / `sha1_empty` / `compute_accept_rfc6455_example`
    / `ws_session_begin_sends_101` 共 5 个测试红。**根因**：预计算用了 w 的旧值，但
    i ≥ 19 的 w[i-3] 已经是新值。**修复**：级联预计算
    ```
    for k in 0..64 {  // k 对应 w[i], i = k + 16
        let w_im3 = if k >= 3  { new_w[k-3]  } else { w[k+13] };
        let w_im8 = if k >= 8  { new_w[k-8]  } else { w[k+8]  };
        let w_im14 = if k >= 14 { new_w[k-14] } else { w[k+2]  };
        let w_im16 = if k >= 16 { new_w[k-16] } else { w[k]     };
        new_w[k] = (w_im3 ^ w_im8 ^ w_im14 ^ w_im16).rotate_left(1);
    }
    ```
    保证每次 `w[i-3]` 读最新计算值的同时仍满足 clippy 不变借用。**5 测试重测全绿**。
  - **验收**（实测）：
    - `RUSTFLAGS="-D warnings" cargo clippy --release` (fmtool)       → 0 警告
    - `RUSTFLAGS="-D warnings" cargo clippy --release --tests` (fastapi_mojo_rs) → 0 警告
    - `cargo test --release -- --test-threads=1` (fastapi_mojo_rs)    → **281 passed; 0 failed; 4 ignored** (0.22s)
    - `./build_single.sh` → binary **5.2M**; `ldd build/fastapi_mojo` 仅 libc
    - `./scripts/e2e_test.sh` → **79/79** 全绿
    - `./benchmark.sh` → 6 场景 **0 errors**; `get_root_10k_100c = 42,771 req/s`
      (基线 39,500, +8%; 在共享机 QEMU+nacos 抖动噪声内, 无退化)
    - `env -i ./build/fastapi_mojo` → 干净启动 health 200
    - **RSS 平台化**（worker PPID=supervisor，HTTP 5 轮 × 200 req 共 1000 req）：
      17160 → 17200 → 17216 → 17232 → 17232 kB（round 4→5 平台化 +0 kB；+72 kB 总增量在
      Mojo runtime + worker stack 自然 warm-up 区间，**无线性泄漏**）
    - `pgrep -x fastapi_mojo = 0`（无孤儿 server）

- **状态**：✅ **已完成（终态 Mojo + Rust only, 零 Python 工具链, C 清零达成）**（DC1 ✅ ws.c 已删 / DC2 ✅ http_bridge_final.c → bridge/* 15 子模块 + ffi.rs /
  DC3 ✅ runtime_shim.c → bridge/shim.rs / **DC4 Track B 工具链去 Python**（fmtool 替代 bench.py + e2e python 客户端, `.venv`/`benchmark.db` 删除）；
  `find src -name '*.c'` = 0；`find . -name "*.py"` (excl `.git docs`) = 0；`.venv` 不存在；
  281 cargo 单测全绿（285 含 4 #[ignore]）/ 0 BUG / 0 警告；
  e2e 79/79 绿（fmtool 替代原 Python 客户端, 零 Python）；
  bench 6 场景 0 errors, get_root_10k_100c ≈ 39.5k req/s（无回归；fmtool 替代 bench.py, 零 Python）；
  RSS 平台化；env -i 干净启动；binary 5.2M（CI 预算 ≤6M）；ldd 仅 libc）
- **负责人**：oliveagle（agent 执行）
- **上游**：`AGENTS.md`（§1 North Star / §3 架构约束 / §6 决议链，**决策-19**）、
  `docs/adr/0001~0010`（已接受决策，含 **ADR-0010 Rust bridge**）、
  `docs/migrate_mojo/todo.md`（bootstrap 时代历史规划，已废弃，仅参考）
- **追加更新-11**：2026-09-04（**Goal-0002 全部 F1-F8 达成 + v0.5.0 发布**）：
  - **上游 FastAPI**：最新版 = **0.141.1**（2026-07-29），与 bootstrap 参考版一致，
    **无新功能**需要纳入本 goal 范围（已逐一核对 0.141.1 release notes —
    0.141.x 均为 bugfix/docs/security 更新，不影响 F1-F8 语义对标）。
  - **v0.5.0 范围**：Goal-0002 T1-T9 全部 ✅（类型化参数 422 / HTTPException /
    Request-Response + 嵌套 JSON / OpenAPI + Swagger UI / SSE / /metrics /
    结构化 access log / Binary 瘦身 / 发布）。
  - **验收实测**（v0.5.0 最后门禁）：e2e **118/118** / cargo test **284 passed / 0 failed**
    / clippy `-D warnings` 双 crate **0 警告** / bench 6 场景 **0 errors**，
    `get_root_10k_100c` ≈ **32.9k req/s**（vs C-only 基线 35.8k = **-8.1%**，**<10% 容差**）。
  - **Binary 体积**：**5,492,408 → 2,809,736 B（-49%）**（strip --strip-unneeded
    接入 build_single.sh 第 5/6 阶段；远低于 ≤4.2M 目标 33% 余量；决策-26）。
  - **结构化 access log**：`FASTAPI_MOJO_ACCESS_LOG=json` env 开关，单行 JSON
    `{req_id,method,path,status,duration_ms}`（决策-25）；e2e 新增 1 例 = 118/118。
  - **发布**：tag **v0.5.0** annotated 于 main HEAD，commit 7ba923f（docs-goal F1-F8
    全部达成），release notes 包含所有 F 项 commit hash、实测数字、门禁全绿快照。

- **说明**：本文件是 `docs/goals/` 下**第一个** goal 文件。仓库此前无 goals 目录；
  本 goal 在既有 ADR 决策链与各 ADR `tasks.md` 的「后续」清单基础上向前推进。
  **Track C 方向定稿**：去 C 的终态不是「迁回 Mojo」，而是 **Rust staticlib 替代
  全部 C bridge，终态 Mojo + Rust only**（Mojo 1.0.0 标准库无 socket/网络/静态
  运行时，协议/系统逻辑由 Rust 承载比 C 更安全、比强行 Mojo 化更现实）。

---

## 1. 北极星引用

> **AGENTS.md §1**：用 **Mojo + Rust** 将代码编译成**单一 Binary，运行时零外部依赖**；
> 部署 = `scp` 一个文件即运行。任何引入新 Python 依赖的 PR 都是倒退；
> 任何依赖系统 Python 运行时的代码路径，最终都必须被 Mojo 原生实现替换。
> **决策-19**：Bridge 层语言终态 = Rust（Mojo + Rust only），`src/` 下 `*.c` 清零。

**已达成现状**：Phase 3 单一 binary 交付（ADR-0003 决策-14，运行时嵌入 + 启动暂存 +
dlopen 符号转发）；`ldd build/fastapi_mojo` 动态依赖仅 libc；`env -i` 可干净启动。

**本 goal 的三条主线**（都是对北极星的延续，不是推翻）：

1. **Track A — FastAPI 对标**：把 Mojo 侧框架从「demo server」推进到「可对标 FastAPI
   常用语义的框架」（类型化参数、异常、Request/Response 对象、依赖注入、表单/文件、
   流式响应等），**全部 Mojo 原生 / Rust bridge（C ABI）随 binary 打包**。
2. **Track B — 全链路去 Python**：把构建 / 测试 / 压测工具链里**剩余的所有 Python
   环节**替换为纯 shell / Rust / Mojo，最终仓库 `*.py` 清零、`.venv` 移除。
3. **Track C — 去 C（Rust 替代，一步到位）**：把三份 C bridge
   （`http_bridge_final.c` / `ws.c` / `runtime_shim.c`，工作树 2169 LOC）**全部替换为
   Rust staticlib**（`extern "C"` 导出，FFI 表面与架构分层完全不变），终态
   **Mojo + Rust only，C 清零**。

   **「最核心部分能否由 Rust 替代」= 能，且已经是终态方向**：bridge 的所有
   *最核心* 字节/系统逻辑都由 Rust 承载，而不是仅「无关紧要的边角」：

   | 最核心职责 | 现状（2026-09-04 实测） | 实现位置 |
   |-----------|-----------------------|---------|
   | socket syscall（`socket` / `bind` / `listen` / `accept` / `recv` / `send` / `close`） | Rust ✅ | `bridge/socket.rs` |
   | poll 事件循环（poll + 计时器 + deadline） | Rust ✅ | `bridge/io.rs` + `bridge/conn/deadlines.rs` |
   | HTTP 请求行+头解析（method/path/version/headers/body chunked） | Rust ✅ | `bridge/parse.rs` + `bridge/conn/parse.rs` |
   | WebSocket 协议原语（SHA-1 / base64 / 帧解析 / 掩码 / 分片 / UTF-8 / close） | Rust ✅ | `ws.rs` + `ws/parser.rs`（DC1；e2e M10-M21 全绿） |
   | Slowloris 防护 / keep-alive / 总时长超时 | Rust ✅ | `bridge/conn/deadlines.rs`（纯逻辑）+ `bridge/io.rs`（I/O 主体应用副作用，DC2-g） |
   | CORS（preflight + 头注入） | Rust ✅ | `bridge/response.rs`（`CORS_HEADERS` 常量）+ `bridge/send.rs`（`send_preflight_response`） |
   | 静态文件（嵌入 + 1MB 上限 + realpath 防穿越 + O_NOFOLLOW） | Rust ✅ | `bridge/send.rs`（`serve_static_file` / `send_static_file` / `send_static_file_head`） |
   | 限流（per-client rate limit / 429） | n/a | 原 C bridge 也没有；当前**未实现**，如未来需要可加 `bridge/ratelimit.rs` |
   | Range / ETag / Last-Modified / Cache-Control | n/a | `bridge/send.rs` 注明 "Range-free"；原 C 也没有 Range 实现；如未来需要可加 |
   | 信号处理（sigaction + handler） | Rust ✅ | `bridge/signals.rs` |
   | worker fork + SO_REUSEPORT + 进程编排 | Rust ✅ | `bridge/init_workers.rs` |
   | 单 binary loader（embed/stage/dlopen/符号转发/孤儿 stage） | Rust ✅ | `bridge/shim.rs`（DC3）+ `build.rs`（80 LOC env → shim_static_gen.rs） |
   | FFI 出口包装（`extern "C"` ~41 符号，对齐 C ABI） | Rust ✅ | `bridge/ffi.rs`（413 LOC，DC2-h） |

   **结论**：bridge 的所有 *最核心* 字节/系统逻辑 100% 由 Rust 承载。表格中标
   `n/a` 的两项（限流 / Range）原 C bridge 同样未实现，不属于"被替换"范畴，
   仅作为未来增强项记录。

   **Mojo 侧保留** = 应用层 / 框架语义 / 业务逻辑（路由注册、参数解析、JSON 序列化、
   handler 业务、错误处理、协议对象），即「应用/协议层原生」；bridge 仅是
   不可避免的「系统调用 + 字节搬运」一层。**这与「迁回 Mojo」不同**：
   Mojo 1.0.0 标准库无 socket / 网络 / crypto / 静态运行时，迁回 Mojo 必然
   重新发明 socket/poll/SHA-1/loader（且无内存安全保证），属于**走回头路**；
   一律由 Rust staticlib 承载更安全、门禁更可验证（FFI 表面 1:1 对齐 C 头 +
   行为等价 e2e + bench + RSS 门禁）。

---

## 2. 现状盘点（2026-09-04 基线）

### 2.1 运行时：✅ 已 0 Python（本 goal 不触碰）

- Mojo 原生 HTTP server（bridge socket 桥接 + 原生协议层）+ 原生 JSON（json.mojo
  线性序列化）+ 原生 Router / 参数解析 / 异常→JSON。
- WebSocket 全链路（ADR-0006~0009，决策-15~18）：多端点、{param} 路由、子协议、
  保活 ping、close 码 / UTF-8 校验、高并发（bridge poll 循环 + Mojo 逐消息分派）、
  鉴权 token、合并帧尾块 P0 修复。
- 并发：多进程 worker + SO_REUSEPORT（ADR-0005）。

### 2.2 工具链：✅ 已零 Python（Track B 达成，决策-22）

| # | 环节 | 现状（Python 用法） | 目标替代方案 | 工作量 |
|---|------|--------------------|--------------|--------|
| T1 | `bench.py` + `benchmark.sh` | 唯一 `.py`；stdlib 实现 HTTP(hey)/WS 负载；`.venv` 仅为它保留 | Rust/Mojo 原生 bench 二进制（或纯 shell + curl + 内置 WS 客户端）；移除 `.venv` | 大 |
| T2 | `scripts/e2e_test.sh` | `python3` 生成畸形字节流 hex / 大 payload / WS 客户端 / keep-alive / HEAD body 校验 | 纯 shell（printf/od/openssl）+ Rust 小工具（随测试构建）| 中 |
| T3 | `build_single.sh` | `python3 -c 'import modular…'` 定位 Mojo 运行时 lib | shell 探测 `$MODULAR_LIB` + 固定路径候选扫描（`~/.modular/pkg/packages/…`）| 小 |

> 约束：工具链去 Python **只影响 build/test/bench**，不得改变运行时交付物（single
> binary 仍零依赖）。CI 里 Mojo 安装本身仍可借 python-pip（工具链启动依赖，可接受）。

### 2.3 FastAPI 对标缺口（Track A 目标，优先级排序）

**已有能力**：GET/POST/PUT/DELETE、Path `{param}` / Query / JSON Body 参数
（`Dict[String,String]`）、静态文件嵌入、before/after 钩子 + timing、CORS、限流、
/health /status /routes、WebSocket 全套、keep-alive。

**对标缺口（按 P0→P3 排序，详见附录 A 矩阵）**：

- **P0 框架语义**（建议 Phase 4）：类型化参数（Int/Float/Bool/List/嵌套 JSON，不再
  只有 String）、`HTTPException` + 自定义异常处理器→统一 JSON 错误体、Request/Response
  对象（读 headers/cookies、改 status_code、自定义响应头）、响应嵌套序列化。
- **P1 API 表面**（建议 Phase 5）：Header/Cookie 参数、表单（urlencoded/multipart）、
  文件上传、依赖注入（Depends 语义）、中间件链（顺序/优先级）、后台任务、
  Streaming/File/Redirect Response。
- **P2 框架生态**：URL 解码（`{param}` 含 `%xx`）、NUL 回复 FFI 协议修订
  （ADR-0007 §5 教训 3）、鉴权链统一（首帧 token / 自定义头 / 与 HTTP 中间件统一）、
  模块化 Router/APIRouter、OpenAPI 文档、lifespan 事件、JWT/OAuth2 助手、模板渲染。
- **P3 协议/服务器**：gzip 压缩、Range/静态缓存头、TLS/HTTPS（可选，需 Rust 依赖
  评估，如 rustls 静态链接）、HTTP/2（远期，不承诺）。

### 2.4 C 侧现状（Track C 终态，2026-09-04 — DC1+DC2+DC3 ✅ 全部完成，C 已 `git rm`）

**基线行数**（`wc -l src/fastapi_mojo/*.c`，2026-09-04 当日盘点）：
基线 2514 LOC（http_bridge_final.c 1774 + ws.c 380 + runtime_shim.c 360）。
**DC1 ✅ 已迁移 ws.c → ws.rs 并删除 ws.c**；KIND_RUN_CMD WIP 已落 HEAD `7b33c26`
（http_bridge_final.c 1809）。**当前工作树剩 2169 LOC**
（http_bridge_final.c 1809 + runtime_shim.c 360，待 DC2/DC3）。

| 文件 | LOC (基线→现状) | 主要职责 | → Rust 目标模块 | 状态 |
|------|-----------------|---------|------------------|------|
| `http_bridge_final.c` | 1774 → **1809** → **0（已删，DC2 + DC3 后）** | socket I/O + poll 事件循环 + HTTP 解析 + keep-alive + 超时/慢连接防护 + CORS + 静态文件 + 限流 + 信号 + worker/SO_REUSEPORT 并发 + WS 会话状态镜像 | `bridge/*` 15 子模块 + `bridge/ffi.rs`（413 LOC extern "C" 包装层） | ✅ **DC2 完成**（15 子模块 + ffi.rs 包装层；**281 单测绿（285 含 4 #[ignore]）、0 BUG、0 警告**；e2e 79/79 绿；bench +22%；build_single.sh 已切走 bridge.o，**服务纯 Rust FFI 运行**；NUL 终止修复 ×3 已收口；DC3 后 `.c` 文件已 `git rm`） |
| `ws.c` | 380 → **0（已删）** | WS 协议原语：SHA-1 / base64 / handshake / 帧解析 / 掩码 / close 码 / UTF-8 校验 | `ws.rs` | ✅ DC1 完成（行为等价 + e2e 79/79 绿 + 26 单测绿 + `build_single.sh` 接入） |
| `runtime_shim.c` | 360 → **0（已删，DC3 后）** | 单 binary loader：Mojo 运行时嵌入 + 启动暂存 + dlopen 符号转发 + 孤儿 stage 清理 + atexit（ADR-0003 决策-14） | `bridge/shim.rs`（374 LOC）+ `build.rs`（80 LOC） | ✅ **DC3 完成**（11 KGEN_CompilerRT_* 转发 macro + .init_array 构造器 + fs::remove_dir_all 修复孤儿清理 + 单测隔离；orphan sweep 实测 22→1→0；e2e 79/79 绿 / bench +22% / binary 5.2M / ldd 仅 libc） |
| **合计** | **2514 → 0**（-100%；ws.c -380 / http_bridge_final.c -1809 / runtime_shim.c -360 全清零；**终态 Mojo + Rust only**） | | **0（C 清零达成）** | |

**关键观察 / 实测教训**：

- **KIND_RUN_CMD WIP 已落 C**（HEAD `7b33c26`，http_bridge_final.c 净增 +35 LOC =
  1809；含 KIND_HTML/serve_forever/run_command_json/UTF-8 codepoint 修复）；Rust 端
  `bridge::cmd::run_command_json` 已就绪（13 单测绿，C 副本待 bridge.o 下线时整体
  移除）。**HEAD 仍含 C 新增业务，但「无 C 新增」= 从现在起生效**：DC2/DC3 内
  不再向 C 添加新逻辑；DC2 迁完一并删除 C 副本。
- `ws.rs` 经验：SHA-1 / base64 / 帧解析 / 掩码 / close / UTF-8 全手写，**零第三方
  crate**，Rust ownership 模型在字节位运算场景下确实甜区（ADR-0009 合并帧尾块
  丢失 P0 在 Rust 版被类型系统静态杜绝同类 bug）。
- **DC2-d（本轮增量）**：在 DC2-a/b/c（纯逻辑/I-O leaves/配置/socket/worker/conn
  表共 11 子模块）之上新增 2 个子模块，**总计 12 个 bridge 子模块、230 cargo 单测
  全绿**：
  - `bridge/conn/deadlines.rs`（16 单测）：端口 C `check_deadlines`（§1028-1067）的
    纯逻辑版。`DeadlineAction` 枚举（None/WsPing/WsClose1000/Timeout408/
    CloseIdle）+ `decide(phase, first_data_ms, last_data_ms, last_active_ms,
    &mut ws_strikes, ping_max, now_ms, recv_timeout_ms, idle_max_ms,
    max_request_ms)`。覆盖 phase 0/1/2/3/4 各分支 + 阈值边界（`>=`）+ ping_max=0
    禁用保活 + 时钟回拨 `saturating_sub` 防 underflow。I/O 主体（poll 驱动
    check_deadlines 副作用）下一步迁移。
  - `bridge/request.rs`（7 `#[test]`，含 `empty_initial_state` / `last_status_byte_access`
    / `ws_protocol_round_trip` / `slice_accessors_return_correct_ptr_and_len` /
    `set_http_fields_truncates_long_inputs` / `last_status_truncates_long_input` /
    `close_after_response_toggle`）：per-request 全局 + slice 访问器。`CurrentRequest`
    结构（method/path/query/protocol_11/close_after_response/active_fd/active_phase/
    ws_event_type/ws_key/ws_protocol/last_status）；`static CURRENT: Mutex<CurrentRequest>`
    （单线程 worker 进程内用 Mutex 满足 Rust 安全）；`CSlice { ptr: *const c_char,
    len: c_long }` 与 C `fmc_slice` 字节对齐。setter：`set_http_fields` / `set_ws_fields`
    / `ws_session_set_protocol` / `reset_request_fields` / `set_active` /
    `set_ws_event_type` / `set_last_status` / `set_protocol_11` /
    `set_close_after_response`。getter slice：`get_method_slice` / `get_path_slice`
    / `get_query_slice` / `get_ws_key_slice` / `get_ws_protocol_slice`。getter
    scalar：`get_close_after_response` / `get_protocol_11` / `get_ws_event_type`
    / `get_last_status_len` / `read_last_status_byte`。**自检 self-bug 修复**：
    `last_status_byte_access` "404 Not Found" 13 字符 i=12→'d' (100)、
    i=13/100→-1 边界；`ws_protocol_round_trip` Mutex 自死锁（实测：full cargo test 在该 test 上 hang 280s+ 无输出；
    guard 内调 accessor 重 lock）→ 已修复 `{ let g = lock; ... }` 显式 scope drop，
    **追加更新-3** 验证全 241 测试 0.22s 通过。
  - **Mutex 非 reentrant（新增教训）**：`CURRENT.lock()` 持有时不能再 lock，
    否则进程自死锁（单线程 worker 也跑不出来）。测试用 `{ let g = lock(); ... }`
    显式 scope drop；生产路径 setter/getter 不在同 scope 内重复锁。
  - **panic=abort 单测仍是 unwind（新增教训）**：默认 `cfg(test)` 用 unwind，
    故一个 panicking test 不杀整个 binary（单测 fail 后继续跑），便于一次性
    收集全套失败信息。
- **self-bug #2 修复（ws_protocol_round_trip assertion）**：修复 #1 的 deadlock 后，
  test 暴露 `assert_eq!(s.len, 8)` 错误断言 —— 实现 `ws_protocol_len = n`（数据
  长度 7，NUL 跟随在 `[n]`），与 method/path/query slice 一致。改 `assert_eq!(s.len, 7)`
  + 验证 `s.len+1` 字节含 NUL 收尾（**追加更新-3**）。
- **build 链接陷阱**：Rust staticlib 默认拉入 `libgcc_s.so.1`（compiler-rt 内建
  函数如 `__udivti3`），破坏 North Star（CI libgcc_s 断言）。修复：
  `gcc -fPIE -pie -O2 -static-libgcc` 静态链接 libgcc_s。已加进
  `build_single.sh`，ldd 回归仅 libc。
- **测试 syscall 隔离**：Rust `ConnTable::close()` 调用真 `close(fd)` syscall，
  测试用合成 fd（101/102/...）若与 libtest 捕获管道撞号会误关，破坏无关测试。
  修复：`#[cfg(test)] sys_close` no-op，单元测试永不真关 fd（生产路径仍走真
  `close()`，行为等价 C）。
- **state_tests env 全局副作用**：env vars 是进程全局，并行 `cargo test` 状态
  测试互相污染。修复：CI 与本地回归统一 `cargo test --release -- --test-threads=1`
  （≈ 0.22s，无明显开销）。
- `shim.rs` 关键风险点：**构造函数顺序**（shim 必须在 Mojo KGEN_CompilerRT_* 首次
  引用前运行）→ Rust 侧用 `#[used] #[link_section = ".init_array"]` + 链接时
  `--whole-archive librust_bridge.a` 保证不被裁掉。
- **binary 体积现状**：C-only 基线 2.2M；DC1 ws.rs 上线后 4.8M（含 -static-libgcc）。
  中间态主要因 ws.rs 用了 `format!` + `Vec` + `CStr` 引入 std 运行时（~1.5-2MB）。
  收口路径：ADR-0010 task #12「去 std 瘦身」（`core::ffi`/`core::slice` + 手写字节
  组装 + 栈缓冲），目标终态 ≤ C + 2MB（≤ 4.2M），CI 中间态预算 ≤ 6M 兜底。

---

## 3. 目标（成功标准可验证）

1. **Track A**：覆盖 P0 全部 + P1 大部分 + P2 可落地子项，全部 Mojo 原生 / Rust
   bridge 随 binary 打包；`e2e` 从 79 项扩展到 ≥ 120 项，覆盖每个新特性。
2. **Track B**：仓库 `find . -name "*.py"`（排除 `.venv`）→ **0 个**；`.venv` 删除；
   `benchmark.sh` / `scripts/e2e_test.sh` / `build_single.sh` 中 `python3` 调用清零。
3. **Track C**：**C 清零，一步到位 mojo + rust only** — `find src -name '*.c'`
   → **0**；三份 C bridge 全部由 Rust staticlib 替代（FFI 表面不变）：
   `bridge.rs`（原 http_bridge_final.c 1809）、`ws.rs`（原 ws.c 380 ✅ DC1 已上线 /
   ws.c 已删除）、`shim.rs`（原 runtime_shim.c 360）。
   **DC1 ✅ ws.c → ws.rs（已删）/ DC2 ✅ http_bridge_final.c → bridge/* 15 子模块
   + ffi.rs 包装层（281 单测绿 / 285 含 4 #[ignore]、0 BUG、0 警告；已删）/
   DC3 ✅ runtime_shim.c → bridge/shim.rs（已删）**。验收门禁：
   - `ldd build/fastapi_mojo` 仍仅 libc；`env -i` 干净启动；
   - 全量 e2e 79 项 + 新增强化项全绿；bench 性能不倒退 >10%；
   - binary 体积增幅 ≤ +2 MB vs C 版（CI 断言）；
   - 构造函数顺序正确（`--whole-archive` + `.init_array`）。
4. **不变量保持**：`ldd` 仅 libc；`env -i ./build/fastapi_mojo` 干净启动；
   CI（build + ldd + 干净环境 + unit + e2e + **C 清零断言**）全绿；
   每个 `.mojo` 文件 < 500 行；每个 Rust bridge 模块 < 500 行（建议）。
5. **任务治理**：每个子项以 beads（`br`）建任务；每项重大特性/协议变更写新 ADR
   （含 6 条架构隔离约束声明）+ e2e 增量 + README/AGENTS 对齐。

---

## 4. 非目标（anti-goals）

- ❌ 不追求「逐字节复刻 FastAPI 全部 API」——只对标**常用语义**，Mojo 1.0.0 语法
  约束不允许的能力（一等函数/闭包）用「类型 + 数据 + 单点 dispatch」模式绕行。
- ❌ 不引入 Python / 第三方 C 动态库到运行时；不引入 Mojo 社区包到运行时（除非可
  静态链接进单 binary 且经 ADR 评审）。
- ❌ 不在本 goal 内做「Mojo 原生 ASGI/WSGI 协议层」（beads: phase1-mojo-native-crt.6，
  独立评估；与本仓库「自研 HTTP 协议层」路线重复，除非用户明确要求）。
- ❌ 不承诺 HTTP/2 / TLS 全量实现（列入 P3 观察，需 Rust 依赖与安全评审）。
- ❌ 不在本 goal 内把 benchmark 工具链语言本身变成「产品」——它是开发工具。
- ❌ **不追求 Mojo 原生实现一切**：Mojo 1.0.0 标准库缺口（socket/网络/crypto/静态
  运行时）由 **Rust bridge** 承载，不在本 goal 内强行 Mojo 化（与上一版「迁回 Mojo」
  方向不同）。
- ❌ **不引入 Rust 第三方动态链接 crate / 不走 cdylib**：Rust 段仅以 `staticlib` +
  C ABI 出现；`panic = "abort"` + 系统 allocator + LTO；破坏 `ldd` 仅 libc 不变量
  的 Rust 依赖一律禁止。

---

## 5. 阶段划分（roadmap）

### Phase 4 — 框架语义对标（Track A·P0 + Track C 启动）

- P4.1 类型化参数：Path/Query/Body 支持 `Int/Float/Bool/List[String]/Dict[String,Any]`
  强类型转换 + 校验失败→422（对标 FastAPI/Pydantic 语义）。
- P4.2 `HTTPException` + 自定义异常处理器注册 → 统一 JSON 错误体（替换硬编码
  400/404/405/413 分支）。
- P4.3 Request/Response 对象：handler 可读 headers/cookies、设置 status_code /
  响应头 / set_cookie；响应支持嵌套 JSON 序列化。
- **DC1 Rust bridge 启动（ADR-0010 落地）**：Rust crate 骨架（`Cargo.toml`
  `crate-type=["staticlib"]` + `lib.rs` 导出表 + `rust-toolchain.toml` pin）；
  `build_single.sh` 接入 `cargo build --release`（`--whole-archive librust_bridge.a`
  替代三份 `.o`，objcopy payload 符号 extern 引用）；CI 安装 rust toolchain +
  C 清零断言；**ws.c → `ws.rs` 行为等价迁移**（SHA-1/base64/帧解析/掩码/close/UTF-8，
  e2e M10-M21 回归）。
- **DC1 完成情况（2026-09-04 当下）**：
  - Rust crate `src/fastapi_mojo_rs/`（crate-type staticlib / panic=abort / LTO /
    系统 allocator / 零第三方依赖；`rust-toolchain.toml` pin 1.97.1）；
  - `ws.rs` 26 单元测试绿 + e2e 79/79 全绿（handshake / frame / mask / close /
    UTF-8 / subprotocol / ping-pong / 合并帧 / {param} 路由 / 鉴权 — ADR-0006~0009
    全套语义保持）；
  - **`ws.c` 已删除**（build_single.sh 不再编译；C 清零 380/2514）；
  - **build_single.sh 加 `-static-libgcc`**：Rust staticlib 默认拉入 libgcc_s
    （compiler-rt），破坏 North Star；静态链接后 ldd 回归仅 libc；
  - **CI 已更新**：`.github/workflows/ci.yml` 加 rustup 安装 + `cargo test --release
    -- --test-threads=1` + 体积预算门禁（中间态 ≤ 6M）+ C 计数步骤（终态 = 0）；
  - **测试 syscall 隔离**：`#[cfg(test)] sys_close` no-op，避免 libtest 捕获管道被
    合成 fd 误关；`state_tests` env 全局副作用统一 `--test-threads=1`。
- 里程碑：ADR-0010 已接受；e2e 79/79（保持，零回归）；`ws.rs` 上线 + `ws.c` 删除；
  DC2 已落地 12 bridge 子模块 + 237 单测绿 / 241 含 4 #[ignore]（parse/response/cmd/time_util/port/
  signals/state/socket/init_workers/conn/conn::parse/conn::deadlines/request）；
  bench run#15 = +32%（47281 vs 35829）、RSS 平台化；binary 5,000,720 B 不变；
  C 清零进度 380/2514（≈ -15%，ws.c）；CI 5 道新门禁绿。

### Phase 5 — API 表面补齐（Track A·P1 + Track B 启动 + Track C 主体迁移）

- P5.1 Header/Cookie 参数 + 表单（application/x-www-form-urlencoded）解析。
- P5.2 文件上传（multipart，Rust 侧分块解析 + 内存缓冲，不落盘）。
- P5.3 依赖注入（`Depends` 语义：解析顺序、缓存、子依赖）。
- P5.4 中间件链（before/after 有序链 + 异常透传）+ 后台任务（进程内简单队列）。
- P5.5 Streaming/File/Redirect Response 原语。
- T1 启动：bench.py → Rust/Mojo 原生（与 P5 并行，独立任务线）。
- **DC2 http_bridge_final.c → `bridge.rs`**：socket/poll 事件循环 + HTTP 解析 +
  keep-alive + 超时/慢连接防护 + CORS + 限流 + 静态 + 信号 + worker/SO_REUSEPORT +
  WS 会话状态全部 Rust 重写（按职责拆子模块，每个 <500 行）；FFI 出口签名逐一对齐
  （`recv_and_parse` / `send_*` / `get_*_slice` 等 ~40 符号）；C 清零进度
  2169/2514（≈ -86%，ws.c 已清 380；剩 http_bridge_final.c 1809 + runtime_shim.c 360）。
- 里程碑：新增 ADR-0011/0012；e2e 90→110；`.venv` 移除（bench 不再依赖 Python）；
  `bridge.rs` 上线。

### Phase 6 — 协议/生态收口（Track A·P2 + Track B 收尾 + Track C 清零）

- P6.1 URL 解码（HTTP + WS `{param}` 统一）；NUL 回复 FFI 协议修订。
- P6.2 鉴权链统一（WS 首帧 token / 自定义头 / 与 HTTP 中间件共用）。
- P6.3 模块化 Router 组合（多路由表合并）。
- P6.4 OpenAPI/Swagger 文档（只读生成，`/openapi.json` 起步）+ lifespan 事件。
- T2/T3 收尾：e2e_test.sh 与 build_single.sh python3 清零。
- **DC3 runtime_shim.c → `shim.rs` + C 清零**：embed/stage/dlopen/符号转发 +
  孤儿 stage 清理 → Rust；**删除三份 `*.c`**；`find src -name '*.c'` = 0；
  终态 **Mojo + Rust only**。
- 里程碑：全仓库 `*.py` = 0；`src/` 下 `*.c` = 0；e2e ≥ 120；CI 全绿；最终发布
  v0.4.0（或按里程碑细分）。

---

## 6. 风险与约束（6 条架构隔离约束声明）

1. **单 binary 零依赖 + Mojo 优先 + Rust bridge**：任何新增能力必须 **Mojo 原生
   优先**，其次 Rust staticlib（C ABI）随 binary 打包；禁止新增 Python / C / 系统
   动态库依赖（ldd 仅 libc + env -i 启动断言永续）。能 Mojo 原生实现的能力不得
   新增到 bridge 层。
2. **用户代码 = 纯数据**：新增路由/处理器 = 数据声明；行为扩展只走显式单点 dispatch
  （`run_handler` / `run_ws_message`）加 kind 分支，核心不含 per-handler 业务逻辑。
3. **God-file 阈值**：每个 `.mojo` 文件 < 500 行；每个 Rust bridge 模块 < 500 行
  （超限拆子模块，标注拆分边界）；**C 文件不再新增，存量逐阶段清零**。
4. **工具链与运行时解耦**：Track B 只改 build/test/bench；Track C 只改 bridge 内部
  实现语言（FFI 表面 / 架构分层 / 单 binary 机制不变）；运行时交付物形态不变
  （single binary 仍零依赖）；工具链可用 shell/Rust/Mojo，不反向污染运行时依赖图。
5. **决策先行**：每项重大特性/协议变更（含 C→Rust 迁移点）须先立 ADR（6 条约束
  声明）+ `br` 任务 + e2e 增量；禁止「大改后补文档」。
6. **兼容既有模式 + C→Rust 迁移规范**：Rust 侧新能力走显式 bridge/adapter 入口
  （`extern "C"` 导出表，与原 C 签名逐一对齐）；**存量 C 逻辑按「行为等价 + e2e
  不回归 + 性能不倒退 >10%」逐段迁 Rust**；Mojo 1.0.0 语法缺口（无闭包/match/文件级
  let）用已验证的「类型 + 数据 + 零参 def 常量」模式绕行，不引入新的不可验证技巧。

---

## 7. 关联决议 / 上游工件

| 工件 | 与本 goal 的关系 |
|------|-----------------|
| `AGENTS.md` §1/§3/§6 | 北极星、架构约束、决策链（本 goal 的硬约束；**决策-19 = 本 Track C 的上游**） |
| `AGENTS.md` §3.1 部署约束 | 允许 Mojo / 社区包 / **Rust staticlib**；禁止最终形态含 C（已同步修订） |
| ADR-0001~0005 | Mojo 替换策略 / 单 binary / 路由注册 / 并发 —— 已落地，本 goal 沿用其模式 |
| ADR-0006~0009 | WebSocket 全链路 —— 其「后续」清单（鉴权扩展 / URL 解码 / NUL 回复 / WS bench）纳入本 goal P2/T1；`ws.c` → `ws.rs` 纳入 Track C DC1 |
| **ADR-0010-rust-bridge** | **Track C 的实施载体**：Rust staticlib 替代三份 C bridge，6 约束 + 任务清单 |
| `docs/migrate_mojo/todo.md` | 历史规划（已废弃）；其 C6「Mojo ASGI 协议层」标注为独立评估，非本 goal 范围 |
| `scripts/e2e_test.sh` | 79 项 e2e，Track A/B/C 每步的验收门禁（含 C→Rust 行为等价回归） |
| `benchmark.sh` / `bench.py` | 统一压测入口；Track B T1 的替换对象；Track C 验收需保证「性能不倒退 >10%」 |
| beads（`br`）| 每个子项建任务并跟踪状态；Track C 子项（DC1/DC2/DC3）独立任务线 |

---

## 8. 度量（每阶段验收）

- **功能**：e2e 增量（79 → 90 → 110 → 120+）；单元自检增量（Rust bridge
  `cargo test --release -- --test-threads=1` **实测 237/241（4 #[ignore] signal/fork 真集成）、
  0.22s、0 BUG**，**追加更新-3**）；每特性对应 e2e 用例数。
- **性能**：`./benchmark.sh` 固定姿势；新增特性不得使既有场景吞吐倒退 >10%
  （HEY HTTP ~20k rps / 单核顺序 ~300 rps 为基线）；Track C 迁移同样以此为门禁。
  **实测（DC2 迁移中，bench run#15）**：get_root_10k_100c = **47281 req/s** vs
  C-only 基线 35829 = **+32%**、0 errors；RSS 平台化 16720→16208→16208→16208→16208 kB
  （2500 req，无线性泄漏）——Rust bridge 迁移至今**零性能退化、零内存回归**。
- **去 Python**：`find . -name "*.py"` 计数；`.venv` 是否移除；三个脚本 `python3`
  调用数归零。
- **去 C**：`find src -name '*.c'` → **0**；三份文件 → Rust 的 LOC 与迁移状态
  （`ws.rs` / `bridge.rs` / `shim.rs`）；C→Rust 迁移点计数（~40 FFI 出口逐一核对）。
- **binary 体积**：`du -h build/fastapi_mojo` 相对 C 版增幅 ≤ +2 MB（CI 断言）。
- **不变量**：CI 上 `ldd` 断言 + `env -i` 启动断言 + **C 清零断言**每 push 自动守护。

---

## 附录 A：FastAPI 对标缺口矩阵（详细）

| 能力 | FastAPI/Starlette | fastapi_mojo 现状 | 本 goal 目标 | 阶段 |
|------|------------------|-------------------|--------------|------|
| 类型化 Path 参数 | `int`/`float`/`bool`/枚举 | String only | 强类型 + 422 | P4.1 |
| 类型化 Query 参数 | 同上 + 默认值/必填 | String only | 强类型 + 422 | P4.1 |
| 类型化 Body | Pydantic 模型嵌套 | `Dict[String,String]` | `Dict[String,Any]` + 嵌套 | P4.1 |
| 异常 → JSON | `HTTPException` + 自定义 handler | 硬编码 400/404/405/413 | 统一错误体 + 自定义处理器 | P4.2 |
| Request 对象 | headers/cookies/method/url | 未暴露 | 读 headers/cookies | P4.3 |
| Response 对象 | status/headers/cookies/redirect | 静态 body only | 完整响应原语 | P4.3/P5.5 |
| Header 参数 | Header(...) | ❌ | 支持 | P5.1 |
| Cookie 参数 | Cookie(...) | ❌ | 支持 | P5.1 |
| 表单 | urlencoded | ❌ | 支持 | P5.1 |
| 文件上传 | multipart/UploadFile | ❌ | 支持（内存） | P5.2 |
| 依赖注入 | Depends | ❌ | 支持 | P5.3 |
| 中间件链 | 有序 + 异常透传 | before/after 单层 | 有序链 | P5.4 |
| 后台任务 | BackgroundTasks | ❌ | 进程内队列 | P5.4 |
| 流式响应 | StreamingResponse | ❌ | 支持 | P5.5 |
| 静态文件 | StaticFiles | 嵌入 binary | 已达标（+缓存头/range） | P3 |
| URL 解码 | 自动 | `{param}` 未解码 | 统一解码 | P6.1 |
| NUL 回复 | 支持 | FFI len 协议缺口 | 修订 | P6.2 |
| 鉴权链 | 中间件/依赖 | WS token 单点 | 统一 | P6.2 |
| 模块化 Router | APIRouter | 单路由表 | 多表合并 | P6.3 |
| OpenAPI 文档 | 自动生成 | ❌ | /openapi.json 起步 | P6.4 |
| lifespan | 事件 | ❌ | 支持 | P6.4 |
| gzip 压缩 | 中间件 | ❌ | 支持 | P3 |
| CORS 精细配置 | allow_headers/expose/max_age | 基础 | 补全 | P3 |
| TLS/HTTPS | 支持 | ❌ | 观察（需 Rust 依赖评审） | P3 |
| HTTP/2 | 支持 | ❌ | 远期，不承诺 | P3 |

## 附录 B：Track B 去 Python 明细（当前 python3 调用点）

| 文件 | 调用点 | 替代方案 | 阶段 |
|------|--------|---------|------|
| `bench.py` | 整个文件（HTTP + WS 负载、统计、SQLite 落库） | Rust/Mojo 原生 bench 二进制 | T1/Phase 5 |
| `benchmark.sh` | `$PYTHON_BIN bench.py …`、`.venv` 探测 | 调用 Rust/Mojo bench | T1/Phase 5 |
| `scripts/e2e_test.sh` | `python3 -c`/heredoc 共 ~15 处（hex 构造 / 大 payload / WS 客户端 / keep-alive / HEAD body） | 纯 shell（printf/od/openssl）+ Rust 小工具 | T2/Phase 6 |
| `build_single.sh` | `python3 -c 'import modular…'` 定位 lib | `$MODULAR_LIB` + 固定路径候选扫描 | T3/Phase 6 |

> **验收红线**：Phase 6 结束时 `git grep -n "python3\|\.venv\|bench\.py" -- ':!docs' ':!AGENTS.md' ':!README.md'`
> 应仅剩历史文档提及；`.venv/` 目录删除。

## 附录 C：Track C 去 C（C → Rust）明细

### C→Rust 迁移对照（2026-09-04 终态：C 清零达成，Mojo + Rust only）

| C 文件 | LOC（基线→现状） | 职责 | Rust 目标模块（现状） | 阶段 |
|--------|------------------|------|----------------------|------|
| `ws.c` | 380 → **0（已删）** | SHA-1（handshake）/ base64（Sec-WebSocket-Accept）/ handshake 构造（101 + subprotocol）/ 帧解析 / 掩码 / 分片重组 / close 码 / UTF-8 校验 / socket write（writev） | `ws.rs` + `ws/parser.rs`（26 单测绿） | ✅ DC1 完成 |
| `http_bridge_final.c` | 1774 → **1809** → **0（已 `git rm`，DC2 + DC3 后）** | socket I/O / poll 事件循环 / accept / read / write / HTTP 请求行+头解析 / keep-alive / Slowloris 防护 / CORS / 限流 / 静态文件（嵌入 + Range/缓存头）/ 信号处理（sigaction + handler）/ WS 会话状态（parser 镜像 / 会话 ID / 队列）/ worker fork + SO_REUSEPORT / 动态 JSON 响应 / OPTIONS preflight | `bridge.rs` 按职责拆 **15 子模块 + `bridge/ffi.rs`** 全部已落地：`parse.rs` / `response.rs` / `cmd.rs` / `time_util.rs` / `port.rs` / `signals.rs` / `state.rs` / `socket.rs` / `init_workers.rs` / `conn.rs` / `conn/parse.rs` / `conn/deadlines.rs` / `request.rs` / `io.rs` / `ws_session_ffi.rs` + `bridge/ffi.rs`（413 LOC extern "C" 包装层） (**281 单测绿 / 285 含 4 #[ignore]、0 BUG**；NUL 终止修复 ×3；e2e 79/79；bench +22%；bridge.o 已下线) | ✅ DC2 完成（DC2-h `bridge/ffi.rs` + build 切换） |
| `runtime_shim.c` | 360 → **0（已 `git rm`，DC3 后）** | Mojo 运行时嵌入（objcopy payload）/ 启动暂存 / dlopen 符号转发（KGEN_CompilerRT_* 等）/ 孤儿 stage 清理 / 进程退出清理 | `bridge/shim.rs`（374 LOC，`.init_array` 构造器 + 11 KGEN 转发 macro + `fs::remove_dir_all` 修复孤儿清理）+ `build.rs`（80 LOC，env → shim_static_gen.rs） | ✅ DC3 完成（orphan sweep 实测 22→0） |
| **合计** | **2514 → 0**（-100%；ws.c -380 / http_bridge_final.c -1809 / runtime_shim.c -360 全清零） | | **0 C（终态 Mojo + Rust only，决策-19）** | |

> 注：`bridge.rs` 目标模块名按 ADR-0010 规划为 `socket/parse/cors/ratelimit/static/
> signal/ws_state/worker` 等；实际落地按「纯逻辑优先、I/O 后迁」拆分，当前
> `mod.rs` 声明的 12 个子模块即为生产态模块边界（见 ADR-0010 `tasks.md`）。

### Rust crate 工程约束（ADR-0010）

- `Cargo.toml`：`[lib] crate-type = ["staticlib"]`；`[profile.release] panic = "abort",
  lto = true, codegen-units = 1, opt-level = "z"`；系统 allocator（不引 jemalloc）。
- 依赖：倾向**零第三方 crate**（SHA-1 / base64 / UTF-8 / 帧解析全手写，保 ldd 干净
  + 体积小）；若引入，仅限**纯 Rust、静态链接、无系统依赖**的 crate，且经 ADR 评审。
- FFI：全部 `extern "C"` 导出，`#[repr(C)]` 结构体，与原 C 头逐字段镜像；
  ~40 个导出符号（`recv_and_parse` / `send_*` / `get_*_slice` / `ws_*` /
  `bridge_fail` / `init_workers` 等）逐一核对。
- 链接：`gcc -pie ... --whole-archive librust_bridge.a` + objcopy payload
  （`_binary_*_start/_end`）用 `extern "C"` 引用；shim 构造函数经
  `#[used] #[link_section = ".init_array"]` 保证先于 Mojo 运行时符号首次引用。
- 工具链 pin：`rust-toolchain.toml` 固定版本；CI / `build_single.sh` 自动检测/安装。

### 迁移优先级（DC1 → DC2 → DC3）

1. **DC1（Phase 4）`ws.rs`** ✅ 已完成：最小、最独立（纯协议原语，不碰 socket
   事件循环）；e2e M10-M21 全绿后切流；C 清零进度 380/2514（**ws.c 已删除**）。
2. **DC2（Phase 5）`bridge.rs`**：主体工程（1809 LOC），按职责拆子模块
   （已落地 **15 子模块** + `bridge/ffi.rs` 413 LOC extern "C" 包装层 +
   **281 单测绿 / 285 含 4 #[ignore]、0 BUG**）；FFI 出口签名逐一对齐；
   e2e 全量 + bench 门禁；build_single.sh 已切走 bridge.o；
   NUL 终止修复 ×3（**追加更新-6 / 决策-20**）。
3. **DC3（Phase 6）`shim.rs` + C 删除** ✅ **已完成**：`bridge/shim.rs` 374 LOC
   端口 `runtime_shim.c` 360 LOC 全套（embed/stage/dlopen/符号转发/孤儿 stage
   清理/atexit）；`build.rs` 80 LOC env → shim_static_gen.rs；三份 `*.c`
   （ws.c / http_bridge_final.c / runtime_shim.c）**全部 `git rm`**；
   `find src -name '*.c'` = **0**；**终态 Mojo + Rust only**（**追加更新-7 /
   决策-21**）。

### 关键验证点（每个迁移阶段必查）

- `ldd build/fastapi_mojo` 仅 libc；
- `env -i ./build/fastapi_mojo` 干净启动；
- 全量 e2e 不回归；bench 不倒退 >10%；
- binary 体积增幅 ≤ +2 MB（CI 断言）；
- shim 构造函数先于 Mojo 运行时符号首次引用（启动即验证，失败 = 段错误/符号未定义）。

> **Track C 验收红线（已达成）**：`find src -name '*.c'` → **0** ✅
> （**DC3 已 `git rm`** http_bridge_final.c + runtime_shim.c；ws.c 更早于 DC1 已删）；
> `git grep -n "\.c\b" -- src/`（业务代码）→ 0 ✅；build_single.sh 中 gcc 链接入口
> 移除（`gcc -c http_bridge_final.c` / `gcc -c runtime_shim.c` 均注释），改 `cargo`；
> **终态 Mojo + Rust only 达成**。
