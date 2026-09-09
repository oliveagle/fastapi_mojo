// gzip.rs 单元测试 (决策-40, ADR-0015)
use super::gzip::*;

#[test]
fn should_gzip_matrix() {
    let on = GzipConfig {
        enabled: true,
        min_size: 500,
        max_size: 1024,
    };
    // 未启用
    assert!(!should_gzip(
        &GzipConfig {
            enabled: false,
            ..on
        },
        1000,
        "200 OK",
        None,
        true,
        true
    ));
    // client 不接受
    assert!(!should_gzip(&on, 1000, "200 OK", None, false, true));
    // 空 body
    assert!(!should_gzip(&on, 0, "200 OK", None, true, true));
    // 低于 min (500 边界含)
    assert!(!should_gzip(&on, 499, "200 OK", None, true, true));
    assert!(should_gzip(&on, 500, "200 OK", None, true, true));
    // 高于 max
    assert!(!should_gzip(&on, 1025, "200 OK", None, true, true));
    // 304
    assert!(!should_gzip(&on, 1000, "304 Not Modified", None, true, true));
    // extra 已声明 Content-Encoding
    assert!(!should_gzip(
        &on,
        1000,
        "200 OK",
        Some("Content-Encoding: br\r\nX: 1"),
        true,
        true
    ));
    // HEAD (include_body=false)
    assert!(!should_gzip(&on, 1000, "200 OK", None, true, false));
    // 全部满足
    assert!(should_gzip(&on, 1000, "200 OK", None, true, true));
    assert!(should_gzip(&on, 1000, "200 OK", Some("Allow: GET"), true, true));
}

#[test]
fn default_config_reads_env() {
    // 只调 default_config() 纯函数 (不触碰 config() OnceLock, 无进程级污染)
    std::env::set_var("FASTAPI_MOJO_GZIP", "1");
    std::env::set_var("FASTAPI_MOJO_GZIP_MIN_SIZE", "123");
    let c = default_config();
    assert!(c.enabled);
    assert_eq!(c.min_size, 123);
    assert_eq!(c.max_size, 1024 * 1024);
    std::env::remove_var("FASTAPI_MOJO_GZIP");
    std::env::remove_var("FASTAPI_MOJO_GZIP_MIN_SIZE");
    let c2 = default_config();
    assert!(!c2.enabled);
    assert_eq!(c2.min_size, 500);
}

#[test]
fn gzip_compress_roundtrip_text() {
    let body = vec![b'h'; 4096];
    let gz = gzip_compress(&body).expect("compress");
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
    let gz = gzip_compress(&body).unwrap();
    let mut dec = flate2::read::GzDecoder::new(&gz[..]);
    let mut out = Vec::new();
    std::io::Read::read_to_end(&mut dec, &mut out).unwrap();
    assert_eq!(out, body);
}
