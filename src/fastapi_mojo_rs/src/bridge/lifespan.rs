//! lifespan.rs — Lifespan (决策-36, Goal-0003 P1): startup/shutdown 命令 env 读取.
//!
//! FastAPI 语义: `lifespan` 上下文管理器, yield 前 = startup, yield 后 = shutdown;
//! 每进程一次; startup 失败 -> 服务不启动 (进程退出).
//!
//! Mojo 1.0.0 无闭包/async, 声明式替代 = 换行分隔的 shell 命令 env:
//!   - `FASTAPI_MOJO_LIFESPAN_STARTUP`   启动前执行的命令 (换行分隔)
//!   - `FASTAPI_MOJO_LIFESPAN_SHUTDOWN`  停止后执行的命令 (换行分隔)
//!   - `FASTAPI_MOJO_LIFESPAN_TIMEOUT_MS` 单条命令 timeout (默认 30000 ms)
//!
//! 本模块只做 **env 一次性读取 + OnceLock 缓存** (与 state.rs `get_access_log_mode`
//! 同模式); 命令切分/执行/失败短路全部在 Mojo 侧 `lifespan.mojo` (复用
//! `run_command_json` FFI, 决策-34/35 同「Mojo 协议层 + 最小 FFI」分层).
//!
//! 多 worker (ADR-0005, re-exec 模型): worker_id 门控在 Mojo 侧
//! (仅 worker 0 执行, 对齐 nginx master init); 本模块不感知 worker.

use std::sync::OnceLock;

pub const ENV_LIFESPAN_STARTUP: &str = "FASTAPI_MOJO_LIFESPAN_STARTUP";
pub const ENV_LIFESPAN_SHUTDOWN: &str = "FASTAPI_MOJO_LIFESPAN_SHUTDOWN";
pub const ENV_LIFESPAN_TIMEOUT_MS: &str = "FASTAPI_MOJO_LIFESPAN_TIMEOUT_MS";
pub const DEFAULT_LIFESPAN_TIMEOUT_MS: u32 = 30000;

/// 纯逻辑: env 读取 (缺失/空 = 空串 = 无命令). 独立成纯函数便于单测
/// (OnceLock 不可 reset, 直接测 env 全局会污染测试进程).
fn read_env(name: &str) -> String {
    std::env::var(name).unwrap_or_default()
}

/// 纯逻辑: timeout env 解析 (缺失/非法 = 默认 30000).
fn parse_timeout(raw: Option<&str>) -> u32 {
    match raw {
        Some(s) if !s.is_empty() => s.parse::<u32>().unwrap_or(DEFAULT_LIFESPAN_TIMEOUT_MS),
        _ => DEFAULT_LIFESPAN_TIMEOUT_MS,
    }
}

/// startup 命令 (一次性读取 + 缓存). **NUL 终止** (末尾 0 字节).
///
/// 空配置 = `[0]` (单 NUL, len=0 = 无命令).
/// NUL 终止是硬性契约: Mojo `CStringSlice.as_bytes()` 按 C 串语义读到首个
/// NUL (忽略 fmc_slice.len), 无 NUL 会越界读堆垃圾 (决策-36 实测 catch:
/// 命令串被拼接了分配器垃圾 "live"; 同病: run_command_json FFI, 一并修复).
pub fn get_lifespan_startup() -> &'static [u8] {
    static V: OnceLock<Vec<u8>> = OnceLock::new();
    V.get_or_init(|| {
        let mut v = read_env(ENV_LIFESPAN_STARTUP).into_bytes();
        v.push(0);
        v
    })
}

/// shutdown 命令 (一次性读取 + 缓存). **NUL 终止** (契约同 get_lifespan_startup).
pub fn get_lifespan_shutdown() -> &'static [u8] {
    static V: OnceLock<Vec<u8>> = OnceLock::new();
    V.get_or_init(|| {
        let mut v = read_env(ENV_LIFESPAN_SHUTDOWN).into_bytes();
        v.push(0);
        v
    })
}

/// 单条命令 timeout (ms), 一次性读取 + 缓存.
pub fn get_lifespan_timeout_ms() -> u32 {
    static V: OnceLock<u32> = OnceLock::new();
    *V.get_or_init(|| parse_timeout(std::env::var(ENV_LIFESPAN_TIMEOUT_MS).ok().as_deref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_timeout_default_when_none() {
        assert_eq!(parse_timeout(None), DEFAULT_LIFESPAN_TIMEOUT_MS);
    }

    #[test]
    fn parse_timeout_default_when_empty() {
        assert_eq!(parse_timeout(Some("")), DEFAULT_LIFESPAN_TIMEOUT_MS);
    }

    #[test]
    fn parse_timeout_default_when_invalid() {
        assert_eq!(parse_timeout(Some("abc")), DEFAULT_LIFESPAN_TIMEOUT_MS);
        assert_eq!(parse_timeout(Some("-5")), DEFAULT_LIFESPAN_TIMEOUT_MS);
        assert_eq!(
            parse_timeout(Some("99999999999999")),
            DEFAULT_LIFESPAN_TIMEOUT_MS
        );
    }

    #[test]
    fn parse_timeout_valid() {
        assert_eq!(parse_timeout(Some("5000")), 5000);
        assert_eq!(parse_timeout(Some("1")), 1);
    }

    #[test]
    fn read_env_missing_is_empty() {
        // 唯一名: 不污染 FASTAPI_MOJO_* 真实配置, 可安全 set/unset (单线程约定).
        let name = "FASTAPI_MOJO_TEST_LS_PROBE_XYZ";
        std::env::remove_var(name);
        assert_eq!(read_env(name), "");
    }

    #[test]
    fn read_env_set_value() {
        let name = "FASTAPI_MOJO_TEST_LS_PROBE_ABC";
        std::env::set_var(name, "cmd1\ncmd2");
        assert_eq!(read_env(name), "cmd1\ncmd2");
        std::env::remove_var(name);
    }

    #[test]
    fn env_names_stable() {
        // env 名是部署契约 (文档/CI 依赖), 钉死.
        assert_eq!(ENV_LIFESPAN_STARTUP, "FASTAPI_MOJO_LIFESPAN_STARTUP");
        assert_eq!(ENV_LIFESPAN_SHUTDOWN, "FASTAPI_MOJO_LIFESPAN_SHUTDOWN");
        assert_eq!(
            ENV_LIFESPAN_TIMEOUT_MS,
            "FASTAPI_MOJO_LIFESPAN_TIMEOUT_MS"
        );
    }
}
