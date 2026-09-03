//! parse.rs — HTTP 头部解析工具 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` §511-665 (`find_header_end` /
//! `bounded_strstr` / `utf8_valid` / `has_header_name_ci` /
//! `get_header_value_ci` / `connection_directive` / `expect_100_continue`)。
//! 纯函数、零 IO、零第三方 crate。
//!
//! 与 C 的差异(仅内部表达, 语义等价):
//!   - 返回 `Option<usize>` / `Option<Vec<u8>>` 取代 C 的 `-1` / out 缓冲;
//!   - `get_header_value_ci` 不做 outsz 截断 (C 仅当调用方缓冲过小时截断,
//!     实际调用点缓冲均充足; 调用方如需截断自行处理);
//!   - `connection_directive` 用 `ConnDirective` 枚举表达 0/1/2。

/// `\r\n\r\n` 在 `buf` 中首次出现的位置 **之后** 的偏移 (即 header 结束、
/// body 开始的字节偏移), 未找到返回 `None`。端口 C `find_header_end`。
pub fn find_header_end(buf: &[u8]) -> Option<usize> {
    if buf.len() < 4 {
        return None;
    }
    for i in 0..=buf.len() - 4 {
        if &buf[i..i + 4] == b"\r\n\r\n" {
            return Some(i + 4);
        }
    }
    None
}

/// 在 `hay[0..hlen]` 中查找 `needle` 首次出现的位置; 空 needle 或
/// needle 长于 hay 返回 `None`。端口 C `bounded_strstr`。
pub fn bounded_strstr(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() {
        return None;
    }
    for i in 0..=hay.len() - needle.len() {
        if &hay[i..i + needle.len()] == needle {
            return Some(i);
        }
    }
    None
}

/// 严格 UTF-8 校验 (bridge 本地版, 与 ws.rs `ws_validate_utf8` 独立实现;
/// 两者语义一致但入口不同域)。端口 C `utf8_valid`:
///   - ASCII < 0x80 直接通过;
///   - 2 字节序列: 头字节 >= 0xC2 (拒绝 overlong);
///   - 3 字节序列: 拒绝 surrogate (U+D800..U+DFFF);
///   - 4 字节序列: 头字节 > 0xF4 拒绝 (覆盖 > U+10FFFF 的编码空间);
///     **注意**: C 版只查头字节, 不验证 0xF4 开头的序列是否真的 <= U+10FFFF
///     (0xF4 0x90 0x80 0x80 = U+110000 会被 C 接受) — 保持字节等价, 不收紧;
///   - 续字节必须 0x80..0xBF; 非法头字节 / 截断 / 孤儿续字节均拒绝。
pub fn utf8_valid(s: &[u8]) -> bool {
    let mut i = 0usize;
    while i < s.len() {
        let c = s[i];
        let extra: usize;
        if c < 0x80 {
            i += 1;
            continue;
        } else if c & 0xE0 == 0xC0 {
            if c < 0xC2 {
                return false; // overlong
            }
            extra = 1;
        } else if c & 0xF0 == 0xE0 {
            extra = 2;
        } else if c & 0xF8 == 0xF0 {
            if c > 0xF4 {
                return false; // > U+10FFFF
            }
            extra = 3;
        } else {
            return false; // stray continuation / invalid lead
        }
        for k in 1..=extra {
            if i + k >= s.len() {
                return false;
            }
            if s[i + k] & 0xC0 != 0x80 {
                return false;
            }
        }
        if extra == 2 {
            let cp = ((c & 0x0F) as u32) << 12
                | ((s[i + 1] & 0x3F) as u32) << 6
                | (s[i + 2] & 0x3F) as u32;
            if (0xD800..=0xDFFF).contains(&cp) {
                return false; // surrogate
            }
        }
        i += 1 + extra;
    }
    true
}

fn eq_ascii_ci(a: u8, b: u8) -> bool {
    a.eq_ignore_ascii_case(&b)
}

/// 大小写不敏感地检查 header 块中是否存在名为 `name` 的头部 (必须在行首,
/// 即 `hdr[0]` 或前一字节为 `\n`)。端口 C `has_header_name_ci`。
pub fn has_header_name_ci(hdr: &[u8], name: &[u8]) -> bool {
    if name.is_empty() || name.len() > hdr.len() {
        return false;
    }
    for i in 0..=hdr.len() - name.len() {
        if i > 0 && hdr[i - 1] != b'\n' {
            continue;
        }
        let mut matched = true;
        for k in 0..name.len() {
            if !eq_ascii_ci(hdr[i + k], name[k]) {
                matched = false;
                break;
            }
        }
        if matched {
            return true;
        }
    }
    false
}

/// 大小写不敏感地提取首个 `name: value` 行的 value (去除前导/尾随空白,
/// 值到 `\r`/`\n` 为止)。端口 C `get_header_value_ci`。
pub fn get_header_value_ci(hdr: &[u8], name: &[u8]) -> Option<Vec<u8>> {
    if name.is_empty() || name.len() > hdr.len() {
        return None;
    }
    for i in 0..=hdr.len() - name.len() {
        if i > 0 && hdr[i - 1] != b'\n' {
            continue;
        }
        if !hdr[i..i + name.len()].eq_ignore_ascii_case(name) {
            continue;
        }
        let mut j = i + name.len();
        while j < hdr.len() && (hdr[j] == b' ' || hdr[j] == b'\t') {
            j += 1;
        }
        if j >= hdr.len() || hdr[j] != b':' {
            continue;
        }
        j += 1;
        while j < hdr.len() && (hdr[j] == b' ' || hdr[j] == b'\t') {
            j += 1;
        }
        let start = j;
        while j < hdr.len() && hdr[j] != b'\r' && hdr[j] != b'\n' {
            j += 1;
        }
        return Some(hdr[start..j].to_vec());
    }
    None
}

/// Connection 头指令扫描结果 (端口 C `connection_directive` 的 0/1/2)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnDirective {
    /// 1: 含 "close"
    Close,
    /// 2: 含 "keep-alive"
    KeepAlive,
    /// 0: 头缺失或仅含其他指令
    None,
}

/// 扫描 Connection 头 value: "close" 优先 (返回 `Close`), 否则 "keep-alive"
/// (返回 `KeepAlive`), 否则 `None`。端口 C `connection_directive` (含其
/// 逐位置子串扫描语义 — 不要求 token 边界, 与 C 行为字节等价)。
pub fn connection_directive(hdr: &[u8]) -> ConnDirective {
    let name = b"Connection";
    if name.len() > hdr.len() {
        return ConnDirective::None;
    }
    for i in 0..=hdr.len() - name.len() {
        if i > 0 && hdr[i - 1] != b'\n' {
            continue;
        }
        if !hdr[i..i + name.len()].eq_ignore_ascii_case(name) {
            continue;
        }
        let mut j = i + name.len();
        while j < hdr.len() && (hdr[j] == b' ' || hdr[j] == b'\t') {
            j += 1;
        }
        if j >= hdr.len() || hdr[j] != b':' {
            continue;
        }
        j += 1;
        let mut has_close = false;
        let mut has_keep = false;
        while j < hdr.len() && hdr[j] != b'\r' && hdr[j] != b'\n' {
            if j + 5 <= hdr.len() && hdr[j..j + 5].eq_ignore_ascii_case(b"close") {
                has_close = true;
            }
            if j + 10 <= hdr.len() && hdr[j..j + 10].eq_ignore_ascii_case(b"keep-alive") {
                has_keep = true;
            }
            j += 1;
        }
        if has_close {
            return ConnDirective::Close;
        }
        if has_keep {
            return ConnDirective::KeepAlive;
        }
        return ConnDirective::None;
    }
    ConnDirective::None
}

/// 大小写不敏感检查 `Expect: 100-continue` (RFC 7231 §5.1.1; 仅 honor
/// 100-continue, 遇到其他 Expect 值返回 false)。端口 C `expect_100_continue`
/// (含其非行首子串扫描语义, 与 C 行为字节等价)。
pub fn expect_100_continue(hdr: &[u8]) -> bool {
    let name = b"expect:";
    let val = b"100-continue";
    if name.len() > hdr.len() {
        return false;
    }
    let mut i = 0usize;
    while i + name.len() <= hdr.len() {
        if hdr[i..i + name.len()].eq_ignore_ascii_case(name) {
            let mut j = i + name.len();
            while j < hdr.len() && hdr[j] != b'\r' && hdr[j] != b'\n' {
                if j + val.len() <= hdr.len()
                    && hdr[j..j + val.len()].eq_ignore_ascii_case(val)
                {
                    return true;
                }
                j += 1;
            }
            return false;
        }
        i += 1;
    }
    false
}
