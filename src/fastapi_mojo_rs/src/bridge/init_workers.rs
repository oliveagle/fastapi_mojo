//! init_workers.rs — 多进程 worker 启动 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` `init_workers()` / `get_worker_id()`
//! (§259-303, ADR-0005):
//!   - `FASTAPI_MOJO_WORKERS=N` (默认 1, 单进程): N <= 1 时直接返回.
//!   - `FASTAPI_MOJO_WORKER=i` 已设置 (已由 spawner fork 出来): 记录我的 id,
//!     直接返回 (子进程路径).
//!   - 否则我是 spawner (worker 0): `setenv(FASTAPI_MOJO_WORKER, "0")`,
//!     `readlink /proc/self/exe`, 对 i=1..N-1 fork 子进程, 每个 execv 自己
//!     传递 `--port <port>`. execv 失败 -> `_exit(127)`.
//!
//! 关键不变式:
//!   - 单进程假定下 G_WORKER_ID 是 AtomicI32 (单线程写读).
//!   - **不** 在 init_workers 中调 setenv/restore env (会污染环境); 只设一次
//!     "FASTAPI_MOJO_WORKER=0", 子进程继承并覆盖为各自 id.
//!   - spawner 不 wait 子进程: nginx pre-fork 模型, 各自独立被 init_signal
//!     接管; 主进程不需追踪子进程退出 (signal handler 不带 reap).
//!
//! 与 C 的差异:
//!   - `WorkerMode` 枚举化三态 (Single/Worker/Spawner), 便于单测不真 fork
//!   - 进程 exec 走 extern "C" 直接调 (fork/execv/readlink/setenv/_exit),
//!     不引入 libc crate
//!   - 真实 fork 部分 `#[cfg(test)]` 隔离 (parallel cargo test 兼容性);
//!     `worker_mode` 纯逻辑部分全套单测.
//!
//! FFI 包装延迟: 同 signals.rs, 待 `bridge.o` 下线时统一加.

use std::os::raw::{c_char, c_int};
use std::sync::atomic::{AtomicI32, Ordering};

use super::port::current_configured_port;

static G_WORKER_ID: AtomicI32 = AtomicI32::new(0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerMode {
    /// `FASTAPI_MOJO_WORKERS` 未设 / <= 1, 单进程.
    Single,
    /// 已是 fork 出来的子进程, `FASTAPI_MOJO_WORKER=<id>` 给出了我的 id.
    Worker(i32),
    /// 主进程 (worker 0), 需要 fork `n - 1` 个子进程.
    Spawner(i32),
}

/// 纯逻辑: 根据 env 推导 WorkerMode (不真读 env, 参数注入便于测试).
/// 端口 C `init_workers` §263-275 的 env 解析路径, 字节等价.
pub fn worker_mode(workers_env: Option<&str>, worker_env: Option<&str>) -> WorkerMode {
    let n: i32 = workers_env
        .filter(|s| !s.is_empty())
        .and_then(|s| s.parse().ok())
        .unwrap_or(1);
    if n <= 1 {
        return WorkerMode::Single;
    }
    if let Some(w) = worker_env.filter(|s| !s.is_empty()) {
        if let Ok(id) = w.parse::<i32>() {
            return WorkerMode::Worker(id);
        }
    }
    WorkerMode::Spawner(n)
}

pub fn get_worker_id() -> i32 {
    G_WORKER_ID.load(Ordering::Relaxed)
}

#[cfg(test)]
pub(crate) fn set_worker_id_for_test(id: i32) {
    G_WORKER_ID.store(id, Ordering::Relaxed);
}

// ========== 系统调用直连 ==========
extern "C" {
    fn fork() -> c_int;
    fn execv(path: *const c_char, argv: *mut *mut c_char) -> c_int;
    fn readlink(path: *const c_char, buf: *mut c_char, bufsz: usize) -> isize;
    fn _exit(status: c_int) -> !;
    fn setenv(name: *const c_char, value: *const c_char, overwrite: c_int) -> c_int;
}

/// init_workers 主入口: 调用后, G_WORKER_ID 反映当前进程的 worker id.
/// Single / Worker 模式无副作用 (单进程或子进程); Spawner 模式会 fork.
/// `pid_of_each_child` (返回): 如有, 填每个子进程的 pid (顺序, 长度 = n-1).
pub fn init_workers() -> Vec<i32> {
    let mode = worker_mode(
        std::env::var("FASTAPI_MOJO_WORKERS").ok().as_deref(),
        std::env::var("FASTAPI_MOJO_WORKER").ok().as_deref(),
    );
    match mode {
        WorkerMode::Single => {
            G_WORKER_ID.store(0, Ordering::Relaxed);
            Vec::new()
        }
        WorkerMode::Worker(id) => {
            G_WORKER_ID.store(id, Ordering::Relaxed);
            Vec::new()
        }
        WorkerMode::Spawner(n) => spawn_workers(n),
    }
}

fn spawn_workers(n: i32) -> Vec<i32> {
    G_WORKER_ID.store(0, Ordering::Relaxed);
    // 把自己标记为 worker 0, 子进程继承覆盖.
    unsafe {
        let k = std::ffi::CString::new("FASTAPI_MOJO_WORKER").unwrap();
        let v = std::ffi::CString::new("0").unwrap();
        setenv(k.as_ptr(), v.as_ptr(), 1);
    }

    let port = current_configured_port();
    let port_str = port.to_string();

    let exe = read_proc_self_exe();
    if exe.is_empty() {
        return Vec::new(); // readlink 失败: C 行为是 `return`, 不 fork
    }

    let mut pids = Vec::with_capacity((n - 1).max(0) as usize);
    for i in 1..n {
        let pid = unsafe { fork() };
        if pid < 0 {
            break; // fork 失败: C 行为 break, 用更少 worker 继续
        }
        if pid == 0 {
            // 子进程: 设 env, execv
            let wstr = i.to_string();
            unsafe {
                let k = std::ffi::CString::new("FASTAPI_MOJO_WORKER").unwrap();
                let v = std::ffi::CString::new(wstr).unwrap();
                setenv(k.as_ptr(), v.as_ptr(), 1);

                let exe_c = std::ffi::CString::new(exe.clone()).unwrap();
                let port_c = std::ffi::CString::new(port_str.clone()).unwrap();
                let arg_port = std::ffi::CString::new("--port").unwrap();
                // argv[0] = exe, argv[1] = "--port", argv[2] = port_str, argv[3] = NULL
                let mut argv: [*mut c_char; 4] = [
                    exe_c.as_ptr() as *mut c_char,
                    arg_port.as_ptr() as *mut c_char,
                    port_c.as_ptr() as *mut c_char,
                    std::ptr::null_mut(),
                ];
                execv(exe_c.as_ptr(), argv.as_mut_ptr());
                _exit(127); // execv 失败
            }
        }
        pids.push(pid);
    }
    pids
}

fn read_proc_self_exe() -> String {
    let path = std::ffi::CString::new("/proc/self/exe").unwrap();
    let mut buf = vec![0u8; 1024];
    let n = unsafe { readlink(path.as_ptr(), buf.as_mut_ptr() as *mut c_char, buf.len() - 1) };
    if n <= 0 {
        return String::new();
    }
    buf.truncate(n as usize);
    String::from_utf8_lossy(&buf).into_owned()
}
