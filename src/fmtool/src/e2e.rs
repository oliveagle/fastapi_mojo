// e2e.rs — e2e_test.sh 的 Python socket/WS 客户端替代 (Track B T2).
//
// 每个子命令对应原来 `python3 ... <<'PY'` heredoc 的一段逻辑:
//   raw      → raw_status()  (发 hex 原始字节, 打印状态行)
//   cont100  → CC_RESULT     (100-continue: interim 100 然后 200, dt<0.9s)
//   keepalive→ KA_RESULT     (单连接多请求 + Connection:close + idle 清理)
//   headbody → HEAD_BODY_BYTES (HEAD / 的 body 字节数)
//   ws1..ws4 → WS_OUT / WS2_OUT / WS3_OUT / WS4_OUT (markers M1..M21)
//   slowloris→ 半发送 + 探针后台客户端
//
// 输出约定: 成功打印 marker (如 M1) 或 OK...; 失败打印 FAIL... (e2e 脚本
// grep marker / OK 前缀判断), 非零退出码.

use crate::deflate::{compress_stored_message, Inflater};
use crate::net::{recv_until_headers, send_exact, tcp_connect, DEFAULT_TIMEOUT};
use crate::ws::{self, Frame};
use std::io::{self, Read};
use std::net::TcpStream;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

// ---------- raw ----------

pub fn raw(port: u16, hex: &str) -> i32 {
    let data = match crate::net::hex_decode(hex) {
        Ok(d) => d,
        Err(e) => {
            println!("FAIL hex decode: {e}");
            return 1;
        }
    };
    let mut s = match tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => {
            println!("FAIL connect: {e}");
            return 1;
        }
    };
    if let Err(e) = send_exact(&mut s, &data) {
        println!("FAIL send: {e}");
        return 1;
    }
    let mut buf = Vec::new();
    let mut tmp = [0u8; 65536];
    match s.read(&mut tmp) {
        Ok(0) => { println!("TIMEOUT"); return 0; }
        Ok(n) => buf.extend_from_slice(&tmp[..n]),
        Err(e) if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
            println!("TIMEOUT");
            return 0;
        }
        Err(e) => { println!("TIMEOUT ({e})"); return 0; }
    }
    let line = buf
        .split(|b| *b == b'\r' || *b == b'\n')
        .next()
        .map(|l| String::from_utf8_lossy(l).into_owned())
        .unwrap_or_default();
    println!("{line}");
    0
}

// ---------- HTTP 响应读取 (headers + content-length body) ----------

fn read_response(s: &mut TcpStream) -> io::Result<Vec<u8>> {
    let head = recv_until_headers(s)?;
    let mut cl = 0usize;
    for line in head.split(|b| *b == b'\n') {
        let line = String::from_utf8_lossy(line).replace('\r', "");
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("content-length:") {
            if let Some(v) = line.split(':').nth(1) {
                cl = v.trim().parse().unwrap_or(0);
            }
        }
    }
    // head 可能已含部分 body; head_end = 头结束(含 \r\n\r\n)的位置
    let head_end = head
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|p| p + 4)
        .unwrap_or(head.len());
    let mut body = head;
    // 补足 content-length 字节 (body 可能未读完)
    while body.len() < head_end + cl {
        let mut tmp = [0u8; 65536];
        let n = s.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    Ok(body)
}

// ---------- cont100 (100-continue) ----------

pub fn cont100(port: u16) -> i32 {
    let t0 = Instant::now();
    let mut s = match tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => {
            println!("FAIL connect: {e}");
            return 1;
        }
    };
    let req = b"POST /items HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 9\r\n\r\n{\"x\":\"1\"}";
    if let Err(e) = send_exact(&mut s, req) {
        println!("FAIL send: {e}");
        return 1;
    }
    // interim: 逐字节读到 "\r\n\r\n"
    let mut interim = Vec::new();
    while !interim.windows(4).any(|w| w == b"\r\n\r\n") {
        let mut b = [0u8; 1];
        match s.read(&mut b) {
            Ok(0) => break,
            Ok(_) => interim.push(b[0]),
            Err(_) => break,
        }
    }
    // final: headers + body
    let final_resp = read_response(&mut s).unwrap_or_default();
    let dt = t0.elapsed().as_secs_f64();
    let hdr = String::from_utf8_lossy(&final_resp).into_owned();
    let ok = String::from_utf8_lossy(&interim).contains("100 Continue")
        && hdr.contains("200 OK")
        && dt < 0.9;
    println!("{}{} dt={:.3}s", if ok { "OK" } else { "FAIL" }, if ok { "" } else { " (interim/final/时间不达标)" }, dt);
    if ok { 0 } else { 1 }
}

// ---------- keepalive ----------

pub fn keepalive(port: u16) -> i32 {
    let mut results: Vec<(&str, bool)> = Vec::new();
    // 1) 单连接 3 个请求 (按 python 版本: 3 次 send + read, 不要预先 read)
    let mut s = match tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => { println!("FAIL connect: {e}"); return 1; }
    };
    let _ = send_exact(&mut s, b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    let h1 = read_response(&mut s).unwrap_or_default();
    let h1s = String::from_utf8_lossy(&h1).into_owned();
    let _ = send_exact(&mut s, b"GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    let h2 = read_response(&mut s).unwrap_or_default();
    let h2s = String::from_utf8_lossy(&h2).into_owned();
    let _ = send_exact(&mut s, b"GET /items/42 HTTP/1.1\r\nHost: x\r\n\r\n");
    let h3 = read_response(&mut s).unwrap_or_default();
    let h3s = String::from_utf8_lossy(&h3).into_owned();
    results.push(("3 requests on 1 connection", h1s.contains("200 OK") && h2s.contains("200 OK") && h3s.contains("200 OK")));
    results.push(("response says Connection: keep-alive", h1s.to_ascii_lowercase().contains("keep-alive")));
    drop(s);

    // 2) client Connection: close honored
    let mut s2 = match tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => { println!("FAIL connect: {e}"); return 1; }
    };
    let _ = send_exact(&mut s2, b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    let hc = read_response(&mut s2).unwrap_or_default();
    let hcs = String::from_utf8_lossy(&hc).into_owned();
    s2.set_read_timeout(Some(Duration::from_secs(2))).ok();
    let extra = read_some(&mut s2);
    let ok3 = extra.is_empty() && hcs.contains("200 OK") && hcs.to_ascii_lowercase().contains("close");
    results.push(("client Connection: close honored", ok3));
    drop(s2);

    // 3) idle keep-alive: server closes silently on timeout (RECV_TIMEOUT=2s)
    let mut s3 = match tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => { println!("FAIL connect: {e}"); return 1; }
    };
    let _ = send_exact(&mut s3, b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    let _ = read_response(&mut s3);
    s3.set_read_timeout(Some(Duration::from_secs(6))).ok();
    let t0 = Instant::now();
    let mut saw_eof = false;
    loop {
        let mut b = [0u8; 1];
        match s3.read(&mut b) {
            Ok(0) => { saw_eof = true; break; }
            Ok(_) => { /* 数据继续读 */ }
            Err(e) if e.kind() == io::ErrorKind::TimedOut || e.kind() == io::ErrorKind::WouldBlock => break,
            Err(_) => { saw_eof = true; break; }
        }
        if t0.elapsed() > Duration::from_secs(6) { break; }
    }
    results.push(("idle keep-alive closed by server", saw_eof));
    drop(s3);

    let ok = results.iter().all(|(_, b)| *b);
    let detail: Vec<String> = results.iter().map(|(n, b)| format!("{n}={b}")).collect();
    println!("{}{} {}", if ok { "OK" } else { "FAIL" }, if ok { "" } else { " (见明细)" }, detail.join("; "));
    if ok { 0 } else { 1 }
}

fn read_some(s: &mut TcpStream) -> Vec<u8> {
    let mut out = Vec::new();
    let mut tmp = [0u8; 65536];
    loop {
        match s.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => out.extend_from_slice(&tmp[..n]),
            Err(_) => break,
        }
    }
    out
}

// ---------- headbody ----------

pub fn headbody(port: u16) -> i32 {
    let mut s = match tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => { println!("FAIL connect: {e}"); return 1; }
    };
    let _ = send_exact(&mut s, b"HEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
    let resp = read_response(&mut s).unwrap_or_default();
    // body 字节数 = 读到 content-length 之后的部分
    let head_end = resp
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|p| p + 4)
        .unwrap_or(resp.len());
    println!("{}", resp.len() - head_end);
    0
}

// ---------- WS 场景 ----------

fn mask4() -> [u8; 4] {
    let r = ws::random_bytes(4);
    [r[0], r[1], r[2], r[3]]
}

fn send_frame(s: &mut TcpStream, op: u8, payload: &[u8], fin: bool) -> io::Result<()> {
    let m = mask4();
    send_exact(s, &ws::make_frame(op, payload, fin, &m))
}

type WsConnectResult = (TcpStream, String, Vec<(String, String)>, String);

fn ws_connect(port: u16, path: &str, extra: &str) -> io::Result<WsConnectResult> {
    let mut s = tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT)?;
    let (statuses, hdrs, key) = ws::connect_and_handshake(&mut s, port, path, extra)?;
    let status = statuses[0].clone();
    Ok((s, status, hdrs, key))
}

fn close_ws(s: &mut TcpStream) {
    let _ = send_frame(s, 0x8, &1000u16.to_be_bytes(), true);
    let _ = recv_frame_timeout(s, Duration::from_secs(2));
}

fn recv_frame_timeout(s: &mut TcpStream, to: Duration) -> io::Result<Frame> {
    s.set_read_timeout(Some(to))?;
    ws::recv_frame(s)
}

// ws1: M1..M6 (ADR-0006)
pub fn ws1(port: u16) -> i32 {
    let mk = || {
        let (mut s, status, hdrs, key) = ws_connect(port, "/ws", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("status {status}")));
        }
        // 验证 Sec-WebSocket-Accept (RFC 6455 §1.3: base64(sha1(key+GUID)))
        // 我的 key 是随机生成的 — 服务端必须对它 hash 出正确 accept。
        // 为精确复现 python 的固定 key 校验, 这里单独重算:
        let accept_ok = verify_accept(&hdrs, &key);
        if !accept_ok {
            return Err(io::Error::other("bad Sec-WebSocket-Accept"));
        }
        println!("M1");

        send_frame(&mut s, 0x1, b"hello mojo", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.fin && f.op == 0x1 && f.payload == b"hello mojo") {
            return Err(io::Error::other("M2 echo mismatch"));
        }
        println!("M2");

        send_frame(&mut s, 0x1, b"part1", false)?;
        send_frame(&mut s, 0x0, b" part2", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.fin && f.op == 0x1 && f.payload == b"part1 part2") {
            return Err(io::Error::other("M3 reassembly mismatch"));
        }
        println!("M3");

        let big: Vec<u8> = (0..=255u8).cycle().take(76800).collect();
        send_frame(&mut s, 0x2, &big, true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.fin && f.op == 0x2 && f.payload == big) {
            return Err(io::Error::other("M4 big binary mismatch"));
        }
        println!("M4");

        send_frame(&mut s, 0x9, b"keepalive", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.op == 0xA && f.payload == b"keepalive") {
            return Err(io::Error::other("M5 pong mismatch"));
        }
        println!("M5");

        send_frame(&mut s, 0x8, &1000u16.to_be_bytes(), true)?;
        match recv_frame_timeout(&mut s, DEFAULT_TIMEOUT) {
            Ok(f) if f.op == 0x8 => {}
            Ok(_) => return Err(io::Error::other("M6 close mismatch")),
            Err(_) => {} // 连接直接关闭也接受 (python 里 ConnectionError 是 pass 的)
        }
        println!("M6");
        Ok(())
    };
    match mk() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}

fn verify_accept(hdrs: &[(String, String)], key: &str) -> bool {
    let expect = ws::expected_accept(key);
    match hdrs.iter().find(|(k, _)| k.eq_ignore_ascii_case("sec-websocket-accept")) {
        Some((_, v)) => v == &expect,
        None => false,
    }
}

// ws2: M7..M13 (ADR-0007)
pub fn ws2(port: u16) -> i32 {
    let mk = || -> io::Result<()> {
        // M7: /ws/chat + subprotocol "chat"
        let (mut s, status, hdrs, _key) = ws_connect(port, "/ws/chat", "Sec-WebSocket-Protocol: chat\r\n")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("M7 status {status}")));
        }
        let proto = hdrs.iter().find(|(k, _)| k.eq_ignore_ascii_case("sec-websocket-protocol")).map(|(_, v)| v.clone()).unwrap_or_default();
        if proto != "chat" {
            return Err(io::Error::other(format!("M7 proto {proto}")));
        }
        send_frame(&mut s, 0x1, b"hi chat", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.fin && f.op == 0x1 && f.payload == b"hi chat") {
            return Err(io::Error::other("M7 echo mismatch"));
        }
        close_ws(&mut s);
        println!("M7");

        // M8: no subprotocol -> 400
        let (s2, status2, _, _) = ws_connect(port, "/ws/chat", "")?;
        if !status2.starts_with("HTTP/1.1 400") {
            return Err(io::Error::other(format!("M8 status {status2}")));
        }
        drop(s2);
        println!("M8");

        // M9: /ws/counter stateful
        let (mut s3, status3, _, _) = ws_connect(port, "/ws/counter", "")?;
        if !status3.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("M9 status {status3}")));
        }
        for (num, expected) in [("1", "sum=1"), ("2", "sum=3"), ("3", "sum=6")] {
            send_frame(&mut s3, 0x1, num.as_bytes(), true)?;
            let f = recv_frame_timeout(&mut s3, DEFAULT_TIMEOUT)?;
            if !(f.fin && f.op == 0x1 && f.payload == expected.as_bytes()) {
                return Err(io::Error::other(format!("M9 counter {num} -> {:?}", f.payload)));
            }
        }
        close_ws(&mut s3);
        println!("M9");

        // M10: server keepalive ping on idle
        let (mut s4, status4, _, _) = ws_connect(port, "/ws", "")?;
        if !status4.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("M10 status {status4}")));
        }
        s4.set_read_timeout(Some(Duration::from_secs(30)))?;
        let t0 = Instant::now();
        let f = ws::recv_frame(&mut s4)?;
        if f.op != 0x9 || !f.payload.is_empty() {
            return Err(io::Error::other(format!("M10 first frame {:?}", f.payload)));
        }
        if t0.elapsed().as_secs_f64() < 1.5 {
            return Err(io::Error::other("M10 ping too early"));
        }
        // pong reset → 2nd ping after another idle window
        send_frame(&mut s4, 0xA, b"", true)?;
        let f = ws::recv_frame(&mut s4)?;
        if f.op != 0x9 {
            return Err(io::Error::other(format!("M10 2nd ping op {}", f.op)));
        }
        close_ws(&mut s4);
        println!("M10");

        // M11: invalid close code 1005 -> 1002
        let (mut s5, status5, _, _) = ws_connect(port, "/ws", "")?;
        if !status5.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other("M11 status"));
        }
        send_frame(&mut s5, 0x8, &1005u16.to_be_bytes(), true)?;
        let f = recv_frame_timeout(&mut s5, DEFAULT_TIMEOUT)?;
        if f.op != 0x8 || f.payload.len() < 2 || u16::from_be_bytes([f.payload[0], f.payload[1]]) != 1002 {
            return Err(io::Error::other(format!("M11 close code {:?}", f.payload)));
        }
        drop(s5);
        println!("M11");

        // M12: invalid UTF-8 text -> close 1007
        let (mut s6, status6, _, _) = ws_connect(port, "/ws", "")?;
        if !status6.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other("M12 status"));
        }
        send_frame(&mut s6, 0x1, &[0xff, 0xfe], true)?;
        let f = recv_frame_timeout(&mut s6, DEFAULT_TIMEOUT)?;
        if f.op != 0x8 || f.payload.len() < 2 || u16::from_be_bytes([f.payload[0], f.payload[1]]) != 1007 {
            return Err(io::Error::other(format!("M12 close code {:?}", f.payload)));
        }
        drop(s6);
        println!("M12");

        // M13: valid close code + reason echoed (4000 "bye")
        let (mut s7, status7, _, _) = ws_connect(port, "/ws", "")?;
        if !status7.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other("M13 status"));
        }
        let mut reason = 4000u16.to_be_bytes().to_vec();
        reason.extend_from_slice(b"bye");
        send_frame(&mut s7, 0x8, &reason, true)?;
        let f = recv_frame_timeout(&mut s7, DEFAULT_TIMEOUT)?;
        if f.op != 0x8 || f.payload != reason {
            return Err(io::Error::other(format!("M13 close {:?}", f.payload)));
        }
        drop(s7);
        println!("M13");
        Ok(())
    };
    match mk() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}

// ws3: M14..M16 (ADR-0008 并发)
pub fn ws3(port: u16) -> i32 {
    let mk = || -> io::Result<()> {
        // M14: 10 并发 WS echo
        let ok_count = Arc::new(AtomicUsize::new(0));
        let mut handles = Vec::new();
        for i in 0..10 {
            let ok = Arc::clone(&ok_count);
            handles.push(std::thread::spawn(move || {
                let r = (|| -> io::Result<()> {
                    let (mut s, status, _, _) = ws_connect(port, "/ws", "")?;
                    if !status.starts_with("HTTP/1.1 101") {
                        return Err(io::Error::other("status"));
                    }
                    let payload = format!("msg-{i}");
                    send_frame(&mut s, 0x1, payload.as_bytes(), true)?;
                    let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
                    if !(f.fin && f.op == 0x1 && f.payload == payload.as_bytes()) {
                        return Err(io::Error::other("echo mismatch"));
                    }
                    close_ws(&mut s);
                    Ok(())
                })();
                if r.is_ok() {
                    ok.fetch_add(1, Ordering::SeqCst);
                }
            }));
        }
        for h in handles {
            let _ = h.join();
        }
        if ok_count.load(Ordering::SeqCst) != 10 {
            return Err(io::Error::other(format!("M14 only {}/10 ok", ok_count.load(Ordering::SeqCst))));
        }
        println!("M14");

        // M15: 3 空闲 WS 会话 + HTTP 探针 <1s
        let mut idle = Vec::new();
        for _ in 0..3 {
            let (s, status, _, _) = ws_connect(port, "/ws", "")?;
            if !status.starts_with("HTTP/1.1 101") {
                return Err(io::Error::other("M15 connect"));
            }
            idle.push(s);
        }
        let t0 = Instant::now();
        let mut probe = tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT)?;
        send_exact(&mut probe, b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")?;
        let resp = read_response(&mut probe)?;
        let dt = t0.elapsed().as_secs_f64();
        if !resp.starts_with(b"HTTP/1.1 200") || dt >= 1.0 {
            return Err(io::Error::other(format!("M15 probe {}s resp {:?}", dt, &resp[..resp.len().min(20)])));
        }
        drop(probe);
        for mut s in idle {
            close_ws(&mut s);
        }
        println!("M15");

        // M16: 每连接 state 隔离
        let (mut sa, st1, _, _) = ws_connect(port, "/ws/counter", "")?;
        let (mut sb, st2, _, _) = ws_connect(port, "/ws/counter", "")?;
        if !st1.starts_with("HTTP/1.1 101") || !st2.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other("M16 connect"));
        }
        // 4 步顺序 (sa/sb 交替), 不能放数组 (借用检查); 直接展开
        for (s, num, expected) in [
            ("a", "1", "sum=1"),
            ("b", "5", "sum=5"),
            ("a", "2", "sum=3"),
            ("b", "7", "sum=12"),
        ] {
            let s_ref: &mut TcpStream = if s == "a" { &mut sa } else { &mut sb };
            send_frame(s_ref, 0x1, num.as_bytes(), true)?;
            let f = recv_frame_timeout(s_ref, DEFAULT_TIMEOUT)?;
            if !(f.op == 0x1 && f.payload == expected.as_bytes()) {
                return Err(io::Error::other(format!("M16 {num} -> {:?}", f.payload)));
            }
        }
        close_ws(&mut sa);
        close_ws(&mut sb);
        println!("M16");
        Ok(())
    };
    match mk() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}

// ws4: M17..M21 (ADR-0009 精化)
pub fn ws4(port: u16) -> i32 {
    let mk = || -> io::Result<()> {
        // M17: 合并帧不丢失
        let (mut s, status, _, _) = ws_connect(port, "/ws", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other("M17 status"));
        }
        let m = mask4();
        let f1 = ws::make_frame(0x1, b"first", true, &m);
        let f2 = ws::make_frame(0x1, b"second", true, &m);
        let mut joined = f1;
        joined.extend_from_slice(&f2);
        send_exact(&mut s, &joined)?;
        let a = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(a.op == 0x1 && a.payload == b"first") { return Err(io::Error::other("M17 first")); }
        let b = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(b.op == 0x1 && b.payload == b"second") { return Err(io::Error::other("M17 second")); }
        // 3 数据帧 + 1 ping 混合
        let f3 = ws::make_frame(0x1, b"a", true, &m);
        let f4 = ws::make_frame(0x9, b"pp", true, &m);
        let f5 = ws::make_frame(0x1, b"c", true, &m);
        let mut mixed = f3;
        mixed.extend_from_slice(&f4);
        mixed.extend_from_slice(&f5);
        send_exact(&mut s, &mixed)?;
        let a = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(a.op == 0x1 && a.payload == b"a") { return Err(io::Error::other("M17 a")); }
        let p = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(p.op == 0xA && p.payload == b"pp") { return Err(io::Error::other("M17 pong")); }
        let c = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(c.op == 0x1 && c.payload == b"c") { return Err(io::Error::other("M17 c")); }
        close_ws(&mut s);
        println!("M17");

        // M18: text 含 NUL
        let (mut s2, status2, _, _) = ws_connect(port, "/ws", "")?;
        if !status2.starts_with("HTTP/1.1 101") { return Err(io::Error::other("M18 status")); }
        send_frame(&mut s2, 0x1, b"a\x00b", true)?;
        let f = recv_frame_timeout(&mut s2, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"a\x00b") { return Err(io::Error::other("M18 nul")); }
        close_ws(&mut s2);
        println!("M18");

        // M19: {param} 路由 /ws/greet/{name}
        let (mut s3, status3, _, _) = ws_connect(port, "/ws/greet/Alice", "")?;
        if !status3.starts_with("HTTP/1.1 101") { return Err(io::Error::other("M19 status")); }
        send_frame(&mut s3, 0x1, b"hi", true)?;
        let f = recv_frame_timeout(&mut s3, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"hello Alice: hi") { return Err(io::Error::other(format!("M19 {:?}", f.payload))); }
        send_frame(&mut s3, 0x1, b"again", true)?;
        let f = recv_frame_timeout(&mut s3, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"hello Alice: again") { return Err(io::Error::other("M19 again")); }
        close_ws(&mut s3);
        println!("M19");

        // M20: 鉴权
        let (mut s4, status4, _, _) = ws_connect(port, "/ws/private?token=secret", "")?;
        if !status4.starts_with("HTTP/1.1 101") { return Err(io::Error::other(format!("M20 auth status {status4}"))); }
        send_frame(&mut s4, 0x1, b"ok", true)?;
        let f = recv_frame_timeout(&mut s4, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"ok") { return Err(io::Error::other("M20 echo")); }
        close_ws(&mut s4);
        let (_, st_no, _, _) = ws_connect(port, "/ws/private", "")?;
        if !st_no.starts_with("HTTP/1.1 403") { return Err(io::Error::other(format!("M20 no-token {st_no}"))); }
        let (_, st_bad, _, _) = ws_connect(port, "/ws/private?token=wrong", "")?;
        if !st_bad.starts_with("HTTP/1.1 403") { return Err(io::Error::other(format!("M20 bad-token {st_bad}"))); }
        println!("M20");

        // M21: {param} + echo — /ws/room/{room}
        let (mut s5, status5, _, _) = ws_connect(port, "/ws/room/abc123", "")?;
        if !status5.starts_with("HTTP/1.1 101") { return Err(io::Error::other("M21 status")); }
        send_frame(&mut s5, 0x1, b"ping", true)?;
        let f = recv_frame_timeout(&mut s5, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"ping") { return Err(io::Error::other("M21 echo")); }
        close_ws(&mut s5);
        println!("M21");
        Ok(())
    };
    match mk() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}

// ws5: W1..W8 (ADR-0026 决策-51 — WS 精化: close/exception/binary/json +
// close-wait). 要求 server 以 FASTAPI_MOJO_WS_CLOSE_WAIT=2000 启动
// (e2e_test.sh 主 server env): W1/W2/W4/W7/W8 的 close-wait 时序断言
// 依赖该值 (1s poll tick 粒度 → 超时 close ∈ [2s, 3s)).
pub fn ws5(port: u16) -> i32 {
    let mk = || -> io::Result<()> {
        let expect_eof = |s: &mut TcpStream, tag: &str, to: Duration| -> io::Result<()> {
            match recv_frame_timeout(s, to) {
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(()),
                Ok(f) => Err(io::Error::other(format!(
                    "{tag}: expected clean EOF, got frame op 0x{op:02x} len {len}",
                    op = f.op,
                    len = f.payload.len()
                ))),
                Err(e) => Err(io::Error::other(format!("{tag}: expected clean EOF, got {e}"))),
            }
        };
        let close_code_reason = |f: &Frame| -> io::Result<(u16, Vec<u8>)> {
            if f.payload.len() < 2 {
                return Err(io::Error::other("close payload < 2 bytes"));
            }
            Ok((
                u16::from_be_bytes([f.payload[0], f.payload[1]]),
                f.payload[2..].to_vec(),
            ))
        };

        // W1: /ws/close — 回复后 close 1000 "bye"; close 回显 → **提前结束**
        // (close-wait 2s 配置下 <1s — P23-1 + P23-7 提前结束)
        let (mut s, status, _, _) = ws_connect(port, "/ws/close", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W1 status {status}")));
        }
        send_frame(&mut s, 0x1, b"go", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"go") {
            return Err(io::Error::other("W1 echo mismatch"));
        }
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if f.op != 0x8 {
            return Err(io::Error::other(format!("W1 close op 0x{op:02x}", op = f.op)));
        }
        let (code, reason) = close_code_reason(&f)?;
        if code != 1000 || reason != b"bye" {
            return Err(io::Error::other(format!("W1 close {code} {reason:?}")));
        }
        let t0 = Instant::now();
        send_frame(&mut s, 0x8, &[0x03, 0xE8, b'b', b'y', b'e'], true)?;
        expect_eof(&mut s, "W1", Duration::from_secs(3))?;
        if t0.elapsed() >= Duration::from_secs(1) {
            return Err(io::Error::other("W1: close echo must end close-wait <1s"));
        }
        println!("W1");

        // W2: /ws/close/4001 — **无回复**, close 4001 "custom reason";
        // close-wait 保持 TCP 打开 → EOF ∈ [1s, 4s) (证明 hold, 非立即关)
        let (mut s, status, _, _) = ws_connect(port, "/ws/close/4001", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W2 status {status}")));
        }
        send_frame(&mut s, 0x1, b"go", true)?;
        let t0 = Instant::now();
        let f = recv_frame_timeout(&mut s, Duration::from_secs(5))?;
        if f.op != 0x8 {
            return Err(io::Error::other("W2 first frame must be close (no reply)"));
        }
        let (code, reason) = close_code_reason(&f)?;
        if code != 4001 || reason != b"custom reason" {
            return Err(io::Error::other(format!("W2 close {code} {reason:?}")));
        }
        expect_eof(&mut s, "W2", Duration::from_secs(5))?;
        let el = t0.elapsed();
        if el < Duration::from_millis(1000) || el > Duration::from_secs(4) {
            return Err(io::Error::other(format!("W2: close-wait hold out of band {el:?}")));
        }
        println!("W2");

        // W3: /ws-exc/boom — 未处理异常: **无 close 帧**, 立即 TCP EOF (1006)
        let (mut s, status, _, _) = ws_connect(port, "/ws-exc/boom", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W3 status {status}")));
        }
        send_frame(&mut s, 0x1, b"go", true)?;
        let t0 = Instant::now();
        match recv_frame_timeout(&mut s, Duration::from_secs(3)) {
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {}
            Ok(f) => {
                return Err(io::Error::other(
                    format!("W3: no close frame allowed, got op 0x{op:02x}", op = f.op),
                ))
            }
            _ => return Err(io::Error::other("W3: timeout waiting for EOF")),
        }
        if t0.elapsed() >= Duration::from_secs(1) {
            return Err(io::Error::other("W3: raise must close immediately (<1s)"));
        }
        println!("W3");

        // W4: /ws-exc/close — WebSocketException 等价: close 4002 "ws-exc"
        // (无回复) + close-wait EOF
        let (mut s, status, _, _) = ws_connect(port, "/ws-exc/close", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W4 status {status}")));
        }
        send_frame(&mut s, 0x1, b"go", true)?;
        let f = recv_frame_timeout(&mut s, Duration::from_secs(5))?;
        if f.op != 0x8 {
            return Err(io::Error::other("W4 first frame must be close"));
        }
        let (code, reason) = close_code_reason(&f)?;
        if code != 4002 || reason != b"ws-exc" {
            return Err(io::Error::other(format!("W4 close {code} {reason:?}")));
        }
        expect_eof(&mut s, "W4", Duration::from_secs(5))?;
        println!("W4");

        // W5: /ws/bin — BINARY 回复, **NUL 保留** (零拷贝, 非 C 串)
        let (mut s, status, _, _) = ws_connect(port, "/ws/bin", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W5 status {status}")));
        }
        send_frame(&mut s, 0x1, b"a\x00b", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x2 && f.payload == b"a\x00b") {
            return Err(io::Error::other(format!("W5 binary: op 0x{op:02x} {p:?}", op = f.op, p = f.payload)));
        }
        close_ws(&mut s);
        println!("W5");

        // W6: /ws/json — compact JSON TEXT 帧 (原始 UTF-8, 逐字节)
        let (mut s, status, _, _) = ws_connect(port, "/ws/json", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W6 status {status}")));
        }
        send_frame(&mut s, 0x1, b"go", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        let want = b"{\"a\":1,\"b\":\"\xe4\xb8\xad\xe6\x96\x87\",\"c\":[1,2]}";
        if !(f.op == 0x1 && f.payload == want) {
            return Err(io::Error::other(format!("W6 json: {p:?}", p = f.payload)));
        }
        close_ws(&mut s);
        println!("W6");

        // W7: close-wait 期间 ping → **丢弃 (不回 pong)**, 超时 close
        let (mut s, status, _, _) = ws_connect(port, "/ws/close", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W7 status {status}")));
        }
        send_frame(&mut s, 0x1, b"go", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"go") {
            return Err(io::Error::other("W7 echo mismatch"));
        }
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if f.op != 0x8 {
            return Err(io::Error::other("W7 expected server close"));
        }
        send_frame(&mut s, 0x9, b"pp", true)?;
        match recv_frame_timeout(&mut s, Duration::from_secs(1)) {
            Ok(f) if f.op == 0xA => {
                return Err(io::Error::other("W7: pong during close-wait must be dropped"))
            }
            Ok(f) => {
                return Err(io::Error::other(format!("W7: unexpected frame op 0x{op:02x}", op = f.op)))
            }
            _ => {} // 1s 无 pong = 丢弃 ✓
        }
        expect_eof(&mut s, "W7", Duration::from_secs(5))?;
        println!("W7");

        // W8: close-wait 期间数据帧 → **丢弃 (无回复)**, 保持开到超时
        let (mut s, status, _, _) = ws_connect(port, "/ws/close", "")?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("W8 status {status}")));
        }
        send_frame(&mut s, 0x1, b"go", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if !(f.op == 0x1 && f.payload == b"go") {
            return Err(io::Error::other("W8 echo mismatch"));
        }
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if f.op != 0x8 {
            return Err(io::Error::other("W8 expected server close"));
        }
        send_frame(&mut s, 0x1, b"late", true)?;
        match recv_frame_timeout(&mut s, Duration::from_secs(1)) {
            Ok(f) if f.op == 0x1 => {
                return Err(io::Error::other("W8: data during close-wait must be dropped"))
            }
            Ok(f) => {
                return Err(io::Error::other(format!("W8: unexpected frame op 0x{op:02x}", op = f.op)))
            }
            _ => {} // 1s 无回复 = 丢弃 ✓
        }
        expect_eof(&mut s, "W8", Duration::from_secs(5))?;
        println!("W8");

        Ok(())
    };
    match mk() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}


// RFC 7692: main-server default mode is ON (WSD1..WSD4).
pub fn wsdeflate(port: u16) -> i32 {
    let run = || -> io::Result<()> {
        // WSD-1: simple offer is accepted; both directions use RSV1 and roundtrip.
        let offer = "Sec-WebSocket-Extensions: permessage-deflate\r\n";
        let (mut s, status, hdrs, _) = ws_connect(port, "/ws", offer)?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("WSD1 status {status}")));
        }
        if extension_value(&hdrs).as_deref() != Some("permessage-deflate") {
            return Err(io::Error::other(format!("WSD1 ext missing in {hdrs:?}")));
        }
        let first = b"hello rfc7692".to_vec();
        let mut client_in = Inflater::new();
        echo_deflate(&mut s, &first, &mut client_in)?;
        println!("WSD1");

        // WSD-2: one TCP connection and one inflater model server context takeover.
        let pattern = b"abcdefghij".iter().cycle().take(1600).cloned().collect::<Vec<_>>();
        echo_deflate(&mut s, &pattern, &mut client_in)?;
        echo_deflate(&mut s, b"abcdefgh", &mut client_in)?;
        close_ws(&mut s);
        println!("WSD2");

        // WSD-3: flags are directional. server_* resets outgoing compression;
        // client_* tells the server to reset its inflater before each message.
        let flags = "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n";
        let (mut s, status, hdrs, _) = ws_connect(port, "/ws", flags)?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("WSD3 status {status}")));
        }
        let ext = extension_value(&hdrs).unwrap_or_default();
        if !ext.contains("server_no_context_takeover") || !ext.contains("client_no_context_takeover") {
            return Err(io::Error::other(format!("WSD3 ext {ext}")));
        }
        let mut fresh_each = Inflater::new();
        echo_deflate(&mut s, b"reset-one", &mut fresh_each)?;
        let mut fresh_each = Inflater::new();
        echo_deflate(&mut s, b"reset-two", &mut fresh_each)?;
        close_ws(&mut s);
        println!("WSD3");

        // WSD-4: unsupported 9-bit offer falls back to the valid 15-bit offer.
        let fallback = "Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=9, permessage-deflate; server_max_window_bits=15\r\n";
        let (mut s, status, hdrs, _) = ws_connect(port, "/ws", fallback)?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(io::Error::other(format!("WSD4 status {status}")));
        }
        if extension_value(&hdrs).as_deref() != Some("permessage-deflate; server_max_window_bits=15") {
            return Err(io::Error::other(format!("WSD4 ext {hdrs:?}")));
        }
        let mut inflater = Inflater::new();
        echo_deflate(&mut s, b"fallback-window", &mut inflater)?;
        close_ws(&mut s);
        println!("WSD4");
        Ok(())
    };
    match run() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}

// RFC 7692: mode=0 declines a valid offer without breaking RFC 6455.
pub fn wsdeflate_off(port: u16) -> i32 {
    let run = || -> io::Result<()> {
        let offer = "Sec-WebSocket-Extensions: permessage-deflate\r\n";
        let (mut s, status, hdrs, _) = ws_connect(port, "/ws", offer)?;
        if !status.starts_with("HTTP/1.1 101") || extension_value(&hdrs).is_some() {
            return Err(io::Error::other(format!("WSD5 status/ext {status} {hdrs:?}")));
        }
        send_frame(&mut s, 0x1, b"plain", true)?;
        let f = recv_frame_timeout(&mut s, DEFAULT_TIMEOUT)?;
        if f.rsv1 || f.op != 0x1 || f.payload != b"plain" {
            return Err(io::Error::other(format!("WSD5 frame rsv={} {f:?}", f.rsv1)));
        }
        close_ws(&mut s);
        println!("WSD5");
        Ok(())
    };
    match run() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}

// RFC 7692: mode=required maps an absent offer to HTTP 400.
pub fn wsdeflate_required(port: u16) -> i32 {
    let run = || -> io::Result<()> {
        let (s, status, hdrs, _) = ws_connect(port, "/ws", "")?;
        drop(s);
        if !status.starts_with("HTTP/1.1 400") || extension_value(&hdrs).is_some() {
            return Err(io::Error::other(format!("WSD6 status/ext {status} {hdrs:?}")));
        }
        println!("WSD6");
        Ok(())
    };
    match run() {
        Ok(()) => 0,
        Err(e) => { println!("FAIL: {e}"); 1 }
    }
}

fn extension_value(hdrs: &[(String, String)]) -> Option<String> {
    hdrs.iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("sec-websocket-extensions"))
        .map(|(_, v)| v.clone())
}

fn send_compressed_frame(
    s: &mut TcpStream,
    op: u8,
    payload: &[u8],
    fin: bool,
) -> io::Result<()> {
    let wire = compress_stored_message(payload);
    let m = mask4();
    send_exact(s, &ws::make_frame_rsv1(op, &wire, fin, &m))
}

fn echo_deflate(
    s: &mut TcpStream,
    payload: &[u8],
    inflater: &mut Inflater,
) -> io::Result<()> {
    send_compressed_frame(s, 0x1, payload, true)?;
    let f = recv_frame_timeout(s, DEFAULT_TIMEOUT)?;
    if !(f.fin && f.rsv1 && f.op == 0x1) {
        return Err(io::Error::other(format!(
            "compressed echo flags fin={} rsv1={} op={}",
            f.fin, f.rsv1, f.op
        )));
    }
    let got = inflater
        .decompress_message(&f.payload)
        .map_err(|e| io::Error::other(format!("inflate error {e:?}")))?;
    if got != payload {
        return Err(io::Error::other(format!(
            "inflate mismatch got {} want {}",
            got.len(),
            payload.len()
        )));
    }
    Ok(())
}

// slowloris: 半发送请求行 + stall, 写 holding, 读响应或 TIMEOUT
pub fn slowloris(port: u16, tmp: &str) -> i32 {
    let holding = format!("{tmp}/holding");
    let stalled = format!("{tmp}/stalled_resp");
    let mut s = match tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT) {
        Ok(s) => s,
        Err(e) => { println!("FAIL connect: {e}"); return 1; }
    };
    if send_exact(&mut s, b"GET /").is_err() {
        println!("FAIL send");
        return 1;
    }
    std::fs::write(&holding, "1").ok();
    std::thread::sleep(Duration::from_secs(2));
    s.set_read_timeout(Some(Duration::from_secs(6))).ok();
    let mut buf = Vec::new();
    let mut tmpbuf = [0u8; 65536];
    match s.read(&mut tmpbuf) {
        Ok(n) => buf.extend_from_slice(&tmpbuf[..n]),
        Err(_) => { std::fs::write(&stalled, "TIMEOUT").ok(); return 0; }
    }
    let line = buf
        .split(|b| *b == b'\r' || *b == b'\n')
        .next()
        .map(|l| String::from_utf8_lossy(l).into_owned())
        .unwrap_or_default();
    std::fs::write(&stalled, line).ok();
    0
}
