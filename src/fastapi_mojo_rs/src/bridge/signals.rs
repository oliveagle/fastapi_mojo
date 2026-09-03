//! signals.rs — 优雅关停信号处理 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` `setup_signal_handlers()`
//! / `signal_handler()` / `is_running()` (§184-202):
//!   - SIGINT / SIGTERM -> 处理器置 `g_running = 0`, poll 循环下次回到顶部
//!     检查 `is_running()` 时返回 0, 主循环 `break` 后 exit(0)。
//!   - SIGPIPE -> SIG_IGN, send() 写已关闭客户端返回 EPIPE 而非杀进程。
//!
//! 与 C 的差异 (表达层 + 安全):
//!   - 用 `AtomicI32` (Relaxed store) 代替 `volatile int` (数据竞争更安全);
//!   - `setup_signal_handlers()` 幂等 (`OnceBool` 守卫), 多次调用无副作用;
//!   - `server_shutdown()` 显式置 0, 用于测试 + 优雅关停触发;
//!   - **不导出 FFI** (与 `bridge.o` 同名符号冲突); 切换 build 时再加
//!     `#[no_mangle] extern "C" fn setup_signal_handlers/is_running` 包装。
//!
//! 并发 / 测试注意:
//!   - 信号处理是**进程范围**的; 处理器只读/写 `G_RUNNING`, 不访问其它
//!     全局状态, 跨线程/跨测试安全 (AtomicI32 Relaxed 序)。
//!   - **会真发信号的测试** (用 `raise(SIGTERM)`) 标记 `#[ignore]`,
//!     需用 `cargo test --release -- --ignored --test-threads=1` 单独跑;
//!     默认 `cargo test` 只跑无信号触发的 API 单元测试 (handler/is_running
//!     /server_shutdown/幂等性), 与其它并发测试无干扰。

use std::os::raw::c_int;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

// ========== 系统调用直连 ==========
extern "C" {
    fn sigaction(signum: c_int, act: *const sigaction_t, oldact: *mut sigaction_t) -> c_int;
    // `raise` 仅被 #[cfg(test)] 的信号测试使用; 非测试构建不引用, 避免 dead_code.
    #[cfg(test)]
    fn raise(signum: c_int) -> c_int;
    fn getpid() -> c_int;
}

const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const SIGPIPE: c_int = 13;

// glibc sigset_t: 16 * u64 = 128 字节. 编译期断言确保 layout 与 C 一致.
#[repr(C)]
#[derive(Clone, Copy)]
struct sigset_t {
    val: [u64; 16],
}

// glibc x86_64 sigaction: 8(handler) + 128(mask) + 4(flags) + 8(restorer) = 152B
#[repr(C)]
#[derive(Clone, Copy)]
struct sigaction_t {
    sa_handler: Option<extern "C" fn(c_int)>,
    sa_mask: sigset_t,
    sa_flags: c_int,
    sa_restorer: Option<extern "C" fn()>,
}

// 编译期 layout 校验 (与 C x86_64 glibc sigaction 字节布局等价)
const _: [(); 152] = [(); std::mem::size_of::<sigaction_t>()];

// SIG_IGN = (sighandler_t)1 in glibc (稳定约定, Linux only).
// transmute 是 unsafe 但 glibc 文档化此约定; 用一次常量化避免散落。
const SIG_IGN_PTR: usize = 1;
fn sig_ign() -> Option<extern "C" fn(c_int)> {
    unsafe { Some(std::mem::transmute::<usize, extern "C" fn(c_int)>(SIG_IGN_PTR)) }
}

// ========== 模块状态 ==========

/// 服务运行标志 (1 = 运行中, 0 = 收到关停信号 / 显式关闭). 单进程多线程
/// 安全 (AtomicI32 Relaxed, 处理器与 poll 循环跨线程读写).
static G_RUNNING: AtomicI32 = AtomicI32::new(1);

/// setup_signal_handlers 幂等守卫 (避免重复 sigaction).
static SIGNALS_INSTALLED: AtomicBool = AtomicBool::new(false);

/// SIGINT/SIGTERM 处理器: 收到关停信号 -> 置 G_RUNNING = 0. poll 循环下次
/// 回到顶部检查 is_running() 即退出. 不访问任何其它全局 (异步信号安全)。
extern "C" fn shutdown_handler(_sig: c_int) {
    G_RUNNING.store(0, Ordering::Relaxed);
}

/// 安装 SIGINT/SIGTERM 处理器 + SIGPIPE 忽略. 幂等: 已安装则 no-op.
/// 返回是否本次**首次**安装 (供测试断言).
pub fn setup_signal_handlers() -> bool {
    // sigaction 三次: SIGINT, SIGTERM 各装 shutdown_handler; SIGPIPE 装 SIG_IGN.
    // 用空 mask (memset 0): 不阻塞其它信号。
    let mut sa: sigaction_t = sigaction_t {
        sa_handler: Some(shutdown_handler),
        sa_mask: sigset_t { val: [0u64; 16] },
        sa_flags: 0,
        sa_restorer: None,
    };
    let installed = !SIGNALS_INSTALLED.swap(true, Ordering::Relaxed);
    if !installed {
        return false; // 幂等: 已安装, 不重复 sigaction
    }
    unsafe {
        if sigaction(SIGINT, &sa, std::ptr::null_mut()) != 0 {
            SIGNALS_INSTALLED.store(false, Ordering::Relaxed);
            return false;
        }
        if sigaction(SIGTERM, &sa, std::ptr::null_mut()) != 0 {
            SIGNALS_INSTALLED.store(false, Ordering::Relaxed);
            return false;
        }
        // SIGPIPE: SIG_IGN, send() 写已关闭客户端返回 EPIPE 而非杀进程.
        sa.sa_handler = sig_ign();
        if sigaction(SIGPIPE, &sa, std::ptr::null_mut()) != 0 {
            SIGNALS_INSTALLED.store(false, Ordering::Relaxed);
            return false;
        }
    }
    true
}

/// 当前运行标志 (1 = 仍在跑, 0 = 应当退出). poll 循环每轮迭代顶部调用.
pub fn is_running() -> bool {
    G_RUNNING.load(Ordering::Relaxed) != 0
}

/// 显式请求关停 (C 中对应 poll 循环顶部对 g_running 的检查; 也用于测试).
pub fn server_shutdown() {
    G_RUNNING.store(0, Ordering::Relaxed);
}

/// 当前 G_RUNNING 原始值 (供测试 / 调试). **不要**用于业务判断 (用
/// `is_running()` 替代).
pub fn raw_running() -> i32 {
    G_RUNNING.load(Ordering::Relaxed)
}

/// 重置 G_RUNNING = 1 (仅用于测试, 不暴露给业务路径).
#[cfg(test)]
pub(crate) fn reset_running_for_test() {
    G_RUNNING.store(1, Ordering::Relaxed);
}

/// 进程 PID (extern "C" getpid 直接调用, 避免 libc crate 依赖).
pub fn get_pid() -> i32 {
    unsafe { getpid() }
}

/// raise(signum) (extern "C" 直接调用). 用于信号测试.
#[cfg(test)]
pub(crate) fn raise_signal(signum: c_int) -> i32 {
    unsafe { raise(signum) }
}

/// 测试专用: 直接调用 SIGINT/SIGTERM 处理器 (避免 raise() 干扰进程级
/// 信号状态). 等价于收到关停信号但不真触发信号.
#[cfg(test)]
pub(crate) fn invoke_shutdown_handler(sig: c_int) {
    shutdown_handler(sig);
}

/// 测试专用: 暴露 SIG_IGN 指针形态 (用于 SIGPIPE 忽略).
#[cfg(test)]
pub(crate) fn sig_ign_for_test() -> Option<extern "C" fn(c_int)> {
    sig_ign()
}
