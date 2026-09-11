// ws_tests.rs — RFC 6455 known vectors + ADR-0009 合并帧回归
// 与生产代码同目录约定 (AGENTS.md §3.2)。
// 通过 ws.rs 内的 `#[cfg(test)] mod ws_tests;` 编译 (同 crate, 可访问私有项)。
use super::*;

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for v in b {
        s.push_str(&format!("{:02x}", v));
    }
    s
}

fn bytes_eq(a: &[u8], hex_expected: &str) -> bool {
    hex(a) == hex_expected
}

// --- SHA-1 (FIPS 180-1) known vectors ---
#[test]
fn sha1_empty() {
    let mut out = [0u8; 20];
    ws_sha1(b"", &mut out);
    assert!(bytes_eq(&out, "da39a3ee5e6b4b0d3255bfef95601890afd80709"));
}

#[test]
fn sha1_abc() {
    let mut out = [0u8; 20];
    ws_sha1(b"abc", &mut out);
    assert!(bytes_eq(&out, "a9993e364706816aba3e25717850c26c9cd0d89d"));
}

#[test]
fn sha1_fox() {
    let mut out = [0u8; 20];
    ws_sha1(b"The quick brown fox jumps over the lazy dog", &mut out);
    assert!(bytes_eq(&out, "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12"));
}

// --- base64 encode known vectors (RFC 4648 §10) ---
#[test]
fn b64_empty() {
    let mut out = [0u8; 16];
    let n = ws_b64encode(&[], &mut out);
    assert_eq!(n, 0);
    assert_eq!(out[0], 0);
}

#[test]
fn b64_man() {
    let mut out = [0u8; 16];
    let n = ws_b64encode(b"Man", &mut out);
    assert_eq!(n, 4);
    assert_eq!(&out[..4], b"TWFu");
}

#[test]
fn b64_padding() {
    let mut out = [0u8; 16];
    let n = ws_b64encode(b"M", &mut out);
    assert_eq!(n, 4);
    assert_eq!(&out[..4], b"TQ==");
    let n = ws_b64encode(b"Ma", &mut out);
    assert_eq!(n, 4);
    assert_eq!(&out[..4], b"TWE=");
}

// --- Sec-WebSocket-Accept (RFC 6455 §1.3 已知例) ---
// key = "dGhlIHNhbXBsZSBub25jZQ==" -> accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
#[test]
fn compute_accept_rfc6455_example() {
    let mut out = [0u8; 64];
    let r = ws_compute_accept_inner(b"dGhlIHNhbXBsZSBub25jZQ==", &mut out);
    assert_eq!(r, 0);
    let len = out.iter().position(|&b| b == 0).unwrap();
    assert_eq!(&out[..len], b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

// --- UTF-8 校验 (公开 FFI 入口) ---
#[test]
fn utf8_valid_ascii() {
    assert_eq!(ws_validate_utf8(b"hello" as *const u8, 5), 1);
}

#[test]
fn utf8_valid_2byte() {
    let s = [0xC3u8, 0xA9]; // é
    assert_eq!(ws_validate_utf8(s.as_ptr(), 2), 1);
}

#[test]
fn utf8_valid_3byte_cjk() {
    let s = [0xE4u8, 0xB8, 0xAD]; // 中
    assert_eq!(ws_validate_utf8(s.as_ptr(), 3), 1);
}

#[test]
fn utf8_valid_4byte_emoji() {
    let s = [0xF0u8, 0x9F, 0x8E, 0x89]; // 🎉
    assert_eq!(ws_validate_utf8(s.as_ptr(), 4), 1);
}

#[test]
fn utf8_invalid_orphan_continuation() {
    let s = [0x80u8];
    assert_eq!(ws_validate_utf8(s.as_ptr(), 1), 0);
}

#[test]
fn utf8_invalid_truncated_2byte() {
    let s = [0xC3u8];
    assert_eq!(ws_validate_utf8(s.as_ptr(), 1), 0);
}

#[test]
fn utf8_invalid_overlong() {
    let s = [0xC0u8, 0xAF]; // overlong encoding of '/'
    assert_eq!(ws_validate_utf8(s.as_ptr(), 2), 0);
}

#[test]
fn utf8_invalid_surrogate() {
    let s = [0xEDu8, 0xA0, 0x80]; // U+D800 surrogate
    assert_eq!(ws_validate_utf8(s.as_ptr(), 3), 0);
}

// --- close 帧 payload 规范化 (wsproto 1.3.2 发送侧 parity, ADR-0026 决策-51) ---
#[test]
fn close_reason_payload_normal() {
    let mut out = [0u8; 125];
    let n = ws_close_reason_payload(1000, b"bye", &mut out);
    assert_eq!(n, 5);
    assert_eq!(&out[..n], &[0x03, 0xE8, b'b', b'y', b'e']);
}

#[test]
fn close_reason_payload_empty_reason() {
    let mut out = [0u8; 125];
    let n = ws_close_reason_payload(4001, b"", &mut out);
    assert_eq!(n, 2);
    assert_eq!(&out[..n], &[0x0F, 0xA1]); // 4001
}

#[test]
fn close_reason_payload_1005_no_payload() {
    let mut out = [0u8; 125];
    let n = ws_close_reason_payload(1005, b"ignored", &mut out);
    assert_eq!(n, 0);
}

#[test]
fn close_reason_payload_local_only_rewritten() {
    let mut out = [0u8; 125];
    for bad in [1004, 1006] {
        let n = ws_close_reason_payload(bad, b"r", &mut out);
        assert_eq!(n, 3);
        assert_eq!(&out[..2], &[0x03, 0xE8]); // 改写 1000
    }
}

#[test]
fn close_reason_payload_registered_codes() {
    let mut out = [0u8; 125];
    for (code, hi, lo) in [(1002u32, 0x03u32, 0xEA), (1003, 0x03, 0xEB),
                           (1007, 0x03, 0xEF), (1015, 0x03, 0xF7),
                           (3000, 0x0B, 0xB8), (4999, 0x13, 0x87)] {
        let n = ws_close_reason_payload(code as i32, b"", &mut out);
        assert_eq!(n, 2);
        assert_eq!(&out[..2], &[(hi as u8), (lo as u8)]);
    }
}

#[test]
fn close_reason_payload_truncate_ascii() {
    let reason = [b'x'; 200];
    let mut out = [0u8; 125];
    let n = ws_close_reason_payload(1000, &reason, &mut out);
    assert_eq!(n, 125);
    assert_eq!(&out[2..125], &[b'x'; 123]);
}

#[test]
fn close_reason_payload_truncate_multibyte_boundary() {
    // é = 2 bytes (0xC3 0xA9). 62 × é = 124 bytes -> 截断 123 落在
    // continuation byte -> 回退 122 (61 完整 é, codepoint 安全).
    let mut reason = Vec::new();
    for _ in 0..62 {
        reason.extend_from_slice(&[0xC3, 0xA9]);
    }
    let mut out = [0u8; 125];
    let n = ws_close_reason_payload(1000, &reason, &mut out);
    assert_eq!(n, 124); // 2 + 122
    assert_eq!(&out[2..n], &reason[..122]);
    // 无截断 (123 恰好 = 61.5? 不: 61 × 2 = 122 < 123) — 整段保留
    let mut short = Vec::new();
    for _ in 0..61 {
        short.extend_from_slice(&[0xC3, 0xA9]);
    }
    let n2 = ws_close_reason_payload(1000, &short, &mut out);
    assert_eq!(n2, 124);
    assert_eq!(&out[2..n2], &short);
}

#[test]
fn close_reason_payload_truncate_3byte() {
    // 中 = 3 bytes (0xE4 0xB8 0xAD). 41 × 中 = 123 恰好整除 -> 无回退.
    let mut r41 = Vec::new();
    for _ in 0..41 {
        r41.extend_from_slice(&[0xE4, 0xB8, 0xAD]);
    }
    let mut out = [0u8; 125];
    let n = ws_close_reason_payload(1000, &r41, &mut out);
    assert_eq!(n, 125);
    // 42 × 中 = 126 -> 截断 123 = 41 × 中 (123 % 3 == 0, 无回退)
    let mut r42 = Vec::new();
    for _ in 0..42 {
        r42.extend_from_slice(&[0xE4, 0xB8, 0xAD]);
    }
    let n2 = ws_close_reason_payload(1000, &r42, &mut out);
    assert_eq!(n2, 125);
    assert_eq!(&out[2..125], &r41);
}
