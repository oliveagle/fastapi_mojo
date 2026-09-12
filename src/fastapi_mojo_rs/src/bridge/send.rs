//! send.rs — HTTP 响应发送层 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c`:
//!   - `send_all`                §1395-1414 (循环 send 直到写完)
//!   - `send_response`           §1421-1445 (头装配 + last_status 记录 +
//!     keep-alive 读全局; 头/体发送)
//!   - `send_error_json`         §1477-1488 (JSON 错误体, msg/status 转义)
//!   - `send_simple_response`    §1490-1493 (application/json)
//!   - `send_simple_response_allow` §1495-1503 (RFC 7231 Allow 头)
//!   - `send_head_response`      §1505-1508 (仅头无体)
//!   - `send_preflight_response` §1517-1526 (固定 204; 字节串在 response.rs)
//!   - `serve_static_file`       §1530-1582 (realpath 防穿越 + O_NOFOLLOW +
//!     1MB 上限 + Range-free)
//!   - `send_static_file` / `send_static_file_head` §1584-1591
//!   - `send_html_response`      §1600-1604 (text/html)
//!
//! 纯字节组装 (Content-Type 表 / 头装配 / CORS / preflight / JSON 转义) 在
//! `response.rs`; 本模块只做「真实 fd 上的 I/O + 字节搬运」。
//!
//! 与 C 的差异 (语义等价):
//!   - body 用 `&[u8]` 显式长度 (C 用 NUL 结尾 CString); body 可含任意字节。
//!   - `send_error_json` 不截断转义结果 (C 的 json_escape_cstr 在 256B 缓冲
//!     不足时退回 "error"; 实际调用点 msg/status 均 < 128B, 无差异)。
//!   - `serve_static_file` 用 `open + lseek + read` (C 用 fdopen + fseek/
//!     ftell/fread), 语义等价; 读入 `Vec<u8>` RAII 回收, 无 malloc/free。
//!   - 错误码/错误消息/发送顺序与 C 字节一致。

use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_long, c_void};

use super::request::{
    current_accepts_gzip, current_cors_request, current_origin, get_close_after_response,
    set_last_status,
};
use super::http2_response;
use super::cors;
use super::gzip;
use super::middleware;
use super::response::{build_preflight_response, build_response_headers, get_content_type, json_escape};
use super::state::get_static_dir;

// ========== Linux 常量 (端口 C §131-138) ==========
pub const MAX_STATIC_DIR: usize = 256; // 已在 state.rs, 此处引用语义
pub const MAX_FILE_SIZE: i64 = 1024 * 1024; // 1MB max static file (§132)
const RESP_HDR_SIZE: usize = 1024; // response header buffer (§134)
const O_RDONLY: c_int = 0;
const O_NOFOLLOW: c_int = 0o400000; // Linux x86_64 (asm-generic 00400000)
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
const EINTR: c_int = 4;

// ========== 系统调用直连 (零第三方 crate) ==========
extern "C" {
    fn send(fd: c_int, buf: *const c_void, len: usize, flags: c_int) -> isize;
    fn read(fd: c_int, buf: *mut c_void, n: usize) -> isize;
    fn open(path: *const c_char, flags: c_int, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn lseek(fd: c_int, offset: i64, whence: c_int) -> i64;
    fn realpath(path: *const c_char, resolved: *mut c_char) -> *mut c_char;
    fn __errno_location() -> *mut c_int;
}

fn errno() -> c_int {
    unsafe { *__errno_location() }
}

/// 循环 `send(fd, buf[off..])` 直到全部写出 (端口 C `send_all` §1395-1414)。
/// 任一次 `send <= 0` 返回 -1; 成功返回 0。
pub fn send_all(fd: c_int, buf: &[u8]) -> c_int {
    if let Some(result) = super::tls::send_all(fd, buf) {
        return result;
    }
    let mut off = 0usize;
    while off < buf.len() {
        let n = unsafe { send(fd, buf.as_ptr().add(off) as *const c_void, buf.len() - off, 0) };
        if n <= 0 {
            // EINTR 重试 (与 C 不同: C 直接返回 -1; 这里重试更稳, 语义等价)
            if n < 0 && errno() == EINTR {
                continue;
            }
            return -1;
        }
        off += n as usize;
    }
    0
}

/// 发送完整 HTTP 响应 (头 + 可选体), 端口 C `send_response` §1421-1445。
/// `extra` 为无尾 CRLF 的可选额外头行 (如 `Allow: GET, POST`); None 不添加。
/// 发送前把 `status` 记入 last_status (供 /status 路由读)。
///
/// 决策-40 (GZip 中间件, Starlette GZipMiddleware 等价): 满足 gzip 条件
/// (env 启用 + client Accept-Encoding: gzip + 尺寸窗口 + 非 304 + extra
/// 无 Content-Encoding) 时 body 换 gzip 字节并追加 `Content-Encoding: gzip`
/// 头 (Content-Type 不变, Content-Length = 压缩后长度)。
pub fn send_response(
    fd: c_int,
    status: &str,
    content_type: &str,
    body: &[u8],
    include_body: bool,
    extra: Option<&str>,
) -> c_int {
    // 决策-55 (ADR-0030): 用户自定义中间件响应面 — GZip 判定前:
    // 用户 mw 位于固定 GZip/CORS env 层之内; BODY 替换重算 Content-Length
    // (修上游 stale-CL h11 悬机, P-MW-5); 未设 env = 零开销直通.
    let (mw_status, mw_body, mw_extra, mw_ct, mw_log) =
        middleware::apply_response(status, body, extra);
    let status = mw_status.as_str();
    let body = mw_body.as_slice();
    let extra: Option<&str> = if mw_extra.is_empty() {
        None
    } else {
        Some(mw_extra.as_str())
    };
    let content_type = if mw_ct.is_empty() {
        content_type
    } else {
        mw_ct.as_str()
    };
    // 决策-40: GZip 判定 + 压缩 (gzip_result 持有压缩 body 生命期)
    let gzip_result: Option<Vec<u8>> =
        if gzip::should_gzip(
            &gzip::config(),
            body.len(),
            status,
            extra,
            current_accepts_gzip(),
            include_body,
        ) {
            gzip::gzip_compress(body)
        } else {
            None
        };
    // 压缩时追加 Content-Encoding: gzip 行 (与既有 extra 行按 \r\n 合并);
    // 未压缩时原样透传 extra.
    let gzip_extra: Option<String> = gzip_result
        .is_some()
        .then(|| match extra {
            Some(e) => format!("{e}\r\nContent-Encoding: gzip"),
            None => "Content-Encoding: gzip".to_string(),
        });
    let body_out: &[u8] = match &gzip_result {
        Some(c) => c.as_slice(),
        None => body,
    };
    let extra_out: Option<&str> = gzip_extra.as_deref().or(extra);
    if http2_response::is_h2(fd) {
        return http2_response::send_response(
            fd, status, content_type, body_out, include_body, extra_out,
        );
    }
    // ⚠️ get_close_after_response() 返回 "close_after" 语义 (C: g_close_after_response);
    // build_response_headers 的 keep_alive 参数是其**取反**。
    // C 逻辑: `g_close_after_response ? "close" : "keep-alive"`。
    let close_after = get_close_after_response();
    let hdr = build_response_headers(status, content_type, body_out.len(), !close_after, extra_out);
    if hdr.len() >= RESP_HDR_SIZE {
        return -1; // C: hlen >= sizeof hdr -> -1
    }
    set_last_status(status.as_bytes());
    if send_all(fd, &hdr) != 0 {
        return -1;
    }
    if include_body && !body_out.is_empty() && send_all(fd, body_out) != 0 {
        return -1;
    }
    if mw_log {
        middleware::log_line(status);
    }
    0
}

/// JSON 错误响应 `{"error":"..","status":".."}` (端口 C `send_error_json`
/// §1477-1488)。msg/status 经 json_escape 转义, 字节级拼接 (可含非 UTF-8)。
pub fn send_error_json(fd: c_int, status: &str, msg: &str) -> c_long {
    let em = json_escape(msg.as_bytes());
    let es = json_escape(status.as_bytes());
    let mut body: Vec<u8> = Vec::with_capacity(em.len() + es.len() + 32);
    body.extend_from_slice(b"{\"error\":\"");
    body.extend_from_slice(&em);
    body.extend_from_slice(b"\",\"status\":\"");
    body.extend_from_slice(&es);
    body.extend_from_slice(b"\"}");
    send_response(fd, status, "application/json", &body, true, None) as c_long
}

/// 动态 JSON 响应 (端口 C `send_simple_response` §1490-1493)。
pub fn send_simple_response(fd: c_int, status: &str, body: &[u8]) -> c_long {
    send_response(fd, status, "application/json", body, true, None) as c_long
}

/// F6: 纯文本响应 (Content-Type: text/plain; charset=utf-8). Prometheus metrics 用.
pub fn send_text_response(fd: c_int, body: &[u8]) -> c_long {
    send_response(fd, "200 OK", "text/plain; charset=utf-8", body, true, None) as c_long
}

/// ADR-0024 (决策-49): 纯文本响应 + 自定义 status (上游 PlainTextResponse(status_code)
/// parity). 与 send_text_response (200 硬编码, F6 metrics) 同型, 加 status 参数.
/// 用途: 异常类型 handler 的 text/plain 响应 (418/503/... 非 200).
pub fn send_text_response_status(fd: c_int, status: &str, body: &[u8]) -> c_long {
    send_response(fd, status, "text/plain; charset=utf-8", body, true, None) as c_long
}

/// F5: SSE 响应 (Content-Type: text/event-stream; charset=utf-8).
/// 调用方传入完整 SSE body (已按 SSE spec 格式化的多事件串), send_response 一次性发送.
/// 不维护长连接 (避免占 worker; 一次性推送后关 fd).
/// 硬编码 "200 OK" — 对齐 v0.5.0 行为 (上游 FastAPI 0.140.13 之前的 bug).
pub fn send_sse_response(fd: c_int, body: &[u8]) -> c_long {
    send_response(fd, "200 OK", "text/event-stream; charset=utf-8", body, true, None) as c_long
}

/// F9: SSE 响应带自定义状态码 + extra 头 (上游 FastAPI 0.140.13 修复对齐).
/// 上游 bug: SSE/JSONL 端点忽略路由声明的 status_code, 永远返回 200,
/// 与 OpenAPI 文档矛盾. 本函数接受 `status` 字符串 (如 "201 Created") 与
/// extra 头 ("\r\n" 分隔的 "Name: value" 行), 与 `send_simple_response_extra`
/// 同一签名风格.
/// 用例: handler 声明 `data["_stream_status"] = "201 Created"` + 
/// `data["_response_headers"] = "Cache-Control: no-cache"` -> dispatch 走本入口.
/// 同时修复 v0.5.0 的 `_response_headers` 被解析但从未发送的静默丢弃缺陷.
pub fn send_sse_response_extra(fd: c_int, status: &str, body: &[u8], extra: &str) -> c_long {
    let ex = if extra.is_empty() { None } else { Some(extra) };
    send_response(fd, status, "text/event-stream; charset=utf-8", body, true, ex) as c_long
}

/// 决策-48: **StreamingResponse**（真 chunked transfer，starlette 1.6.0 parity，
/// ADR-0023）：
///   - `media_type` 空 → **不带任何 Content-Type 头**（上游 Response.media_type =
///     None 的 quirk，probe S1 实测 headers 空）；非空 → charset 规则（text/*
///     追加 `; charset=utf-8`）
///   - `body` = "|"-分隔 chunk 串（与 SSE `_stream_events` 同约定；空段跳过，
///     与 SSE builder 一致；整体空 = 零 chunk）
///   - 帧形: `hexlen\r\ndata\r\n ... 0\r\n\r\n`（无 content-length；
///     TestClient/httpx 自动解 chunked，真实 socket 可见帧）
///   - GZip 不介入（绕过 send_response 单点 gzip — 上游 GZipMiddleware 会压缩
///     streaming 体，§3.5 文档化偏差）
pub fn send_streaming_response(
    fd: c_int,
    status: &str,
    body: &str,
    media_type: &str,
    extra: &str,
) -> c_long {
    if http2_response::is_h2(fd) {
        return http2_response::send_streaming(fd, status, body, media_type, extra) as c_long;
    }
    let conn = if get_close_after_response() { "close" } else { "keep-alive" };
    let mut h = String::with_capacity(256 + status.len() + media_type.len() + extra.len());
    h.push_str(&format!("HTTP/1.1 {status}\r\n"));
    if !media_type.is_empty() {
        h.push_str(&format!(
            "Content-Type: {}\r\n",
            super::file_protocol::apply_charset_rule(media_type)
        ));
    }
    h.push_str("Transfer-Encoding: chunked\r\n");
    h.push_str(&format!("Connection: {conn}\r\n"));
    for line in cors::normal_cors_lines(current_origin().as_deref()) {
        h.push_str(&line);
        h.push_str("\r\n");
    }
    if !extra.is_empty() {
        h.push_str(extra);
        h.push_str("\r\n");
    }
    h.push_str("\r\n");
    set_last_status(status.as_bytes());
    if send_all(fd, h.as_bytes()) != 0 {
        return -1;
    }
    for part in body.split('|') {
        if part.is_empty() {
            continue;
        }
        let mut chunk = String::with_capacity(part.len() + 16);
        chunk.push_str(&format!("{:x}\r\n", part.len()));
        chunk.push_str(part);
        chunk.push_str("\r\n");
        if send_all(fd, chunk.as_bytes()) != 0 {
            return -1;
        }
    }
    if send_all(fd, b"0\r\n\r\n") != 0 {
        return -1;
    }
    0
}

/// 决策-68 (ADR-0043): 上游 Starlette `RedirectResponse` 的 URL 百分号编码.
///
/// Starlette: `quote(str(url), safe=":/%#?=@[]!$&'()*+,;")` — safe set 之外的
/// 字节按 UTF-8 byte 编成 `%XX` (大写 hex); `urllib.parse.quote` 恒安全集
/// (alnum + `_.-~`) 亦保留。实测: `"/p a th?x=1&y=2#frag"` ->
/// `"/p%20a%20th?x=1&y=2#frag"`。
pub fn redirect_quote(url: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(url.len());
    for &b in url.as_bytes() {
        let safe = matches!(b,
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
            | b'_' | b'.' | b'-' | b'~'
            | b':' | b'/' | b'%' | b'#' | b'?' | b'=' | b'@'
            | b'[' | b']' | b'!' | b'$' | b'&' | b'\'' | b'(' | b')'
            | b'*' | b'+' | b',' | b';');
        if safe {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0f) as usize] as char);
        }
    }
    out
}

/// 决策-68: RedirectResponse 头装配 (纯函数, 便于单测).
///
/// 上游 Starlette `RedirectResponse` (media_type=None): **无 Content-Type**,
/// `Content-Length: 0`, `Location: <url>`, 空 body。`location` 应已由
/// `redirect_quote` 编码; CORS 行由调用方给出 (读请求全局)。
pub fn build_redirect_headers(
    status: &str,
    location: &str,
    keep_alive: bool,
    cors_lines: &[String],
) -> Vec<u8> {
    let conn = if keep_alive { "keep-alive" } else { "close" };
    let mut s = String::with_capacity(128 + status.len() + location.len());
    s.push_str("HTTP/1.1 ");
    s.push_str(status);
    s.push_str("\r\nContent-Length: 0\r\nConnection: ");
    s.push_str(conn);
    s.push_str("\r\n");
    for line in cors_lines {
        s.push_str(line);
        s.push_str("\r\n");
    }
    if !location.is_empty() {
        s.push_str("Location: ");
        s.push_str(location);
        s.push_str("\r\n");
    }
    s.push_str("\r\n");
    s.into_bytes()
}

/// 决策-68 (ADR-0043): RedirectResponse (307/303/301/308) — 空 body +
/// `Content-Length: 0` + `Location` 头, 无 Content-Type (上游 media_type=None
/// quirk)。location 按上游 safe set 百分号编码; HTTP/2 走 header-only 帧。
pub fn send_redirect_response(fd: c_int, status: &str, location: &str) -> c_long {
    let location = redirect_quote(location);
    if http2_response::is_h2(fd) {
        let extra = if location.is_empty() {
            String::new()
        } else {
            format!("Location: {location}")
        };
        return http2_response::send_redirect(fd, status, &extra) as c_long;
    }
    let cors_lines = cors::normal_cors_lines(current_origin().as_deref());
    let hdr = build_redirect_headers(status, &location, !get_close_after_response(), &cors_lines);
    set_last_status(status.as_bytes());
    if send_all(fd, &hdr) != 0 {
        return -1;
    }
    0
}

/// F3b: JSON 响应携带自定义头 (端口 C `send_simple_response` 变体).
/// extra 为 "\r\n" 分隔的 "Name: value" 行, 末尾不带 CRLF (build_response_headers 内部追加).
/// 空 extra -> 与 send_simple_response 等价.
pub fn send_simple_response_extra(fd: c_int, status: &str, body: &[u8], extra: &str) -> c_long {
    let ex = if extra.is_empty() { None } else { Some(extra) };
    send_response(fd, status, "application/json", body, true, ex) as c_long
}

/// 405 响应携带 RFC 7231 Allow 头 (端口 C `send_simple_response_allow`
/// §1495-1503)。C 用 256B 缓冲截断 Allow; 实际方法串 < 255B, format! 不截断
/// 亦等价。
pub fn send_simple_response_allow(fd: c_int, status: &str, body: &[u8], allow: &str) -> c_long {
    let extra = format!("Allow: {}", allow);
    send_response(fd, status, "application/json", body, true, Some(&extra)) as c_long
}

/// HEAD: 仅头无体 (端口 C `send_head_response` §1505-1508)。
pub fn send_head_response(fd: c_int, status: &str, body: &[u8]) -> c_long {
    send_response(fd, status, "application/json", body, false, None) as c_long
}

/// OPTIONS 预检 (端口 C `send_preflight_response` §1517-1526, 字节串在
/// response.rs::build_preflight_response)。
pub fn send_preflight_response(fd: c_int) -> c_long {
    if http2_response::is_h2(fd) {
        let (acrm, achr) = current_cors_request();
        let (status, lines, err) = cors::preflight_build(
            current_origin().as_deref(), acrm.as_deref(), achr.as_deref(),
        );
        let body = err.map(|message| {
            let escaped = String::from_utf8_lossy(&json_escape(message.as_bytes())).into_owned();
            format!("{{\"error\":\"{escaped}\",\"status\":\"{status}\"}}").into_bytes()
        });
        return http2_response::send_preflight(
            fd, status, &lines.join("\r\n"), body.as_deref().unwrap_or_default(),
        ) as c_long;
    }
    let resp = build_preflight_response();
    send_all(fd, &resp) as c_long
}

/// 原始 HTML 响应 (端口 C `send_html_response` §1600-1604)。
pub fn send_html_response(fd: c_int, status: &str, body: &[u8]) -> c_long {
    send_response(fd, status, "text/html; charset=utf-8", body, true, None) as c_long
}

/// 静态文件服务 (GET/HEAD 共享), 端口 C `serve_static_file` §1530-1582。
///
/// 安全 (与 C 一致):
///   1. realpath(static_dir) 与 realpath(full_path) 解析;
///   2. 要求解析后的候选路径前缀 == 解析后的静态目录, 且下一个字符是 `/`
///      或 `\0` (防目录穿越 + symlink 逃逸);
///   3. `open(O_RDONLY | O_NOFOLLOW)` (TOCTOU 加固, 拒绝 symlink 最后一跳);
///   4. 文件大小上限 1MB (413); 失败路径错误码/消息与 C 逐字节一致。
fn serve_static_file(fd: c_int, path: &str, include_body: bool) -> c_long {
    let static_dir = get_static_dir();
    let full_path = if path == "/" {
        format!("{}/index.html", static_dir)
    } else {
        format!("{}{}", static_dir, path)
    };

    let dir_c = match std::ffi::CString::new(static_dir.as_bytes()) {
        Ok(c) => c,
        Err(_) => return send_error_json(fd, "404 Not Found", "Not Found"),
    };
    let path_c = match std::ffi::CString::new(full_path.as_bytes()) {
        Ok(c) => c,
        Err(_) => return send_error_json(fd, "404 Not Found", "Not Found"),
    };

    // realpath 两个候选; 失败 -> 404 (与 C 一致)
    let mut dir_buf = [0i8; 4096]; // PATH_MAX
    let mut path_buf = [0i8; 4096];
    let rdir = unsafe { realpath(dir_c.as_ptr(), dir_buf.as_mut_ptr()) };
    if rdir.is_null() {
        return send_error_json(fd, "404 Not Found", "Not Found");
    }
    let rpath = unsafe { realpath(path_c.as_ptr(), path_buf.as_mut_ptr()) };
    if rpath.is_null() {
        return send_error_json(fd, "404 Not Found", "Not Found");
    }
    let resolved_dir = unsafe { CStr::from_ptr(rdir) }.to_bytes();
    let resolved_path = unsafe { CStr::from_ptr(rpath) }.to_bytes();

    // 前缀包含检查: resolved_path 必须以 resolved_dir 开头, 且下一字节为
    // '/' 或 '\0' (防止 /static2 逃逸)。
    let dlen = resolved_dir.len();
    if resolved_path.len() < dlen
        || &resolved_path[..dlen] != resolved_dir
        || (resolved_path.get(dlen) != Some(&b'/') && resolved_path.len() != dlen)
    {
        return send_error_json(fd, "403 Forbidden", "Forbidden");
    }

    // open(O_RDONLY | O_NOFOLLOW); <0 -> 403 (与 C 一致)
    let ffd = unsafe { open(rpath, O_RDONLY | O_NOFOLLOW) };
    if ffd < 0 {
        return send_error_json(fd, "403 Forbidden", "Forbidden");
    }

    // 文件大小: lseek(END) -> 大小 -> lseek(SET) 复位 (等价 C fseek/ftell)
    let size = unsafe { lseek(ffd, 0, SEEK_END) };
    if size < 0 {
        unsafe { close(ffd) };
        return send_error_json(fd, "404 Not Found", "Not Found");
    }
    unsafe { lseek(ffd, 0, SEEK_SET) };
    if size > MAX_FILE_SIZE {
        unsafe { close(ffd) };
        return send_error_json(fd, "413 Payload Too Large", "File too large");
    }

    // 读入 Vec (RAII, 无手工 free)。
    // ⚠️ 陷阱: `Vec::with_capacity(n)` 的 len 为 0, `content[0..]` 切出空切片,
    // read 得到 0 长度 -> 读到空文件。必须先用 `vec![0u8; size]` 占位 (len=size)。
    let mut content: Vec<u8> = vec![0u8; size as usize];
    let mut used = 0usize;
    loop {
        let chunk = &mut content[used..];
        if chunk.is_empty() {
            break;
        }
        let n = unsafe { read(ffd, chunk.as_mut_ptr() as *mut c_void, chunk.len()) };
        if n < 0 {
            if errno() == EINTR {
                continue;
            }
            unsafe { close(ffd) };
            return send_error_json(fd, "404 Not Found", "Not Found");
        }
        if n == 0 {
            break; // EOF
        }
        used += n as usize;
    }
    unsafe { close(ffd) };
    content.truncate(used);

    let ctype = get_content_type(&String::from_utf8_lossy(resolved_path));
    send_response(fd, "200 OK", ctype, &content, include_body, None) as c_long
}

/// GET 静态文件 (端口 C `send_static_file` §1584-1586)。
pub fn send_static_file(fd: c_int, path: &str) -> c_long {
    serve_static_file(fd, path, true)
}

/// HEAD 静态文件 (端口 C `send_static_file_head` §1588-1590)。
pub fn send_static_file_head(fd: c_int, path: &str) -> c_long {
    serve_static_file(fd, path, false)
}
