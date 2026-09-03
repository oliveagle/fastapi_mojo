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

// --- 帧解析器: 完整小文本帧单帧 (掩码, FIN=1) ---
#[test]
fn parser_feed_single_text_frame() {
    let frame: [u8; 11] = [
        0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58,
    ];
    let mut p = new_parser();
    let mut reasm = [0u8; 64];
    let mut op: c_int = 0;
    let mut ml: usize = 0;
    let mut consumed: usize = 0;
    let r = ws_parser_feed(
        &mut p as *mut _,
        frame.as_ptr(),
        frame.len(),
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r, 1, "data message complete");
    assert_eq!(op, 1, "opcode = text");
    assert_eq!(ml, 5);
    assert_eq!(&reasm[..ml], b"Hello");
    assert_eq!(consumed, frame.len());
}

// --- 帧解析器: 未掩码 (协议错误 -> -1) ---
#[test]
fn parser_feed_unmasked_rejected() {
    let frame: [u8; 3] = [0x81, 0x01, 0x41];
    let mut p = new_parser();
    let mut reasm = [0u8; 64];
    let mut op: c_int = 0;
    let mut ml: usize = 0;
    let mut consumed: usize = 0;
    let r = ws_parser_feed(
        &mut p as *mut _,
        frame.as_ptr(),
        frame.len(),
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r, -1, "unmasked client frame must be rejected");
}

// --- 帧解析器: 16-bit 长度 (126..65535), mask 全零 -> 载荷原值 ---
#[test]
fn parser_feed_16bit_length() {
    let len: usize = 200;
    let mut frame = vec![0u8; 4 + 4 + len];
    frame[0] = 0x82; // FIN=1, opcode=2 (binary)
    frame[1] = 0xFE; // MASK=1, len 标记 = 126 -> 16-bit ext
    frame[2] = ((len >> 8) & 0xFF) as u8;
    frame[3] = (len & 0xFF) as u8;
    // bytes 4..8 = mask key (全零)
    for i in 0..len {
        frame[8 + i] = (i & 0xFF) as u8;
    }
    let mut p = new_parser();
    let mut reasm = vec![0u8; 1024];
    let mut op: c_int = 0;
    let mut ml: usize = 0;
    let mut consumed: usize = 0;
    let r = ws_parser_feed(
        &mut p as *mut _,
        frame.as_ptr(),
        frame.len(),
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r, 1);
    assert_eq!(op, 2);
    assert_eq!(ml, len);
    assert_eq!(reasm[0], 0);
    assert_eq!(reasm[100], 100);
    assert_eq!(reasm[199], 199);
}

// --- 帧解析器: 64-bit 长度 (>65535) 大帧边界 ---
#[test]
fn parser_feed_64bit_length() {
    let len: usize = 70000;
    let mut frame = vec![0u8; 8 + 8 + len];
    frame[0] = 0x82;
    frame[1] = 0xFF; // MASK=1, len 标记 = 127 -> 64-bit ext
    let blen = len as u64;
    for i in 0..8 {
        frame[2 + i] = ((blen >> (56 - 8 * i)) & 0xFF) as u8;
    }
    // bytes 10..14 = mask key (全零)
    for i in 0..len {
        frame[14 + i] = (i & 0xFF) as u8;
    }
    let mut p = new_parser();
    let mut reasm = vec![0u8; WS_MAX_MSG + 1];
    let mut op: c_int = 0;
    let mut ml: usize = 0;
    let mut consumed: usize = 0;
    let r = ws_parser_feed(
        &mut p as *mut _,
        frame.as_ptr(),
        frame.len(),
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r, 1);
    assert_eq!(op, 2);
    assert_eq!(ml, len);
    assert_eq!(reasm[0], 0);
    assert_eq!(reasm[69999], (69999 & 0xFF) as u8);
}

// --- 帧解析器: 多帧同块 (ADR-0009 P0 — 合并帧不丢) ---
#[test]
fn parser_feed_two_frames_in_one_block() {
    let mut combined = vec![0x81u8, 0x82, 0x00, 0x00, 0x00, 0x00, 0x48, 0x69];
    combined.extend_from_slice(&[0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 0x4f, 0x4b]);

    let mut p = new_parser();
    let mut reasm = [0u8; 64];
    let mut op: c_int = 0;
    let mut ml: usize = 0;
    let mut consumed: usize = 0;

    let r1 = ws_parser_feed(
        &mut p as *mut _,
        combined.as_ptr(),
        combined.len(),
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r1, 1);
    assert_eq!(&reasm[..ml], b"Hi");

    let r2 = ws_parser_feed(
        &mut p as *mut _,
        unsafe { combined.as_ptr().add(consumed) },
        combined.len() - consumed,
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r2, 1);
    assert_eq!(&reasm[..ml], b"OK");
}

// --- 帧解析器: 分片重组 (FIN=0 + 延续帧) ---
#[test]
fn parser_feed_fragmented_message() {
    // "Hello" (FIN=0, text) + "World" (FIN=1, continuation)
    let f1 = vec![0x01u8, 0x85, 0, 0, 0, 0, 0x48, 0x65, 0x6c, 0x6c, 0x6f];
    let f2 = vec![0x80u8, 0x85, 0, 0, 0, 0, 0x57, 0x6f, 0x72, 0x6c, 0x64];
    let mut block = f1;
    block.extend_from_slice(&f2);

    let mut p = new_parser();
    let mut reasm = [0u8; 64];
    let mut op: c_int = 0;
    let mut ml: usize = 0;
    let mut consumed: usize = 0;

    // 同块内: 第一帧 FIN=0 不产生返回, parser 继续解析下一帧;
    // 整个块结束时消息已重组完整 (与 C 版 ws_parser_feed 语义一致)
    let r1 = ws_parser_feed(
        &mut p as *mut _,
        block.as_ptr(),
        block.len(),
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r1, 1, "whole block re-assembles the fragmented message");
    assert_eq!(op, 1);
    assert_eq!(ml, 10);
    assert_eq!(&reasm[..ml], b"HelloWorld");
    assert_eq!(consumed, block.len());

    // 剩余重放为空 -> 返回 0
    let r2 = ws_parser_feed(
        &mut p as *mut _,
        unsafe { block.as_ptr().add(consumed) },
        block.len() - consumed,
        &mut op,
        &mut ml,
        reasm.as_mut_ptr(),
        reasm.len(),
        &mut consumed,
    );
    assert_eq!(r2, 0, "nothing left");
}

// --- 帧解析器: reasm 容量不足 -> -2 (未越界写入, 扩容重放) ---
#[test]
fn parser_feed_requires_growth() {
    let payload: Vec<u8> = (0..10u8).collect();
    let mut frame = vec![0x81u8, 0x8A, 0, 0, 0, 0];
    frame.extend_from_slice(&payload);

    let mut p = new_parser();
    let mut small_reasm = [0u8; 5];
    let mut op: c_int = 0;
    let mut ml: usize = 0;
    let mut consumed: usize = 0;
    let r = ws_parser_feed(
        &mut p as *mut _,
        frame.as_ptr(),
        frame.len(),
        &mut op,
        &mut ml,
        small_reasm.as_mut_ptr(),
        small_reasm.len(),
        &mut consumed,
    );
    assert_eq!(r, -2, "reasm too small -> -2 without overflow");
    assert_eq!(consumed, 6, "consumed points at payload start");

    let mut big_reasm = [0u8; 64];
    let r2 = ws_parser_feed(
        &mut p as *mut _,
        unsafe { frame.as_ptr().add(consumed) },
        frame.len() - consumed,
        &mut op,
        &mut ml,
        big_reasm.as_mut_ptr(),
        big_reasm.len(),
        &mut consumed,
    );
    assert_eq!(r2, 1);
    assert_eq!(ml, 10);
    assert_eq!(&big_reasm[..ml], &payload[..]);
}

// --- close 码校验 (同 crate 私有可见) ---
#[test]
fn close_code_valid() {
    let mut code: c_int = 0;
    assert_eq!(ws_parse_close_code(&[0x03, 0xE8], &mut code), 1); // 1000
    assert_eq!(code, 1000);
    assert_eq!(ws_parse_close_code(&[0x03, 0xE9], &mut code), 1); // 1001
    assert_eq!(ws_parse_close_code(&[0x0B, 0xB8], &mut code), 1); // 3000
    assert_eq!(ws_parse_close_code(&[0x13, 0x87], &mut code), 1); // 4999
}

#[test]
fn close_code_empty() {
    let mut code: c_int = 0;
    assert_eq!(ws_parse_close_code(&[], &mut code), 0);
    assert_eq!(code, 0);
}

#[test]
fn close_code_invalid() {
    let mut code: c_int = 0;
    assert_eq!(ws_parse_close_code(&[0x03], &mut code), -1); // 单字节
    assert_eq!(ws_parse_close_code(&[0x03, 0xEA], &mut code), -1); // 1002
    assert_eq!(ws_parse_close_code(&[0x03, 0xEB], &mut code), -1); // 1003
    assert_eq!(ws_parse_close_code(&[0x03, 0xEF], &mut code), -1); // 1007
    assert_eq!(ws_parse_close_code(&[0x0B, 0xB7], &mut code), -1); // 2999
    assert_eq!(ws_parse_close_code(&[0x13, 0x88], &mut code), -1); // 5000
}

// --- WsParser 结构体布局 (与 C 镜像逐字段一致) ---
#[test]
fn ws_parser_layout_size() {
    assert_eq!(
        std::mem::size_of::<WsParser>(),
        72,
        "WsParser size must match C mirror (x86_64 SysV)"
    );
}

// --- 辅助: 构造清零 parser ---
fn new_parser() -> WsParser {
    WsParser {
        stage: 0,
        fin: 0,
        opcode: 0,
        masked: 0,
        ext: [0; 8],
        ext_need: 0,
        ext_got: 0,
        flen: 0,
        mask: [0; 4],
        mask_got: 0,
        pgot: 0,
        in_msg: 0,
        msg_opcode: 0,
        reasm_len: 0,
    }
}
