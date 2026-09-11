//! Minimal prior-knowledge HTTP/2 client for the dependency-free e2e tool.
//! It supports the server's literal response encoding and emits enough framing
//! (SETTINGS/PING/ACK/CONTINUATION/DATA) to exercise the transport end to end.

use crate::net::{send_exact, tcp_connect, DEFAULT_TIMEOUT};
use std::io::{self, Read};
use std::net::TcpStream;

const PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const DATA: u8 = 0;
const HEADERS: u8 = 1;
const SETTINGS: u8 = 4;
const PING: u8 = 6;
const GOAWAY: u8 = 7;
const ACK: u8 = 1;
const END_STREAM: u8 = 1;
const END_HEADERS: u8 = 4;

const STATIC_NAMES: [&[u8]; 61] = [
    b":authority",
    b":method",
    b":method",
    b":path",
    b":path",
    b":scheme",
    b":scheme",
    b":status",
    b":status",
    b":status",
    b":status",
    b":status",
    b":status",
    b":status",
    b"accept-charset",
    b"accept-encoding",
    b"accept-language",
    b"accept-ranges",
    b"accept",
    b"access-control-allow-origin",
    b"age",
    b"allow",
    b"authorization",
    b"cache-control",
    b"content-disposition",
    b"content-encoding",
    b"content-language",
    b"content-length",
    b"content-location",
    b"content-range",
    b"content-type",
    b"cookie",
    b"date",
    b"etag",
    b"expect",
    b"expires",
    b"from",
    b"host",
    b"if-match",
    b"if-modified-since",
    b"if-none-match",
    b"if-range",
    b"if-unmodified-since",
    b"last-modified",
    b"link",
    b"location",
    b"max-forwards",
    b"proxy-authenticate",
    b"proxy-authorization",
    b"range",
    b"referer",
    b"refresh",
    b"retry-after",
    b"server",
    b"set-cookie",
    b"strict-transport-security",
    b"transfer-encoding",
    b"user-agent",
    b"vary",
    b"via",
    b"www-authenticate",
];

#[derive(Debug, Default)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(field, _)| field.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

fn frame(ty: u8, flags: u8, stream: u32, payload: &[u8]) -> Vec<u8> {
    let len = payload.len();
    let mut out = Vec::with_capacity(9 + len);
    out.extend_from_slice(&[(len >> 16) as u8, (len >> 8) as u8, len as u8, ty, flags]);
    out.extend_from_slice(&stream.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn integer(value: usize, prefix_bits: u8) -> Vec<u8> {
    let max = (1 << prefix_bits) - 1;
    if value < max {
        return vec![value as u8];
    }
    let mut out = vec![max as u8];
    let mut rest = value - max;
    while rest >= 128 {
        out.push((rest as u8 & 0x7f) | 0x80);
        rest >>= 7;
    }
    out.push(rest as u8);
    out
}

fn string(value: &[u8]) -> Vec<u8> {
    let mut out = integer(value.len(), 7);
    out.extend_from_slice(value);
    out
}

fn indexed_name(index: usize, value: &[u8]) -> Vec<u8> {
    let mut out = integer(index, 4);
    out[0] |= 0x00;
    out.extend(string(value));
    out
}

fn header_block(
    method: &str,
    path: &str,
    authority: &str,
    content_length: Option<usize>,
) -> Vec<u8> {
    let mut block = Vec::with_capacity(128);
    if method == "GET" {
        block.push(0x82);
    } else if method == "POST" {
        block.push(0x83);
    } else {
        block.extend(indexed_name(2, method.as_bytes()));
    }
    if path == "/" {
        block.push(0x84);
    } else {
        block.extend(indexed_name(4, path.as_bytes()));
    }
    block.push(0x86);
    block.extend(indexed_name(1, authority.as_bytes()));
    if let Some(length) = content_length {
        block.extend(indexed_name(28, length.to_string().as_bytes()));
        block.extend(indexed_name(31, b"application/json"));
    }
    block
}

fn decode_integer(input: &[u8], pos: usize, prefix_bits: u8) -> io::Result<(usize, usize)> {
    let mask = (1 << prefix_bits) - 1;
    let mut value = (input[pos] & mask) as usize;
    let mut next = pos + 1;
    if value < mask as usize {
        return Ok((value, next));
    }
    let mut shift = 0;
    while next < input.len() {
        let byte = input[next];
        next += 1;
        value += usize::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok((value, next));
        }
        shift += 7;
    }
    Err(io::Error::other("truncated HPACK integer"))
}

fn decode_string(input: &[u8], pos: usize) -> io::Result<(Vec<u8>, usize)> {
    let huffman = input[pos] & 0x80 != 0;
    let (len, next) = decode_integer(input, pos, 7)?;
    if next + len > input.len() {
        return Err(io::Error::other("truncated HPACK string"));
    }
    let raw = input[next..next + len].to_vec();
    if huffman {
        return Err(io::Error::other("Huffman response is outside e2e subset"));
    }
    Ok((raw, next + len))
}

fn decode_headers(block: &[u8]) -> io::Result<Vec<(String, String)>> {
    let mut fields = Vec::new();
    let mut pos = 0;
    while pos < block.len() {
        if block[pos] & 0x80 != 0 {
            let (index, next) = decode_integer(block, pos, 7)?;
            let name = *STATIC_NAMES
                .get(index.wrapping_sub(1))
                .ok_or_else(|| io::Error::other("bad HPACK index"))?;
            fields.push((String::from_utf8_lossy(name).into_owned(), String::new()));
            pos = next;
        } else {
            let first = block[pos];
            let (name_index, mut next) = decode_integer(block, pos, 4)?;
            let name = if name_index == 0 {
                let (name, after) = decode_string(block, next)?;
                next = after;
                name
            } else {
                let name = *STATIC_NAMES
                    .get(name_index - 1)
                    .ok_or_else(|| io::Error::other("bad HPACK name index"))?;
                name.to_vec()
            };
            let (value, end) = decode_string(block, next)?;
            fields.push((
                String::from_utf8_lossy(&name).into_owned(),
                String::from_utf8_lossy(&value).into_owned(),
            ));
            pos = end;
            let _ = first;
        }
    }
    Ok(fields)
}

fn read_frame(stream: &mut TcpStream) -> io::Result<(u8, u8, u32, Vec<u8>)> {
    let mut head = [0u8; 9];
    stream.read_exact(&mut head)?;
    let len = usize::from(head[0]) << 16 | usize::from(head[1]) << 8 | usize::from(head[2]);
    let ty = head[3];
    let flags = head[4];
    let id = u32::from_be_bytes([head[5], head[6], head[7], head[8]]) & 0x7fff_ffff;
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload)?;
    Ok((ty, flags, id, payload))
}

pub fn connect(port: u16) -> io::Result<TcpStream> {
    let mut stream = tcp_connect(&format!("127.0.0.1:{port}"), DEFAULT_TIMEOUT)?;
    send_exact(&mut stream, PREFACE)?;
    send_exact(&mut stream, &frame(SETTINGS, 0, 0, &[]))?;
    Ok(stream)
}

pub fn send_request(
    stream: &mut TcpStream,
    stream_id: u32,
    method: &str,
    path: &str,
    body: Option<&[u8]>,
) -> io::Result<()> {
    let block = header_block(method, path, "127.0.0.1", body.map(|b| b.len()));
    let mut frames = vec![frame(
        HEADERS,
        END_HEADERS | if body.is_none() { END_STREAM } else { 0 },
        stream_id,
        &block,
    )];
    if let Some(body) = body {
        frames.push(frame(DATA, END_STREAM, stream_id, body));
    }
    for frame in frames {
        send_exact(stream, &frame)?;
    }
    Ok(())
}

pub fn request(
    stream: &mut TcpStream,
    stream_id: u32,
    method: &str,
    path: &str,
    body: Option<&[u8]>,
) -> io::Result<Response> {
    send_request(stream, stream_id, method, path, body)?;
    read_response(stream, stream_id)
}

pub fn request_with_continuation(
    stream: &mut TcpStream,
    stream_id: u32,
    path: &str,
) -> io::Result<Response> {
    let block = header_block("GET", path, "127.0.0.1", None);
    let split = block.len() / 2;
    send_exact(
        stream,
        &frame(HEADERS, END_STREAM, stream_id, &block[..split]),
    )?;
    send_exact(stream, &frame(9, END_HEADERS, stream_id, &block[split..]))?;
    read_response(stream, stream_id)
}

pub fn read_response(stream: &mut TcpStream, expected: u32) -> io::Result<Response> {
    let mut response = Response::default();
    loop {
        let (ty, flags, id, payload) = read_frame(stream)?;
        match ty {
            SETTINGS if flags & ACK == 0 => {
                send_exact(stream, &frame(SETTINGS, ACK, 0, &[]))?;
            }
            PING if flags & ACK == 0 => {
                send_exact(stream, &frame(PING, ACK, 0, &payload))?;
            }
            HEADERS if id == expected => {
                let fields = decode_headers(&payload)?;
                for (name, value) in fields {
                    if name == ":status" {
                        response.status = value.parse().unwrap_or_default();
                    } else {
                        response.headers.push((name, value));
                    }
                }
                if flags & END_STREAM != 0 {
                    return Ok(response);
                }
            }
            DATA if id == expected => {
                response.body.extend_from_slice(&payload);
                if flags & END_STREAM != 0 {
                    return Ok(response);
                }
            }
            GOAWAY => return Err(io::Error::other("server GOAWAY")),
            _ => {}
        }
    }
}

pub fn ping(stream: &mut TcpStream) -> io::Result<()> {
    send_exact(stream, &frame(PING, 0, 0, b"fmtoolh2"))?;
    loop {
        let (ty, flags, _, payload) = read_frame(stream)?;
        if ty == PING && flags & ACK != 0 && payload == b"fmtoolh2" {
            return Ok(());
        }
        if ty == GOAWAY {
            return Err(io::Error::other("server GOAWAY"));
        }
    }
}

pub fn e2e(port: u16) -> i32 {
    let run = || -> io::Result<()> {
        let mut stream = connect(port)?;
        let health = request(&mut stream, 1, "GET", "/health", None)?;
        let health_text = String::from_utf8_lossy(&health.body).into_owned();
        if health.status == 200
            && health_text.contains(r#""status": "healthy""#)
            && health_text.contains(r#""uptime": "running""#)
        {
            println!("H2-1");
        } else {
            return Err(io::Error::other(format!(
                "health {} {:?}",
                health.status, health.body
            )));
        }
        let content_length = health.body.len().to_string();
        if health.header("content-type") == Some("application/json")
            && health
                .header("content-length")
                .is_some_and(|v| *v == content_length)
        {
            println!("H2-2");
        } else {
            return Err(io::Error::other("health response headers missing"));
        }

        let body = br#"{"name":"h2","price":7}"#;
        let item = request(&mut stream, 3, "POST", "/items", Some(body))?;
        if item.status == 200
            && String::from_utf8_lossy(&item.body).contains(r#""item_name": "h2""#)
            && String::from_utf8_lossy(&item.body).contains(r#""item_price": "7""#)
        {
            println!("H2-3");
        } else {
            return Err(io::Error::other(format!("POST body {:?}", item.body)));
        }

        let continued = request_with_continuation(&mut stream, 5, "/hello?name=Mojo")?;
        if continued.status == 200
            && String::from_utf8_lossy(&continued.body).contains("Hello, Mojo")
        {
            println!("H2-4");
        } else {
            return Err(io::Error::other(format!(
                "continuation {:?}",
                continued.body
            )));
        }

        let head = request(&mut stream, 7, "HEAD", "/", None)?;
        if head.status == 200 && head.body.is_empty() && head.header("content-length").is_some() {
            println!("H2-5");
        } else {
            return Err(io::Error::other("HEAD must omit DATA"));
        }

        ping(&mut stream)?;
        println!("H2-6");

        // Both HEADERS frames arrive before either response is read.  This
        // regression proves buffered multiplexed streams are drained without
        // waiting for another socket event after the first conn_done.
        send_request(&mut stream, 9, "GET", "/health", None)?;
        send_request(&mut stream, 11, "GET", "/health", None)?;
        let first = read_response(&mut stream, 9)?;
        let second = read_response(&mut stream, 11)?;
        if first.status == 200 && second.status == 200 {
            println!("H2-7");
        } else {
            return Err(io::Error::other(format!(
                "multiplexed responses {} {}",
                first.status, second.status
            )));
        }
        Ok(())
    };
    match run() {
        Ok(()) => 0,
        Err(err) => {
            println!("FAIL: {err}");
            1
        }
    }
}
