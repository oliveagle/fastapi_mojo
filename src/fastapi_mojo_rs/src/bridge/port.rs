//! port.rs — listen port 解析 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` `get_configured_port()` (§306-348):
//!   1) env `FASTAPI_MOJO_PORT` (合法范围 1..65536)
//!   2) CLI `/proc/self/cmdline` NUL 分隔: `--port N` 或 `--port=N` (env 覆盖)
//!   3) default 8000
//!
//! 与 C 的差异 (表达层, 语义等价):
//!   - cmdline 输入为 `&[u8]` (NUL 分隔), 由调用方从 /proc/self/cmdline 读
//!     或测试注入; 不在本模块内做 IO, 保持纯函数 + 单测友好.
//!   - `Option<String>` / `Option<&[u8]>` 取代 C 指针 + atoi 的隐式失败路径.

/// 默认端口 (端口 C `get_configured_port` 默认 8000).
pub const DEFAULT_PORT: u16 = 8000;

/// 端口合法范围 (端口 C 检查 `v > 0 && v < 65536`, i.e. 1..65535).
pub const MIN_PORT: u16 = 1;
pub const MAX_PORT: u16 = 65535;

/// 解析 cmdline 字节流 (NUL 分隔的 argv, 来自 `/proc/self/cmdline`) 中的
/// `--port N` / `--port=N`。返回首个合法端口, 否则返回 `None`。
///
/// 与 C 行为字节等价:
///   - NUL 分隔遍历; 每段超过 256 字节截断丢弃 (匹配 C `arg[256]` 上限)
///   - `--port` 后必须是独立下一段; `--port=` 内嵌值
///   - 首个合法端口胜出, 后续忽略
pub fn parse_cmdline_port(cmdline: &[u8]) -> Option<u16> {
    let mut iter = cmdline.split(|&b| b == 0);
    let mut pending_port = false;
    for arg in iter.by_ref() {
        if arg.is_empty() {
            // C 不在空段重置 pending_port (段 alen=0 时整个 if 块跳过);
            // 若上一段是 "--port", 下一段触发 `if pending_port` 分支直接解析
            // (C 的语义, 含边界 case: cmdline=["--port","","9001"] -> 解析 9001).
            continue;
        }
        if pending_port {
            // arg 是 --port 的下一个段; 尝试解析
            if let Some(p) = parse_port_bytes(arg) {
                return Some(p);
            }
            // 解析失败: C 行为是 `break` (不再继续找), 这里也一致
            return None;
        }
        if arg == b"--port" {
            pending_port = true;
            continue;
        }
        if let Some(rest) = arg.strip_prefix(b"--port=") {
            if let Some(p) = parse_port_bytes(rest) {
                return Some(p);
            }
            return None;
        }
    }
    None
}

pub fn parse_port_bytes(b: &[u8]) -> Option<u16> {
    if b.is_empty() {
        return None;
    }
    let mut v: u32 = 0;
    for &c in b {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as u32)?;
    }
    if !(MIN_PORT as u32..=MAX_PORT as u32).contains(&v) {
        return None;
    }
    Some(v as u16)
}

/// 端口解析主入口 (端口 C `get_configured_port()` 的语义):
///   1) CLI `--port N` / `--port=N` 优先 (无论 env 是否存在)
///   2) env `FASTAPI_MOJO_PORT`
///   3) DEFAULT_PORT (8000)
pub fn resolve_port(cmdline: &[u8], env_value: Option<&[u8]>) -> u16 {
    if let Some(p) = parse_cmdline_port(cmdline) {
        return p;
    }
    if let Some(v) = env_value {
        if let Some(p) = parse_port_bytes(v) {
            return p;
        }
    }
    DEFAULT_PORT
}

/// 从真实进程环境解析当前端口: 读 `/proc/self/cmdline` + `FASTAPI_MOJO_PORT`
/// env. 端口 C `get_configured_port()` 的完整行为 (§306-348).
/// 供 `init_workers` re-exec 子进程时拼接 `--port` 参数。
pub fn current_configured_port() -> u16 {
    let cmdline = std::fs::read("/proc/self/cmdline").unwrap_or_default();
    let env_value = std::env::var("FASTAPI_MOJO_PORT").ok();
    resolve_port(&cmdline, env_value.as_deref().map(|s| s.as_bytes()))
}
