//! HTTP/2 I/O adapter: preface detection, bounded recv loop, and adapters into
//! the existing HTTP request globals. This keeps the generic poll/I/O module
//! independent of h2 framing details.

use super::conn::Conn;
use super::http2::{H2Connection, H2Request, H2_PHASE, H2_PREFACE};
use super::io::sys_recv;
use super::parse as bridge_parse;
use super::request::{
    set_accepts_gzip, set_cors_pna, set_cors_request, set_http2, set_http_fields, set_range_headers,
};
use super::send::send_all;
use super::time_util::now_ms;

// ========== HTTP/2 prior-knowledge transport (Decision-63) ==========

/// Returns 1 when the connection switched to H2, 0 while the preface is still
/// partial, and -1 for an ordinary HTTP/1.x connection.
pub(crate) fn try_start_h2(c: &mut Conn) -> i32 {
    if c.h2.is_some() {
        return 1;
    }
    if c.hdr_total == 0 {
        return -1; // No bytes yet: enter HTTP/1 recv first; re-detect after recv.
    }
    if c.hdr_total < H2_PREFACE.len() {
        return if c.hdr[..c.hdr_total] == H2_PREFACE[..c.hdr_total] {
            0
        } else {
            set_http2(false);
            return -1;
        };
    }
    if !c.hdr.starts_with(H2_PREFACE) {
        set_http2(false);
        return -1;
    }
    let rx = c.hdr[H2_PREFACE.len()..c.hdr_total].to_vec();
    c.hdr_total = 0;
    c.cl = 0;
    c.body.clear();
    c.body_got = 0;
    c.h2 = Some(H2Connection::new(rx));
    c.phase = H2_PHASE;
    1
}

fn send_h2_control_frames(c: &mut Conn) -> bool {
    let Some(h2) = c.h2.as_mut() else {
        return false;
    };
    let frames = h2.take_frames();
    for frame in frames {
        if send_all(c.fd, &frame) != 0 {
            c.reset_for_close();
            return false;
        }
    }
    true
}

fn set_h2_request_globals(c: &Conn, request: &H2Request) {
    set_http_fields(
        &request.method,
        &request.path,
        &request.query,
        true,
        false,
        c.fd,
    );
    set_accepts_gzip(
        request
            .header_value(b"accept-encoding")
            .is_some_and(bridge_parse::accepts_gzip),
    );
    set_cors_request(
        request.header_value(b"origin"),
        request.header_value(b"access-control-request-method"),
        request.header_value(b"access-control-request-headers"),
    );
    set_cors_pna(request.header_value(b"access-control-request-private-network"));
    set_range_headers(
        request.header_value(b"range"),
        request.header_value(b"if-range"),
    );
}

fn apply_h2_request(c: &mut Conn, request: H2Request) -> i32 {
    if !request.is_multipart_form_data() && !bridge_parse::utf8_valid(&request.body) {
        if let Some(h2) = c.h2.as_mut() {
            h2.enqueue_rst_stream(request.stream_id, 0x0000_0003);
        }
        send_h2_control_frames(c);
        c.reset_for_close();
        return -1;
    }
    set_h2_request_globals(c, &request);
    set_http2(true);
    let body_len = request.body.len();
    c.cl = body_len;
    c.body = request.body;
    c.body.push(0); // FFI NUL termination contract.
    c.body_got = body_len;
    c.phase = 2;
    1
}

pub(crate) fn pump_h2_conn(c: &mut Conn, max_body_size: i32) -> i32 {
    if c.phase == 2 {
        return 0;
    }
    if !send_h2_control_frames(c) {
        return -1;
    }
    if c.h2.as_ref().is_some_and(H2Connection::has_ready) {
        if let Some(h2) = c.h2.as_mut() {
            if let Some(request) = h2.take_ready() {
                return apply_h2_request(c, request);
            }
        }
    }
    let mut buf = [0u8; 16 * 1024];
    let n = sys_recv(c.fd, &mut buf);
    if n == 0 {
        c.reset_for_close();
        return -1;
    }
    if n == -1 {
        return 0;
    }
    let n = n as usize;
    c.first_data_ms = if c.first_data_ms == 0 {
        now_ms() as i64
    } else {
        c.first_data_ms
    };
    c.last_data_ms = now_ms() as i64;
    c.last_active_ms = c.last_data_ms;
    let result = c.h2.as_mut().map_or(Err("http2 connection closed"), |h2| {
        h2.feed(&buf[..n], max_body_size as usize)
    });
    if result.is_err() {
        if let Some(h2) = c.h2.as_mut() {
            h2.enqueue_goaway(0x0000_000a);
        }
        send_h2_control_frames(c);
        return -1;
    }
    if !send_h2_control_frames(c) {
        return -1;
    }
    if c.h2.as_ref().is_some_and(H2Connection::has_ready) {
        if let Some(h2) = c.h2.as_mut() {
            if let Some(request) = h2.take_ready() {
                return apply_h2_request(c, request);
            }
        }
    }
    0
}
