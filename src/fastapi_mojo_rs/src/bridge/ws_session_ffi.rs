//! ws_session_ffi.rs — WS 会话 FFI 入口层 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` §1221-1383 (WS 会话 FFI):
//!   - is_ws_upgrade / get_ws_key_slice / get_ws_protocol_slice (offer)
//!   - ws_session_begin (101 握手) / ws_conn_upgrade (phase 0→3)
//!   - ws_event_type / get_ws_path_slice / ws_last_opcode / ws_payload_slice
//!   - ws_write_current / ws_write_text / ws_send_close
//!   - ws_message_done (phase 4→3) / ws_conn_close (入队结束事件 + 关闭)
//!   - get_ws_ping_max (env 一次性解析)
//!
//! 与 C 的差异 (语义等价):
//!   - 全局 `g_ws_key` (256B 栈缓冲) → `WS_KEY_BUF` (Mutex<WsKeyBuf>, 256B);
//!     ptr 在下次 is_ws_upgrade 写入前有效 (C 同样: static buf 复用)。
//!   - `g_ws_event_type` 走 `request::set_ws_event_type`/`get_ws_event_type`
//!     (CurrentRequest 单字段, request.rs 已落地)。
//!   - `g_path` 走 `request::get_path_slice` (request.rs 已落地)。
//!   - `ws_event_push` 走 `ws_events()` (conn.rs 已落地 WsEventQueue)。
//!
//! FFI 包装 (#[no_mangle] extern "C") 待 `bridge.o` 下线时统一加 (与 conn /
//! response / signals 同批, 避免当前 `--whole-archive` 同时链接 C 与 Rust
//! 时的同名符号冲突, 详见 ADR-0010 §3 决策-4)。

use std::os::raw::{c_char, c_int};
use std::sync::{Mutex, OnceLock};

use super::conn::parse::{check_ws_upgrade, get_ws_protocol};
use super::conn::{conn_table, ws_events};
use super::request::{self, CSlice};
use super::time_util::now_ms;

// ========== WS key 临时缓冲 (端口 C g_ws_key[256]) ==========
struct WsKeyBuf {
    data: [u8; 256],
    len: usize,
}
impl WsKeyBuf {
    const fn new() -> Self {
        WsKeyBuf { data: [0u8; 256], len: 0 }
    }
}
static WS_KEY: OnceLock<Mutex<WsKeyBuf>> = OnceLock::new();
fn ws_key_buf() -> &'static Mutex<WsKeyBuf> {
    WS_KEY.get_or_init(|| Mutex::new(WsKeyBuf::new()))
}

/// 1 if active 请求是合法 RFC 6455 upgrade; 端口 C `is_ws_upgrade` (§1223-1246).
/// 副作用: 把 Sec-WebSocket-Key 拷入 WS_KEY_BUF (供 get_ws_key_slice 读)。
pub fn is_ws_upgrade() -> c_int {
    let table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return 0,
    };
    let idx = match table.active() { Some(i) => i, None => return 0 };
    let c = match table.get(idx) {
        Some(c) if c.in_use => c,
        _ => return 0,
    };
    // method 在 request.rs::CurrentRequest (C 的 g_method 全局), 不是 conn 字段
    let method_slice = request::get_method_slice();
    let method_bytes: &[u8] = unsafe {
        std::slice::from_raw_parts(method_slice.ptr as *const u8, method_slice.len as usize)
    };
    if method_bytes != b"GET" {
        return 0;
    }
    let hdr_end = std::cmp::min(c.hdr_total, c.hdr.len());
    let key = match check_ws_upgrade(method_bytes, &c.hdr[..hdr_end]) {
        Some(k) => k,
        None => return 0,
    };
    // 写入 WS_KEY_BUF (受 256B 截断, 与 C g_ws_key 一致)
    let mut kb = ws_key_buf().lock().expect("WS_KEY poisoned");
    let n = key.len().min(kb.data.len());
    kb.data[..n].copy_from_slice(&key[..n]);
    kb.len = n;
    1
}

/// Sec-WebSocket-Key (is_ws_upgrade 之后读); 端口 C `get_ws_key_slice` (§1249-1251).
/// 返回的 CSlice 在下一次 is_ws_upgrade 写入前有效 (C 同样的 static buf 约束)。
pub fn get_ws_key_slice() -> CSlice {
    let kb = ws_key_buf().lock().expect("WS_KEY poisoned");
    CSlice {
        ptr: kb.data.as_ptr() as *const c_char,
        len: kb.len as std::os::raw::c_long,
    }
}

/// Sec-WebSocket-Protocol offer (active conn hdr); 端口 C `get_ws_protocol_slice`
/// (§1257-1269). **与 `request::get_ws_protocol_slice` 不同**: 本函数读 hdr offer
/// (upgrade 前可用); request 版读 `ws_session_set_protocol` 写入的"服务器选中值"。
pub fn get_ws_protocol_offer_slice() -> CSlice {
    // 按需读 active conn hdr (匹配 C: 每次调用都从 active conn hdr 重读,
    // 不在 is_ws_upgrade 缓存)。active conn 不存在或 hdr 未填 -> 空。
    let mut offer = get_protocol_offer_buf().lock().expect("WS_PROTO_OFFER poisoned");
    offer.clear();
    let table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return CSlice { ptr: offer.as_ptr() as *const c_char, len: 0 },
    };
    if let Some(idx) = table.active() {
        if let Some(c) = table.get(idx) {
            if c.in_use {
                let hdr_end = std::cmp::min(c.hdr_total, c.hdr.len());
                let proto = get_ws_protocol(&c.hdr[..hdr_end]);
                offer.extend_from_slice(&proto);
            }
        }
    }
    CSlice {
        ptr: offer.as_ptr() as *const c_char,
        len: offer.len() as std::os::raw::c_long,
    }
}

// get_protocol_offer_buf: 256B 缓冲 + Mutex (与 C `static char proto[256]` 等价)
static PROTO_OFFER: OnceLock<Mutex<Vec<u8>>> = OnceLock::new();
fn get_protocol_offer_buf() -> &'static Mutex<Vec<u8>> {
    PROTO_OFFER.get_or_init(|| Mutex::new(Vec::with_capacity(256)))
}

/// active 连接 101 握手; 端口 C `ws_session_begin` (§1272-1277). 0 = ok.
pub fn ws_session_begin(subprotocol: &str) -> c_int {
    let fd = {
        let table = match conn_table().lock() {
            Ok(g) => g,
            Err(_) => return 1,
        };
        match table.active().and_then(|i| table.get(i)) {
            Some(c) if c.in_use => c.fd,
            _ => return 1,
        }
    };
    // ⚠️ ws_handshake 按 NUL 结尾 C 串读 key (FFI 约定): 必须补 NUL,
    // 否则读到 Vec 末尾之外的内存 (实测 accept 值被污染成 u4FMQqF7...)。
    let key_bytes = {
        let kb = ws_key_buf().lock().expect("WS_KEY poisoned");
        let mut v: Vec<u8> = Vec::with_capacity(kb.len + 1);
        v.extend_from_slice(&kb.data[..kb.len]);
        v.push(0);
        v
    };
    // subprotocol 传 CString (含 NUL), C ws_handshake 用 strlen 读
    let sp_c = std::ffi::CString::new(subprotocol.as_bytes()).unwrap_or_default();
    let rc = crate::ws::ws_handshake(
        fd,
        key_bytes.as_ptr() as *const c_char,
        if sp_c.as_bytes().is_empty() { std::ptr::null() } else { sp_c.as_ptr() },
    );
    if rc == 0 { 0 } else { 1 }
}

/// 移交 active 连接 HTTP→WS (phase 0→3); 端口 C `ws_conn_upgrade` (§1280-1304).
/// 保存 path 供 Mojo 逐消息查 WS 路由; 释放 body; 重置 parser + reasm/tail。
/// 0 = ok, 1 = 找不到 fd.
pub fn ws_conn_upgrade(fd: c_int) -> c_int {
    let mut table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return 1,
    };
    let idx = match table.find(fd) {
        Some(i) => i,
        None => return 1,
    };
    {
        let c = match table.get_mut(idx) {
            Some(c) => c,
            None => return 1,
        };
        c.body.clear();
        c.body_got = 0;
        c.hdr.clear();
        c.hdr_total = 0;
        c.first_data_ms = 0;
        c.par_reset();
        c.ws_opcode = 0;
        c.ws_mlen = 0;
        c.ws_strikes = 0;
        c.ws_tail_len = 0;
        c.last_data_ms = now_ms() as i64;
        c.last_active_ms = now_ms() as i64;
        // copy g_path -> ws_path (Vec::extend_from_slice 自增长; 截断 MAX_PATH)
        let path_slice = request::get_path_slice();
        let n = (path_slice.len as usize).min(1024); // MAX_PATH 上限
        unsafe {
            let src = std::slice::from_raw_parts(path_slice.ptr as *const u8, n);
            c.ws_path.clear();
            c.ws_path.extend_from_slice(src);
        }
        c.phase = 3;
    }
    // g_ws_event_type = 0 (C: g_ws_event_type = 0)
    request::set_ws_event_type(0);
    0
}

/// 最近一次 recv_and_parse 返回 fd 的事件类型 (0=HTTP, 1=WS 数据, 2=WS 结束);
/// 端口 C `ws_event_type` (§1307-1308).
pub fn ws_event_type() -> c_int {
    request::get_ws_event_type() as c_int
}

/// WS 连接 upgrade 时的 path; 端口 C `get_ws_path_slice` (§1311-1315).
pub fn get_ws_path_slice() -> CSlice {
    let table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return CSlice { ptr: std::ptr::null(), len: 0 },
    };
    let idx = match table.active() {
        Some(i) => i,
        None => return CSlice { ptr: std::ptr::null(), len: 0 },
    };
    let c = match table.get(idx) {
        Some(c) => c,
        None => return CSlice { ptr: std::ptr::null(), len: 0 },
    };
    // ws_path 是 Vec<u8>; CSlice 指向其缓冲 (as_ptr 在 Vec 后续 push 时可能 realloc,
    // 调用方须立即消费; 与 C 同样的 "static buf 复用" 约束)。
    CSlice {
        ptr: c.ws_path.as_ptr() as *const c_char,
        len: c.ws_path.len() as std::os::raw::c_long,
    }
}

/// 待处理 WS 消息的 opcode (1=text, 2=binary); 端口 C `ws_last_opcode` (§1318-1321).
pub fn ws_last_opcode() -> c_int {
    let table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return 0,
    };
    let idx = match table.active() {
        Some(i) => i,
        None => return 0,
    };
    match table.get(idx) {
        Some(c) if c.phase == 4 => c.ws_opcode,
        _ => 0,
    }
}

/// 待处理 WS 消息载荷 (NUL 结尾, phase 4 期间稳定); 端口 C `ws_payload_slice` (§1324-1328).
pub fn ws_payload_slice() -> CSlice {
    let table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return CSlice { ptr: std::ptr::null(), len: 0 },
    };
    let idx = match table.active() {
        Some(i) => i,
        None => return CSlice { ptr: std::ptr::null(), len: 0 },
    };
    let c = match table.get(idx) {
        Some(c) if c.phase == 4 => c,
        _ => return CSlice { ptr: std::ptr::null(), len: 0 },
    };
    // ws_reasm 是 Vec<u8>; CSlice 指向其缓冲 (调用方立即消费; 与 C 同约束)。
    // ⚠️ ws_mlen 字节后追加 NUL (reasm 是消息载荷, NUL 收尾; ws.rs::ws_write_message
    // / Mojo CString 读法依赖)。如果 ws_reasm 已含 NUL, 不重复追加 (这里仅在
    // ws_mlen < reasm.len() 时设 NUL)。
    if c.ws_mlen < c.ws_reasm.len() {
        // 借用可变来放 NUL — 不安全 (借 c 后再借用 table): 改用 ptr into bytes。
        // 取只读 ptr 即可: caller 按 ws_mlen 读, ws.rs::ws_write_message 也按
        // plen 读。NUL 收尾由 ws.rs 写入 reasm 时保证 (见 conn::io::pump_ws)。
        // 此处直接返回 (ptr, mlen), 与 C 字节等价 (C 的 ws_reasm 也保证 [mlen]=0)。
    }
    CSlice {
        ptr: c.ws_reasm.as_ptr() as *const c_char,
        len: c.ws_mlen as std::os::raw::c_long,
    }
}

/// 零拷贝 echo: 把待处理消息原样发回; 端口 C `ws_write_current` (§1331-1335).
pub fn ws_write_current(fd: c_int, opcode: c_int) -> c_int {
    let table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return 1,
    };
    let idx = match table.find(fd) {
        Some(i) => i,
        None => return 1,
    };
    let (payload, plen) = match table.get(idx) {
        Some(c) if c.ws_mlen > 0 => (c.ws_reasm.as_ptr(), c.ws_mlen),
        _ => return 1,
    };
    crate::ws::ws_write_message(fd, opcode, payload, plen)
}

/// text 回复; 端口 C `ws_write_text` (§1341-1344). data 不可含 NUL.
pub fn ws_write_text(fd: c_int, data: &[u8]) -> c_int {
    crate::ws::ws_write_message(fd, 1, data.as_ptr(), data.len())
}

/// 服务端 close 帧; 端口 C `ws_send_close` (§1347-1350).
pub fn ws_send_close(fd: c_int, code: c_int) -> c_int {
    let p: [u8; 2] = [(code >> 8) as u8, (code & 0xFF) as u8];
    crate::ws::ws_write_message(fd, 8, p.as_ptr(), 2)
}

/// Mojo 处理完一条消息 (phase 4→3, 恢复 pump); 端口 C `ws_message_done` (§1356-1359).
pub fn ws_message_done(fd: c_int) {
    let mut table = match conn_table().lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if let Some(idx) = table.find(fd) {
        if let Some(c) = table.get_mut(idx) {
            if c.phase == 4 {
                c.phase = 3;
            }
        }
    }
}

/// Mojo 发起结束: 入队结束事件 + 关连接; 端口 C `ws_conn_close` (§1362-1366).
pub fn ws_conn_close(fd: c_int) {
    let idx = {
        let mut table = match conn_table().lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        let idx = match table.find(fd) {
            Some(i) => i,
            None => return,
        };
        // 入队结束事件 (fd, 2)
        ws_events().lock().expect("WS_EVENTS poisoned").push(fd, 2);
        // 关连接
        table.close(idx);
        idx
    };
    let _ = idx;
}

/// FASTAPI_MOJO_WS_PING_MAX (默认 3); 0 = 禁用保活. 端口 C `get_ws_ping_max` (§1369-1382).
/// 一次性解析 + 缓存 (C 用 static int v=-1; 这里用 OnceLock<i32>).
pub fn get_ws_ping_max() -> c_int {
    *WS_PING_MAX.get_or_init(|| {
        let raw = std::env::var("FASTAPI_MOJO_WS_PING_MAX").ok();
        let n = match raw {
            Some(s) if !s.is_empty() => s.parse::<c_int>().unwrap_or(3).max(0),
            _ => 3,
        };
        n
    })
}
static WS_PING_MAX: OnceLock<c_int> = OnceLock::new();
