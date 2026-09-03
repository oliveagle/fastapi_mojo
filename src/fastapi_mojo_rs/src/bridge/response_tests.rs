// response_tests.rs — 响应头构建回归 (ADR-0010 DC2)
// 与生产代码同目录约定 (AGENTS.md §3.2)。
use super::response::*;

// ---------- get_content_type ----------

#[test]
fn content_type_html() {
    assert_eq!(get_content_type("/index.html"), "text/html");
    assert_eq!(get_content_type("/a/b.htm"), "text/html");
    assert_eq!(get_content_type("x.HTML"), "application/octet-stream"); // 大小写敏感 (C 同)
}

#[test]
fn content_type_known() {
    assert_eq!(get_content_type("/s.css"), "text/css");
    assert_eq!(get_content_type("/s.js"), "application/javascript");
    assert_eq!(get_content_type("/d.json"), "application/json");
    assert_eq!(get_content_type("/i.png"), "image/png");
    assert_eq!(get_content_type("/i.jpg"), "image/jpeg");
    assert_eq!(get_content_type("/i.jpeg"), "image/jpeg");
    assert_eq!(get_content_type("/i.gif"), "image/gif");
    assert_eq!(get_content_type("/i.svg"), "image/svg+xml");
    assert_eq!(get_content_type("/fav.ico"), "image/x-icon");
    assert_eq!(get_content_type("/readme.txt"), "text/plain");
    assert_eq!(get_content_type("/d.xml"), "application/xml");
    assert_eq!(get_content_type("/doc.pdf"), "application/pdf");
    assert_eq!(get_content_type("/f.woff"), "font/woff");
    assert_eq!(get_content_type("/f.woff2"), "font/woff2");
}

#[test]
fn content_type_unknown_and_no_ext() {
    assert_eq!(get_content_type("/file.bin"), "application/octet-stream");
    assert_eq!(get_content_type("/noext"), "application/octet-stream");
    assert_eq!(get_content_type(""), "application/octet-stream");
}

#[test]
fn content_type_dot_in_dir() {
    // 取最后一个点 (C strrchr); "a.b/file" 中 .b 被视为扩展名, 未知 -> octet
    assert_eq!(get_content_type("/a.b/file"), "application/octet-stream");
}

// ---------- json_escape ----------

#[test]
fn json_escape_plain() {
    assert_eq!(json_escape(b"hello world"), b"hello world");
    assert_eq!(json_escape(b""), b"");
}

#[test]
fn json_escape_quote_and_backslash() {
    assert_eq!(json_escape(b"a\"b\\c"), b"a\\\"b\\\\c");
}

#[test]
fn json_escape_control_short_forms() {
    assert_eq!(json_escape(b"a\nb"), b"a\\nb");
    assert_eq!(json_escape(b"a\rb"), b"a\\rb");
    assert_eq!(json_escape(b"a\tb"), b"a\\tb");
    assert_eq!(json_escape(&[0x08]), b"\\b");
    assert_eq!(json_escape(&[0x0C]), b"\\f");
}

#[test]
fn json_escape_other_control_u00xx() {
    assert_eq!(json_escape(&[0x01]), b"\\u0001");
    assert_eq!(json_escape(&[0x1F]), b"\\u001f");
    assert_eq!(json_escape(&[0x0A]), b"\\n"); // 0x0A 走短转义
}

#[test]
fn json_escape_non_utf8_passthrough() {
    // 非控制、非特殊字节 (含非法 UTF-8) 原样拷贝 — 与 C json_escape_cstr 一致
    assert_eq!(json_escape(&[0xFF, 0xFE, 0x80]), &[0xFF, 0xFE, 0x80]);
}

// ---------- build_response_headers ----------

#[test]
fn response_headers_close() {
    let h = build_response_headers("200 OK", "application/json", 12, false, None);
    let s = String::from_utf8(h).unwrap();
    assert!(s.starts_with("HTTP/1.1 200 OK\r\n"));
    assert!(s.contains("\r\nContent-Type: application/json\r\n"));
    assert!(s.contains("\r\nContent-Length: 12\r\n"));
    assert!(s.contains("\r\nConnection: close\r\n"));
    assert!(s.contains("\r\nAccess-Control-Allow-Origin: *\r\n"));
    assert!(s.ends_with("\r\n\r\n"));
}

#[test]
fn response_headers_keep_alive() {
    let h = build_response_headers("200 OK", "text/plain", 0, true, None);
    let s = String::from_utf8(h).unwrap();
    assert!(s.contains("\r\nConnection: keep-alive\r\n"));
}

#[test]
fn response_headers_extra_allow() {
    let h = build_response_headers("405 Method Not Allowed", "application/json", 2, false, Some("Allow: GET, POST"));
    let s = String::from_utf8(h).unwrap();
    assert!(s.contains("\r\nAllow: GET, POST\r\n"));
}

#[test]
fn response_headers_empty_extra() {
    let a = build_response_headers("200 OK", "text/html", 0, true, None);
    let b = build_response_headers("200 OK", "text/html", 0, true, Some(""));
    assert_eq!(a, b);
}

#[test]
fn response_headers_include_cors_full_set() {
    let h = build_response_headers("200 OK", "x", 0, true, None);
    let s = String::from_utf8(h).unwrap();
    for line in [
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type, Authorization",
        "Access-Control-Max-Age: 86400",
    ] {
        assert!(s.contains(line), "missing CORS line: {line}");
    }
}

// ---------- build_preflight_response ----------

#[test]
fn preflight_exact_bytes() {
    let expected = b"HTTP/1.1 204 No Content\r\n\
Content-Length: 0\r\n\
Connection: close\r\n\
Access-Control-Allow-Origin: *\r\n\
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n\
Access-Control-Allow-Headers: Content-Type, Authorization\r\n\
Access-Control-Max-Age: 86400\r\n\
\r\n";
    assert_eq!(build_preflight_response(), expected);
}
