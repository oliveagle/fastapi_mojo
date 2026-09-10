//! file_protocol.rs — FileResponse **纯协议**原语（决策-48, ADR-0023）。
//!
//! starlette 1.6.0 `responses.py` 无 IO 部分的行为等价移植（/tmp/fresp_probe
//! p10* 逐条 probe 证据，ADR-0023 §1）：RFC1123 时间 / RFC5987 quote /
//! Content-Disposition / charset 规则 / etag（md5 在 crypto.rs）/ Range
//! 解析（含 101+ 段 → [] quirk 与 4 条 400 消息）/ multipart content-length
//! 公式 / 26-hex boundary。I/O（stat/读/发送）在 file_serve.rs。
//! 零第三方 crate；纯函数 + `time_util::now_ns`（boundary seed）。

use super::crypto::md5_hex;
use super::time_util::now_ns;

// ========== 时间格式化（formatdate(usegmt=True) parity）==========

const WEEKDAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// Howard Hinnant `civil_from_days`：1970-01-01 起 day 数 → (Y, M, D)。
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = (yoe + era * 400) as i32;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `formatdate(sec, usegmt=True)` parity：`Wdy, DD Mon YYYY HH:MM:SS GMT`
/// （%02d 补零；1970-01-01 = Thu；正秒截断 = time.gmtime 语义）。
pub fn fmt_rfc1123(sec: i64) -> String {
    let days = sec / 86400;
    let rem = sec % 86400;
    let (y, mo, d) = civil_from_days(days);
    let wd = (days.rem_euclid(7) + 3) % 7;
    format!(
        "{}, {:02} {} {:04} {:02}:{:02}:{:02} GMT",
        WEEKDAYS[wd as usize],
        d,
        MONTHS[(mo - 1) as usize],
        y,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60,
    )
}

// ========== RFC5987 / Content-Disposition / charset 规则 ==========

/// `urllib.parse.quote` 对 filename 的有效语义（safe='/' 默认）：永不转义集
/// `[A-Za-z0-9_.~-/]`，其余（含非 ASCII UTF-8）→ %XX 大写。
pub fn rfc5987_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_' | b'-' | b'.' | b'~' | b'/' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// `{cdt}; filename="f"`；quote 后变化 → `{cdt}; filename*=utf-8''{q}`。
pub fn build_content_disposition(filename: &str, cdt: &str) -> Option<String> {
    if filename.is_empty() {
        return None;
    }
    let q = rfc5987_quote(filename);
    if q == filename {
        Some(format!("{cdt}; filename=\"{filename}\""))
    } else {
        Some(format!("{cdt}; filename*=utf-8''{q}"))
    }
}

/// `Response.init_headers` 规则：`text/*`（大小写敏感前缀）且不含
/// `charset=`（大小写不敏感）→ 追加 `; charset=utf-8`。
pub fn apply_charset_rule(media_type: &str) -> String {
    if media_type.starts_with("text/") && !media_type.to_lowercase().contains("charset=") {
        format!("{media_type}; charset=utf-8")
    } else {
        media_type.to_string()
    }
}

/// etag = `"` + md5(repr(mtime) + "-" + str(size)) + `"`（整秒 mtime 的
/// f64 Display 与 Python repr 差 ".0" — §3.5 文档化；opaque token 语义不变）。
pub fn etag_from_mtime_size(mtime: f64, size: i64) -> String {
    format!("\"{}\"", md5_hex(format!("{mtime}-{size}").as_bytes()))
}

// ========== Range 解析（_parse_range_header/_parse_ranges parity）==========

#[derive(Clone, Debug, PartialEq)]
pub enum RangeErr {
    /// 400 + body = 消息（4 条精确措辞）。
    Malformed(String),
    /// 416 + `Content-Range: bytes */size`。
    Unsatisfiable(i64),
}

/// 单个 part：空 / "-" / 无 "-" / 非数字 → None（Python try/except 跳过）；
/// suffix "-N" → (max(size-N,0), size)；"S-E" → (S, E<size ? E+1 : size)；"S-" → (S, size)。
fn parse_one_part(part: &str, file_size: i64) -> Option<(i64, i64)> {
    let part = part.trim();
    if part.is_empty() || part == "-" {
        return None;
    }
    let (s, e) = part.split_once('-')?;
    let s = s.trim();
    let e = e.trim();
    if s.is_empty() {
        let n = e.parse::<i64>().ok()?;
        return Some(((file_size - n).max(0), file_size));
    }
    let start = s.parse::<i64>().ok()?;
    let end = if e.is_empty() {
        file_size
    } else {
        let en = e.parse::<i64>().ok()?;
        if en < file_size {
            en + 1
        } else {
            file_size
        }
    };
    Some((start, end))
}

/// starlette `_parse_range_header` parity（顺序敏感）：无 "=" → Malformed
/// （默认消息）；units≠bytes → Malformed；**101+ 段 → Ok([])（→200 quirk，
/// 非 400）**；0 有效 part → Malformed("...must be requested")；start 越界 →
/// Unsatisfiable（**先于** start>=end）；start>=end → Malformed；单段直返；
/// 多段排序 + 合并重叠（start <= last_end → 延展 end）。
pub fn parse_range_header(http_range: &str, file_size: i64) -> Result<Vec<(i64, i64)>, RangeErr> {
    let (units, range_) = match http_range.split_once('=') {
        Some(t) => t,
        None => return Err(RangeErr::Malformed("Malformed range header.".into())),
    };
    if units.trim().to_lowercase() != "bytes" {
        return Err(RangeErr::Malformed("Only support bytes range".into()));
    }
    if range_.split(',').count() > 100 {
        return Ok(Vec::new());
    }
    let mut ranges = Vec::new();
    for part in range_.split(',') {
        if let Some(r) = parse_one_part(part, file_size) {
            ranges.push(r);
        }
    }
    if ranges.is_empty() {
        return Err(RangeErr::Malformed(
            "Range header: range must be requested".into(),
        ));
    }
    if ranges.iter().any(|(s, _)| *s < 0 || *s >= file_size) {
        return Err(RangeErr::Unsatisfiable(file_size));
    }
    if ranges.iter().any(|(s, e)| *s >= *e) {
        return Err(RangeErr::Malformed(
            "Range header: start must be less than end".into(),
        ));
    }
    if ranges.len() == 1 {
        return Ok(ranges);
    }
    ranges.sort();
    let mut result = vec![ranges[0]];
    for (s, e) in &ranges[1..] {
        let last = result.last_mut().unwrap();
        if *s <= last.1 {
            last.1 = last.1.max(*e);
        } else {
            result.push((*s, *e));
        }
    }
    Ok(result)
}

// ========== multipart / boundary ==========

/// `generate_multipart` content-length 公式（p10c MP2 实测 242 = 手算 242）：
/// 每段 49 + bl + len(ct) + len(str(size)) + len(str(s)) + len(str(e-1)) +
/// (e-s)；总长 + 4 + bl（终止符 `--{b}--`）。（49 = 47 固定头字符 + 段尾 CRLF 2）
pub fn multipart_content_length(
    ranges: &[(i64, i64)],
    boundary_len: usize,
    content_type: &str,
    size: i64,
) -> i64 {
    let mut total = 4 + boundary_len as i64;
    for (s, e) in ranges {
        total += 49
            + boundary_len as i64
            + content_type.len() as i64
            + size.to_string().len() as i64
            + s.to_string().len() as i64
            + (e - 1).to_string().len() as i64
            + (e - s);
    }
    total
}

/// `secrets.token_hex(13)` parity（starlette 1.6.0 `_handle_multiple_ranges`
/// 实测：26 小写 hex = 104-bit 熵，对齐浏览器 95-96 bit）：xorshift32 × 6
/// 混合后取前 26 字符；seed = now_ns ^ fd ^ size，每请求唯一。
pub fn generate_boundary(fd: i32, size: i64) -> String {
    let mut x = (now_ns() ^ ((fd as u64).wrapping_mul(0x9E37_79B9) ^ size.unsigned_abs()))
        .wrapping_mul(0x41C6_CE57) as u32;
    if x == 0 {
        x = 0xDEADBEEF;
    }
    let mut out = String::with_capacity(26);
    for _ in 0..6 {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        out.push_str(&format!("{x:08x}"));
    }
    out.truncate(26);
    out
}
