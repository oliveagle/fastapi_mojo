//! time_util.rs — wall-clock millisecond timer (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` `gettimeofday_ms()` (§230-233):
//!   `tv_sec * 1000 + tv_usec / 1000` (单调非真; NTP 跳变可见)。
//!
//! 提供 `now_ms()` 给以下模块复用:
//!   - `cmd::run_command_json` (子进程超时/截止)
//!   - `port::get_configured_port` (cdebug 时间戳, 未来)
//!   - 未来 `signals` / `conn` 状态机的 deadline 计算
//!
//! 与 C 的差异:
//!   - 用 std::time::SystemTime + UNIX_EPOCH, 避免 libc crate 依赖;
//!   - `as u64` 截断 64 位以上的毫秒 (约 5.8 亿年, 远超 server 寿命)。

use std::time::{SystemTime, UNIX_EPOCH};

/// Wall-clock 毫秒 (与 C `gettimeofday_ms` 字节等价: 自 UNIX_EPOCH 起)。
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
