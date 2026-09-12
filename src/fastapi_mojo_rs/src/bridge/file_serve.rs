//! file_serve.rs — FileResponse **I/O 层**（决策-48, ADR-0023）：
//! stat/open/read/lseek + 响应头装配 + Range 分派（纯协议原语在
//! file_protocol.rs；FFI 包装在 ffi.rs）。
//!
//! 行为等价 starlette 1.6.0 `FileResponse`（probe 证据 ADR-0023 §1）：
//!   - 200/2xx 全量（Accept-Ranges/Content-Length/Last-Modified/ETag/
//!     [Content-Disposition]）；64KB 块读（上游 chunk_size）
//!   - 206 单段（Content-Range + 切片）/ 多段 multipart/byteranges
//!   - 400（4 条精确消息）/ 416（bytes */size，CL 0）/ 500（缺失/非普通
//!     文件，"Internal Server Error" 21B，均无文件头）
//!   - HEAD = 仅头无体（上游 0.141.1 HEAD→405 quirk；§3.5 文档化偏差）
//!   - GZip（决策-78 ADR-0053）：200 全量在可压时读全量 + gzip
//!     （CE/CL/Vary; 上游 GZipMiddleware 压缩 FileResponse；206/Range 跳过）
//!
//! 零第三方 crate。Range/If-Range 从 CurrentRequest 读（io.rs 记录）。

use std::os::raw::{c_char, c_int, c_long, c_void};

use super::cors;
use super::file_protocol::{
    apply_charset_rule, build_content_disposition, etag_from_mtime_size, fmt_rfc1123,
    generate_boundary, multipart_content_length, parse_range_header, RangeErr,
};
use super::request;
use super::response::get_content_type;
use super::send::send_all;
use super::state::get_static_dir;

const CHUNK_SIZE: usize = 64 * 1024;
const O_RDONLY: c_int = 0;
const SEEK_SET: c_int = 0;
const EINTR: c_int = 4;
const S_IFMT: u32 = 0o170000; // 0xF000（C: 00170000；勿 0o070000 — 少一位，REG 恒 false）
const S_IFREG: u32 = 0o100000;

extern "C" {
    fn stat(path: *const c_char, buf: *mut LinuxStat) -> c_int;
    fn open(path: *const c_char, flags: c_int, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn lseek(fd: c_int, offset: i64, whence: c_int) -> i64;
    fn read(fd: c_int, buf: *mut c_void, n: usize) -> isize;
    fn __errno_location() -> *mut c_int;
}

/// Linux x86_64 `struct stat`（**144B glibc 布局**，stat(2) 符号按
/// `sizeof(struct stat)` 整写 — 缓冲 < 144B = 栈 OOB 写！偏移：
/// mode@24 / rdev@40 / size@48 / blksize@56 / blocks@64 / atime@72(+8) /
/// mtime@88(+8) / ctime@104(+8) / unused@120(24B)；offset 由
/// file_serve_tests 守护，值经 C `stat()` 逐字段交叉验证）。
#[repr(C)]
#[allow(dead_code)]
pub struct LinuxStat {
    pub(crate) st_dev: u64,
    pub(crate) st_ino: u64,
    pub(crate) st_nlink: u64,
    pub(crate) st_mode: u32,
    pub(crate) st_uid: u32,
    pub(crate) st_gid: u32,
    pub(crate) __pad0: i32,
    pub(crate) st_rdev: u64,
    pub(crate) st_size: i64,
    pub(crate) st_blksize: i64,
    pub(crate) st_blocks: i64,
    pub(crate) st_atime: i64,
    pub(crate) st_atime_nsec: i64,
    pub(crate) st_mtime: i64,
    pub(crate) st_mtime_nsec: i64,
    pub(crate) st_ctime: i64,
    pub(crate) st_ctime_nsec: i64,
    pub(crate) __unused: [u64; 3],
}

fn errno() -> c_int {
    unsafe { *__errno_location() }
}

fn stat_file(path: &str) -> Option<(i64, f64, bool)> {
    let cpath = std::ffi::CString::new(path).ok()?;
    let mut st: LinuxStat = unsafe { std::mem::zeroed() };
    if unsafe { stat(cpath.as_ptr(), &mut st) } < 0 {
        return None;
    }
    let is_reg = (st.st_mode & S_IFMT) == S_IFREG;
    let mtime = st.st_mtime as f64 + st.st_mtime_nsec as f64 * 1e-9;
    Some((st.st_size, mtime, is_reg))
}

fn send_fd(fd: c_int, buf: &[u8]) -> bool {
    send_all(fd, buf) == 0
}

/// [start, start+len) 字节区间 64KB 块流式直发（上游 chunk_size 一致）。
fn write_file_range(fd: c_int, ffd: c_int, start: i64, len: i64) -> bool {
    if len <= 0 {
        return true;
    }
    if unsafe { lseek(ffd, start, SEEK_SET) } < 0 {
        return false;
    }
    let mut remaining = len;
    let mut buf = vec![0u8; CHUNK_SIZE];
    while remaining > 0 {
        let n = unsafe {
            read(
                ffd,
                buf.as_mut_ptr() as *mut c_void,
                (remaining as usize).min(buf.len()),
            )
        };
        if n < 0 {
            if errno() == EINTR {
                continue;
            }
            return false;
        }
        if n == 0 || !send_fd(fd, &buf[..n as usize]) {
            return false;
        }
        remaining -= n as i64;
    }
    true
}

fn keep_alive_line() -> &'static str {
    if request::get_close_after_response() {
        "close"
    } else {
        "keep-alive"
    }
}

/// 文件响应公共头块（200/206/多段共用）：Content-Type / Accept-Ranges /
/// Content-Length / Last-Modified / ETag / [Content-Range] /
/// [Content-Disposition] / Connection / CORS / extra / 空行。
#[allow(clippy::too_many_arguments)] // FFI 对齐 C bridge 参数面（8 头字段槽位）
fn file_header_block(
    status: &str,
    ct: &str,
    content_length: i64,
    last_modified: &str,
    etag: &str,
    content_range: Option<&str>,
    cd: Option<&str>,
    extra: &str,
) -> String {
    let mut h = String::with_capacity(380 + extra.len() + ct.len());
    h.push_str(&format!("HTTP/1.1 {status}\r\n"));
    h.push_str(&format!("Content-Type: {ct}\r\n"));
    h.push_str("Accept-Ranges: bytes\r\n");
    h.push_str(&format!("Content-Length: {content_length}\r\n"));
    h.push_str(&format!("Last-Modified: {last_modified}\r\n"));
    h.push_str(&format!("ETag: {etag}\r\n"));
    if let Some(cr) = content_range {
        h.push_str(&format!("Content-Range: {cr}\r\n"));
    }
    if let Some(cd) = cd {
        h.push_str(&format!("Content-Disposition: {cd}\r\n"));
    }
    h.push_str(&format!("Connection: {}\r\n", keep_alive_line()));
    for line in cors::normal_cors_lines(request::current_origin().as_deref()) {
        h.push_str(&line);
        h.push_str("\r\n");
    }
    if !extra.is_empty() {
        h.push_str(extra);
        h.push_str("\r\n");
    }
    h.push_str("\r\n");
    h
}

/// 400/416/500 文本响应（全新 PlainTextResponse / uvicorn ServerErrorResponse
/// parity：**无文件头**，p10c MF*/NS1 + p10f 实测）。
fn send_plain_error(
    fd: c_int,
    status: &str,
    body: &str,
    content_range: Option<&str>,
    extra: &str,
) -> c_long {
    let mut h = String::with_capacity(220 + body.len() + extra.len());
    h.push_str(&format!("HTTP/1.1 {status}\r\n"));
    h.push_str("Content-Type: text/plain; charset=utf-8\r\n");
    h.push_str(&format!("Content-Length: {}\r\n", body.len()));
    if let Some(cr) = content_range {
        h.push_str(&format!("Content-Range: {cr}\r\n"));
    }
    h.push_str(&format!("Connection: {}\r\n", keep_alive_line()));
    for line in cors::normal_cors_lines(request::current_origin().as_deref()) {
        h.push_str(&line);
        h.push_str("\r\n");
    }
    if !extra.is_empty() {
        h.push_str(extra);
        h.push_str("\r\n");
    }
    h.push_str("\r\n");
    request::set_last_status(status.as_bytes());
    let ok = send_fd(fd, h.as_bytes()) && send_fd(fd, body.as_bytes());
    if ok { 0 } else { -1 }
}

/// **FileResponse 单点发送**（KIND_FILE FFI 入口，决策-48）。
/// `path` = 相对静态目录（bridge 拼 `static_dir/`）或绝对路径；`media_type`
/// 空 = guess(filename or path)（fallback octet-stream）+ charset 规则；
/// `filename` 非空 → Content-Disposition（`cdt` 空 = attachment）；
/// `status` = "200 OK"/"201 Created"…；`extra` = "\r\n" 分隔头行（不得含
/// Content-Type/ETag 语义头 — ADR-0023 §3.5）。0 = 成功，-1 = 写失败。
pub fn send_file_response(
    fd: c_int,
    path: &str,
    media_type: &str,
    filename: &str,
    cdt: &str,
    status: &str,
    extra: &str,
) -> c_long {
    let full = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("{}/{}", get_static_dir(), path)
    };

    let (size, mtime, is_reg) = match stat_file(&full) {
        Some(t) => t,
        None => {
            eprintln!("[file] 500: File at path {full} does not exist");
            return send_plain_error(
                fd,
                "500 Internal Server Error",
                "Internal Server Error",
                None,
                extra,
            );
        }
    };
    if !is_reg {
        eprintln!("[file] 500: File at path {full} is not a file");
        return send_plain_error(
            fd,
            "500 Internal Server Error",
            "Internal Server Error",
            None,
            extra,
        );
    }
    let cpath = match std::ffi::CString::new(full.as_bytes()) {
        Ok(c) => c,
        Err(_) => {
            return send_plain_error(
                fd,
                "500 Internal Server Error",
                "Internal Server Error",
                None,
                extra,
            );
        }
    };
    let ffd = unsafe { open(cpath.as_ptr(), O_RDONLY) };
    if ffd < 0 {
        return send_plain_error(
            fd,
            "500 Internal Server Error",
            "Internal Server Error",
            None,
            extra,
        );
    }

    // content-type（guess 源 = filename or path 基名；+ charset 规则）
    let guess_src = if !filename.is_empty() {
        filename.to_string()
    } else {
        full.rsplit('/').next().unwrap_or(&full).to_string()
    };
    let ct_base = if media_type.is_empty() {
        get_content_type(&guess_src)
    } else {
        media_type
    };
    let ct = apply_charset_rule(ct_base);
    let etag = etag_from_mtime_size(mtime, size);
    let last_modified = fmt_rfc1123(mtime.trunc() as i64);
    let cdt_used = if cdt.is_empty() { "attachment" } else { cdt };
    let cd = build_content_disposition(filename, cdt_used);
    let is_head = request::current_method_is_head();

    let range = request::current_range();
    let if_range = request::current_if_range();
    let use_range =
        range.is_some() && if_range.as_ref().is_none_or(|ir| ir == &last_modified || ir == &etag);

    let result = if !use_range {
        send_full(fd, ffd, status, &ct, size, &last_modified, &etag, cd.as_deref(), extra, is_head)
    } else {
        match parse_range_header(range.as_deref().unwrap_or(""), size) {
            Err(RangeErr::Malformed(msg)) => {
                send_plain_error(fd, "400 Bad Request", &msg, None, extra)
            }
            Err(RangeErr::Unsatisfiable(sz)) => send_plain_error(
                fd,
                "416 Range Not Satisfiable",
                "",
                Some(&format!("bytes */{sz}")),
                extra,
            ),
            Ok(ref ranges) if ranges.is_empty() => {
                // 101+ 段 quirk → 200 全量（p10c MF10）
                send_full(
                    fd,
                    ffd,
                    status,
                    &ct,
                    size,
                    &last_modified,
                    &etag,
                    cd.as_deref(),
                    extra,
                    is_head,
                )
            }
            Ok(ref ranges) if ranges.len() == 1 => {
                let (s, e) = ranges[0];
                request::set_last_status(b"206 Partial Content");
                let cr = format!("bytes {s}-{}/{size}", e - 1);
                let h = file_header_block(
                    "206 Partial Content",
                    &ct,
                    e - s,
                    &last_modified,
                    &etag,
                    Some(&cr),
                    cd.as_deref(),
                    extra,
                );
                if send_fd(fd, h.as_bytes()) && (is_head || write_file_range(fd, ffd, s, e - s)) {
                    0
                } else {
                    -1
                }
            }
            Ok(ranges) => {
                let boundary = generate_boundary(fd, size);
                let cl = multipart_content_length(&ranges, boundary.len(), &ct, size);
                request::set_last_status(b"206 Partial Content");
                let ct_mp = format!("multipart/byteranges; boundary={boundary}");
                let h = file_header_block(
                    "206 Partial Content",
                    &ct_mp,
                    cl,
                    &last_modified,
                    &etag,
                    None,
                    cd.as_deref(),
                    extra,
                );
                if !send_fd(fd, h.as_bytes()) {
                    -1
                } else if is_head {
                    0
                } else {
                    let mut ok = true;
                    for (s, e) in &ranges {
                        let part_h = format!(
                            "--{boundary}\r\nContent-Type: {ct}\r\nContent-Range: bytes {s}-{}/{size}\r\n\r\n",
                            e - 1
                        );
                        if !send_fd(fd, part_h.as_bytes())
                            || !write_file_range(fd, ffd, *s, e - s)
                            || !send_fd(fd, b"\r\n")
                        {
                            ok = false;
                            break;
                        }
                    }
                    if ok {
                        ok = send_fd(fd, format!("--{boundary}--").as_bytes());
                    }
                    if ok {
                        0
                    } else {
                        -1
                    }
                }
            }
        }
    };

    unsafe { close(ffd) };
    result
}

/// 200/2xx 全量发送（含 101+ 段退化路径）。
#[allow(clippy::too_many_arguments)] // FFI 对齐 C bridge 参数面
fn send_full(
    fd: c_int,
    ffd: c_int,
    status: &str,
    ct: &str,
    size: i64,
    last_modified: &str,
    etag: &str,
    cd: Option<&str>,
    extra: &str,
    is_head: bool,
) -> c_long {
    // 决策-78 (ADR-0053): FileResponse gzip（上游 GZipMiddleware 压缩 FileResponse；
    // 206/Range 走别径跳过）。可压 -> 读全量 + gzip（CL = 压缩后长度）; 不可压 -> 原样流式。
    let gz_cfg = super::gzip::config();
    let gz_plan = super::gzip::plan(
        &gz_cfg,
        ct,
        size as usize,
        status,
        if extra.is_empty() { None } else { Some(extra) },
        request::current_accepts_gzip(),
        !is_head,
        false,
    );
    let mut gz_body: Option<Vec<u8>> = None;
    if gz_plan.compress {
        if let Some(raw) = read_all(ffd, size) {
            gz_body = super::gzip::gzip_compress(&raw, gz_cfg.level);
        }
    }
    let extra_final = super::gzip::merge_extra(extra, gz_plan.vary, gz_body.is_some());
    let cl = match &gz_body {
        Some(g) => g.len() as i64,
        None => size,
    };
    request::set_last_status(status.as_bytes());
    let h = file_header_block(status, ct, cl, last_modified, etag, None, cd, &extra_final);
    if !send_fd(fd, h.as_bytes()) {
        return -1;
    }
    if is_head {
        return 0;
    }
    match &gz_body {
        Some(g) => {
            if !send_fd(fd, g) {
                return -1;
            }
        }
        None => {
            if !write_file_range(fd, ffd, 0, size) {
                return -1;
            }
        }
    }
    0
}

/// 读文件全量（gzip 用; 失败/超界 -> None）。上限 4 MiB（防御）。
fn read_all(ffd: c_int, size: i64) -> Option<Vec<u8>> {
    const READ_ALL_MAX: i64 = 4 * 1024 * 1024;
    if !(0..=READ_ALL_MAX).contains(&size) {
        return None;
    }
    if unsafe { lseek(ffd, 0, SEEK_SET) } < 0 {
        return None;
    }
    let mut out = vec![0u8; size as usize];
    let mut got = 0usize;
    while got < out.len() {
        let n = unsafe { read(ffd, out[got..].as_mut_ptr() as *mut c_void, out.len() - got) };
        if n < 0 {
            if errno() == EINTR {
                continue;
            }
            return None;
        }
        if n == 0 {
            break;
        }
        got += n as usize;
    }
    out.truncate(got);
    Some(out)
}
// temporary probe - appended to file_serve.rs as test
