// json.rs — 最小 JSON 解析器/序列化器 (零依赖).
//
// 够用就行: 支持 object / array / string / number / true / false / null.
// 仅覆盖 fastapi_mojo 自身的场景/输出/历史 JSONL 需求, 不做 RFC 8259 全覆盖
// (例: 不支持 number 的指数/小数同时出现 — bench 数值都是整数或简单小数).
// 用途:
//   - 解析 benchmark-scenarios.json (list of {name,url,n,c})
//   - 生成 benchmark-results.json (嵌套 dict/list)
//   - 解析历史 JSONL (每行一个完整 JSON object)

use std::fmt;

// ---------- Value 类型 ----------

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Array(Vec<Value>),
    Object(Vec<(String, Value)>),
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self { Value::Str(s) => Some(s.as_str()), _ => None }
    }
    pub fn as_num(&self) -> Option<f64> {
        match self { Value::Num(n) => Some(*n), _ => None }
    }
    pub fn as_arr(&self) -> Option<&Vec<Value>> {
        match self { Value::Array(a) => Some(a), _ => None }
    }
    pub fn as_obj(&self) -> Option<&Vec<(String, Value)>> {
        match self { Value::Object(o) => Some(o), _ => None }
    }
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(o) => o.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

// ---------- Parse ----------

pub struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

#[derive(Debug)]
pub struct ParseError {
    pub msg: String,
    pub pos: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "JSON parse error at {}: {}", self.pos, self.msg)
    }
}

impl std::error::Error for ParseError {}

impl<'a> Parser<'a> {
    pub fn new(s: &'a str) -> Self {
        Self { bytes: s.as_bytes(), pos: 0 }
    }
    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() {
            let b = self.bytes[self.pos];
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' { self.pos += 1; }
            else { break; }
        }
    }
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }
    fn eat(&mut self, b: u8) -> Result<(), ParseError> {
        if self.peek() == Some(b) { self.pos += 1; Ok(()) }
        else { Err(self.err(format!("expected '{}'", b as char))) }
    }
    fn err(&self, msg: impl Into<String>) -> ParseError {
        ParseError { msg: msg.into(), pos: self.pos }
    }

    pub fn parse_value(&mut self) -> Result<Value, ParseError> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.parse_object(),
            Some(b'[') => self.parse_array(),
            Some(b'"') => Ok(Value::Str(self.parse_string()?)),
            Some(b't') => { self.eat_word("true")?; Ok(Value::Bool(true)) }
            Some(b'f') => { self.eat_word("false")?; Ok(Value::Bool(false)) }
            Some(b'n') => { self.eat_word("null")?; Ok(Value::Null) }
            Some(b'-') | Some(b'0'..=b'9') => Ok(Value::Num(self.parse_number()?)),
            Some(c) => Err(self.err(format!("unexpected char '{}'", c as char))),
            None => Err(self.err("unexpected EOF")),
        }
    }

    fn eat_word(&mut self, w: &str) -> Result<(), ParseError> {
        if self.bytes[self.pos..].starts_with(w.as_bytes()) {
            self.pos += w.len();
            Ok(())
        } else {
            Err(self.err(format!("expected '{}'", w)))
        }
    }

    fn parse_string(&mut self) -> Result<String, ParseError> {
        self.eat(b'"')?;
        let mut out = String::new();
        loop {
            let b = self.peek().ok_or_else(|| self.err("unterminated string"))?;
            match b {
                b'"' => { self.pos += 1; return Ok(out); }
                b'\\' => {
                    self.pos += 1;
                    let esc = self.peek().ok_or_else(|| self.err("bad escape"))?;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\x08'),
                        b'f' => out.push('\x0c'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            self.pos += 1;
                            let hex = std::str::from_utf8(&self.bytes[self.pos..self.pos+4])
                                .map_err(|_| self.err("bad \\u escape"))?;
                            self.pos += 4;
                            let cp = u32::from_str_radix(hex, 16)
                                .map_err(|_| self.err("bad \\u escape"))?;
                            if let Some(c) = char::from_u32(cp) {
                                out.push(c);
                            } // else: drop surrogate silently (dev tool only)
                        }
                        _ => return Err(self.err(format!("bad escape \\{}", esc as char))),
                    }
                    self.pos += 1;
                }
                _ => {
                    // utf-8 byte → char (1~4 bytes)
                    let start = self.pos;
                    let s = std::str::from_utf8(&self.bytes[start..self.bytes.len()])
                        .map_err(|_| self.err("bad utf-8"))?;
                    let c = s.chars().next().ok_or_else(|| self.err("empty string"))?;
                    out.push(c);
                    self.pos += c.len_utf8();
                }
            }
        }
    }

    fn parse_number(&mut self) -> Result<f64, ParseError> {
        let start = self.pos;
        if self.peek() == Some(b'-') { self.pos += 1; }
        while let Some(b) = self.peek() {
            if b.is_ascii_digit() || b == b'.' || b == b'e' || b == b'E' || b == b'+' || b == b'-' {
                self.pos += 1;
            } else { break; }
        }
        std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| self.err("bad number"))?
            .parse::<f64>()
            .map_err(|_| self.err("bad number"))
    }

    fn parse_array(&mut self) -> Result<Value, ParseError> {
        self.eat(b'[')?;
        let mut arr = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') { self.pos += 1; return Ok(Value::Array(arr)); }
        loop {
            arr.push(self.parse_value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => { self.pos += 1; self.skip_ws(); }
                Some(b']') => { self.pos += 1; return Ok(Value::Array(arr)); }
                _ => return Err(self.err("expected ',' or ']'")),
            }
        }
    }

    fn parse_object(&mut self) -> Result<Value, ParseError> {
        self.eat(b'{')?;
        let mut obj = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') { self.pos += 1; return Ok(Value::Object(obj)); }
        loop {
            self.skip_ws();
            let k = self.parse_string()?;
            self.skip_ws();
            self.eat(b':')?;
            let v = self.parse_value()?;
            obj.push((k, v));
            self.skip_ws();
            match self.peek() {
                Some(b',') => { self.pos += 1; }
                Some(b'}') => { self.pos += 1; return Ok(Value::Object(obj)); }
                _ => return Err(self.err("expected ',' or '}'")),
            }
        }
    }
}

pub fn parse(s: &str) -> Result<Value, ParseError> {
    let mut p = Parser::new(s);
    let v = p.parse_value()?;
    p.skip_ws();
    if p.pos < p.bytes.len() {
        Err(p.err("trailing data"))
    } else {
        Ok(v)
    }
}

// ---------- Write (serialize, 紧凑格式无空格, key 顺序保持插入序) ----------

pub struct Writer<'a> {
    out: &'a mut String,
}

impl<'a> Writer<'a> {
    pub fn new(out: &'a mut String) -> Self { Self { out } }
    pub fn write(&mut self, v: &Value) {
        match v {
            Value::Null => self.out.push_str("null"),
            Value::Bool(true) => self.out.push_str("true"),
            Value::Bool(false) => self.out.push_str("false"),
            Value::Num(n) => self.write_num(*n),
            Value::Str(s) => self.write_str(s),
            Value::Array(a) => {
                self.out.push('[');
                for (i, x) in a.iter().enumerate() {
                    if i > 0 { self.out.push(','); }
                    self.write(x);
                }
                self.out.push(']');
            }
            Value::Object(o) => {
                self.out.push('{');
                for (i, (k, x)) in o.iter().enumerate() {
                    if i > 0 { self.out.push(','); }
                    self.write_str(k);
                    self.out.push(':');
                    self.write(x);
                }
                self.out.push('}');
            }
        }
    }
    fn write_num(&mut self, n: f64) {
        if n.is_nan() { self.out.push_str("null"); return; }
        if n.is_infinite() { self.out.push_str("null"); return; }
        if n == (n as i64) as f64 {
            // 整数路径: 避免 4.0 这种小数尾巴
            self.out.push_str(&format!("{}", n as i64));
        } else {
            self.out.push_str(&format!("{:.4}", n));
        }
    }
    fn write_str(&mut self, s: &str) {
        self.out.push('"');
        for c in s.chars() {
            match c {
                '"' => self.out.push_str("\\\""),
                '\\' => self.out.push_str("\\\\"),
                '\n' => self.out.push_str("\\n"),
                '\r' => self.out.push_str("\\r"),
                '\t' => self.out.push_str("\\t"),
                '\x08' => self.out.push_str("\\b"),
                '\x0c' => self.out.push_str("\\f"),
                c if (c as u32) < 0x20 => {
                    self.out.push_str(&format!("\\u{:04x}", c as u32));
                }
                c => self.out.push(c),
            }
        }
        self.out.push('"');
    }
}

pub fn write_into(out: &mut String, v: &Value) {
    Writer::new(out).write(v);
}

pub fn to_string(v: &Value) -> String {
    let mut s = String::new();
    write_into(&mut s, v);
    s
}
