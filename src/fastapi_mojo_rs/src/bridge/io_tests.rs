//! io.rs 单元测试 — 用真实 socketpair 验证 pump_conn / pump_ws_conn /
//! check_deadlines / conn_done 主体行为等价 C 版.
//!
//! 守则:
//!   - 真 socket syscall (recv/send/poll) 是必要的 (io.rs 写真实 fd).
//!   - `--test-threads=1` (CI/本地统一) 保证全局 conn_table / ws_events
//!     不互相污染.
//!   - 测试用 socketpair 创建 conn fd, 不会撞 libtest 捕获管道.
//!   - sys_close 在测试环境是 no-op (conn::sys_close #[cfg(test)]).
//!   - **作用域规则**: 任何 `let table = conn_table().lock()...` 必须用
//!     `{ ... }` 显式 scope 让 guard 在 reset_all() 前 drop, 否则
//!     reset_all() 二次 lock 会自死锁 (Mutex 非 reentrant).

use std::os::raw::{c_int, c_void};

use super::conn::{
    conn_table, ws_events, MAX_BODY,
    WS_TAIL_MAX, WS_REASM_INIT, WS_EV_MSG, WS_EV_END,
};
use super::io::*;
use crate::bridge::io::pump_ws_conn;
use crate::ws::ws_parser_init;
use super::state::set_max_body_size;

// ---------- 测试用 syscall 直连 ----------
extern "C" {
    fn socketpair(domain: c_int, ty: c_int, protocol: c_int, sv: *mut c_int) -> c_int;
    fn send(fd: c_int, buf: *const c_void, n: usize, flags: c_int) -> isize;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
}
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const O_NONBLOCK: c_int = 0o4000;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;

// ---------- 测试辅助 ----------

/// 一对已连接的 unix socket; 手动 close_pair 清理.
struct ConnPair { a: c_int, b: c_int }

impl ConnPair {
    fn new() -> ConnPair {
        let mut sv = [0i32; 2];
        let rc = unsafe { socketpair(AF_UNIX, SOCK_STREAM, 0, sv.as_mut_ptr()) };
        assert_eq!(rc, 0, "socketpair failed");
        ConnPair { a: sv[0], b: sv[1] }
    }
}

fn close_pair(p: &ConnPair) {
    unsafe { close(p.a); close(p.b); }
}

fn make_nonblock(fd: c_int) {
    unsafe {
        let fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }
}

fn write_b(p: &ConnPair, buf: &[u8]) {
    let n = unsafe { send(p.b, buf.as_ptr() as *const c_void, buf.len(), 0) };
    assert_eq!(n as usize, buf.len(), "send short");
}

/// 全局状态重置. 不持任何 guard.
fn reset_all() {
    clear_listen_fd();
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let n = table.conns_len();
        for i in 0..n {
            table.close(i);
        }
    }
    {
        let mut ev = ws_events().lock().unwrap_or_else(|e| e.into_inner());
        while ev.pop().is_some() {}
    }
    set_max_body_size(1024 * 1024);
}

fn alloc_conn(fd: c_int) -> usize {
    let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
    table.alloc(fd).expect("alloc_conn failed")
}

// ===========================================================================
// pump_conn 测试
// ===========================================================================

#[test]
fn pump_conn_phase0_recv_complete_returns_one() {
    reset_all();
    let p = ConnPair::new();
    let req = b"GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    write_b(&p, req);
    let idx = alloc_conn(p.a);
    let result = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_conn(c, MAX_BODY as i32)
    };
    assert_eq!(result, 1, "complete header should return 1");
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.phase, 2);
        assert_eq!(c.hdr_total, req.len());
    }
    close_pair(&p);
    reset_all();
}

#[test]
fn pump_conn_phase0_partial_recv_returns_zero() {
    reset_all();
    let p = ConnPair::new();
    make_nonblock(p.a);
    let req = b"GET /partial HTTP/1.1\r\nHost: x\r\n";
    write_b(&p, req);
    let idx = alloc_conn(p.a);
    let result = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_conn(c, MAX_BODY as i32)
    };
    assert_eq!(result, 0, "no \r\n\r\n in partial header -> returns 0");
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.phase, 0, "phase should remain 0 (header 不完整)");
        // c.hdr_total 应等于 recv 实际读到的字节数 (≤ req.len())
        // socketpair 可能一次性传递全部 31 字节 — 但因为没 \r\n\r\n 所以返回 0
        assert!(c.hdr_total <= req.len(), "hdr_total 不应超过 req.len()");
        assert!(c.hdr_total > 0, "应读到部分 header");
    }
    close_pair(&p);
    reset_all();
}

#[test]
fn pump_conn_phase0_eof_closes() {
    reset_all();
    let p = ConnPair::new();
    unsafe { close(p.b); }
    let idx = alloc_conn(p.a);
    let result = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_conn(c, MAX_BODY as i32)
    };
    assert_eq!(result, -1, "EOF should close (-1)");
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert!(!c.in_use, "conn should be closed (in_use=false)");
    }
    reset_all();
}

#[test]
fn pump_conn_phase1_recv_body_completes() {
    reset_all();
    let p = ConnPair::new();
    let req = b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    write_b(&p, req);
    let idx = alloc_conn(p.a);
    let result = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_conn(c, MAX_BODY as i32)
    };
    assert_eq!(result, 1, "complete POST should return 1");
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.phase, 2);
        assert_eq!(c.body_got, 5);
        assert_eq!(&c.body[..5], b"hello");
    }
    close_pair(&p);
    reset_all();
}

#[test]
fn pump_conn_phase1_eof_short_body_completes_pre_v11() {
    reset_all();
    let p = ConnPair::new();
    let req = b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\nConnection: close\r\n\r\nhi";
    write_b(&p, req);
    unsafe { close(p.b); }
    let idx = alloc_conn(p.a);
    // 第一次 pump: finish_header -> phase 1 (body 收 2 字节 < 10); 返回 0
    let r1 = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_conn(c, MAX_BODY as i32)
    };
    // 第二次 pump: EOF -> pre-v11 接受短 body, 返回 1
    let r2 = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_conn(c, MAX_BODY as i32)
    };
    assert_eq!(r1, 0, "first pump: body 不足, returns 0");
    assert_eq!(r2, 1, "second pump: EOF 接受短 body, returns 1");
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.phase, 2);
        assert_eq!(c.body_got, 2);
    }
    reset_all();
}

// ===========================================================================
// pump_ws_conn 测试 (调 pub(crate) fn pump_ws_conn 直接)
// ===========================================================================

fn setup_phase3_conn(fd: c_int) -> usize {
    let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
    let idx = table.alloc(fd).unwrap();
    let c = table.get_mut(idx).unwrap();
    c.phase = 3;
    c.ws_tail = vec![0u8; WS_TAIL_MAX];
    c.ws_reasm = vec![0u8; WS_REASM_INIT];
    ws_parser_init(&mut c.ws_par as *mut _);
    idx
}

#[test]
fn pump_ws_conn_text_frame_completes_and_queues() {
    reset_all();
    let p = ConnPair::new();
    make_nonblock(p.a);
    let idx = setup_phase3_conn(p.a);
    // text 帧: FIN=1 opcode=1, MASK=1, len=2, mask_key=0 (payload XOR 0 = 原样)
    let mut frame = vec![0x81u8, 0x82, 0, 0, 0, 0];
    frame.extend_from_slice(b"hi");
    write_b(&p, &frame);
    let result = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_ws_conn(c)
    };
    assert_eq!(result, 0, "data message -> phase 4, returns 0");
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.phase, 4);
        assert_eq!(c.ws_opcode, 1);
        assert_eq!(c.ws_mlen, 2);
        assert_eq!(&c.ws_reasm[..2], b"hi");
    }
    let popped = {
        let mut ev = ws_events().lock().unwrap_or_else(|e| e.into_inner());
        ev.pop()
    };
    assert!(popped.is_some());
    let (fd, ty) = popped.unwrap();
    assert_eq!(fd, p.a);
    assert_eq!(ty, WS_EV_MSG);
    close_pair(&p);
    reset_all();
}

#[test]
fn pump_ws_conn_ping_auto_pong() {
    reset_all();
    let p = ConnPair::new();
    make_nonblock(p.a);
    let idx = setup_phase3_conn(p.a);
    // ping 帧: FIN=1 opcode=9, MASK=1, len=0
    let frame = [0x89u8, 0x80, 0, 0, 0, 0];
    write_b(&p, &frame);
    let result = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_ws_conn(c)
    };
    // ping 自动 pong, 不入队, 继续循环收下一块 (无更多 -> 0)
    assert_eq!(result, 0);
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.phase, 3);
    }
    {
        let mut ev = ws_events().lock().unwrap_or_else(|e| e.into_inner());
        assert!(ev.pop().is_none(), "ping 不入队");
    }
    close_pair(&p);
    reset_all();
}

#[test]
fn pump_ws_conn_close_frame_ends_session() {
    reset_all();
    let p = ConnPair::new();
    make_nonblock(p.a);
    let idx = setup_phase3_conn(p.a);
    // close 帧: FIN=1 opcode=8, MASK=1, len=2, payload=0x03E8 (1000)
    let frame = [0x88u8, 0x82, 0, 0, 0, 0, 0x03, 0xE8];
    write_b(&p, &frame);
    let result = {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        pump_ws_conn(c)
    };
    assert_eq!(result, -1, "close frame ends session");
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert!(!c.in_use);
    }
    let popped = {
        let mut ev = ws_events().lock().unwrap_or_else(|e| e.into_inner());
        ev.pop()
    };
    assert!(popped.is_some());
    let (fd, ty) = popped.unwrap();
    assert_eq!(fd, p.a);
    assert_eq!(ty, WS_EV_END);
    reset_all();
}

// ===========================================================================
// conn_done 测试
// ===========================================================================

#[test]
fn conn_done_reuse_resets_phase_0() {
    reset_all();
    let p = ConnPair::new();
    let idx = alloc_conn(p.a);
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        c.phase = 2;
        c.body = vec![0u8; 10];
        c.body_got = 10;
        c.hdr_total = 100;
        c.first_data_ms = 1;
        c.last_data_ms = 2;
    }
    conn_done(p.a, 1);
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.phase, 0);
        assert_eq!(c.body_got, 0);
        assert_eq!(c.hdr_total, 0);
        assert_eq!(c.first_data_ms, 0);
        assert!(c.last_active_ms > 0);
    }
    close_pair(&p);
    reset_all();
}

#[test]
fn conn_done_no_reuse_closes() {
    reset_all();
    let p = ConnPair::new();
    let idx = alloc_conn(p.a);
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        c.phase = 2;
        c.body = vec![1u8, 2, 3];
        c.body_got = 3;
    }
    conn_done(p.a, 0);
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert!(!c.in_use);
    }
    reset_all();
}

// ===========================================================================
// check_deadlines 测试
// ===========================================================================

#[test]
fn check_deadlines_ws_phase_strikes_after_idle() {
    reset_all();
    let p = ConnPair::new();
    let idx = alloc_conn(p.a);
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        c.phase = 3;
        c.last_data_ms = 1; // 远在过去, 触发 recv_timeout
        c.first_data_ms = 1;
    }
    check_deadlines();
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert_eq!(c.ws_strikes, 1, "ws_strikes 应自增");
        assert!(c.in_use, "ws_ping_max=3 (默认), strike=1 不应 close");
    }
    close_pair(&p);
    reset_all();
}

#[test]
fn check_deadlines_ws_phase_close_after_max_strikes() {
    reset_all();
    let p = ConnPair::new();
    let idx = alloc_conn(p.a);
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        c.phase = 3;
        c.last_data_ms = 1;
        c.first_data_ms = 1;
        c.ws_strikes = 4; // > ping_max(3)
    }
    check_deadlines();
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert!(!c.in_use);
    }
    {
        let mut ev = ws_events().lock().unwrap_or_else(|e| e.into_inner());
        assert!(ev.pop().is_some());
    }
    reset_all();
}

#[test]
fn check_deadlines_http_408_on_recv_timeout() {
    reset_all();
    let p = ConnPair::new();
    let idx = alloc_conn(p.a);
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        c.phase = 0;
        c.first_data_ms = 1;
        c.last_data_ms = 1;
    }
    check_deadlines();
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert!(!c.in_use, "recv_timeout 应 close (408)");
    }
    reset_all();
}

#[test]
fn check_deadlines_idle_keepalive_close() {
    reset_all();
    let p = ConnPair::new();
    let idx = alloc_conn(p.a);
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get_mut(idx).unwrap();
        c.phase = 0;
        c.first_data_ms = 0;
        c.last_active_ms = 1; // 远在过去, idle keepalive 超时
    }
    check_deadlines();
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let c = table.get(idx).unwrap();
        assert!(!c.in_use);
    }
    reset_all();
}

// ===========================================================================
// listen fd + shutdown_all 测试
// ===========================================================================

#[test]
fn get_listen_fd_default_minus_one() {
    reset_all();
    assert_eq!(get_listen_fd(), -1);
    set_listen_fd(12345);
    assert_eq!(get_listen_fd(), 12345);
    clear_listen_fd();
    assert_eq!(get_listen_fd(), -1);
}

#[test]
fn shutdown_all_closes_all_conns_and_listen() {
    reset_all();
    set_listen_fd(99999);
    let p = ConnPair::new();
    let _ = alloc_conn(p.a);
    shutdown_all();
    assert_eq!(get_listen_fd(), -1);
    {
        let table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        for i in 0..table.conns_len() {
            assert!(!table.is_in_use(i), "conn {} 应关", i);
        }
    }
    close_pair(&p);
    reset_all();
}
