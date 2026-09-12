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
    // 决策-42: request 全局无 Origin → 不带任何 CORS 行（Starlette 对齐;
    // C 时代「每响应必带 *」偏差已移除, 显式 reset 防其他测试泄漏）。
    super::request::reset_request_fields();
    let h = build_response_headers("200 OK", "application/json", 12, false, None);
    let s = String::from_utf8(h).unwrap();
    assert!(s.starts_with("HTTP/1.1 200 OK\r\n"));
    assert!(s.contains("\r\nContent-Type: application/json\r\n"));
    assert!(s.contains("\r\nContent-Length: 12\r\n"));
    assert!(s.contains("\r\nConnection: close\r\n"));
    assert!(!s.contains("Access-Control"), "no Origin → no CORS lines");
    assert!(s.ends_with("\r\n\r\n"));
    super::request::reset_request_fields();
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
fn response_headers_cors_dynamic() {
    // 决策-42: CORS 行 = f(request Origin, env config), 不再是固定常量。
    cors_env_clear();
    super::request::reset_request_fields();

    // 1) 无 Origin → 0 行
    let s = String::from_utf8(build_response_headers("200 OK", "x", 0, true, None)).unwrap();
    assert!(!s.contains("Access-Control"));

    // 2) 默认通配 + Origin → ACAO *（credentials 关 → 无 credentials 行）
    super::request::set_cors_request(Some(b"http://example.com"), None, None);
    let s = String::from_utf8(build_response_headers("200 OK", "x", 0, true, None)).unwrap();
    assert!(s.contains("Access-Control-Allow-Origin: *"));
    assert!(!s.contains("Access-Control-Allow-Credentials"));

    // 3) 白名单命中 + credentials → 回显 origin + credentials 行
    std::env::set_var("FASTAPI_MOJO_CORS_ORIGINS", "http://a.com,http://b.com");
    std::env::set_var("FASTAPI_MOJO_CORS_CREDENTIALS", "true");
    super::cors::__test_reset_config();
    super::request::set_cors_request(Some(b"http://b.com"), None, None);
    let s = String::from_utf8(build_response_headers("200 OK", "x", 0, true, None)).unwrap();
    assert!(s.contains("Access-Control-Allow-Origin: http://b.com"));
    assert!(s.contains("Access-Control-Allow-Credentials: true"));

    // 4) 白名单未命中 → 无 Allow-Origin（上游仍发静态 simple_headers: credentials）
    super::request::set_cors_request(Some(b"http://evil.com"), None, None);
    let s = String::from_utf8(build_response_headers("200 OK", "x", 0, true, None)).unwrap();
    assert!(!s.contains("Access-Control-Allow-Origin"));
    assert!(s.contains("Access-Control-Allow-Credentials: true"));

    // cleanup: 不泄漏到后续测试
    super::request::reset_request_fields();
    cors_env_clear();
}

/// 决策-42 测试隔离: 清 FASTAPI_MOJO_CORS_* env + cors config 缓存
/// (--test-threads=1 顺序纪律; 复用 cors.rs 共享钩子, 断言 panic 跳过
/// 结尾清理的防御纵深)。
fn cors_env_clear() {
    super::cors::__test_clear_env();
}

// ---------- build_preflight_response ----------

#[test]
fn preflight_bare_options_default() {
    // 决策-42 动态版: 无 Origin/ACRM/ACHR（裸 OPTIONS, C 端口既有行为）→
    // 204 + 通配 ACAO + Max-Age 600（Starlette; C 时代 86400 → 对齐上游）;
    // ACRM/ACHR 未带 → 不带 Allow-Methods/Allow-Headers（Starlette 预检
    // 响应含 Allow-Methods 是默认 7 方法集超集, 本实现按需输出, e2e 守护）。
    cors_env_clear();
    super::request::reset_request_fields();
    let s = String::from_utf8(build_preflight_response()).unwrap();
    assert!(s.starts_with("HTTP/1.1 204 No Content\r\n"));
    assert!(s.contains("Access-Control-Allow-Origin: *\r\n"));
    assert!(s.contains("Access-Control-Max-Age: 600\r\n"));
    assert!(s.contains("Content-Length: 0\r\n"));
    assert!(s.contains("Connection: close\r\n"));
    assert!(s.ends_with("\r\n\r\n"));
    super::request::reset_request_fields();
}

#[test]
fn preflight_200_ok_full_headers() {
    // 决策-73 (ADR-0048): 真预检通过 → 200 + text/plain `OK` + 完整头集。
    cors_env_clear();
    std::env::set_var("FASTAPI_MOJO_CORS_ORIGINS", "http://a.com");
    std::env::set_var("FASTAPI_MOJO_CORS_MAX_AGE", "120");
    super::cors::__test_reset_config();
    super::request::reset_request_fields();
    super::request::set_cors_request(Some(b"http://a.com"), Some(b"POST"), Some(b"Content-Type, Authorization"));
    let s = String::from_utf8(build_preflight_response()).unwrap();
    assert!(s.starts_with("HTTP/1.1 200 OK\r\n"));
    assert!(s.contains("Vary: Origin\r\n"));
    assert!(s.contains("Access-Control-Allow-Origin: http://a.com\r\n"));
    assert!(s.contains("Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"));
    assert!(s.contains(
        "Access-Control-Allow-Headers: Accept, Accept-Language, Authorization, Content-Language, Content-Type\r\n"
    ));
    assert!(s.contains("Access-Control-Max-Age: 120\r\n"));
    assert!(s.contains("Content-Type: text/plain; charset=utf-8\r\n"));
    assert!(s.contains("Content-Length: 2\r\n"));
    assert!(s.ends_with("\r\n\r\nOK"));
    super::request::reset_request_fields();
    cors_env_clear();
}

#[test]
fn preflight_400_origin_not_allowed() {
    // 决策-73: 失败 → 400 + text/plain `Disallowed CORS origin` + preflight 头集。
    cors_env_clear();
    std::env::set_var("FASTAPI_MOJO_CORS_ORIGINS", "http://a.com");
    super::cors::__test_reset_config();
    super::request::reset_request_fields();
    super::request::set_cors_request(Some(b"http://evil.com"), Some(b"POST"), Some(b"Content-Type"));
    let s = String::from_utf8(build_preflight_response()).unwrap();
    assert!(s.starts_with("HTTP/1.1 400 Bad Request\r\n"));
    assert!(s.contains("Content-Type: text/plain; charset=utf-8\r\n"));
    assert!(s.contains("Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"));
    assert!(s.ends_with("\r\n\r\nDisallowed CORS origin"));
    super::request::reset_request_fields();
    cors_env_clear();
}
