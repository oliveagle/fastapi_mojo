// csv.rs — 最小 CSV 解析 (仅够 hey -o csv 输出, 零依赖).
//
// hey csv 首行是列名, 后续每行一个请求. 支持标准双引号转义 (RFC 4180
// 基本子集): "..." 内的逗号/引号("" → ") 正确处理. 其余视为裸字段.

#[derive(Debug, Clone)]
pub struct Csv {
    pub header: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

impl Csv {
    pub fn parse(input: &str) -> Result<Csv, String> {
        let lines: Vec<&str> = input.lines().collect();
        if lines.is_empty() {
            return Err("empty csv".into());
        }
        let header = parse_line(lines[0])?;
        let mut rows = Vec::new();
        for l in &lines[1..] {
            if l.trim().is_empty() {
                continue;
            }
            rows.push(parse_line(l)?);
        }
        Ok(Csv { header, rows })
    }

    /// 按列名取某行某字段 (不存在返回 "")
    pub fn field(&self, row: &[String], col: &str) -> String {
        for (i, h) in self.header.iter().enumerate() {
            if h.trim() == col {
                return row.get(i).cloned().unwrap_or_default();
            }
        }
        String::new()
    }
}

fn parse_line(line: &str) -> Result<Vec<String>, String> {
    let bytes = line.as_bytes();
    let mut fields = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if in_quotes {
            if b == b'"' {
                if i + 1 < bytes.len() && bytes[i + 1] == b'"' {
                    cur.push('"');
                    i += 2;
                    continue;
                }
                in_quotes = false;
                i += 1;
                continue;
            }
            cur.push(b as char);
            i += 1;
        } else if b == b'"' {
            in_quotes = true;
            i += 1;
        } else if b == b',' {
            fields.push(std::mem::take(&mut cur));
            i += 1;
        } else if b == b'\r' {
            i += 1; // skip stray CR
        } else {
            cur.push(b as char);
            i += 1;
        }
    }
    if in_quotes {
        return Err("unterminated quoted field".into());
    }
    fields.push(cur);
    Ok(fields)
}
