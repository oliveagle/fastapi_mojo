// cors.rs 单元测试 (决策-42 ADR-0017 → 决策-73 ADR-0048 上游对齐).
//
// --test-threads=1 纪律: env 全局副作用 (FASTAPI_MOJO_CORS_*) 按 set→assert→
// remove+reset 顺序执行; 每个测试结尾 clear_env() 保证不泄漏到后续测试。

use super::cors::*;

const ORIGINS: &str = "FASTAPI_MOJO_CORS_ORIGINS";
const ORIGIN_REGEX: &str = "FASTAPI_MOJO_CORS_ORIGIN_REGEX";
const METHODS: &str = "FASTAPI_MOJO_CORS_METHODS";
const HEADERS: &str = "FASTAPI_MOJO_CORS_HEADERS";
const CREDENTIALS: &str = "FASTAPI_MOJO_CORS_CREDENTIALS";
const MAX_AGE: &str = "FASTAPI_MOJO_CORS_MAX_AGE";
const EXPOSE: &str = "FASTAPI_MOJO_CORS_EXPOSE_HEADERS";
const PRIVATE_NETWORK: &str = "FASTAPI_MOJO_CORS_PRIVATE_NETWORK";

fn clear_env() {
    __test_clear_env();
}

/// 全默认字段基线 (测试按需改字段)。
fn base() -> CorsConfig {
    default_config()
}

fn cfg_all_origins() -> CorsConfig {
    let mut c = base();
    c.origins = None;
    c
}

// ---------- default_config ----------

#[test]
fn default_config_no_env() {
    clear_env();
    let c = default_config();
    assert!(c.origins.is_none(), "default = wildcard *");
    assert!(c.origin_regex.is_none());
    assert_eq!(c.methods, vec!["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS"]);
    assert_eq!(
        c.headers,
        Some(vec!["Content-Type".to_string(), "Authorization".to_string()])
    );
    assert!(!c.credentials);
    assert_eq!(c.max_age, 600);
    assert!(c.expose_headers.is_empty());
    assert!(!c.private_network);
    clear_env();
}

#[test]
fn default_config_star_methods_headers_and_new_envs() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com, http://b.com");
    std::env::set_var(ORIGIN_REGEX, r"https://.*\.example\.com");
    std::env::set_var(METHODS, "*");
    std::env::set_var(HEADERS, "*");
    std::env::set_var(CREDENTIALS, "true");
    std::env::set_var(MAX_AGE, "120");
    std::env::set_var(EXPOSE, "X-Total, X-Page");
    std::env::set_var(PRIVATE_NETWORK, "true");
    let c = default_config();
    assert_eq!(
        c.origins,
        Some(vec!["http://a.com".to_string(), "http://b.com".to_string()])
    );
    assert_eq!(c.origin_regex.as_deref(), Some(r"https://.*\.example\.com"));
    assert_eq!(c.methods, vec!["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]);
    assert!(c.headers.is_none(), "* → allow all headers");
    assert!(c.credentials);
    assert_eq!(c.max_age, 120);
    assert_eq!(c.expose_headers, vec!["X-Total".to_string(), "X-Page".to_string()]);
    assert!(c.private_network);
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com, *");
    assert!(default_config().origins.is_none(), "CSV 含 * → wildcard");
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

#[test]
fn sorted_allow_headers_unions_safelist() {
    let c = base(); // default headers = Content-Type, Authorization
    assert_eq!(
        c.sorted_allow_headers(),
        vec!["Accept", "Accept-Language", "Authorization", "Content-Language", "Content-Type"]
    );
}

// ---------- is_allowed_origin ----------

#[test]
fn is_allowed_origin_matrix() {
    let wild = cfg_all_origins();
    let mut list = base();
    list.origins = Some(vec!["http://a.com".to_string(), "http://b.com".to_string()]);
    assert!(is_allowed_origin(&wild, "http://x.com"));
    assert!(is_allowed_origin(&wild, "null"));
    assert!(is_allowed_origin(&list, "http://a.com"));
    assert!(!is_allowed_origin(&list, "http://c.com"));
    assert!(!is_allowed_origin(&list, "http://a.com.evil.com"), "前缀不算命中");
    // regex fullmatch
    let mut rx = base();
    rx.origins = Some(vec![]);
    rx.origin_regex = Some(r"https://.*\.example\.com".to_string());
    assert!(is_allowed_origin(&rx, "https://a.example.com"), "fullmatch 命中");
    assert!(!is_allowed_origin(&rx, "https://evil.com"));
    assert!(!is_allowed_origin(&rx, "https://a.example.com.evil.com"), "fullmatch 不中缀");
    // 别名
    assert!(origin_allowed(&wild, "http://x.com"));
}

// ---------- normal_cors_lines ----------

#[test]
fn normal_cors_lines_matrix() {
    clear_env();
    assert_eq!(normal_cors_lines(None), Vec::<String>::new());
    assert_eq!(normal_cors_lines(Some("")), Vec::<String>::new());
    // 通配 + Origin → ACAO * (无 Vary)
    assert_eq!(
        normal_cors_lines(Some("http://example.com")),
        vec!["Access-Control-Allow-Origin: *".to_string()]
    );
    clear_env();
    // 白名单命中 + credentials → 回显 + credentials + Vary: Origin
    std::env::set_var(ORIGINS, "http://a.com,http://b.com");
    std::env::set_var(CREDENTIALS, "true");
    __test_reset_config();
    assert_eq!(
        normal_cors_lines(Some("http://b.com")),
        vec![
            "Access-Control-Allow-Credentials: true".to_string(),
            "Access-Control-Allow-Origin: http://b.com".to_string(),
            "Vary: Origin".to_string(),
        ]
    );
    // 白名单未命中 → 仅静态 simple_headers (credentials), 无 ACAO/Vary
    assert_eq!(
        normal_cors_lines(Some("http://evil.com")),
        vec!["Access-Control-Allow-Credentials: true".to_string()]
    );
    // 通配 + credentials → 回显 (替换 `*`) + credentials + Vary
    std::env::remove_var(ORIGINS);
    __test_reset_config();
    assert_eq!(
        normal_cors_lines(Some("http://example.com")),
        vec![
            "Access-Control-Allow-Origin: http://example.com".to_string(),
            "Access-Control-Allow-Credentials: true".to_string(),
            "Vary: Origin".to_string(),
        ]
    );
    clear_env();
}

#[test]
fn normal_cors_lines_expose_headers() {
    clear_env();
    std::env::set_var(EXPOSE, "X-Total,X-Page");
    __test_reset_config();
    assert_eq!(
        normal_cors_lines(Some("http://x.com")),
        vec![
            "Access-Control-Allow-Origin: *".to_string(),
            "Access-Control-Expose-Headers: X-Total, X-Page".to_string(),
        ]
    );
    // regex 命中 → echo + expose
    std::env::set_var(ORIGIN_REGEX, r"https://.*\.example\.com");
    std::env::set_var(ORIGINS, " ");
    __test_reset_config();
    assert_eq!(
        normal_cors_lines(Some("https://a.example.com")),
        vec![
            "Access-Control-Expose-Headers: X-Total, X-Page".to_string(),
            "Access-Control-Allow-Origin: https://a.example.com".to_string(),
            "Vary: Origin".to_string(),
        ]
    );
    clear_env();
}

// ---------- preflight_build ----------

#[test]
fn preflight_bare_options_superset() {
    clear_env();
    let (status, lines, body) = preflight_build(None, None, None, None);
    assert_eq!(status, "204 No Content");
    assert!(body.is_empty());
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
fn preflight_200_ok_full_lines() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com");
    std::env::set_var(CREDENTIALS, "true");
    std::env::set_var(MAX_AGE, "120");
    __test_reset_config();
    let (status, lines, body) =
        preflight_build(Some("http://a.com"), Some("POST"), Some("Content-Type, Authorization"), None);
    assert_eq!(status, "200 OK");
    assert_eq!(body, "OK");
    assert_eq!(
        lines,
        vec![
            "Vary: Origin".to_string(),
            "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS".to_string(),
            "Access-Control-Max-Age: 120".to_string(),
            "Access-Control-Allow-Headers: Accept, Accept-Language, Authorization, Content-Language, Content-Type".to_string(),
            "Access-Control-Allow-Credentials: true".to_string(),
            "Access-Control-Allow-Origin: http://a.com".to_string(),
        ]
    );
    clear_env();
}

#[test]
fn preflight_wildcard_all_origins_no_vary() {
    clear_env();
    // 全通配 + 无 credentials → 非 explicit: ACAO *, 无 Vary
    let (status, lines, body) = preflight_build(Some("http://x.com"), Some("GET"), None, None);
    assert_eq!(status, "200 OK");
    assert_eq!(body, "OK");
    assert_eq!(lines[0], "Access-Control-Allow-Origin: *");
    assert!(!lines.iter().any(|l| l == "Vary: Origin"));
    // `*` headers → 镜像请求头
    std::env::set_var(HEADERS, "*");
    __test_reset_config();
    let (status, lines, _) = preflight_build(Some("http://x.com"), Some("GET"), Some("X-A, X-B"), None);
    assert_eq!(status, "200 OK");
    assert!(lines.iter().any(|l| l == "Access-Control-Allow-Headers: X-A, X-B"), "mirror: {lines:?}");
    clear_env();
}

#[test]
fn preflight_400_failures() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com");
    __test_reset_config();
    // origin 不允许 (仍带 preflight 头集)
    let (status, lines, body) = preflight_build(Some("http://evil.com"), Some("GET"), None, None);
    assert_eq!(status, "400 Bad Request");
    assert_eq!(body, "Disallowed CORS origin");
    assert!(lines.iter().any(|l| l.starts_with("Access-Control-Allow-Methods:")));
    // method 越界 (大小写敏感) → Allow-Origin 已回显
    let (status, lines, body) = preflight_build(Some("http://a.com"), Some("PATCH"), None, None);
    assert_eq!(status, "400 Bad Request");
    assert_eq!(body, "Disallowed CORS method");
    assert!(lines.iter().any(|l| l == "Access-Control-Allow-Origin: http://a.com"));
    // headers 越界
    let (status, _, body) = preflight_build(Some("http://a.com"), Some("GET"), Some("X-Custom"), None);
    assert_eq!(status, "400 Bad Request");
    assert_eq!(body, "Disallowed CORS headers");
    // 多重失败 (逗号连接, 上游顺序 origin, method, headers)
    let (_, _, body) = preflight_build(Some("http://evil.com"), Some("PATCH"), Some("X-Custom"), None);
    assert_eq!(body, "Disallowed CORS origin, method, headers");
    clear_env();
}

#[test]
fn preflight_private_network() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com");
    __test_reset_config();
    // 关闭 → 400 private-network
    let (status, _, body) = preflight_build(Some("http://a.com"), Some("GET"), None, Some("true"));
    assert_eq!(status, "400 Bad Request");
    assert_eq!(body, "Disallowed CORS private-network");
    // 打开 → 200 + Allow-Private-Network: true
    std::env::set_var(PRIVATE_NETWORK, "true");
    __test_reset_config();
    let (status, lines, body) = preflight_build(Some("http://a.com"), Some("GET"), None, Some("true"));
    assert_eq!(status, "200 OK");
    assert_eq!(body, "OK");
    assert!(lines.iter().any(|l| l == "Access-Control-Allow-Private-Network: true"));
    clear_env();
}

#[test]
fn preflight_methods_case_sensitive() {
    clear_env();
    std::env::set_var(ORIGINS, "http://a.com");
    __test_reset_config();
    // 上游 `requested_method not in allow_methods` = 精确大小写
    let (status, _, body) = preflight_build(Some("http://a.com"), Some("get"), None, None);
    assert_eq!(status, "400 Bad Request");
    assert_eq!(body, "Disallowed CORS method");
    // `*` methods → ALL_METHODS (含 PATCH)
    std::env::set_var(METHODS, "*");
    __test_reset_config();
    let (status, _, _) = preflight_build(Some("http://a.com"), Some("PATCH"), None, None);
    assert_eq!(status, "200 OK");
    clear_env();
}
