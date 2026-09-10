//! 决策-54 (ADR-0029): 手写 regex 引擎 (零第三方依赖, Rust std only).
//!
//! 支持面 (Python `re` 常用子集, 文档化): 字面量 / `.` / 转义
//! (`\n \t \r \f \v \a \0` + class escape `\d \D \w \W \s \S`
//! 类内外均可) / 字符类 `[a-z]` (`^` 否定, `]` 首字符 = 字面, 类内
//! `\d` 展开为 range) / 量词 `* + ? {n} {n,} {n,m}` / 组 `(...)`
//! (非捕获) / 交替 `|` / 锚 `^` (仅串首, 无 multiline) / `$` (串尾或
//! 尾 `\n` 前, Python 同款) / 字边界 `\b`. 不支持 (偏差): 反向引用 /
//! 环视 / 命名组 / 内联标志.
//!
//! 匹配语义 = **search** (上游 pydantic 2.13.5 实测 parity, P26-h:
//! `^[a-z]+` vs "abcX" → match; `[a-z]+` vs "XabcX" → match).
//! 实现 = 有界 NFA (end-position 集合展开 + 步数预算; search = 存在性
//! 判定, 全可能展开天然正确; 预算超限 = 判未中, 防 pathological DoS).
//! FFI: `regex_match(pattern, s) -> i32` (1 = 命中 / 0 = 未中 /
//! -1 = 编译失败); 每调用编译+匹配 (注册期编译校验复用 rgx_compile_ok).

use std::collections::HashSet;

/// 步数预算 (header/query/path 值 <<1KB; 100k 步对合理 pattern 足够).
const STEP_BUDGET: u64 = 100_000;
/// 每层 end-position 集合上限 (去重后; 超限截断 — 存在性判定保守安全:
/// 截断只可能漏报 match, 不会误报; 实际向量远不到此规模).
const POS_CAP: usize = 1024;

#[derive(Debug, Clone)]
enum Node {
    /// 单字符集 (1 = 字面/点/转义字符; N = 字符类; negated).
    CharSet(Vec<u32>, bool),
    WordBoundary,
    AnchorStart,
    AnchorEnd,
    Empty,
    Concat(Vec<Node>),
    Alt(Vec<Node>),
    /// Repeat(child, min, max); max = u32::MAX = 无上限.
    Repeat(Box<Node>, u32, u32),
}

fn class_ranges(c: u8) -> Option<Vec<(u32, u32)>> {
    match c {
        b'd' => Some(vec![(0x30, 0x39)]),
        b'D' => Some(vec![(0x00, 0x2F), (0x3A, 0x40), (0x5B, 0x60), (0x7B, 0x7F)]),
        b'w' => Some(vec![(0x30, 0x39), (0x41, 0x5A), (0x5F, 0x5F), (0x61, 0x7A)]),
        b'W' => Some(vec![(0x00, 0x2F), (0x3A, 0x40), (0x5B, 0x5E), (0x60, 0x60), (0x7B, 0x7F)]),
        b's' => Some(vec![(0x09, 0x0D), (0x20, 0x20)]),
        b'S' => Some(vec![(0x00, 0x08), (0x0E, 0x1F), (0x21, 0x7F)]),
        _ => None,
    }
}

/// `.` = 除 \n 外任意 ASCII 字符 (Python 默认, 无 DOTALL; ASCII 域 —
/// 非 ASCII 字节不匹配, 文档化).
fn dot_char_set() -> Node {
    let mut v: Vec<u32> = (0u32..=0x7F).filter(|x| *x != 0x0A).collect();
    v.sort();
    Node::CharSet(v, false)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn new(s: &'a str) -> Self {
        Parser { s: s.as_bytes(), i: 0 }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let c = self.peek();
        if c.is_some() {
            self.i += 1;
        }
        c
    }

    fn parse(&mut self) -> Result<Node, String> {
        let node = self.parse_group()?;
        if self.peek().is_some() {
            return Err("trailing input".to_string());
        }
        Ok(node)
    }

    /// 组解析 = 交替序列 (括号内/顶层共用): parse_concat 由 '|' 分隔,
    /// 直到 ')' (顶层无 ')').
    fn parse_group(&mut self) -> Result<Node, String> {
        let mut alts: Vec<Node> = Vec::new();
        loop {
            alts.push(self.parse_concat()?);
            if self.peek() == Some(b'|') {
                self.bump();
                continue;
            }
            break;
        }
        if alts.len() == 1 {
            Ok(alts.pop().unwrap())
        } else {
            Ok(Node::Alt(alts))
        }
    }

    fn parse_concat(&mut self) -> Result<Node, String> {
        let mut items: Vec<Node> = Vec::new();
        while let Some(c) = self.peek() {
            if c == b'|' || c == b')' {
                break;
            }
            items.push(self.parse_atom()?);
        }
        if items.is_empty() {
            Ok(Node::Empty)
        } else if items.len() == 1 {
            Ok(items.pop().unwrap())
        } else {
            Ok(Node::Concat(items))
        }
    }

    fn parse_atom(&mut self) -> Result<Node, String> {
        let c = self.bump().ok_or_else(|| "unterminated pattern".to_string())?;
        let base = match c {
            b'^' => Node::AnchorStart,
            b'$' => Node::AnchorEnd,
            b'.' => dot_char_set(),
            b'(' => {
                let inner = self.parse_group()?;
                if self.peek() != Some(b')') {
                    return Err("unbalanced '('".to_string());
                }
                self.bump();
                inner
            }
            b'[' => self.parse_class()?,
            b'\\' => {
                if self.peek() == Some(b'b') {
                    self.bump();
                    Node::WordBoundary
                } else {
                    self.parse_escape_outside_class()?
                }
            }
            b']' => Node::CharSet(vec![0x5D], false),  // 类外 ] = 字面 (Python 同款)
            b'{' => return Err("dangling '{' (no preceding atom)".to_string()),
            _ => Node::CharSet(vec![c as u32], false),
        };
        self.parse_quantifier(base)
    }

    fn parse_quantifier(&mut self, base: Node) -> Result<Node, String> {
        let mut node = base;
        if let Some(q) = self.peek() {
            match q {
                b'*' => {
                    self.bump();
                    node = Node::Repeat(Box::new(node), 0, u32::MAX);
                }
                b'+' => {
                    self.bump();
                    node = Node::Repeat(Box::new(node), 1, u32::MAX);
                }
                b'?' => {
                    self.bump();
                    node = Node::Repeat(Box::new(node), 0, 1);
                }
                b'{' => {
                    self.bump();
                    let (min, max) = self.parse_braces()?;
                    node = Node::Repeat(Box::new(node), min, max);
                }
                _ => {}
            }
        }
        Ok(node)
    }

    fn parse_braces(&mut self) -> Result<(u32, u32), String> {
        // '{' 已消费. 形态: n / n, / n,m
        let mut nums: Vec<u32> = Vec::new();
        while let Some(c) = self.peek() {
            if c.is_ascii_digit() {
                let start = self.i;
                while self.peek().is_some_and(|x| x.is_ascii_digit()) {
                    self.bump();
                }
                let t = std::str::from_utf8(&self.s[start..self.i]).unwrap_or("0");
                nums.push(t.parse().map_err(|_| "brace number overflow".to_string())?);
            } else if c == b',' && nums.len() == 1 {
                self.bump();
                if !self.peek().is_some_and(|x| x.is_ascii_digit()) {
                    if self.peek() == Some(b'}') {
                        self.bump();
                        return Ok((nums[0], u32::MAX));
                    }
                    return Err("bad brace form".to_string());
                }
            } else if c == b'}' {
                self.bump();
                break;
            } else {
                return Err("bad brace form".to_string());
            }
        }
        match nums.len() {
            1 => Ok((nums[0], nums[0])),
            2 => {
                if nums[0] > nums[1] {
                    return Err("brace min > max".to_string());
                }
                Ok((nums[0], nums[1]))
            }
            _ => Err("bad brace form".to_string()),
        }
    }

    fn parse_class(&mut self) -> Result<Node, String> {
        // '[' 已消费.
        let mut negated = false;
        if self.peek() == Some(b'^') {
            negated = true;
            self.bump();
        }
        let mut chars: HashSet<u32> = HashSet::new();
        let mut any = false;
        loop {
            let c = self.bump().ok_or_else(|| "unterminated '['".to_string())?;
            if c == b']' {
                if !any && !negated {
                    return Err("empty char class".to_string());
                }
                break;
            }
            any = true;
            // 类内 escape: class escape (\d 等) 展开 range; 其余 escape = 字面字符.
            if c == b'\\' {
                let e = self.bump().ok_or_else(|| "trailing backslash".to_string())?;
                if let Some(ranges) = class_ranges(e) {
                    for (lo2, hi2) in ranges {
                        let mut v = lo2;
                        while v <= hi2 {
                            chars.insert(v);
                            v += 1;
                        }
                    }
                    continue;
                }
                chars.insert(Self::char_escape(e)?);
                continue;
            }
            let lo = c as u32;
            if self.peek() == Some(b'-') && self.s.get(self.i + 1).copied() != Some(b']') {
                self.bump();
                let hc = self.bump().ok_or_else(|| "dangling '-' in class".to_string())?;
                if hc == b'\\' {
                    let e = self.bump().ok_or_else(|| "trailing backslash".to_string())?;
                    if let Some(ranges) = class_ranges(e) {
                        for (lo2, hi2) in ranges {
                            let mut v = lo2;
                            while v <= hi2 {
                                chars.insert(v);
                                v += 1;
                            }
                        }
                    } else {
                        chars.insert(Self::char_escape(e)?);
                    }
                    continue;
                }
                let hi = hc as u32;
                if lo > hi {
                    return Err("inverted range".to_string());
                }
                let mut v = lo;
                while v <= hi {
                    chars.insert(v);
                    v += 1;
                }
            } else {
                chars.insert(lo);
            }
        }
        let mut v: Vec<u32> = chars.into_iter().collect();
        v.sort();
        Ok(Node::CharSet(v, negated))
    }

    fn parse_escape_outside_class(&mut self) -> Result<Node, String> {
        let c = self
            .bump()
            .ok_or_else(|| "trailing backslash".to_string())?;
        if let Some(ranges) = class_ranges(c) {
            let mut chars: HashSet<u32> = HashSet::new();
            for (lo, hi) in ranges {
                let mut v = lo;
                while v <= hi {
                    chars.insert(v);
                    v += 1;
                }
            }
            let mut v: Vec<u32> = chars.into_iter().collect();
            v.sort();
            return Ok(Node::CharSet(v, false));
        }
        Ok(Node::CharSet(vec![Self::char_escape(c)?], false))
    }

    fn char_escape(c: u8) -> Result<u32, String> {
        match c {
            b'n' => Ok(0x0A),
            b't' => Ok(0x09),
            b'r' => Ok(0x0D),
            b'f' => Ok(0x0C),
            b'v' => Ok(0x0B),
            b'a' => Ok(0x07),
            b'0' => Ok(0x00),
            b'b' => Err("word boundary escape (use pattern-level \\b)".to_string()),
            _ => Ok(c as u32),
        }
    }
}

impl Node {
}

fn is_word_char(c: u32) -> bool {
    (0x30..=0x39).contains(&c) || (0x41..=0x5A).contains(&c) || c == 0x5F || (0x61..=0x7A).contains(&c)
}

/// NFA 展开: 从 pos 出发 node 的全部 end-position (去重, 有界).
fn end_positions(node: &Node, text: &[u32], pos: usize, budget: &mut u64) -> Vec<usize> {
    if *budget == 0 {
        return Vec::new();
    }
    *budget -= 1;
    match node {
        Node::CharSet(chars, negated) => {
            if pos >= text.len() {
                return Vec::new();
            }
            let ch = text[pos];
            let hit = chars.binary_search(&ch).is_ok();
            let ok = if *negated { !hit } else { hit };
            if ok {
                vec![pos + 1]
            } else {
                Vec::new()
            }
        }
        Node::WordBoundary => {
            let prev_word = pos > 0 && is_word_char(text[pos - 1]);
            let cur_word = pos < text.len() && is_word_char(text[pos]);
            if prev_word != cur_word {
                vec![pos]
            } else {
                Vec::new()
            }
        }
        Node::AnchorStart => {
            if pos == 0 {
                vec![pos]
            } else {
                Vec::new()
            }
        }
        Node::AnchorEnd => {
            if pos >= text.len() || (pos == text.len() - 1 && text[pos] == 0x0A) {
                vec![pos]
            } else {
                Vec::new()
            }
        }
        Node::Empty => vec![pos],
        Node::Concat(items) => {
            let mut cur = vec![pos];
            for it in items {
                let mut next: HashSet<usize> = HashSet::new();
                for &p in &cur {
                    for e in end_positions(it, text, p, budget) {
                        if next.len() < POS_CAP {
                            next.insert(e);
                        }
                    }
                    if *budget == 0 {
                        return Vec::new();
                    }
                }
                if next.len() > POS_CAP {
                    next = next.into_iter().take(POS_CAP).collect();
                }
                cur = next.into_iter().collect();
                if cur.is_empty() {
                    return Vec::new();
                }
            }
            cur
        }
        Node::Alt(alts) => {
            let mut out: HashSet<usize> = HashSet::new();
            for a in alts {
                for e in end_positions(a, text, pos, budget) {
                    if out.len() < POS_CAP {
                        out.insert(e);
                    }
                }
                if *budget == 0 {
                    break;
                }
            }
            let mut v: Vec<usize> = out.into_iter().collect();
            v.sort();
            v
        }
        Node::Repeat(child, min, max) => {
            let e0 = vec![pos];
            let mut levels: Vec<Vec<usize>> = vec![e0.clone()];
            let mut cur = e0;
            let mut k: u32 = 0;
            loop {
                if k == *max {
                    break;
                }
                let mut next: HashSet<usize> = HashSet::new();
                for &p in &cur {
                    for e in end_positions(child, text, p, budget) {
                        if next.len() < POS_CAP {
                            next.insert(e);
                        }
                    }
                }
                if *budget == 0 {
                    return Vec::new();
                }
                if next.is_empty() {
                    break;
                }
                cur = next.into_iter().collect();
                levels.push(cur.clone());
                k += 1;
            }
            let mut out: HashSet<usize> = HashSet::new();
            let start = (*min as usize).min(levels.len());
            for lvl in &levels[start..] {
                for &p in lvl {
                    if out.len() < POS_CAP {
                        out.insert(p);
                    }
                }
            }
            let mut v: Vec<usize> = out.into_iter().collect();
            v.sort();
            v
        }
    }
}

/// 编译 + search. 1 = 命中 / 0 = 未中 / -1 = 编译失败.
pub fn rgx_match(pattern: &str, s: &str) -> i32 {
    let mut p = Parser::new(pattern);
    let node = match p.parse() {
        Ok(n) => n,
        Err(_) => return -1,
    };
    if p.peek().is_some() {
        return -1;
    }
    let text: Vec<u32> = s.bytes().map(|b| b as u32).collect();
    let mut budget = STEP_BUDGET;
    for start in 0..=text.len() {
        let ends = end_positions(&node, &text, start, &mut budget);
        if !ends.is_empty() {
            return 1;
        }
        if budget == 0 {
            break;
        }
    }
    0
}

/// 仅编译校验 (注册期 check 用). true = 可编译.
pub fn rgx_compile_ok(pattern: &str) -> bool {
    let mut p = Parser::new(pattern);
    if p.parse().is_err() {
        return false;
    }
    p.peek().is_none()
}

#[cfg(test)]
pub fn rgx(pattern: &str, s: &str) -> i32 {
    rgx_match(pattern, s)
}
