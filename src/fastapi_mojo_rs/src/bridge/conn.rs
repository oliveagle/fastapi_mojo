//! conn.rs — 连接状态机核心 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c` 的 conn 层:
//!   - `struct conn` (§409-441) + MAX_CONNS 表 (§442)
//!   - `alloc_conn` / `find_conn` / `close_conn` (§444-479)
//!   - WS 事件队列 (§832-849: g_ws_ev_* push/pop, ADR-0008)
//!   - **纯逻辑解析** (见 `conn::parse`): finish_header / request-line /
//!     Content-Length / keep-alive / WS upgrade (§665-828, §1216-1254)
//!
//! 设计 (与 C 的差异, 语义等价):
//!   - `finish_header` 返回 `Result<RequestHeader, (status, message)>` —
//!     错误时由调用方发 error JSON + close (C 中内联); 纯函数可单测.
//!   - ConnTable / WsEventQueue 用 Vec 管理 (C 固定数组); 单线程 + Mutex.
//!   - 内存: body/reasm/tail 用 Vec (RAII), 替代 C 的 malloc/free —
//!     **无内存泄漏** (close 时 drop 即回收).
//!   - FFI 包装 (get_*_slice / recv_and_parse 等) 待 `bridge.o` 下线时加.
//!
//! 未含 (下轮, 与 poll loop 一并迁移): `pump_conn` / `pump_ws_conn` /
//! `check_deadlines` / `recv_and_parse` 外层字节状态机 — 它们做 socket I/O,
//! 依赖本模块的 ConnTable + parse 原语.

use std::os::raw::c_int;
use std::sync::Mutex;
use std::sync::OnceLock;

use super::time_util::now_ms;
use crate::ws::parser::WsParser;

pub mod deadlines;
pub mod parse;

#[cfg(test)]
mod deadlines_tests;

// ========== 常量 (端口 C 宏) ==========
pub const MAX_CONNS: usize = 1024;
pub const HDR_BUF_SIZE: usize = 16384;
pub const MAX_METHOD: usize = 16;
pub const MAX_PATH: usize = 1024;
pub const MAX_QUERY: usize = 1024;
pub const MAX_BODY: usize = 1024 * 1024;
pub const WS_TAIL_MAX: usize = 8192;
pub const WS_REASM_INIT: usize = 4096 + 1;
/// 事件队列容量 = 2*MAX_CONNS+64 (ADR-0008: 每个存活连接至多 1 条待处理事件,
/// 结构上不会溢出; 溢出仍走 1008 防御路径).
pub const WS_EV_MAX: usize = 2 * MAX_CONNS + 64;

/// 事件类型: 1 = 数据消息就绪, 2 = 会话结束.
pub const WS_EV_MSG: i32 = 1;
pub const WS_EV_END: i32 = 2;

// ========== Conn 结构 (端口 C struct conn) ==========
pub struct Conn {
    pub in_use: bool,
    pub fd: i32,
    /// 0=header 1=body 2=HTTP dispatch(Mojo busy)
    /// 3=WS session(poll 可驱动) 4=WS dispatch(Mojo 处理一条消息)
    pub phase: i32,
    pub hdr: Vec<u8>,       // HDR_BUF_SIZE 上限
    pub hdr_total: usize,
    pub cl: usize,          // 解析出的 Content-Length
    pub body: Vec<u8>,      // malloc(cl+1) 等价
    pub body_got: usize,
    pub connected_ms: i64,
    pub last_active_ms: i64,
    pub first_data_ms: i64, // 当前请求首字节 (0 = 无)
    pub last_data_ms: i64,
    pub ws_path: Vec<u8>,   // upgrade 时的 path
    pub ws_reasm: Vec<u8>,  // 消息载荷重组缓冲 (按需增长, 上限 MAX_BODY+1)
    pub ws_tail: Vec<u8>,   // 尾块缓冲 (WS_TAIL_MAX)
    pub ws_tail_len: usize,
    pub ws_par: WsParser,   // 状态化帧解析器 (ws.rs, 72B repr(C))
    pub ws_opcode: i32,     // 待处理数据帧 opcode
    pub ws_mlen: usize,     // 待处理数据帧长度
    pub ws_strikes: i32,    // 保活 strike 计数
}

impl Conn {
    fn new(fd: i32) -> Self {
        let t = now_ms() as i64;
        Conn {
            in_use: true,
            fd,
            phase: 0,
            hdr: vec![0u8; HDR_BUF_SIZE],
            hdr_total: 0,
            cl: 0,
            body: Vec::new(),
            body_got: 0,
            connected_ms: t,
            last_active_ms: t,
            first_data_ms: 0,
            last_data_ms: 0,
            ws_path: Vec::new(),
            ws_reasm: Vec::new(),
            ws_tail: Vec::new(),
            ws_tail_len: 0,
            ws_par: WsParser::new(),
            ws_opcode: 0,
            ws_mlen: 0,
            ws_strikes: 0,
        }
    }

    /// 端口 C `close_conn` (§459-479): 释放 body/reasm/tail (Rust Vec drop),
    /// 关闭 fd, 复位. **不**动 fd 本身以外的连接资源.
    pub fn reset_for_close(&mut self) {
        self.in_use = false;
        if self.fd >= 0 {
            sys_close(self.fd);
        }
        self.fd = -1;
        self.phase = 0;
        self.hdr_total = 0;
        self.body.clear();
        self.body_got = 0;
        self.first_data_ms = 0;
        self.last_data_ms = 0;
        self.ws_path.clear();
        self.ws_reasm.clear();
        self.ws_tail.clear();
        self.ws_tail_len = 0;
        self.ws_opcode = 0;
        self.ws_mlen = 0;
        self.ws_strikes = 0;
        self.par_reset();
    }

    pub(crate) fn par_reset(&mut self) {
        self.ws_par = WsParser::new();
    }
}

// ========== 系统调用直连 ==========
// 仅非测试构建需要 (测试构建 sys_close 是 no-op, 不引用 extern close).
#[cfg(not(test))]
extern "C" {
    fn close(fd: c_int) -> c_int;
}

// 单元测试里绝不真正 close 文件描述符: conn 表测试用的是合成 fd 号
// (101/102/.../1000+), 若与测试进程真实 fd (libtest 捕获管道 / stdio)
// 撞号会误关, 导致无关测试被破坏. 生产路径 (非 test) 走真实 close.
#[cfg(test)]
fn sys_close(fd: c_int) -> c_int {
    let _ = fd;
    -1
}
#[cfg(not(test))]
fn sys_close(fd: c_int) -> c_int {
    // SAFETY: fd 由 conn 表生命周期管理, 与 C close_conn 行为等价.
    unsafe { close(fd) }
}

// ========== ConnTable (端口 C g_conns[1024]) ==========
pub struct ConnTable {
    conns: Vec<Conn>,
    /// g_active_conn 的索引 (Some(idx)); None = 无 active.
    active: Option<usize>,
}

impl ConnTable {
    pub fn new() -> Self {
        ConnTable {
            conns: Vec::with_capacity(MAX_CONNS),
            active: None,
        }
    }

    /// 端口 C `alloc_conn` (§444-458): 找空闲槽, 初始化, 记录 connected_ms /
    /// last_active_ms. 满则 None (调用方 503).
    /// 行为等价 C alloc_conn (§445-458): 先扫描既有槽位找已 reset 的
    /// 空闲槽复用 (C 走定长数组扫描; Rust 走 Vec 但语义相同); 仅当
    /// 全占用 (== MAX_CONNS) 才返回 None.
    pub fn alloc(&mut self, fd: i32) -> Option<usize> {
        for (i, c) in self.conns.iter_mut().enumerate() {
            if !c.in_use {
                *c = Conn::new(fd);
                return Some(i);
            }
        }
        if self.conns.len() < MAX_CONNS {
            let idx = self.conns.len();
            self.conns.push(Conn::new(fd));
            return Some(idx);
        }
        None
    }

    pub fn find(&self, fd: i32) -> Option<usize> {
        self.conns
            .iter()
            .position(|c| c.in_use && c.fd == fd)
    }

    /// 端口 C `close_conn` 包装: 关闭连接并清 active.
    pub fn close(&mut self, idx: usize) {
        if idx >= self.conns.len() {
            return;
        }
        if self.active == Some(idx) {
            self.active = None;
        }
        self.conns[idx].reset_for_close();
    }

    pub fn get(&self, idx: usize) -> Option<&Conn> {
        self.conns.get(idx)
    }
    pub fn get_mut(&mut self, idx: usize) -> Option<&mut Conn> {
        self.conns.get_mut(idx)
    }
    pub fn iter_active(&self) -> impl Iterator<Item = (usize, &Conn)> {
        self.conns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.in_use)
    }

    pub fn set_active(&mut self, idx: Option<usize>) {
        self.active = idx;
    }
    pub fn active(&self) -> Option<usize> {
        self.active
    }

    /// 当前 conn 表已分配槽数 (用于遍历上界; 与 MAX_CONNS 解耦, 便于测试).
    pub fn conns_len(&self) -> usize {
        self.conns.len()
    }

    /// 槽位是否在用 (便捷访问; idx >= len 返回 false).
    pub fn is_in_use(&self, idx: usize) -> bool {
        self.conns.get(idx).map(|c| c.in_use).unwrap_or(false)
    }
}

// 全局 ConnTable (单线程访问 + Mutex 保护; FFI 层薄壳).
static CONN_TABLE: OnceLock<Mutex<ConnTable>> = OnceLock::new();

pub fn conn_table() -> &'static Mutex<ConnTable> {
    CONN_TABLE.get_or_init(|| Mutex::new(ConnTable::new()))
}

// ========== WS 事件队列 (端口 C g_ws_ev_*, §832-849) ==========
pub struct WsEventQueue {
    fds: Vec<i32>,
    types: Vec<i32>,
    head: usize,
    count: usize,
}

impl WsEventQueue {
    pub fn new() -> Self {
        WsEventQueue {
            fds: vec![0; WS_EV_MAX],
            types: vec![0; WS_EV_MAX],
            head: 0,
            count: 0,
        }
    }

    /// 端口 C `ws_event_push` (§844-849): 0 = 入队成功, 1 = 溢出.
    pub fn push(&mut self, fd: i32, ty: i32) -> bool {
        if self.count >= WS_EV_MAX {
            return false; // 溢出 (调用方必须结束会话)
        }
        let tail = (self.head + self.count) % WS_EV_MAX;
        self.fds[tail] = fd;
        self.types[tail] = ty;
        self.count += 1;
        true
    }

    /// 端口 C `ws_event_pop` (§850-855): None = 空; Some((fd, type)).
    pub fn pop(&mut self) -> Option<(i32, i32)> {
        if self.count == 0 {
            return None;
        }
        let fd = self.fds[self.head];
        let ty = self.types[self.head];
        self.head = (self.head + 1) % WS_EV_MAX;
        self.count -= 1;
        Some((fd, ty))
    }

    pub fn len(&self) -> usize {
        self.count
    }
    pub fn is_empty(&self) -> bool {
        self.count == 0
    }
}

static WS_EVENTS: OnceLock<Mutex<WsEventQueue>> = OnceLock::new();
pub fn ws_events() -> &'static Mutex<WsEventQueue> {
    WS_EVENTS.get_or_init(|| Mutex::new(WsEventQueue::new()))
}
