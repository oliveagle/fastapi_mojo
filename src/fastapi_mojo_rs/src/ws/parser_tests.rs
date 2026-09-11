// parser_tests.rs — RFC 6455 parser + RFC 7692 RSV1/decomp 状态回归
// 从 ws_tests.rs 拆分，保持测试文件与生产代码同目录且低于 500 行。
use super::*;

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

// --- RFC 7692: RSV1 压缩 payload 重定向 decomp 缓冲 ---
#[test]
fn parser_feed_compressed_message_redirects_payload() {
    let frame = [0xC1u8, 0x85, 0, 0, 0, 0, b'h', b'e', b'l', b'l', b'o'];
    let mut p = new_parser();
    let mut reasm = [0u8; 32];
    let mut decomp = [0u8; 32];
    p.deflate_enabled = 1;
    p.decomp_addr = decomp.as_mut_ptr() as usize;
    p.decomp_cap = decomp.len();
    let mut op = 0;
    let mut ml = 0;
    let mut consumed = 0;
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
    assert_eq!((op, ml), (1, 5));
    assert_eq!(&decomp[..ml], b"hello");
    assert_eq!(p.msg_rsv, 1);
}

#[test]
fn parser_feed_compressed_fragment_accumulates_decomp() {
    let f1 = [0x41u8, 0x82, 0, 0, 0, 0, b'a', b'b'];
    let f2 = [0x80u8, 0x83, 0, 0, 0, 0, b'c', b'd', b'e'];
    let mut p = new_parser();
    let mut reasm = [0u8; 32];
    let mut decomp = [0u8; 32];
    p.deflate_enabled = 1;
    p.decomp_addr = decomp.as_mut_ptr() as usize;
    p.decomp_cap = decomp.len();
    let mut op = 0;
    let mut ml = 0;
    let mut consumed = 0;
    let mut r = ws_parser_feed(
        &mut p as *mut _, f1.as_ptr(), f1.len(), &mut op, &mut ml,
        reasm.as_mut_ptr(), reasm.len(), &mut consumed,
    );
    assert_eq!(r, 0);
    r = ws_parser_feed(
        &mut p as *mut _, f2.as_ptr(), f2.len(), &mut op, &mut ml,
        reasm.as_mut_ptr(), reasm.len(), &mut consumed,
    );
    assert_eq!(r, 1);
    assert_eq!(ml, 5);
    assert_eq!(&decomp[..ml], b"abcde");
}

#[test]
fn parser_feed_rsv1_requires_negotiation_and_first_data_frame() {
    let compressed = [0xC1u8, 0x82, 0, 0, 0, 0, 1, 2];
    let continuation = [0xC0u8, 0x82, 0, 0, 0, 0, 1, 2];
    let control = [0xC9u8, 0x82, 0, 0, 0, 0, 1, 2];
    for frame in [&compressed, &control] {
        let mut p = new_parser();
        let mut reasm = [0u8; 16];
        let mut decomp = [0u8; 16];
        p.decomp_addr = decomp.as_mut_ptr() as usize;
        p.decomp_cap = decomp.len();
        let mut op = 0;
        let mut ml = 0;
        let mut consumed = 0;
        assert_eq!(ws_parser_feed(
            &mut p as *mut _, frame.as_ptr(), frame.len(), &mut op, &mut ml,
            reasm.as_mut_ptr(), reasm.len(), &mut consumed,
        ), -1);
    }

    let mut p = new_parser();
    let mut reasm = [0u8; 16];
    let mut decomp = [0u8; 16];
    p.deflate_enabled = 1;
    p.decomp_addr = decomp.as_mut_ptr() as usize;
    p.decomp_cap = decomp.len();
    p.in_msg = 1;
    p.msg_rsv = 1;
    p.decomp_len = 2;
    let mut op = 0;
    let mut ml = 0;
    let mut consumed = 0;
    assert_eq!(ws_parser_feed(
        &mut p as *mut _, continuation.as_ptr(), continuation.len(), &mut op, &mut ml,
        reasm.as_mut_ptr(), reasm.len(), &mut consumed,
    ), -1);
}

#[test]
fn parser_feed_compressed_capacity_error_does_not_write_oob() {
    let frame = [0xC1u8, 0x85, 0, 0, 0, 0, 1, 2, 3, 4, 5];
    let mut p = new_parser();
    let mut reasm = [0u8; 16];
    let mut decomp = [0xFFu8; 3];
    p.deflate_enabled = 1;
    p.decomp_addr = decomp.as_mut_ptr() as usize;
    p.decomp_cap = decomp.len();
    let mut op = 0;
    let mut ml = 0;
    let mut consumed = 0;
    assert_eq!(ws_parser_feed(
        &mut p as *mut _, frame.as_ptr(), frame.len(), &mut op, &mut ml,
        reasm.as_mut_ptr(), reasm.len(), &mut consumed,
    ), -2);
    assert_eq!(decomp, [0xFFu8; 3]);
}

// --- WsParser 初始化 (RFC 7692 字段随全零初始化) ---
#[test]
fn ws_parser_zero_init_is_valid() {
    let p = WsParser::new();
    assert_eq!(p.rsv, 0);
    assert_eq!(p.msg_rsv, 0);
    assert_eq!(p.decomp_len, 0);
    assert_eq!(p.decomp_cap, 0);
    assert!(p.decomp_addr == 0);
    assert_eq!(p.deflate_enabled, 0);
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
        rsv: 0,
        msg_rsv: 0,
        decomp_len: 0,
        decomp_addr: 0,
        decomp_cap: 0,
        deflate_enabled: 0,
    }
}
