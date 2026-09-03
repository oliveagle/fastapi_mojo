// ws.rs — WebSocket (RFC 6455) 客户端原语, 零依赖 (SHA-1/base64/UTF-8/帧解析 全手写).
//
// 复用范围:
//   - e2e ws1..ws4 (ADR-0006~0009 验收 markers)
//   - bench wsbench (内置 WS 负载, hey-csv 同构输出)
//
// 与 fastapi_mojo_rs::ws (服务端) 行为镜像: 同样的 SHA-1 + base64 handshake,
// 同样的 RFC 6455 帧解析. 加密密钥 (mask) 用 /dev/urandom 等价物
// (thread-local xorshift), 性能足够 e2e/bench 场景.

use crate::net::{recv_exact, send_exact};
use std::io::{self, Read};
use std::net::TcpStream;
use std::time::{SystemTime, UNIX_EPOCH};

pub const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ---------- SHA-1 (RFC 3174, 80 轮 f1/f2/f3/f4) ----------

pub fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h0: u32 = 0x67452301;
    let mut h1: u32 = 0xEFCDAB89;
    let mut h2: u32 = 0x98BADCFE;
    let mut h3: u32 = 0x10325476;
    let mut h4: u32 = 0xC3D2E1F0;

    let bit_len = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    for block in msg.chunks(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }

        let mut a = h0;
        let mut b = h1;
        let mut c = h2;
        let mut d = h3;
        let mut e = h4;

        for (i, wi) in w.iter_mut().enumerate() {
            let (f, k) = if i < 20 {
                ((b & c) | ((!b) & d), 0x5A827999)
            } else if i < 40 {
                (b ^ c ^ d, 0x6ED9EBA1)
            } else if i < 60 {
                ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
            } else {
                (b ^ c ^ d, 0xCA62C1D6)
            };
            let t = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = t;
        }

        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
        h4 = h4.wrapping_add(e);
    }

    let mut out = [0u8; 20];
    out[0..4].copy_from_slice(&h0.to_be_bytes());
    out[4..8].copy_from_slice(&h1.to_be_bytes());
    out[8..12].copy_from_slice(&h2.to_be_bytes());
    out[12..16].copy_from_slice(&h3.to_be_bytes());
    out[16..20].copy_from_slice(&h4.to_be_bytes());
    out
}

// ---------- base64 (RFC 4648 §4) ----------

const B64: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(data: &[u8]) -> String {
    let mut s = String::with_capacity(data.len().div_ceil(3) * 4);
    let mut i = 0;
    while i + 3 <= data.len() {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | (data[i + 2] as u32);
        s.push(B64[((n >> 18) & 0x3F) as usize] as char);
        s.push(B64[((n >> 12) & 0x3F) as usize] as char);
        s.push(B64[((n >> 6) & 0x3F) as usize] as char);
        s.push(B64[(n & 0x3F) as usize] as char);
        i += 3;
    }
    let rem = data.len() - i;
    if rem == 1 {
        let n = (data[i] as u32) << 16;
        s.push(B64[((n >> 18) & 0x3F) as usize] as char);
        s.push(B64[((n >> 12) & 0x3F) as usize] as char);
        s.push('=');
        s.push('=');
    } else if rem == 2 {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8);
        s.push(B64[((n >> 18) & 0x3F) as usize] as char);
        s.push(B64[((n >> 12) & 0x3F) as usize] as char);
        s.push(B64[((n >> 6) & 0x3F) as usize] as char);
        s.push('=');
    }
    s
}

// ---------- xorshift PRNG (mask 密钥, 避免引入 rand crate) ----------

fn now_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0xdead_beef_cafe_babe)
}

thread_local! {
    static RNG_STATE: std::cell::Cell<u64> = std::cell::Cell::new(now_nanos() ^ 0x9E37_79B9_7F4A_7C15);
}

fn xorshift_next() -> u64 {
    RNG_STATE.with(|s| {
        let mut x = s.get();
        if x == 0 {
            x = now_nanos() | 1;
        }
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        s.set(x);
        x
    })
}

pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(n);
    while out.len() < n {
        let r = xorshift_next();
        for b in r.to_le_bytes() {
            if out.len() >= n {
                break;
            }
            out.push(b);
        }
    }
    out
}

// ---------- 帧编/解码 ----------

/// op: 0x1=text, 0x2=binary, 0x8=close, 0x9=ping, 0xA=pong
pub fn make_frame(op: u8, payload: &[u8], fin: bool, mask: &[u8; 4]) -> Vec<u8> {
    let first = if fin { 0x80 | op } else { op };
    let mut h = vec![first];
    let n = payload.len();
    if n < 126 {
        h.push(0x80 | (n as u8));
    } else if n <= 0xFFFF {
        h.push(0x80 | 126);
        h.extend_from_slice(&(n as u16).to_be_bytes());
    } else {
        h.push(0x80 | 127);
        h.extend_from_slice(&(n as u64).to_be_bytes());
    }
    h.extend_from_slice(mask);
    let mut masked = Vec::with_capacity(h.len() + n);
    masked.extend_from_slice(&h);
    for i in 0..n {
        masked.push(payload[i] ^ mask[i % 4]);
    }
    masked
}

pub struct Frame {
    pub fin: bool,
    pub op: u8,
    pub payload: Vec<u8>,
}

pub fn recv_frame(s: &mut TcpStream) -> io::Result<Frame> {
    let h = recv_exact(s, 2)?;
    let fin = (h[0] & 0x80) != 0;
    let op = h[0] & 0x0F;
    let mut n = (h[1] & 0x7F) as usize;
    if n == 126 {
        let ext = recv_exact(s, 2)?;
        n = u16::from_be_bytes([ext[0], ext[1]]) as usize;
    } else if n == 127 {
        let ext = recv_exact(s, 8)?;
        n = u64::from_be_bytes([ext[0], ext[1], ext[2], ext[3], ext[4], ext[5], ext[6], ext[7]]) as usize;
    }
    let payload = if n > 0 { recv_exact(s, n)? } else { Vec::new() };
    Ok(Frame { fin, op, payload })
}

// ---------- handshake ----------

type HandshakeResult = (Vec<String>, Vec<(String, String)>, String);

pub fn connect_and_handshake(
    s: &mut TcpStream,
    port: u16,
    path: &str,
    extra_headers: &str,
) -> io::Result<HandshakeResult> {
    // 生成 16B 随机 base64 key (RFC 6455 §1.3 风格, 服务端只 hash, 不要求可解码)
    let key_bytes = random_bytes(16);
    let key = base64_encode(&key_bytes);

    let mut req = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
    );
    if !extra_headers.is_empty() {
        req.push_str(extra_headers);
        if !extra_headers.ends_with("\r\n") {
            req.push_str("\r\n");
        }
    }
    req.push_str("\r\n");

    send_exact(s, req.as_bytes())?;

    let mut resp = Vec::with_capacity(2048);
    let mut tmp = [0u8; 4096];
    while !resp.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = s.read(&mut tmp)?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "EOF in handshake"));
        }
        resp.extend_from_slice(&tmp[..n]);
    }

    let resp_str = String::from_utf8_lossy(&resp);
    let mut lines = resp_str.split("\r\n");
    let status_line = lines.next().unwrap_or("").to_string();
    let lines: Vec<String> = lines.map(|s| s.to_string()).collect();

    let mut hdrs: Vec<(String, String)> = Vec::new();
    for line in &lines {
        if let Some(idx) = line.find(": ") {
            let (k, v) = line.split_at(idx);
            hdrs.push((k.to_string(), v[2..].to_string()));
        }
    }
    Ok((vec![status_line], hdrs, key))
}

/// RFC 6455 §1.3 expected accept: base64(sha1(key + GUID))
pub fn expected_accept(key: &str) -> String {
    let mut data = Vec::with_capacity(key.len() + WS_GUID.len());
    data.extend_from_slice(key.as_bytes());
    data.extend_from_slice(WS_GUID.as_bytes());
    base64_encode(&sha1(&data))
}
