use super::conn::conn_table;
use super::hpack::{encode_indexed_name, HpackDecoder};
use super::http2::{H2Connection, H2Request};
use super::http2_frames::{DATA, END_HEADERS, END_STREAM, HEADERS, SETTINGS};
use super::http2_response::{response_frames, send_response};
use super::request::{is_http2, set_http2};

fn frame(ty: u8, flags: u8, stream: u32, payload: &[u8]) -> Vec<u8> {
    let len = payload.len();
    let mut out = len.to_be_bytes()[5..].to_vec();
    out.push(ty);
    out.push(flags);
    out.extend_from_slice(&stream.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn authority(value: &[u8]) -> Vec<u8> {
    encode_indexed_name(1, value)
}

#[test]
fn decodes_prior_knowledge_get_request() {
    let mut connection = H2Connection::new(Vec::new());
    connection.feed(&frame(4, 0, 0, &[]), 1024 * 1024).unwrap();
    let mut block = vec![0x82, 0x84, 0x86];
    block.extend(authority(b"example.com"));
    connection
        .feed(
            &frame(HEADERS, END_STREAM | END_HEADERS, 1, &block),
            1024 * 1024,
        )
        .unwrap();
    let request = connection.take_ready().unwrap();
    assert_eq!(request.stream_id, 1);
    assert_eq!(request.method, b"GET".to_vec());
    assert_eq!(request.path, b"/".to_vec());
    assert_eq!(request.authority, b"example.com".to_vec());
    assert_eq!(connection.current_stream(), Some(1));
}

#[test]
fn decodes_post_body_and_content_length() {
    let mut connection = H2Connection::new(Vec::new());
    let mut block = vec![0x83, 0x86];
    block.extend(authority(b"example.com"));
    block.extend(encode_indexed_name(4, b"/items?full=1"));
    block.extend(encode_indexed_name(31, b"application/json"));
    block.extend(encode_indexed_name(28, b"9"));
    connection
        .feed(&frame(HEADERS, END_HEADERS, 3, &block), 1024 * 1024)
        .unwrap();
    connection
        .feed(&frame(DATA, END_STREAM, 3, br#"{"x":"1"}"#), 1024 * 1024)
        .unwrap();
    let request = connection.take_ready().unwrap();
    assert_eq!(request.method, b"POST".to_vec());
    assert_eq!(request.path, b"/items".to_vec());
    assert_eq!(request.query, b"full=1".to_vec());
    assert_eq!(request.body, br#"{"x":"1"}"#.to_vec());
}

#[test]
fn decodes_continuation_and_rejects_connection_header() {
    let mut connection = H2Connection::new(Vec::new());
    let mut block = vec![0x82, 0x84, 0x86];
    block.extend(authority(b"example.com"));
    let split = block.len() - 2;
    connection
        .feed(&frame(HEADERS, END_STREAM, 1, &block[..split]), 1024 * 1024)
        .unwrap();
    connection
        .feed(&frame(9, END_HEADERS, 1, &block[split..]), 1024 * 1024)
        .unwrap();
    assert!(connection.take_ready().is_some());

    let mut bad = vec![0x82, 0x84, 0x86];
    bad.extend(authority(b"example.com"));
    bad.extend(encode_indexed_name(14, b"close"));
    assert!(connection
        .feed(
            &frame(HEADERS, END_STREAM | END_HEADERS, 3, &bad),
            1024 * 1024
        )
        .is_err());
}

#[test]
fn rejects_malformed_content_length_digits() {
    let mut connection = H2Connection::new(Vec::new());
    let mut block = vec![0x83, 0x86];
    block.extend(authority(b"example.com"));
    block.extend(encode_indexed_name(4, b"/items"));
    block.extend(encode_indexed_name(28, b"9x"));
    let result = connection.feed(
        &frame(HEADERS, END_STREAM | END_HEADERS, 1, &block),
        1024 * 1024,
    );
    assert!(result.is_err());
}

#[test]
fn continuation_expects_no_interleaved_control_frame() {
    let mut connection = H2Connection::new(Vec::new());
    let mut block = vec![0x82, 0x84, 0x86];
    block.extend(authority(b"example.com"));
    connection
        .feed(
            &frame(HEADERS, END_STREAM, 1, &block[..block.len() - 2]),
            1024 * 1024,
        )
        .unwrap();
    assert!(connection
        .feed(&frame(SETTINGS, 0, 0, &[]), 1024 * 1024)
        .is_err());
}

#[test]
fn response_frames_are_hpack_and_end_stream() {
    let body = b"{\"ok\":true}";
    let frames = response_frames(
        7,
        "201 Created",
        "application/json",
        Some(body.len()),
        true,
        body,
        "",
    )
    .unwrap();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0][3], HEADERS);
    assert_eq!(frames[0][4], END_HEADERS);
    assert_eq!(frames[1][3], DATA);
    assert_eq!(frames[1][4], END_STREAM);

    let header_payload = &frames[0][9..];
    let fields = HpackDecoder::new().decode(header_payload).unwrap();
    assert_eq!(fields[0], (b":status".to_vec(), b"201".to_vec()));
    assert_eq!(
        fields[1],
        (b"content-type".to_vec(), b"application/json".to_vec())
    );
    assert_eq!(fields[2], (b"content-length".to_vec(), b"11".to_vec()));
}

#[test]
fn empty_response_ends_in_headers_and_current_request_is_cloneable() {
    let frames = response_frames(
        9,
        "204 No Content",
        "application/json",
        Some(0),
        true,
        b"",
        "",
    )
    .unwrap();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0][4], END_HEADERS | END_STREAM);

    let request = H2Request {
        stream_id: 9,
        method: b"GET".to_vec(),
        path: b"/".to_vec(),
        query: Vec::new(),
        authority: b"example.com".to_vec(),
        headers: Vec::new(),
        body: Vec::new(),
    };
    assert_eq!(request.header_value(b"HOST"), Some(&b"example.com"[..]));
}

#[test]
fn head_response_keeps_the_full_h2_data_window() {
    {
        let mut table = conn_table().lock().unwrap();
        for i in 0..table.conns_len() {
            table.close(i);
        }
    }
    let mut connection = H2Connection::new(Vec::new());
    connection
        .feed(&frame(SETTINGS, 0, 0, &[]), 1024 * 1024)
        .unwrap();
    let mut block = vec![0x82, 0x84, 0x86];
    block.extend(authority(b"example.com"));
    connection
        .feed(
            &frame(HEADERS, END_STREAM | END_HEADERS, 1, &block),
            1024 * 1024,
        )
        .unwrap();
    connection.take_ready().unwrap();

    let mut sockets = [0i32; 2];
    assert_eq!(
        unsafe { libc_socketpair(1, 1, 0, sockets.as_mut_ptr()) },
        0,
        "socketpair failed"
    );
    let (a, b) = (sockets[0], sockets[1]);
    {
        let mut table = conn_table().lock().unwrap();
        let idx = table.alloc(a).expect("conn table full");
        let conn = table.get_mut(idx).unwrap();
        conn.h2 = Some(connection);
    }
    set_http2(true);
    assert!(is_http2());
    let rc = send_response(a, "200 OK", "application/json", &[7u8; 4096], false, None);
    set_http2(false);
    assert_eq!(rc, 0);

    {
        let mut table = conn_table().lock().unwrap();
        let idx = table.find(a).unwrap();
        let conn = table.get_mut(idx).unwrap();
        let h2 = conn.h2.as_mut().unwrap();
        // The protocol body was omitted, so its 4KiB must not consume DATA window.
        assert!(h2.take_send_window(65_535));
        table.close(idx);
    }
    unsafe {
        libc_close(a);
        libc_close(b);
    }
}

extern "C" {
    #[link_name = "socketpair"]
    fn libc_socketpair(domain: i32, ty: i32, protocol: i32, sv: *mut i32) -> i32;
    #[link_name = "close"]
    fn libc_close(fd: i32) -> i32;
}
