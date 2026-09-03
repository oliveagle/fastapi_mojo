//! socket.rs — listen socket 创建 + 连接 socket 选项 (ADR-0010 DC2).
//!
//! 行为等价翻译自 `http_bridge_final.c`:
//!   - `create_bound_socket` (§350-368): socket(AF_INET, SOCK_STREAM) +
//!     SO_REUSEADDR + SO_REUSEPORT (ADR-0005, 多 worker 共享端口) + bind
//!     (0.0.0.0:port) + listen(128); 内部先 setup_signal_handlers +
//!     init_timeouts_from_env (与 C 一致: 这两个调用发生在 socket 之前)
//!   - `setup_conn_fd` (§480-495): 每连接 SO_RCVTIMEO/SO_SNDTIMEO (慢连接
//!     防护) + TCP_NODELAY (避免 keep-alive 的 Nagle/delayed-ACK 40ms 停顿)
//!
//! 与 C 的差异:
//!   - sockaddr_in / sockaddr_in 布局用 #[repr(C)] 显式定义; htons 用
//!     `to_be()` (x86_64 LE 下等价)
//!   - 失败路径: 不设置 G_LISTEN_FD 全局 (C 设了但 conn state machine 未迁
//!     移, 全局留待 conn 端口一并处理); 返回 i32 fd 或 -1
//!   - `setup_conn_fd` 只取 fd 参数 (不依赖 conn struct), 便于单测
//!
//! FFI 包装延迟: 同 signals.rs, 待 `bridge.o` 下线时统一加.

use std::os::raw::{c_int, c_void};

use super::signals::setup_signal_handlers;
use super::state::init_timeouts_from_env;

// ========== Linux 常量 ==========
const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET: c_int = 1;
const SO_REUSEADDR: c_int = 2;
const SO_REUSEPORT: c_int = 15;
const SO_RCVTIMEO: c_int = 20;
const SO_SNDTIMEO: c_int = 21;
const IPPROTO_TCP: c_int = 6;
const TCP_NODELAY: c_int = 1;
const INADDR_ANY: u32 = 0;
const LISTEN_BACKLOG: c_int = 128;

// ========== struct 布局 (Linux x86_64 glibc) ==========
#[repr(C)]
#[derive(Clone, Copy)]
struct in_addr {
    s_addr: u32, // big-endian
}

#[repr(C)]
#[derive(Clone, Copy)]
struct sockaddr_in {
    sin_family: u16,   // sa_family_t (AF_INET)
    sin_port: u16,     // big-endian
    sin_addr: in_addr,
    sin_zero: [u8; 8],
}

#[repr(C)]
struct timeval {
    tv_sec: i64,
    tv_usec: i64,
}

// 编译期 layout 校验: sockaddr_in 16 字节 (sin_family 2 + sin_port 2 +
// sin_addr 4 + sin_zero 8), 与 C 一致.
const _: [(); 16] = [(); std::mem::size_of::<sockaddr_in>()];

// ========== 系统调用直连 ==========
extern "C" {
    fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
    fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const c_void, optlen: usize) -> c_int;
    fn bind(fd: c_int, addr: *const c_void, addrlen: usize) -> c_int;
    fn listen(fd: c_int, backlog: c_int) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn getsockname(fd: c_int, addr: *mut c_void, addrlen: *mut usize) -> c_int;
}

fn htons(v: u16) -> u16 {
    v.to_be()
}

/// 创建并绑定 listen socket. 端口 C `create_bound_socket` (§350-368).
/// 返回 fd (>=0) 或 -1 (失败). 内部先 setup_signal_handlers +
/// init_timeouts_from_env (与 C 的调用顺序一致).
pub fn create_bound_socket(port: u16) -> i32 {
    // 与 C 一致: socket 创建前先初始化信号处理 + 超时配置
    setup_signal_handlers();
    init_timeouts_from_env();

    let fd = unsafe { socket(AF_INET, SOCK_STREAM, 0) };
    if fd < 0 {
        return -1;
    }
    let one: c_int = 1;
    unsafe {
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one as *const _ as *const c_void, std::mem::size_of::<c_int>());
        // ADR-0005: workers share the port; the kernel distributes new
        // connections by 4-tuple hash (no-op for the default single worker).
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one as *const _ as *const c_void, std::mem::size_of::<c_int>());

        let addr = sockaddr_in {
            sin_family: AF_INET as u16,
            sin_port: htons(port),
            sin_addr: in_addr { s_addr: INADDR_ANY },
            sin_zero: [0u8; 8],
        };
        if bind(fd, &addr as *const _ as *const c_void, std::mem::size_of::<sockaddr_in>()) < 0 {
            close(fd);
            return -1;
        }
        if listen(fd, LISTEN_BACKLOG) < 0 {
            close(fd);
            return -1;
        }
    }
    fd
}

/// 每连接 socket 选项 (慢连接防护 + TCP_NODELAY). 端口 C `setup_conn_fd`
/// (§480-495). recv_timeout_ms 来自 state::get_recv_timeout_ms().
pub fn setup_conn_fd(fd: i32) {
    let timeout_ms = super::state::get_recv_timeout_ms() as i64;
    let tv = timeval {
        tv_sec: timeout_ms / 1000,
        tv_usec: (timeout_ms % 1000) * 1000,
    };
    let nodelay: c_int = 1;
    unsafe {
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv as *const _ as *const c_void, std::mem::size_of::<timeval>());
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv as *const _ as *const c_void, std::mem::size_of::<timeval>());
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay as *const _ as *const c_void, std::mem::size_of::<c_int>());
    }
}

/// 读取 listen socket 实际绑定的端口 (用于测试: bind port 0 -> 内核选
/// 临时端口; 也用于运行期诊断).
pub fn bound_port(fd: i32) -> u16 {
    let mut addr = sockaddr_in {
        sin_family: 0,
        sin_port: 0,
        sin_addr: in_addr { s_addr: 0 },
        sin_zero: [0u8; 8],
    };
    let mut len: usize = std::mem::size_of::<sockaddr_in>();
    let rc = unsafe {
        getsockname(fd, &mut addr as *mut _ as *mut c_void, &mut len)
    };
    if rc < 0 {
        return 0;
    }
    u16::from_be(addr.sin_port)
}

/// 测试辅助: 关闭 fd (也用于生产收尾).
pub fn close_fd(fd: i32) {
    unsafe { close(fd); }
}
