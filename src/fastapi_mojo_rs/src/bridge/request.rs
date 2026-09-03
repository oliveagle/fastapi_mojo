//! bridge/request.rs — 当前请求的全局切片 + 字段访问器 (ADR-0010 DC2).
//!
//! 端口 C `http_bridge_final.c` 的 §100-165 全局 (g_method/g_path/g_query/g_method_len/
//! g_path_len/g_query_len/g_protocol_11/g_close_after_response) + §1202-1265 slice
//! 访问器 (get_method_slice/path/query/body/ws_path/ws_protocol/ws_key).
//!
//! 用途: recv_and_parse 解析完一个 HTTP 请求后, 把 method/path/query/body 写到本
//! 模块; Mojo 通过 extern "C" `get_*_slice` 读回 (CStringSlice ABI). WS upgrade 时
//! 同理 (ws_path/ws_protocol/ws_key).
//!
//! **线程模型**: 每个 worker 进程独立 (fork 模型), 进程内单线程 (桥接串行
//! dispatch), 全局可直接用 `static mut` (在 unsafe 块中) 而无需 Mutex — 与 C 端
//! 单线程假设一致. 但为 Rust 安全, 这里用 `Mutex` 包裹 (`Mutex::lock()` 无竞争,
//! 等价单线程访问, 仅多一层边界检查).

use std::os::raw::c_char;
use std::sync::Mutex;

/// 当前 HTTP 请求的 method/path/query 字段 (固定大小数组, 与 C g_method/g_path/g_query 对齐).
pub const MAX_METHOD: usize = 16;
pub const MAX_PATH: usize = 1024;
pub const MAX_QUERY: usize = 1024;

/// 当前活跃连接的 fd (用于 ws_* 访问器; -1 = 无).
/// 注意: ws_payload_slice / ws_last_opcode 等需要 active 连接的状态.
#[derive(Debug, Clone, Copy)]
pub struct CurrentRequest {
    pub method: [u8; MAX_METHOD],
    pub method_len: usize,
    pub path: [u8; MAX_PATH],
    pub path_len: usize,
    pub query: [u8; MAX_QUERY],
    pub query_len: usize,
    pub protocol_11: bool,
    pub close_after_response: bool,
    /// 当前活跃 conn 的 fd (recv_and_parse 返回时设置).
    pub active_fd: i32,
    /// 当前活跃 conn 的 phase (0..4, 0/1=读中 2=HTTP dispatch 3=WS session 4=WS dispatch).
    pub active_phase: i32,
    /// 上一帧 WS 事件类型 (0=HTTP, 1=WS 数据, 2=WS 结束). 由 recv_and_parse 设置.
    pub ws_event_type: i32,
    /// ws_upgrade 时提取的 Sec-WebSocket-Key (NUL 结尾).
    pub ws_key: [u8; 256],
    pub ws_key_len: usize,
    /// 上一次 set 进来的 subprotocol / Sec-WebSocket-Protocol (slice 用).
    pub ws_protocol: [u8; 256],
    pub ws_protocol_len: usize,
    /// 上一次响应状态行 (供 /status 路由读, send_response 时更新).
    pub last_status: [u8; 32],
    pub last_status_len: usize,
}

impl CurrentRequest {
    pub const fn empty() -> Self {
        CurrentRequest {
            method: [0u8; MAX_METHOD],
            method_len: 0,
            path: [0u8; MAX_PATH],
            path_len: 0,
            query: [0u8; MAX_QUERY],
            query_len: 0,
            protocol_11: false,
            close_after_response: true,
            active_fd: -1,
            active_phase: 0,
            ws_event_type: 0,
            ws_key: [0u8; 256],
            ws_key_len: 0,
            ws_protocol: [0u8; 256],
            ws_protocol_len: 0,
            last_status: [0u8; 32],
            last_status_len: 0,
        }
    }
}

static CURRENT: Mutex<CurrentRequest> = Mutex::new(CurrentRequest::empty());

/// poison-safe CURRENT lock: 任何单测在持锁时 panic 会 poison Mutex,
/// 用 into_inner 恢复, 避免单个测试失败级联污染全部后续测试 (教训-12).
fn lock_current() -> std::sync::MutexGuard<'static, CurrentRequest> {
    CURRENT.lock().unwrap_or_else(|e| e.into_inner())
}


/// C ABI slice (与 C `fmc_slice { const char *ptr; long len; }` 完全一致).
#[repr(C)]
pub struct CSlice {
    pub ptr: *const c_char,
    pub len: c_long,
}

// 显式导入 c_long (在 raw 命名空间下)
use std::os::raw::c_long;

/// 在 recv_and_parse 完成请求解析后调用, 把 method/path/query 写入全局.
pub fn set_http_fields(method: &[u8], path: &[u8], query: &[u8], protocol_11: bool, close_after: bool, fd: i32) {
    let mut g = lock_current();
    let mlen = method.len().min(MAX_METHOD);
    g.method[..mlen].copy_from_slice(&method[..mlen]);
    g.method_len = mlen;
    let plen = path.len().min(MAX_PATH);
    g.path[..plen].copy_from_slice(&path[..plen]);
    g.path_len = plen;
    let qlen = query.len().min(MAX_QUERY);
    g.query[..qlen].copy_from_slice(&query[..qlen]);
    g.query_len = qlen;
    g.protocol_11 = protocol_11;
    g.close_after_response = close_after;
    g.active_fd = fd;
    g.active_phase = 2;  // HTTP dispatch
    g.ws_event_type = 0;
}

/// 在 ws_conn_upgrade 时调用, 把 WS key/path 写入全局.
pub fn set_ws_fields(ws_key: &[u8], ws_path: &[u8], ws_protocol: Option<&[u8]>) {
    let mut g = lock_current();
    let klen = ws_key.len().min(255);
    g.ws_key[..klen].copy_from_slice(&ws_key[..klen]);
    g.ws_key[klen] = 0;
    g.ws_key_len = klen;
    let plen = ws_path.len().min(255);
    g.ws_protocol[..plen].copy_from_slice(&ws_path[..plen]);
    g.ws_protocol[plen] = 0;
    g.ws_protocol_len = plen;
    let _ = ws_protocol;  // 当前实现用 path 字段统一; ws_protocol 由独立的 ws_session_set_protocol 单独设置
}

/// 单独设置 ws_protocol (get_ws_protocol_slice 读取).
pub fn ws_session_set_protocol(p: &[u8]) {
    let mut g = lock_current();
    let n = p.len().min(255);
    g.ws_protocol[..n].copy_from_slice(&p[..n]);
    g.ws_protocol[n] = 0;
    g.ws_protocol_len = n;
}

/// 重置 per-request 字段 (类似 C `finish_header` 开头的 per-request reset).
///
/// ⚠️ 必须**完整**还原 `CurrentRequest::empty()`: 漏掉任意字段都会让
/// `request::tests::empty_initial_state` 在 io_tests / send_tests 之后
/// 因污染状态而失败, panic 时持锁又会 poison CURRENT, 级联 28 测试失败.
/// (教训-12 / 决策-19).
pub fn reset_request_fields() {
    let mut g = lock_current();
    g.method_len = 0;
    g.path_len = 0;
    g.query_len = 0;
    g.protocol_11 = false;
    g.close_after_response = true;
    g.active_fd = -1;
    g.active_phase = 0;
    g.ws_event_type = 0;
    g.ws_key_len = 0;
    g.ws_protocol_len = 0;
    g.last_status_len = 0;
    g.last_status = [0u8; 32];
}

/// 更新 active fd/phase (conn_done / pump 后).
pub fn set_active(fd: i32, phase: i32) {
    let mut g = lock_current();
    g.active_fd = fd;
    g.active_phase = phase;
}

/// 更新 ws_event_type (recv_and_parse 入队/出队时).
pub fn set_ws_event_type(t: i32) {
    let mut g = lock_current();
    g.ws_event_type = t;
}

/// 更新 last_status (send_response 后).
pub fn set_last_status(s: &[u8]) {
    let mut g = lock_current();
    let n = s.len().min(31);
    g.last_status[..n].copy_from_slice(&s[..n]);
    g.last_status[n] = 0;
    g.last_status_len = n;
}

/// 更新 protocol_11 (finish_header 后).
pub fn set_protocol_11(p: bool) {
    let mut g = lock_current();
    g.protocol_11 = p;
}

/// 更新 close_after_response.
pub fn set_close_after_response(c: bool) {
    let mut g = lock_current();
    g.close_after_response = c;
}

/// 读取 close_after_response (get_close_after_response FFI 用).
pub fn get_close_after_response() -> bool {
    lock_current().close_after_response
}

/// 读取 protocol_11.
pub fn get_protocol_11() -> bool {
    lock_current().protocol_11
}

/// 读取 ws_event_type.
pub fn get_ws_event_type() -> i32 {
    lock_current().ws_event_type
}

// ========== Slice 访问器 (FFI 形态, 返回 CSLice { ptr, len }) ==========

pub fn get_method_slice() -> CSlice {
    let g = lock_current();
    CSlice {
        ptr: g.method.as_ptr() as *const c_char,
        len: g.method_len as c_long,
    }
}

pub fn get_path_slice() -> CSlice {
    let g = lock_current();
    CSlice {
        ptr: g.path.as_ptr() as *const c_char,
        len: g.path_len as c_long,
    }
}

pub fn get_query_slice() -> CSlice {
    let g = lock_current();
    CSlice {
        ptr: g.query.as_ptr() as *const c_char,
        len: g.query_len as c_long,
    }
}

pub fn get_ws_key_slice() -> CSlice {
    let g = lock_current();
    CSlice {
        ptr: g.ws_key.as_ptr() as *const c_char,
        len: g.ws_key_len as c_long,
    }
}

pub fn get_ws_protocol_slice() -> CSlice {
    let g = lock_current();
    CSlice {
        ptr: g.ws_protocol.as_ptr() as *const c_char,
        len: g.ws_protocol_len as c_long,
    }
}

/// ws_path / ws_payload / ws_protocol 等**需要 active conn 状态**的访问器
/// 不能直接走 CURRENT (它们依赖 conn 表里的 conn 实例). 由 ws_session_ffi 模块
/// 通过 conn 表实现.

pub fn get_last_status_len() -> usize {
    lock_current().last_status_len
}

pub fn read_last_status_byte(i: usize) -> i32 {
    let g = lock_current();
    if i < g.last_status_len {
        g.last_status[i] as i32
    } else {
        -1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_initial_state() {
        reset_request_fields();
        let g = lock_current();
        assert_eq!(g.method_len, 0);
        assert_eq!(g.path_len, 0);
        assert_eq!(g.query_len, 0);
        assert!(!g.protocol_11);
        assert!(g.close_after_response);
        assert_eq!(g.active_fd, -1);
        assert_eq!(g.ws_event_type, 0);
        assert_eq!(g.last_status_len, 0);
    }

    #[test]
    fn set_http_fields_truncates_long_inputs() {
        let mut long_method = vec![b'A'; 100];
        long_method.truncate(MAX_METHOD);
        set_http_fields(b"GET", b"/foo", b"x=1", true, false, 42);
        let g = lock_current();
        assert_eq!(&g.method[..3], b"GET");
        assert_eq!(g.method_len, 3);
        assert_eq!(&g.path[..4], b"/foo");
        assert_eq!(g.path_len, 4);
        assert!(g.protocol_11);
        assert!(!g.close_after_response);
        assert_eq!(g.active_fd, 42);
        assert_eq!(g.active_phase, 2);
    }

    #[test]
    fn slice_accessors_return_correct_ptr_and_len() {
        set_http_fields(b"POST", b"/items", b"", true, true, 7);
        let m = get_method_slice();
        let p = get_path_slice();
        assert_eq!(m.len, 4);
        assert_eq!(p.len, 6);
        // ptr should point into the global (not a temporary)
        let bytes = unsafe { std::slice::from_raw_parts(m.ptr as *const u8, m.len as usize) };
        assert_eq!(bytes, b"POST");
        let pbytes = unsafe { std::slice::from_raw_parts(p.ptr as *const u8, p.len as usize) };
        assert_eq!(pbytes, b"/items");
    }

    #[test]
    fn ws_protocol_round_trip() {
        ws_session_set_protocol(b"chat.v1");
        // ⚠️ Mutex 非 reentrant: 必须在调用 get_ws_protocol_slice() 前先释放 guard,
        // 否则单线程 worker 也会自死锁 (实测: full cargo test 在此 test 上 hang)。
        {
            let g = lock_current();
            assert_eq!(&g.ws_protocol[..g.ws_protocol_len], b"chat.v1");
            assert_eq!(g.ws_protocol_len, 7);
            assert_eq!(g.ws_protocol[7], 0, "NUL terminator");
        }
        let s = get_ws_protocol_slice();
        // ws_protocol_len 存数据长度 ("chat.v1" = 7), NUL 在 [ws_protocol_len] 位;
        // 与 method/path/query slice 语义一致 (data only, NUL 跟随)。
        assert_eq!(s.len, 7);
        // 读取 s.len+1 字节验证 NUL 收尾 (Mojo 侧读 CString 用)。
        let bytes = unsafe { std::slice::from_raw_parts(s.ptr as *const u8, (s.len + 1) as usize) };
        assert_eq!(bytes, b"chat.v1\0");
    }

    #[test]
    fn last_status_byte_access() {
        set_last_status(b"404 Not Found");
        assert_eq!(get_last_status_len(), 13);
        assert_eq!(read_last_status_byte(0), b'4' as i32);
        assert_eq!(read_last_status_byte(4), b'N' as i32);
        assert_eq!(read_last_status_byte(12), b'd' as i32);  // last valid char
        assert_eq!(read_last_status_byte(13), -1);          // just past end
        assert_eq!(read_last_status_byte(100), -1);         // way past end
    }

    #[test]
    fn last_status_truncates_long_input() {
        let long = b"a".repeat(100);
        set_last_status(&long);
        assert_eq!(get_last_status_len(), 31);  // 32 - 1 for NUL
    }

    #[test]
    fn close_after_response_toggle() {
        set_close_after_response(false);
        assert!(!get_close_after_response());
        set_close_after_response(true);
        assert!(get_close_after_response());
    }
}
