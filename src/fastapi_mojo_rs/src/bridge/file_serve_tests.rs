//! file_serve.rs 单元测试 — 真 socketpair 验证 FileResponse /
//! StreamingResponse 响应字节（send_tests.rs 同模式: 受控真系统调用,
//! --test-threads=1 防全局状态污染; 静态目录 = 临时目录, send_tests 同手法）。

use std::os::raw::{c_char, c_int, c_void};

use super::file_serve::{send_file_response, LinuxStat};
use super::request::{
    reset_request_fields, set_close_after_response, set_http_fields, set_range_headers,
};
use super::send::send_streaming_response;
use super::state::set_static_dir;

extern "C" {
    fn socketpair(domain: c_int, ty: c_int, protocol: c_int, sv: *mut c_int) -> c_int;
    fn recv(fd: c_int, buf: *mut c_void, len: usize, flags: c_int) -> isize;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn mkdir(path: *const c_char, mode: u32) -> c_int;
}
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const O_NONBLOCK: c_int = 0o4000;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;

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
    fn make_a_nonblock(&mut self) {
        unsafe {
            let fl = fcntl(self.a, F_GETFL, 0);
            fcntl(self.a, F_SETFL, fl | O_NONBLOCK);
        }
    }
    /// 排空直到稳定 (3 次 10ms 无新字节) — 容忍多段 send 的到达间隔。
    fn recv_settled(&mut self) -> Vec<u8> {
        self.make_a_nonblock();
        let mut out = Vec::new();
        let mut idle = 0;
        let mut buf = [0u8; 65536];
        loop {
            let n = unsafe { recv(self.a, buf.as_mut_ptr() as *mut c_void, buf.len(), 0) };
            if n > 0 {
                out.extend_from_slice(&buf[..n as usize]);
                idle = 0;
            } else {
                idle += 1;
                if idle >= 3 {
                    break;
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        out
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

fn headers_only(resp: &[u8]) -> &str {
    // 含头块终止符 CR LF CR LF（断言 "Last: x CR LF" 依赖）
    let end = match resp.windows(4).position(|w| w == b"\r\n\r\n") {
        Some(i) => i + 4,
        None => resp.len(),
    };
    std::str::from_utf8(&resp[..end]).unwrap_or("")
}

fn body_after(resp: &[u8]) -> &[u8] {
    let idx = resp.windows(4).position(|w| w == b"\r\n\r\n").unwrap_or(resp.len()) + 4;
    &resp[idx..]
}
fn setup_static(tmp: &str) {
    std::env::remove_var("FASTAPI_MOJO_STATIC_DIR");
    // 幂等：上次 run panic 前未 teardown 会残留目录 → mkdir EEXIST(-1)
    std::fs::remove_dir_all(tmp).ok();
    let c = std::ffi::CString::new(tmp).unwrap();
    assert_eq!(unsafe { mkdir(c.as_ptr(), 0o755) }, 0);
    set_static_dir(Some(tmp));
}

fn teardown() {
    std::env::remove_var("FM_TEST_RESTORE_STATIC");
}

/// 完整 file case: 临时静态目录 + 请求 (method/range/if-range) → 响应字节。
/// content = "" 且 `make_dir=true` → 建目录 (非普通文件 500 用例)。
#[allow(clippy::too_many_arguments)] // 测试 helper: 全参数面显式传（可读性优先）
fn file_case(
    tmp: &str,
    fname: &str,
    content: &str,
    make_dir: bool,
    range: Option<&str>,
    if_range: Option<&str>,
    media: &str,
    filename: &str,
    cdt: &str,
    status: &str,
    extra: &str,
    method: &str,
) -> Vec<u8> {
    setup_static(tmp);
    if make_dir {
        std::fs::create_dir_all(format!("{tmp}/{fname}")).unwrap();
    } else if !content.is_empty() || fname != "NOPE.txt" {
        let path = format!("{tmp}/{fname}");
        std::fs::write(&path, content).unwrap();
        // 固定 mtime = 1788996557.9171202（p10 probe 值）：跨文件/跨 run
        // etag（md5(mtime-size)）与 Last-Modified 确定性 — If-Range 匹配
        // 用例依赖（两次 write 的 ns mtime 不同 → etag 不同 → 误 200）
        let ft = std::fs::File::open(&path).unwrap();
        let t = std::time::UNIX_EPOCH
            + std::time::Duration::from_secs(1788996557)
            + std::time::Duration::from_nanos(917120000);
        ft.set_modified(t).unwrap();
    }
    reset_request_fields();
    set_http_fields(method.as_bytes(), b"/file", b"", true, true, 7);
    set_close_after_response(true);
    set_range_headers(range.map(|s| s.as_bytes()), if_range.map(|s| s.as_bytes()));
    let mut cp = ConnPair::new();
    assert_eq!(send_file_response(cp.b, fname, media, filename, cdt, status, extra), 0);
    let resp = cp.recv_settled();
    std::fs::remove_dir_all(tmp).ok();
    teardown();
    resp
}

fn stream_case(status: &str, body: &str, media: &str, extra: &str) -> Vec<u8> {
    reset_request_fields();
    set_http_fields(b"GET", b"/stream", b"", true, true, 7);
    set_close_after_response(true);
    set_range_headers(None, None);
    let mut cp = ConnPair::new();
    assert_eq!(send_streaming_response(cp.b, status, body, media, extra), 0);
    let resp = cp.recv_settled();
    teardown();
    resp
}

// ---------- 结构 ----------

#[test]
fn linux_stat_layout_144() {
    // glibc x86_64 struct stat = 144B（stat(2) 整写；< 144B 缓冲 = 栈 OOB）。
    // 关键偏移（C offsetof 交叉验证）：mode@24 size@48 mtime@88 mtime_nsec@96。
    assert_eq!(std::mem::size_of::<LinuxStat>(), 144);
    assert_eq!(std::mem::offset_of!(LinuxStat, st_mode), 24);
    assert_eq!(std::mem::offset_of!(LinuxStat, st_size), 48);
    assert_eq!(std::mem::offset_of!(LinuxStat, st_mtime), 88);
    assert_eq!(std::mem::offset_of!(LinuxStat, st_mtime_nsec), 96);
}


// ---------- 200 全量 ----------

#[test]
fn file_200_full_octet() {
    let resp = file_case("/tmp/fm_fs_t1", "test.bin", "hello", false, None, None, "", "", "", "200 OK", "", "GET");
    let h = headers_only(&resp);
    assert!(h.starts_with("HTTP/1.1 200 OK\r\n"), "{h}");
    assert!(h.contains("Content-Type: application/octet-stream\r\n"), "{h}");
    assert!(h.contains("Content-Length: 5\r\n"), "{h}");
    assert!(h.contains("Accept-Ranges: bytes\r\n"), "{h}");
    assert!(h.contains("Last-Modified: ") && h.contains(" GMT\r\n"), "{h}");
    assert!(h.contains("ETag: \"") && h.contains("\"\r\n"), "{h}");
    assert!(h.contains("Connection: close\r\n"), "{h}");
    assert_eq!(body_after(&resp), b"hello");
}

#[test]
fn file_200_text_charset_and_201() {
    let r1 = file_case("/tmp/fm_fs_t2", "a.txt", "x", false, None, None, "text/plain", "", "", "200 OK", "", "GET");
    assert!(headers_only(&r1).contains("Content-Type: text/plain; charset=utf-8\r\n"));
    let r2 = file_case("/tmp/fm_fs_t3", "a.bin", "ab", false, None, None, "", "", "", "201 Created", "X-Extra: ee", "GET");
    let h = headers_only(&r2);
    assert!(h.starts_with("HTTP/1.1 201 Created\r\n"), "{h}");
    assert!(h.contains("X-Extra: ee\r\n"), "{h}");
    assert_eq!(body_after(&r2), b"ab");
}

// ---------- Content-Disposition ----------

#[test]
fn file_content_disposition_plain_and_star() {
    let r1 = file_case("/tmp/fm_fs_t4", "a.bin", "z", false, None, None, "", "report.txt", "attachment", "200 OK", "", "GET");
    assert!(headers_only(&r1).contains("Content-Disposition: attachment; filename=\"report.txt\"\r\n"));
    let r2 = file_case("/tmp/fm_fs_t5", "a.bin", "z", false, None, None, "", "a b.txt", "inline", "200 OK", "", "GET");
    assert!(headers_only(&r2).contains("Content-Disposition: inline; filename*=utf-8''a%20b.txt\r\n"));
}

// ---------- 500 ----------

#[test]
fn file_missing_and_non_regular_500() {
    let r1 = file_case("/tmp/fm_fs_t6", "NOPE.txt", "", false, None, None, "", "", "", "200 OK", "", "GET");
    let h = headers_only(&r1);
    assert!(h.starts_with("HTTP/1.1 500 Internal Server Error\r\n"), "{h}");
    assert!(h.contains("Content-Type: text/plain; charset=utf-8\r\n"), "{h}");
    assert!(h.contains("Content-Length: 21\r\n"), "{h}");
    assert!(!h.contains("ETag") && !h.contains("Last-Modified"), "{h}");
    assert_eq!(body_after(&r1), b"Internal Server Error");
    let r2 = file_case("/tmp/fm_fs_t7", "subdir", "", true, None, None, "", "", "", "200 OK", "", "GET");
    assert!(headers_only(&r2).starts_with("HTTP/1.1 500 Internal Server Error\r\n"));
}

// ---------- Range ----------

#[test]
fn file_range_single_suffix_open() {
    let r1 = file_case("/tmp/fm_fs_t8", "a.bin", "0123456789", false, Some("bytes=2-4"), None, "", "", "", "200 OK", "", "GET");
    let h = headers_only(&r1);
    assert!(h.starts_with("HTTP/1.1 206 Partial Content\r\n"), "{h}");
    assert!(h.contains("Content-Range: bytes 2-4/10\r\n"), "{h}");
    assert!(h.contains("Content-Length: 3\r\n"), "{h}");
    assert_eq!(body_after(&r1), b"234");
    let r2 = file_case("/tmp/fm_fs_t9", "a.bin", "0123456789", false, Some("bytes=-3"), None, "", "", "", "200 OK", "", "GET");
    assert!(headers_only(&r2).contains("Content-Range: bytes 7-9/10\r\n"));
    let r3 = file_case("/tmp/fm_fs_t10", "a.bin", "0123456789", false, Some("bytes=7-"), None, "", "", "", "200 OK", "", "GET");
    let h = headers_only(&r3);
    assert!(h.contains("Content-Range: bytes 7-9/10\r\n") && h.contains("Content-Length: 3\r\n"));
    assert_eq!(body_after(&r3), b"789");
}

#[test]
fn file_range_416_and_400s() {
    let r1 = file_case("/tmp/fm_fs_t11", "a.bin", "0123456789", false, Some("bytes=100-200"), None, "", "", "", "200 OK", "", "GET");
    let h = headers_only(&r1);
    assert!(h.starts_with("HTTP/1.1 416 Range Not Satisfiable\r\n"), "{h}");
    assert!(h.contains("Content-Range: bytes */10\r\n"), "{h}");
    assert!(h.contains("Content-Length: 0\r\n"), "{h}");
    assert!(!h.contains("ETag"), "{h}");
    assert!(body_after(&r1).is_empty());
    let cases = [
        ("foo", "Malformed range header."),
        ("items=0-5", "Only support bytes range"),
        ("bytes=-", "Range header: range must be requested"),
        ("bytes=5-3", "Range header: start must be less than end"),
    ];
    for (i, (hdr, msg)) in cases.iter().enumerate() {
        let r = file_case(
            &format!("/tmp/fm_fs_t400_{i}"), "a.bin", "0123456789", false,
            Some(hdr), None, "", "", "", "200 OK", "", "GET",
        );
        let h = headers_only(&r);
        assert!(h.starts_with("HTTP/1.1 400 Bad Request\r\n"), "{h}");
        assert_eq!(body_after(&r), msg.as_bytes(), "hdr={hdr}");
        assert!(!h.contains("ETag"), "{h}");
    }
}

#[test]
fn file_range_101_parts_full() {
    let parts: Vec<String> = (0..101).map(|i| format!("{i}-{i}")).collect();
    let hdr = format!("bytes={}", parts.join(","));
    let r = file_case("/tmp/fm_fs_t12", "a.bin", "0123456789", false, Some(&hdr), None, "", "", "", "200 OK", "", "GET");
    assert!(headers_only(&r).starts_with("HTTP/1.1 200 OK\r\n"));
    assert_eq!(body_after(&r), b"0123456789");
}

#[test]
fn file_if_range_match_and_stale() {
    let first = file_case("/tmp/fm_fs_t13", "a.bin", "0123456789", false, None, None, "", "", "", "200 OK", "", "GET");
    let etag = headers_only(&first)
        .lines()
        .find(|l| l.starts_with("ETag: "))
        .unwrap()
        .strip_prefix("ETag:")
        .unwrap()
        .trim()
        .to_string();
    let r1 = file_case("/tmp/fm_fs_t14", "a.bin", "0123456789", false, Some("bytes=2-4"), Some(&etag), "", "", "", "200 OK", "", "GET");
    assert!(headers_only(&r1).starts_with("HTTP/1.1 206 Partial Content\r\n"));
    assert_eq!(body_after(&r1), b"234");
    let r2 = file_case("/tmp/fm_fs_t15", "a.bin", "0123456789", false, Some("bytes=2-4"), Some("\"stale\""), "", "", "", "200 OK", "", "GET");
    assert!(headers_only(&r2).starts_with("HTTP/1.1 200 OK\r\n"));
    assert_eq!(body_after(&r2), b"0123456789");
}

// ---------- multipart 206 ----------

#[test]
fn file_range_multi_multipart() {
    let resp = file_case("/tmp/fm_fs_t16", "a.bin", "0123456789", false, Some("bytes=0-1,5-6"), None, "", "", "", "200 OK", "", "GET");
    let h = headers_only(&resp);
    assert!(h.starts_with("HTTP/1.1 206 Partial Content\r\n"), "{h}");
    let ct_line = h.lines()
        .find(|l| l.starts_with("Content-Type: "))
        .unwrap()
        .strip_prefix("Content-Type: ")
        .unwrap()
        .trim()
        .to_string();
    let bd = ct_line.split("boundary=").nth(1).unwrap().to_string();
    assert!(ct_line.starts_with("multipart/byteranges; boundary="));
    assert_eq!(bd.len(), 26);
    assert!(bd.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    assert!(!h.to_ascii_lowercase().contains("content-range"), "{h}");
    // 手算: 2×(49+26+24+2+1+1+2) + 4+26 = 240（ct="application/octet-stream"=24）
    assert!(h.contains("Content-Length: 240\r\n"), "{h}");
    let body = body_after(&resp);
    let expect = format!(
        "--{bd}\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes 0-1/10\r\n\r\n01\r\n\
         --{bd}\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes 5-6/10\r\n\r\n56\r\n\
         --{bd}--"
    );
    assert_eq!(body, expect.as_bytes());
}

// ---------- HEAD ----------

#[test]
fn file_head_full_and_range() {
    let r1 = file_case("/tmp/fm_fs_t17", "a.bin", "0123456789", false, None, None, "", "", "", "200 OK", "", "HEAD");
    let h = headers_only(&r1);
    assert!(h.starts_with("HTTP/1.1 200 OK\r\n"), "{h}");
    assert!(h.contains("Content-Length: 10\r\n"), "{h}");
    assert!(body_after(&r1).is_empty());
    let r2 = file_case("/tmp/fm_fs_t18", "a.bin", "0123456789", false, Some("bytes=2-4"), None, "", "", "", "200 OK", "", "HEAD");
    let h = headers_only(&r2);
    assert!(h.starts_with("HTTP/1.1 206 Partial Content\r\n"), "{h}");
    assert!(h.contains("Content-Range: bytes 2-4/10\r\n") && h.contains("Content-Length: 3\r\n"), "{h}");
    assert!(body_after(&r2).is_empty());
}

// ---------- StreamingResponse ----------

#[test]
fn stream_chunked_no_content_type() {
    let resp = stream_case("200 OK", "hello |world|中", "", "");
    let h = headers_only(&resp);
    assert!(h.starts_with("HTTP/1.1 200 OK\r\n"), "{h}");
    assert!(!h.contains("Content-Type"), "{h}");
    assert!(h.contains("Transfer-Encoding: chunked\r\n"), "{h}");
    assert!(!h.contains("Content-Length"), "{h}");
    assert_eq!(body_after(&resp), b"6\r\nhello \r\n5\r\nworld\r\n3\r\n\xe4\xb8\xad\r\n0\r\n\r\n");
}

#[test]
fn stream_json_202_custom_header() {
    let resp = stream_case("202 Accepted", "{\"a\":0}|{\"a\":1}", "application/json", "X-Custom: cv");
    let h = headers_only(&resp);
    assert!(h.starts_with("HTTP/1.1 202 Accepted\r\n"), "{h}");
    assert!(h.contains("Content-Type: application/json\r\n"), "{h}");
    assert!(h.contains("X-Custom: cv\r\n"), "{h}");
    assert_eq!(body_after(&resp), b"7\r\n{\"a\":0}\r\n7\r\n{\"a\":1}\r\n0\r\n\r\n");
}

#[test]
fn stream_text_media_gets_charset() {
    let resp = stream_case("200 OK", "ab", "text/csv", "");
    assert!(headers_only(&resp).contains("Content-Type: text/csv; charset=utf-8\r\n"));
}

#[test]
fn stream_empty() {
    let resp = stream_case("200 OK", "", "", "");
    let h = headers_only(&resp);
    assert!(h.starts_with("HTTP/1.1 200 OK\r\n"), "{h}");
    assert!(!h.contains("Content-Type"), "{h}");
    assert_eq!(body_after(&resp), b"0\r\n\r\n");
}
