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

// ========== MD5 (RFC 1321, 决策-48: FileResponse etag 用) ==========

/// MD5 K 表（RFC 1321）：K[i] = floor(2^32 * |sin(i+1)|)，(i+1) **本身
/// 就是弧度**（RFC 原文 "i+1 radians"；勿 to_radians() — 那是度数→弧度，
/// 会系统性错表）。**const 嵌入而非运行时派生**：运行时 `f64::sin` 会链入
/// libm.so.6，破坏 North Star ldd = libc 门禁（CI 禁 libm.so，见
/// .github/workflows/ci.yml L101）；值由 math.sin（glibc 正确舍入 sin，
/// 与 Rust f64::sin 同一 libm 函数）逐位导出，`md5_k_table_matches_sin`
/// 测试守护 const ≡ 派生。
pub(crate) const MD5_K: [u32; 64] = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

const MD5_S: [u32; 64] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

/// MD5（RFC 1321）：任意长度输入 → 16B 摘要（小端序输出）。
pub fn md5(data: &[u8]) -> [u8; 16] {
    let k = MD5_K;
    let mut h0: u32 = 0x67452301;
    let mut h1: u32 = 0xefcdab89;
    let mut h2: u32 = 0x98badcfe;
    let mut h3: u32 = 0x10325476;
    let bitlen = (data.len() as u64).wrapping_mul(8);
    let mut p = Vec::with_capacity(data.len() + 72);
    p.extend_from_slice(data);
    p.push(0x80);
    while p.len() % 64 != 56 {
        p.push(0);
    }
    p.extend_from_slice(&bitlen.to_le_bytes());
    for off in (0..p.len()).step_by(64) {
        let mut m = [0u32; 16];
        for i in 0..16usize {
            m[i] = u32::from_le_bytes([
                p[off + 4 * i],
                p[off + 4 * i + 1],
                p[off + 4 * i + 2],
                p[off + 4 * i + 3],
            ]);
        }
        let (mut a, mut b, mut c, mut d) = (h0, h1, h2, h3);
        for i in 0..64usize {
            let (f, g) = match i {
                0..=15 => ((b & c) | (!b & d), i),
                16..=31 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                32..=47 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let f = f.wrapping_add(a).wrapping_add(k[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f.rotate_left(MD5_S[i]));
        }
        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
    }
    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&h0.to_le_bytes());
    out[4..8].copy_from_slice(&h1.to_le_bytes());
    out[8..12].copy_from_slice(&h2.to_le_bytes());
    out[12..16].copy_from_slice(&h3.to_le_bytes());
    out
}

/// MD5 hex（32 小写字母）— etag 等用。
pub fn md5_hex(data: &[u8]) -> String {
    let d = md5(data);
    let mut s = String::with_capacity(32);
    for b in d {
        s.push_str(&format!("{b:02x}"));
    }
    s
}


