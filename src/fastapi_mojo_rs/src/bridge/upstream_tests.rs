// upstream_tests.rs — upstream_call 回归 (长度前缀 JSON over TCP)
// 与生产代码同目录约定 (AGENTS.md §3.2).
// 用 std::net::TcpListener 起一个假引擎: 读帧 -> [path][body] -> 回一帧.
use super::upstream::{
    last_error_ptr, last_reply_ptr, pick_port, port_ring, store_result, upstream_call, MAX_FRAME,
    MAX_PATH,
};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

/// 假引擎模式: 0 = 回 body, 1 = 回 "path|body", 2 = 回 path.
fn spawn_echo_engine(mode: u8) -> (u16, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let h = thread::spawn(move || {
        if let Ok((mut sock, _)) = listener.accept() {
            let mut len_buf = [0u8; 4];
            if sock.read_exact(&mut len_buf).is_ok() {
                let total = u32::from_be_bytes(len_buf) as usize;
                let mut frame = vec![0u8; total];
                if sock.read_exact(&mut frame).is_ok() {
                    let path_len = frame[0] as usize;
                    let path = &frame[1..1 + path_len];
                    let body = &frame[1 + path_len..];
                    let out = match mode {
                        1 => {
                            let mut v = path.to_vec();
                            v.push(b'|');
                            v.extend_from_slice(body);
                            v
                        }
                        2 => path.to_vec(),
                        _ => body.to_vec(),
                    };
                    let mut resp = Vec::with_capacity(6 + out.len());
                    resp.extend_from_slice(&((2 + out.len()) as u32).to_be_bytes());
                    resp.extend_from_slice(&200u16.to_be_bytes());
                    resp.extend_from_slice(&out);
                    let _ = sock.write_all(&resp);
                }
            }
        }
    });
    (port, h)
}

#[test]
fn echo_roundtrip() {
    let (port, h) = spawn_echo_engine(0);
    let payload = br#"{"state":{"x":1},"questions":{"a":"b"}}"#;
    let out = upstream_call("127.0.0.1", port, b"/v1/systemone", payload, 5000).expect("call");
    assert_eq!(out, payload.to_vec());
    let _ = h.join();
}

#[test]
fn path_is_framed_before_body() {
    let (port, h) = spawn_echo_engine(1);
    let out = upstream_call("127.0.0.1", port, b"/health", b"", 5000).expect("call");
    assert_eq!(out, b"/health|".to_vec());
    let _ = h.join();
}

#[test]
fn empty_payload_roundtrip() {
    let (port, h) = spawn_echo_engine(2);
    let out = upstream_call("127.0.0.1", port, b"/health", b"", 5000).expect("call");
    assert_eq!(out, b"/health".to_vec());
    let _ = h.join();
}

#[test]
fn connect_refused_is_error() {
    // 端口 1 上基本没有监听者 -> 连接失败 -> Err
    let err = upstream_call("127.0.0.1", 1, b"/x", b"{}", 2000).expect_err("should fail");
    assert!(err.contains("connect"), "got: {err}");
}

#[test]
fn unresolvable_host_is_error() {
    let err = upstream_call("no-such-host.invalid", 9999, b"/x", b"{}", 2000).expect_err("should fail");
    assert!(err.contains("resolve"), "got: {err}");
}

#[test]
fn oversized_payload_rejected_before_connect() {
    let err = upstream_call("127.0.0.1", 9, b"/x", &vec![0u8; MAX_FRAME + 1], 1000)
        .expect_err("should fail");
    assert!(err.contains("too large"), "got: {err}");
}

#[test]
fn oversized_path_rejected_before_connect() {
    let long = vec![b'a'; MAX_PATH + 1];
    let err = upstream_call("127.0.0.1", 9, &long, b"{}", 1000).expect_err("should fail");
    assert!(err.contains("path too long"), "got: {err}");
}

#[test]
fn pick_port_round_robins_over_csv() {
    let got: Vec<u16> = (0..6).map(|_| pick_port("18410,18411,18412", -1).unwrap()).collect();
    // 6 次连续取模必须均匀覆盖 3 个端口 (顺序取决于全局计数器起点, 只验分布).
    let mut a = got.clone();
    a.sort_unstable();
    a.dedup();
    assert_eq!(a.len(), 3, "got {got:?}");
    for w in got.windows(2) {
        assert_ne!(w[0], w[1], "相邻两次不应命中同一端口: {got:?}");
    }
}

#[test]
fn pick_port_rejects_empty_and_bad() {
    assert!(pick_port("", -1).is_err());
    assert!(pick_port(" , ", -1).is_err());
    assert!(pick_port("abc", -1).is_err());
    assert!(pick_port("70000", -1).is_err());
    assert_eq!(pick_port(" 18410 ", -1).unwrap(), 18410);
}

#[test]
fn store_result_keeps_nul_terminated_buffers() {
    store_result(Ok(b"hello".to_vec()));
    let (p, len) = last_reply_ptr();
    assert!(!p.is_null());
    assert_eq!(len, 5);
    // 尾部 NUL: 第 6 个字节是 0
    unsafe {
        assert_eq!(*p.add(5), 0);
    }
    let (_, elen) = last_error_ptr();
    assert_eq!(elen, 0, "成功时错误缓冲应为空");

    store_result(Err("boom".to_string()));
    let (p2, len2) = last_error_ptr();
    assert!(!p2.is_null());
    assert_eq!(len2, 4);
    unsafe {
        assert_eq!(*p2.add(4), 0);
    }
}

/// 假引擎: 接受 `accepts` 条连接, 每条服务 `per_conn` 帧后关闭; 全部完成后退出.
fn spawn_keepalive_engine(accepts: usize, per_conn: usize) -> (u16, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let h = thread::spawn(move || {
        for _ in 0..accepts {
            let Ok((mut sock, _)) = listener.accept() else { return };
            for _ in 0..per_conn {
                let mut len_buf = [0u8; 4];
                if sock.read_exact(&mut len_buf).is_err() {
                    break;
                }
                let total = u32::from_be_bytes(len_buf) as usize;
                let mut frame = vec![0u8; total];
                if sock.read_exact(&mut frame).is_err() {
                    break;
                }
                let path_len = frame[0] as usize;
                let body = &frame[1 + path_len..];
                let mut resp = Vec::with_capacity(4 + body.len());
                resp.extend_from_slice(&((2 + body.len()) as u32).to_be_bytes());
                resp.extend_from_slice(&200u16.to_be_bytes());
                resp.extend_from_slice(body);
                if sock.write_all(&resp).is_err() {
                    break;
                }
            }
        }
    });
    (port, h)
}

#[test]
fn connection_is_reused_across_calls() {
    // 只接受 1 条连接: 若客户端每调用都重连, 第 2/3 次必然超时失败.
    let (port, h) = spawn_keepalive_engine(1, 3);
    for _ in 0..3 {
        let out = upstream_call("127.0.0.1", port, b"/v1/systemone", b"ping", 3000).expect("call");
        assert_eq!(out, b"ping".to_vec());
        assert_eq!(super::upstream::last_status(), 200);
    }
    let _ = h.join();
}

#[test]
fn stale_connection_is_retried_on_a_fresh_one() {
    // 每条连接只服务 1 帧就关闭 -> 第 2 次调用必须透明重连 (accept 两次).
    let (port, h) = spawn_keepalive_engine(2, 1);
    for _ in 0..2 {
        let out = upstream_call("127.0.0.1", port, b"/health", b"", 3000).expect("call");
        assert!(out.is_empty());
    }
    let _ = h.join();
}

#[test]
fn pick_port_pins_by_index() {
    // pin = worker_id: 每个 worker 稳定命中同一个副本 (轮转不参与).
    assert_eq!(pick_port("18410,18411,18412", 0).unwrap(), 18410);
    assert_eq!(pick_port("18410,18411,18412", 1).unwrap(), 18411);
    assert_eq!(pick_port("18410,18411,18412", 2).unwrap(), 18412);
    assert_eq!(pick_port("18410,18411,18412", 7).unwrap(), 18411);
}

#[test]
fn port_ring_orders_from_pinned_replica() {
    // pin=1 -> 从 18411 开始, 环序 18411,18412,18410 (failover 顺序).
    let (ports, start) = port_ring("18410,18411,18412", 1).unwrap();
    assert_eq!(ports, vec![18410, 18411, 18412]);
    assert_eq!(start, 1);
    let order: Vec<u16> = (0..ports.len()).map(|i| ports[(start + i) % ports.len()]).collect();
    assert_eq!(order, vec![18411, 18412, 18410]);

    // pin 越界 -> 取模回到 0; 空表 -> Err.
    let (_, s2) = port_ring("18410,18411,18412", 7).unwrap();
    assert_eq!(s2, 1);
    assert!(port_ring("", 0).is_err());
    assert!(port_ring("x,18410", 0).is_err());
}
