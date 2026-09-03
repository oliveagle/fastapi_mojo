// parse_tests.rs — HTTP 头部解析工具回归 (ADR-0010 DC2)
// 与生产代码同目录约定 (AGENTS.md §3.2)。
// 通过 bridge/mod.rs 的 `#[cfg(test)] mod parse_tests;` 编译 (同 crate)。
use super::parse::*;

// ---------- find_header_end ----------

#[test]
fn find_header_end_empty() {
    assert_eq!(find_header_end(b""), None);
    assert_eq!(find_header_end(b"\r\n"), None);
    assert_eq!(find_header_end(b"\r\n\r"), None);
}

#[test]
fn find_header_end_basic() {
    let hdr = b"GET / HTTP/1.1\r\nHost: a\r\n\r\nbody";
    // body 起始于 4 字节分隔符之后
    assert_eq!(find_header_end(hdr), Some(27));
    assert_eq!(&hdr[find_header_end(hdr).unwrap()..], b"body");
}

#[test]
fn find_header_end_exact_end() {
    // "GET / HTTP/1.1" = 14 字节, \r\n\r\n 从 14 起; 返回 14+4 = 18
    let hdr = b"GET / HTTP/1.1\r\n\r\n";
    assert_eq!(find_header_end(hdr), Some(18));
}

#[test]
fn find_header_end_no_separator() {
    assert_eq!(find_header_end(b"GET / HTTP/1.1\r\nHost: a"), None);
}

#[test]
fn find_header_end_short_buf() {
    // < 4 字节直接返回 None (窗口扫描下界)
    assert_eq!(find_header_end(b"\r\n\r"), None);
    assert_eq!(find_header_end(b"abcd"), None);
}

#[test]
fn find_header_end_multiple_separators() {
    // 取第一个分隔符 (14 -> 18)
    let hdr = b"GET / HTTP/1.1\r\n\r\nX\r\n\r\nY";
    assert_eq!(find_header_end(hdr), Some(18));
}

#[test]
fn find_header_end_lone_crlf_not_sep() {
    // 单独的 \r\n 不是终止符; 完整 \r\n\r\n 才是
    assert_eq!(find_header_end(b"GET / HTTP/1.1\r\n\r\n"), Some(18));
    // "GET / HTTP/1.1\r\nX" = 17 字节, 分隔符从 17 起 -> 21
    assert_eq!(find_header_end(b"GET / HTTP/1.1\r\nX\r\n\r\n"), Some(21));
}

// ---------- bounded_strstr ----------

#[test]
fn bounded_strstr_basic() {
    let hay = b"hello world";
    assert_eq!(bounded_strstr(hay, b"world"), Some(6));
    assert_eq!(bounded_strstr(hay, b"hello"), Some(0));
    assert_eq!(bounded_strstr(hay, b"o w"), Some(4));
}

#[test]
fn bounded_strstr_empty_needle() {
    assert_eq!(bounded_strstr(b"abc", b""), None);
}

#[test]
fn bounded_strstr_needle_too_long() {
    assert_eq!(bounded_strstr(b"abc", b"abcd"), None);
}

#[test]
fn bounded_strstr_not_found() {
    assert_eq!(bounded_strstr(b"abcdef", b"xyz"), None);
}

#[test]
fn bounded_strstr_needle_at_end() {
    assert_eq!(bounded_strstr(b"abcdef", b"def"), Some(3));
    assert_eq!(bounded_strstr(b"abc", b"c"), Some(2));
}

// ---------- utf8_valid ----------

#[test]
fn utf8_valid_ascii() {
    assert!(utf8_valid(b"GET /path?q=1 HTTP/1.1"));
    assert!(utf8_valid(b""));
}

#[test]
fn utf8_valid_2byte() {
    assert!(utf8_valid("é".as_bytes())); // C3 A9
    assert!(utf8_valid("a€b".as_bytes())); // mixed with 3-byte
}

#[test]
fn utf8_valid_3byte_cjk() {
    assert!(utf8_valid("中文".as_bytes()));
    assert!(utf8_valid("日本語".as_bytes()));
}

#[test]
fn utf8_valid_4byte_emoji() {
    assert!(utf8_valid("emoji \u{1F600}".as_bytes()));
    assert!(utf8_valid(&[0xF0, 0x9F, 0x98, 0x80])); // U+1F600
}

#[test]
fn utf8_valid_overlong_rejected() {
    // C0 80 = overlong NUL
    assert!(!utf8_valid(&[0xC0, 0x80]));
    // C1 BF = overlong
    assert!(!utf8_valid(&[0xC1, 0xBF]));
}

#[test]
fn utf8_valid_surrogate_rejected() {
    // ED A0 80 = U+D800 surrogate
    assert!(!utf8_valid(&[0xED, 0xA0, 0x80]));
    // ED BF BF = U+DFFF surrogate
    assert!(!utf8_valid(&[0xED, 0xBF, 0xBF]));
}

#[test]
fn utf8_valid_above_10ffff_rejected() {
    // F5 80 80 80 = 头字节 > 0xF4 (覆盖 > U+10FFFF 空间) -> 拒绝
    assert!(!utf8_valid(&[0xF5, 0x80, 0x80, 0x80]));
}

#[test]
fn utf8_valid_4byte_lead_check_only_matches_c() {
    // C quirk: 只检查头字节 <= 0xF4, 不验证 0xF4 序列是否 > U+10FFFF;
    // 0xF4 0x90 0x80 0x80 (= U+110000) 会被 C 接受 — 保持等价, 不收紧。
    assert!(utf8_valid(&[0xF4, 0x90, 0x80, 0x80]));
    assert!(utf8_valid(&[0xF4, 0x8F, 0xBF, 0xBF])); // U+10FFFF 合法
}

#[test]
fn utf8_valid_truncated_rejected() {
    assert!(!utf8_valid(&[0xC3])); // 2-byte lead, no continuation
    assert!(!utf8_valid(&[0xE4, 0xB8])); // 3-byte lead, 1 continuation
    assert!(!utf8_valid(&[0xF0, 0x9F, 0x98])); // 4-byte lead, 2 conts
}

#[test]
fn utf8_valid_orphan_continuation_rejected() {
    assert!(!utf8_valid(&[0x80]));
    assert!(!utf8_valid(&[0xBF]));
    assert!(!utf8_valid(b"abc\x80def"));
}

#[test]
fn utf8_valid_bad_continuation_rejected() {
    // C3 41: continuation byte must be 10xxxxxx
    assert!(!utf8_valid(&[0xC3, 0x41]));
}

#[test]
fn utf8_valid_boundary_2byte() {
    assert!(utf8_valid(&[0xC2, 0x80])); // U+0080, smallest 2-byte
    assert!(utf8_valid(&[0xDF, 0xBF])); // U+07FF, largest 2-byte
}

#[test]
fn utf8_valid_boundary_4byte() {
    assert!(utf8_valid(&[0xF4, 0x8F, 0xBF, 0xBF])); // U+10FFFF, largest
}

// ---------- has_header_name_ci ----------

#[test]
fn has_header_name_ci_basic() {
    let hdr = b"GET / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n";
    assert!(has_header_name_ci(hdr, b"Transfer-Encoding"));
    assert!(has_header_name_ci(hdr, b"transfer-encoding"));
    assert!(has_header_name_ci(hdr, b"TRANSFER-ENCODING"));
    assert!(!has_header_name_ci(hdr, b"Content-Length"));
}

#[test]
fn has_header_name_ci_first_line() {
    // 请求行本身不是 header, 但 C 允许 i==0 行首匹配; 保持字节等价
    let hdr = b"GET / HTTP/1.1\r\n\r\n";
    assert!(has_header_name_ci(hdr, b"GET"));
}

#[test]
fn has_header_name_ci_mid_line_not_matched() {
    // 名称出现在行中 (非行首) 不匹配
    let hdr = b"X: Transfer-Encoding\r\n\r\n";
    assert!(!has_header_name_ci(hdr, b"Transfer-Encoding"));
}

#[test]
fn has_header_name_ci_prefix_quirk_matches_c() {
    // C 实现是"行首前缀比较"(不要求 name 后紧跟 ':'): "Content" 会命中
    // 行首的 "Content-Length: 0"。保持字节等价, 不收紧 (实际调用只用完整
    // 头名 "Transfer-Encoding" 等, 无歧义)。
    let hdr = b"Host: a\r\nContent-Length: 0\r\n\r\n";
    assert!(has_header_name_ci(hdr, b"Content-Length"));
    assert!(has_header_name_ci(hdr, b"Content")); // C quirk
}

#[test]
fn has_header_name_ci_requires_line_start() {
    // 行中 (非行首) 出现同名字符串不命中
    let hdr = b"X-Foo: Host\r\n\r\n";
    assert!(!has_header_name_ci(hdr, b"Host"));
}

#[test]
fn has_header_name_ci_empty_name() {
    assert!(!has_header_name_ci(b"abc", b""));
}

// ---------- get_header_value_ci ----------

#[test]
fn get_header_value_ci_basic() {
    let hdr = b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    assert_eq!(
        get_header_value_ci(hdr, b"Host").unwrap(),
        b"example.com"
    );
}

#[test]
fn get_header_value_ci_case_insensitive_name() {
    let hdr = b"hOsT: example.com\r\n\r\n";
    assert_eq!(get_header_value_ci(hdr, b"HOST").unwrap(), b"example.com");
}

#[test]
fn get_header_value_ci_trimmed() {
    let hdr = b"Host:   spaced value  \r\n\r\n";
    // 前导空白剥离, 尾随空白保留 (C 只剥前导, 值到 \r 为止)
    assert_eq!(get_header_value_ci(hdr, b"Host").unwrap(), b"spaced value  ");
}

#[test]
fn get_header_value_ci_missing() {
    let hdr = b"GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    assert!(get_header_value_ci(hdr, b"Content-Length").is_none());
}

#[test]
fn get_header_value_ci_no_colon() {
    // 名称后无冒号 -> 跳过
    let hdr = b"Host example.com\r\n\r\n";
    assert!(get_header_value_ci(hdr, b"Host").is_none());
}

#[test]
fn get_header_value_ci_tab_separator() {
    let hdr = b"Host:\tvalue\r\n\r\n";
    assert_eq!(get_header_value_ci(hdr, b"Host").unwrap(), b"value");
}

#[test]
fn get_header_value_ci_empty_value() {
    let hdr = b"X-Empty: \r\n\r\n";
    assert_eq!(get_header_value_ci(hdr, b"X-Empty").unwrap(), b"");
}

// ---------- connection_directive ----------

#[test]
fn conn_close() {
    let hdr = b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n";
    assert_eq!(connection_directive(hdr), ConnDirective::Close);
}

#[test]
fn conn_keep_alive() {
    let hdr = b"GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n";
    assert_eq!(connection_directive(hdr), ConnDirective::KeepAlive);
}

#[test]
fn conn_close_wins() {
    let hdr = b"GET / HTTP/1.1\r\nConnection: keep-alive, close\r\n\r\n";
    assert_eq!(connection_directive(hdr), ConnDirective::Close);
}

#[test]
fn conn_absent() {
    let hdr = b"GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    assert_eq!(connection_directive(hdr), ConnDirective::None);
}

#[test]
fn conn_other_directive() {
    let hdr = b"GET / HTTP/1.1\r\nConnection: upgrade\r\n\r\n";
    assert_eq!(connection_directive(hdr), ConnDirective::None);
}

#[test]
fn conn_case_insensitive() {
    let hdr = b"GET / HTTP/1.1\r\nconnection: Close\r\n\r\n";
    assert_eq!(connection_directive(hdr), ConnDirective::Close);
    let hdr2 = b"GET / HTTP/1.1\r\nConnection: Keep-Alive\r\n\r\n";
    assert_eq!(connection_directive(hdr2), ConnDirective::KeepAlive);
}

#[test]
fn conn_first_line_lookup() {
    // C 允许 i==0 行首匹配 "Connection" (请求行不可能以此开头) — 保持等价
    let hdr = b"Connection: close\r\n\r\n";
    assert_eq!(connection_directive(hdr), ConnDirective::Close);
}

// ---------- expect_100_continue ----------

#[test]
fn expect_100_basic() {
    let hdr = b"POST / HTTP/1.1\r\nExpect: 100-continue\r\n\r\n";
    assert!(expect_100_continue(hdr));
}

#[test]
fn expect_100_case_insensitive() {
    let hdr = b"POST / HTTP/1.1\r\nexpect: 100-CONTINUE\r\n\r\n";
    assert!(expect_100_continue(hdr));
}

#[test]
fn expect_100_with_spaces() {
    let hdr = b"POST / HTTP/1.1\r\nExpect:   100-continue   \r\n\r\n";
    assert!(expect_100_continue(hdr));
}

#[test]
fn expect_100_absent() {
    let hdr = b"POST / HTTP/1.1\r\nHost: a\r\n\r\n";
    assert!(!expect_100_continue(hdr));
}

#[test]
fn expect_100_other_value() {
    let hdr = b"POST / HTTP/1.1\r\nExpect: 100-other\r\n\r\n";
    assert!(!expect_100_continue(hdr));
}

#[test]
fn expect_100_embedded_token() {
    // C 逐位置子串扫描: "x100-continue" 也命中 (与 C 字节等价)
    let hdr = b"POST / HTTP/1.1\r\nExpect: x100-continue\r\n\r\n";
    assert!(expect_100_continue(hdr));
}
