// net.rs — 基础 TCP helpers (std::net, 零依赖)
//
// 设计: 所有函数返回 std::io::Result; e2e/bench 场景失败由调用方决定
// 是否 panic 或回传错误字符串. 统一超时硬上限 60s, 防脚本 hang.

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);

pub fn tcp_connect(addr: &str, timeout: Duration) -> io::Result<TcpStream> {
    let s = TcpStream::connect_timeout(
        &addr.parse().map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?,
        timeout,
    )?;
    s.set_read_timeout(Some(timeout))?;
    s.set_write_timeout(Some(timeout))?;
    s.set_nodelay(true).ok();
    Ok(s)
}

pub fn send_exact(s: &mut TcpStream, buf: &[u8]) -> io::Result<()> {
    let mut off = 0;
    while off < buf.len() {
        let n = s.write(&buf[off..])?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "short write"));
        }
        off += n;
    }
    Ok(())
}

pub fn recv_exact(s: &mut TcpStream, n: usize) -> io::Result<Vec<u8>> {
    let mut buf = vec![0u8; n];
    let mut off = 0;
    while off < n {
        let k = s.read(&mut buf[off..])?;
        if k == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "EOF"));
        }
        off += k;
    }
    Ok(buf)
}

/// 从 socket 读到 "\r\n\r\n" (HTTP 头结束), 返回 (headers, 是否读完).
pub fn recv_until_headers(s: &mut TcpStream) -> io::Result<Vec<u8>> {
    let deadline = Instant::now() + DEFAULT_TIMEOUT;
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        if Instant::now() > deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "headers timeout"));
        }
        s.set_read_timeout(Some(Duration::from_millis(200)))?;
        match s.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
                continue;
            }
            Err(e) => return Err(e),
        }
    }
    Ok(buf)
}

pub fn hex_decode(s: &str) -> io::Result<Vec<u8>> {
    let s = s.trim();
    if !s.len().is_multiple_of(2) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "odd hex length"));
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let bytes = s.as_bytes();
    for i in (0..s.len()).step_by(2) {
        let hi = hex_nibble(bytes[i])?;
        let lo = hex_nibble(bytes[i + 1])?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

fn hex_nibble(b: u8) -> io::Result<u8> {
    match b {
        b'0'..=b'9' => Ok(b - b'0'),
        b'a'..=b'f' => Ok(b - b'a' + 10),
        b'A'..=b'F' => Ok(b - b'A' + 10),
        _ => Err(io::Error::new(io::ErrorKind::InvalidInput, "bad hex char")),
}
}
