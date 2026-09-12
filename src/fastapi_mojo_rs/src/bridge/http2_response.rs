//! HTTP/2 response framing. The transport remains sequential and bounded:
//! middleware/GZip transformations happen in the HTTP response facade, then this
//! module emits literal HPACK headers and <=1MiB DATA payloads with END_STREAM.

use std::os::raw::c_int;

use super::conn::conn_table;
use super::cors;
use super::file_protocol::apply_charset_rule;
use super::hpack::{encode_indexed_name, encode_literal_name};
use super::http2::H2Connection;
use super::http2_frames::{frame, DATA, END_HEADERS, END_STREAM, HEADERS};
use super::request::{current_origin, is_http2, set_last_status};
use super::send::send_all;

const MAX_RESPONSE_BODY: usize = 1024 * 1024;
const RESPONSE_HEADER_MAX: usize = 16 * 1024;

pub fn is_h2(_fd: c_int) -> bool {
    is_http2()
}

pub fn send_response(
    fd: c_int,
    status: &str,
    content_type: &str,
    body: &[u8],
    include_body: bool,
    extra: Option<&str>,
) -> c_int {
    let extra = combined_extra(extra);
    let send_len = usize::from(include_body) * body.len();
    let Some(stream) = reserve_stream(fd, send_len) else {
        return -1;
    };
    let Some(frames) = response_frames(
        stream,
        status,
        content_type,
        Some(body.len()),
        include_body,
        body,
        &extra,
    ) else {
        return -1;
    };
    send_frames(fd, status, &frames)
}

pub fn send_streaming(fd: c_int, status: &str, body: &[u8], media_type: &str, extra: &str) -> c_int {
    let extra = combined_extra(if extra.is_empty() { None } else { Some(extra) });
    let Some(stream) = reserve_stream(fd, body.len()) else {
        return -1;
    };
    let media_type = if media_type.is_empty() {
        None
    } else {
        Some(apply_charset_rule(media_type))
    };
    // 决策-77 (ADR-0052): HEAD → 仅头无体（HEADERS 带 END_STREAM, 无 DATA）。
    let is_head = super::request::current_method_is_head();
    let Some(mut frames) = header_frames(
        stream,
        status,
        media_type.as_deref(),
        None,
        body.is_empty() || is_head,
        &extra,
    ) else {
        return -1;
    };
    if !is_head && !body.is_empty() {
        frames.push(frame(DATA, END_STREAM, stream, body));
    }
    send_frames(fd, status, &frames)
}

/// 决策-73 (ADR-0048): 预检响应 — 直接走 `header_frames`（**不**注入
/// `normal_cors_lines`; 预检头已在 extra 中）; 非空 body → `text/plain;
/// charset=utf-8`（上游 PlainTextResponse）, 空 body (204 通配超集) → 无 CT。
pub fn send_preflight(fd: c_int, status: &str, extra: &str, body: &[u8]) -> c_int {
    let include_body = !body.is_empty();
    let Some(stream) = reserve_stream(fd, body.len()) else {
        return -1;
    };
    let ct = if include_body {
        Some(apply_charset_rule("text/plain"))
    } else {
        None
    };
    let Some(mut frames) = header_frames(
        stream,
        status,
        ct.as_deref(),
        Some(body.len()),
        !include_body,
        extra,
    ) else {
        return -1;
    };
    if include_body {
        frames.push(frame(DATA, END_STREAM, stream, body));
    }
    send_frames(fd, status, &frames)
}

/// 决策-68: RedirectResponse (header-only, 空 body). 无 content-type,
/// `content-length: 0`, 可选 `location` (extra 行), END_STREAM 直接落在 HEADERS.
pub fn send_redirect(fd: c_int, status: &str, extra: &str) -> c_int {
    let extra = combined_extra(if extra.is_empty() { None } else { Some(extra) });
    let Some(stream) = reserve_stream(fd, 0) else {
        return -1;
    };
    let Some(frames) = header_frames(stream, status, None, Some(0), true, &extra) else {
        return -1;
    };
    send_frames(fd, status, &frames)
}

fn reserve_stream(fd: c_int, body_len: usize) -> Option<u32> {
    if body_len > MAX_RESPONSE_BODY {
        return None;
    }
    let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
    let idx = table.find(fd)?;
    let conn = table.get_mut(idx)?;
    let h2: &mut H2Connection = conn.h2.as_mut()?;
    let stream = h2.current_stream()?;
    h2.take_send_window(body_len).then_some(stream)
}

fn combined_extra(extra: Option<&str>) -> String {
    let mut lines = cors::normal_cors_lines(current_origin().as_deref());
    if let Some(value) = extra {
        lines.extend(
            value
                .split("\r\n")
                .filter(|line| !line.is_empty())
                .map(str::to_string),
        );
    }
    lines.join("\r\n")
}

fn status_code(status: &str) -> String {
    status
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_string()
}

fn sanitize_name(name: &str) -> Option<String> {
    let name = name.trim().to_ascii_lowercase();
    (name.len() <= 4096
        && !name.is_empty()
        && !name.starts_with(':')
        && !matches!(
            name.as_str(),
            "connection" | "keep-alive" | "proxy-connection" | "transfer-encoding" | "upgrade"
        ))
    .then_some(name)
}

fn append_header(block: &mut Vec<u8>, indexed_name: Option<usize>, name: &[u8], value: &[u8]) {
    match indexed_name {
        Some(index) => block.extend(encode_indexed_name(index, value)),
        None => block.extend(encode_literal_name(name, value)),
    }
}

fn header_block(
    status: &str,
    content_type: Option<&str>,
    content_length: Option<usize>,
    extra: &str,
) -> Option<Vec<u8>> {
    let mut block = Vec::with_capacity(512);
    append_header(
        &mut block,
        Some(8),
        b":status",
        status_code(status).as_bytes(),
    );
    if let Some(value) = content_type {
        append_header(&mut block, Some(31), b"content-type", value.as_bytes());
    }
    if let Some(length) = content_length {
        append_header(
            &mut block,
            Some(28),
            b"content-length",
            length.to_string().as_bytes(),
        );
    }
    for line in extra.split("\r\n").filter(|line| !line.is_empty()) {
        let (raw_name, value) = line.split_once(':')?;
        let name = sanitize_name(raw_name)?;
        append_header(&mut block, None, name.as_bytes(), value.trim().as_bytes());
    }
    (block.len() <= RESPONSE_HEADER_MAX).then_some(block)
}

fn header_frames(
    stream: u32,
    status: &str,
    content_type: Option<&str>,
    content_length: Option<usize>,
    end_stream: bool,
    extra: &str,
) -> Option<Vec<Vec<u8>>> {
    let block = header_block(status, content_type, content_length, extra)?;
    let flags = if end_stream {
        END_HEADERS | END_STREAM
    } else {
        END_HEADERS
    };
    Some(vec![frame(HEADERS, flags, stream, &block)])
}

pub(crate) fn response_frames(
    stream: u32,
    status: &str,
    content_type: &str,
    content_length: Option<usize>,
    include_body: bool,
    body: &[u8],
    extra: &str,
) -> Option<Vec<Vec<u8>>> {
    let end_headers = !include_body || body.is_empty();
    let mut frames = header_frames(
        stream,
        status,
        Some(content_type),
        content_length,
        end_headers,
        extra,
    )?;
    if include_body && !body.is_empty() {
        let chunks: Vec<_> = body.chunks(16 * 1024).collect();
        for (index, chunk) in chunks.iter().enumerate() {
            let flags = if index + 1 == chunks.len() {
                END_STREAM
            } else {
                0
            };
            frames.push(frame(DATA, flags, stream, chunk));
        }
    }
    Some(frames)
}

fn send_frames(fd: c_int, status: &str, frames: &[Vec<u8>]) -> c_int {
    set_last_status(status.as_bytes());
    if frames.iter().all(|frame| send_all(fd, frame) == 0) {
        0
    } else {
        -1
    }
}
