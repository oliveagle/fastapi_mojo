//! response.rs — HTTP 响应头构建 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c`:
//!   - `get_content_type`      §1385-1402 (扩展名 -> MIME)
//!   - `json_escape_cstr`      §1452-1474 (JSON 字符串转义)
//!   - `send_response` 的头装配 §1495-1520 (本模块 `build_response_headers`)
//!   - `send_preflight_response` §1517-1526 (本模块 `build_preflight_response`;
//!     决策-42 起动态: env 配置 + 请求 Origin/ACRM/ACHR, 204/400)
//!   - CORS 头: C 时代固定常量 `CORS_HEADERS` 已删 — 决策-42 起
//!     `cors::normal_cors_lines` 按请求 Origin + env 配置动态生成
//!     (Starlette CORSMiddleware 对齐; 无 Origin 不带任何 CORS 头)
//!
//! 纯函数、零 IO; 发送动作 (send_all) 由 I/O 层负责。
//!
//! 与 C 的差异 (仅内部表达, 语义等价):
//! 设计要点: 头终止符为单 `\r\n` (CORS/extra 各行末位已带 `\r\n`, 再加
//! 一个即 `\r\n\r\n` 空行), 与 C `snprintf` 格式串字节等价。
//!
//!   - `json_escape_cstr` 返回 `Vec<u8>` (可含非 UTF-8 字节, 与 C 一致:
//!     非控制字节原样拷贝), 无 out_size 截断 — C 仅在缓冲不足时返回 -1,
//!     实际调用点均预留充足缓冲。
//!   - 响应头统一由 `build_response_headers` 装配, keep-alive 由调用方
//!     决定 (C 中读全局 `g_close_after_response`)。

use super::cors;
use super::request;

/// 扩展名 -> MIME 表 (端口 C `get_content_type`)。
/// 无扩展名 / 未识别扩展名返回 `application/octet-stream`。
pub fn get_content_type(path: &str) -> &'static str {
    let ext = match path.rfind('.') {
        Some(i) => &path[i..],
        None => return "application/octet-stream",
    };
    match ext {
        ".html" | ".htm" => "text/html",
        ".css" => "text/css",
        ".js" => "application/javascript",
        ".json" => "application/json",
        ".png" => "image/png",
        ".jpg" | ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".svg" => "image/svg+xml",
        ".ico" => "image/x-icon",
        ".txt" => "text/plain",
        ".xml" => "application/xml",
        ".pdf" => "application/pdf",
        ".woff" => "font/woff",
        ".woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

/// 组装完整响应头 (状态行 + 通用头 + CORS + 可选 extra 行 + 空行)。
/// 端口 C `send_response` 的 header 装配部分 (`extra` 为无尾 CRLF 的可选
/// 额外头行, 如 `Allow: GET, POST`; 空/None 不添加)。
pub fn build_response_headers(
    status: &str,
    content_type: &str,
    body_len: usize,
    keep_alive: bool,
    extra: Option<&str>,
) -> Vec<u8> {
    let ex = extra.unwrap_or("");
    let conn = if keep_alive { "keep-alive" } else { "close" };
    let mut s = String::with_capacity(96 + status.len() + content_type.len() + ex.len());
    s.push_str("HTTP/1.1 ");
    s.push_str(status);
    s.push_str("\r\nContent-Type: ");
    s.push_str(content_type);
    s.push_str("\r\nContent-Length: ");
    s.push_str(&body_len.to_string());
    s.push_str("\r\nConnection: ");
    s.push_str(conn);
    s.push_str("\r\n");
    // 决策-42: 动态 CORS 行 (按请求 Origin + env 配置; 无 Origin → 0 行)
    for line in cors::normal_cors_lines(request::current_origin().as_deref()) {
        s.push_str(&line);
        s.push_str("\r\n");
    }
    s.push_str(ex);
    if ex.is_empty() {
        // 无 CORS/extra: 状态块末 \r\n 后补一个即构成空行 (\r\n\r\n).
        s.push_str("\r\n");
    } else {
        // 有 CORS/extra: 各行末 \r\n + 收尾 CRLF + 空行 CRLF.
        // 🔴 修复 (2026-09-04): 原实现只补一个 \r\n, extra 最后一行后无空行,
        // 导致 body 被接收方视为 header 延续 (Content-Length 已声明但 body 永不
        // "到达") — 实测 405/自定义头响应 header 到 body 不达 (curl 0/186 bytes).
        // 补齐空行后 header 终止符正确 (\r\n\r\n).
        s.push_str("\r\n");
        s.push_str("\r\n");
    }
    s.into_bytes()
}

/// OPTIONS 预检响应 (决策-42 动态版, FFI 签名不变).
/// 读 request 全局 (Origin/ACRM/ACHR) + cors config:
///   - 通过 → 204 + 动态 CORS 头 (Allow-Origin 回显/`*` / [Credentials] /
///     [Allow-Methods] / [Allow-Headers] / Max-Age); 裸 OPTIONS (无 Origin)
///     走通配超集 (C 端口既有行为, e2e 守护)
///   - origin 不允许 / ACRM 越界 / ACHR 越界 → 400 + JSON 错误体 (Starlette
///     `_build_pre_response` 400 语义)
pub fn build_preflight_response() -> Vec<u8> {
    let origin = request::current_origin();
    let (acrm, achr) = request::current_cors_request();
    let (status, lines, err) =
        cors::preflight_build(origin.as_deref(), acrm.as_deref(), achr.as_deref());
    let mut s = String::with_capacity(256);
    s.push_str("HTTP/1.1 ");
    s.push_str(status);
    s.push_str("\r\n");
    if err.is_some() {
        // 400: JSON 错误体 (与 send_error_json 同一 schema)
        let msg = err.unwrap_or("preflight rejected");
        let em = String::from_utf8_lossy(&json_escape(msg.as_bytes())).into_owned();
        let es = String::from_utf8_lossy(&json_escape(status.as_bytes())).into_owned();
        let b = format!("{{\"error\":\"{em}\",\"status\":\"{es}\"}}");
        s.push_str("Content-Type: application/json\r\n");
        s.push_str(&format!("Content-Length: {}\r\n", b.len()));
        s.push_str("Connection: close\r\n\r\n");
        s.push_str(&b);
        return s.into_bytes();
    }
    // 204
    for line in &lines {
        s.push_str(line);
        s.push_str("\r\n");
    }
    s.push_str("Content-Length: 0\r\n");
    s.push_str("Connection: close\r\n");
    s.push_str("\r\n");
    s.into_bytes()
}

/// JSON 字符串转义 (端口 C `json_escape_cstr`): 转义 `"` `\` 与 <0x20 控制
/// 符 (`\b \f \n \r \t` 用短转义, 其余控制符用 `\u00XX`); 非控制字节原样
/// 拷贝 (可含非 UTF-8 字节, 与 C 一致)。返回转义后的字节序列。
pub fn json_escape(in_bytes: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::with_capacity(in_bytes.len() + 16);
    for &b in in_bytes {
        match b {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            0x08 => out.extend_from_slice(b"\\b"),
            0x0C => out.extend_from_slice(b"\\f"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            c if c < 0x20 => {
                // \u00XX (小写 hex, 与 C snprintf("%04x") 一致)
                let hex = b"0123456789abcdef";
                out.extend_from_slice(&[b'\\', b'u', b'0', b'0', hex[(c >> 4) as usize], hex[(c & 0x0F) as usize]]);
            }
            c => out.push(c),
        }
    }
    out
}
