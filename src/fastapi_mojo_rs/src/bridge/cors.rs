//! bridge/cors.rs — CORS 完整配置 (决策-42 ADR-0017 → 决策-73 ADR-0048 对齐上游).
//!
//! FastAPI/Starlette `CORSMiddleware` 的**声明式 env 等价形态**（Mojo 无闭包/
//! 中间件对象; 横切配置一律 env — GZip/lifespan/access-log 同模式）:
//!   - `FASTAPI_MOJO_CORS_ORIGINS`          CSV 白名单 或 `*`（默认 `*`）
//!   - `FASTAPI_MOJO_CORS_ORIGIN_REGEX`     `allow_origin_regex`（re.fullmatch）
//!   - `FASTAPI_MOJO_CORS_METHODS`          CSV 或 `*`（`*` → ALL_METHODS; 默认既有 6 方法）
//!   - `FASTAPI_MOJO_CORS_HEADERS`          CSV 或 `*`（默认 Content-Type, Authorization）
//!   - `FASTAPI_MOJO_CORS_CREDENTIALS`      true/false（默认 false）
//!   - `FASTAPI_MOJO_CORS_MAX_AGE`          秒（默认 600）
//!   - `FASTAPI_MOJO_CORS_EXPOSE_HEADERS`   CSV（`Access-Control-Expose-Headers`）
//!   - `FASTAPI_MOJO_CORS_PRIVATE_NETWORK`  true/false（PNA 预检放行）
//!
//! 语义（Starlette 1.6.0 `CORSMiddleware` 逐项对齐, ADR-0048）:
//!   - `allow_methods` 含 `*` → `ALL_METHODS`（DELETE 起头, 上游同款）。
//!   - `allow_headers` = `sorted(SAFELISTED_HEADERS ∪ 配置)`; 含 `*` → 全放行且
//!     预检**镜像**回 `Access-Control-Request-Headers`。
//!   - `preflight_explicit_allow_origin = !allow_all_origins || credentials`。
//!   - 普通响应: `simple_headers`（Allow-Origin `*` / Credentials / Expose-Headers）
//!     恒发; 命中 echo 条件（全通配+credentials, 或白名单/regex 命中）额外回显
//!     origin + `Vary: Origin`。
//!   - 预检（真预检 = Origin + ACRM 在场）: 成功 → **200 + text/plain
//!     `OK`**; 失败 → **400 + text/plain `Disallowed CORS <failures>`**（failures
//!     `origin` / `method` / `headers` / `private-network` 逗号连接）; 两种情况都
//!     携带完整 preflight 头集（Vary/`*` + Allow-Methods + Max-Age +
//!     [Allow-Headers] + [Credentials] + 动态 Allow-Origin / 镜像 Allow-Headers /
//!     Allow-Private-Network）。裸 OPTIONS / 无 ACRM 的 OPTIONS 保留既有 204 通配
//!     超集（文档化偏差, 见 ADR-0017 §3.2 / ADR-0048 §7）。
//!
//! request 全局: origin / acrm / achr / pna（io.rs 解析 header 时写入, FFI 面不变）。

use std::sync::Mutex;

/// 上游 `SAFELISTED_HEADERS`（永远并入 allow_headers）。
const SAFELISTED_HEADERS: [&str; 4] = ["Accept", "Accept-Language", "Content-Language", "Content-Type"];
/// 上游 `ALL_METHODS`（`allow_methods` 含 `*` 时替换; DELETE 起头）。
const ALL_METHODS: [&str; 7] = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"];

#[derive(Debug, Clone)]
pub struct CorsConfig {
    /// None = 通配 (`*`); Some(列表) = 白名单
    pub origins: Option<Vec<String>>,
    /// `allow_origin_regex`（`re.fullmatch`; None = 未配置）
    pub origin_regex: Option<String>,
    pub methods: Vec<String>,
    /// None = `*`（放行全部请求头, 预检镜像请求头）
    pub headers: Option<Vec<String>>,
    pub credentials: bool,
    pub max_age: i64,
    /// `Access-Control-Expose-Headers` 值列表（空 = 不发）
    pub expose_headers: Vec<String>,
    /// PNA (`Access-Control-Request-Private-Network`) 放行开关
    pub private_network: bool,
}

impl CorsConfig {
    pub fn allow_all_origins(&self) -> bool {
        self.origins.is_none()
    }
    pub fn allow_all_headers(&self) -> bool {
        self.headers.is_none()
    }
    /// 上游 `preflight_explicit_allow_origin`。
    pub fn explicit_allow_origin(&self) -> bool {
        !self.allow_all_origins() || self.credentials
    }
    /// `sorted(SAFELISTED_HEADERS ∪ 配置)`; `headers = None` 时仅用于成员判定。
    pub fn sorted_allow_headers(&self) -> Vec<String> {
        let mut set: Vec<String> = SAFELISTED_HEADERS.iter().map(|s| s.to_string()).collect();
        if let Some(list) = &self.headers {
            for h in list {
                if !set.iter().any(|x| x == h) {
                    set.push(h.clone());
                }
            }
        }
        set.sort();
        set
    }
    /// 普通响应静态 simple_headers（构造顺序 = 上游 dict 顺序）。
    fn simple_header_lines(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.allow_all_origins() {
            out.push("Access-Control-Allow-Origin: *".to_string());
        }
        if self.credentials {
            out.push("Access-Control-Allow-Credentials: true".to_string());
        }
        if !self.expose_headers.is_empty() {
            out.push(format!(
                "Access-Control-Expose-Headers: {}",
                self.expose_headers.join(", ")
            ));
        }
        out
    }
    /// 预检静态头（构造顺序 = 上游 `preflight_headers` dict 顺序）。
    fn preflight_static_lines(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.explicit_allow_origin() {
            out.push("Vary: Origin".to_string());
        } else {
            out.push("Access-Control-Allow-Origin: *".to_string());
        }
        out.push(format!(
            "Access-Control-Allow-Methods: {}",
            self.methods.join(", ")
        ));
        out.push(format!("Access-Control-Max-Age: {}", self.max_age));
        if !self.allow_all_headers() {
            out.push(format!(
                "Access-Control-Allow-Headers: {}",
                self.sorted_allow_headers().join(", ")
            ));
        }
        if self.credentials {
            out.push("Access-Control-Allow-Credentials: true".to_string());
        }
        out
    }
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

/// 默认配置: origins `*` / methods 既有 6 / headers Content-Type,Authorization /
/// credentials 关 / max_age 600（Starlette）; 新增 regex/expose/PNA 默认关（ADR-0048）。
pub fn default_config() -> CorsConfig {
    let origins = match env_csv("FASTAPI_MOJO_CORS_ORIGINS") {
        Some(v) if v.iter().any(|s| s == "*") => None,
        other => other,
    };
    let methods = match env_csv("FASTAPI_MOJO_CORS_METHODS") {
        Some(v) if v.iter().any(|s| s == "*") => ALL_METHODS.iter().map(|s| s.to_string()).collect(),
        Some(v) => v,
        None => vec![
            "GET".into(),
            "POST".into(),
            "PUT".into(),
            "DELETE".into(),
            "HEAD".into(),
            "OPTIONS".into(),
        ],
    };
    let headers = match env_csv("FASTAPI_MOJO_CORS_HEADERS") {
        Some(v) if v.iter().any(|s| s == "*") => None,
        Some(v) => Some(v),
        None => Some(vec!["Content-Type".to_string(), "Authorization".to_string()]),
    };
    let origin_regex = env_csv("FASTAPI_MOJO_CORS_ORIGIN_REGEX")
        .and_then(|v| v.into_iter().next())
        .filter(|s| !s.is_empty());
    CorsConfig {
        origins,
        origin_regex,
        methods,
        headers,
        credentials: env_bool("FASTAPI_MOJO_CORS_CREDENTIALS"),
        max_age: env_i64("FASTAPI_MOJO_CORS_MAX_AGE", 600),
        expose_headers: env_csv("FASTAPI_MOJO_CORS_EXPOSE_HEADERS").unwrap_or_default(),
        private_network: env_bool("FASTAPI_MOJO_CORS_PRIVATE_NETWORK"),
    }
}

/// 进程级缓存（Mutex 而非 OnceLock — 提供 #[cfg(test)] 重置钩子）。
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
/// config 缓存。cors/response/send 测试文件共用。
#[cfg(test)]
pub fn __test_clear_env() {
    for k in [
        "FASTAPI_MOJO_CORS_ORIGINS",
        "FASTAPI_MOJO_CORS_ORIGIN_REGEX",
        "FASTAPI_MOJO_CORS_METHODS",
        "FASTAPI_MOJO_CORS_HEADERS",
        "FASTAPI_MOJO_CORS_CREDENTIALS",
        "FASTAPI_MOJO_CORS_MAX_AGE",
        "FASTAPI_MOJO_CORS_EXPOSE_HEADERS",
        "FASTAPI_MOJO_CORS_PRIVATE_NETWORK",
    ] {
        std::env::remove_var(k);
    }
    __test_reset_config();
}

/// origin 是否被允许（通配放行; regex fullmatch; 白名单精确字符串匹配）。
pub fn is_allowed_origin(cfg: &CorsConfig, origin: &str) -> bool {
    if cfg.allow_all_origins() {
        return true;
    }
    if let Some(rx) = &cfg.origin_regex {
        if crate::bridge::regex::rgx_fullmatch(rx, origin) == 1 {
            return true;
        }
    }
    match &cfg.origins {
        Some(list) => list.iter().any(|o| o == origin),
        None => true,
    }
}

/// 上游 `origin in allow_origins` 的别名（保守语义, 供既有调用）。
pub fn origin_allowed(cfg: &CorsConfig, origin: &str) -> bool {
    is_allowed_origin(cfg, origin)
}

/// 普通响应的 CORS 头行; 无 Origin / 空 Origin → 空。
pub fn normal_cors_lines(origin: Option<&str>) -> Vec<String> {
    let cfg = config();
    let Some(o) = origin else {
        return Vec::new();
    };
    if o.is_empty() {
        return Vec::new();
    }
    let mut lines = cfg.simple_header_lines();
    let echo = (cfg.allow_all_origins() && cfg.credentials)
        || (!cfg.allow_all_origins() && is_allowed_origin(&cfg, o));
    if echo {
        let line = format!("Access-Control-Allow-Origin: {o}");
        match lines.iter().position(|l| l.starts_with("Access-Control-Allow-Origin:")) {
            Some(pos) => lines[pos] = line,
            None => lines.push(line),
        }
        lines.push("Vary: Origin".to_string());
    }
    lines
}

/// 裸 OPTIONS / 无 ACRM 的 OPTIONS → 既有 204 通配超集（文档化偏差）。
fn superset_bare_options(cfg: &CorsConfig, origin: Option<&str>, acrm: Option<&str>, achr: Option<&str>) -> (&'static str, Vec<String>, String) {
    let mut lines = Vec::new();
    match origin {
        Some(o) if !o.is_empty() => {
            if cfg.origins.is_some() || cfg.credentials {
                lines.push(format!("Access-Control-Allow-Origin: {o}"));
            } else {
                lines.push("Access-Control-Allow-Origin: *".to_string());
            }
        }
        _ => lines.push("Access-Control-Allow-Origin: *".to_string()),
    }
    if cfg.credentials {
        lines.push("Access-Control-Allow-Credentials: true".to_string());
    }
    if let Some(m) = acrm {
        if !m.is_empty() {
            lines.push(format!("Access-Control-Allow-Methods: {}", cfg.methods.join(", ")));
        }
    }
    if let Some(h) = achr {
        if !h.is_empty() {
            let hv = if cfg.allow_all_headers() {
                "*".to_string()
            } else {
                cfg.sorted_allow_headers().join(", ")
            };
            lines.push(format!("Access-Control-Allow-Headers: {hv}"));
        }
    }
    lines.push(format!("Access-Control-Max-Age: {}", cfg.max_age));
    ("204 No Content", lines, String::new())
}

/// 预检判定 + 响应（status_line, 头行, body）。返回体:
///   - `""`   = 204 通配超集（裸 OPTIONS）
///   - `"OK"` = 200 真预检通过
///   - `"Disallowed CORS …"` = 400 真预检失败
pub fn preflight_build(
    origin: Option<&str>,
    acrm: Option<&str>,
    achr: Option<&str>,
    pna: Option<&str>,
) -> (&'static str, Vec<String>, String) {
    let cfg = config();
    let has_origin = origin.map(|o| !o.is_empty()).unwrap_or(false);
    let has_acrm = acrm.map(|m| !m.is_empty()).unwrap_or(false);
    if !has_origin || !has_acrm {
        return superset_bare_options(&cfg, origin, acrm, achr);
    }
    let o = origin.expect("has_origin");
    let m = acrm.expect("has_acrm");
    let mut lines = cfg.preflight_static_lines();
    let mut failures: Vec<&'static str> = Vec::new();

    if is_allowed_origin(&cfg, o) {
        if cfg.explicit_allow_origin() {
            lines.push(format!("Access-Control-Allow-Origin: {o}"));
        }
    } else {
        failures.push("origin");
    }
    // 上游大小写敏感精确匹配（allow_methods 已归一化）。
    if !cfg.methods.iter().any(|x| x == m) {
        failures.push("method");
    }
    if cfg.allow_all_headers() {
        if let Some(h) = achr {
            if !h.is_empty() {
                lines.push(format!("Access-Control-Allow-Headers: {h}"));
            }
        }
    } else if let Some(h) = achr {
        if !h.is_empty() {
            let allow_lc: Vec<String> = cfg
                .sorted_allow_headers()
                .iter()
                .map(|s| s.to_ascii_lowercase())
                .collect();
            let bad = h
                .split(',')
                .map(|s| s.trim().to_ascii_lowercase())
                .filter(|s| !s.is_empty())
                .any(|r| !allow_lc.iter().any(|a| a == &r));
            if bad {
                failures.push("headers");
            }
        }
    }
    if let Some(p) = pna {
        if !p.is_empty() {
            if cfg.private_network {
                lines.push("Access-Control-Allow-Private-Network: true".to_string());
            } else {
                failures.push("private-network");
            }
        }
    }
    if failures.is_empty() {
        ("200 OK", lines, "OK".to_string())
    } else {
        ("400 Bad Request", lines, format!("Disallowed CORS {}", failures.join(", ")))
    }
}
