// testclient/http.rs — the `testclient http` subcommand
// A declarative HTTP client that sends requests to a real URL and reports the response.
// Reuses net.rs primitives for TCP I/O, json.rs for serialization.

use std::net::TcpStream;
use std::time::Duration;

use super::{CookieJar, UA, cookie_header, parse_url, url_encode, UrlParts};
use crate::json;
use crate::net;

// ----------------- Types -----------------

pub struct HttpOpts {
    pub json_body: Option<String>,
    pub data_body: Option<String>,
    pub headers: Vec<(String, String)>,
    pub params: Vec<(String, String)>,
    pub cookies: Vec<(String, String)>,
    pub cookie_jar: Option<String>,
    pub follow: bool,
    pub max_hops: usize,
    pub timeout_ms: u64,
    pub json_out: bool,
}

impl Default for HttpOpts {
    fn default() -> Self {
        Self {
            json_body: None,
            data_body: None,
            headers: Vec::new(),
            params: Vec::new(),
            cookies: Vec::new(),
            cookie_jar: None,
            follow: true,
            max_hops: 10,
            timeout_ms: 5000,
            json_out: false,
        }
    }
}

pub enum HttpErr {
    Connect,
    Timeout,
    Protocol(String),
    RedirectLoop,
}

pub struct HttpResp {
    pub status: u16,
    pub reason: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub url: String,
}

// ----------------- CLI entry -----------------

pub fn http_cli(args: &[&str]) -> i32 {
    if args.len() < 2 {
        eprintln!("usage: fmtool testclient http <METHOD> <URL> [options]");
        return 2;
    }
    let method = args[0].to_uppercase();
    let url = args[1];
    let mut opts = HttpOpts::default();
    let mut jar = CookieJar { entries: Vec::new() };
    let mut i = 2;
    while i < args.len() {
        let a = args[i];
        match a {
            "--json" => {
                opts.json_body = Some(args.get(i + 1).copied().unwrap_or("").to_string());
                i += 2;
            }
            "--data" => {
                opts.data_body = Some(args.get(i + 1).copied().unwrap_or("").to_string());
                i += 2;
            }
            "--header" => {
                if let Some(h) = args.get(i + 1) {
                    if let Some((k, v)) = h.split_once(':') {
                        opts.headers.push((k.to_string(), v.to_string()));
                    }
                }
                i += 2;
            }
            "--param" => {
                if let Some(p) = args.get(i + 1) {
                    if let Some((k, v)) = p.split_once('=') {
                        opts.params.push((k.to_string(), v.to_string()));
                    }
                }
                i += 2;
            }
            "--cookie" => {
                if let Some(c) = args.get(i + 1) {
                    if let Some((k, v)) = c.split_once('=') {
                        opts.cookies.push((k.to_string(), v.to_string()));
                    }
                }
                i += 2;
            }
            "--cookie-jar" => {
                if let Some(j) = args.get(i + 1) {
                    opts.cookie_jar = Some(j.to_string());
                    jar = CookieJar::load(j);
                }
                i += 2;
            }
            "--no-follow" => {
                opts.follow = false;
                i += 1;
            }
            "--max-hops" => {
                if let Some(v) = args.get(i + 1) {
                    if let Ok(n) = v.parse() {
                        opts.max_hops = n;
                    }
                }
                i += 2;
            }
            "--timeout-ms" => {
                if let Some(v) = args.get(i + 1) {
                    if let Ok(n) = v.parse() {
                        opts.timeout_ms = n;
                    }
                }
                i += 2;
            }
            "--json-out" => {
                opts.json_out = true;
                i += 1;
            }
            _ => {
                eprintln!("unknown http option: {a}");
                return 2;
            }
        }
    }
    let result = http_request(url, &method, &opts, &mut jar);
    if let Some(jpath) = &opts.cookie_jar {
        let _ = jar.save(jpath);
    }
    match result {
        Ok(resp) => {
            if opts.json_out {
                print_json_out(&resp, &jar);
            } else {
                print_human(&resp);
            }
            0
        }
        Err(e) => match &e {
            HttpErr::Connect => {
                eprintln!("ERROR: connection failed");
                1
            }
            HttpErr::Timeout => {
                eprintln!("ERROR: timeout");
                2
            }
            HttpErr::Protocol(m) => {
                eprintln!("ERROR: protocol: {m}");
                3
            }
            HttpErr::RedirectLoop => {
                eprintln!("ERROR: redirect loop");
                4
            }
        },
    }
}

// ----------------- Core request logic -----------------

/// Redirect method-change rules (pure, unit-testable).
/// 303 -> GET + drop body; 301/302 -> POST downgrades to GET + drop body;
/// 307/308/other -> method and body preserved (RFC 9110 §15.4).
pub fn redirect_method(status: u16, method: &str) -> (String, bool) {
    match status {
        303 => (String::from("GET"), true),
        301 | 302 if method == "POST" => (String::from("GET"), true),
        _ => (method.to_string(), false),
    }
}

pub fn http_request(
    url: &str,
    method: &str,
    opts: &HttpOpts,
    jar: &mut CookieJar,
) -> Result<HttpResp, HttpErr> {
    let timeout = Duration::from_millis(opts.timeout_ms);
    let mut cur_url = url.to_string();
    // append params to the initial URL only
    if !opts.params.is_empty() {
        let sep = if cur_url.contains('?') { '&' } else { '?' };
        let q: Vec<String> = opts
            .params
            .iter()
            .map(|(k, v)| format!("{}={}", url_encode(k), url_encode(v)))
            .collect();
        cur_url = format!("{cur_url}{sep}{}", q.join("&"));
    }
    let mut cur_method = method.to_string();
    let mut body = build_body(opts);
    let headers = build_headers(opts, jar);
    let mut hops = 0;
    loop {
        let resp = do_request(&cur_url, &cur_method, &body, &headers, timeout)?;
        // handle redirects
        if opts.follow && (300..400).contains(&resp.status) {
            if let Some(loc) = resp.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("location")).map(|(_, v)| v.clone()) {
                hops += 1;
                if hops > opts.max_hops {
                    return Err(HttpErr::RedirectLoop);
                }
                // resolve location
                let new_url = if loc.starts_with("http://") || loc.starts_with("https://") {
                    loc
                } else if loc.starts_with('/') {
                    // same host
                    let p = parse_url(&cur_url).unwrap_or(UrlParts { host: "127.0.0.1".into(), port: 8000, path: "/".into() });
                    format!("http://{}:{}{}", p.host, p.port, loc)
                } else {
                    // path relative
                    let p = parse_url(&cur_url).unwrap_or(UrlParts { host: "127.0.0.1".into(), port: 8000, path: "/".into() });
                    format!("http://{}:{}/{}", p.host, p.port, loc)
                };
                // method change rules (303 -> GET; 301/302 POST -> GET; 307/308 preserved)
                let (nm, drop) = redirect_method(resp.status, &cur_method);
                cur_method = nm;
                if drop {
                    body.clear();
                }
                // update jar with Set-Cookie from this response
                apply_set_cookie(jar, &resp);
                cur_url = new_url;
                continue;
            }
        }
        // final response — update jar
        apply_set_cookie(jar, &resp);
        let mut r = resp;
        r.url = cur_url.clone();
        return Ok(r);
    }
}

fn do_request(
    url: &str,
    method: &str,
    body: &[u8],
    headers: &[(String, String)],
    timeout: Duration,
) -> Result<HttpResp, HttpErr> {
    let parts = parse_url(url).ok_or(HttpErr::Protocol("bad url".into()))?;
    let addr = format!("{}:{}", parts.host, parts.port);
    let mut s = match net::tcp_connect(&addr, timeout) {
        Ok(s) => s,
        Err(e) => {
            return Err(if e.kind() == std::io::ErrorKind::TimedOut {
                HttpErr::Timeout
            } else {
                HttpErr::Connect
            });
        }
    };
    // build request line
    let mut req = format!(
        "{method} {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {}\r\n",
        parts.path,
        parts.host,
        UA
    );
    for (k, v) in headers {
        req.push_str(k);
        req.push_str(": ");
        req.push_str(v);
        req.push_str("\r\n");
    }
    if !body.is_empty() {
        req.push_str("Content-Length: ");
        req.push_str(&body.len().to_string());
        req.push_str("\r\n");
    }
    req.push_str("Connection: close\r\n\r\n");
    if let Err(e) = net::send_exact(&mut s, req.as_bytes()) {
        return Err(HttpErr::Protocol(format!("send failed: {e}")));
    }
    if !body.is_empty() {
        if let Err(e) = net::send_exact(&mut s, body) {
            return Err(HttpErr::Protocol(format!("send body failed: {e}")));
        }
    }
    // read response
    let mut resp = read_response(&mut s)?;
    resp.url = url.to_string();
    Ok(resp)
}

fn read_response(s: &mut TcpStream) -> Result<HttpResp, HttpErr> {
    let head = match net::recv_until_headers(s) {
        Ok(h) => h,
        Err(e) => {
            return Err(if e.kind() == std::io::ErrorKind::TimedOut {
                HttpErr::Timeout
            } else {
                HttpErr::Protocol(format!("read headers: {e}"))
            });
        }
    };
    let head_end = head
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|p| p + 4)
        .unwrap_or(head.len());
    let head_str = String::from_utf8_lossy(&head[..head_end]).into_owned();
    let mut lines = head_str.split("\r\n");
    let status_line = lines.next().unwrap_or("").to_string();
    let mut headers = Vec::new();
    let mut cl = 0usize;
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some(i) = line.find(':') {
            let k = line[..i].trim().to_string();
            let v = line[i + 1..].trim().to_string();
            if k.eq_ignore_ascii_case("content-length") {
                cl = v.parse().unwrap_or(0);
            }
            headers.push((k, v));
        }
    }
    // parse status
    let mut sl = status_line.split_whitespace();
    let _ver = sl.next();
    let status = sl.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let reason = sl.collect::<Vec<_>>().join(" ");
    // body
    let mut body = head[head_end..].to_vec();
    if body.len() < cl {
        let need = cl - body.len();
        match net::recv_exact(s, need) {
            Ok(b) => body.extend_from_slice(&b),
            Err(e) => {
                if e.kind() == std::io::ErrorKind::TimedOut {
                    return Err(HttpErr::Timeout);
                }
                return Err(HttpErr::Protocol(format!("body short of CL: {e}")));
            }
        }
    }
    Ok(HttpResp {
        status,
        reason,
        headers,
        body,
        url: String::new(),
    })
}

fn build_headers(opts: &HttpOpts, jar: &CookieJar) -> Vec<(String, String)> {
    let mut h = Vec::new();
    for (k, v) in &opts.headers {
        h.push((k.clone(), v.clone()));
    }
    if opts.json_body.is_some() {
        h.push(("Content-Type".into(), "application/json".into()));
    }
    if opts.data_body.is_some() {
        h.push(("Content-Type".into(), "application/x-www-form-urlencoded".into()));
    }
    let mut cookies: Vec<(String, String)> = opts.cookies.clone();
    for (k, v) in &jar.entries {
        if !cookies.iter().any(|(ek, _)| ek == k) {
            cookies.push((k.clone(), v.clone()));
        }
    }
    if let Some(hdr) = cookie_header(&cookies) {
        h.push(("Cookie".into(), hdr));
    }
    h
}

pub fn build_body(opts: &HttpOpts) -> Vec<u8> {
    if let Some(j) = &opts.json_body {
        // normalize to compact JSON
        match json::parse(j) {
            Ok(v) => json::to_string(&v).into_bytes(),
            Err(_) => j.clone().into_bytes(),
        }
    } else if let Some(d) = &opts.data_body {
        if d.contains('=') || d.contains('&') {
            let parts: Vec<String> = d
                .split('&')
                .filter(|p| !p.is_empty())
                .map(|p| {
                    if let Some((k, v)) = p.split_once('=') {
                        format!("{}={}", url_encode(k), url_encode(v))
                    } else {
                        url_encode(p)
                    }
                })
                .collect();
            parts.join("&").into_bytes()
        } else {
            d.clone().into_bytes()
        }
    } else {
        Vec::new()
    }
}

fn apply_set_cookie(jar: &mut CookieJar, resp: &HttpResp) {
    for (k, v) in &resp.headers {
        if k.eq_ignore_ascii_case("set-cookie") {
            let first = v.split(';').next().unwrap_or(v).trim();
            if let Some((ck, cv)) = first.split_once('=') {
                jar.set(ck.trim(), cv.trim());
            }
        }
    }
}

fn print_json_out(resp: &HttpResp, jar: &CookieJar) {
    let body_str = String::from_utf8(resp.body.clone());
    let body_v = match body_str {
        Ok(s) => json::Value::Str(s),
        Err(_) => json::Value::Null,
    };
    let b64_v = if matches!(&body_v, json::Value::Null) {
        json::Value::Str(crate::ws::base64_encode(&resp.body))
    } else {
        json::Value::Null
    };
    let mut obj: Vec<(String, json::Value)> = Vec::new();
    obj.push(("status_code".into(), json::Value::Num(resp.status as f64)));
    obj.push(("reason".into(), json::Value::Str(resp.reason.clone())));
    let hdrs: Vec<json::Value> = resp
        .headers
        .iter()
        .map(|(k, v)| json::Value::Array(vec![
            json::Value::Str(k.clone()),
            json::Value::Str(v.clone()),
        ]))
        .collect();
    obj.push(("headers".into(), json::Value::Array(hdrs)));
    let cookies: Vec<json::Value> = jar
        .entries
        .iter()
        .map(|(k, v)| json::Value::Array(vec![
            json::Value::Str(k.clone()),
            json::Value::Str(v.clone()),
        ]))
        .collect();
    obj.push(("cookies".into(), json::Value::Array(cookies)));
    obj.push(("url".into(), json::Value::Str(resp.url.clone())));
    obj.push(("body".into(), body_v));
    obj.push(("body_b64".into(), b64_v));
    println!("{}", json::to_string(&json::Value::Object(obj)));
}

fn print_human(resp: &HttpResp) {
    println!("HTTP/1.1 {} {}", resp.status, resp.reason);
    for (k, v) in &resp.headers {
        println!("{k}: {v}");
    }
    println!();
    if let Ok(s) = String::from_utf8(resp.body.clone()) {
        println!("{s}");
    } else {
        println!("<{} bytes>", resp.body.len());
    }
}
