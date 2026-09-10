//! file_protocol.rs 单元测试 — 纯协议原语（时间/quote/CD/charset/etag/
//! Range/multipart/boundary）。known vectors 来自 /tmp/fresp_probe p10*
//! （FastAPI 0.141.1 + starlette 1.6.0 实测）+ RFC 1321/6455/5987/9110。

use super::file_protocol::*;

// ---------- fmt_rfc1123 ----------

#[test]
fn rfc1123_epoch() {
    assert_eq!(fmt_rfc1123(0), "Thu, 01 Jan 1970 00:00:00 GMT");
}

#[test]
fn rfc1123_probe_vector() {
    // p10c: mtime 1788996557.9171202 → "Wed, 09 Sep 2026 23:29:17 GMT"
    assert_eq!(fmt_rfc1123(1788996557), "Wed, 09 Sep 2026 23:29:17 GMT");
}

#[test]
fn rfc1123_leap_day_2000() {
    assert_eq!(fmt_rfc1123(951782400), "Tue, 29 Feb 2000 00:00:00 GMT");
}

#[test]
fn rfc1123_day_padding() {
    // 2026-01-05 07:48:09 UTC = 1767599289（date -u -R 交叉验证）
    assert_eq!(fmt_rfc1123(1767599289), "Mon, 05 Jan 2026 07:48:09 GMT");
}

// ---------- rfc5987_quote ----------

#[test]
fn quote_unreserved_verbatim() {
    assert_eq!(rfc5987_quote("report.txt"), "report.txt");
    assert_eq!(rfc5987_quote("a/b_c-d~e.f"), "a/b_c-d~e.f");
}

#[test]
fn quote_space_and_nonascii() {
    assert_eq!(rfc5987_quote("a b.txt"), "a%20b.txt");
    assert_eq!(rfc5987_quote("héllo"), "h%C3%A9llo");
}

// ---------- build_content_disposition ----------

#[test]
fn cd_plain_filename() {
    assert_eq!(
        build_content_disposition("report.txt", "attachment").as_deref(),
        Some("attachment; filename=\"report.txt\"")
    );
}

#[test]
fn cd_star_on_change() {
    assert_eq!(
        build_content_disposition("a b.txt", "attachment").as_deref(),
        Some("attachment; filename*=utf-8''a%20b.txt")
    );
}

#[test]
fn cd_inline() {
    assert_eq!(
        build_content_disposition("a b.txt", "inline").as_deref(),
        Some("inline; filename*=utf-8''a%20b.txt")
    );
}

#[test]
fn cd_empty_filename_none() {
    assert_eq!(build_content_disposition("", "attachment"), None);
}

// ---------- apply_charset_rule ----------

#[test]
fn charset_text_appended() {
    assert_eq!(apply_charset_rule("text/plain"), "text/plain; charset=utf-8");
    assert_eq!(apply_charset_rule("text/csv"), "text/csv; charset=utf-8");
}

#[test]
fn charset_non_text_verbatim() {
    assert_eq!(apply_charset_rule("application/json"), "application/json");
    assert_eq!(
        apply_charset_rule("application/octet-stream"),
        "application/octet-stream"
    );
}

#[test]
fn charset_existing_kept_and_case_sensitive_prefix() {
    assert_eq!(
        apply_charset_rule("text/csv; charset=iso-8859-1"),
        "text/csv; charset=iso-8859-1"
    );
    // 前缀大小写敏感（上游 startswith("text/")）
    assert_eq!(apply_charset_rule("TEXT/PLAIN"), "TEXT/PLAIN");
}

// ---------- etag ----------

#[test]
fn etag_probe_vector() {
    // p10b/p10c 实测: md5("1788996557.9171202-10") = 588d6b9d7f2b830e63aed185c35d2763
    assert_eq!(
        etag_from_mtime_size(1788996557.9171202, 10),
        "\"588d6b9d7f2b830e63aed185c35d2763\""
    );
}

#[test]
fn etag_stable_and_quoted() {
    let a = etag_from_mtime_size(1788996557.9171202, 10);
    let b = etag_from_mtime_size(1788996557.9171202, 10);
    assert_eq!(a, b);
    assert_eq!(a.len(), 34); // " + 32hex + "
}

// ---------- parse_range_header ----------

fn ok(v: Vec<(i64, i64)>) -> Result<Vec<(i64, i64)>, RangeErr> {
    Ok(v)
}

#[test]
fn range_no_eq_default_msg() {
    assert_eq!(
        parse_range_header("foo", 10),
        Err(RangeErr::Malformed("Malformed range header.".into()))
    );
    assert_eq!(
        parse_range_header("", 10),
        Err(RangeErr::Malformed("Malformed range header.".into()))
    );
}

#[test]
fn range_bad_unit() {
    assert_eq!(
        parse_range_header("items=0-5", 10),
        Err(RangeErr::Malformed("Only support bytes range".into()))
    );
    // 大小写: "BYTES" → lower == bytes (Python .lower())
    assert_eq!(parse_range_header("BYTES=0-1", 10), ok(vec![(0, 2)]));
}

#[test]
fn range_must_be_requested() {
    let msg = RangeErr::Malformed("Range header: range must be requested".into());
    assert_eq!(parse_range_header("bytes=", 10), Err(msg.clone()));
    assert_eq!(parse_range_header("bytes=-", 10), Err(msg.clone()));
    assert_eq!(parse_range_header("bytes=abc-def", 10), Err(msg.clone()));
    assert_eq!(parse_range_header("bytes=abc,def", 10), Err(msg));
}

#[test]
fn range_start_lt_end() {
    assert_eq!(
        parse_range_header("bytes=5-3", 10),
        Err(RangeErr::Malformed(
            "Range header: start must be less than end".into()
        ))
    );
    // "5--3": end = -3 < 10 → -2 → (5,-2) → start>=end
    assert_eq!(
        parse_range_header("bytes=5--3", 10),
        Err(RangeErr::Malformed(
            "Range header: start must be less than end".into()
        ))
    );
}

#[test]
fn range_unsatisfiable_precedence() {
    // start 越界先于 start>=end 判定
    assert_eq!(
        parse_range_header("bytes=100-200", 10),
        Err(RangeErr::Unsatisfiable(10))
    );
    assert_eq!(
        parse_range_header("bytes=10-", 10),
        Err(RangeErr::Unsatisfiable(10))
    );
    // 注意: suffix "-1" = start max(10-1,0)=9 < 10 → 合法 (见 range_suffix)
}

#[test]
fn range_suffix() {
    assert_eq!(parse_range_header("bytes=-4", 10), ok(vec![(6, 10)]));
    // -100 截断到 0
    assert_eq!(parse_range_header("bytes=-100", 10), ok(vec![(0, 10)]));
    assert_eq!(parse_range_header("bytes=-1", 10), ok(vec![(9, 10)]));
}

#[test]
fn range_open_and_clamp() {
    assert_eq!(parse_range_header("bytes=7-", 10), ok(vec![(7, 10)]));
    assert_eq!(parse_range_header("bytes=0-999", 10), ok(vec![(0, 10)]));
    assert_eq!(parse_range_header("bytes=0-3", 10), ok(vec![(0, 4)]));
}

#[test]
fn range_malformed_part_skipped() {
    // "abc" 无 "-" 跳过, "0-1" 保留 (p10c MF9)
    assert_eq!(parse_range_header("bytes=abc,0-1", 10), ok(vec![(0, 2)]));
    // "5-abc": e 非数字 → 整个 part 跳过 (Python try/except 语义)
    assert_eq!(
        parse_range_header("bytes=5-abc", 10),
        Err(RangeErr::Malformed(
            "Range header: range must be requested".into()
        ))
    );
}

#[test]
fn range_merge_overlapping() {
    // p10c MG1: 0-1,1-3 → 合并 0-4 (end 排他 → 0-3 含尾)
    assert_eq!(parse_range_header("bytes=0-1,1-3", 10), ok(vec![(0, 4)]));
    // 无序: 5-6,0-1 → 排序后两段独立
    assert_eq!(
        parse_range_header("bytes=5-6,0-1", 10),
        ok(vec![(0, 2), (5, 7)])
    );
    // 0-9,2-3 完全包含 → 0-10
    assert_eq!(parse_range_header("bytes=0-9,2-3", 10), ok(vec![(0, 10)]));
}

#[test]
fn range_101_parts_full_response() {
    // 101 段（max_ranges=100）→ []（→200 全量 quirk，先于解析）
    let parts: Vec<String> = (0..101).map(|i| format!("{i}-{i}")).collect();
    assert_eq!(parse_range_header(&format!("bytes={}", parts.join(",")), 1000), ok(Vec::new()));
    // 100 个相邻单字节段：上游合并语义 `start <= last_end` → 单段 (0,100)
    let parts: Vec<String> = (0..100).map(|i| format!("{i}-{i}")).collect();
    assert_eq!(
        parse_range_header(&format!("bytes={}", parts.join(",")), 1000),
        ok(vec![(0, 100)])
    );
    // 100 个不相邻段：不合并，原样保留
    let parts: Vec<String> = (0..100).map(|i| format!("{}-{}", i * 2, i * 2)).collect();
    let r = parse_range_header(&format!("bytes={}", parts.join(",")), 1000).unwrap();
    assert_eq!(r.len(), 100);
    assert_eq!(r[0], (0, 1));
    assert_eq!(r[99], (198, 199));
}

#[test]
fn range_overflow_i64() {
    // 超 i64: 我们跳过该 part (上游 Python int 无界 → 416; 文档化偏差 §3.5)
    assert_eq!(
        parse_range_header("bytes=99999999999999999999-", 10),
        Err(RangeErr::Malformed(
            "Range header: range must be requested".into()
        ))
    );
}

#[test]
fn range_whitespace_tolerated() {
    assert_eq!(parse_range_header("bytes = 1-2", 10), ok(vec![(1, 3)]));
    assert_eq!(parse_range_header("bytes= 1 - 2 ", 10), ok(vec![(1, 3)]));
}

// ---------- multipart_content_length ----------

#[test]
fn multipart_len_probe_vector() {
    // p10c MP2: size=10, boundary 26 hex, ct="text/plain; charset=utf-8",
    // ranges (0,2),(5,7) → 实测 242
    assert_eq!(
        multipart_content_length(&[(0, 2), (5, 7)], 26, "text/plain; charset=utf-8", 10),
        242
    );
}

#[test]
fn multipart_len_single_part() {
    // 手算: 段 49+26+24+1+1+1+4=106（"application/octet-stream" = 24 字符）
    //      + 终止符 4+26=30 → 136
    assert_eq!(
        multipart_content_length(&[(0, 4)], 26, "application/octet-stream", 9),
        136
    );
}

// ---------- boundary ----------

#[test]
fn boundary_format() {
    let b = generate_boundary(42, 1234);
    assert_eq!(b.len(), 26);
    assert!(b.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
}
