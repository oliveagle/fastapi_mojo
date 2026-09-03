//! ws.rs — WebSocket (RFC 6455) 协议原语 (ADR-0010 DC1)
//!
//! 行为等价翻译自 `ws.c` (380 LOC, ADR-0006~0009)。FFI 导出 6 符号
//! (ws_parser_init/feed, ws_handshake, ws_write_message, ws_validate_utf8,
//! ws_reply_close_buf) 与 C 版逐一对齐; `#[repr(C)]` 布局镜像
//! http_bridge_final.c 的 ws_parser_t (x86_64 SysV, 72B)。
//! 零第三方 crate; 内部辅助 ws_sha1/ws_b64encode/ws_compute_accept_inner/
//! ws_parse_close_code/ws_send_all 为本模块私有。
//! 行为等价门禁: src/ws/ws_tests.rs (RFC 6455 known vectors + ADR-0009 合并帧)。

use std::os::raw::{c_char, c_int, c_uchar, c_void};

pub mod parser;
pub use parser::{WsParser, ws_parser_feed, ws_parser_init};

// ========== 常量 ==========
pub const WS_MAX_MSG: usize = 1024 * 1024;
const WS_GUID: &[u8; 36] = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ========== 系统调用直连 (避免 libc crate 依赖) ==========
extern "C" {
    fn send(fd: c_int, buf: *const c_void, n: usize, flags: c_int) -> isize;
}

// ========== SHA-1 (FIPS 180-1, 行为等价 ws.c 第 37-77 行) ==========
fn ws_sha1(data: &[u8], out: &mut [u8; 20]) {
    let mut h: [u32; 5] = [
        0x67452301u32, 0xEFCDAB89u32, 0x98BADCFEu32, 0x10325476u32, 0xC3D2E1F0u32,
    ];
    let padded_len = ((data.len() + 8) / 64 + 1) * 64;
    let mut p = vec![0u8; padded_len];
    p[..data.len()].copy_from_slice(data);
    p[data.len()] = 0x80;
    let bitlen = (data.len() as u64) * 8;
    for i in 0..8 {
        p[padded_len - 1 - i] = ((bitlen >> (8 * i)) & 0xFF) as u8;
    }
    let mut w = [0u32; 80];
    for off in (0..padded_len).step_by(64) {
        for i in 0..16 {
            w[i] = ((p[off + 4 * i] as u32) << 24)
                | ((p[off + 4 * i + 1] as u32) << 16)
                | ((p[off + 4 * i + 2] as u32) << 8)
                | (p[off + 4 * i + 3] as u32);
        }
        // 预计算 w[16..80] 的新值, 避免 iter_mut() 与 w[i-3..i-16] 读取的借用冲突.
        // 算法 (RFC 3174 §6.1): w[i] = rotl(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1)
        // 关键: w[i] 依赖 w[i-3] (i >= 19 时是刚算的新值), 故必须级联预计算
        // —— 不能用未更新的 w 读 new_w[k+3] 等位置.
        let mut new_w = [0u32; 64];
        for k in 0..64usize {
            // k 对应原 w[i], i = k + 16
            let w_im3 = if k >= 3  { new_w[k - 3]  } else { w[k + 13] };
            let w_im8 = if k >= 8  { new_w[k - 8]  } else { w[k + 8]  };
            let w_im14 = if k >= 14 { new_w[k - 14] } else { w[k + 2]  };
            let w_im16 = if k >= 16 { new_w[k - 16] } else { w[k]      };
            new_w[k] = (w_im3 ^ w_im8 ^ w_im14 ^ w_im16).rotate_left(1);
        }
        for (wi, new) in w[16..].iter_mut().zip(new_w.iter()) {
            *wi = *new;
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (i, wi) in w.iter().enumerate() {
            let (f, k): (u32, u32) = if i < 20 {
                ((b & c) | (!b & d), 0x5A827999u32)
            } else if i < 40 {
                (b ^ c ^ d, 0x6ED9EBA1u32)
            } else if i < 60 {
                ((b & c) | (b & d) | (c & d), 0x8F1BBCDCu32)
            } else {
                (b ^ c ^ d, 0xCA62C1D6u32)
            };
            let tmp = a.rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = tmp;
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }
    for i in 0..5 {
        out[4 * i] = ((h[i] >> 24) & 0xFF) as u8;
        out[4 * i + 1] = ((h[i] >> 16) & 0xFF) as u8;
        out[4 * i + 2] = ((h[i] >> 8) & 0xFF) as u8;
        out[4 * i + 3] = (h[i] & 0xFF) as u8;
    }
}

// ========== base64 encode (行为等价 ws.c 第 79-97 行) ==========
fn ws_b64encode(input: &[u8], out: &mut [u8]) -> usize {
    const TBL: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut o: usize = 0;
    for chunk in input.chunks(3) {
        let b0 = chunk[0];
        let b1 = if chunk.len() > 1 { chunk[1] } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] } else { 0 };
        let t: u32 = ((b0 as u32) << 16) | ((b1 as u32) << 8) | (b2 as u32);
        if o + 4 < out.len() {
            out[o] = TBL[((t >> 18) & 0x3F) as usize];
            o += 1;
            out[o] = TBL[((t >> 12) & 0x3F) as usize];
            o += 1;
            out[o] = if chunk.len() > 1 {
                TBL[((t >> 6) & 0x3F) as usize]
            } else {
                b'='
            };
            o += 1;
            out[o] = if chunk.len() > 2 {
                TBL[(t & 0x3F) as usize]
            } else {
                b'='
            };
            o += 1;
        }
    }
    if o < out.len() {
        out[o] = 0;
    }
    o
}

// ========== Sec-WebSocket-Accept (RFC 6455 §4.1) ==========
fn ws_compute_accept_inner(key: &[u8], out: &mut [u8]) -> i32 {
    let mut data = Vec::with_capacity(key.len() + WS_GUID.len());
    data.extend_from_slice(key);
    data.extend_from_slice(WS_GUID);
    let mut sha = [0u8; 20];
    ws_sha1(&data, &mut sha);
    let len = ws_b64encode(&sha, out);
    if len < out.len() {
        out[len] = 0;
    }
    0
}

// ========== 短写重发 (行为等价 ws.c 第 114-125 行) ==========
fn ws_send_all(fd: c_int, buf: &[u8]) -> c_int {
    let mut sent = 0;
    while sent < buf.len() {
        let r = unsafe {
            send(
                fd,
                buf.as_ptr().add(sent) as *const c_void,
                buf.len() - sent,
                0,
            )
        };
        if r <= 0 {
            return -1;
        }
        sent += r as usize;
    }
    0
}

// ========== handshake (101 + Sec-WebSocket-Accept) ==========
#[no_mangle]
pub extern "C" fn ws_handshake(
    fd: c_int,
    key: *const c_char,
    subprotocol: *const c_char,
) -> c_int {
    // 读取 NUL 结尾 C 串 key
    let key_bytes = unsafe {
        let mut len = 0;
        while *key.add(len) != 0 {
            len += 1;
        }
        std::slice::from_raw_parts(key as *const u8, len)
    };

    // 计算 accept
    let mut accept = [0u8; 64];
    if ws_compute_accept_inner(key_bytes, &mut accept) != 0 {
        return -1;
    }
    let accept_str = match std::ffi::CStr::from_bytes_until_nul(&accept) {
        Ok(c) => match c.to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        },
        Err(_) => return -1,
    };

    // 读取可选 subprotocol (空/NULL = 不发送子协议头)
    let sub_bytes = unsafe {
        if subprotocol.is_null() {
            None
        } else {
            let mut len = 0;
            while *subprotocol.add(len) != 0 {
                len += 1;
            }
            if len == 0 {
                None
            } else {
                Some(std::slice::from_raw_parts(subprotocol as *const u8, len))
            }
        }
    };

    let mut resp = [0u8; 512];
    let n = if let Some(sp) = sub_bytes {
        let sp_str = match std::str::from_utf8(sp) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let s = format!(
            "HTTP/1.1 101 Switching Protocols\r\n\
             Upgrade: websocket\r\n\
             Connection: Upgrade\r\n\
             Sec-WebSocket-Accept: {}\r\n\
             Sec-WebSocket-Protocol: {}\r\n\r\n",
            accept_str, sp_str
        );
        if s.len() >= resp.len() {
            return -1;
        }
        resp[..s.len()].copy_from_slice(s.as_bytes());
        s.len()
    } else {
        let s = format!(
            "HTTP/1.1 101 Switching Protocols\r\n\
             Upgrade: websocket\r\n\
             Connection: Upgrade\r\n\
             Sec-WebSocket-Accept: {}\r\n\r\n",
            accept_str
        );
        if s.len() >= resp.len() {
            return -1;
        }
        resp[..s.len()].copy_from_slice(s.as_bytes());
        s.len()
    };

    ws_send_all(fd, &resp[..n])
}

// ========== write_message (单帧, 服务端不掩码, FIN=1) ==========
#[no_mangle]
pub extern "C" fn ws_write_message(
    fd: c_int,
    opcode: c_int,
    payload: *const c_uchar,
    plen: usize,
) -> c_int {
    let payload_slice: &[u8] = if plen == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(payload, plen) }
    };
    let mut hdr = [0u8; 10];
    hdr[0] = 0x80 | (opcode as u8 & 0x0F); // FIN=1, 不掩码
    let hlen: usize = if plen < 126 {
        hdr[1] = plen as u8;
        2
    } else if plen <= 0xFFFF {
        hdr[1] = 126;
        hdr[2] = ((plen >> 8) & 0xFF) as u8;
        hdr[3] = (plen & 0xFF) as u8;
        4
    } else {
        hdr[1] = 127;
        for i in 0..8 {
            hdr[2 + i] = ((plen >> (56 - 8 * i)) & 0xFF) as u8;
        }
        10
    };
    if ws_send_all(fd, &hdr[..hlen]) != 0 {
        return -1;
    }
    if !payload_slice.is_empty() && ws_send_all(fd, payload_slice) != 0 {
        return -1;
    }
    0
}

// ========== parse_close_code (内部辅助; reply_close_buf 使用) ==========
//   1 = 合法 (1000/1001/3000..4999, 可回显)
//   0 = 空 payload (按 1000 回复)
//  -1 = 非法 (保留码/越界, 应回 1002)
fn ws_parse_close_code(payload: &[u8], code_out: &mut c_int) -> c_int {
    if payload.is_empty() {
        *code_out = 0;
        return 0;
    }
    if payload.len() < 2 {
        return -1;
    }
    let c = ((payload[0] as c_int) << 8) | (payload[1] as c_int);
    *code_out = c;
    if c == 1000 || c == 1001 || (3000..=4999).contains(&c) {
        return 1;
    }
    -1
}

// ========== reply_close_buf ==========
#[no_mangle]
pub extern "C" fn ws_reply_close_buf(
    fd: c_int,
    payload: *const c_uchar,
    n: usize,
) -> c_int {
    let payload_slice: &[u8] = if n == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(payload, n) }
    };
    let mut code: c_int = 0;
    let r = ws_parse_close_code(payload_slice, &mut code);
    if r == -1 {
        let p2 = [0x03u8, 0xEA]; // 1002 Protocol error
        return ws_write_message(fd, 8, p2.as_ptr(), 2);
    }
    if r == 0 {
        let p2 = [0x03u8, 0xE8]; // 1000 Normal closure
        return ws_write_message(fd, 8, p2.as_ptr(), 2);
    }
    let cap = if n > 125 { 125 } else { n };
    if cap == 0 {
        let p2 = [0x03u8, 0xE8];
        return ws_write_message(fd, 8, p2.as_ptr(), 2);
    }
    ws_write_message(fd, 8, payload_slice.as_ptr(), cap)
}

// ========== UTF-8 校验 (RFC 6455 §5.6: text 必须是合法 UTF-8) ==========
//   1 = 合法; 0 = 非法 (会话应回 1007 并结束)
#[no_mangle]
pub extern "C" fn ws_validate_utf8(p: *const c_uchar, n: usize) -> c_int {
    let s = unsafe { std::slice::from_raw_parts(p, n) };
    let mut i: usize = 0;
    while i < n {
        let b = s[i];
        if b < 0x80 {
            i += 1;
            continue;
        }
        let (extra, mut cp): (usize, u32);
        if (b & 0xE0) == 0xC0 {
            extra = 1;
            cp = (b & 0x1F) as u32;
        } else if (b & 0xF0) == 0xE0 {
            extra = 2;
            cp = (b & 0x0F) as u32;
        } else if (b & 0xF8) == 0xF0 {
            extra = 3;
            cp = (b & 0x07) as u32;
        } else {
            return 0;
        }
        if i + extra >= n {
            return 0; // 截断
        }
        let mut ok = true;
        for k in 1..=extra {
            if (s[i + k] & 0xC0) != 0x80 {
                ok = false;
                break;
            }
            cp = (cp << 6) | ((s[i + k] & 0x3F) as u32);
        }
        if !ok {
            return 0;
        }
        if extra == 1 && cp < 0x80 {
            return 0;
        } // overlong
        if extra == 2 && (cp < 0x800 || (0xD800..=0xDFFF).contains(&cp)) {
            return 0;
        }
        if extra == 3 && !(0x10000..=0x10FFFF).contains(&cp) {
            return 0;
        }
        i += 1 + extra;
    }
    1
}

#[cfg(test)]
mod ws_tests;