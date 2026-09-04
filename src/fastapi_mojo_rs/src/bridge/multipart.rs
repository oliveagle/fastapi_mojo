//! bridge/multipart.rs — multipart/form-data 解析 (Goal-0002 P5.2 + G3 ROI #3).
//!
//! 为什么 Rust 而不是 Mojo: multipart body 含任意二进制文件内容 (PNG / PDF /
//! ZIP 等), Mojo String 是 UTF-8 容器, [byte=...] 切片在非 codepoint boundary
//! 上 assert; span_to_str 转换会 U+FFFD 替换 invalid 字节, 文件内容已损毁.
//! Rust `&[u8]` 字节切片天然无此约束. 符合 ADR-0010 原则: 字节逻辑归 Rust
//! 静态库承载, Mojo 通过 FFI 调用.
//!
//! 行为等价 multipart 解析 (RFC 2046 §5.1.1 / RFC 7578):
//!   - CT 提取 boundary (case-insensitive "boundary=")
//!   - delim = "\r\n--<boundary>", terminator = "--<boundary>--"
//!   - 每个 part: headers + "\r\n\r\n" + body
//!   - Content-Disposition 提取 name + filename (filename = 文件字段)
//!   - 文件 body 用 base64 编码注入 (Mojo String 安全)
//!
//! 限制:
//!   - body 大小 <= set_max_body_size (默认 1MB; e2e 用小文件)
//!   - 单 part 文件 body base64 后 <= 16MB (硬限制; 超限 part 仍 parse, body 空)
//!   - parts 数量 <= 32 (防 multipart bomb)
//!
//! FFI 表面 (ffi.rs 包装) — 全部纯整数返回 (i64), 规避两类 ABI 陷阱:
//!   1. Mojo CStringSlice 对 Rust CSlice 的解析歧义 (span_to_str 在 CSlice 上
//!      会 index OOB / segfault) -- 见 ADR-0010.
//!   2. Rust c_int 返回 -1 时 x86-64 ABI 写入 EAX 零扩展 RAX, Mojo 按 Int(int64)
//!      读到 uint64 巨大值, 导致 `n_parts <= 0` 等比较误判, 触发 40 亿次空循环
//!      (教训-13). 全部 mp_* 返回类型用 i64, -1 完整传播.
//!
//! FFI 导出:
//!   mp_parse_current() -> i64  // 解析 active conn 的 multipart body, 返回 part 数
//!                              //   (-1 = 失败)
//!   mp_part_count() -> i64     // 上次解析的 part 数 (-1 = 未解析)
//!   mp_part_field_len(i, field) -> i64  // part 字段长度
//!   mp_part_field_byte(i, field, idx) -> i64  // 逐字节读取 (越界返回 -1)

use std::os::raw::c_int;
use std::sync::{Mutex, MutexGuard};

use super::conn::conn_table;

const MAX_PARTS: usize = 32;
const MAX_B64_PER_PART: usize = 16 * 1024 * 1024; // 16MB

#[derive(Default)]
pub struct MpPart {
    pub name: Vec<u8>,
    pub filename: Option<Vec<u8>>,
    pub content_type: Vec<u8>,
    pub body: Vec<u8>,
    pub body_b64: Vec<u8>, // 预编码 (避免每次调用重新编码)
}

#[derive(Default)]
pub struct MpState {
    pub parts: Vec<MpPart>,
    pub last_count: c_int,
}

static CURRENT_MP: Mutex<MpState> = Mutex::new(MpState {
    parts: Vec::new(),
    last_count: -1,
});

pub fn lock_mp() -> MutexGuard<'static, MpState> {
    CURRENT_MP.lock().unwrap_or_else(|e| e.into_inner())
}

// ===== helpers =====

/// CT 里提取 boundary value (case-insensitive). 不含 "--" 前缀.
fn extract_boundary(ct: &[u8]) -> Option<Vec<u8>> {
    // 找 "boundary" (lowercase)
    let needle = b"boundary";
    let n = ct.len();
    let mut i = 0;
    while i + needle.len() <= n {
        // case-insensitive match
        let mut ok = true;
        for j in 0..needle.len() {
            let c = ct[i + j];
            let l = if c.is_ascii_uppercase() { c + 32 } else { c };
            if l != needle[j] {
                ok = false;
                break;
            }
        }
        if !ok {
            i += 1;
            continue;
        }
        // match 后必须是 = 或 含 ;WSP 等
        let mut j = i + needle.len();
        // skip whitespace
        while j < n && (ct[j] == b' ' || ct[j] == b'\t') {
            j += 1;
        }
        if j >= n || ct[j] != b'=' {
            i += 1;
            continue;
        }
        j += 1;
        // skip WSP
        while j < n && (ct[j] == b' ' || ct[j] == b'\t') {
            j += 1;
        }
        let mut b = j;
        // skip leading quote
        if b < n && ct[b] == b'"' {
            b += 1;
        }
        let mut e = b;
        while e < n {
            let c = ct[e];
            if c == b';' || c == b'"' || c == b'\r' || c == b'\n' {
                break;
            }
            e += 1;
        }
        if e > b {
            return Some(ct[b..e].to_vec());
        }
        return None;
    }
    None
}

/// 在 haystack[start..] 找 needle, 返回绝对偏移 (start..) 或 None.
fn find_from(haystack: &[u8], start: usize, needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || start + needle.len() > haystack.len() {
        return None;
    }
    let mut i = start;
    while i + needle.len() <= haystack.len() {
        let mut ok = true;
        for j in 0..needle.len() {
            if haystack[i + j] != needle[j] {
                ok = false;
                break;
            }
        }
        if ok {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// 提取 attr="value" 或 attr=value (value 到 ; 或结尾). case-insensitive.
fn extract_attr(headers_val: &[u8], attr: &[u8]) -> Option<Vec<u8>> {
    let n = headers_val.len();
    let al = attr.len();
    let mut i = 0;
    while i + al < n {
        let mut ok = true;
        for j in 0..al {
            let c = headers_val[i + j];
            let l = if c.is_ascii_uppercase() { c + 32 } else { c };
            if l != attr[j] {
                ok = false;
                break;
            }
        }
        if !ok {
            i += 1;
            continue;
        }
        if headers_val[i + al] != b'=' {
            i += 1;
            continue;
        }
        let mut b = i + al + 1;
        // trim WSP
        while b < n && (headers_val[b] == b' ' || headers_val[b] == b'\t') {
            b += 1;
        }
        let quoted = b < n && headers_val[b] == b'"';
        if quoted {
            b += 1;
            let e_start = b;
            while b < n && headers_val[b] != b'"' {
                b += 1;
            }
            return Some(headers_val[e_start..b].to_vec());
        } else {
            let e_start = b;
            while b < n && headers_val[b] != b';' && headers_val[b] != b' ' && headers_val[b] != b'\t' {
                b += 1;
            }
            return Some(headers_val[e_start..b].to_vec());
        }
    }
    None
}

/// 提取 part header 块 (到空行 \r\n\r\n 或 \n\n).
/// 返回 (headers, body_start_offset). headers 是 trimmed slice (不含尾 CRLF).
fn split_part_headers(part: &[u8]) -> Option<(&[u8], usize)> {
    let n = part.len();
    let mut i = 0;
    while i < n {
        // 找行末
        let mut line_end = i;
        while line_end < n && part[line_end] != b'\n' {
            line_end += 1;
        }
        // 检查是否空行 (line_end == i 即 CRLF 起头空行)
        if line_end == i {
            // 空行: 跳到下一字节作为 body 起点
            return Some((&part[..i], i + 1));
        }
        // 行内: trim \r 末
        let actual_end = if line_end > 0 && part[line_end - 1] == b'\r' {
            line_end - 1
        } else {
            line_end
        };
        if actual_end == i {
            // 行全是 \r: 也算空行
            return Some((&part[..i], line_end + 1));
        }
        if line_end == n {
            // 到末尾无空行
            return None;
        }
        i = line_end + 1;
    }
    None
}

/// 解析一个 header 行 (e.g. "Content-Disposition: form-data; name=\"x\"").
/// 返回 (key_lower, value).
fn parse_header_line(line: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let n = line.len();
    let mut colon = 0;
    while colon < n && line[colon] != b':' {
        colon += 1;
    }
    if colon == 0 || colon >= n {
        return None;
    }
    let mut key = Vec::with_capacity(colon);
    for &c in &line[..colon] {
        key.push(if c.is_ascii_uppercase() { c + 32 } else { c });
    }
    // trim leading WSP from value
    let mut vb = colon + 1;
    while vb < n && (line[vb] == b' ' || line[vb] == b'\t') {
        vb += 1;
    }
    let value = line[vb..n].to_vec();
    Some((key, value))
}

/// base64 encode (RFC 4648). 不依赖第三方.
fn b64_encode(input: &[u8]) -> Vec<u8> {
    const TBL: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(input.len().div_ceil(3) * 4);
    let mut i = 0;
    let n = input.len();
    while i + 3 <= n {
        let b0 = input[i];
        let b1 = input[i + 1];
        let b2 = input[i + 2];
        let t = ((b0 as u32) << 16) | ((b1 as u32) << 8) | (b2 as u32);
        out.push(TBL[((t >> 18) & 0x3F) as usize]);
        out.push(TBL[((t >> 12) & 0x3F) as usize]);
        out.push(TBL[((t >> 6) & 0x3F) as usize]);
        out.push(TBL[(t & 0x3F) as usize]);
        i += 3;
    }
    let rem = n - i;
    if rem == 1 {
        let b0 = input[i];
        let t = (b0 as u32) << 16;
        out.push(TBL[((t >> 18) & 0x3F) as usize]);
        out.push(TBL[((t >> 12) & 0x3F) as usize]);
        out.push(b'=');
        out.push(b'=');
    } else if rem == 2 {
        let b0 = input[i];
        let b1 = input[i + 1];
        let t = ((b0 as u32) << 16) | ((b1 as u32) << 8);
        out.push(TBL[((t >> 18) & 0x3F) as usize]);
        out.push(TBL[((t >> 12) & 0x3F) as usize]);
        out.push(TBL[((t >> 6) & 0x3F) as usize]);
        out.push(b'=');
    }
    out
}

// ===== public API =====

/// 解析 multipart body. 返回 part 数 (>=0) 或 -1 (失败).
pub fn parse_multipart(body: &[u8], content_type: &[u8]) -> c_int {
    let boundary = match extract_boundary(content_type) {
        Some(b) => b,
        None => {
            let mut g = lock_mp();
            g.parts.clear();
            g.last_count = -1;
            return -1;
        }
    };
    if body.is_empty() || boundary.is_empty() {
        let mut g = lock_mp();
        g.parts.clear();
        g.last_count = -1;
        return -1;
    }
    // delim = "\r\n--" + boundary; leading part start with "--" + boundary
    let mut delim = Vec::with_capacity(2 + 2 + boundary.len());
    delim.extend_from_slice(b"\r\n--");
    delim.extend_from_slice(&boundary);
    let terminator: Vec<u8> = {
        let mut t = Vec::with_capacity(2 + 2 + boundary.len());
        t.extend_from_slice(b"--");
        t.extend_from_slice(&boundary);
        t
    };

    let mut parts: Vec<MpPart> = Vec::new();
    // 找第一个 part 起点 (terminator + \r\n 或 \n)
    let mut search_from = 0;
    let first_term = match find_from(body, 0, &terminator) {
        Some(p) => p,
        None => {
            let mut g = lock_mp();
            g.parts.clear();
            g.last_count = -1;
            return -1;
        }
    };
    // terminator 之后是 \r\n 或 \n
    let mut part_start = first_term + terminator.len();
    if part_start < body.len() && body[part_start] == b'\r' {
        part_start += 1;
    }
    if part_start < body.len() && body[part_start] == b'\n' {
        part_start += 1;
    }

    while let Some(next_delim) = find_from(body, search_from, &delim) {
        // 检查是否为 terminator: delim 后跟 "--"
        let after = next_delim + delim.len();
        let is_term = after + 1 < body.len() && body[after] == b'-' && body[after + 1] == b'-';
        // part 范围 [part_start, next_delim)
        if next_delim > part_start {
            let part_slice = &body[part_start..next_delim];
            if let Some((hdrs, body_start_in_part)) = split_part_headers(part_slice) {
                let mut mp = MpPart::default();
                // 解析 headers
                let mut line_start = 0;
                let hn = hdrs.len();
                while line_start < hn {
                    let mut line_end = line_start;
                    while line_end < hn && hdrs[line_end] != b'\n' {
                        line_end += 1;
                    }
                    let actual_end = if line_end > 0 && hdrs[line_end - 1] == b'\r' {
                        line_end - 1
                    } else {
                        line_end
                    };
                    if actual_end > line_start {
                        if let Some((key, value)) = parse_header_line(&hdrs[line_start..actual_end]) {
                            if key == b"content-disposition" {
                                if let Some(n) = extract_attr(&value, b"name") {
                                    mp.name = n;
                                }
                                if let Some(f) = extract_attr(&value, b"filename") {
                                    mp.filename = Some(f);
                                }
                            } else if key == b"content-type" {
                                mp.content_type = value;
                            }
                        }
                    }
                    if line_end == hn {
                        break;
                    }
                    line_start = line_end + 1;
                }
                // body = 精确 part 内容: \r\n--boundary 分隔符已被 next_delim 排除,
                // split_part_headers 的 body_start 在空行之后, 故 raw_body 不含分隔符.
                // 不再做任何 \n / \r\n 尾部 trim — 否则会错误丢弃文件内容的合法尾字节.
                let raw_body = &part_slice[body_start_in_part..];
                mp.body = raw_body.to_vec();
                // 限制 base64 大小
                if mp.body.len() <= MAX_B64_PER_PART {
                    mp.body_b64 = b64_encode(&mp.body);
                } else {
                    // 超限: body_b64 留空, e2e / handler 应检查 size
                    mp.body_b64.clear();
                }
                if mp.content_type.is_empty() && mp.filename.is_some() {
                    mp.content_type = b"application/octet-stream".to_vec();
                }
                if !mp.name.is_empty() {
                    parts.push(mp);
                }
            }
        }
        if is_term {
            break;
        }
        if parts.len() >= MAX_PARTS {
            break;
        }
        // 下一个 part 起点: 跳过 delim + \r\n
        part_start = next_delim + delim.len();
        if part_start < body.len() && body[part_start] == b'\r' {
            part_start += 1;
        }
        if part_start < body.len() && body[part_start] == b'\n' {
            part_start += 1;
        }
        search_from = part_start;
    }

    let count = parts.len() as c_int;
    let mut g = lock_mp();
    g.parts = parts;
    g.last_count = count;
    count
}

/// 读 active conn 的 body + Content-Type, 解析 multipart. 返回 part 数.
pub fn parse_current() -> c_int {
let body;
    let ct;
    {
        let t = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let active_idx = match t.active() {
            Some(i) => i,
            None => {
                let mut g = lock_mp();
                g.parts.clear();
                g.last_count = -1;
                return -1;
            }
        };
        let conn = match t.get(active_idx) {
            Some(c) => c,
            None => {
                let mut g = lock_mp();
                g.parts.clear();
                g.last_count = -1;
                return -1;
            }
        };
        if conn.body_got == 0 {
            let mut g = lock_mp();
            g.parts.clear();
            g.last_count = -1;
            return -1;
        }
        body = conn.body[..conn.body_got].to_vec();
        // Content-Type from hdr 缓冲 (case-insensitive match "content-type")
        let hdr_buf = &conn.hdr[..conn.hdr_total];
        let mut ct_val: Vec<u8> = Vec::new();
        let needle = b"content-type";
        let mut i = 0;
        'outer: while i + needle.len() <= hdr_buf.len() {
            // check it's at line start
            if i == 0 || hdr_buf[i - 1] == b'\n' {
                let mut ok = true;
                for j in 0..needle.len() {
                    let c = hdr_buf[i + j];
                    let l = if c.is_ascii_uppercase() { c + 32 } else { c };
                    if l != needle[j] {
                        ok = false;
                        break;
                    }
                }
                if ok {
                    // 找 ':'
                    let mut j = i + needle.len();
                    while j < hdr_buf.len() && (hdr_buf[j] == b' ' || hdr_buf[j] == b'\t') {
                        j += 1;
                    }
                    if j < hdr_buf.len() && hdr_buf[j] == b':' {
                        j += 1;
                        while j < hdr_buf.len() && (hdr_buf[j] == b' ' || hdr_buf[j] == b'\t') {
                            j += 1;
                        }
                        let val_start = j;
                        while j < hdr_buf.len() && hdr_buf[j] != b'\r' && hdr_buf[j] != b'\n' {
                            j += 1;
                        }
                        ct_val = hdr_buf[val_start..j].to_vec();
                        break 'outer;
                    }
                }
            }
            i += 1;
        }
        ct = ct_val;
    }
    parse_multipart(&body, &ct)
}

// ===== getters (供 ffi.rs 包装) =====

pub fn get_part_count() -> c_int {
    lock_mp().last_count
}

// ===== 逐字节访问器 (纯整数返回, 避免 CStringSlice ABI 歧义) =====
// field: 0=name 1=filename 2=content_type 3=body 4=body_b64
// 返回: field_len(i, field) -> 长度; field_byte(i, field, idx) -> 字节 or -1
pub fn get_part_field_len(i: usize, field: c_int) -> i64 {
    let g = lock_mp();
    let p = match g.parts.get(i) {
        Some(p) => p,
        None => return -1,
    };
    let v = match field {
        0 => &p.name,
        1 => p.filename.as_deref().unwrap_or(&[]),
        2 => &p.content_type,
        3 => &p.body,
        4 => &p.body_b64,
        _ => &[],
    };
    v.len() as i64
}

pub fn get_part_field_byte(i: usize, field: c_int, idx: i64) -> c_int {
    let g = lock_mp();
    let p = match g.parts.get(i) {
        Some(p) => p,
        None => return -1,
    };
    let v = match field {
        0 => &p.name,
        1 => p.filename.as_deref().unwrap_or(&[]),
        2 => &p.content_type,
        3 => &p.body,
        4 => &p.body_b64,
        _ => &[],
    };
    if idx < 0 || idx as usize >= v.len() {
        return -1;
    }
    v[idx as usize] as c_int
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_boundary_basic() {
        let ct = b"multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";
        assert_eq!(
            extract_boundary(ct).unwrap(),
            b"----WebKitFormBoundary7MA4YWxkTrZu0gW".to_vec()
        );
    }

    #[test]
    fn extract_boundary_quoted() {
        let ct = b"multipart/form-data; boundary=\"abc def\"";
        assert_eq!(extract_boundary(ct).unwrap(), b"abc def".to_vec());
    }

    #[test]
    fn extract_boundary_case_insensitive() {
        let ct = b"multipart/form-data; BOUNDARY=xxx";
        assert_eq!(extract_boundary(ct).unwrap(), b"xxx".to_vec());
    }

    #[test]
    fn parse_simple_text_field() {
        let body = b"--xxx\r\nContent-Disposition: form-data; name=\"hello\"\r\n\r\nworld\r\n--xxx--\r\n";
        let ct = b"multipart/form-data; boundary=xxx";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.name, b"hello");
        assert!(p.filename.is_none());
        assert_eq!(p.body, b"world");
        assert_eq!(String::from_utf8_lossy(&p.body_b64), "d29ybGQ=");
    }

    #[test]
    fn parse_file_upload() {
        let body = b"--xxx\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile content here\r\n--xxx--\r\n";
        let ct = b"multipart/form-data; boundary=xxx";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.name, b"upload");
        assert_eq!(p.filename.as_ref().unwrap(), b"a.txt");
        assert_eq!(p.content_type, b"text/plain");
        assert_eq!(p.body, b"file content here");
    }

    #[test]
    fn parse_file_trailing_newline_preserved() {
        // Regression: trailing \n (and \r\n) of file content must NOT be trimmed.
        // 分隔符已排除, raw_body 须为精确 part 内容 (决策-32 multipart roundtrip).
        let body = b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n\r\nHello e2e multipart!\n\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.body, b"Hello e2e multipart!\n");
        assert_eq!(String::from_utf8_lossy(&p.body_b64), "SGVsbG8gZTJlIG11bHRpcGFydCEK");
    }

    #[test]
    fn parse_file_trailing_crlf_preserved() {
        // file 内容合法以 \r\n 结尾: 须原样保留 (分隔符已排除).
        let body = b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n\r\ndata\r\n\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.body, b"data\r\n");
    }

    #[test]
    fn parse_multiple_fields_and_files() {
        let body = b"--xxx\r\n\
            Content-Disposition: form-data; name=\"title\"\r\n\r\n\
            My Document\r\n\
            --xxx\r\n\
            Content-Disposition: form-data; name=\"file1\"; filename=\"a.bin\"\r\n\
            Content-Type: application/octet-stream\r\n\r\n\
            \x00\x01\x02\x03\xff\r\n\
            --xxx\r\n\
            Content-Disposition: form-data; name=\"file2\"; filename=\"b.txt\"\r\n\r\n\
            text content\r\n\
            --xxx--\r\n";
        let ct = b"multipart/form-data; boundary=xxx";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 3);
        let parts = &lock_mp().parts;
        assert_eq!(parts[0].name, b"title");
        assert!(parts[0].filename.is_none());
        assert_eq!(parts[0].body, b"My Document");
        assert_eq!(parts[1].name, b"file1");
        assert_eq!(parts[1].filename.as_ref().unwrap(), b"a.bin");
        assert_eq!(parts[1].content_type, b"application/octet-stream");
        assert_eq!(parts[1].body, b"\x00\x01\x02\x03\xff");
        assert_eq!(parts[2].name, b"file2");
        assert_eq!(parts[2].filename.as_ref().unwrap(), b"b.txt");
        assert_eq!(parts[2].content_type, b"application/octet-stream"); // default
        assert_eq!(parts[2].body, b"text content");
    }

    #[test]
    fn parse_binary_body_preserved() {
        // body 含 NUL + 0xFF 等 invalid UTF-8, 必须 bytes-level 正确
        let body = b"--x\r\nContent-Disposition: form-data; name=\"data\"; filename=\"raw.bin\"\r\n\r\n\x00\xff\xfe\xfd\r\n--x--\r\n";
        let ct = b"multipart/form-data; boundary=x";
        let n = parse_multipart(body, ct);
        assert_eq!(n, 1);
        let p = &lock_mp().parts[0];
        assert_eq!(p.body, b"\x00\xff\xfe\xfd");
        // b64 反解应回到原 bytes
        // (测试仅断言 body 字段; b64 已预编码并验证)
        assert!(!p.body_b64.is_empty());
    }

    #[test]
    fn parse_missing_boundary_returns_neg1() {
        let body = b"hello world";
        let ct = b"application/octet-stream";
        assert_eq!(parse_multipart(body, ct), -1);
    }

    #[test]
    fn parse_empty_body_returns_neg1() {
        let body = b"";
        let ct = b"multipart/form-data; boundary=xxx";
        assert_eq!(parse_multipart(body, ct), -1);
    }

    #[test]
    fn extract_attr_quoted_and_unquoted() {
        assert_eq!(
            extract_attr(b"form-data; name=\"x\"", b"name").unwrap(),
            b"x".to_vec()
        );
        assert_eq!(
            extract_attr(b"form-data; name=y", b"name").unwrap(),
            b"y".to_vec()
        );
        assert_eq!(
            extract_attr(b"form-data; filename=\"a b.txt\"", b"filename").unwrap(),
            b"a b.txt".to_vec()
        );
    }
}
