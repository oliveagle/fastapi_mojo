//! bridge/io.rs — I/O 主体 (ADR-0010 DC2 Step A).
//!
//! 行为等价 `http_bridge_final.c` 的 I/O 主路径 (§820-1185):
//!   - `pump_conn`            phase 0/1 状态机 (§962-1020) + phase 3 委托
//!   - `pump_ws_conn`         WS 帧分派 (§867-940, 尾块重放 + 控制帧)
//!   - `ws_pump_close`        WS 结束 (§859-865, 尽力 close + 入队 + 关 conn)
//!   - `ws_pump_now`          Mojo 处理完一条消息立即重 pump (§942-947)
//!   - `check_deadlines`      每连接超时 + 保活 (§1028-1067, 走 deadlines::decide)
//!   - `conn_done`            复用 / 关闭 conn (§1170-1180, body 释放 + phase 0)
//!   - `recv_and_parse`       master event loop (§1067-1170, WS 事件优先 + poll)
//!   - `shutdown_all`         关 listen + 所有 conn (§1180-1185, 测试 / 显式清理)
//!
//! 与 C 的差异 (语义等价 + Rust 安全):
//!   - **所有跨 Mutex 调用都用 `{ let g = lock; ... }` 显式 scope drop**:
//!     避免 Mutex 非 reentrant 自死锁 (已在 request.rs / ws_session_ffi.rs
//!     应用 + 教训文档化).
//!   - 系统调用 `recv/accept/poll/send/close` 用 `extern "C"` 直连; 不引 libc crate.
//!   - conn 表/事件队列复用 `bridge::conn::{conn_table, ws_events}` (DC2 已落地).
//!   - **单元测试里 sys_close 走 no-op** (继承 `conn::Conn::reset_for_close`),
//!     fd 合成 (101+) 永不撞 libtest 捕获管道.
//!   - 监听 fd 全局 `G_LISTEN_FD` AtomicI32 (端口 C `g_listen_fd` long); 启动时
//!     `set_listen_fd`, `shutdown_all` 时 `clear_listen_fd`.
//!
//! **未含 (DC3 待办)**: `extern "C"` FFI 包装层 (recv_and_parse / pump_ws_conn 等),
//! 按 ADR-0010 §3 决策-4 「FFI 包装延迟」约束, 待 `bridge.o` 下线那一 turn
//! 统一加, 避免当前 `--whole-archive` 同时链接 C 与 Rust 时的同名符号冲突.
//!
//! reasm buffer 内存模型:
//!   - Conn.ws_reasm 永远是 `vec![0u8; n]` (len == capacity == n);
//!     ws_parser_feed 的 reasm_cap = c.ws_reasm.capacity().
//!   - 翻倍 (rc == -2): new Vec cap = min(cap*2, MAX_BODY+1), 旧内容整体
//!     copy (Vec 字节都是 u8, 旧 buffer 全 [0u8; cap] 初始化, 含已写入数据
//!     与未使用零字节); parser 内部 p.reasm_len 保留, 重喂尾块后继续写.

use std::os::raw::{c_int, c_uint, c_void};
use std::sync::atomic::{AtomicI32, Ordering};

use super::conn::{
    conn_table, ws_events, MAX_CONNS, HDR_BUF_SIZE, MAX_BODY,
    WS_TAIL_MAX, WS_REASM_INIT, WS_EV_MSG, WS_EV_END,
};
use super::conn::deadlines::{decide, DeadlineAction};
use super::conn::parse::finish_header;
use super::parse as bridge_parse;
use super::request::{set_http_fields, set_ws_event_type};
use super::send::{send_all, send_error_json};
use super::signals::is_running;
use super::socket::setup_conn_fd;
use super::state::{get_idle_max_ms, get_max_body_size, get_max_request_ms, get_recv_timeout_ms};
use super::time_util::now_ms;
use super::ws_session_ffi::{get_ws_ping_max, ws_send_close};
use crate::bridge::conn::Conn;
use crate::ws::{ws_parser_feed, ws_reply_close_buf, ws_write_message};

// ========== Linux 常量 ==========
const MSG_DONTWAIT: c_int = 0x40;
const EAGAIN: c_int = 11;
const EWOULDBLOCK: c_int = 11;
const EINTR: c_int = 4;
const POLLIN: i16 = 0x001;
const POLLHUP: i16 = 0x010;
const POLLERR: i16 = 0x008;
const POLL_TICK_MS: c_int = 1000;
/// pollfd 数组大小 = 1 (listen) + MAX_CONNS (1024). 端口 C `static struct pollfd pf[1 + MAX_CONNS]`.
const POLL_NFDS: usize = 1 + MAX_CONNS;
const HUNDRED_CONTINUE: &[u8] = b"HTTP/1.1 100 Continue\r\n\r\n";

// ========== listen fd 全局 (端口 C `static long g_listen_fd = -1`) ==========
static G_LISTEN_FD: AtomicI32 = AtomicI32::new(-1);

/// 设置/重置监听 fd (启动 create_bound_socket 后调用).
pub fn set_listen_fd(fd: i32) {
    G_LISTEN_FD.store(fd, Ordering::Release);
}

/// 当前监听 fd (-1 = 未设置).
pub fn get_listen_fd() -> i32 {
    G_LISTEN_FD.load(Ordering::Acquire)
}

/// 清空监听 fd (shutdown_all 时).
pub fn clear_listen_fd() {
    G_LISTEN_FD.store(-1, Ordering::Release);
}

// ========== 系统调用直连 (零 libc crate) ==========
extern "C" {
    fn recv(fd: c_int, buf: *mut c_void, len: usize, flags: c_int) -> isize;
    fn close(fd: c_int) -> c_int;
    fn poll(fds: *mut pollfd_t, nfds: c_uint, timeout: c_int) -> c_int;
    fn accept(fd: c_int, addr: *mut c_void, addrlen: *mut u32) -> c_int;
    fn __errno_location() -> *mut c_int;
}

/// `struct pollfd` Linux x86_64 layout (fd: c_int + events: i16 + revents: i16 = 8B).
#[repr(C)]
#[derive(Clone, Copy)]
struct pollfd_t {
    fd: c_int,
    events: i16,
    revents: i16,
}

const _: [(); 8] = [(); std::mem::size_of::<pollfd_t>()];

#[inline(always)]
fn errno() -> c_int {
    // SAFETY: __errno_location() 返回线程局部 errno 指针.
    unsafe { *__errno_location() }
}

/// Non-blocking recv (MSG_DONTWAIT). 返回:
///   >0  : 读到的字节数
///    0  : EOF (对端关闭)
///   -1  : EAGAIN/EWOULDBLOCK (spurious); 调用方应 return 0
///   -2  : 其它错误 (ECONNRESET 等); 调用方应 close
fn sys_recv(fd: i32, buf: &mut [u8]) -> i32 {
    let n = unsafe {
        recv(fd, buf.as_mut_ptr() as *mut c_void, buf.len(), MSG_DONTWAIT)
    };
    if n > 0 {
        return n as i32;
    }
    if n == 0 {
        return 0;
    }
    let e = errno();
    if e == EAGAIN || e == EWOULDBLOCK {
        return -1;
    }
    -2
}

/// Non-blocking accept. 返回:
///   >=0 : 新 conn fd
///   -1  : EAGAIN/EWOULDBLOCK (无 pending)
///   -2  : 其它错误
fn sys_accept(fd: i32) -> i32 {
    // sockaddr_in 16B (Linux x86_64); addrlen in/out 都用 16.
    let mut addr = [0u8; 16];
    let mut addrlen: u32 = 16;
    let cfd = unsafe {
        accept(fd, addr.as_mut_ptr() as *mut c_void, &mut addrlen as *mut u32)
    };
    if cfd >= 0 {
        return cfd;
    }
    let e = errno();
    if e == EAGAIN || e == EWOULDBLOCK {
        return -1;
    }
    -2
}

/// poll syscall 直连. 返回 poll() 原生返回值 (nready, 0=timeout, -1=err).
fn sys_poll(fds: &mut [pollfd_t], timeout_ms: c_int) -> i32 {
    unsafe { poll(fds.as_mut_ptr(), fds.len() as c_uint, timeout_ms) }
}

fn send_100_continue(fd: i32) {
    let _ = send_all(fd, HUNDRED_CONTINUE);
}

/// 把 `finish_header` 的纯逻辑结果落到 Conn 上, 并更新 request globals.
/// 返回 1 = request 已就绪 (phase 2), 0 = 仍需 body (phase 1), -1 = 已关闭.
fn apply_request_header(c: &mut Conn, hdr: super::conn::parse::RequestHeader) -> i32 {
    c.cl = hdr.content_length;
    c.first_data_ms = now_ms() as i64;
    c.last_data_ms = c.first_data_ms;

    // 0 body: phase 2 立刻就绪
    if hdr.content_length == 0 {
        c.body.clear();
        c.body_got = 0;
        c.phase = 2;
        set_http_fields(
            &hdr.method,
            &hdr.path,
            &hdr.query,
            hdr.protocol_11,
            hdr.close_after_response,
            c.fd,
        );
        return 1;
    }

    // 非 0 body: 分配 c.body (Vec<u8>, 等价 C malloc(cl+1))
    // ⚠️ Vec::with_capacity(n) 后 len=0 (踩坑教训); 用 resize 强制 len = content_length.
    c.body.resize(hdr.content_length, 0u8);
    c.body_got = hdr.body_got.min(hdr.content_length);

    // 已随 header 到达的 body 字节 (pipelining 已被 C 丢弃; 这里按 C 行为字节等价).
    if c.body_got > 0 {
        // body 来自 c.hdr[hdr_end..c.hdr_total].
        if let Some(hdr_end) = bridge_parse::find_header_end(&c.hdr[..c.hdr_total]) {
            c.body[..c.body_got].copy_from_slice(&c.hdr[hdr_end..hdr_end + c.body_got]);
        }
    }

    // 写 request globals
    set_http_fields(
        &hdr.method,
        &hdr.path,
        &hdr.query,
        hdr.protocol_11,
        hdr.close_after_response,
        c.fd,
    );

    if c.body_got >= hdr.content_length {
        // body 已齐: UTF-8 校验
        if !bridge_parse::utf8_valid(&c.body[..c.body_got]) {
            send_error_json(c.fd, "400 Bad Request", "Invalid UTF-8 in request body");
            c.reset_for_close();
            return -1;
        }
        c.phase = 2;
        return 1;
    }
    // 仍需 body
    c.phase = 1;
    0
}

/// WS 结束会话: 尽力发 close + 入队结束事件 + 关闭连接 (端口 C `ws_pump_close` §859-865).
/// 总是返回 -1 (调用方应 return -1).
fn ws_pump_close(c: &mut Conn, code: i32) -> i32 {
    let _ = ws_send_close(c.fd, code);
    let fd = c.fd;
    {
        let mut ev = ws_events().lock().expect("WS_EVENTS poisoned");
        let _ = ev.push(fd, WS_EV_END);
    }
    c.reset_for_close();
    -1
}

/// 单一连接 pump (phase 0/1/3/4). 端口 C `pump_conn` (§962-1020).
/// 返回 1 = request 已就绪, 0 = 仍在等, -1 = 连接已关闭.
pub fn pump_conn(c: &mut Conn, max_body_size: i32) -> i32 {
    // phase 2 / 4: Mojo 分派中, 不做 I/O (与 C 一致)
    if c.phase == 2 || c.phase == 4 {
        return 0;
    }
    // phase 3: WS 会话
    if c.phase == 3 {
        return pump_ws_conn(c);
    }
    // phase 0: 累积 header
    if c.phase == 0 {
        // 已完整 (跨块累积完毕)? 直接进 finish_header.
        if bridge_parse::find_header_end(&c.hdr[..c.hdr_total]).is_some() {
            return finish_header_into(c, max_body_size);
        }
        if c.hdr_total >= HDR_BUF_SIZE - 1 {
            send_error_json(
                c.fd,
                "431 Request Header Fields Too Large",
                "Request header too large",
            );
            c.reset_for_close();
            return -1;
        }
        let n = sys_recv(c.fd, &mut c.hdr[c.hdr_total..HDR_BUF_SIZE - 1]);
        if n <= 0 {
            if n == 0 {
                // EOF
                c.reset_for_close();
                return -1;
            }
            if n == -1 {
                return 0; // EAGAIN, spurious
            }
            c.reset_for_close();
            return -1;
        }
        c.hdr_total += n as usize;
        if c.first_data_ms == 0 {
            c.first_data_ms = now_ms() as i64;
        }
        c.last_data_ms = now_ms() as i64;
        // 一次重试: 本次 recv 可能把 header 收齐
        return pump_conn(c, max_body_size);
    }
    // phase 1: body 累积中
    let remaining = c.cl - c.body_got;
    if remaining == 0 {
        // 不应发生: phase 1 但 body 已齐; 直接转 phase 2 (C 等价).
        c.phase = 2;
        return 1;
    }
    let n = sys_recv(c.fd, &mut c.body[c.body_got..c.body_got + remaining]);
    if n <= 0 {
        if n == 0 {
            // EOF mid-body: 客户端走 pre-v11 行为, 接受短 body (而不是 hang).
            if c.body_got > 0 && !bridge_parse::utf8_valid(&c.body[..c.body_got]) {
                send_error_json(c.fd, "400 Bad Request", "Invalid UTF-8 in request body");
                c.reset_for_close();
                return -1;
            }
            c.phase = 2;
            return 1;
        }
        if n == -1 {
            return 0; // EAGAIN
        }
        c.reset_for_close();
        return -1;
    }
    c.body_got += n as usize;
    c.last_data_ms = now_ms() as i64;
    if c.body_got >= c.cl {
        // body 已齐: UTF-8 校验
        if !bridge_parse::utf8_valid(&c.body[..c.body_got]) {
            send_error_json(c.fd, "400 Bad Request", "Invalid UTF-8 in request body");
            c.reset_for_close();
            return -1;
        }
        c.phase = 2;
        return 1;
    }
    0
}

/// phase 0 的 finish_header 入口 (持有 c 时调用).
///   - 调纯逻辑 `finish_header` 解析
///   - 成功 → apply_request_header (写 body/phase/时间戳 + 更新 request globals)
///   - 失败 → send_error_json + reset_for_close
fn finish_header_into(c: &mut Conn, max_body_size: i32) -> i32 {
    let hdr_view = &c.hdr[..c.hdr_total];
    let hdr = match finish_header(hdr_view, max_body_size) {
        Ok(h) => h,
        Err((status, msg)) => {
            send_error_json(c.fd, status, msg);
            c.reset_for_close();
            return -1;
        }
    };
    // expect_100 (RFC 7231 §5.1.1)
    if hdr.expect_100 {
        send_100_continue(c.fd);
    }
    apply_request_header(c, hdr)
}

/// WS 会话 pump (phase 3). 端口 C `pump_ws_conn` (§867-940).
/// 公开为 `pub(crate)` 仅供 io_tests 调用 (生产路径通过 pump_conn 委托).
pub(crate) fn pump_ws_conn(c: &mut Conn) -> i32 {
    // 惰性分配 ws_tail / ws_reasm (等价 C 首次进入 phase 3 时 malloc)
    if c.ws_tail.is_empty() {
        c.ws_tail = vec![0u8; WS_TAIL_MAX];
        c.ws_tail_len = 0;
    }
    if c.ws_reasm.is_empty() {
        // ⚠️ Vec::with_capacity(n) 后 len=0 (踩坑教训); 用 vec![0u8; n] 让 len==cap==n.
        c.ws_reasm = vec![0u8; WS_REASM_INIT];
    }
    loop {
        // 数据源: 尾块重放 (上一块消费的剩余) 优先, 否则新 recv
        let (chunk_ptr, chunk_len, was_tail) = if c.ws_tail_len > 0 {
            let p = c.ws_tail.as_ptr();
            let n = c.ws_tail_len;
            c.ws_tail_len = 0;
            (p, n, true)
        } else {
            let n = sys_recv(c.fd, &mut c.ws_tail);
            if n <= 0 {
                if n == 0 {
                    return ws_pump_close(c, 1001); // EOF (客户端未走 close 握手)
                }
                if n == -1 {
                    break; // EAGAIN, spurious
                }
                return ws_pump_close(c, 1001);
            }
            c.last_data_ms = now_ms() as i64;
            c.ws_strikes = 0; // 任何客户端数据 (含 pong) 都是活性证明
            (c.ws_tail.as_ptr(), n as usize, false)
        };

        // 安全: chunk_ptr 是 c.ws_tail 的指针, chunk_len <= WS_TAIL_MAX.
        let chunk: &[u8] = unsafe { std::slice::from_raw_parts(chunk_ptr, chunk_len) };

        let mut opcode: c_int = 0;
        let mut mlen: usize = 0;
        let mut consumed: usize = 0;
        let rc = ws_parser_feed(
            &mut c.ws_par as *mut _,
            chunk.as_ptr(),
            chunk_len,
            &mut opcode,
            &mut mlen,
            c.ws_reasm.as_mut_ptr(),
            c.ws_reasm.capacity(),
            &mut consumed,
        );

        let _ = was_tail; // unused after borrow fix

        // 尾块保留: 本块内完整消息之后的剩余字节, 下轮重放 (ADR-0009:
        // 丢弃 = 丢消息).
        if consumed < chunk_len {
            c.ws_tail[..chunk_len - consumed].copy_from_slice(&chunk[consumed..]);
            c.ws_tail_len = chunk_len - consumed;
        }

        if rc == -2 {
            // 重组缓冲不足: 按需翻倍 (上限 1MB+1)
            let old_cap = c.ws_reasm.capacity();
            let new_cap = (old_cap * 2).min(MAX_BODY + 1);
            if new_cap <= old_cap {
                return ws_pump_close(c, 1009); // 超 1MB 上限
            }
            // 翻倍: 旧内容整体拷贝 (Vec<u8> 字节都是 u8, vec![0u8; n] 初始化,
            // 已写入 + 未使用零字节全在 buffer 中; parser p.reasm_len 跟踪
            // 已写字节, 翻倍后重喂尾块会继续从 p.reasm_len 写).
            let mut new_reasm = vec![0u8; new_cap];
            new_reasm[..old_cap].copy_from_slice(&c.ws_reasm[..old_cap]);
            c.ws_reasm = new_reasm;
            continue;
        }
        if rc == -1 {
            return ws_pump_close(c, 1002); // 协议错误
        }
        if rc == 2 {
            // 控制帧: 协议层自动处理
            if opcode == 9 {
                // ping -> pong (同载荷)
                let _ = ws_write_message(c.fd, 10, c.ws_reasm.as_ptr(), mlen);
            } else if opcode == 8 {
                // close -> 码校验回复, 结束会话
                let _ = ws_reply_close_buf(c.fd, c.ws_reasm.as_ptr(), mlen);
                let fd = c.fd;
                {
                    let mut ev = ws_events().lock().expect("WS_EVENTS poisoned");
                    let _ = ev.push(fd, WS_EV_END);
                }
                c.reset_for_close();
                return -1;
            }
            // opcode 10 (pong): 活性已计入 (last_data_ms), 无动作; 继续循环
            continue;
        }
        if rc == 1 {
            // 数据消息 (text/binary)
            if opcode == 1
                && crate::ws::ws_validate_utf8(c.ws_reasm.as_ptr(), mlen) == 0
            {
                return ws_pump_close(c, 1007); // 非法 UTF-8
            }
            c.ws_opcode = opcode;
            c.ws_mlen = mlen;
            // 入队消息事件
            let fd = c.fd;
            let overflow = {
                let mut ev = ws_events().lock().expect("WS_EVENTS poisoned");
                !ev.push(fd, WS_EV_MSG)
            };
            if overflow {
                return ws_pump_close(c, 1008); // 背压
            }
            c.phase = 4; // Mojo 处理中; 暂停本连接 pump (尾块已在 c.ws_tail)
            return 0;
        }
        // rc == 0: 块全部消耗、无完整消息 (部分帧状态在解析器内) -> 收下一块
    }
    0
}

/// Mojo 处理完一条消息后立即重 pump (ADR-0009: 尾块延迟 1s tick 不可接受).
/// 端口 C `ws_pump_now(fd)` (§942-947).
/// 行为: 若 conn 存在且 phase 3, 调 pump_ws_conn; 否则 no-op.
pub fn ws_pump_now(fd: i32) {
    let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
    let idx = match table.find(fd) {
        Some(i) => i,
        None => return,
    };
    if let Some(c) = table.get_mut(idx) {
        if c.phase == 3 {
            // pump_ws_conn 内部不锁 conn_table (由调用方持有), 仅锁 ws_events
            // (push 事件) — 不同 Mutex, 顺序固定 (conn_table → ws_events),
            // 无死锁.
            let _ = pump_ws_conn(c);
        }
    }
}

/// 每连接超时 + 保活扫描 (端口 C `check_deadlines` §1028-1067).
/// 用 `deadlines::decide` 纯函数决策, 再按 action 触发副作用.
/// 两阶段避免在持 conn_table lock 时持可变借用冲突:
///   1) 收集 (idx, action, new_strikes) — 持锁纯计算
///   2) 应用副作用 — 按需短事务持锁 (push event / close / send_error)
pub fn check_deadlines() {
    let now = now_ms() as i64;
    let recv_timeout = get_recv_timeout_ms() as i64;
    let idle_max = get_idle_max_ms();
    let max_req = get_max_request_ms();
    let ping_max = get_ws_ping_max();

    #[derive(Clone, Copy)]
    struct Decision {
        idx: usize,
        action: DeadlineAction,
        new_strikes: i32,
        old_strikes: i32,
        fd: i32,
    }

    let decisions: Vec<Decision> = {
        let table = conn_table().lock().expect("CONN_TABLE poisoned");
        let mut out = Vec::new();
        for i in 0..MAX_CONNS {
            let c = match table.get(i) {
                Some(c) if c.in_use => c,
                _ => continue,
            };
            let mut strikes = c.ws_strikes;
            let action = decide(
                c.phase,
                c.first_data_ms,
                c.last_data_ms,
                c.last_active_ms,
                &mut strikes,
                ping_max,
                now,
                recv_timeout,
                idle_max,
                max_req,
            );
            out.push(Decision {
                idx: i,
                action,
                new_strikes: strikes,
                old_strikes: c.ws_strikes,
                fd: c.fd,
            });
        }
        out
    };

    for d in decisions {
        // 同步 strike 自增 (None / WsPing / WsClose1000 都可能)
        if d.new_strikes != d.old_strikes {
            let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
            if let Some(c) = table.get_mut(d.idx) {
                c.ws_strikes = d.new_strikes;
            }
        }
        match d.action {
            DeadlineAction::None => {}
            DeadlineAction::WsPing => {
                let _ = ws_write_message(d.fd, 9, b"".as_ptr(), 0);
            }
            DeadlineAction::WsClose1000 => {
                let _ = ws_send_close(d.fd, 1000);
                // 入队结束事件
                {
                    let mut ev = ws_events().lock().expect("WS_EVENTS poisoned");
                    let _ = ev.push(d.fd, WS_EV_END);
                }
                // 关连接 (短事务)
                {
                    let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
                    table.close(d.idx);
                }
            }
            DeadlineAction::Timeout408 => {
                send_error_json(d.fd, "408 Request Timeout", "Request timeout");
                let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
                table.close(d.idx);
            }
            DeadlineAction::CloseIdle => {
                let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
                table.close(d.idx);
            }
        }
    }
}

/// Mojo 处理完一次响应后调用 (端口 C `conn_done` §1170-1180).
///   - phase 3/4: WS 会话, 不动 (生命周期归 poll 循环)
///   - 释放 body, 重置 phase 0 / 时间戳
///   - reuse=1 且 running → keep-alive (重置 last_active_ms)
///   - reuse=0 或 !running → reset_for_close
pub fn conn_done(fd: i32, reuse: c_int) {
    let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
    let idx = match table.find(fd) {
        Some(i) => i,
        None => return,
    };
    let c = match table.get_mut(idx) {
        Some(c) => c,
        None => return,
    };
    // WS 会话: 跳过 (与 C 一致)
    if c.phase == 3 || c.phase == 4 {
        return;
    }
    c.body.clear();
    c.body_got = 0;
    c.phase = 0;
    c.hdr_total = 0;
    c.first_data_ms = 0;
    c.last_data_ms = 0;
    if reuse != 0 && is_running() {
        c.last_active_ms = now_ms() as i64;
    } else {
        // reset_for_close 在测试环境 sys_close no-op; 生产环境真 close.
        c.reset_for_close();
    }
}

/// master event loop (端口 C `recv_and_parse` §1067-1170).
/// 行为: WS 事件优先 (FIFO) → poll(listen + 所有 conn) → accept/pump → check_deadlines.
/// 返回 fd (>0 = request ready / WS event), 0 = connection closed / nothing to do.
pub fn recv_and_parse() -> i32 {
    // pollfd 栈数组 (PORT C static struct pollfd pf[1 + MAX_CONNS])
    let mut pf: Vec<pollfd_t> = vec![
        pollfd_t { fd: 0, events: 0, revents: 0 };
        POLL_NFDS
    ];
    let mut pf_pos: Vec<usize> = vec![0usize; MAX_CONNS];

    loop {
        if !is_running() {
            return 0;
        }

        // WS 事件优先 (ADR-0008): FIFO 队首 = 最早就绪的消息/会话结束
        let ev_opt = {
            let mut ev = ws_events().lock().expect("WS_EVENTS poisoned");
            ev.pop()
        };
        if let Some((ev_fd, ev_type)) = ev_opt {
            // 短事务: 设 active (conn_table) + 设 ws_event_type (CURRENT).
            //   ev_type 写入 request::CURRENT.ws_event_type.
            {
                let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
                if let Some(idx) = table.find(ev_fd) {
                    if let Some(c) = table.get_mut(idx) {
                        c.last_active_ms = now_ms() as i64;
                    }
                    table.set_active(Some(idx));
                }
            }
            set_ws_event_type(ev_type);
            return ev_fd;
        }

        // poll 设置: pf[0] = listen, pf[1..] = 所有 conn
        let listen_fd = get_listen_fd();
        pf[0].fd = listen_fd;
        pf[0].events = POLLIN;
        pf[0].revents = 0;
        let mut nfd: usize = 1;
        {
            let table = conn_table().lock().expect("CONN_TABLE poisoned");
            for i in 0..MAX_CONNS {
                let c = match table.get(i) {
                    Some(c) if c.in_use => c,
                    _ => continue,
                };
                pf_pos[i] = nfd;
                pf[nfd].fd = c.fd;
                pf[nfd].events = POLLIN;
                pf[nfd].revents = 0;
                nfd += 1;
            }
        }

        let pr = sys_poll(&mut pf[..nfd], POLL_TICK_MS);
        if pr < 0 {
            let e = errno();
            if e == EINTR {
                continue;
            }
            // 其它错误: 短暂 sleep 后重试 (与 C usleep(10000) 等价)
            std::thread::sleep(std::time::Duration::from_millis(10));
            continue;
        }

        // 1) 新连接 (accept)
        if pr > 0 && listen_fd >= 0 && (pf[0].revents & (POLLIN | POLLHUP)) != 0 {
            let cfd = sys_accept(listen_fd);
            if cfd >= 0 {
                setup_conn_fd(cfd);
                let max_body = get_max_body_size();
                // alloc + 立即 pump (客户端常握完手即发请求)
                let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
                let alloc_opt = table.alloc(cfd);
                let alloc_idx: usize = match alloc_opt {
                    Some(i) => i,
                    None => {
                        // 连接数满: 直接 close, 不入 conn 表
                        drop(table);
                        send_error_json(
                            cfd,
                            "503 Service Unavailable",
                            "Too many connections",
                        );
                        unsafe {
                            close(cfd);
                        }
                        return 0;
                    }
                };
                let pump_result = match table.get_mut(alloc_idx) {
                    Some(c) => pump_conn(c, max_body),
                    None => -1,
                };
                if pump_result == 1 {
                    table.set_active(Some(alloc_idx));
                    if let Some(c) = table.get_mut(alloc_idx) {
                        c.last_active_ms = now_ms() as i64;
                    }
                    set_ws_event_type(0);
                    let fd = match table.get(alloc_idx) {
                        Some(c) => c.fd,
                        None => -1,
                    };
                    return fd;
                }
                // r == 0 / -1: 进入下一轮 poll
            }
        }

        // 2) 已有 conn 的 POLLIN/POLLHUP/POLLERR
        if pr > 0 {
            let mut ready_fd: i32 = -1;
            let max_body = get_max_body_size();
            {
                let mut table = conn_table().lock().expect("CONN_TABLE poisoned");
                for i in 0..MAX_CONNS {
                    let active_fd = match table.get(i) {
                        Some(c) if c.in_use => c.fd,
                        _ => continue,
                    };
                    let re = pf[pf_pos[i]].revents;
                    if re & (POLLIN | POLLHUP | POLLERR) == 0 {
                        continue;
                    }
                    if re & (POLLERR | POLLHUP) != 0 && (re & POLLIN) == 0 {
                        // 纯错误, 无数据
                        table.close(i);
                        continue;
                    }
                    let pump_result = {
                        let c = match table.get_mut(i) {
                            Some(c) => c,
                            None => continue,
                        };
                        pump_conn(c, max_body)
                    };
                    if pump_result == 1 {
                        table.set_active(Some(i));
                        if let Some(c) = table.get_mut(i) {
                            c.last_active_ms = now_ms() as i64;
                        }
                        set_ws_event_type(0);
                        ready_fd = active_fd;
                        break;
                    }
                    // r == 0 / -1: 继续 (下一次 poll)
                }
            }
            if ready_fd >= 0 {
                return ready_fd;
            }
        }

        // 3) deadline 扫描 (每轮迭代 1s tick)
        check_deadlines();
    }
}

/// 关 listen fd + 所有 conn (端口 C `server_shutdown` §1180-1185).
/// 不影响 signals::server_shutdown (那个仅置 G_RUNNING=0); 本函数是
/// "显式关停 + 资源回收" 入口, 用于测试 / 优雅退出兜底.
pub fn shutdown_all() {
    // 关所有 conn
    {
        let mut table = conn_table().lock().unwrap_or_else(|e| e.into_inner());
        let n = table.conns_len();
        for i in 0..n {
            if table.is_in_use(i) {
                table.close(i);
            }
        }
    }
    // 关 listen fd
    let lfd = get_listen_fd();
    if lfd >= 0 {
        unsafe {
            close(lfd);
        }
        clear_listen_fd();
    }
}
