// testclient/mod.rs — shared types, URL parsing, action parsing
mod http;
mod run;
mod ws;

#[cfg(test)]
mod testclient_tests;

pub const UA: &str = "testclient";

pub struct UrlParts {
    pub host: String,
    pub port: u16,
    pub path: String,
}

impl UrlParts {
    pub fn addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

/// Parse "http://host:port/path" or "ws://host:port/path" or bare "/path"
pub fn parse_url(s: &str) -> Option<UrlParts> {
    let (scheme, rest) = match s.split_once("://") {
        Some((sc, r)) => (sc, r),
        None => {
            // bare path — default to local server
            return Some(UrlParts {
                host: "127.0.0.1".into(),
                port: 8000,
                path: s.to_string(),
            });
        }
    };
    let _ = scheme; // http/ws handled the same at transport level
    // rest = host:port/path
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h, p.parse().ok()?),
        None => (hostport, 80),
    };
    Some(UrlParts {
        host: host.to_string(),
        port,
        path: path.to_string(),
    })
}

/// Percent-encode for form/query: space -> '+', alphanumerics and -_.~ kept
pub fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub enum RcvKind { Text, Bytes, Json, Raw }

pub enum Action {
    SendText(String),
    SendJson(String),
    SendBytes(Vec<u8>),
    Close(u16, String),
    ExpectClose(u16, Option<String>),
    Receive(RcvKind, Option<String>),
}

pub fn parse_action(spec: &str) -> Result<Action, String> {
    let (verb, payload) = match spec.split_once(':') {
        Some((v, p)) => (v, p),
        None => (spec, ""),
    };
    match verb {
        "send-text" => Ok(Action::SendText(payload.to_string())),
        "send-json" => Ok(Action::SendJson(payload.to_string())),
        "send-bytes" => {
            let v = crate::net::hex_decode(payload).map_err(|e| format!("bad hex: {e}"))?;
            Ok(Action::SendBytes(v))
        }
        "close" | "expect-close" => {
            let (code, reason) = match payload.split_once(':') {
                Some((c, r)) => (c, Some(r.to_string())),
                None => (payload, None),
            };
            let c = code.parse::<u16>().map_err(|_| format!("bad close code: {code}"))?;
            if verb == "expect-close" {
                Ok(Action::ExpectClose(c, reason))
            } else {
                Ok(Action::Close(c, reason.unwrap_or_default()))
            }
        }
        "receive" => Ok(Action::Receive(RcvKind::Raw, None)),
        "receive-text" => Ok(Action::Receive(RcvKind::Text, parse_expect(payload))),
        "receive-bytes" => Ok(Action::Receive(RcvKind::Bytes, parse_expect(payload))),
        "receive-json" => Ok(Action::Receive(RcvKind::Json, parse_expect(payload))),
        _ => Err(format!("unknown action: {verb}")),
    }
}

fn parse_expect(payload: &str) -> Option<String> {
    if payload.is_empty() {
        None
    } else {
        Some(payload.to_string())
    }
}

/// Cookie jar file = "name=value" lines (first '=' splits)
pub struct CookieJar {
    pub entries: Vec<(String, String)>,
}

impl CookieJar {
    pub fn load(path: &str) -> CookieJar {
        let mut j = CookieJar { entries: Vec::new() };
        if let Ok(txt) = std::fs::read_to_string(path) {
            for line in txt.lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                if let Some((k, v)) = line.split_once('=') {
                    j.entries.retain(|(ek, _)| ek != k);
                    j.entries.push((k.to_string(), v.to_string()));
                }
            }
        }
        j
    }

    /// Insert/replace; an update moves the entry to the tail (LRU-style, like a re-set cookie).
    pub fn set(&mut self, k: &str, v: &str) {
        self.entries.retain(|(ek, _)| ek != k);
        self.entries.push((k.to_string(), v.to_string()));
    }

    pub fn save(&self, path: &str) -> std::io::Result<()> {
        let mut out = String::new();
        for (k, v) in &self.entries {
            out.push_str(k);
            out.push('=');
            out.push_str(v);
            out.push('\n');
        }
        std::fs::write(path, out)
    }

}

/// Join `name=value` cookie pairs as an HTTP `Cookie` header value (`; ` sep).
pub fn cookie_header(entries: &[(String, String)]) -> Option<String> {
    if entries.is_empty() {
        return None;
    }
    Some(entries.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; "))
}

pub fn dispatch(args: &[&str]) -> i32 {
    if args.is_empty() {
        eprintln!("usage: fmtool testclient http|ws|run ...");
        return 2;
    }
    match args[0] {
        "http" => http::http_cli(&args[1..]),
        "ws" => ws::ws_cli(&args[1..]),
        "run" => run::run_cli(&args[1..]),
        _ => {
            eprintln!("unknown testclient subcommand: {}", args[0]);
            2
        }
    }
}
