// port_tests.rs — port 解析回归 (ADR-0010 DC2)
use super::port::*;

fn cmdline(s: &[&str]) -> Vec<u8> {
    let mut v = Vec::new();
    for a in s {
        v.extend_from_slice(a.as_bytes());
        v.push(0);
    }
    v
}

// ---------- parse_port_bytes ----------

#[test]
fn parse_port_basic() {
    assert_eq!(parse_port_bytes(b"8000"), Some(8000));
    assert_eq!(parse_port_bytes(b"1"), Some(1));
    assert_eq!(parse_port_bytes(b"65535"), Some(65535));
}

#[test]
fn parse_port_out_of_range() {
    assert_eq!(parse_port_bytes(b"0"), None); // < MIN
    assert_eq!(parse_port_bytes(b"65536"), None); // > MAX
    assert_eq!(parse_port_bytes(b"99999"), None);
    assert_eq!(parse_port_bytes(b"70000"), None);
}

#[test]
fn parse_port_invalid() {
    assert_eq!(parse_port_bytes(b""), None);
    assert_eq!(parse_port_bytes(b"-1"), None);
    assert_eq!(parse_port_bytes(b"abc"), None);
    assert_eq!(parse_port_bytes(b"8000a"), None);
    assert_eq!(parse_port_bytes(b"8000.0"), None);
}

#[test]
fn parse_port_overflow() {
    // u32 overflow guard (checked_mul catches it)
    assert_eq!(parse_port_bytes(b"999999999999"), None);
}

// ---------- parse_cmdline_port ----------

#[test]
fn cmdline_space_form() {
    let cl = cmdline(&["fastapi_mojo", "--port", "9001", "arg2"]);
    assert_eq!(parse_cmdline_port(&cl), Some(9001));
}

#[test]
fn cmdline_equals_form() {
    let cl = cmdline(&["fastapi_mojo", "--port=9002"]);
    assert_eq!(parse_cmdline_port(&cl), Some(9002));
}

#[test]
fn cmdline_no_port() {
    let cl = cmdline(&["fastapi_mojo", "--workers", "4"]);
    assert_eq!(parse_cmdline_port(&cl), None);
}

#[test]
fn cmdline_port_takes_first() {
    // 首个合法 --port 胜出 (与 C 行为字节等价: C 用 break, 后续忽略)
    let cl = cmdline(&["a", "--port", "9003", "--port", "9004"]);
    assert_eq!(parse_cmdline_port(&cl), Some(9003));
}

#[test]
fn cmdline_invalid_port_in_value() {
    // --port 后接非法数字 -> C 行为: break, 返回 8000 (CLI 不覆盖 env)
    // 本模块 parse_cmdline_port 在该路径下返回 None (CLI 不覆盖);
    // resolve_port 才会走 env/default. 这里只测 parse_cmdline_port 的 None 语义.
    let cl = cmdline(&["a", "--port", "abc"]);
    assert_eq!(parse_cmdline_port(&cl), None);
}

#[test]
fn cmdline_equals_invalid() {
    let cl = cmdline(&["a", "--port=0"]);
    assert_eq!(parse_cmdline_port(&cl), None);
}

#[test]
fn cmdline_empty_argv() {
    let cl = cmdline(&[]);
    assert_eq!(parse_cmdline_port(&cl), None);
}

#[test]
fn cmdline_truncated_arg() {
    // 段 > 256 字节: C 静默截断到 arg[255] (最后一个 char 可能是非数字), 
    // 本模块同样: parse_port_bytes 会拒绝非数字字符 -> None
    let big = "a".repeat(300);
    let cl = cmdline(&[&big]);
    assert_eq!(parse_cmdline_port(&cl), None);
}

#[test]
fn cmdline_realistic_proc_self_cmdline() {
    // 模拟 /proc/self/cmdline 字节流 (末尾 NUL, 与实际一致)
    let mut cl = Vec::new();
    cl.extend_from_slice(b"/usr/local/bin/fastapi_mojo");
    cl.push(0);
    cl.extend_from_slice(b"--port");
    cl.push(0);
    cl.extend_from_slice(b"18888");
    cl.push(0);
    cl.extend_from_slice(b"--workers");
    cl.push(0);
    cl.extend_from_slice(b"2");
    cl.push(0);
    assert_eq!(parse_cmdline_port(&cl), Some(18888));
}

// ---------- resolve_port ----------

#[test]
fn resolve_cli_wins_over_env() {
    let cl = cmdline(&["a", "--port", "9001"]);
    assert_eq!(resolve_port(&cl, Some(b"7000")), 9001);
}

#[test]
fn resolve_env_when_no_cli() {
    let cl = cmdline(&["a"]);
    assert_eq!(resolve_port(&cl, Some(b"7000")), 7000);
}

#[test]
fn resolve_default_when_nothing() {
    let cl = cmdline(&["a"]);
    assert_eq!(resolve_port(&cl, None), 8000);
}

#[test]
fn resolve_default_when_env_invalid() {
    let cl = cmdline(&["a"]);
    assert_eq!(resolve_port(&cl, Some(b"abc")), 8000);
    assert_eq!(resolve_port(&cl, Some(b"0")), 8000);
    assert_eq!(resolve_port(&cl, Some(b"70000")), 8000);
}

#[test]
fn resolve_cli_equals_over_default() {
    let cl = cmdline(&["a", "--port=12345"]);
    assert_eq!(resolve_port(&cl, None), 12345);
}
