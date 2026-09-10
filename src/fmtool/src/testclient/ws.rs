// testclient/ws.rs — the `testclient ws` subcommand: a declarative WS client.
//
// Connects to a ws:// URL, performs the RFC 6455 handshake (host-aware,
// deviation #5 vs the 127.0.0.1-hardcoded ws.rs helper), validates the
// Sec-WebSocket-Accept echo, executes the action script, and prints one
// compact JSON event per line (JSONL) to stdout.
//
// Reuses ws.rs primitives (SHA-1/base64/random/make_frame/recv_frame/
// expected_accept) and net.rs TCP helpers — zero new dependencies.
//
// Exit codes: 0 done / 1 connect / 2 bad args / 3 protocol / 4 denial /
//             5 early disconnect or action mismatch / 6 timeout.

use std::io::{self, Read};
use std::net::{Shutdown, TcpStream};
use std::time::Duration;

use super::{Action, RcvKind, parse_action, parse_url};
use crate::json::{self, Value};
use crate::net;
use crate::ws;

// ----------------- CLI entry -----------------

pub fn ws_cli(args: &[&str]) -> i32 {
    if args.is_empty() {
        eprintln!("usage: fmtool testclient ws <URL> [--subprotocol a,b] [--action SPEC]* [--timeout-ms N]");
        return 2;
    }
    let mut timeout_ms: u64 = 5000;
    let mut subprotocol = String::new();
    let mut actions: Vec<Action> = Vec::new();
    let mut i = 1;
    while i < args.len() {
        let a = args[i];
        match a {
            "--subprotocol" => {
                subprotocol = args.get(i + 1).copied().unwrap_or("").to_string();
                i += 2;
            }
            "--action" => {
                if let Some(spec) = args.get(i + 1) {
                    match parse_action(spec) {
                        Ok(act) => actions.push(act),
                        Err(m) => {
                            eprintln!("ERROR: {m}");
                            return 5;
                        }
                    }
                }
                i += 2;
            }
            "--timeout-ms" => {
                if let Ok(n) = args.get(i + 1).copied().unwrap_or("").parse() {
                    timeout_ms = n;
                }
                i += 2;
            }
            _ => {
                eprintln!("unknown ws option: {a}");
                return 2;
            }
        }
    }
    ws_core(args[0], &actions, timeout_ms, &subprotocol)
}

// ----------------- Core -----------------

pub fn ws_core(url: &str, actions: &[Action], timeout_ms: u64, subprotocol: &str) -> i32 {
    let timeout = Duration::from_millis(timeout_ms);
    let parts = match parse_url(url) {
        Some(p) => p,
        None => {
            eprintln!("ERROR: bad url: {url}");
            return 2;
        }
    };
    let mut s = match net::tcp_connect(&parts.addr(), timeout) {
        Ok(s) => s,
        Err(e) => {
            if e.kind() == io::ErrorKind::TimedOut {
                eprintln!("ERROR: timeout");
                return 6;
            }
            eprintln!("ERROR: connection failed");
            return 1;
        }
    };
    // RFC 6455 handshake — host-aware (the ws.rs helper hardcodes 127.0.0.1)
    let key = ws::base64_encode(&ws::random_bytes(16));
    let mut req = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n",
        parts.path,
        parts.addr()
    );
    if !subprotocol.is_empty() {
        req.push_str("Sec-WebSocket-Protocol: ");
        req.push_str(subprotocol);
        req.push_str("\r\n");
    }
    req.push_str("\r\n");
    if let Err(e) = net::send_exact(&mut s, req.as_bytes()) {
        eprintln!("ERROR: protocol: handshake send: {e}");
        return 3;
    }
    let head = match net::recv_until_headers(&mut s) {
        Ok(h) => h,
        Err(e) => {
            if e.kind() == io::ErrorKind::TimedOut {
                eprintln!("ERROR: timeout");
                return 6;
            }
            eprintln!("ERROR: protocol: handshake read: {e}");
            return 3;
        }
    };
    let head_end = head.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4).unwrap_or(head.len());
    let head_str = String::from_utf8_lossy(&head[..head_end]).into_owned();
    let mut lines = head_str.split("\r\n");
    let status_line = lines.next().unwrap_or("").to_string();
    let mut hdrs: Vec<(String, String)> = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some(i) = line.find(": ") {
            hdrs.push((line[..i].trim().to_string(), line[i + 2..].trim().to_string()));
        }
    }
    let mut sl = status_line.split_whitespace();
    let _ver = sl.next();
    let status = sl.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let reason = sl.collect::<Vec<_>>().join(" ");
    if status != 101 {
        // denial: the server answered with a plain HTTP response
        let cl = hdrs
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, v)| v.parse().ok())
            .unwrap_or(0);
        let mut body = head[head_end..].to_vec();
        while body.len() < cl {
            let mut tmp = [0u8; 4096];
            match s.read(&mut tmp) {
                Ok(0) => break,
                Ok(n) => body.extend_from_slice(&tmp[..n]),
                Err(e) => {
                    if e.kind() == io::ErrorKind::TimedOut {
                        eprintln!("ERROR: timeout");
                        return 6;
                    }
                    eprintln!("ERROR: protocol: denial body read: {e}");
                    return 3;
                }
            }
        }
        let body_out = match String::from_utf8(body.clone()) {
            Ok(s) => s,
            Err(_) => ws::base64_encode(&body),
        };
        emit(&[
            ("event".to_string(), Value::Str("denial".to_string())),
            ("status".to_string(), Value::Num(status as f64)),
            ("reason".to_string(), Value::Str(reason)),
            ("body".to_string(), Value::Str(body_out)),
        ]);
        let _ = s.shutdown(Shutdown::Both);
        return 4;
    }
    // 101 — validate the accept echo (hard RFC check)
    let accept = hdrs
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("sec-websocket-accept"))
        .map(|(_, v)| v.clone());
    if let Some(a) = &accept {
        if a != &ws::expected_accept(&key) {
            eprintln!("ERROR: protocol: bad Sec-WebSocket-Accept");
            let _ = s.shutdown(Shutdown::Both);
            return 3;
        }
    }
    let negotiated = hdrs
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("sec-websocket-protocol"))
        .map(|(_, v)| v.clone())
        .unwrap_or_default();
    emit(&[
        ("event".to_string(), Value::Str("connect".to_string())),
        ("subprotocol".to_string(), Value::Str(negotiated)),
    ]);
    // action loop
    for act in actions {
        let rc = exec_action(act, &mut s, &timeout);
        if rc != 0 {
            return rc;
        }
    }
    // script complete without an explicit close — auto close 1000, then done
    let explicit_close = actions.iter().any(|a| matches!(a, Action::Close(..) | Action::ExpectClose(..)));
    if !explicit_close {
        auto_close(&mut s, &timeout);
        let _ = s.shutdown(Shutdown::Both);
        emit(&[("event".to_string(), Value::Str("done".to_string()))]);
    }
    0
}

// ----------------- Actions -----------------

fn exec_action(act: &Action, s: &mut TcpStream, timeout: &Duration) -> i32 {
    match act {
        Action::SendText(p) => {
            send_frame(0x1, p.as_bytes(), s);
            0
        }
        Action::SendJson(p) => match json::parse(p) {
            Ok(v) => {
                emit(&[
                    ("event".to_string(), Value::Str("sent".to_string())),
                    ("op".to_string(), Value::Str("json".to_string())),
                    ("value".to_string(), v),
                ]);
                send_frame(0x1, p.as_bytes(), s);
                0
            }
            Err(_) => {
                emit(&[
                    ("event".to_string(), Value::Str("error".to_string())),
                    ("message".to_string(), Value::Str("bad json".to_string())),
                ]);
                5
            }
        },
        Action::SendBytes(p) => {
            send_frame(0x2, p, s);
            0
        }
        Action::Close(code, reason) => {
            send_close(*code, reason, s);
            wait_echo(s, timeout);
            emit(&[
                ("event".to_string(), Value::Str("close".to_string())),
                ("code".to_string(), Value::Num(*code as f64)),
                ("reason".to_string(), Value::Str(reason.clone())),
                ("initiator".to_string(), Value::Str("client".to_string())),
            ]);
            0
        }
        Action::ExpectClose(code, expect) => {
            // read frames until the server's close; control frames transparent
            loop {
                let frame = match ws::recv_frame(s) {
                    Ok(f) => f,
                    Err(e) => {
                        if e.kind() == io::ErrorKind::TimedOut {
                            emit(&[
                                ("event".to_string(), Value::Str("error".to_string())),
                                ("message".to_string(), Value::Str("timeout".to_string())),
                            ]);
                            return 6;
                        }
                        emit(&[
                            ("event".to_string(), Value::Str("error".to_string())),
                            ("message".to_string(), Value::Str("eof".to_string())),
                        ]);
                        return 5;
                    }
                };
                match frame.op {
                    0x9 => {
                        send_pong(&frame.payload, s);
                        continue;
                    }
                    0xA => continue,
                    0x8 => {
                        let (fcode, freason) = parse_close_payload(&frame.payload);
                        if fcode == *code && (expect.is_none() || expect.as_ref() == Some(&freason)) {
                            send_close(fcode, &freason, s);
                            emit(&[
                                ("event".to_string(), Value::Str("close".to_string())),
                                ("code".to_string(), Value::Num(fcode as f64)),
                                ("reason".to_string(), Value::Str(freason)),
                                ("initiator".to_string(), Value::Str("server".to_string())),
                            ]);
                            emit(&[("event".to_string(), Value::Str("done".to_string()))]);
                            let _ = s.shutdown(Shutdown::Both);
                            return 0;
                        }
                        emit(&[
                            ("event".to_string(), Value::Str("error".to_string())),
                            ("message".to_string(), Value::Str("close mismatch".to_string())),
                        ]);
                        return 5;
                    }
                    _ => {
                        // data frames before the close — transparent noise
                        continue;
                    }
                }
            }
        }
        Action::Receive(kind, expect) => {
            // read until a complete (reassembled) data frame
            let mut buf: Vec<u8> = Vec::new();
            loop {
                let frame = match ws::recv_frame(s) {
                    Ok(f) => f,
                    Err(e) => {
                        if e.kind() == io::ErrorKind::TimedOut {
                            emit(&[
                                ("event".to_string(), Value::Str("error".to_string())),
                                ("message".to_string(), Value::Str("timeout".to_string())),
                            ]);
                            return 6;
                        }
                        emit(&[
                            ("event".to_string(), Value::Str("error".to_string())),
                            ("message".to_string(), Value::Str("eof".to_string())),
                        ]);
                        return 5;
                    }
                };
                match frame.op {
                    0x9 => {
                        send_pong(&frame.payload, s);
                        continue;
                    }
                    0xA => continue,
                    0x8 => {
                        // close arrived while a data receive was pending — early disconnect
                        let (c, r) = parse_close_payload(&frame.payload);
                        emit(&[
                            ("event".to_string(), Value::Str("close".to_string())),
                            ("code".to_string(), Value::Num(c as f64)),
                            ("reason".to_string(), Value::Str(r)),
                            ("initiator".to_string(), Value::Str("server".to_string())),
                        ]);
                        return 5;
                    }
                    0x0..=0x2 => {
                        if !frame.fin {
                            buf.extend_from_slice(&frame.payload);
                            continue;
                        }
                        buf.extend_from_slice(&frame.payload);
                        if !verify(kind, &buf, expect) {
                            emit(&[
                                ("event".to_string(), Value::Str("error".to_string())),
                                ("message".to_string(), Value::Str("mismatch".to_string())),
                            ]);
                            return 5;
                        }
                        emit(&[
                            ("event".to_string(), Value::Str("receive".to_string())),
                            ("value".to_string(), value_of(kind, &buf)),
                        ]);
                        return 0;
                    }
                    _ => continue,
                }
            }
        }
    }
}

// ----------------- Frame helpers -----------------

fn send_frame(op: u8, payload: &[u8], s: &mut TcpStream) {
    let raw = ws::random_bytes(4);
    let mut mask = [0u8; 4];
    mask.copy_from_slice(&raw);
    let f = ws::make_frame(op, payload, true, &mask);
    let _ = net::send_exact(s, &f);
}

fn send_pong(payload: &[u8], s: &mut TcpStream) {
    send_frame(0xA, payload, s);
}

fn send_close(code: u16, reason: &str, s: &mut TcpStream) {
    let mut payload: Vec<u8> = code.to_be_bytes().to_vec();
    payload.extend_from_slice(reason.as_bytes());
    send_frame(0x8, &payload, s);
}

/// wait up to 2 s for the server's close echo; EOF/timeout tolerated
fn wait_echo(s: &mut TcpStream, timeout: &Duration) {
    let _ = s.set_read_timeout(Some(Duration::from_millis(2000)));
    let _ = ws::recv_frame(s);
    let _ = s.set_read_timeout(Some(*timeout));
}

fn auto_close(s: &mut TcpStream, timeout: &Duration) {
    send_close(1000, "", s);
    wait_echo(s, timeout);
}

fn parse_close_payload(payload: &[u8]) -> (u16, String) {
    let code = if payload.len() >= 2 {
        u16::from_be_bytes([payload[0], payload[1]])
    } else {
        0
    };
    let rest: &[u8] = if payload.len() > 2 { &payload[2..] } else { &[] };
    (code, String::from_utf8_lossy(rest).into_owned())
}

// ----------------- Expectation checks -----------------

fn verify(kind: &RcvKind, buf: &[u8], expect: &Option<String>) -> bool {
    match kind {
        RcvKind::Text => {
            if let Some(e) = expect {
                let s = String::from_utf8_lossy(buf).into_owned();
                return s == *e;
            }
            true
        }
        RcvKind::Bytes => {
            if let Some(e) = expect {
                let s = String::from_utf8_lossy(buf).into_owned();
                return s == *e;
            }
            true
        }
        RcvKind::Json => {
            if let Some(e) = expect {
                let a = String::from_utf8_lossy(buf).into_owned();
                return normalize_json(&a) == normalize_json(e);
            }
            true
        }
        RcvKind::Raw => true,
    }
}

fn normalize_json(s: &str) -> String {
    match json::parse(s) {
        Ok(v) => json::to_string(&v),
        Err(_) => s.to_string(),
    }
}

fn value_of(kind: &RcvKind, buf: &[u8]) -> Value {
    match kind {
        RcvKind::Text | RcvKind::Raw => Value::Str(String::from_utf8_lossy(buf).into_owned()),
        RcvKind::Bytes => Value::Str(ws::base64_encode(buf)),
        RcvKind::Json => {
            let s = String::from_utf8_lossy(buf).into_owned();
            match json::parse(&s) {
                Ok(v) => v,
                Err(_) => Value::Str(s),
            }
        }
    }
}

fn emit(pairs: &[(String, Value)]) {
    let v = Value::Object(pairs.to_vec());
    println!("{}", json::to_string(&v));
}
