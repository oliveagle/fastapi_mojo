// conn_tests.rs — 连接状态机核心 + 纯解析回归 (ADR-0010 DC2)
use super::conn::parse::*;
use super::conn::*;

// ---------- ConnTable ----------

#[test]
fn table_alloc_and_find() {
    let mut t = ConnTable::new();
    let idx = t.alloc(100).expect("alloc 100");
    assert_eq!(idx, 0);
    assert_eq!(t.find(100), Some(0));
    assert_eq!(t.find(101), None);
    assert_eq!(t.get(idx).unwrap().fd, 100);
    assert!(t.get(idx).unwrap().in_use);
}

#[test]
fn table_alloc_then_close_reuse_slot() {
    let mut t = ConnTable::new();
    let a = t.alloc(101).unwrap();
    let b = t.alloc(102).unwrap();
    assert_ne!(a, b);
    t.close(a);
    // a 槽位被复用 (新 conn fd=103)
    let c = t.alloc(103).unwrap();
    assert_eq!(c, a, "closed slot should be reused");
    assert_eq!(t.find(103), Some(a));
    assert_eq!(t.find(101), None);
    t.close(b);
    t.close(c);
}

#[test]
fn table_close_resets_conn_state() {
    let mut t = ConnTable::new();
    let idx = t.alloc(10).unwrap();
    {
        let c = t.get_mut(idx).unwrap();
        c.hdr_total = 42;
        c.body_got = 7;
    }
    t.close(idx);
    let c = t.get(idx).unwrap();
    assert!(!c.in_use);
    assert_eq!(c.fd, -1);
    assert_eq!(c.phase, 0);
    assert_eq!(c.hdr_total, 0);
    assert_eq!(c.body_got, 0);
    assert_eq!(c.first_data_ms, 0);
    assert_eq!(c.last_data_ms, 0);
    // body/reasm/tail 已清空 (Rust Vec drop = C free)
    assert!(c.body.is_empty());
    assert!(c.ws_reasm.is_empty());
    assert!(c.ws_tail.is_empty());
}

#[test]
fn table_full_alloc_returns_none() {
    let mut t = ConnTable::new();
    // 填满 MAX_CONNS 槽位
    for i in 0..MAX_CONNS {
        assert!(t.alloc((i + 1000) as i32).is_some(), "slot {i} should alloc");
    }
    // 已满 -> None
    assert!(t.alloc(99999).is_none());
    // 释放一个后又能分配
    t.close(0);
    let idx = t.alloc(777).expect("after close should alloc");
    assert_eq!(t.find(777), Some(idx));
}

#[test]
fn table_active_conn_tracking() {
    let mut t = ConnTable::new();
    let a = t.alloc(101).unwrap();
    let b = t.alloc(102).unwrap();
    assert_eq!(t.active(), None);
    t.set_active(Some(b));
    assert_eq!(t.active(), Some(b));
    t.close(a);
    assert_eq!(t.active(), Some(b), "closing non-active should keep active");
    t.close(b);
    assert_eq!(t.active(), None, "closing active clears it");
}

#[test]
fn table_iter_active_only_in_use() {
    let mut t = ConnTable::new();
    let a = t.alloc(101).unwrap();
    let b = t.alloc(102).unwrap();
    t.close(a);
    let actives: Vec<(usize, i32)> = t.iter_active().map(|(i, c)| (i, c.fd)).collect();
    assert_eq!(actives, vec![(b, 102)]);
    t.close(b);
}

// ---------- WsEventQueue ----------

#[test]
fn queue_fifo_order() {
    let mut q = WsEventQueue::new();
    assert!(q.is_empty());
    assert!(q.push(10, WS_EV_MSG));
    assert!(q.push(20, WS_EV_END));
    assert!(!q.is_empty());
    assert_eq!(q.len(), 2);
    assert_eq!(q.pop(), Some((10, WS_EV_MSG)));
    assert_eq!(q.pop(), Some((20, WS_EV_END)));
    assert_eq!(q.pop(), None);
    assert!(q.is_empty());
}

#[test]
fn queue_wraparound() {
    // 填满再逐条 pop, 验证 head 回绕
    let mut q = WsEventQueue::new();
    let n = WS_EV_MAX;
    for i in 0..n {
        assert!(q.push(i as i32, 1), "push {i} should succeed");
    }
    // 溢出 -> false
    assert!(!q.push(9999, 1));
    assert_eq!(q.len(), n);
    // FIFO pop 全部
    for i in 0..n {
        assert_eq!(q.pop(), Some((i as i32, 1)), "pop {i}");
    }
    assert_eq!(q.pop(), None);
    // 回绕后再 push/pop
    assert!(q.push(1, 2));
    assert_eq!(q.pop(), Some((1, 2)));
}

#[test]
fn queue_reuse_after_full_cycle() {
    let mut q = WsEventQueue::new();
    for i in 0..WS_EV_MAX {
        q.push(i as i32, 1);
    }
    for _ in 0..WS_EV_MAX {
        q.pop();
    }
    // 空后再用 (head 已回绕到 0)
    assert!(q.push(5, 2));
    assert_eq!(q.pop(), Some((5, 2)));
}

// ---------- parse_request_line ----------

#[test]
fn rl_basic() {
    let rl = parse_request_line(b"GET /hello HTTP/1.1\r\n").unwrap();
    assert_eq!(rl.method, b"GET");
    assert_eq!(rl.path, b"/hello");
    assert_eq!(rl.query, b"");
    assert!(rl.protocol_11);
}

#[test]
fn rl_http10() {
    let rl = parse_request_line(b"GET / HTTP/1.0\r\n").unwrap();
    assert!(!rl.protocol_11);
}

#[test]
fn rl_with_query() {
    let rl = parse_request_line(b"GET /search?q=rust&p=1 HTTP/1.1\r\n").unwrap();
    assert_eq!(rl.path, b"/search");
    assert_eq!(rl.query, b"q=rust&p=1");
}

#[test]
fn rl_query_only() {
    let rl = parse_request_line(b"POST /x? HTTP/1.1\r\n").unwrap();
    assert_eq!(rl.path, b"/x");
    assert_eq!(rl.query, b"");
}

#[test]
fn rl_lowercase_method_rejected() {
    assert!(parse_request_line(b"get / HTTP/1.1\r\n").is_none());
}

#[test]
fn rl_mixed_case_method_rejected() {
    assert!(parse_request_line(b"GeT / HTTP/1.1\r\n").is_none());
}

#[test]
fn rl_digits_in_method_rejected() {
    assert!(parse_request_line(b"GET1 / HTTP/1.1\r\n").is_none());
}

#[test]
fn rl_empty_path_rejected() {
    assert!(parse_request_line(b"GET  HTTP/1.1\r\n").is_none());
    assert!(parse_request_line(b"GET\r\n").is_none());
}

#[test]
fn rl_bad_proto_rejected() {
    assert!(parse_request_line(b"GET / HTTP/2.0\r\n").is_none());
    assert!(parse_request_line(b"GET / SPAM\r\n").is_none());
    assert!(parse_request_line(b"GET /\r\n").is_none());
}

#[test]
fn rl_path_not_slash_rejected() {
    assert!(parse_request_line(b"GET abc HTTP/1.1\r\n").is_none());
}

// ---------- parse_content_length ----------

#[test]
fn cl_basic() {
    let hdr = b"GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 42\r\n\r\n";
    assert_eq!(parse_content_length(hdr), 42);
}

#[test]
fn cl_absent() {
    let hdr = b"GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    assert_eq!(parse_content_length(hdr), 0);
}

#[test]
fn cl_with_spaces() {
    let hdr = b"Content-Length:   100\r\n\r\n";
    assert_eq!(parse_content_length(hdr), 100);
}

#[test]
fn cl_overflow_guard() {
    // > (MAX_BODY+1)/10 时 -> MAX_BODY+1 (截断防御)
    let big = format!("Content-Length: {}\r\n\r\n", MAX_BODY + 1);
    assert_eq!(parse_content_length(big.as_bytes()), MAX_BODY as i32 + 1);
}

#[test]
fn cl_trailing_garbage_stops() {
    let hdr = b"Content-Length: 12abc\r\n\r\n";
    assert_eq!(parse_content_length(hdr), 12);
}

#[test]
fn cl_negative_ignored() {
    // "-5" 非数字 -> 解析不出, cl=0
    let hdr = b"Content-Length: -5\r\n\r\n";
    assert_eq!(parse_content_length(hdr), 0);
}

// ---------- decide_keepalive ----------

#[test]
fn keepalive_table() {
    use super::parse::ConnDirective as D;
    // HTTP/1.1 default keep, close overrides, keep-alive directive overrides
    assert!(decide_keepalive(true, D::None));
    assert!(!decide_keepalive(true, D::Close));
    assert!(decide_keepalive(true, D::KeepAlive));
    // HTTP/1.0 default close, keep-alive directive enables
    assert!(!decide_keepalive(false, D::None));
    assert!(!decide_keepalive(false, D::Close));
    assert!(decide_keepalive(false, D::KeepAlive));
}

// ---------- finish_header ----------

#[test]
fn fh_no_body_complete() {
    let hdr = b"GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert_eq!(rh.method, b"GET");
    assert_eq!(rh.path, b"/");
    assert!(rh.protocol_11);
    assert!(!rh.close_after_response);
    assert_eq!(rh.content_length, 0);
    assert!(!rh.need_body);
    assert_eq!(rh.body_got, 0);
    assert!(!rh.expect_100);
}

#[test]
fn fh_http10_close() {
    let hdr = b"GET / HTTP/1.0\r\n\r\n";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert!(!rh.protocol_11);
    assert!(rh.close_after_response, "HTTP/1.0 默认 close");
}

#[test]
fn fh_http10_keepalive_directive() {
    let hdr = b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert!(!rh.close_after_response);
}

#[test]
fn fh_http11_connection_close() {
    let hdr = b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert!(rh.close_after_response);
}

#[test]
fn fh_body_in_header() {
    // body 完整在 header 缓冲里 (CL=3, "abc" 紧跟在 \r\n\r\n 后)
    let hdr = b"POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert!(!rh.need_body);
    assert_eq!(rh.body_got, 3);
    assert_eq!(rh.content_length, 3);
}

#[test]
fn fh_body_partial_needs_more() {
    let hdr = b"POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert!(rh.need_body);
    assert_eq!(rh.body_got, 2);
    assert_eq!(rh.content_length, 5);
}

#[test]
fn fh_transfer_encoding_411() {
    let hdr = b"POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    assert_eq!(
        finish_header(hdr, 1024 * 1024).unwrap_err(),
        ("411 Length Required", "Transfer-Encoding not supported; send Content-Length")
    );
}

#[test]
fn fh_payload_too_large_413() {
    let hdr = b"POST /x HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n";
    // max_body_size = 1MB, CL 远大于 -> 413
    assert_eq!(
        finish_header(hdr, 1024 * 1024).unwrap_err(),
        ("413 Payload Too Large", "Request body too large")
    );
}

#[test]
fn fh_body_utf8_invalid_400() {
    let hdr = b"POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\n\xc0\x80";
    assert_eq!(
        finish_header(hdr, 1024 * 1024).unwrap_err(),
        ("400 Bad Request", "Invalid UTF-8 in request body")
    );
}

#[test]
fn fh_malformed_request_line_400() {
    let hdr = b"BLAH\r\n\r\n";
    assert_eq!(
        finish_header(hdr, 1024 * 1024).unwrap_err(),
        ("400 Bad Request", "Malformed request line")
    );
}

#[test]
fn fh_expect_100_with_body() {
    let hdr = b"POST /x HTTP/1.1\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert!(rh.expect_100);
    assert!(rh.need_body);
}

#[test]
fn fh_no_expect_100_when_no_body() {
    let hdr = b"GET /x HTTP/1.1\r\nExpect: 100-continue\r\n\r\n";
    let rh = finish_header(hdr, 1024 * 1024).unwrap();
    assert!(!rh.expect_100, "CL=0 时不发 100-continue");
}

// ---------- check_ws_upgrade ----------

#[test]
fn ws_upgrade_valid() {
    let hdr = b"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    let key = check_ws_upgrade(b"GET", hdr).expect("should upgrade");
    assert_eq!(key, b"dGhlIHNhbXBsZSBub25jZQ==");
}

#[test]
fn ws_upgrade_non_get() {
    let hdr = b"POST /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: abc\r\n\r\n";
    assert!(check_ws_upgrade(b"POST", hdr).is_none());
}

#[test]
fn ws_upgrade_missing_key() {
    let hdr = b"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
    assert!(check_ws_upgrade(b"GET", hdr).is_none());
}

#[test]
fn ws_upgrade_wrong_upgrade_value() {
    let hdr = b"GET /ws HTTP/1.1\r\nUpgrade: h2c\r\nConnection: Upgrade\r\nSec-WebSocket-Key: abc\r\n\r\n";
    assert!(check_ws_upgrade(b"GET", hdr).is_none());
}

#[test]
fn ws_upgrade_connection_no_upgrade_token() {
    let hdr = b"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Key: abc\r\n\r\n";
    assert!(check_ws_upgrade(b"GET", hdr).is_none());
}

#[test]
fn ws_upgrade_case_insensitive_tokens() {
    let hdr = b"GET /ws HTTP/1.1\r\nupgrade: WebSocket\r\nconnection: Upgrade, keep-alive\r\nsec-websocket-key: abc\r\n\r\n";
    let key = check_ws_upgrade(b"GET", hdr);
    assert_eq!(key.as_deref(), Some(&b"abc"[..]));
}

// ---------- get_ws_protocol ----------

#[test]
fn ws_protocol_present() {
    let hdr = b"GET /ws HTTP/1.1\r\nSec-WebSocket-Protocol: chat, superchat\r\n\r\n";
    assert_eq!(get_ws_protocol(hdr), b"chat, superchat");
}

#[test]
fn ws_protocol_absent() {
    let hdr = b"GET /ws HTTP/1.1\r\nHost: a\r\n\r\n";
    assert_eq!(get_ws_protocol(hdr), b"");
}
