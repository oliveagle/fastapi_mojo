//! bridge/cors.rs — CORS 完整配置（决策-42, ADR-0017, Goal-0003 P2 矩阵 #15）.
//!
//! FastAPI/Starlette `CORSMiddleware` 的**声明式 env 等价形态**（Mojo 无闭包/
//! 中间件对象; 横切配置一律 env — GZip/lifespan/access-log 同模式）:
//!   - `FASTAPI_MOJO_CORS_ORIGINS`    CSV 白名单 或 `*`（默认 `*` = 既有行为）
//!   - `FASTAPI_MOJO_CORS_METHODS`    CSV（默认 = 既有 7 方法集）
//!   - `FASTAPI_MOJO_CORS_HEADERS`    CSV 或 `*`（默认 = 既有 Content-Type, Authorization）
//!   - `FASTAPI_MOJO_CORS_CREDENTIALS` true/false（默认 false, Starlette）
//!   - `FASTAPI_MOJO_CORS_MAX_AGE`    秒（默认 600, Starlette）
//!
//! 语义（Starlette CORSMiddleware 对齐）:
//!   - 普通响应: 仅当请求带 Origin 且被允许时输出 CORS 头（无 Origin 不带,
//!     Starlette 对齐 — 与 C 端口时代「每个响应都带 `*`」的差异, ADR-0017 §3.2）
//!     - 通配且非 credentials → `Access-Control-Allow-Origin: *`
//!     - 白名单命中 或 credentials → **回显**具体 origin（`*` + credentials
//!       按 RFC 6265bis 非法, Starlette 回显）
//!     - credentials → `Access-Control-Allow-Credentials: true`
//!     - origin 不被允许 → 不带任何 CORS 头（浏览器自行拦截, 上游同款）
//!   - 预检（OPTIONS 拦截, dispatch 侧）:
//!     - Origin 不在白名单 → **400**（Starlette `_build_pre_response` 400 语义）
//!     - 带 ACRM 且不在 allow_methods → **400**
//!     - 带 ACHR 且任一请求头不在 allow_headers（`*` 放行）→ **400**
//!     - 通过 → 204 + Allow-Origin（回显/`*`）+ [Allow-Credentials] +
//!       [Allow-Methods]（ACRM 在场时）+ [Allow-Headers]（ACHR 在场时）+
//!       Max-Age
//!     - 裸 OPTIONS（无 Origin, C 端口既有行为, e2e 守护）→ 204 + 通配集
//!       （本实现的预检拦截是 Starlette 的**超集**: Starlette 把非预检
//!       OPTIONS 交 app, 这里统一 204; 对浏览器无差异 — 浏览器预检必带
//!       Origin + ACRM）
//!
//! request 全局: origin / acrm / achr（io.rs 解析 header 时写入, FFI 面不变）。

use std::sync::Mutex;

#[derive(Debug, Clone)]
pub struct CorsConfig {
    /// None = 通配 (`*`); Some(列表) = 白名单
    pub origins: Option<Vec<String>>,
    pub methods: Vec<String>,
    /// None = `*`（放行全部请求头）
    pub headers: Option<Vec<String>>,
    pub credentials: bool,
    pub max_age: i64,
}

fn env_csv(name: &str) -> Option<Vec<String>> {
    let raw = std::env::var(name).ok()?;
    let items: Vec<String> = raw
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    Some(items)
}

fn env_bool(name: &str) -> bool {
    matches!(std::env::var(name).ok().as_deref(), Some("1" | "true" | "yes" | "on"))
}

fn env_i64(name: &str, default: i64) -> i64 {
    match std::env::var(name) {
        Ok(v) => v.trim().parse().unwrap_or(default),
        Err(_) => default,
    }
}

/// 默认配置: 与 C 端口时代线上字节一致（`*` origin / 7 方法 / 2 头）,
/// credentials 关, max_age = Starlette 600（C 时代 86400 → 对齐上游, ADR §3.2）。
pub fn default_config() -> CorsConfig {
    let origins = match env_csv("FASTAPI_MOJO_CORS_ORIGINS") {
        Some(v) if v.iter().any(|s| s == "*") => None,
        other => other,
    };
    let methods = env_csv("FASTAPI_MOJO_CORS_METHODS").unwrap_or_else(|| {
        vec![
            "GET".into(),
            "POST".into(),
            "PUT".into(),
            "DELETE".into(),
            "HEAD".into(),
            "OPTIONS".into(),
        ]
    });
    let headers = match env_csv("FASTAPI_MOJO_CORS_HEADERS") {
        // 显式 `*` → 通配放行全部请求头
        Some(v) if v.iter().any(|s| s == "*") => None,
        // 显式 CSV → 白名单
        Some(v) => Some(v),
        // 未设置 → C 时代默认头集（Starlette CORSMiddleware allow_headers=None
        // 语义不同 — 上游 None = 只放行简单头; 这里取 C 端口既有默认, ADR-0017 §3.2）
        None => Some(vec!["Content-Type".to_string(), "Authorization".to_string()]),
    };
    CorsConfig {
        origins,
        methods,
        headers,
        credentials: env_bool("FASTAPI_MOJO_CORS_CREDENTIALS"),
        max_age: env_i64("FASTAPI_MOJO_CORS_MAX_AGE", 600),
    }
}

/// 进程级缓存（Mutex 而非 OnceLock — 提供 #[cfg(test)] 重置钩子,
/// GZip config 同模式）。
static CONFIG: Mutex<Option<CorsConfig>> = Mutex::new(None);

pub fn config() -> CorsConfig {
    let mut g = CONFIG.lock().unwrap_or_else(|e| e.into_inner());
    if g.is_none() {
        *g = Some(default_config());
    }
    g.as_ref().expect("just set").clone()
}

#[cfg(test)]
pub fn __test_reset_config() {
    let mut g = CONFIG.lock().unwrap_or_else(|e| e.into_inner());
    *g = None;
}

/// 测试钩子（--test-threads=1 纪律）: 清全部 `FASTAPI_MOJO_CORS_*` env +
/// config 缓存。cors/response/send 三个测试文件共用, 防 env 全局副作用
/// 跨测试泄漏（断言 panic 跳过结尾清理的防御纵深）。
#[cfg(test)]
pub fn __test_clear_env() {
    for k in [
        "FASTAPI_MOJO_CORS_ORIGINS",
        "FASTAPI_MOJO_CORS_METHODS",
        "FASTAPI_MOJO_CORS_HEADERS",
        "FASTAPI_MOJO_CORS_CREDENTIALS",
        "FASTAPI_MOJO_CORS_MAX_AGE",
    ] {
        std::env::remove_var(k);
    }
    __test_reset_config();
}

/// origin 是否被允许（通配放行; 白名单大小写敏感精确匹配,
/// Starlette 对 origins 是精确字符串匹配）。
pub fn origin_allowed(cfg: &CorsConfig, origin: &str) -> bool {
    match &cfg.origins {
        None => true,
        Some(list) => list.iter().any(|o| o == origin),
    }
}

fn origin_line(cfg: &CorsConfig, origin: &str) -> String {
    // 白名单 或 credentials → 回显具体 origin; 通配且无 credentials → `*`
    if cfg.origins.is_some() || cfg.credentials {
        format!("Access-Control-Allow-Origin: {origin}")
    } else {
        "Access-Control-Allow-Origin: *".to_string()
    }
}

/// 普通响应的 CORS 头行（0..2 行）; 无 Origin / origin 不允许 → 空。
pub fn normal_cors_lines(origin: Option<&str>) -> Vec<String> {
    let cfg = config();
    if let Some(o) = origin {
        if o.is_empty() || !origin_allowed(&cfg, o) {
            return Vec::new();
        }
        let mut out = vec![origin_line(&cfg, o)];
        if cfg.credentials {
            out.push("Access-Control-Allow-Credentials: true".to_string());
        }
        out
    } else {
        Vec::new()
    }
}

/// 预检判定 + 响应头行。返回 (status_line, lines, error_msg):
///   - 400: origin 不允许 / ACRM 不在 methods / ACHR 越界
///   - 204: 通过（含裸 OPTIONS 通配超集路径）
///
/// ACRM/ACHR 为 None = 请求未带。
pub fn preflight_build(origin: Option<&str>, acrm: Option<&str>, achr: Option<&str>) -> (&'static str, Vec<String>, Option<&'static str>) {
    let cfg = config();
    if let Some(o) = origin {
        if !o.is_empty() && !origin_allowed(&cfg, o) {
            return ("400 Bad Request", Vec::new(), Some("origin not allowed"));
        }
    }
    // ACRM 在场 → 必须 ∈ allow_methods
    if let Some(m) = acrm {
        if !m.is_empty() && !cfg.methods.iter().any(|x| x.eq_ignore_ascii_case(m)) {
            return ("400 Bad Request", Vec::new(), Some("method not allowed"));
        }
    }
    // ACHR 在场 → 每个请求头 ∈ allow_headers（`*` / None 放行; 大小写不敏感）
    if let Some(h) = achr {
        if !h.is_empty() {
            if let Some(allow) = &cfg.headers {
                let requested: Vec<&str> = h.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
                if requested.iter().any(|r| !allow.iter().any(|a| a.eq_ignore_ascii_case(r))) {
                    return ("400 Bad Request", Vec::new(), Some("requested header not allowed"));
                }
            }
        }
    }
    // 204: 组装头
    let mut lines = Vec::new();
    match origin {
        Some(o) if !o.is_empty() => lines.push(origin_line(&cfg, o)),
        None => lines.push("Access-Control-Allow-Origin: *".to_string()),
        Some(_) => {}
    }
    if cfg.credentials {
        lines.push("Access-Control-Allow-Credentials: true".to_string());
    }
    if acrm.is_some() {
        lines.push(format!("Access-Control-Allow-Methods: {}", cfg.methods.join(", ")));
    }
    if achr.is_some() {
        let hv = match &cfg.headers {
            None => "*".to_string(),
            Some(v) => v.join(", "),
        };
        lines.push(format!("Access-Control-Allow-Headers: {hv}"));
    }
    lines.push(format!("Access-Control-Max-Age: {}", cfg.max_age));
    ("204 No Content", lines, None)
}
