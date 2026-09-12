//! bridge/gzip.rs — GZip 响应压缩（决策-40 ADR-0015 → 决策-78 ADR-0053，Starlette 1.6.0 全量对齐）.
//!
//! FastAPI/Starlette `GZipMiddleware` 的**声明式 env 等价形态**（Mojo 无闭包/
//! 无中间件对象, 本项目横切配置一律 env — lifespan/access-log 同模式）:
//!   - `FASTAPI_MOJO_GZIP=1`              启用（默认关 = FastAPI 默认不加 gzip）
//!   - `FASTAPI_MOJO_GZIP_MIN_SIZE`       压缩下限（默认 500, 对齐 `minimum_size`）
//!   - `FASTAPI_MOJO_GZIP_LEVEL`          压缩级别（默认 9, 对齐 `compresslevel`）
//!   - `FASTAPI_MOJO_GZIP_MAX_SIZE`       可选上限（默认 0 = 无上限; 设 >0 = 内存保护, 非上游）
//!   - `FASTAPI_MOJO_GZIP_EXCLUDE`        逗号分隔 media-type 排除表（覆盖默认表）
//!
//! 语义（Starlette 1.6.0 `GZipMiddleware` 逐项对齐, 见 ADR-0053）:
//!   - client 判定 = `Accept-Encoding` 含**大小写敏感子串** `gzip`（上游
//!     `"gzip" in headers.get("Accept-Encoding","")` quirk：`GZIP`/`Gzip` 不算,
//!     `x-gzip`/`gzip;q=0` 算）
//!   - 排除 media type（默认表含 `text/event-stream`/`image/*`/`video/*`/`audio/*` 等）
//!   - status 206（partial）/ extra 已声明 `Content-Encoding` → 跳过
//!   - `Vary: Accept-Encoding` 在**可压响应**上恒加（上游 `add_vary_header`,
//!     与客户端是否真接受 gzip 无关）；小体（< minimum_size, 非 streaming）不加
//!   - streaming 响应可压（上游 `more_body` 分支, 不受 minimum_size 门）
//!
//! `plan()` → `GzipPlan { vary, compress }`：`vary` 决定是否加 `Vary: Accept-Encoding`；
//! `compress` 决定是否真正压缩（`vary ∧ client 接受 ∧ 若设上限则尺寸在上限内`）。
//!
//! flate2 = **纯 Rust miniz_oxide 后端**（默认 feature 无 zlib-ng/C 路径）,
//! 静态链接进 libfastapi_mojo_rs.a → ldd 仍仅 libc（North Star 不破）。

use std::io::Write;
use std::sync::Mutex;

use flate2::{Compression, write::GzEncoder};

/// 上游 `GZipMiddleware.DEFAULT_EXCLUDED_CONTENT_TYPES`（starlette 1.6.0）。
pub const DEFAULT_EXCLUDE: &[&str] = &[
    "application/gzip",
    "application/x-gzip",
    "application/zip",
    "audio/*",
    "font/woff",
    "font/woff2",
    "image/avif",
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/webp",
    "text/event-stream",
    "video/*",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GzipConfig {
    pub enabled: bool,
    pub min_size: usize,
    /// 0 = 无上限（上游行为）；>0 = 额外内存保护（本仓库扩展）
    pub max_size: usize,
    pub level: u32,
    /// 排除的 media type（全小写；`type/*` 匹配整类）
    pub exclude: Vec<String>,
}

fn env_usize(name: &str, default: usize) -> usize {
    match std::env::var(name) {
        Ok(v) => v.trim().parse().unwrap_or(default),
        Err(_) => default,
    }
}

fn env_u32(name: &str, default: u32) -> u32 {
    match std::env::var(name) {
        Ok(v) => v.trim().parse().unwrap_or(default),
        Err(_) => default,
    }
}

fn env_bool(name: &str) -> bool {
    matches!(std::env::var(name).ok().as_deref(), Some("1" | "true" | "yes" | "on"))
}

/// 默认配置: 关, min 500, 无上限, level 9, 上游默认排除表.
pub fn default_config() -> GzipConfig {
    let exclude = match std::env::var("FASTAPI_MOJO_GZIP_EXCLUDE") {
        Ok(v) => v
            .split(',')
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty())
            .collect(),
        Err(_) => DEFAULT_EXCLUDE.iter().map(|s| s.to_string()).collect(),
    };
    GzipConfig {
        enabled: env_bool("FASTAPI_MOJO_GZIP"),
        min_size: env_usize("FASTAPI_MOJO_GZIP_MIN_SIZE", 500),
        max_size: env_usize("FASTAPI_MOJO_GZIP_MAX_SIZE", 0),
        level: env_u32("FASTAPI_MOJO_GZIP_LEVEL", 9),
        exclude,
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
    g.as_ref().expect("just set").clone()
}

#[cfg(test)]
/// 测试钩子: 清 config 缓存 (配合 --test-threads=1 顺序执行隔离 env 副作用).
pub fn __test_reset_config() {
    let mut g = CONFIG.lock().unwrap_or_else(|e| e.into_inner());
    *g = None;
}

/// gzip 压缩（miniz_oxide 纯 Rust）。失败（理论不会）返回 None。
/// `level` = 上游 `compresslevel`（默认 9）。
pub fn gzip_compress(body: &[u8], level: u32) -> Option<Vec<u8>> {
    let mut enc = GzEncoder::new(Vec::new(), Compression::new(level.min(9)));
    enc.write_all(body).ok()?;
    enc.finish().ok()
}

/// extra 头串（"\r\n" 分隔的 Name: value 行）是否已声明 Content-Encoding
/// （按**头名**判定: 行内到第一个 ':' 为止, 大小写不敏感）— 已有则不叠加 gzip.
pub fn extra_has_content_encoding(extra: &str) -> bool {
    extra.lines().any(|l| {
        let name = l.split(':').next().unwrap_or("").trim();
        name.eq_ignore_ascii_case("Content-Encoding")
    })
}

/// media type 是否在排除表内（`;` 后缀剥离 + 小写; 精确或 `type/*` 匹配）.
/// 空 media type → 不排除（上游 `media_type=""` 不命中任何排除项）.
pub fn media_type_excluded(content_type: &str, exclude: &[String]) -> bool {
    let media = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if media.is_empty() {
        return false;
    }
    let star = format!("{}/*", media.split('/').next().unwrap_or(""));
    exclude.iter().any(|e| e == &media || e == &star)
}

/// GZip 处理计划.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GzipPlan {
    /// 是否加 `Vary: Accept-Encoding`（上游在可压响应上恒加, 与 client 是否接受无关）
    pub vary: bool,
    /// 是否真正压缩（vary ∧ client 接受 ∧ 尺寸上限内）
    pub compress: bool,
}

pub const SKIP: GzipPlan = GzipPlan { vary: false, compress: false };

/// 计算响应的 gzip 计划（纯判定, 不压缩）.
///
/// `streaming=true` 时不受 `min_size` 门（上游 `more_body` 分支）.
#[allow(clippy::too_many_arguments)] // 语义参数面（上游 GZipResponder 同维度）
pub fn plan(
    cfg: &GzipConfig,
    content_type: &str,
    body_len: usize,
    status: &str,
    extra: Option<&str>,
    client_accepts: bool,
    include_body: bool,
    streaming: bool,
) -> GzipPlan {
    if !cfg.enabled || !include_body {
        return SKIP;
    }
    if status.starts_with("206") {
        return SKIP; // 上游 partial_response
    }
    if let Some(e) = extra {
        if extra_has_content_encoding(e) {
            return SKIP;
        }
    }
    if media_type_excluded(content_type, &cfg.exclude) {
        return SKIP;
    }
    // 上游: streaming 响应（首块 more_body=True）不受 min_size 门; 但**空流**
    // （唯一 body 消息 more_body=False）落入 small-response 分支 → 不压也不加 Vary。
    // 本模型的整条 stream 合并成一体, 故 `streaming && body_len == 0` 视同非 streaming。
    let effective_streaming = streaming && body_len > 0;
    if !effective_streaming && body_len < cfg.min_size {
        return SKIP;
    }
    let within_cap = cfg.max_size == 0 || body_len <= cfg.max_size;
    GzipPlan {
        vary: true,
        compress: client_accepts && within_cap && body_len > 0,
    }
}

/// gzip 相关待追加头行（顺序 = 上游: `Vary` 先, `Content-Encoding` 后）。
/// 返回 `None` = 无需追加。
pub fn extra_add_lines(vary: bool, compress: bool) -> Option<String> {
    if !vary && !compress {
        return None;
    }
    let mut s = String::new();
    if vary {
        s.push_str("Vary: Accept-Encoding");
    }
    if compress {
        if !s.is_empty() {
            s.push_str("\r\n");
        }
        s.push_str("Content-Encoding: gzip");
    }
    Some(s)
}

/// 把 gzip 相关行合并进既有 extra 头串（`\r\n` 分隔）。
pub fn merge_extra(extra: &str, vary: bool, compress: bool) -> String {
    match extra_add_lines(vary, compress) {
        None => extra.to_string(),
        Some(add) => {
            if extra.is_empty() {
                add
            } else {
                format!("{extra}\r\n{add}")
            }
        }
    }
}
