//! crypto.rs — SHA-256 / HMAC-SHA256 / base64url 原语 (决策-44, ADR-0019).
//!
//! 纯 Rust 手写实现 (零第三方 crate, ADR-0010 设计守则):
//!   - sha256      : FIPS 180-4
//!   - hmac_sha256 : RFC 2104 (key > 64B 先 sha256)
//!   - b64url_*    : RFC 7515 \u00a72.1 (JWS 用 URL-safe, 无 padding)
//!
//! 用途: JWT HS256 签名/校验 (OAuth2 password flow, FastAPI 0.141.1 教程同款).
//! FFI 包装: ffi.rs `fm_hmac_sha256_b64url` (malloc + NUL, free 走 libc free).
//! 测试: crypto_tests.rs (FIPS/RFC known vectors).

// ========== SHA-256 (FIPS 180-4) ==========

/// 64 个轮常量 (FIPS 180-4 \u00a74.2.2).
const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// SHA-256 (FIPS 180-4). 输入任意长度 -> 32B 摘要.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let bitlen = (data.len() as u64).wrapping_mul(8);
    let mut p = Vec::with_capacity(data.len() + 72);
    p.extend_from_slice(data);
    p.push(0x80);
    while p.len() % 64 != 56 {
        p.push(0);
    }
    p.extend_from_slice(&bitlen.to_be_bytes());
    for off in (0..p.len()).step_by(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                p[off + 4 * i],
                p[off + 4 * i + 1],
                p[off + 4 * i + 2],
                p[off + 4 * i + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }
    let mut out = [0u8; 32];
    for i in 0..8 {
        out[4 * i..4 * i + 4].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}

// ========== HMAC-SHA256 (RFC 2104) ==========

/// HMAC-SHA256. key 任意长度 (> 64B 先 sha256 压缩, RFC 2104 \u00a72.3).
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        let hk = sha256(key);
        k[..32].copy_from_slice(&hk);
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut inner = Vec::with_capacity(64 + msg.len());
    inner.extend_from_slice(&k.map(|b| b ^ 0x36));
    inner.extend_from_slice(msg);
    let ih = sha256(&inner);
    let mut outer = Vec::with_capacity(96);
    outer.extend_from_slice(&k.map(|b| b ^ 0x5c));
    outer.extend_from_slice(&ih);
    sha256(&outer)
}

// ========== base64url (RFC 7515 \u00a72.1) ==========

/// base64url 字母表 (RFC 4648 \u00a75: - 替代 +, _ 替代 /; JWT 无 padding).
const B64URL_TBL: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// base64url 编码 (无 padding).
pub fn b64url_encode(data: &[u8]) -> String {
    let mut s = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0];
        let b1 = if chunk.len() > 1 { chunk[1] } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] } else { 0 };
        let t = ((b0 as u32) << 16) | ((b1 as u32) << 8) | (b2 as u32);
        s.push(B64URL_TBL[((t >> 18) & 0x3F) as usize] as char);
        s.push(B64URL_TBL[((t >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            s.push(B64URL_TBL[((t >> 6) & 0x3F) as usize] as char);
        }
        if chunk.len() > 2 {
            s.push(B64URL_TBL[(t & 0x3F) as usize] as char);
        }
    }
    s
}

fn b64url_val(c: u8) -> u32 {
    match c {
        b'A'..=b'Z' => (c - b'A') as u32,
        b'a'..=b'z' => (c - b'a') as u32 + 26,
        b'0'..=b'9' => (c - b'0') as u32 + 52,
        b'-' | b'+' => 62, // url-safe 或标准 base64
        b'_' | b'/' => 63, // url-safe 或标准 base64
        _ => u32::MAX,     // padding '=' / 空白 / 非法 -> 调用方过滤
    }
}

/// base64url 解码 (宽松: 忽略 '=' padding 与空白, 容忍标准字母表 +/).
/// 非法字符 -> None (JWT 签名校验必须严格于字母表).
pub fn b64url_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() / 4 * 3 + 3);
    let mut val: u32 = 0;
    let mut bits: u32 = 0;
    for c in s.bytes() {
        if c == b'=' || c == b' ' || c == b'\t' || c == b'\n' || c == b'\r' {
            continue;
        }
        let v = b64url_val(c);
        if v == u32::MAX {
            return None;
        }
        val = (val << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((val >> bits) as u8);
            val &= (1 << bits) - 1;
        }
    }
    Some(out)
}
