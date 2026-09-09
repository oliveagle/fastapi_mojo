// cors.rs 单元测试 (决策-42, ADR-0017, Goal-0003 P2 矩阵 #15)
//
// --test-threads=1 纪律: env 全局副作用 (FASTAPI_MOJO_CORS_*) 按 set→assert→
// remove+reset 顺序执行; 每个测试结尾 clear_env() 保证不泄漏到后续测试
// (与 gzip_tests 同一隔离模式)。

use super::cors::*;

const ORIGINS: &str = "FASTAPI_MOJO_CORS_ORIGINS";
const METHODS: &str = "FASTAPI_MOJO_CORS_METHODS";
const HEADERS: &str = "FASTAPI_MOJO_CORS_HEADERS";
const CREDENTIALS: &str = "FASTAPI_MOJO_CORS_CREDENTIALS";
const MAX_AGE: &str = "FASTAPI_MOJO_CORS_MAX_AGE";

fn clear_env() {
    // 共享钩子（cors.rs）: 清 5 个 env + config 缓存
    __test_clear_env();
}

fn cfg(
    origins: Option<Vec<String>>,
    methods: Vec<String>,
    headers: Option<Vec<String>>,
    credentials: bool,
    max_age: i64,
) -> CorsConfig {
    CorsConfig {
        origins,
        methods,
        headers,
        credentials,
        max_age,
    }
}

// ---------- default_config ----------

#[test]
fn default_config_no_env_starlette_defaults() {
    clear_env();
    let c = default_config();
    assert!(c.origins.is_none(), "default = wildcard *");
    assert_eq!(
        c.methods,
        vec!["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS"]
    );
    assert_eq!(
        c.headers,
        Some(vec!["Content-Type".to_string(), "Authorization".to_string()]),
    );
    assert!(!c.credentials);
    assert_eq!(c.max_age, 600, "Starlette CORSMiddleware max_age=600");
    clear_env();
}

#[test]
fn default_config_csv_star_creds_max_age() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com, http://b.com");
    std::env::set_var(METHODS, "GET, POST");
    std::env::set_var(HEADERS, "*");
    std::env::set_var(CREDENTIALS, "true");
    std::env::set_var(MAX_AGE, "120");
    let c = default_config();
    assert_eq!(
        c.origins,
        Some(vec!["http://a.com".to_string(), "http://b.com".to_string()])
    );
    assert_eq!(c.methods, vec!["GET", "POST"]);
    assert!(c.headers.is_none(), "* → allow all headers");
    assert!(c.credentials);
    assert_eq!(c.max_age, 120);
    clear_env();
}

#[test]
fn default_config_origins_star_anywhere_is_wildcard() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com, *");
    assert!(default_config().origins.is_none(), "CSV 含 * → wildcard");
    clear_env();
    std::env::set_var(ORIGINS, " * , http://a.com");
    assert!(default_config().origins.is_none(), "trim 后 * → wildcard");
    clear_env();
}

#[test]
fn default_config_bool_variants_and_bad_int() {
    clear_env();
    for (v, want) in [("1", true), ("true", true), ("yes", true), ("on", true), ("false", false), ("0", false)] {
        std::env::set_var(CREDENTIALS, v);
        assert_eq!(default_config().credentials, want, "variant {v}");
    }
    std::env::remove_var(CREDENTIALS);
    std::env::set_var(MAX_AGE, "not-a-number");
    assert_eq!(default_config().max_age, 600, "bad int → default");
    clear_env();
}

// ---------- origin_allowed ----------

#[test]
fn origin_allowed_matrix() {
    let wild = cfg(None, vec![], None, false, 600);
    let list = cfg(
        Some(vec!["http://a.com".to_string(), "http://b.com".to_string()]),
        vec![],
        None,
        false,
        600,
    );
    let empty = cfg(Some(vec![]), vec![], None, false, 600);
    // 通配放行一切（含 "null" origin — 浏览器 file:// 场景）
    assert!(origin_allowed(&wild, "http://x.com"));
    assert!(origin_allowed(&wild, "null"));
    // 白名单精确匹配
    assert!(origin_allowed(&list, "http://a.com"));
    assert!(origin_allowed(&list, "http://b.com"));
    assert!(!origin_allowed(&list, "http://c.com"));
    assert!(!origin_allowed(&list, "http://a.com.evil.com"), "前缀不算命中");
    // 空白名单拒绝一切
    assert!(!origin_allowed(&empty, "http://a.com"));
}

// ---------- normal_cors_lines ----------

#[test]
fn normal_cors_lines_matrix() {
    clear_env();
    // 无 Origin → 0 行（Starlette 对齐; C 时代「每响应必带 *」偏差移除）
    assert_eq!(normal_cors_lines(None), Vec::<String>::new());
    assert_eq!(normal_cors_lines(Some("")), Vec::<String>::new());
    // 默认通配 + Origin → ACAO *（无 credentials 行）
    assert_eq!(
        normal_cors_lines(Some("http://example.com")),
        vec!["Access-Control-Allow-Origin: *".to_string()]
    );
    clear_env();
    // 白名单命中 + credentials → 回显 + credentials 行
    std::env::set_var(ORIGINS, "http://a.com,http://b.com");
    std::env::set_var(CREDENTIALS, "true");
    __test_reset_config();
    assert_eq!(
        normal_cors_lines(Some("http://b.com")),
        vec![
            "Access-Control-Allow-Origin: http://b.com".to_string(),
            "Access-Control-Allow-Credentials: true".to_string(),
        ]
    );
    // 白名单未命中 → 0 行
    assert_eq!(normal_cors_lines(Some("http://evil.com")), Vec::<String>::new());
    // 通配 + credentials → 回显（* + credentials 按 RFC 非法, Starlette 回显）
    std::env::remove_var(ORIGINS);
    __test_reset_config();
    assert_eq!(
        normal_cors_lines(Some("http://example.com")),
        vec![
            "Access-Control-Allow-Origin: http://example.com".to_string(),
            "Access-Control-Allow-Credentials: true".to_string(),
        ]
    );
    clear_env();
}

// ---------- preflight_build ----------

#[test]
fn preflight_bare_options_wildcard_superset() {
    clear_env();
    // 裸 OPTIONS（无 Origin/ACRM/ACHR）→ 204 通配超集（C 端口既有行为, e2e 守护）
    let (status, lines, err) = preflight_build(None, None, None);
    assert_eq!(status, "204 No Content");
    assert!(err.is_none());
    assert_eq!(
        lines,
        vec![
            "Access-Control-Allow-Origin: *".to_string(),
            "Access-Control-Max-Age: 600".to_string(),
        ]
    );
    clear_env();
}

#[test]
fn preflight_204_full_lines() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com");
    std::env::set_var(CREDENTIALS, "true");
    std::env::set_var(MAX_AGE, "120");
    __test_reset_config();
    let (status, lines, err) = preflight_build(Some("http://a.com"), Some("POST"), Some("Content-Type, Authorization"));
    assert_eq!(status, "204 No Content");
    assert!(err.is_none());
    assert_eq!(
        lines,
        vec![
            "Access-Control-Allow-Origin: http://a.com".to_string(),
            "Access-Control-Allow-Credentials: true".to_string(),
            "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS".to_string(),
            "Access-Control-Allow-Headers: Content-Type, Authorization".to_string(),
            "Access-Control-Max-Age: 120".to_string(),
        ]
    );
    clear_env();
}

#[test]
fn preflight_400_origin_method_headers() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com");
    __test_reset_config();
    // origin 不在白名单
    let (status, lines, err) = preflight_build(Some("http://evil.com"), None, None);
    assert_eq!(status, "400 Bad Request");
    assert!(lines.is_empty());
    assert_eq!(err, Some("origin not allowed"));
    // ACRM 越界（默认 7 方法集无 PATCH）
    let (status, _, err) = preflight_build(Some("http://a.com"), Some("PATCH"), None);
    assert_eq!(status, "400 Bad Request");
    assert_eq!(err, Some("method not allowed"));
    // ACHR 越界（默认头集仅 Content-Type/Authorization）
    let (status, _, err) = preflight_build(Some("http://a.com"), None, Some("X-Custom-Not-Allowed"));
    assert_eq!(status, "400 Bad Request");
    assert_eq!(err, Some("requested header not allowed"));
    // ACHR 多值部分越界
    let (status, _, err) = preflight_build(Some("http://a.com"), None, Some("Content-Type, X-Nope"));
    assert_eq!(status, "400 Bad Request");
    assert_eq!(err, Some("requested header not allowed"));
    clear_env();
}

#[test]
fn preflight_pass_edges() {
    clear_env();
    // ACRM 大小写不敏感
    let (status, _, err) = preflight_build(Some("http://x.com"), Some("post"), None);
    assert_eq!(status, "204 No Content");
    assert!(err.is_none());
    // headers 默认 * ? 否 — 默认是 Content-Type, Authorization; 设 * 放行一切
    std::env::set_var(HEADERS, "*");
    __test_reset_config();
    let (status, lines, err) = preflight_build(Some("http://x.com"), None, Some("X-Whatever"));
    assert_eq!(status, "204 No Content");
    assert!(err.is_none());
    assert!(lines.iter().any(|l| l == "Access-Control-Allow-Headers: *"));
    // 空 ACRM/ACHR（带 header 但值为空）→ 不触发 400
    let (status, _, err) = preflight_build(Some("http://x.com"), Some(""), Some(""));
    assert_eq!(status, "204 No Content");
    assert!(err.is_none());
    clear_env();
}
