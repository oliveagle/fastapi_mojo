//! conn/parse.rs — 请求头纯逻辑解析 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` finish_header (§665-828) 与
//! is_ws_upgrade / get_ws_protocol (§1216-1254) 的**纯解析部分** (无 socket
//! I/O, 可单测)。send_error_json / send_all(100-continue) / close_conn 由
//! 调用方按 `Result` / `RequestHeader.expect_100` 处理。
//!
//! 与 C 行为字节等价 (含 quirk): Content-Length 大小写敏感子串、溢出 guard、
//! keep-alive 决策、WS upgrade 逐位置子串扫描。

use super::super::parse::{
    bounded_strstr, connection_directive, expect_100_continue, find_header_end,
    get_header_value_ci, has_header_name_ci, utf8_valid, ConnDirective,
};
use super::{MAX_BODY, MAX_METHOD, MAX_PATH, MAX_QUERY};

/// 解析后的请求头结果 (端口 C finish_header 产出的全部决策字段).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestHeader {
    pub method: Vec<u8>,
    pub path: Vec<u8>,
    pub query: Vec<u8>,
    pub protocol_11: bool,
    /// true = 响应应宣布 Connection: close (keep-alive 判定).
    pub close_after_response: bool,
    pub content_length: usize,
    /// 需要在读 body 前发 "HTTP/1.1 100 Continue".
    pub expect_100: bool,
    /// true = phase 1 (body 未齐); false = phase 2 (请求完整).
    pub need_body: bool,
    /// 已从 header 缓冲拷贝进 body 的字节数 (<= content_length).
    pub body_got: usize,
}

/// 端口 C `finish_header` (§665-828) 的纯逻辑版.
/// 输入完整 header 字节 (含 \r\n\r\n), 返回 Ok(RequestHeader) 或
/// Err((status, message)) — 后者由调用方 send_error_json + close_conn.
pub fn finish_header(
    hdr: &[u8],
    max_body_size: i32,
) -> Result<RequestHeader, (&'static str, &'static str)> {
    let hdr_end = match find_header_end(hdr) {
        Some(e) => e,
        None => return Err(("400 Bad Request", "Malformed request line")),
    };
    let header = &hdr[..hdr_end];

    // 1) request line
    let rl = match parse_request_line(header) {
        Some(rl) => rl,
        None => return Err(("400 Bad Request", "Malformed request line")),
    };

    // 2b) UTF-8 (method/path/query)
    if !utf8_valid(&rl.method) || !utf8_valid(&rl.path) || !utf8_valid(&rl.query) {
        return Err(("400 Bad Request", "Invalid UTF-8 in request line"));
    }

    // 3) Transfer-Encoding -> 411
    if has_header_name_ci(header, b"Transfer-Encoding") {
        return Err((
            "411 Length Required",
            "Transfer-Encoding not supported; send Content-Length",
        ));
    }

    // 4) Content-Length (cap check + body limit)
    let content_length = parse_content_length(header);
    if content_length as i64 > max_body_size as i64 {
        return Err(("413 Payload Too Large", "Request body too large"));
    }
    let content_length = (content_length as usize).min(MAX_BODY);

    // 5) Expect: 100-continue (content_length > 0 时才可能)
    let expect_100 = content_length > 0 && expect_100_continue(header);

    // 6) keep-alive
    let keep = decide_keepalive(rl.protocol_11, connection_directive(header));

    // 7) body
    let body_in_hdr = hdr.len() - hdr_end;
    if content_length == 0 {
        return Ok(RequestHeader {
            method: rl.method,
            path: rl.path,
            query: rl.query,
            protocol_11: rl.protocol_11,
            close_after_response: !keep,
            content_length: 0,
            expect_100,
            need_body: false,
            body_got: 0,
        });
    }
    let copy = body_in_hdr.min(content_length);
    if copy >= content_length {
        // body 已齐: UTF-8 校验
        let body = &hdr[hdr_end..hdr_end + copy];
        if !utf8_valid(body) {
            return Err(("400 Bad Request", "Invalid UTF-8 in request body"));
        }
        return Ok(RequestHeader {
            method: rl.method,
            path: rl.path,
            query: rl.query,
            protocol_11: rl.protocol_11,
            close_after_response: !keep,
            content_length,
            expect_100,
            need_body: false,
            body_got: copy,
        });
    }
    Ok(RequestHeader {
        method: rl.method,
        path: rl.path,
        query: rl.query,
        protocol_11: rl.protocol_11,
        close_after_response: !keep,
        content_length,
        expect_100,
        need_body: true,
        body_got: copy,
    })
}

/// RequestLine: method / path / query / protocol_11.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestLine {
    pub method: Vec<u8>,
    pub path: Vec<u8>,
    pub query: Vec<u8>,
    pub protocol_11: bool,
}

/// 端口 C finish_header §1-2 的 request-line 解析 + 校验.
/// 非法 (method 非大写 token / path 非 '/' 开头 / 非 HTTP/1.0|1.1) -> None.
pub fn parse_request_line(hdr: &[u8]) -> Option<RequestLine> {
    // METHOD SP PATH SP HTTP/1.x
    let mut i = 0usize;
    let mut method: Vec<u8> = Vec::new();
    while i < hdr.len() && hdr[i] != b' ' && method.len() < MAX_METHOD - 1 {
        method.push(hdr[i]);
        i += 1;
    }
    if i < hdr.len() && hdr[i] == b' ' {
        i += 1;
    }
    let mut path: Vec<u8> = Vec::new();
    while i < hdr.len() && hdr[i] != b' ' && hdr[i] != b'\r' && path.len() < MAX_PATH - 1 {
        path.push(hdr[i]);
        i += 1;
    }
    // query 拆分
    let mut query: Vec<u8> = Vec::new();
    if let Some(q) = path.iter().position(|&b| b == b'?') {
        let _qlen = path.len() - q - 1;
        query = path[q + 1..].to_vec();
        if query.len() >= MAX_QUERY {
            query.truncate(MAX_QUERY - 1);
        }
        path.truncate(q);
    }
    // protocol
    let mut j = i;
    if j < hdr.len() && hdr[j] == b' ' {
        j += 1;
    }
    let mut proto: Vec<u8> = Vec::new();
    while j < hdr.len() && hdr[j] != b'\r' && proto.len() < 15 {
        proto.push(hdr[j]);
        j += 1;
    }
    let protocol_11 = proto == b"HTTP/1.1";
    let ok_method = !method.is_empty()
        && method.len() < MAX_METHOD
        && method.iter().all(|&c| c.is_ascii_uppercase());
    let ok_path = !path.is_empty() && path[0] == b'/';
    let ok_proto = proto == b"HTTP/1.0" || proto == b"HTTP/1.1";
    if !ok_method || !ok_path || !ok_proto {
        return None;
    }
    Some(RequestLine {
        method,
        path,
        query,
        protocol_11,
    })
}

/// 端口 C finish_header §4 的 Content-Length 解析 (大小写敏感子串
/// "Content-Length:", 溢出 guard: > (MAX_BODY+1)/10 -> 置 MAX_BODY+1).
pub fn parse_content_length(hdr: &[u8]) -> i32 {
    let mut cl: i32 = 0;
    if let Some(pos) = bounded_strstr(hdr, b"Content-Length:") {
        let mut i = pos + b"Content-Length:".len();
        while i < hdr.len() && (hdr[i] == b' ' || hdr[i] == b'\t') {
            i += 1;
        }
        while i < hdr.len() && hdr[i].is_ascii_digit() {
            if cl > (MAX_BODY as i32 + 1) / 10 {
                cl = MAX_BODY as i32 + 1;
                break;
            }
            cl = cl.wrapping_mul(10).wrapping_add((hdr[i] - b'0') as i32);
            i += 1;
        }
    }
    cl
}

/// 端口 C finish_header §6 的 keep-alive 决策.
pub fn decide_keepalive(protocol_11: bool, dir: ConnDirective) -> bool {
    let mut keep = protocol_11;
    match dir {
        ConnDirective::Close => keep = false,
        ConnDirective::KeepAlive => keep = true,
        ConnDirective::None => {}
    }
    keep
}

// ========== WS upgrade 检测 (端口 C is_ws_upgrade, §1216-1254) ==========

/// 端口 C `is_ws_upgrade` 的纯逻辑: method == GET, Upgrade: websocket,
/// Connection 含 "upgrade", 非空 Sec-WebSocket-Key. 返回 Some(key) 或 None.
pub fn check_ws_upgrade(method: &[u8], hdr: &[u8]) -> Option<Vec<u8>> {
    if method != b"GET" {
        return None;
    }
    let hdr_end = find_header_end(hdr)?;
    let header = &hdr[..hdr_end];
    let upgrade = get_header_value_ci(header, b"Upgrade")?;
    if !upgrade.eq_ignore_ascii_case(b"websocket") {
        return None;
    }
    let connection = get_header_value_ci(header, b"Connection")?;
    let has_upgrade = connection
        .windows(7)
        .any(|w| w.eq_ignore_ascii_case(b"upgrade"));
    if !has_upgrade {
        return None;
    }
    let key = get_header_value_ci(header, b"Sec-WebSocket-Key")?;
    if key.is_empty() {
        return None;
    }
    Some(key)
}

/// 端口 C `get_ws_protocol_slice` 的纯逻辑: Sec-WebSocket-Protocol offer.
pub fn get_ws_protocol(hdr: &[u8]) -> Vec<u8> {
    if let Some(e) = find_header_end(hdr) {
        get_header_value_ci(&hdr[..e], b"Sec-WebSocket-Protocol").unwrap_or_default()
    } else {
        Vec::new()
    }
}
