//! middleware.rs — 用户自定义中间件: 响应面 (决策-55, ADR-0030).
//!
//! 上游 `@app.middleware("http")` / `BaseHTTPMiddleware` 的声明式 env 等价
//! (Mojo 1.0.0 无闭包 — ADR-0004 声明式世界观; 决策-40/42/49 先例):
//!
//!   `FASTAPI_MOJO_MIDDLEWARE="<mw1>;<mw2>;...;<mwN>"`
//!   `<mwK>` = `<verb1>,<verb2>,...` (书写序 = 执行序)
//!   `<verb>` = `NAME[:A[:B[:C]]]`
//!
//! 栈序 (上游活体探测 P-MW-1/2, fastapi 0.141.1): mw1 = 先添加 = innermost,
//! mwN = 后添加 = outermost. 请求面 (MAP/REQHDR/BLOCK) 由 Mojo 侧 dispatch
//! 前应用 (outermost→innermost, mw_spec.mojo); **响应面** (HDR/STATUS/BODY/
//! LOG) 在本模块, `send_response` 单点、GZip 判定前 (用户 mw 位于固定
//! GZip/CORS env 层之内, ADR-0030 §3.5):
//!   - 执行序 = innermost→outermost = **env 正序**;
//!   - HDR 同名行原位替换, 后写胜 (P-MW-2);
//!   - BODY 替换 body + **重算 Content-Length** — 上游 stale-CL → h11
//!     `LocalProtocolError: Too little data for declared Content-Length`
//!     (P-MW-5 实测), 文档化优于上游;
//!   - LOG = 发送成功后打印一行 `[mw] <req_id> <METHOD> <path>[?<q>] -> <status>`.
//!
//! 零第三方 crate; ldd 仅 libc (纯 std 字节/字符串操作).

use std::sync::OnceLock;

/// 解析后的中间件栈 (env 序: index 0 = mw1 = innermost ... 末位 = outermost).
#[derive(Default)]
pub struct MwStack {
    pub mws: Vec<Mw>,
}

/// 一个中间件单元.
#[derive(Default)]
pub struct Mw {
    /// 请求面动词 (书写序) — Mojo 侧应用 (mw_spec.mojo).
    pub req: Vec<MwVerb>,
    /// 响应面动词 (书写序) — 本模块应用.
    pub resp: Vec<MwVerb>,
}

/// 全部动词 (请求面 + 响应面; 解析时归类到 Mw.req / Mw.resp).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MwVerb {
    /// `MAP:FROM:TO` (请求): 路径重写 (P-MW-7 `scope["path"]` 等价).
    Map { from: String, to: String },
    /// `REQHDR:NAME:VALUE` (请求): 合成请求头注入.
    ReqHdr { name: String, value: String },
    /// `BLOCK:STATUS:BODY:PATHS` (请求): 早期响应 / 短路 (P-MW-3).
    Block { status: String, body: String, paths: Vec<String> },
    /// `HDR:NAME:VALUE` (响应): 设/追加响应头 (后写胜, P-MW-2).
    Hdr { name: String, value: String },
    /// `STATUS:FROM:TO` (响应): 状态重设 (P-MW-4).
    Status { from: String, to: String },
    /// `BODY:TEMPLATE` (响应): 换 body (插值 + 重算 CL).
    Body { template: String },
    /// `LOG` (响应): 发送后打印 `[mw]` 行.
    Log,
}

fn is_code3(s: &str) -> bool {
    s.len() == 3 && s.bytes().all(|b| b.is_ascii_digit())
}

fn is_code_or_star(s: &str) -> bool {
    s == "*" || is_code3(s)
}

/// 值内禁止结构性分隔符 `;` `,` `:` `|` (含 = 歧义, 解析期 fail-fast).
fn check_value(s: &str) -> Result<(), String> {
    if s.bytes().any(|b| matches!(b, b';' | b',' | b':' | b'|')) {
        return Err(format!(
            "middleware: value '{}' contains a reserved separator (; , : |)",
            s
        ));
    }
    Ok(())
}

fn fields_of(v: &str, want: usize) -> Result<Vec<&str>, String> {
    let fs: Vec<&str> = v.split(':').map(|s| s.trim()).collect();
    if fs.len() != want {
        return Err(format!(
            "middleware: verb '{}' expects {} ':'-fields, got {}",
            v,
            want,
            fs.len()
        ));
    }
    Ok(fs)
}

fn parse_verb(v: &str) -> Result<MwVerb, String> {
    if v.is_empty() {
        return Err("middleware: empty verb entry".into());
    }
    let fs: Vec<&str> = v.split(':').collect();
    let name = fs[0].trim().to_ascii_uppercase();
    match name.as_str() {
        "LOG" => {
            if fs.len() != 1 {
                return Err(format!("middleware: LOG takes no arguments (got '{}')", v));
            }
            Ok(MwVerb::Log)
        }
        "HDR" => {
            let f = fields_of(v, 3)?;
            if f[1].is_empty() {
                return Err(format!("middleware: HDR needs a non-empty name: '{}'", v));
            }
            check_value(f[2])?;
            Ok(MwVerb::Hdr { name: f[1].to_string(), value: f[2].to_string() })
        }
        "STATUS" => {
            let f = fields_of(v, 3)?;
            if !is_code_or_star(f[1]) || !is_code3(f[2]) {
                return Err(format!(
                    "middleware: STATUS:FROM:TO needs 3-digit codes (FROM may be '*'): '{}'",
                    v
                ));
            }
            Ok(MwVerb::Status { from: f[1].to_string(), to: f[2].to_string() })
        }
        "BODY" => {
            let f = fields_of(v, 2)?;
            if f[1].is_empty() {
                return Err(format!("middleware: BODY needs a non-empty template: '{}'", v));
            }
            check_value(f[1])?;
            Ok(MwVerb::Body { template: f[1].to_string() })
        }
        "MAP" => {
            let f = fields_of(v, 3)?;
            if !f[1].starts_with('/') || f[1] == "/" || !f[2].starts_with('/') {
                return Err(format!(
                    "middleware: MAP:FROM:TO needs absolute paths (FROM != '/'): '{}'",
                    v
                ));
            }
            check_value(f[1])?;
            check_value(f[2])?;
            Ok(MwVerb::Map { from: f[1].to_string(), to: f[2].to_string() })
        }
        "REQHDR" => {
            let f = fields_of(v, 3)?;
            if f[1].is_empty() {
                return Err(format!("middleware: REQHDR needs a non-empty name: '{}'", v));
            }
            check_value(f[1])?;
            check_value(f[2])?;
            Ok(MwVerb::ReqHdr { name: f[1].to_string(), value: f[2].to_string() })
        }
        "BLOCK" => {
            let f = fields_of(v, 4)?;
            if !is_code3(f[1]) {
                return Err(format!("middleware: BLOCK needs a 3-digit status: '{}'", v));
            }
            if f[2].is_empty() {
                return Err(format!("middleware: BLOCK needs a non-empty body: '{}'", v));
            }
            check_value(f[2])?;
            let paths: Vec<String> = f[3]
                .split('|')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            if paths.is_empty() {
                return Err(format!(
                    "middleware: BLOCK needs at least one path (or '*'): '{}'",
                    v
                ));
            }
            for p in &paths {
                if p != "*" && !p.starts_with('/') {
                    return Err(format!(
                        "middleware: BLOCK path '{}' must be '*' or absolute",
                        p
                    ));
                }
            }
            Ok(MwVerb::Block { status: f[1].to_string(), body: f[2].to_string(), paths })
        }
        _ => Err(format!("middleware: unknown verb '{}'", fs[0])),
    }
}

/// 解析 spec (env 原串). None/空/空白 = 零中间件. **错误 → 空栈**
/// (bridge 侧防御: 权威校验 = Mojo 启动期 `check_mw_spec` fail-fast,
/// 畸形 spec 的服务根本起不来; 此处仅防运行期漂移).
pub fn parse_spec(raw: Option<&str>) -> MwStack {
    let mut st = MwStack::default();
    let Some(s) = raw else { return st };
    let t = s.trim();
    if t.is_empty() {
        return st;
    }
    for mw_s in t.split(';') {
        let mt = mw_s.trim();
        if mt.is_empty() {
            continue;
        }
        let mut mw = Mw::default();
        for v in mt.split(',') {
            let vt = v.trim();
            if vt.is_empty() {
                continue;
            }
            match parse_verb(vt) {
                Ok(vb) => match vb {
                    MwVerb::Map { .. } | MwVerb::ReqHdr { .. } | MwVerb::Block { .. } => {
                        mw.req.push(vb)
                    }
                    _ => mw.resp.push(vb),
                },
                Err(e) => {
                    eprintln!("[mw] spec error (bridge side ignores; Mojo startup check is authoritative): {e}");
                    return MwStack::default();
                }
            }
        }
        if mw.req.is_empty() && mw.resp.is_empty() {
            continue;
        }
        st.mws.push(mw);
    }
    st
}

/// env 一次性读取 (GZip/access-log 先例: OnceLock).
pub fn cached_stack() -> &'static MwStack {
    static ST: OnceLock<MwStack> = OnceLock::new();
    ST.get_or_init(|| parse_spec(std::env::var("FASTAPI_MOJO_MIDDLEWARE").ok().as_deref()))
}

/// 标准 status 名 (小表; 未知码 → "Unknown").
pub fn status_name(code: &str) -> &'static str {
    match code {
        "200" => "OK",
        "201" => "Created",
        "202" => "Accepted",
        "204" => "No Content",
        "301" => "Moved Permanently",
        "302" => "Found",
        "304" => "Not Modified",
        "400" => "Bad Request",
        "401" => "Unauthorized",
        "403" => "Forbidden",
        "404" => "Not Found",
        "405" => "Method Not Allowed",
        "406" => "Not Acceptable",
        "409" => "Conflict",
        "415" => "Unsupported Media Type",
        "418" => "I'm a Teapot",
        "422" => "Unprocessable Entity",
        "429" => "Too Many Requests",
        "500" => "Internal Server Error",
        "501" => "Not Implemented",
        "503" => "Service Unavailable",
        _ => "Unknown",
    }
}

fn status_code(status: &str) -> &str {
    status.get(..3).unwrap_or("")
}

/// 插值 `{method} {path} {query} {status} {req_id}` (status = 3 位码);
/// 未知 `{...}` 保留字面 (house 约定, 决策-50 state 插值同款).
pub fn interpolate(t: &str, method: &str, path: &str, query: &str, status: &str, req_id: &str) -> String {
    t.replace("{method}", method)
        .replace("{path}", path)
        .replace("{query}", query)
        .replace("{status}", status)
        .replace("{req_id}", req_id)
}

/// 路径重写 (`MAP:FROM:TO`): path == FROM → TO; path 以 `FROM/` 起 →
/// TO(非 `/` 尾时补 `/`)+ 剩余段 (P-MW-7 `scope["path"]` 等价).
fn map_path(p: &str, from: &str, to: &str) -> String {
    if p == from {
        return to.to_string();
    }
    let prefix = format!("{from}/");
    if let Some(rest) = p.strip_prefix(prefix.as_str()) {
        if to.ends_with('/') {
            format!("{to}{rest}")
        } else {
            format!("{to}/{rest}")
        }
    } else {
        p.to_string()
    }
}

/// `BLOCK` PATHS 匹配: `*` = 全部; `prefix/` = 前缀; 其余精确.
fn block_match(path: &str, paths: &[String]) -> bool {
    for p in paths {
        if p == "*" {
            return true;
        }
        if p.ends_with('/') {
            if path.starts_with(p.as_str()) {
                return true;
            }
        } else if path == p {
            return true;
        }
    }
    false
}

/// 重放请求面计划 (镜像 Mojo `mw_plan_request`): outermost→innermost,
/// 先应用 `MAP` 路径重写, 再找首个命中的 `BLOCK`. 返回 (重写后 path,
/// blocker index or None) — 供 `apply_response_ctx` 短路判定
/// (ADR-0030 §3.2: BLOCK 于 mwK → 响应仅过 mwK+1..mwN 响应动词).
pub fn plan_request_path(stack: &MwStack, path: &str) -> (String, Option<usize>) {
    let n = stack.mws.len();
    let mut p = path.to_string();
    for idx in (0..n).rev() {
        for v in &stack.mws[idx].req {
            match v {
                MwVerb::Map { from, to } => {
                    p = map_path(&p, from, to);
                }
                MwVerb::Block { paths, .. }
                    if block_match(&p, paths) =>
                {
                    return (p, Some(idx));
                }
                _ => {}
            }
        }
    }
    (p, None)
}

/// 应用响应面动词 (纯 ctx 版 — 单测入口).
///
/// `status` = "CODE NAME"; `extra` = "\r\n" 分 "Name: value" 行 (无尾 CRLF,
/// 空 = 无); `body` = GZip 前原 body. 中间件按 env 序 (innermost→outermost)
/// 执行; 短路 (BLOCK 于 mwK) 时仅 mwK+1..mwN 响应动词应用. 返回 (status, body, extra, content_type, log): BODY 动词触发时
/// content_type = `text/plain; charset=utf-8` (非空; 否则空 = 调用方原值).
pub fn apply_response_ctx(
    stack: &MwStack,
    status: &str,
    body: &[u8],
    extra: Option<&str>,
    ctx: &super::request::ReqCtx,
) -> (String, Vec<u8>, String, String, bool) {
    if stack.mws.is_empty() {
        return (
            status.to_string(),
            body.to_vec(),
            extra.unwrap_or("").to_string(),
            String::new(),
            false,
        );
    }
    let (p2, block_idx) = plan_request_path(stack, &ctx.path);
    let mut st = status.to_string();
    let mut bd = body.to_vec();
    let mut ex = extra.unwrap_or("").to_string();
    let mut ct = String::new();
    let mut log = false;
    for (i, mw) in stack.mws.iter().enumerate() {
        if let Some(k) = block_idx {
            if i <= k {
                continue; // 短路: 跳过 blocker(mwK)自身及更内层的响应动词
            }
        }
        for v in &mw.resp {
            match v {
                MwVerb::Status { from, to } => {
                    if from == "*" || status_code(&st) == from {
                        st = format!("{to} {}", status_name(to));
                    }
                }
                MwVerb::Hdr { name, value } => {
                    let mut lines: Vec<String> = if ex.is_empty() {
                        Vec::new()
                    } else {
                        ex.split("\r\n").map(|s| s.to_string()).collect()
                    };
                    lines.retain(|l| !same_header_name(l, name));
                    lines.push(format!("{name}: {value}"));
                    ex = lines.join("\r\n");
                }
                MwVerb::Body { template } => {
                    let s = interpolate(template, &ctx.method, &p2, &ctx.query, status_code(&st), &ctx.req_id);
                    bd = s.into_bytes();
                    ct = "text/plain; charset=utf-8".to_string();
                }
                MwVerb::Log => log = true,
                _ => {}
            }
        }
    }
    (st, bd, ex, ct, log)
}

/// 生产入口: 全局 ctx (CurrentRequest method/path/query/req_id) + env 缓存栈.
pub fn apply_response(status: &str, body: &[u8], extra: Option<&str>) -> (String, Vec<u8>, String, String, bool) {
    let ctx = super::request::get_req_ctx();
    apply_response_ctx(cached_stack(), status, body, extra, &ctx)
}

/// `[mw]` 日志行 (纯 ctx 版 — 单测入口).
pub fn log_line_ctx(method: &str, path: &str, query: &str, req_id: &str, status: &str) -> String {
    let pathq = if query.is_empty() {
        path.to_string()
    } else {
        format!("{path}?{query}")
    };
    format!("[mw] {req_id} {method} {pathq} -> {status}")
}

/// 发送成功后打印 LOG 行 (生产入口).
pub fn log_line(status: &str) {
    let ctx = super::request::get_req_ctx();
    println!("{}", log_line_ctx(&ctx.method, &ctx.path, &ctx.query, &ctx.req_id, status));
}

/// "Name: value" 行的 name 是否 (CI) 等于给定 name.
fn same_header_name(line: &str, name: &str) -> bool {
    match line.split_once(':') {
        Some((n, _)) => n.trim().eq_ignore_ascii_case(name),
        None => false,
    }
}
