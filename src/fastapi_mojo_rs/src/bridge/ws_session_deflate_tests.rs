//! RFC 7692 negotiation/send tests. Global table helpers intentionally mirror
//! ws_session_ffi_tests; the suite requires `--test-threads=1`.

use std::os::raw::{c_int, c_void};

use super::conn::conn_table;
use super::request;
use super::ws_session_ffi::{is_ws_upgrade, ws_session_begin, ws_write_text};

extern "C" {
    fn socketpair(domain: c_int, ty: c_int, protocol: c_int, sv: *mut c_int) -> c_int;
    fn recv(fd: c_int, buf: *mut c_void, len: usize, flags: c_int) -> isize;
    fn close(fd: c_int) -> c_int;
}

struct Pair { a: c_int, b: c_int }
impl Pair {
    fn new() -> Self {
        let mut sv = [0, 0];
        assert_eq!(unsafe { socketpair(1, 1, 0, sv.as_mut_ptr()) }, 0);
        Pair { a: sv[0], b: sv[1] }
    }
    fn recv(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        let n = unsafe { recv(self.a, buf.as_mut_ptr() as *mut c_void, buf.len(), 0) };
        if n > 0 { out.extend_from_slice(&buf[..n as usize]); }
        out
    }
}
impl Drop for Pair {
    fn drop(&mut self) { unsafe { close(self.a); close(self.b); } }
}

fn reset_mode() { crate::ws::deflate::reset_ws_deflate_mode_cache_for_test(); }

fn setup(p: &Pair, extension: &str) {
    let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
    let n = table.conns_len();
    for i in 0..n { table.close(i); }
    table.set_active(None);
    let idx = table.alloc(p.b).unwrap();
    let c = table.get_mut(idx).unwrap();
    let req = "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n".to_string();
    let req = if extension.is_empty() {
        req + "\r\n"
    } else {
        req + "Sec-WebSocket-Extensions: " + extension + "\r\n\r\n"
    };
    let n = req.len().min(c.hdr.len());
    c.hdr[..n].copy_from_slice(&req.as_bytes()[..n]);
    c.hdr_total = n;
    table.set_active(Some(idx));
    drop(table);
    request::set_http_fields(b"GET", b"/ws", b"", true, false, p.b);
    assert_eq!(is_ws_upgrade(), 1);
}

#[test]
fn ws_deflate_negotiates_and_compresses_outgoing_text() {
    reset_mode();
    std::env::remove_var("FASTAPI_MOJO_WS_DEFLATE");
    let p = Pair::new();
    setup(&p, "permessage-deflate");
    assert_eq!(ws_session_begin(""), 0);
    let resp = p.recv();
    let text = String::from_utf8_lossy(&resp);
    assert!(text.starts_with("HTTP/1.1 101"));
    assert!(text.contains("Sec-WebSocket-Extensions: permessage-deflate\r\n"));
    {
        let table = conn_table().lock().unwrap();
        let c = table.get(table.active().unwrap()).unwrap();
        assert!(c.ws_deflate);
        assert!(!c.ws_server_no_context_takeover);
        assert!(!c.ws_client_no_context_takeover);
        assert!(c.ws_comp.is_some() && c.ws_decomp.is_some());
    }
    assert_eq!(ws_write_text(p.b, b"deflate-roundtrip"), 0);
    let raw = p.recv();
    assert_eq!(raw[0], 0xC1, "FIN text + RSV1");
    let mut dec = crate::ws::deflate::new_inflater();
    let got = crate::ws::deflate::decompress_message(&mut dec, &raw[2..], false).unwrap();
    assert_eq!(got, b"deflate-roundtrip");
    reset_mode();
}

#[test]
fn ws_deflate_no_context_params_preserve_direction() {
    reset_mode();
    std::env::remove_var("FASTAPI_MOJO_WS_DEFLATE");
    let p = Pair::new();
    setup(&p, "permessage-deflate; server_no_context_takeover; client_no_context_takeover");
    assert_eq!(ws_session_begin(""), 0);
    let raw_resp = p.recv();
    let resp = String::from_utf8_lossy(&raw_resp);
    assert!(resp.contains("server_no_context_takeover"));
    assert!(resp.contains("client_no_context_takeover"));
    let table = conn_table().lock().unwrap();
    let c = table.get(table.active().unwrap()).unwrap();
    assert!(c.ws_server_no_context_takeover);
    assert!(c.ws_client_no_context_takeover);
    reset_mode();
}

#[test]
fn ws_deflate_off_declines_even_when_offered() {
    reset_mode();
    std::env::set_var("FASTAPI_MOJO_WS_DEFLATE", "off");
    let p = Pair::new();
    setup(&p, "permessage-deflate");
    assert_eq!(ws_session_begin(""), 0);
    let raw_resp = p.recv();
    let resp = String::from_utf8_lossy(&raw_resp);
    assert!(!resp.contains("Sec-WebSocket-Extensions"));
    let table = conn_table().lock().unwrap();
    assert!(!table.get(table.active().unwrap()).unwrap().ws_deflate);
    std::env::remove_var("FASTAPI_MOJO_WS_DEFLATE");
    reset_mode();
}

#[test]
fn ws_deflate_required_without_offer_returns_2() {
    reset_mode();
    std::env::set_var("FASTAPI_MOJO_WS_DEFLATE", "required");
    let p = Pair::new();
    setup(&p, "");
    assert_eq!(ws_session_begin(""), 2);
    std::env::remove_var("FASTAPI_MOJO_WS_DEFLATE");
    reset_mode();
}
