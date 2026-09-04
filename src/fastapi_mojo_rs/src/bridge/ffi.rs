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
use super::init_workers::{get_worker_id as init_get_worker_id, init_workers as init_init_workers};
use super::io::{
    conn_done as io_conn_done, recv_and_parse as io_recv_and_parse, set_listen_fd as io_set_listen_fd,
};
use super::port::current_configured_port as port_current_configured_port;
use super::metrics::{metrics_get_slice, metrics_init as bridge_metrics_init};
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
use super::send::{
    send_error_json as send_error_json_inner,
    send_simple_response_extra as send_send_simple_response_extra,
    send_sse_response as send_send_sse_response,
    send_sse_response_extra as send_send_sse_response_extra,
    send_text_response as send_send_text_response,
    send_head_response as send_send_head_response,
    send_html_response as send_send_html_response,
    send_preflight_response as send_send_preflight_response,
    send_simple_response as send_send_simple_response,
    send_simple_response_allow as send_send_simple_response_allow,
    send_static_file as send_send_static_file,
    send_static_file_head as send_send_static_file_head,
};
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
};
use super::io::ws_pump_now as io_ws_pump_now;
use super::ws_session_ffi::{
    get_ws_path_slice as wsf_get_ws_path_slice, get_ws_ping_max as wsf_get_ws_ping_max,
    get_ws_protocol_offer_slice as wsf_get_ws_protocol_offer_slice,
    is_ws_upgrade as wsf_is_ws_upgrade, ws_conn_close as wsf_ws_conn_close,
    ws_conn_upgrade as wsf_ws_conn_upgrade, ws_last_opcode as wsf_ws_last_opcode,
    ws_message_done as wsf_ws_message_done, ws_payload_slice as wsf_ws_payload_slice,
    ws_send_close as wsf_ws_send_close,
    ws_session_begin as wsf_ws_session_begin, ws_write_current as wsf_ws_write_current,
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
/// 返回 -1 = 出错 (无 active conn); 0 = ok (含 header 缺失, 此时 len=0).
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
    // malloc + memcpy; ptr 由 run_command_free(libc free) 回收 (与 C bridge 一致).
    let n = bytes.len();
    let p = unsafe { malloc(n) } as *mut c_char;
    if p.is_null() {
        return CSlice { ptr: empty_ptr(), len: 0 };
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, n);
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
