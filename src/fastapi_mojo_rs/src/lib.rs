//! fastapi_mojo_rs — Rust bridge for fastapi_mojo single binary
//!
//! 终态: **Mojo + Rust only** (ADR-0010, AGENTS.md 决策-19).
//! 本 crate 替代 `src/fastapi_mojo/{http_bridge_final,ws,runtime_shim}.c`,
//! 以 `staticlib` + C ABI 形态被 `build_single.sh` 链接进 single binary。
//!
//! FFI 表 (与历史 C bridge 逐符号对齐, ~40 个 extern "C" 入口):
//!   - DC1 已就绪 (`ws` 模块): ws_parser_init, ws_parser_feed, ws_handshake,
//!     ws_write_message, ws_validate_utf8, ws_reply_close_buf
//!   - DC2 已落地 (桥头纯逻辑, 见 `bridge/` 子模块): find_header_end /
//!     bounded_strstr / utf8_valid / has_header_name_ci / get_header_value_ci
//!     / connection_directive / expect_100_continue / get_content_type /
//!     json_escape / build_response_headers / build_preflight_response /
//!     run_command_json。**FFI 包装 (`#[no_mangle] extern "C"` 入口, 与 C
//!     bridge.o 同名符号)** 在 `bridge.o` -> `librust_bridge.a` 切换时统一
//!     加上 (避免当前 --whole-archive 同时链接 C 与 Rust 时的同名冲突)。
//!   - DC3 待开工: shim 模块 (loader/embed/dlopen/...)

#![allow(clippy::missing_safety_doc)]
#![allow(non_camel_case_types)]

// FFI glue: 本 crate 的 `pub` 函数绝大多数是 `#[no_mangle] extern "C"` 导出
// (与原 C bridge 同名符号对齐, ~40 个), 它们的指针参数由 Mojo C ABI 调用契约
// 保证有效 (与原 C bridge 行为字节等价). 在 lib 根部 allow 该 lint 而非逐函数
// 标记 `unsafe`, 以避免 50+ 个 Rust 单测调用点都需要 `unsafe { }` 包装 ——
// 这不会带来任何额外的安全保证 (解引用已经在函数体内, unsafe block 只是语法).
// Rust 调用方不存在 (这些符号是 C ABI 边界, 仅供 Mojo 用); 契约保证是设计层面的.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod bridge;
pub mod ws;

// 重新导出 FFI 入口符号 (staticlib 链接时以符号名解析, 这里仅作 Rust 侧引用)
pub use ws::{
    ws_handshake, ws_parser_feed, ws_parser_init, ws_reply_close_buf,
    ws_validate_utf8, ws_write_message, WsParser, WS_MAX_MSG,
};
