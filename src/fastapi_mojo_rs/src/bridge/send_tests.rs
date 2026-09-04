//! send.rs 单元测试 — 用真实 socketpair 验证响应字节 + 静态文件安全语义。
//!
//! 守则:
//!   - 真 socket syscall (send/recv) 在本测试是必需的 (send_all 写真实 fd);
//!     与 signals_tests 真信号、cmd_tests 真 fork 同一类「受控真系统调用」。
//!   - `--test-threads=1` (CI/本地统一) 保证 env 全局副作用不互相污染。
//!   - 静态文件测试: 显式 remove_var FASTAPI_MOJO_STATIC_DIR + 临时目录,
//!     测完清理并恢复旧值 (不污染后续 state_tests)。

use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering};

use super::request::{get_last_status_len, read_last_status_byte};
use super::send::*;
use super::state::set_static_dir;

// ---------- 测试用 syscall 直连 ----------
extern "C" {
    fn socketpair(domain: c_int, ty: c_int, protocol: c_int, sv: *mut c_int) -> c_int;
    fn recv(fd: c_int, buf: *mut c_void, len: usize, flags: c_int) -> isize;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
}
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const O_NONBLOCK: c_int = 0o4000;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;

/// 一对已连接的 socket; drop 时关闭两端。
struct ConnPair {
    a: c_int,
    b: c_int,
}
impl ConnPair {
    fn new() -> ConnPair {
        let mut sv = [0i32; 2];
        let rc = unsafe { socketpair(AF_UNIX, SOCK_STREAM, 0, sv.as_mut_ptr()) };
        assert_eq!(rc, 0, "socketpair failed");
        ConnPair { a: sv[0], b: sv[1] }
    }
    /// a 端设为非阻塞 (便于 recv 探测边界)。
    fn make_a_nonblock(&mut self) {
        unsafe {
            let fl = fcntl(self.a, F_GETFL, 0);
            fcntl(self.a, F_SETFL, fl | O_NONBLOCK);
        }
    }
}
impl Drop for ConnPair {
    fn drop(&mut self) {
        unsafe {
            close(self.a);
            close(self.b);
        }
    }
}

/// 从 a 端读完当前所有可用字节 (非阻塞循环直到 EAGAIN)。
fn recv_all(cp: &mut ConnPair) -> Vec<u8> {
    cp.make_a_nonblock();
    let mut out = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = unsafe { recv(cp.a, buf.as_mut_ptr() as *mut c_void, buf.len(), 0) };
        if n <= 0 {
            break; // n<0: EAGAIN; n==0: EOF (对本测试不会出现)
        }
        out.extend_from_slice(&buf[..n as usize]);
        if (n as usize) < buf.len() {
            break; // 已排空内核缓冲
        }
    }
    out
}

fn body_after_headers(resp: &[u8]) -> &[u8] {
    let idx = find_blank_line(resp);
    &resp[idx..]
}

fn find_blank_line(resp: &[u8]) -> usize {
    resp.windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(resp.len())
}

/// last_status 被 send_response 更新 (供 /status 路由读)。
fn assert_last_status(status: &str) {
    let n = status.len();
    assert_eq!(get_last_status_len(), n, "last_status_len mismatch");
    for (i, &b) in status.as_bytes().iter().enumerate() {
        assert_eq!(read_last_status_byte(i), b as i32, "byte {i}");
    }
    assert_eq!(read_last_status_byte(n), -1, "OOB must be -1");
}

// ---------- send_all / send_response ----------

#[test]
fn send_all_writes_entire_payload() {
    let mut cp = ConnPair::new();
    let payload: Vec<u8> = (0..20000u32).map(|i| (i % 251) as u8).collect();
    assert_eq!(send_all(cp.b, &payload), 0);
    let got = recv_all(&mut cp);
    assert_eq!(got.len(), payload.len());
    assert_eq!(got, payload);
}

#[test]
fn send_response_keepalive_true() {
    let mut cp = ConnPair::new();
    super::request::set_close_after_response(false);
    let rc = send_response(cp.b, "200 OK", "text/plain", b"hello", true, None);
    assert_eq!(rc, 0);
    assert_last_status("200 OK");
    let resp = recv_all(&mut cp);
    let head = &resp[..find_blank_line(&resp)];
    let hs = String::from_utf8_lossy(head);
    assert!(hs.starts_with("HTTP/1.1 200 OK\r\n"));
    assert!(hs.contains("Content-Type: text/plain\r\n"));
    assert!(hs.contains("Content-Length: 5\r\n"));
    assert!(hs.contains("Connection: keep-alive\r\n"));
    assert!(hs.contains("Access-Control-Allow-Origin: *\r\n"));
    assert_eq!(body_after_headers(&resp), b"hello");
}

#[test]
fn send_response_keepalive_false_and_extra() {
    let mut cp = ConnPair::new();
    super::request::set_close_after_response(true);
    let rc = send_response(cp.b, "405 Method Not Allowed", "application/json", b"{}", true, Some("Allow: GET, POST"));
    let resp = recv_all(&mut cp);
    assert_eq!(rc, 0);
    assert_last_status("405 Method Not Allowed");
    let hs = String::from_utf8_lossy(&resp);
    assert!(hs.contains("Connection: close\r\n"));
    assert!(hs.contains("Allow: GET, POST\r\n"));
    // ✅ 修复 (2026-09-04): extra 行后必须有空行 `\r\n\r\n` 终止 header 段.
    // 旧实现: extra 收尾只一个 CRLF, body 直接接在 Allow 行末 CRLF 之后 (缺空行),
    // 导致接收方按 Content-Length 等待 body 永远不达 (实测 405/自定义头 body hang).
    // 新行为: CORS + extra 行 + 收尾 CRLF + 空行 CRLF + body, 与 RFC 9112 一致.
    assert!(hs.ends_with("Allow: GET, POST\r\n\r\n{}"), "extra 头后必须有空行, body 才能送达");
}

#[test]
fn send_head_response_has_no_body() {
    let mut cp = ConnPair::new();
    let rc = send_head_response(cp.b, "200 OK", b"should-not-appear");
    assert_eq!(rc, 0);
    let resp = recv_all(&mut cp);
    let idx = find_blank_line(&resp);
    assert_eq!(&resp[idx..], b"", "HEAD must not carry body");
    let head = String::from_utf8_lossy(&resp[..idx]);
    assert!(head.contains("Content-Length: 17"));
}

// ---------- JSON 错误 / 简单 / 预检 / HTML ----------

#[test]
fn send_error_json_escapes_and_builds_body() {
    let mut cp = ConnPair::new();
    let rc = send_error_json(cp.b, "400 Bad Request", "bad \"quote\"\nline");
    assert_eq!(rc, 0);
    assert_last_status("400 Bad Request");
    let resp = recv_all(&mut cp);
    let idx = find_blank_line(&resp);
    let head = String::from_utf8_lossy(&resp[..idx]);
    assert!(head.contains("Content-Type: application/json\r\n"));
    let body = String::from_utf8_lossy(&resp[idx..]);
    assert_eq!(body, "{\"error\":\"bad \\\"quote\\\"\\nline\",\"status\":\"400 Bad Request\"}");
}

#[test]
fn send_simple_response_and_html() {
    let mut cp = ConnPair::new();
    assert_eq!(send_simple_response(cp.b, "200 OK", b"{\"ok\":true}"), 0);
    let resp = recv_all(&mut cp);
    let head = String::from_utf8_lossy(&resp[..find_blank_line(&resp)]);
    assert!(head.contains("Content-Type: application/json\r\n"));
    assert_eq!(body_after_headers(&resp), b"{\"ok\":true}");

    assert_eq!(send_html_response(cp.b, "200 OK", b"<h1>hi</h1>"), 0);
    let resp = recv_all(&mut cp);
    let head = String::from_utf8_lossy(&resp[..find_blank_line(&resp)]);
    assert!(head.contains("Content-Type: text/html; charset=utf-8\r\n"));
    assert_eq!(body_after_headers(&resp), b"<h1>hi</h1>");
}

#[test]
fn send_preflight_response_exact_bytes() {
    let mut cp = ConnPair::new();
    let rc = send_preflight_response(cp.b);
    assert_eq!(rc, 0);
    let resp = recv_all(&mut cp);
    let expected = super::response::build_preflight_response();
    assert_eq!(resp, expected);
}

// ---------- 静态文件 (安全语义) ----------

/// 建临时静态目录 (含 index.html + hello.txt), 返回 (dir, cleanup flag)。
/// 用全局静态目录状态, 测完恢复; 由本文件顶部的 env 清理保证不污染。
static CLEANUP_NEEDED: AtomicBool = AtomicBool::new(false);

fn setup_static_dir() -> std::path::PathBuf {
    // 显式清除 env 覆盖, 保证 set_static_dir(Some(dir)) 生效
    std::env::remove_var("FASTAPI_MOJO_STATIC_DIR");
    let dir = std::env::temp_dir().join(format!("fm_rs_send_tests_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("index.html"), b"<h1>static</h1>").unwrap();
    std::fs::write(dir.join("hello.txt"), b"hello static").unwrap();
    set_static_dir(Some(dir.to_str().unwrap()));
    CLEANUP_NEEDED.store(true, Ordering::SeqCst);
    dir
}

fn teardown_static_dir(dir: &std::path::PathBuf) {
    let _ = std::fs::remove_dir_all(dir);
    CLEANUP_NEEDED.store(false, Ordering::SeqCst);
}

#[test]
fn static_file_serves_root_index() {
    let dir = setup_static_dir();
    let mut cp = ConnPair::new();
    let rc = send_static_file(cp.b, "/");
    let resp = recv_all(&mut cp);
    assert_eq!(rc, 0);
    assert_last_status("200 OK");
    let head = String::from_utf8_lossy(&resp[..find_blank_line(&resp)]);
    assert!(head.contains("Content-Type: text/html\r\n"));
    assert_eq!(body_after_headers(&resp), b"<h1>static</h1>");
    teardown_static_dir(&dir);
}

#[test]
fn static_file_serves_named_file() {
    let dir = setup_static_dir();
    let mut cp = ConnPair::new();
    let rc = send_static_file(cp.b, "/hello.txt");
    assert_eq!(rc, 0);
    let resp = recv_all(&mut cp);
    let head = String::from_utf8_lossy(&resp[..find_blank_line(&resp)]);
    assert!(head.contains("Content-Type: text/plain\r\n"));
    assert_eq!(body_after_headers(&resp), b"hello static");
    teardown_static_dir(&dir);
}

#[test]
fn static_file_head_omits_body() {
    let dir = setup_static_dir();
    let mut cp = ConnPair::new();
    let rc = send_static_file_head(cp.b, "/hello.txt");
    assert_eq!(rc, 0);
    let resp = recv_all(&mut cp);
    let idx = find_blank_line(&resp);
    assert_eq!(&resp[idx..], b"", "HEAD static must not carry body");
    teardown_static_dir(&dir);
}

#[test]
fn static_file_missing_returns_404() {
    let dir = setup_static_dir();
    let mut cp = ConnPair::new();
    let rc = send_static_file(cp.b, "/nope.txt");
    assert_eq!(rc, 0);
    assert_last_status("404 Not Found");
    let resp = recv_all(&mut cp);
    let body = String::from_utf8_lossy(body_after_headers(&resp));
    assert!(body.contains("\"status\":\"404 Not Found\""));
    teardown_static_dir(&dir);
}

#[test]
fn static_file_traversal_returns_403() {
    let dir = setup_static_dir();
    let mut cp = ConnPair::new();
    // ../ 逃逸: realpath 后不在 static dir 内 -> 403 Forbidden
    let rc = send_static_file(cp.b, "/../../etc/passwd");
    assert_eq!(rc, 0);
    assert_last_status("403 Forbidden");
    let resp = recv_all(&mut cp);
    let body = String::from_utf8_lossy(body_after_headers(&resp));
    assert!(body.contains("\"status\":\"403 Forbidden\""));
    teardown_static_dir(&dir);
}

#[test]
fn static_file_too_large_returns_413() {
    let dir = setup_static_dir();
    // 稀疏 2MB 文件 (set_len 不占磁盘), lseek 大小 > 1MB -> 413
    std::fs::write(dir.join("big.bin"), b"x").unwrap();
    let f = std::fs::OpenOptions::new().write(true).open(dir.join("big.bin")).unwrap();
    f.set_len(2 * 1024 * 1024).unwrap();
    drop(f);
    let mut cp = ConnPair::new();
    let rc = send_static_file(cp.b, "/big.bin");
    assert_eq!(rc, 0);
    assert_last_status("413 Payload Too Large");
    let resp = recv_all(&mut cp);
    let body = String::from_utf8_lossy(body_after_headers(&resp));
    assert!(body.contains("\"status\":\"413 Payload Too Large\""));
    teardown_static_dir(&dir);
}

#[test]
fn send_simple_response_extra_body_present() {
    // F3b: 带 extra 头时 body 必须完整到达 (曾复现 405/ctx 头到 body 不达).
    let mut cp = ConnPair::new();
    let extra = "X-Handler:ctx\r\nX-Server:fastapi_mojo";
    let body = b"{\"detail\":\"ok\",\"status\":\"200\"}";
    let rc = send_simple_response_extra(cp.b, "200 OK", body, extra);
    assert_eq!(rc, 0);
    let resp = recv_all(&mut cp);
    let head = String::from_utf8_lossy(&resp[..find_blank_line(&resp)]);
    assert!(head.contains("X-Handler:ctx\r\n"), "extra hdr 1 present: {head:?}");
    assert!(head.contains("X-Server:fastapi_mojo\r\n"), "extra hdr 2 present: {head:?}");
    assert_eq!(body_after_headers(&resp), body, "body must arrive intact");
}

#[test]
fn send_simple_response_extra_empty_is_plain() {
    let mut cp = ConnPair::new();
    let rc = send_simple_response_extra(cp.b, "200 OK", b"{\"ok\":1}", "");
    assert_eq!(rc, 0);
    let resp = recv_all(&mut cp);
    assert_eq!(body_after_headers(&resp), b"{\"ok\":1}");
}

#[test]
fn debug_send_simple_response_extra_bytes() {
    let mut cp = ConnPair::new();
    let extra = "X-Handler:ctx\r\nX-Server:fastapi_mojo";
    let body = b"{\"detail\":\"ok\"}";
    let _ = send_simple_response_extra(cp.b, "200 OK", body, extra);
    let resp = recv_all(&mut cp);
    eprintln!("=== full response ({} bytes) ===", resp.len());
    eprintln!("{:?}", String::from_utf8_lossy(&resp));
    eprintln!("=== END ===");
    eprintln!("body after blank: {:?}", body_after_headers(&resp));
    // also dump content-length
    if let Some(s) = String::from_utf8_lossy(&resp).find("Content-Length: ") {
        eprintln!("Content-Length line: {:?}", &String::from_utf8_lossy(&resp)[s..s+50]);
    }
}
