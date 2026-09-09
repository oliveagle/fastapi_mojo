//! bridge/gzip.rs — GZip 响应压缩（决策-40, ADR-0015, Goal-0003 P2 矩阵 #24）.
//!
//! FastAPI/Starlette `GZipMiddleware` 的**声明式 env 等价形态**（Mojo 无闭包/
//! 无中间件对象, 本项目的横切配置一律 env 声明 — lifespan/access-log 同模式）:
//!   - `FASTAPI_MOJO_GZIP=1`          启用（默认关 — FastAPI 默认不加 gzip）
//!   - `FASTAPI_MOJO_GZIP_MIN_SIZE`   压缩下限（默认 500, 对齐 Starlette）
//!   - `FASTAPI_MOJO_GZIP_MAX_SIZE`   压缩上限（默认 1 MiB, 内存保护,
//!     对齐 MAX_FILE_SIZE 静态文件上限）
//!
//! 语义（Starlette GZipMiddleware 对齐）:
//!   - 请求 `Accept-Encoding` 含裸 token gzip/x-gzip（不支持 q, 对齐上游 quirk）
//!   - 响应非 304、extra 未声明 Content-Encoding
//!   - body 非空且 `min_size <= len <= max_size`
//!
//! 满足全部 → body 换 gzip 字节, 响应头加 `Content-Encoding: gzip`
//! （Content-Type 不变, Content-Length 更新为压缩后长度）。
//!
//! flate2 = **纯 Rust miniz_oxide 后端**（默认 feature 无 zlib-ng/C 路径）,
//! 静态链接进 libfastapi_mojo_rs.a → ldd 仍仅 libc（North Star 不破）。
//! 压缩级别 `Compression::default()` = 6（Starlette 默认 compresslevel=6）。

use std::io::Write;
use std::sync::Mutex;

use flate2::{Compression, write::GzEncoder};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GzipConfig {
    pub enabled: bool,
    pub min_size: usize,
    pub max_size: usize,
}

fn env_usize(name: &str, default: usize) -> usize {
    match std::env::var(name) {
        Ok(v) => v.trim().parse().unwrap_or(default),
        Err(_) => default,
    }
}

fn env_bool(name: &str) -> bool {
    matches!(std::env::var(name).ok().as_deref(), Some("1" | "true" | "yes" | "on"))
}

/// 默认配置: 关, min 500 (Starlette), max 1 MiB.
pub fn default_config() -> GzipConfig {
    GzipConfig {
        enabled: env_bool("FASTAPI_MOJO_GZIP"),
        min_size: env_usize("FASTAPI_MOJO_GZIP_MIN_SIZE", 500),
        max_size: env_usize("FASTAPI_MOJO_GZIP_MAX_SIZE", 1024 * 1024),
    }
}

/// 进程级 config 缓存 (env 一次读取; Mutex 而非 OnceLock — 单线程 worker
/// 模型下无竞争, Mutex 额外允许 #[cfg(test)] 重置, 隔离 env 全局副作用,
/// 与 conn::reset_for_close 的 sys_close no-op 同一类测试隔离机制).
static CONFIG: Mutex<Option<GzipConfig>> = Mutex::new(None);

pub fn config() -> GzipConfig {
    let mut g = CONFIG.lock().unwrap_or_else(|e| e.into_inner());
    if g.is_none() {
        *g = Some(default_config());
    }
    g.expect("just set")
}

#[cfg(test)]
/// 测试钩子: 清 config 缓存 (配合 --test-threads=1 顺序执行隔离 env 副作用).
pub fn __test_reset_config() {
    let mut g = CONFIG.lock().unwrap_or_else(|e| e.into_inner());
    *g = None;
}

/// gzip 压缩（miniz_oxide 纯 Rust）。失败（理论不会）返回 None。
pub fn gzip_compress(body: &[u8]) -> Option<Vec<u8>> {
    let mut enc = GzEncoder::new(Vec::new(), Compression::default());
    enc.write_all(body).ok()?;
    enc.finish().ok()
}

/// extra 头串（"\r\n" 分隔的 Name: value 行）是否已声明 Content-Encoding
/// （按**头名**判定: 行内到第一个 ':' 为止, 大小写不敏感）— 已有则不叠加 gzip.
fn extra_has_content_encoding(extra: &str) -> bool {
    extra.lines().any(|l| {
        let name = l.split(':').next().unwrap_or("").trim();
        name.eq_ignore_ascii_case("Content-Encoding")
    })
}

/// 是否应对该响应做 gzip。纯判定（不压缩）:
/// 启用 + client 接受 + include_body + body 非空 + 尺寸窗口 + 非 304
/// + extra 无 Content-Encoding.
pub fn should_gzip(
    cfg: &GzipConfig,
    body_len: usize,
    status: &str,
    extra: Option<&str>,
    client_accepts: bool,
    include_body: bool,
) -> bool {
    if !cfg.enabled || !include_body || !client_accepts || body_len == 0 {
        return false;
    }
    if body_len < cfg.min_size || body_len > cfg.max_size {
        return false;
    }
    if status.starts_with("304") {
        return false;
    }
    if let Some(e) = extra {
        if extra_has_content_encoding(e) {
            return false;
        }
    }
    true
}
