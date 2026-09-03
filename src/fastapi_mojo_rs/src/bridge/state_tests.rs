// state_tests.rs — 全局状态 setter/getter/env 解析回归 (ADR-0010 DC2)
use super::state::*;

fn unset(k: &str) {
    // SAFETY: tests run single-threaded for env mutation (env reads are
    // racy under cargo test parallelism; state_tests avoids assertions that
    // depend on env from other parallel tests by saving/restoring the
    // specific keys we touch).
    unsafe { std::env::remove_var(k) }
}

fn setv(k: &str, v: &str) {
    unsafe { std::env::set_var(k, v) }
}

// ---------- max body size ----------

#[test]
fn max_body_default() {
    reset_for_test();
    assert_eq!(get_max_body_size(), DEFAULT_MAX_BODY_SIZE);
}

#[test]
fn max_body_set_in_range() {
    reset_for_test();
    set_max_body_size(512 * 1024);
    assert_eq!(get_max_body_size(), 512 * 1024);
}

#[test]
fn max_body_set_rejected_when_zero() {
    reset_for_test();
    let before = get_max_body_size();
    set_max_body_size(0);
    assert_eq!(get_max_body_size(), before); // 0 不被接受
}

#[test]
fn max_body_set_rejected_when_over_limit() {
    reset_for_test();
    let before = get_max_body_size();
    set_max_body_size(MAX_BODY + 1);
    assert_eq!(get_max_body_size(), before); // 超过 MAX_BODY 不被接受
}

#[test]
fn max_body_set_at_max_boundary() {
    reset_for_test();
    set_max_body_size(MAX_BODY);
    assert_eq!(get_max_body_size(), MAX_BODY as i32);
}

// ---------- timeouts (env-driven) ----------

#[test]
fn timeouts_default() {
    reset_for_test();
    unset("FASTAPI_MOJO_RECV_TIMEOUT");
    unset("FASTAPI_MOJO_IDLE_TIMEOUT");
    unset("FASTAPI_MOJO_MAX_REQUEST");
    init_timeouts_from_env();
    assert_eq!(get_recv_timeout_ms(), DEFAULT_RECV_TIMEOUT_MS);
    assert_eq!(get_idle_max_ms(), DEFAULT_IDLE_MAX_MS);
    assert_eq!(get_max_request_ms(), DEFAULT_MAX_REQUEST_MS);
}

#[test]
fn timeouts_env_in_range() {
    reset_for_test();
    setv("FASTAPI_MOJO_RECV_TIMEOUT", "10");
    setv("FASTAPI_MOJO_IDLE_TIMEOUT", "120");
    setv("FASTAPI_MOJO_MAX_REQUEST", "60");
    init_timeouts_from_env();
    assert_eq!(get_recv_timeout_ms(), 10_000);
    assert_eq!(get_idle_max_ms(), 120_000);
    assert_eq!(get_max_request_ms(), 60_000);
    unset("FASTAPI_MOJO_RECV_TIMEOUT");
    unset("FASTAPI_MOJO_IDLE_TIMEOUT");
    unset("FASTAPI_MOJO_MAX_REQUEST");
}

#[test]
fn timeouts_env_out_of_range_ignored() {
    reset_for_test();
    setv("FASTAPI_MOJO_RECV_TIMEOUT", "0"); // < 1
    setv("FASTAPI_MOJO_IDLE_TIMEOUT", "9999"); // > 3600
    setv("FASTAPI_MOJO_MAX_REQUEST", "-5"); // < 1
    init_timeouts_from_env();
    assert_eq!(get_recv_timeout_ms(), DEFAULT_RECV_TIMEOUT_MS);
    assert_eq!(get_idle_max_ms(), DEFAULT_IDLE_MAX_MS);
    assert_eq!(get_max_request_ms(), DEFAULT_MAX_REQUEST_MS);
    unset("FASTAPI_MOJO_RECV_TIMEOUT");
    unset("FASTAPI_MOJO_IDLE_TIMEOUT");
    unset("FASTAPI_MOJO_MAX_REQUEST");
}

#[test]
fn timeouts_env_garbage_ignored() {
    reset_for_test();
    setv("FASTAPI_MOJO_RECV_TIMEOUT", "abc");
    setv("FASTAPI_MOJO_IDLE_TIMEOUT", "5x");
    init_timeouts_from_env();
    assert_eq!(get_recv_timeout_ms(), DEFAULT_RECV_TIMEOUT_MS);
    assert_eq!(get_idle_max_ms(), DEFAULT_IDLE_MAX_MS);
    unset("FASTAPI_MOJO_RECV_TIMEOUT");
    unset("FASTAPI_MOJO_IDLE_TIMEOUT");
}

#[test]
fn timeouts_env_at_boundaries() {
    reset_for_test();
    setv("FASTAPI_MOJO_RECV_TIMEOUT", "1");
    setv("FASTAPI_MOJO_IDLE_TIMEOUT", "3600");
    setv("FASTAPI_MOJO_MAX_REQUEST", "1");
    init_timeouts_from_env();
    assert_eq!(get_recv_timeout_ms(), 1_000);
    assert_eq!(get_idle_max_ms(), 3_600_000);
    assert_eq!(get_max_request_ms(), 1_000);
    unset("FASTAPI_MOJO_RECV_TIMEOUT");
    unset("FASTAPI_MOJO_IDLE_TIMEOUT");
    unset("FASTAPI_MOJO_MAX_REQUEST");
}

// ---------- static dir ----------

#[test]
fn static_dir_default_is_dot_slash_static() {
    reset_for_test();
    unset("FASTAPI_MOJO_STATIC_DIR");
    // 默认值是 "./static"
    assert_eq!(get_static_dir(), "./static");
}

#[test]
fn static_dir_set_with_path() {
    reset_for_test();
    unset("FASTAPI_MOJO_STATIC_DIR");
    set_static_dir(Some("/var/www"));
    assert_eq!(get_static_dir(), "/var/www");
}

#[test]
fn static_dir_env_overrides_passed() {
    reset_for_test();
    unset("FASTAPI_MOJO_STATIC_DIR");
    set_static_dir(Some("/var/www"));
    setv("FASTAPI_MOJO_STATIC_DIR", "/srv/http");
    set_static_dir(Some("/var/www"));
    assert_eq!(get_static_dir(), "/srv/http");
    unset("FASTAPI_MOJO_STATIC_DIR");
}

#[test]
fn static_dir_truncates_long_input() {
    reset_for_test();
    unset("FASTAPI_MOJO_STATIC_DIR");
    let long = "a".repeat(300);
    set_static_dir(Some(&long));
    let got = get_static_dir();
    // NUL 终止, 字节长度 <= MAX_STATIC_DIR - 1
    assert!(got.len() <= MAX_STATIC_DIR - 1);
    assert_eq!(got.len(), MAX_STATIC_DIR - 1);
    assert!(got.chars().all(|c| c == 'a'));
}

#[test]
fn static_dir_embedded_fallback_when_cwd_missing() {
    reset_for_test();
    unset("FASTAPI_MOJO_STATIC_DIR");
    set_embedded_static_dir(Some("/nonexistent_xyz_static_dir_42"));
    set_static_dir(Some("/another_nonexistent_dir_42"));
    // CWD 不存在且 embedded 也不存在 -> 保留传入 dir (旧行为, 后续 404)
    assert_eq!(get_static_dir(), "/another_nonexistent_dir_42");
    set_embedded_static_dir(None);
}

#[test]
fn static_dir_none_is_noop() {
    reset_for_test();
    unset("FASTAPI_MOJO_STATIC_DIR");
    let before = get_static_dir();
    set_static_dir(None);
    assert_eq!(get_static_dir(), before);
}

// ---------- embedded static dir ----------

#[test]
fn embedded_static_dir_default_empty() {
    reset_for_test();
    assert_eq!(get_embedded_static_dir(), "");
}

#[test]
fn embedded_static_dir_set_and_get() {
    reset_for_test();
    set_embedded_static_dir(Some("/tmp/embed"));
    assert_eq!(get_embedded_static_dir(), "/tmp/embed");
    set_embedded_static_dir(None);
}

#[test]
fn embedded_static_dir_empty_string_ignored() {
    reset_for_test();
    set_embedded_static_dir(Some(""));
    assert_eq!(get_embedded_static_dir(), "");
}

// ---------- last status ----------

#[test]
fn last_status_default_empty() {
    reset_for_test();
    assert_eq!(get_last_status_len(), 0);
    assert_eq!(read_last_status_byte(0), -1);
}

#[test]
fn last_status_set_and_read() {
    reset_for_test();
    set_last_status("200 OK");
    assert_eq!(get_last_status_len(), 6);
    assert_eq!(read_last_status_byte(0), b'2' as i32);
    assert_eq!(read_last_status_byte(5), b'K' as i32);
    assert_eq!(read_last_status_byte(6), -1);
    assert_eq!(read_last_status_byte(100), -1);
}

#[test]
fn last_status_truncates_long_status() {
    reset_for_test();
    let long = "X".repeat(40);
    set_last_status(&long);
    // 截到 MAX_LAST_STATUS - 1 = 31 字节
    assert_eq!(get_last_status_len(), MAX_LAST_STATUS - 1);
}
