//! bridge/mod.rs — pure-Rust HTTP bridge helpers (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` (1809 LOC) 的**纯逻辑 + 自包含**
//! 模块。I/O 心跳 (recv/parse outer state machine, poll loop, workers,
//! socket create, signal setup, WS conn-state coupling) 在 C 侧保留, 等
//! I/O 阶段 (DC2 phase 2) 整体迁移; FFI 包装层 (`#[no_mangle] extern "C"`)
//! 在切换 `bridge.o` -> `librust_bridge.a` 时再加 (避免当前
//! `--whole-archive` 同时链接 C 与 Rust 时的同名符号冲突)。
//!
//! 子模块:
//!   - parse        : HTTP 头部工具 (find_header_end, header value 提取,
//!                    UTF-8 校验, Connection/Expect 指令识别) — 端口 §511-665
//!   - response     : 响应头构建 (Content-Type 表、响应头装配、CORS 头、
//!                    preflight 响应、JSON 转义) — 端口 §1385-1525
//!   - cmd          : `run_command_json` — sh -c 包装 + 超时 + 输出封顶 +
//!                    JSON 化; 端口 §1600-1775 (含 KIND_RUN_CMD WIP)
//!   - time_util    : `now_ms` (墙钟毫秒) — 端口 §230-233 gettimeofday_ms;
//!                    供 cmd / port / signals / 未来 conn 共享
//!   - port         : `get_configured_port` (env + /proc/self/cmdline 解析,
//!                    --port N / --port=N) — 端口 §306-348
//!   - signals      : `setup_signal_handlers` (SIGINT/SIGTERM -> G_RUNNING=0,
//!                    SIGPIPE -> SIG_IGN) + `is_running` / `server_shutdown` —
//!                    端口 §184-202
//!
//! 设计守则:
//!   - 零第三方 crate; 系统调用用 extern "C" 直连; SHA-1/base64/UTF-8/poll/
//!     sigaction 手写或 libc-stable 约定 (SIG_IGN=1).
//!   - 纯函数 / 模块原子优先 (AtomicI32 + AtomicBool); 避免 raw 全局.
//!   - 与 C 行为字节等价 (header 解析顺序、JSON 字段顺序、错误码 JSON).
//!   - 每个子模块随附 `_tests.rs` 同目录; 真信号测试 `#[ignore]`, 需
//!     `cargo test --release -- --ignored --test-threads=1` 单独跑.

pub mod cmd;
pub mod ffi;
pub mod conn;
pub mod init_workers;
pub mod io;
pub mod parse;
pub mod request;
pub mod port;
pub mod response;
pub mod shim;
pub mod send;
pub mod signals;
pub mod socket;
pub mod ws_session_ffi;
pub mod state;
pub mod time_util;

#[cfg(test)]
mod cmd_tests;

#[cfg(test)]
mod conn_tests;

#[cfg(test)]
mod init_workers_tests;

#[cfg(test)]
mod io_tests;

#[cfg(test)]
mod parse_tests;

#[cfg(test)]
mod port_tests;

#[cfg(test)]
mod response_tests;

#[cfg(test)]
mod send_tests;

#[cfg(test)]
mod signals_tests;

#[cfg(test)]
mod socket_tests;

#[cfg(test)]
mod ws_session_ffi_tests;

#[cfg(test)]
mod state_tests;
