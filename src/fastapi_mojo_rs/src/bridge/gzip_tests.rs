// gzip.rs 单元测试 (决策-40 ADR-0015 → 决策-78 ADR-0053, Starlette 1.6.0 对齐)
use super::gzip::*;

fn cfg(enabled: bool, min_size: usize) -> GzipConfig {
    GzipConfig {
        enabled,
        min_size,
        max_size: 0,
        level: 9,
        exclude: DEFAULT_EXCLUDE.iter().map(|s| s.to_string()).collect(),
    }
}

#[test]
fn plan_matrix() {
    let on = cfg(true, 500);
    let j = "application/json";
    // 未启用 → skip
    assert_eq!(plan(&cfg(false, 500), j, 1000, "200 OK", None, true, true, false), SKIP);
    // client 不接受 gzip → 仍 vary（上游在可压响应上恒加 Vary）, 但不压缩
    assert_eq!(
        plan(&on, j, 1000, "200 OK", None, false, true, false),
        GzipPlan { vary: true, compress: false }
    );
    // 空 body (< min) → skip
    assert_eq!(plan(&on, j, 0, "200 OK", None, true, true, false), SKIP);
    // 低于 min 边界
    assert_eq!(plan(&on, j, 499, "200 OK", None, true, true, false), SKIP);
    assert_eq!(
        plan(&on, j, 500, "200 OK", None, true, true, false),
        GzipPlan { vary: true, compress: true }
    );
    // 206 partial → skip（上游 partial_response）
    assert_eq!(plan(&on, j, 1000, "206 Partial Content", None, true, true, false), SKIP);
    // extra 已声明 Content-Encoding → skip
    assert_eq!(
        plan(&on, j, 1000, "200 OK", Some("Content-Encoding: br\r\nX: 1"), true, true, false),
        SKIP
    );
    // HEAD (include_body=false) → skip
    assert_eq!(plan(&on, j, 1000, "200 OK", None, true, false, false), SKIP);
    // 排除 media type（text/event-stream / image/png / video/*）
    assert_eq!(plan(&on, "text/event-stream", 1000, "200 OK", None, true, true, false), SKIP);
    assert_eq!(plan(&on, "image/png", 1000, "200 OK", None, true, true, false), SKIP);
    assert_eq!(plan(&on, "image/png; charset=x", 1000, "200 OK", None, true, true, false), SKIP);
    assert_eq!(plan(&on, "video/mp4", 1000, "200 OK", None, true, true, false), SKIP);
    assert_eq!(plan(&on, "audio/mpeg", 1000, "200 OK", None, true, true, false), SKIP);
    assert_eq!(plan(&on, "font/woff2", 1000, "200 OK", None, true, true, false), SKIP);
    // 未排除（image/svg+xml / text/html / application/octet-stream）
    assert!(plan(&on, "image/svg+xml", 1000, "200 OK", None, true, true, false).compress);
    assert!(plan(&on, "text/html; charset=utf-8", 1000, "200 OK", None, true, true, false).compress);
    assert!(plan(&on, "application/octet-stream", 1000, "200 OK", None, true, true, false).compress);
    // 空 media type → 不排除
    assert!(plan(&on, "", 1000, "200 OK", None, true, true, false).compress);
    // 默认表 + 全通配
    assert!(media_type_excluded("text/event-stream", &on.exclude));
    assert!(media_type_excluded("image/png", &on.exclude));
    assert!(media_type_excluded("video/mp4", &on.exclude)); // 默认表含 video/*
    assert!(!media_type_excluded("image/ANY", &on.exclude)); // 默认表 image 为具体类型
    assert!(!media_type_excluded("image/svg+xml", &on.exclude));
    assert!(!media_type_excluded("", &on.exclude));
    // streaming: 不受 min_size 门
    assert_eq!(
        plan(&on, j, 10, "200 OK", None, true, true, true),
        GzipPlan { vary: true, compress: true }
    );
    assert_eq!(plan(&on, "text/event-stream", 10, "200 OK", None, true, true, true), SKIP);
    // 可选上限（非上游）: 超大体 → vary 但 compress=false
    let capped = GzipConfig { max_size: 1000, ..cfg(true, 500) };
    assert_eq!(plan(&capped, j, 2000, "200 OK", None, true, true, false), GzipPlan { vary: true, compress: false });
}

#[test]
fn media_type_excluded_empty_and_star() {
    let ex = vec!["image/*".to_string(), "application/zip".to_string()];
    assert!(media_type_excluded("image/png", &ex));
    assert!(media_type_excluded("IMAGE/GIF; x=1", &ex));
    assert!(media_type_excluded("application/zip", &ex));
    assert!(!media_type_excluded("application/gzip", &ex));
    assert!(!media_type_excluded("", &ex));
}

#[test]
fn default_config_reads_env() {
    // 只调 default_config() 纯函数 (不触碰 config() Mutex, 无进程级污染)
    std::env::set_var("FASTAPI_MOJO_GZIP", "1");
    std::env::set_var("FASTAPI_MOJO_GZIP_MIN_SIZE", "123");
    std::env::set_var("FASTAPI_MOJO_GZIP_LEVEL", "6");
    let c = default_config();
    assert!(c.enabled);
    assert_eq!(c.min_size, 123);
    assert_eq!(c.max_size, 0); // 上游无上限
    assert_eq!(c.level, 6);
    assert!(c.exclude.iter().any(|e| e == "text/event-stream")); // 默认排除表
    std::env::remove_var("FASTAPI_MOJO_GZIP");
    std::env::remove_var("FASTAPI_MOJO_GZIP_MIN_SIZE");
    std::env::remove_var("FASTAPI_MOJO_GZIP_LEVEL");
    let c2 = default_config();
    assert!(!c2.enabled);
    assert_eq!(c2.min_size, 500);
    assert_eq!(c2.level, 9);
}

#[test]
fn default_config_exclude_env_overrides() {
    std::env::set_var("FASTAPI_MOJO_GZIP_EXCLUDE", "text/plain, Application/X-Test");
    let c = default_config();
    assert_eq!(c.exclude, vec!["text/plain".to_string(), "application/x-test".to_string()]);
    std::env::remove_var("FASTAPI_MOJO_GZIP_EXCLUDE");
}

#[test]
fn gzip_compress_roundtrip_text() {
    let body = vec![b'h'; 4096];
    let gz = gzip_compress(&body, 9).expect("compress");
    assert_eq!(&gz[..2], &[0x1f, 0x8b]); // gzip magic
    let mut dec = flate2::read::GzDecoder::new(&gz[..]);
    let mut out = Vec::new();
    std::io::Read::read_to_end(&mut dec, &mut out).unwrap();
    assert_eq!(out, body);
    assert!(gz.len() < body.len(), "repetitive text must shrink");
}

#[test]
fn gzip_compress_roundtrip_binary_0_255() {
    let body: Vec<u8> = (0..=255).cycle().take(2000).collect();
    let gz = gzip_compress(&body, 9).unwrap();
    let mut dec = flate2::read::GzDecoder::new(&gz[..]);
    let mut out = Vec::new();
    std::io::Read::read_to_end(&mut dec, &mut out).unwrap();
    assert_eq!(out, body);
}

#[test]
fn plan_empty_streaming_is_skipped() {
    // 上游: 空流 (唯一 body 消息 more_body=False) 落入 small-response 分支 →
    // 不压也不加 Vary。非空流不受 min_size 门。
    let on = cfg(true, 500);
    assert_eq!(plan(&on, "application/json", 0, "200 OK", None, true, true, true), SKIP);
    assert_eq!(
        plan(&on, "application/json", 1, "200 OK", None, true, true, true),
        GzipPlan { vary: true, compress: true }
    );
}

#[test]
fn extra_add_lines_order_and_merge() {
    // 顺序 = 上游 add_vary_header 先, Content-Encoding 后。
    assert_eq!(extra_add_lines(false, false), None);
    assert_eq!(extra_add_lines(true, false).unwrap(), "Vary: Accept-Encoding");
    assert_eq!(
        extra_add_lines(true, true).unwrap(),
        "Vary: Accept-Encoding\r\nContent-Encoding: gzip"
    );
    // 合并进既有 extra (空 / 非空)
    assert_eq!(merge_extra("", true, true), "Vary: Accept-Encoding\r\nContent-Encoding: gzip");
    assert_eq!(
        merge_extra("X-A: 1\r\nX-B: 2", true, false),
        "X-A: 1\r\nX-B: 2\r\nVary: Accept-Encoding"
    );
    assert_eq!(merge_extra("X-A: 1", false, false), "X-A: 1");
}

#[test]
fn extra_has_content_encoding_case_insensitive() {
    assert!(extra_has_content_encoding("content-encoding: br"));
    assert!(extra_has_content_encoding("X: 1\r\nContent-Encoding: gzip"));
    assert!(!extra_has_content_encoding("X-Content-Encoding: gzip"));
    assert!(!extra_has_content_encoding("Content-Type: text/html"));
    assert!(!extra_has_content_encoding(""));
}
