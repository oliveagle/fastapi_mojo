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

use super::request::{get_close_after_response, set_last_status};
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
pub fn send_response(
    fd: c_int,
    status: &str,
    content_type: &str,
    body: &[u8],
    include_body: bool,
    extra: Option<&str>,
) -> c_int {
    // ⚠️ get_close_after_response() 返回 "close_after" 语义 (C: g_close_after_response);
    // build_response_headers 的 keep_alive 参数是其**取反**。
    // C 逻辑: `g_close_after_response ? "close" : "keep-alive"`。
    let close_after = get_close_after_response();
    let hdr = build_response_headers(status, content_type, body.len(), !close_after, extra);
    if hdr.len() >= RESP_HDR_SIZE {
        return -1; // C: hlen >= sizeof hdr -> -1
    }
    set_last_status(status.as_bytes());
    if send_all(fd, &hdr) != 0 {
        return -1;
    }
    if include_body && !body.is_empty() && send_all(fd, body) != 0 {
        return -1;
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

/// F5: SSE 响应 (Content-Type: text/event-stream; charset=utf-8).
/// 调用方传入完整 SSE body (已按 SSE spec 格式化的多事件串), send_response 一次性发送.
/// 不维护长连接 (避免占 worker; 一次性推送后关 fd).
pub fn send_sse_response(fd: c_int, body: &[u8]) -> c_long {
    send_response(fd, "200 OK", "text/event-stream; charset=utf-8", body, true, None) as c_long
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
