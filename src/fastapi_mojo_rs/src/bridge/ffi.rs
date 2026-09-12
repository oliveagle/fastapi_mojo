//! bridge/ffi.rs — extern "C" FFI 包装层 (ADR-0010 §3 决策-4).
//!
//! 把所有 bridge 子模块的纯逻辑 API 包成 `#[no_mangle] pub extern "C" fn`,
//! 对齐 `http_bridge_final.c` ABI (FMC slice / long / int / void).
//!
//! 调用方 (Mojo 0.25 / `external_call[...]`) 完全不变; build 切换时
//! 直接删除 `bridge.o`, 让 `librust_bridge.a` 走 `--whole-archive` 提供
//! 同名符号即可无缝替换 C 实现.
//!
//! 类型映射 (对齐 C -> Rust ABI):
//!   - C `int`       -> `c_int`     (i32; x86_64 SysV zero-extend 到 RAX)
//!   - C `long`      -> `c_long`    (i64)
//!   - C `fmc_slice` -> `CSlice`    (`#[repr(C)]` {*const c_char, c_long})
//!   - C `const char *` -> `*const c_char` (调用方保证 NUL-terminated; null=空)
//!
//! 与 C 的差异:
//!   - `run_command_json` 返回的 buffer 由 `run_command_free` 走 libc free
//!     (malloc 声明 extern "C", 与原 C bridge.o 内存契约一致; Mojo 端
//!     run_command_free 调用顺序不变).
//!   - 字符串返回 (method/path/query/...) ptr 指向 Rust 静态数组, 不需要 free.
//!   - `bridge_fail` 走 `std::process::exit(1)` (C: exit(1)).
//!   - 内部信号处理函数 (signal_handler) 不导出 (setup_signal_handlers 内部用).

use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_long, c_void};

// ===== 子模块导入 (全部 `as` 别名以避免与 extern "C" fn 同名冲突) =====

use super::cmd::run_command_json as cmd_run_command_json;
use super::regex::rgx_match;
use super::crypto::{b64url_encode as crypto_b64url_encode, hmac_sha256 as crypto_hmac_sha256};
use super::init_workers::{get_worker_id as init_get_worker_id, init_workers as init_init_workers};
use super::io::{
    conn_done as io_conn_done, recv_and_parse as io_recv_and_parse, set_listen_fd as io_set_listen_fd,
};
use super::port::current_configured_port as port_current_configured_port;
use super::metrics::{metrics_get_slice, metrics_init as bridge_metrics_init};
use super::otel_traces::{
    trace_record as otel_trace_record_inner, traces_get_slice as otel_traces_get_slice,
};
use super::request::{
    get_body_slice_inner, get_close_after_response as req_get_close_after_response,
    get_last_status_len as req_get_last_status_len, get_method_slice as req_get_method_slice,
    get_header_value_slice as req_get_header_value_slice,
    get_path_slice as req_get_path_slice, get_query_slice as req_get_query_slice,
    get_ws_event_type as req_get_ws_event_type, get_ws_key_slice as req_get_ws_key_slice,
    read_last_status_byte as req_read_last_status_byte, CSlice,
};
use super::state::{
    get_access_log_mode as state_get_access_log_mode,
    set_embedded_static_dir as state_set_embedded_static_dir,
    set_max_body_size as state_set_max_body_size,
    set_static_dir as state_set_static_dir,
};
use super::lifespan::{
    get_lifespan_shutdown as ls_shutdown, get_lifespan_startup as ls_startup,
    get_lifespan_timeout_ms as ls_timeout_ms,
};
use super::send::{
    send_error_json as send_error_json_inner,
    send_simple_response_extra as send_send_simple_response_extra,
    send_sse_response as send_send_sse_response,
    send_sse_response_extra as send_send_sse_response_extra,
    send_text_response as send_send_text_response,
    send_text_response_status as send_send_text_response_status,
    send_head_response as send_send_head_response,
    send_html_response as send_send_html_response,
    send_preflight_response as send_send_preflight_response,
    send_redirect_response as send_send_redirect_response,
    send_simple_response as send_send_simple_response,
    send_simple_response_allow as send_send_simple_response_allow,
    send_static_file as send_send_static_file,
    send_static_file_head as send_send_static_file_head,
};
use super::file_serve::send_file_response as fs_send_file_response;
use super::send::send_streaming_response as send_send_streaming_response;
use super::signals::{
    is_running as sig_is_running, server_shutdown as sig_server_shutdown,
    setup_signal_handlers as sig_setup_signal_handlers,
};
use super::socket::create_bound_socket as sock_create_bound_socket;
use super::time_util::now_ms as time_now_ms;
use super::multipart::{
    parse_current as mp_parse_current_inner,
    get_part_count as mp_get_part_count_inner,
    get_part_field_len as mp_get_part_field_len_inner,
    get_part_field_byte as mp_get_part_field_byte_inner,
    part_save as mp_part_save_inner,
};
use super::io::ws_pump_now as io_ws_pump_now;
use super::ws_session_ffi::{
    get_ws_close_wait_ms as wsf_get_ws_close_wait_ms,
    get_ws_path_slice as wsf_get_ws_path_slice, get_ws_ping_max as wsf_get_ws_ping_max,
    get_ws_protocol_offer_slice as wsf_get_ws_protocol_offer_slice,
    is_ws_upgrade as wsf_is_ws_upgrade, ws_conn_close as wsf_ws_conn_close,
    ws_conn_upgrade as wsf_ws_conn_upgrade, ws_last_opcode as wsf_ws_last_opcode,
    ws_message_done as wsf_ws_message_done, ws_payload_slice as wsf_ws_payload_slice,
    ws_send_close as wsf_ws_send_close,
    ws_send_close_reason as wsf_ws_send_close_reason,
    ws_set_closing as wsf_ws_set_closing,
    ws_session_begin as wsf_ws_session_begin, ws_write_current as wsf_ws_write_current,
    ws_write_current_binary as wsf_ws_write_current_binary,
    ws_write_binary as wsf_ws_write_binary,
    ws_write_text as wsf_ws_write_text,
};

extern "C" {
    #[allow(dead_code)]
    fn malloc(size: usize) -> *mut c_void;
    #[allow(dead_code)]
    fn free(ptr: *mut c_void);
}

// ========== C string -> &[u8] 安全转换 (null/empty 容忍) ==========

/// SAFETY: 调用方保证 `p` 指向 NUL-terminated C string, 或为 null.
unsafe fn c_str_bytes(p: *const c_char) -> Vec<u8> {
    if p.is_null() {
        return Vec::new();
    }
    CStr::from_ptr(p).to_bytes().to_vec()
}

/// SAFETY: 同 `c_str_bytes`, 但用于 path/status 这类需要 `&str` 的入口.
unsafe fn c_str_lossy(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    CStr::from_ptr(p).to_string_lossy().into_owned()
}

/// 空字符串常指针 (供 run_command_json 失败路径返回, 与 C `""` 字面量同).
fn empty_ptr() -> *const c_char {
    static EMPTY: &[u8] = b"\0";
    EMPTY.as_ptr() as *const c_char
}

// =====================================================================
// 1. 时钟 / 生命周期
// =====================================================================

#[no_mangle]
pub extern "C" fn gettimeofday_ms() -> c_long {
    time_now_ms() as c_long
}

#[no_mangle]
pub extern "C" fn is_running() -> c_int {
    if sig_is_running() { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn server_shutdown() {
    sig_server_shutdown();
}

#[no_mangle]
pub extern "C" fn setup_signal_handlers() -> c_int {
    if sig_setup_signal_handlers() { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn bridge_fail() {
    std::process::exit(1);
}

// =====================================================================
// 2. 配置 / 启动 / worker
// =====================================================================

#[no_mangle]
pub extern "C" fn get_configured_port() -> c_int {
    port_current_configured_port() as c_int
}

#[no_mangle]
pub extern "C" fn create_bound_socket(port: c_int) -> c_int {
    let fd = sock_create_bound_socket(port as u16);
    if fd >= 0 {
        // C: `g_listen_fd = fd` (create_bound_socket 末尾); Mojo 不传回 fd,
        // 必须由 bridge 内部记住, recv_and_parse 才认得 listen fd.
        io_set_listen_fd(fd);
    }
    fd as c_int
}

#[no_mangle]
pub extern "C" fn init_workers() {
    init_init_workers();
}

#[no_mangle]
pub extern "C" fn get_worker_id() -> c_int {
    init_get_worker_id() as c_int
}

#[no_mangle]
pub extern "C" fn set_max_body_size(size: c_int) {
    state_set_max_body_size(size as usize);
}

/// C: `void set_static_dir(const char *dir)` — setup 链路 (Mojo setup_static_dir)
#[no_mangle]
pub extern "C" fn set_static_dir(dir: *const c_char) {
    let s = unsafe { c_str_lossy(dir) };
    state_set_static_dir(if s.is_empty() { None } else { Some(s.as_str()) });
}

#[no_mangle]
pub extern "C" fn set_embedded_static_dir(dir: *const c_char) {
    let s = unsafe { c_str_lossy(dir) };
    state_set_embedded_static_dir(if s.is_empty() { None } else { Some(s.as_str()) });
}

/// C: `int get_access_log_mode(void)` — F7 access log 模式 (0=text, 1=json)
#[no_mangle]
pub extern "C" fn get_access_log_mode() -> c_int {
    state_get_access_log_mode()
}

// =====================================================================
// 2b. Lifespan (决策-36, Goal-0003 P1): startup/shutdown 命令 env 读取.
//     命令切分/执行/失败短路在 Mojo 侧 lifespan.mojo (复用 run_command_json).
// =====================================================================

/// 决策-36: `fmc_slice get_lifespan_startup_slice(void)` — startup 命令
/// (env FASTAPI_MOJO_LIFESPAN_STARTUP, 换行分隔). 空 = 未配置 (len=0).
/// 缓冲 NUL 终止 (len 不含 NUL; Mojo CStringSlice.as_bytes() 按 NUL 截断, 见
/// lifespan.rs 模块文档 — 无 NUL 会越界读堆垃圾, 决策-36 实测 catch).
#[no_mangle]
pub extern "C" fn get_lifespan_startup_slice() -> CSlice {
    let v = ls_startup();
    CSlice { ptr: v.as_ptr() as *const c_char, len: (v.len() - 1) as c_long }
}

/// 决策-36: `fmc_slice get_lifespan_shutdown_slice(void)` — shutdown 命令
/// (env FASTAPI_MOJO_LIFESPAN_SHUTDOWN, 换行分隔). 空 = 未配置 (len=0).
/// NUL 终止契约同 get_lifespan_startup_slice.
#[no_mangle]
pub extern "C" fn get_lifespan_shutdown_slice() -> CSlice {
    let v = ls_shutdown();
    CSlice { ptr: v.as_ptr() as *const c_char, len: (v.len() - 1) as c_long }
}

/// 决策-36: `long get_lifespan_timeout_ms(void)` — 单条命令 timeout (默认 30000).
#[no_mangle]
pub extern "C" fn get_lifespan_timeout_ms() -> c_long {
    ls_timeout_ms() as c_long
}

// =====================================================================
// 3. per-request slice 访问器 (fmc_slice 返回, ptr 指向 Rust 静态 / active conn)
// =====================================================================

#[no_mangle]
pub extern "C" fn get_method_slice() -> CSlice {
    req_get_method_slice()
}

#[no_mangle]
pub extern "C" fn get_path_slice() -> CSlice {
    req_get_path_slice()
}

#[no_mangle]
pub extern "C" fn get_query_slice() -> CSlice {
    req_get_query_slice()
}

/// F3a: 按名从当前请求的 header 缓冲取值, 结果写入 CurrentRequest.hdr_value.
/// 返回: 0 = 找到 (值可能为空串); -2 = 未找到 (len=0); -1 = 出错 (无 active conn).
/// 调用方再调 get_header_value_slice 读结果.
#[no_mangle]
pub extern "C" fn extract_request_header(name: *const c_char) -> c_int {
    let n = unsafe { c_str_bytes(name) };
    super::conn::extract_request_header(&n) as c_int
}

/// F3a: 读取最近一次 extract_request_header 的结果 (CSlice { ptr, len }).
#[no_mangle]
pub extern "C" fn get_header_value_slice() -> CSlice {
    req_get_header_value_slice()
}

/// F6: 初始化 metrics 计数器 (START_MS 记当前时间). 在 main/init_workers 调一次.
#[no_mangle]
pub extern "C" fn metrics_init() {
    bridge_metrics_init();
}

/// F6: 渲染 Prometheus 文本 metrics. 返回 CSlice 指向静态缓冲 (单线程 worker 内调用).
#[no_mangle]
pub extern "C" fn get_metrics_block() -> CSlice {
    let (len, ptr) = metrics_get_slice();
    CSlice {
        ptr: ptr as *const c_char,
        len: len as c_long,
    }
}

/// Decision-62: record one completed HTTP request into the bounded in-process
/// OpenTelemetry trace ring. Recording is called by Mojo only when
/// FASTAPI_MOJO_OTEL=1; this FFI remains allocation-light and cannot fail.
#[no_mangle]
pub extern "C" fn otel_trace_record(
    method: *const c_char,
    path: *const c_char,
    query: *const c_char,
    status: *const c_char,
    duration_ms: c_long,
) {
    let m = unsafe { c_str_lossy(method) };
    let p = unsafe { c_str_lossy(path) };
    let q = unsafe { c_str_lossy(query) };
    let s = unsafe { c_str_lossy(status) };
    otel_trace_record_inner(&m, &p, &q, &s, duration_ms);
}

/// Decision-62: OTLP JSON-shaped in-memory trace export for GET /traces.
#[no_mangle]
pub extern "C" fn get_traces_block() -> CSlice {
    let (len, ptr) = otel_traces_get_slice();
    CSlice {
        ptr: ptr as *const c_char,
        len: len as c_long,
    }
}

/// C: `fmc_slice get_body_slice(void)` — active conn 的 body slice
/// (无 active 或 body 未收 → 返回空 ptr, 与 C `(fmc_slice){"", 0}` 一致).
#[no_mangle]
pub extern "C" fn get_body_slice() -> CSlice {
    get_body_slice_inner()
}

#[no_mangle]
pub extern "C" fn get_ws_key_slice() -> CSlice {
    req_get_ws_key_slice()
}

/// C ABI `get_ws_protocol_slice` = **客户端原始 offer** (读 active conn hdr,
/// 与 C §1257-1269 一致; upgrade 前由 Mojo run_ws_upgrade 调用).
/// `request::get_ws_protocol_slice` (服务器选中值) 是**内部** API, 不导出.
#[no_mangle]
pub extern "C" fn get_ws_protocol_slice() -> CSlice {
    wsf_get_ws_protocol_offer_slice()
}

#[no_mangle]
pub extern "C" fn get_ws_path_slice() -> CSlice {
    wsf_get_ws_path_slice()
}

#[no_mangle]
pub extern "C" fn ws_payload_slice() -> CSlice {
    wsf_ws_payload_slice()
}

// =====================================================================
// 4. scalar getters (long / int)
// =====================================================================

#[no_mangle]
pub extern "C" fn get_close_after_response() -> c_long {
    if req_get_close_after_response() { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn get_last_status_len() -> c_long {
    req_get_last_status_len() as c_long
}

#[no_mangle]
pub extern "C" fn read_last_status_byte(i: c_int) -> c_long {
    req_read_last_status_byte(i as usize) as c_long
}

#[no_mangle]
pub extern "C" fn is_ws_upgrade() -> c_int {
    if wsf_is_ws_upgrade() != 0 { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn ws_event_type() -> c_int {
    req_get_ws_event_type() as c_int
}

#[no_mangle]
pub extern "C" fn ws_last_opcode() -> c_int {
    wsf_ws_last_opcode() as c_int
}

#[no_mangle]
pub extern "C" fn get_ws_ping_max() -> c_int {
    wsf_get_ws_ping_max() as c_int
}

// =====================================================================
// 5. HTTP 响应发送 (fd + status + body/msg/path)
// =====================================================================

#[no_mangle]
pub extern "C" fn send_simple_response(fd: c_int, status: *const c_char, body: *const c_char) -> c_long {
    let s = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_bytes(body) };
    send_send_simple_response(fd, &s, &b) as c_long
}

#[no_mangle]
pub extern "C" fn send_simple_response_allow(
    fd: c_int, status: *const c_char, body: *const c_char, allow: *const c_char,
) -> c_long {
    let s = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_bytes(body) };
    let a = unsafe { c_str_lossy(allow) };
    send_send_simple_response_allow(fd, &s, &b, &a) as c_long
}

/// F3b: JSON 响应携带自定义头 (与 send_simple_response 同款, extra 为 "\r\n" 分隔头行).
#[no_mangle]
pub extern "C" fn send_simple_response_extra(
    fd: c_int, status: *const c_char, body: *const c_char, extra: *const c_char,
) -> c_long {
    let s = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_bytes(body) };
    let e = unsafe { c_str_lossy(extra) };
    send_send_simple_response_extra(fd, &s, &b, &e) as c_long
}

/// F5: SSE 响应 (Content-Type: text/event-stream; charset=utf-8).
/// 调用方负责构造 SSE body (format_sse_event / build_sse_body).
#[no_mangle]
pub extern "C" fn send_sse_response(fd: c_int, body: *const c_char) -> c_long {
    let b = unsafe { c_str_bytes(body) };
    send_send_sse_response(fd, &b) as c_long
}

/// F9: SSE 响应带自定义状态码 + extra 头 (上游 FastAPI 0.140.13 修复对齐).
/// `status` 形如 "201 Created"; 透传到响应头, 不再硬编码 200 OK.
/// `extra` 为 "\r\n" 分隔的 "Name: value" 行 (空串 = 无 extra).
#[no_mangle]
pub extern "C" fn send_sse_response_extra(
    fd: c_int, status: *const c_char, body: *const c_char, extra: *const c_char,
) -> c_long {
    let st = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_bytes(body) };
    let ex = unsafe { c_str_lossy(extra) };
    send_send_sse_response_extra(fd, &st, &b, &ex) as c_long
}

/// F6: 纯文本响应 (Content-Type: text/plain; charset=utf-8). Prometheus metrics 用.
#[no_mangle]
pub extern "C" fn send_text_response(fd: c_int, body: *const c_char) -> c_long {
    let b = unsafe { c_str_bytes(body) };
    send_send_text_response(fd, &b) as c_long
}

/// ADR-0024 (决策-49): 异常 handler 的 text/plain + 自定义 status 响应.
#[no_mangle]
pub extern "C" fn send_text_response_status(
    fd: c_int, status: *const c_char, body: *const c_char,
) -> c_long {
    let s = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_bytes(body) };
    send_send_text_response_status(fd, &s, &b) as c_long
}

#[no_mangle]
pub extern "C" fn send_head_response(fd: c_int, status: *const c_char, body: *const c_char) -> c_long {
    let s = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_bytes(body) };
    send_send_head_response(fd, &s, &b) as c_long
}

#[no_mangle]
pub extern "C" fn send_preflight_response(fd: c_int) -> c_long {
    send_send_preflight_response(fd) as c_long
}

#[no_mangle]
pub extern "C" fn send_html_response(fd: c_int, status: *const c_char, body: *const c_char) -> c_long {
    let s = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_bytes(body) };
    send_send_html_response(fd, &s, &b) as c_long
}

#[no_mangle]
pub extern "C" fn send_static_file(fd: c_int, path: *const c_char) -> c_long {
    let p = unsafe { c_str_lossy(path) };
    send_send_static_file(fd, &p) as c_long
}

#[no_mangle]
pub extern "C" fn send_static_file_head(fd: c_int, path: *const c_char) -> c_long {
    let p = unsafe { c_str_lossy(path) };
    send_send_static_file_head(fd, &p) as c_long
}

/// 决策-48: FileResponse 单点发送 (KIND_FILE FFI; file_serve.rs 内部 stat /
/// Range 分派 / etag / multipart / 500; 相对路径 = 静态目录相对, 绝对路径原样).
#[no_mangle]
pub extern "C" fn send_file_response(
    fd: c_int,
    path: *const c_char,
    media_type: *const c_char,
    filename: *const c_char,
    cdt: *const c_char,
    status: *const c_char,
    extra: *const c_char,
) -> c_long {
    let p = unsafe { c_str_lossy(path) };
    let m = unsafe { c_str_lossy(media_type) };
    let f = unsafe { c_str_lossy(filename) };
    let c = unsafe { c_str_lossy(cdt) };
    let s = unsafe { c_str_lossy(status) };
    let e = unsafe { c_str_lossy(extra) };
    fs_send_file_response(fd, &p, &m, &f, &c, &s, &e)
}

/// 决策-48: StreamingResponse (chunked transfer; media_type 空 = 无 Content-Type).
#[no_mangle]
pub extern "C" fn send_streaming_response(
    fd: c_int,
    status: *const c_char,
    body: *const c_char,
    media_type: *const c_char,
    extra: *const c_char,
) -> c_long {
    let st = unsafe { c_str_lossy(status) };
    let b = unsafe { c_str_lossy(body) };
    let m = unsafe { c_str_lossy(media_type) };
    let e = unsafe { c_str_lossy(extra) };
    send_send_streaming_response(fd, &st, &b, &m, &e)
}

/// 决策-68: RedirectResponse (无 Content-Type / Content-Length: 0 / Location 头).
/// `status` 形如 "307 Temporary Redirect"; `location` 为原始 URL (bridge 内
/// 按上游 safe set 百分号编码)。
#[no_mangle]
pub extern "C" fn send_redirect_response(
    fd: c_int,
    status: *const c_char,
    location: *const c_char,
) -> c_long {
    let st = unsafe { c_str_lossy(status) };
    let loc = unsafe { c_str_lossy(location) };
    send_send_redirect_response(fd, &st, &loc)
}

#[no_mangle]
pub extern "C" fn send_error_json(fd: c_int, status: *const c_char, msg: *const c_char) -> c_long {
    let s = unsafe { c_str_lossy(status) };
    let m = unsafe { c_str_lossy(msg) };
    send_error_json_inner(fd, &s, &m) as c_long
}

// =====================================================================
// 6. WS FFI
// =====================================================================

#[no_mangle]
pub extern "C" fn ws_session_begin(subprotocol: *const c_char) -> c_int {
    let s = unsafe { c_str_lossy(subprotocol) };
    wsf_ws_session_begin(&s) as c_int
}

#[no_mangle]
pub extern "C" fn ws_conn_upgrade(fd: c_int) -> c_int {
    wsf_ws_conn_upgrade(fd) as c_int
}

#[no_mangle]
pub extern "C" fn ws_write_current(fd: c_int, opcode: c_int) -> c_int {
    wsf_ws_write_current(fd, opcode) as c_int
}

#[no_mangle]
pub extern "C" fn ws_write_text(fd: c_int, data: *const c_char) -> c_int {
    let d = unsafe { c_str_bytes(data) };
    wsf_ws_write_text(fd, &d) as c_int
}

#[no_mangle]
pub extern "C" fn ws_send_close(fd: c_int, code: c_int) -> c_int {
    wsf_ws_send_close(fd, code) as c_int
}

/// close 帧 (code + reason); ADR-0026 决策-51. reason = NUL 结尾 C 串
/// (FFI 约定同 ws_write_text). wsproto 规范化 (1004/1006→1000, 1005→
/// 无 payload, UTF-8 截断 123B) 在 ws.rs.
#[no_mangle]
pub extern "C" fn ws_send_close_reason(fd: c_int, code: c_int, reason: *const c_char) -> c_int {
    let d = unsafe { c_str_bytes(reason) };
    wsf_ws_send_close_reason(fd, code, &d) as c_int
}

/// BINARY 回复帧 (NUL-free 文本, 非 echo handler); ADR-0026 决策-51.
#[no_mangle]
pub extern "C" fn ws_write_binary(fd: c_int, data: *const c_char) -> c_int {
    let d = unsafe { c_str_bytes(data) };
    wsf_ws_write_binary(fd, &d) as c_int
}

/// 零拷贝: 待处理消息载荷 → BINARY 帧 (NUL 安全); ADR-0026 决策-51.
#[no_mangle]
pub extern "C" fn ws_write_current_binary(fd: c_int) -> c_int {
    wsf_ws_write_current_binary(fd) as c_int
}

/// 进入 WS close-wait (phase 5); 调用前 close 帧须已发; ADR-0026 决策-51.
/// close-wait 时长 = env FASTAPI_MOJO_WS_CLOSE_WAIT (内部自读, 0 = 立即关).
#[no_mangle]
pub extern "C" fn ws_set_closing(fd: c_int) -> c_int {
    wsf_ws_set_closing(fd) as c_int
}

/// FASTAPI_MOJO_WS_CLOSE_WAIT (默认 10000ms; 0 = 立即关); ADR-0026.
#[no_mangle]
pub extern "C" fn get_ws_close_wait_ms() -> c_int {
    wsf_get_ws_close_wait_ms() as c_int
}

#[no_mangle]
pub extern "C" fn ws_message_done(fd: c_int) {
    wsf_ws_message_done(fd);
}

#[no_mangle]
pub extern "C" fn ws_conn_close(fd: c_int) {
    wsf_ws_conn_close(fd);
}

#[no_mangle]
pub extern "C" fn ws_pump_now(fd: c_int) {
    io_ws_pump_now(fd);
}

// =====================================================================
// 7. master event loop (recv_and_parse / conn_done)
// =====================================================================

#[no_mangle]
pub extern "C" fn recv_and_parse() -> c_long {
    io_recv_and_parse() as c_long
}

#[no_mangle]
pub extern "C" fn conn_done(fd: c_int, reuse: c_int) {
    io_conn_done(fd, reuse);
}

// =====================================================================
// 8. cmd 路径 (run_command_json / run_command_free)
// =====================================================================

#[no_mangle]
pub extern "C" fn run_command_json(cmd: *const c_char, timeout_ms: c_long) -> CSlice {
    let cmd_str = unsafe { c_str_lossy(cmd) };
    let bytes = cmd_run_command_json(&cmd_str, timeout_ms as u32);
    if bytes.is_empty() {
        return CSlice { ptr: empty_ptr(), len: 0 };
    }
    // malloc(n+1) + memcpy(n) + NUL 收尾; ptr 由 run_command_free(libc free) 回收.
    // NUL 终止是硬性契约 (决策-36 修复): Mojo CStringSlice.as_bytes() 按 C 串
    // 语义读到首个 NUL (忽略 fmc_slice.len); 无 NUL 时 Mojo 越界读堆垃圾
    // (F11 BackgroundTasks 的 out= 日志尾部一直带垃圾, 同此病, C bridge 遗留).
    let n = bytes.len();
    let p = unsafe { malloc(n + 1) } as *mut c_char;
    if p.is_null() {
        return CSlice { ptr: empty_ptr(), len: 0 };
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, n);
        *p.add(n) = 0;
    }
    CSlice { ptr: p, len: n as c_long }
}

#[no_mangle]
pub extern "C" fn run_command_free(ptr: *const c_char) {
    if !ptr.is_null() {
        unsafe { free(ptr as *mut c_void); }
    }
}

// =====================================================================
// 8.5 crypto (fm_hmac_sha256_b64url / _free) — 决策-44 OAuth2/JWT (HS256)
// =====================================================================
// JWT 签名原语: HMAC-SHA256(key, signing_input) -> base64url (RFC 7515, 无
// padding). 内存契约与 run_command_json 一致: malloc(n+1) + NUL 终止
// (决策-36: Mojo CStringSlice.as_bytes() 按 C 串读至 NUL), ptr 由
// fm_hmac_sha256_b64url_free 走 libc free 回收. 输出为 URL-safe 字母表
// (A-Za-z0-9-_), 无内部 NUL 风险.
//
// len 参数语义: > 0 时按显式长度取字节 (二进制安全, 可含 NUL);
// == 0 / 指针为 null 时回退 NUL-terminated 语义 (空 = 空输入).

/// SAFETY: `p` 指向至少 `len` 可读字节; `len <= 0` 或 null 时返回空
/// (或 NUL 截断). 调用方 (Mojo CStringSlice) 保证.
unsafe fn c_bytes_len(p: *const c_char, len: c_long) -> Vec<u8> {
    if len <= 0 {
        return c_str_bytes(p);
    }
    if p.is_null() {
        return Vec::new();
    }
    std::slice::from_raw_parts(p as *const u8, len as usize).to_vec()
}

#[no_mangle]
pub extern "C" fn fm_hmac_sha256_b64url(
    key: *const c_char,
    key_len: c_long,
    msg: *const c_char,
    msg_len: c_long,
) -> CSlice {
    let kb = unsafe { c_bytes_len(key, key_len) };
    let mb = unsafe { c_bytes_len(msg, msg_len) };
    let sig = crypto_b64url_encode(&crypto_hmac_sha256(&kb, &mb));
    let n = sig.len();
    let p = unsafe { malloc(n + 1) } as *mut c_char;
    if p.is_null() {
        return CSlice { ptr: empty_ptr(), len: 0 };
    }
    unsafe {
        std::ptr::copy_nonoverlapping(sig.as_ptr(), p as *mut u8, n);
        *p.add(n) = 0;
    }
    CSlice { ptr: p, len: n as c_long }
}

#[no_mangle]
pub extern "C" fn fm_hmac_sha256_b64url_free(ptr: *const c_char) {
    if !ptr.is_null() {
        unsafe { free(ptr as *mut c_void); }
    }
}

// =====================================================================
// 9. multipart (mp_*) — G3-v0.7 文件上传 (multipart/form-data, Rust bridge)
// =====================================================================
// 字节逻辑归 Rust 承载 (binary body / invalid UTF-8 文件内容不损毁):
//   mp_parse_current(): 读 active conn 的 body + Content-Type, 解析 multipart,
//                       返回 part 数 (i64; -1 = 非 multipart 或失败, Mojo 端按
//                       Int(int64) 读取, 避免 c_int(-1) 零扩展为 uint64 巨大值
//                       导致 n_parts<=0 误判的整型 ABI 陷阱 -- 教训-13).
//   mp_part_count()/mp_part_{name,filename,content_type,body_b64}():
//                       按索引读上次解析结果 (CSlice 指向 thread_local buf;
//                       调用方须在下次 mp_* 调用前消费).
// Mojo 侧在 dispatch 的 inject_multipart_fields 中调用.

#[no_mangle]
pub extern "C" fn mp_parse_current() -> c_long {
    mp_parse_current_inner() as c_long
}

#[no_mangle]
pub extern "C" fn mp_part_count() -> c_long {
    mp_get_part_count_inner() as c_long
}

// 逐字节访问器 (纯整数返回, 无 CStringSlice ABI 歧义).
// field: 0=name 1=filename 2=content_type 3=body 4=body_b64
#[no_mangle]
pub extern "C" fn mp_part_field_len(i: c_int, field: c_int) -> c_long {
    mp_get_part_field_len_inner(i as usize, field) as c_long
}

#[no_mangle]
pub extern "C" fn mp_part_field_byte(i: c_int, field: c_int, idx: c_long) -> c_long {
    mp_get_part_field_byte_inner(i as usize, field, idx) as c_long
}

// 决策-54 (ADR-0029): regex search (pattern, s) — 1 = 命中 / 0 = 未中 /
// -1 = 编译失败. ASCII 域 (文档化); search 语义 = 上游 pydantic 2.13.5
// parity (P26-h: ^ 仅串首, 任意起点, $ 串尾/尾\n前).
#[no_mangle]
pub extern "C" fn regex_match(pattern: *const c_char, s: *const c_char) -> c_int {
    if pattern.is_null() || s.is_null() {
        return -1;
    }
    let p = unsafe { c_str_lossy(pattern) };
    let t = unsafe { c_str_lossy(s) };
    rgx_match(&p, &t)
}

// 决策-46 (ADR-0021): part body 写盘 (UploadFile save 等价).
// path: NUL-terminated (Mojo CStringSlice 契约). 0 成功 / -1 失败
// (b64 空 / 解码失败 / fs 失败). 路径穿越检查在 Mojo 层 (_file_save).
#[no_mangle]
pub extern "C" fn mp_part_save(i: c_int, path: *const c_char) -> c_int {
    if path.is_null() {
        return -1;
    }
    let p = unsafe { c_str_lossy(path) };
    mp_part_save_inner(i as usize, &p) as c_int
}

// =====================================================================
// 55. Middleware (decision-55, ADR-0030): user custom middleware FFI.
//     set_req_id: Mojo-side request-id output (per request) -> CurrentRequest.
//     inject_request_header: REQHDR verb synthetic header (per verb).
// =====================================================================

/// Decision-55 (ADR-0030): current request ID (NUL-terminated; the Mojo side
/// passes the request-id middleware's output) — stored for BODY `{req_id}`
/// interpolation and the `[mw]` log line. 0 = ok, -1 = null.
#[no_mangle]
pub extern "C" fn set_req_id(id: *const c_char) -> c_int {
    if id.is_null() {
        return -1;
    }
    let s = unsafe { c_str_lossy(id) };
    super::request::set_req_id(&s)
}

/// Decision-55 (ADR-0030): inject a synthetic request header (REQHDR verb)
/// — visible to extract_request_header/get_header_value_ci (first injected
/// wins, CI). 0 = ok, 1 = cap reached, -1 = null.
#[no_mangle]
pub extern "C" fn inject_request_header(name: *const c_char, value: *const c_char) -> c_int {
    if name.is_null() || value.is_null() {
        return -1;
    }
    let n = unsafe { c_str_lossy(name) };
    let v = unsafe { c_str_lossy(value) };
    super::request::synth_push(&n, &v)
}
