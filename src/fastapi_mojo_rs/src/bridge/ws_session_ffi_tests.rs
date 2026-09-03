//! ws_session_ffi.rs 单元测试。
//!
//! 真实 socketpair 用于 ws_session_begin / ws_write_text / ws_send_close /
//! ws_write_current (ws.rs 发真实帧); conn 表 + request 全局用于
//! is_ws_upgrade / ws_conn_upgrade / ws_last_opcode / ws_message_done /
//! ws_conn_close 状态迁移。
//!
//! 注意: 本模块操纵**进程全局** conn 表 / request / WS key 缓冲, 必须在
//! `--test-threads=1` 下运行 (CI 与本地统一), 测试间不并行。

use std::os::raw::{c_int, c_void};

use super::conn::{conn_table, ws_events};
use super::request::{self};
use super::ws_session_ffi::*;

extern "C" {
    fn socketpair(domain: c_int, ty: c_int, protocol: c_int, sv: *mut c_int) -> c_int;
    fn recv(fd: c_int, buf: *mut c_void, len: usize, flags: c_int) -> isize;
    fn close(fd: c_int) -> c_int;
}
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;

struct ConnPair {
    a: c_int,
    b: c_int,
}
impl ConnPair {
    fn new() -> ConnPair {
        let mut sv = [0i32; 2];
        assert_eq!(unsafe { socketpair(AF_UNIX, SOCK_STREAM, 0, sv.as_mut_ptr()) }, 0);
        ConnPair { a: sv[0], b: sv[1] }
    }
    fn recv_all(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut buf = [0u8; 8192];
        loop {
            let n = unsafe { recv(self.a, buf.as_mut_ptr() as *mut c_void, buf.len(), 0) };
            if n <= 0 { break; }
            out.extend_from_slice(&buf[..n as usize]);
            if (n as usize) < buf.len() { break; }
        }
        out
    }
}
impl Drop for ConnPair {
    fn drop(&mut self) {
        unsafe { close(self.a); close(self.b); }
    }
}

/// 重置全局 conn 表 (清空所有连接 + active)。
fn lock_table() -> std::sync::MutexGuard<'static, super::conn::ConnTable> {
    conn_table().lock().unwrap_or_else(|e| e.into_inner())
}
fn lock_events() -> std::sync::MutexGuard<'static, super::conn::WsEventQueue> {
    ws_events().lock().unwrap_or_else(|e| e.into_inner())
}
fn reset_global_conn_table() {
    let mut table = lock_table();
    let conns = table.iter_active().map(|(i, _)| i).collect::<Vec<_>>();
    for i in conns {
        table.close(i);
    }
    table.set_active(None);
    // 清 WS 事件队列
    let mut ev = lock_events();
    while ev.pop().is_some() {}
}

/// 构造一个 active conn (fd 为合成值, 不真关), 填入 method/path/hdr。
fn setup_active_conn(fd: i32, method: &[u8], path: &[u8], raw_request: &[u8]) {
    reset_global_conn_table();
    let mut table = lock_table();
    let idx = table.alloc(fd).expect("alloc conn");
    {
        let c = table.get_mut(idx).unwrap();
        // 直接塞 request 原始字节 (含 header), hdr_total = 完整长度
        let n = raw_request.len().min(c.hdr.len());
        c.hdr[..n].copy_from_slice(&raw_request[..n]);
        c.hdr_total = n;
    }
    table.set_active(Some(idx));
    // request 全局 (C 的 g_method / g_path)
    request::set_http_fields(method, path, b"", true, false, fd);
}

const UPGRADE_REQ: &[u8] = b"GET /ws HTTP/1.1\r\n\
Host: localhost\r\n\
Upgrade: websocket\r\n\
Connection: keep-alive, Upgrade\r\n\
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
Sec-WebSocket-Protocol: chat.v1\r\n\
Sec-WebSocket-Version: 13\r\n\
\r\n";

const NON_UPGRADE_REQ: &[u8] = b"GET / HTTP/1.1\r\n\
Host: localhost\r\n\
\r\n";

// ---------- is_ws_upgrade / key / protocol offer ----------

#[test]
fn is_ws_upgrade_accepts_valid_handshake() {
    setup_active_conn(2001, b"GET", b"/ws", UPGRADE_REQ);
    assert_eq!(is_ws_upgrade(), 1);
    // key 已拷入 WS_KEY_BUF
    let s = get_ws_key_slice();
    let key = unsafe { std::slice::from_raw_parts(s.ptr as *const u8, s.len as usize) };
    assert_eq!(key, b"dGhlIHNhbXBsZSBub25jZQ==");
}

#[test]
fn is_ws_upgrade_rejects_non_get() {
    setup_active_conn(2002, b"POST", b"/ws", UPGRADE_REQ);
    assert_eq!(is_ws_upgrade(), 0);
}

#[test]
fn is_ws_upgrade_rejects_plain_http() {
    setup_active_conn(2003, b"GET", b"/", NON_UPGRADE_REQ);
    assert_eq!(is_ws_upgrade(), 0);
}

#[test]
fn is_ws_upgrade_no_active_conn() {
    reset_global_conn_table();
    assert_eq!(is_ws_upgrade(), 0);
}

#[test]
fn get_ws_protocol_offer_reads_header() {
    setup_active_conn(2004, b"GET", b"/ws", UPGRADE_REQ);
    let s = get_ws_protocol_offer_slice();
    let proto = unsafe { std::slice::from_raw_parts(s.ptr as *const u8, s.len as usize) };
    assert_eq!(proto, b"chat.v1");
}

#[test]
fn get_ws_protocol_offer_empty_when_missing() {
    setup_active_conn(2005, b"GET", b"/", NON_UPGRADE_REQ);
    let s = get_ws_protocol_offer_slice();
    let proto = unsafe { std::slice::from_raw_parts(s.ptr as *const u8, s.len as usize) };
    assert_eq!(proto, b"");
}

// ---------- ws_session_begin (真实 101 握手) ----------

#[test]
fn ws_session_begin_sends_101() {
    let cp = ConnPair::new();
    setup_active_conn(cp.b, b"GET", b"/ws", UPGRADE_REQ);
    assert_eq!(is_ws_upgrade(), 1);
    let rc = ws_session_begin("chat.v1");
    assert_eq!(rc, 0);
    let resp = cp.recv_all();
    let head = String::from_utf8_lossy(&resp[..resp.len().min(256)]);
    assert!(head.contains("HTTP/1.1 101 Switching Protocols"), "got: {head}");
    assert!(head.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "got: {head}");
    assert!(head.contains("Sec-WebSocket-Protocol: chat.v1"), "got: {head}");
}

#[test]
fn ws_session_begin_no_active_conn_fails() {
    reset_global_conn_table();
    assert_eq!(ws_session_begin("chat.v1"), 1);
}

// ---------- ws_conn_upgrade / ws_message_done / ws_last_opcode ----------

#[test]
fn ws_conn_upgrade_moves_phase_and_saves_path() {
    setup_active_conn(2010, b"GET", b"/ws/counter", UPGRADE_REQ);
    let mut table = lock_table();
    let idx = table.active().unwrap();
    // 模拟 recv_and_parse 已把 phase 设为 2 (HTTP dispatch)
    table.get_mut(idx).unwrap().phase = 2;
    drop(table);

    let rc = ws_conn_upgrade(2010);
    assert_eq!(rc, 0);
    let table = lock_table();
    let c = table.get(table.active().unwrap()).unwrap();
    assert_eq!(c.phase, 3);
    // ws_path 尾部有 NUL 终止字节 (C: ws_path[pl]=0; Mojo CStringSlice 读到 NUL
    // 为止, 无 NUL 会读越界 — 教训-12). 断言数据部分 == b"/ws/counter" + 尾 NUL.
    assert_eq!(&c.ws_path[..c.ws_path.len() - 1], b"/ws/counter");
    assert_eq!(c.ws_path.last(), Some(&0), "ws_path 必须有 NUL 终止");
    assert_eq!(c.ws_mlen, 0);
    assert_eq!(request::get_ws_event_type(), 0);
}

#[test]
fn ws_conn_upgrade_unknown_fd_fails() {
    setup_active_conn(2011, b"GET", b"/ws", UPGRADE_REQ);
    assert_eq!(ws_conn_upgrade(9999), 1);
}

#[test]
fn ws_message_done_resumes_phase_3() {
    setup_active_conn(2012, b"GET", b"/ws", UPGRADE_REQ);
    // ⚠️ Mutex 非 reentrant: 必须在调用 ws_last_opcode / ws_payload_slice /
    // ws_message_done (它们都会重 lock conn 表) 之前 drop table guard。
    {
        let mut table = lock_table();
        let idx = table.active().unwrap();
        let c = table.get_mut(idx).unwrap();
        c.phase = 4; // dispatch 中
        c.ws_opcode = 1;
        c.ws_mlen = 4;
        c.ws_reasm = b"ping".to_vec();
    }
    // ws_last_opcode 只在 phase 4 返回
    assert_eq!(ws_last_opcode(), 1);
    let payload = ws_payload_slice();
    let bytes = unsafe { std::slice::from_raw_parts(payload.ptr as *const u8, payload.len as usize) };
    assert_eq!(bytes, b"ping");

    ws_message_done(2012);
    {
        let table = lock_table();
        let c = table.get(table.active().unwrap()).unwrap();
        assert_eq!(c.phase, 3);
    }
    assert_eq!(ws_last_opcode(), 0);
}

// ---------- ws_write_text / ws_send_close (真实帧) ----------

#[test]
fn ws_write_text_sends_server_frame() {
    let cp = ConnPair::new();
    let rc = ws_write_text(cp.b, b"hello");
    assert_eq!(rc, 0);
    let raw = cp.recv_all();
    // FIN=1 opcode=1 text, len=5
    assert_eq!(raw[0], 0x81);
    assert_eq!(raw[1], 5);
    assert_eq!(&raw[2..], b"hello");
}

#[test]
fn ws_send_close_sends_close_frame() {
    let cp = ConnPair::new();
    let rc = ws_send_close(cp.b, 1000);
    assert_eq!(rc, 0);
    let raw = cp.recv_all();
    assert_eq!(raw[0], 0x88); // FIN=1 opcode=8 close
    assert_eq!(raw[1], 2);
    assert_eq!(&raw[2..], &[0x03, 0xE8]); // 1000 BE
}

// ---------- ws_conn_close (入队结束事件 + 关闭) ----------

#[test]
fn ws_conn_close_pushes_event_and_releases_conn() {
    setup_active_conn(2020, b"GET", b"/ws", UPGRADE_REQ);
    // 占一个真实 socket 让 close 落到真实 fd 上? 不行 — 合成 fd 由
    // sys_close no-op 处理 (测试隔离), 事件入队即可验证语义。
    ws_conn_close(2020);
    let mut ev = lock_events();
    let e = ev.pop();
    assert_eq!(e, Some((2020, 2)));
    let table = lock_table();
    assert!(table.find(2020).is_none(), "conn 必须已释放");
}

// ---------- get_ws_ping_max (env 一次性解析, 缓存) ----------

#[test]
fn ws_ping_max_env_read_once() {
    // 必须先重置: io_tests 的 check_deadlines_ws_phase_strikes_after_idle
    // 会先调 get_ws_ping_max() 把缓存设成默认 3 (教训-12).
    reset_ws_ping_max_cache_for_test();
    std::env::set_var("FASTAPI_MOJO_WS_PING_MAX", "5");
    assert_eq!(get_ws_ping_max(), 5);
    // 缓存: 改 env 不再生效 (C static int v=-1 同语义)
    std::env::set_var("FASTAPI_MOJO_WS_PING_MAX", "9");
    assert_eq!(get_ws_ping_max(), 5);
    std::env::remove_var("FASTAPI_MOJO_WS_PING_MAX");
    reset_ws_ping_max_cache_for_test();
}
