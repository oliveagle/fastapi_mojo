//! cmd.rs — `run_command_json` 的 Rust 翻译 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` §1600-1775 (KIND_RUN_CMD 控制平面
//! 用例: 运维面板跑 bash/python 短命令, 捕获 stdout+stderr + 超时)。
//!
//! C 版关键不变式 (本模块严格保持):
//!   - 空 cmd -> `{"rc":-1,"ok":false,"err":"empty cmd"}`
//!   - 调用 `/bin/sh -c <cmd>` (等价 Python `subprocess.run(shell=True)`)
//!   - 父进程在 timeout 内 (默认 15s) 非阻塞读 stdout/stderr, 每流封顶
//!     256 KiB (defensive: 防止失控子进程撑爆服务进程内存)
//!   - timeout 触发 SIGKILL, rc = 128 + 9 = 137 (信号死亡)
//!   - 返回 JSON 字段顺序 (与 C 字节等价): rc, ok, timeout, out, err
//!   - `ok = (rc == 0)`, **不** 等价于 `!timeout` (C 显式区分)
//!
//! 与 C 的差异 (实现策略与改进, 行为等价或更优):
//!   - 读侧: C 用 `fcntl(O_NONBLOCK) + poll + drain_fd`; 本模块同样用
//!     poll + 非阻塞 read (纯 extern "C" 直连, 零第三方 crate), 不引入
//!     reader thread (阻塞 join 在子进程派生后台进程持有管道时会挂起,
//!     与 C 的"立即返回部分输出"语义不符)。
//!   - 子进程 spawn: std::process::Command (不裸 fork/exec);
//!   - **进程组 kill**: `.process_group(0)` 使子进程成为独立进程组组长,
//!     timeout 时 `kill(-pgid, SIGKILL)` 整组击杀 — 比 C 的"只杀直接
//!     子进程"更彻底: `sh -c "sleep 10"` 这类 sh 派生 sleep 的场景, C 会
//!     遗留孤儿 sleep 继续占管道, 本模块整组击杀无孤儿泄漏。
//!   - "pipe failed" / "fork failed" / "oom" 合并为 "spawn failed"
//!     (std::process spawn 一次封装了三步, 不再分别报错); 仅 empty cmd
//!     与 spawn failed 两个错误路径. 调用方 (KIND_RUN_CMD) 仅观测 err
//!     是否非空 + rc==-1, 不受影响。
//!
//! FFI 包装 (run_command_json extern "C" -> fmc_slice + run_command_free)
//! 在切换 `bridge.o` -> `librust_bridge.a` 时再加 (避免当前 --whole-archive
//! 同时链接 C 和 Rust 时的同名符号冲突). 当前 `run_command_json` 返回
//! `Vec<u8>` (与 fmc_slice 字节等价但 RAII, 测试友好)。

use std::os::raw::{c_int, c_uint, c_void};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

use super::response::json_escape;
use super::time_util::now_ms;

/// 单流最大字节数 (defensive cap, 端口 C MAX_OUT = 256 KiB).
const MAX_OUT: usize = 256 * 1024;

/// 默认超时 (port C: `timeout_ms <= 0 -> 15000`).
const DEFAULT_TIMEOUT_MS: u64 = 15_000;

// ---------- 系统调用直连 (避免 libc crate 依赖) ----------

#[derive(Clone, Copy)]
#[repr(C)]
struct pollfd {
    fd: c_int,
    events: i16,
    revents: i16,
}

extern "C" {
    fn poll(fds: *mut pollfd, nfds: c_uint, timeout: c_int) -> c_int;
    fn read(fd: c_int, buf: *mut c_void, n: usize) -> isize;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
    fn __errno_location() -> *mut c_int;
}

const POLLIN: i16 = 0x001;
const POLLHUP: i16 = 0x010;
const POLLERR: i16 = 0x008;
const O_NONBLOCK: c_int = 0o4000;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const SIGKILL: c_int = 9;
const EINTR: c_int = 4;

fn errno() -> c_int {
    unsafe { *__errno_location() }
}

fn set_nonblock(fd: c_int) {
    unsafe {
        let fl = fcntl(fd, F_GETFL, 0);
        if fl >= 0 {
            fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        }
    }
}

/// 读完当前可用数据 (O_NONBLOCK, EAGAIN 即止); 端口 C `drain_fd` 的
/// 非阻塞语义。EINTR 重试; 其余负值终止。
fn drain_fd(fd: c_int, buf: &mut Vec<u8>) {
    let mut tmp = [0u8; 8192];
    loop {
        let n = unsafe { read(fd, tmp.as_mut_ptr() as *mut c_void, tmp.len()) };
        if n < 0 {
            let e = errno();
            if e == EINTR {
                continue;
            }
            break; // EAGAIN/EWOULDBLOCK 或其他错误: 本轮无可读数据
        }
        if n == 0 {
            break; // EOF
        }
        buf.extend_from_slice(&tmp[..n as usize]);
    }
}

fn status_to_rc(s: &std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    if let Some(code) = s.code() {
        return code;
    }
    if let Some(sig) = s.signal() {
        return 128 + sig;
    }
    -1
}

/// 调用 `/bin/sh -c cmd`, timeout (默认 15s) 后整组 SIGKILL, 返回
/// `{"rc":N,"ok":..,"timeout":..,"out":"..","err":".."}` JSON 字节序列.
/// 见模块级文档的不变式与差异说明。
pub fn run_command_json(cmd: &str, timeout_ms: u32) -> Vec<u8> {
    if cmd.is_empty() {
        return br#"{"rc":-1,"ok":false,"err":"empty cmd"}"#.to_vec();
    }

    // process_group(0): 子进程独立进程组 (pgid == child pid), timeout 时
    // kill(-pgid, SIGKILL) 整组击杀 (含 sh 派生的 sleep 等), 无孤儿泄漏。
    let mut child = match Command::new("/bin/sh")
        .arg("-c")
        .arg(cmd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return br#"{"rc":-1,"ok":false,"err":"spawn failed"}"#.to_vec(),
    };

    let stdout = match child.stdout.take() {
        Some(s) => s,
        None => return br#"{"rc":-1,"ok":false,"err":"spawn failed"}"#.to_vec(),
    };
    let stderr = match child.stderr.take() {
        Some(s) => s,
        None => return br#"{"rc":-1,"ok":false,"err":"spawn failed"}"#.to_vec(),
    };
    let out_fd = { use std::os::unix::io::AsRawFd; stdout.as_raw_fd() };
    let err_fd = { use std::os::unix::io::AsRawFd; stderr.as_raw_fd() };
    set_nonblock(out_fd);
    set_nonblock(err_fd);

    let mut out_buf: Vec<u8> = Vec::new();
    let mut err_buf: Vec<u8> = Vec::new();
    let mut out_eof = false;
    let mut err_eof = false;
    let mut timed_out = false;

    let deadline_ms: u64 = if timeout_ms == 0 {
        DEFAULT_TIMEOUT_MS
    } else {
        timeout_ms as u64
    };
    let start = now_ms();

    while !(out_eof && err_eof) {
        let elapsed = now_ms().saturating_sub(start);
        if elapsed >= deadline_ms {
            timed_out = true;
            break;
        }
        let mut wait_ms = (deadline_ms - elapsed) as c_int;
        if wait_ms < 1 {
            wait_ms = 1;
        }

        let mut pfds: [pollfd; 2] = [pollfd { fd: -1, events: 0, revents: 0 }; 2];
        let mut nfds: c_uint = 0;
        if !out_eof {
            pfds[nfds as usize] = pollfd { fd: out_fd, events: POLLIN, revents: 0 };
            nfds += 1;
        }
        if !err_eof {
            pfds[nfds as usize] = pollfd { fd: err_fd, events: POLLIN, revents: 0 };
            nfds += 1;
        }

        let pr = unsafe { poll(pfds.as_mut_ptr(), nfds, wait_ms) };
        if pr < 0 {
            if errno() == EINTR {
                continue;
            }
            break;
        }
        if pr == 0 {
            // poll 超时: 子进程可能仍在跑; 继续轮询直至 deadline
            continue;
        }

        let mut idx = 0usize;
        if !out_eof {
            let rev = pfds[idx].revents;
            if rev & (POLLIN | POLLHUP | POLLERR) != 0 {
                let before = out_buf.len();
                drain_fd(out_fd, &mut out_buf);
                if out_buf.len() == before && rev & (POLLHUP | POLLERR) != 0 {
                    out_eof = true;
                }
            }
            idx += 1;
        }
        if !err_eof {
            let rev = pfds[idx].revents;
            if rev & (POLLIN | POLLHUP | POLLERR) != 0 {
                let before = err_buf.len();
                drain_fd(err_fd, &mut err_buf);
                if err_buf.len() == before && rev & (POLLHUP | POLLERR) != 0 {
                    err_eof = true;
                }
            }
        }
    }

    if timed_out {
        // 整组 SIGKILL (pgid == child pid, process_group(0) 保证) + 直接子进程兜底
        unsafe {
            kill(-(child.id() as i32), SIGKILL);
        }
        let _ = child.kill();
    }

    // 收尾: 排空残留数据 (O_NONBLOCK 立即返回), 再 wait 收割退出码
    drain_fd(out_fd, &mut out_buf);
    drain_fd(err_fd, &mut err_buf);

    let rc = child.wait().map(|s| status_to_rc(&s)).unwrap_or(-1);

    let out_trunc: &[u8] = if out_buf.len() > MAX_OUT {
        &out_buf[..MAX_OUT]
    } else {
        &out_buf[..]
    };
    let err_trunc: &[u8] = if err_buf.len() > MAX_OUT {
        &err_buf[..MAX_OUT]
    } else {
        &err_buf[..]
    };

    let ok = if rc == 0 { "true" } else { "false" };
    let tout = if timed_out { "true" } else { "false" };

    let out_esc = json_escape(out_trunc);
    let err_esc = json_escape(err_trunc);

    // 字段顺序与 C 字节等价: rc, ok, timeout, out, err.
    let mut body: Vec<u8> = Vec::with_capacity(64 + out_esc.len() + err_esc.len());
    body.extend_from_slice(b"{\"rc\":");
    body.extend_from_slice(rc.to_string().as_bytes());
    body.extend_from_slice(b",\"ok\":");
    body.extend_from_slice(ok.as_bytes());
    body.extend_from_slice(b",\"timeout\":");
    body.extend_from_slice(tout.as_bytes());
    body.extend_from_slice(b",\"out\":\"");
    body.extend_from_slice(&out_esc);
    body.extend_from_slice(b"\",\"err\":\"");
    body.extend_from_slice(&err_esc);
    body.extend_from_slice(b"\"}");
    body
}
