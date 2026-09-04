//! state.rs — 全局状态 + 简单的 setter / getter / env 配置 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c`:
//!   - timeout globals + env 解析 (§500-516: g_recv_timeout_ms / g_idle_max_ms
//!     / g_max_request_ms + FASTAPI_MOJO_*_TIMEOUT env)
//!   - max body size (§236-237: set_max_body_size)
//!   - static dir (§210-228: set_static_dir 含 env 覆盖 + embedded 兜底)
//!   - embedded static dir (§204-207: set_embedded_static_dir)
//!   - last status (§1421-1426: get_last_status_len / read_last_status_byte)
//!
//! 不包括 conn 状态机的 globals (g_method/g_path/g_query/g_active_conn),
//! 它们与外层 `recv_and_parse` 紧耦合, 等 conn state machine 端口一并迁移.
//!
//! 与 C 的差异:
//!   - `Mutex<[u8; N]>` 替代 raw char[] 全局 (单线程访问假定下零开销),
//!     保证内存安全 + 杜绝 buffer overrun; `AtomicI32` / `AtomicI64` 替代
//!     volatile int/long
//!   - 所有 setter 接受 `&str` / `Option<&str>` 取代 `const char*` + 长度;
//!     C 内部 strncpy + 强制 NUL 终止的语义在 Rust 端由 `.copy_from_slice`
//!     + 末尾置 0 保证
//!   - env 解析走 `std::env::var`, 不引入 libc
//!
//! FFI 包装延迟: 同 `signals.rs`, 待 `bridge.o` 下线时统一加 `extern "C"`.

use std::os::raw::c_int;
use std::sync::atomic::{AtomicI32, AtomicI64, Ordering};
use std::sync::Mutex;

// ========== 常量 ==========
pub const MAX_STATIC_DIR: usize = 256;
pub const MAX_BODY: usize = 1024 * 1024;
pub const DEFAULT_MAX_BODY_SIZE: i32 = 1024 * 1024;
pub const DEFAULT_RECV_TIMEOUT_MS: i32 = 5000;
pub const DEFAULT_IDLE_MAX_MS: i64 = 60_000;
pub const DEFAULT_MAX_REQUEST_MS: i64 = 30_000;
pub const MAX_LAST_STATUS: usize = 32;

// ========== 数字全局 (Atomic, Relaxed 即可: 单线程访问假定) ==========
static G_MAX_BODY_SIZE: AtomicI32 = AtomicI32::new(DEFAULT_MAX_BODY_SIZE);
static G_RECV_TIMEOUT_MS: AtomicI32 = AtomicI32::new(DEFAULT_RECV_TIMEOUT_MS);
static G_IDLE_MAX_MS: AtomicI64 = AtomicI64::new(DEFAULT_IDLE_MAX_MS);
static G_MAX_REQUEST_MS: AtomicI64 = AtomicI64::new(DEFAULT_MAX_REQUEST_MS);

// ========== 字符串全局 (Mutex<[u8; N]>, NUL 终止) ==========
static G_STATIC_DIR: Mutex<[u8; MAX_STATIC_DIR]> = Mutex::new(const_init_dir());
static G_EMBEDDED_STATIC_DIR: Mutex<[u8; MAX_STATIC_DIR]> = Mutex::new([0u8; MAX_STATIC_DIR]);
static G_LAST_STATUS: Mutex<[u8; MAX_LAST_STATUS]> = Mutex::new([0u8; MAX_LAST_STATUS]);

const fn const_init_dir() -> [u8; MAX_STATIC_DIR] {
    // "./static" 字节: . / s t a t i c  (8 字节) + 248 个 NUL
    let mut a = [0u8; MAX_STATIC_DIR];
    let s = b"./static";
    let mut i = 0;
    while i < s.len() {
        a[i] = s[i];
        i += 1;
    }
    a
}

// ========== setter / getter: max body size ==========

pub fn set_max_body_size(size: usize) {
    if size > 0 && size <= MAX_BODY {
        G_MAX_BODY_SIZE.store(size as i32, Ordering::Relaxed);
    }
}

pub fn get_max_body_size() -> i32 {
    G_MAX_BODY_SIZE.load(Ordering::Relaxed)
}

// ========== setter / getter: timeouts ==========

/// 读取 env (FASTAPI_MOJO_RECV_TIMEOUT / IDLE_TIMEOUT / MAX_REQUEST, 单位秒,
/// 合法范围 1..=3600) 写入 G_RECV_TIMEOUT_MS / G_IDLE_MAX_MS / G_MAX_REQUEST_MS.
/// 端口 C `init_recv_timeout()` (§496-516).
pub fn init_timeouts_from_env() {
    if let Ok(v) = std::env::var("FASTAPI_MOJO_RECV_TIMEOUT") {
        if let Ok(n) = v.parse::<i64>() {
            if (1..=3600).contains(&n) {
                G_RECV_TIMEOUT_MS.store((n * 1000) as i32, Ordering::Relaxed);
            }
        }
    }
    if let Ok(v) = std::env::var("FASTAPI_MOJO_IDLE_TIMEOUT") {
        if let Ok(n) = v.parse::<i64>() {
            if (1..=3600).contains(&n) {
                G_IDLE_MAX_MS.store(n * 1000, Ordering::Relaxed);
            }
        }
    }
    if let Ok(v) = std::env::var("FASTAPI_MOJO_MAX_REQUEST") {
        if let Ok(n) = v.parse::<i64>() {
            if (1..=3600).contains(&n) {
                G_MAX_REQUEST_MS.store(n * 1000, Ordering::Relaxed);
            }
        }
    }
}

pub fn get_recv_timeout_ms() -> i32 {
    G_RECV_TIMEOUT_MS.load(Ordering::Relaxed)
}
pub fn get_idle_max_ms() -> i64 {
    G_IDLE_MAX_MS.load(Ordering::Relaxed)
}
pub fn get_max_request_ms() -> i64 {
    G_MAX_REQUEST_MS.load(Ordering::Relaxed)
}

// ========== setter / getter: static / embedded static dir ==========

fn copy_cstr_into(buf: &mut [u8], s: &str) {
    // 等价 C: strncpy(buf, s, sizeof-1); buf[sizeof-1] = 0;
    let bytes = s.as_bytes();
    let n = bytes.len().min(buf.len() - 1);
    buf[..n].copy_from_slice(&bytes[..n]);
    buf[n..].iter_mut().for_each(|b| *b = 0);
    debug_assert_eq!(buf[n], 0);
}

/// 端口 C `set_embedded_static_dir` (§204-207). 空串或 None 跳过.
pub fn set_embedded_static_dir(dir: Option<&str>) {
    let Some(d) = dir else { return };
    if d.is_empty() {
        return;
    }
    let mut g = G_EMBEDDED_STATIC_DIR.lock().expect("G_EMBEDDED_STATIC_DIR poisoned");
    copy_cstr_into(&mut *g, d);
}

/// 端口 C `set_static_dir` (§210-228).
/// 解析优先级:
///   1) FASTAPI_MOJO_STATIC_DIR env (覆盖)
///   2) 传入 dir (CWD 相对 ./static 等开发模式)
///   3) embedded dir (单 binary 模式下 shim 暂存的静态资源)
///   4) 传入 dir 原样保留 (旧行为: 后续 404)
pub fn set_static_dir(dir: Option<&str>) {
    let env = std::env::var("FASTAPI_MOJO_STATIC_DIR").ok();
    let mut chosen: Option<String> = None;

    if let Some(e) = env.filter(|s| !s.is_empty()) {
        chosen = Some(e);
    } else if let Some(d) = dir.filter(|s| !s.is_empty()) {
        // 检查 CWD 目录是否存在; 不存在且 embedded dir 存在 -> 用 embedded
        let cwd_exists = std::path::Path::new(d).is_dir();
        if !cwd_exists {
            let embedded = get_embedded_static_dir();
            if !embedded.is_empty() && std::path::Path::new(&embedded).is_dir() {
                chosen = Some(embedded);
            } else {
                chosen = Some(d.to_string());
            }
        } else {
            chosen = Some(d.to_string());
        }
    }

    if let Some(c) = chosen {
        let mut g = G_STATIC_DIR.lock().expect("G_STATIC_DIR poisoned");
        copy_cstr_into(&mut *g, &c);
    }
}

pub fn get_static_dir() -> String {
    let g = G_STATIC_DIR.lock().expect("G_STATIC_DIR poisoned");
    cstr_from(&*g)
}

pub fn get_embedded_static_dir() -> String {
    let g = G_EMBEDDED_STATIC_DIR.lock().expect("G_EMBEDDED_STATIC_DIR poisoned");
    cstr_from(&*g)
}

fn cstr_from(buf: &[u8]) -> String {
    let n = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..n]).into_owned()
}

// ========== last status (用于静态文件响应的真实 status 反馈) ==========

pub fn set_last_status(status: &str) {
    let mut g = G_LAST_STATUS.lock().expect("G_LAST_STATUS poisoned");
    copy_cstr_into(&mut *g, status);
}

pub fn get_last_status_len() -> usize {
    let g = G_LAST_STATUS.lock().expect("G_LAST_STATUS poisoned");
    g.iter().position(|&b| b == 0).unwrap_or(g.len())
}

pub fn read_last_status_byte(i: usize) -> i32 {
    let g = G_LAST_STATUS.lock().expect("G_LAST_STATUS poisoned");
    let n = g.iter().position(|&b| b == 0).unwrap_or(g.len());
    if i < n {
        g[i] as i32
    } else {
        -1
    }
}

// ========== 测试辅助: 重置 (#[cfg(test)] pub(crate)) ==========

#[cfg(test)]
pub(crate) fn reset_for_test() {
    G_MAX_BODY_SIZE.store(DEFAULT_MAX_BODY_SIZE, Ordering::Relaxed);
    G_RECV_TIMEOUT_MS.store(DEFAULT_RECV_TIMEOUT_MS, Ordering::Relaxed);
    G_IDLE_MAX_MS.store(DEFAULT_IDLE_MAX_MS, Ordering::Relaxed);
    G_MAX_REQUEST_MS.store(DEFAULT_MAX_REQUEST_MS, Ordering::Relaxed);
    *G_STATIC_DIR.lock().unwrap() = const_init_dir();
    *G_EMBEDDED_STATIC_DIR.lock().unwrap() = [0u8; MAX_STATIC_DIR];
    *G_LAST_STATUS.lock().unwrap() = [0u8; MAX_LAST_STATUS];
}

/// F7: access log 模式. 0 = text (默认), 1 = JSON.
/// env 一次性读取 + OnceLock 缓存 (与现有 init_timeouts_from_env 一致模式).
pub fn get_access_log_mode() -> c_int {
    use std::sync::OnceLock;
    static MODE: OnceLock<c_int> = OnceLock::new();
    *MODE.get_or_init(|| {
        match std::env::var("FASTAPI_MOJO_ACCESS_LOG") {
            Ok(v) if v.eq_ignore_ascii_case("json") => 1,
            _ => 0,
        }
    })
}
