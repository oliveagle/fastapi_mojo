//! upstream.rs — 上游引擎转发客户端 (ADR-0010 风格: 零第三方 crate, std-only).
//!
//! 用途: 让 fastapi_mojo 把一次请求转给"模型引擎"进程 (例如 soft-decider 的
//! torch 推理侧车), HTTP 语义完全留在 Mojo 侧 —— 本项目本标是"运行时零 Python",
//! 引擎侧车是**另一个进程**, 不是本 binary 的运行期依赖.
//!
//! 协议: **长度前缀 JSON over TCP** (刻意不用 HTTP):
//!   请求帧: [u32 大端 total][u8 path_len][path bytes][body bytes]
//!   响应帧: [u32 大端 total][u16 大端 status][payload]  (total = 2 + payload.len)
//!
//! 请求帧带 path (1 字节长度 + 路径字节) 是为了引擎侧车能复用同一端口服务
//! 多个端点 (/health, /v1/systemone, 未来 /metrics), 而不必为每个端点开新端口
//! 或把 path 塞进 JSON body (那会把原始请求体二次编码/转义).
//!
//! 为什么不用 HTTP:
//!   1. 上游是模型引擎, 不需要 HTTP 语义 (状态码/头/cookie/CORS) —— 一帧 JSON 足够;
//!   2. 引擎侧因此**不必起 HTTP 框架** (无 uvicorn/FastAPI/ASGI/pydantic), Python
//!      侧每请求开销从"框架解析 + 模型校验"降到"4 字节长度 + 一次 json.loads";
//!   3. Rust 侧解析成本 = 读 4 字节长度 + 读 N 字节, 不做 HTTP 头扫描;
//!   4. 帧长显式 => 没有 chunked/keep-alive 歧义, 引擎侧可以用最朴素的
//!      "读满 4 字节 -> 读满 N 字节" 实现, 零解析零缓冲池.
//!
//! 约束 (与项目其他 bridge 模块一致):
//!   - 只用 std::net / std::io / std::time, 无第三方 crate;
//!   - 同步阻塞: 由 Mojo dispatch 在 worker 进程内调用; 并发度靠
//!     FASTAPI_MOJO_WORKERS (pre-fork 多进程 + SO_REUSEPORT) 提供;
//!   - **连接复用**: 每个线程缓存一条到 (host, port) 的连接 (thread-local),
//!     请求间复用 keep-alive 帧通道 —— 实测每请求省 ~2.2ms (引擎侧不用再为
//!     每个连接起新线程 + 付 CUDA/线程局部初始化). 对端关闭/出错时丢弃缓存并
//!     重连一次 (语义 = 一次透明重试);
//!   - 同一 timeout 同时作用于 connect / read / write, 上游卡死不会拖死 worker;
//!   - FFI 契约: 返回的 slice 缓冲**必须 NUL 终止** (决策-36), 调用方须在
//!     下一次 upstream_* 调用前消费.

use std::cell::{Cell, RefCell};
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// 单帧上限 (64 MiB): 防御性上限, 防止上游报出荒谬长度导致巨额分配.
pub const MAX_FRAME: usize = 64 * 1024 * 1024;

/// 路径字段上限 (u8 长度前缀).
pub const MAX_PATH: usize = 255;

/// 默认超时 (ms): 与 KIND_RUN_CMD 的 15s 同量级, 但给模型推理留余量.
pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;

thread_local! {
    /// 上一次 upstream_call 的响应体 (**含尾部 NUL**).
    static LAST_REPLY: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    /// 上一次 upstream_call 的错误信息 (**含尾部 NUL**); 成功时为空.
    static LAST_ERROR: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    /// 上一次 upstream_call 的上游状态码 (0 = 传输层失败/未调用).
    static LAST_STATUS: Cell<i64> = const { Cell::new(0) };
}

/// 取上次 upstream_call 的上游 HTTP 状态码 (0 = 失败).
pub fn last_status() -> i64 {
    LAST_STATUS.with(|c| c.get())
}

/// 线程级上游连接缓存 (keep-alive 帧通道复用).
struct Conn {
    host: String,
    port: u16,
    stream: TcpStream,
}

thread_local! {
    static CONN: RefCell<Option<Conn>> = const { RefCell::new(None) };
}

/// 把一次调用的结果写进 thread-local (Mojo 侧随后用 slice 访问器取).
pub fn store_result(reply: Result<Vec<u8>, String>) {
    match reply {
        Ok(body) => {
            let mut v = body;
            v.push(0); // NUL 终止契约
            LAST_REPLY.with(|c| *c.borrow_mut() = v);
            LAST_ERROR.with(|c| c.borrow_mut().clear());
        }
        Err(e) => {
            LAST_REPLY.with(|c| c.borrow_mut().clear());
            let mut v = e.into_bytes();
            v.push(0);
            LAST_ERROR.with(|c| *c.borrow_mut() = v);
        }
    }
}

/// 取上次响应体的 (ptr, len) —— **指针指向 thread-local 内部缓冲**, 不是副本:
/// 下一次 `upstream_call` 会覆盖该缓冲, 调用方须在此之前消费 (与 mp_* 访问器同契约).
/// len 不含尾部 NUL.
pub fn last_reply_ptr() -> (*const u8, usize) {
    LAST_REPLY.with(|c| {
        let v = c.borrow();
        if v.is_empty() {
            (std::ptr::null(), 0)
        } else {
            (v.as_ptr(), v.len() - 1)
        }
    })
}

/// 取上次错误信息的 (ptr, len) —— 同 `last_reply_ptr` 的生命周期契约.
pub fn last_error_ptr() -> (*const u8, usize) {
    LAST_ERROR.with(|c| {
        let v = c.borrow();
        if v.is_empty() {
            (std::ptr::null(), 0)
        } else {
            (v.as_ptr(), v.len() - 1)
        }
    })
}

/// 读满 buf.len() 字节 (EINTR 重试; EOF 提前 = 短读错误).
fn read_exact(stream: &mut TcpStream, buf: &mut [u8]) -> Result<(), String> {
    let mut read = 0usize;
    while read < buf.len() {
        match stream.read(&mut buf[read..]) {
            Ok(0) => return Err(format!("unexpected EOF after {read} bytes")),
            Ok(n) => read += n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}

/// 解析 host:port -> SocketAddr (取第一个解析结果).
fn resolve(host: &str, port: u16) -> Result<std::net::SocketAddr, String> {
    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("resolve {host}:{port} failed: {e}"))?;
    addrs
        .into_iter()
        .next()
        .ok_or_else(|| format!("resolve {host}:{port} failed: no address"))
}

use std::sync::atomic::{AtomicUsize, Ordering};

/// 引擎副本轮转计数器 (每请求自增; 多副本分摊到不同 GPU).
static RR: AtomicUsize = AtomicUsize::new(0);

/// 解析 "18410,18411,18412,18413" -> 选中的端口.
///
/// `pin >= 0`: 固定取 `ports[pin % n]` (调用方传 worker_id — 每个前端 worker
/// 绑定一个引擎副本, 保证每个引擎同时只有 1 个在飞请求; 引擎侧 GIL 在并发下
/// 会互相打转, 单飞才是满速).
/// `pin < 0`:  跨请求轮转 (无 worker 语义时的退化路径).
///
/// 空串 / 非法条目 -> Err (调用方按上游失败处理, 返回 502).
pub fn pick_port(ports_csv: &str, pin: i64) -> Result<u16, String> {
    let mut ports: Vec<u16> = Vec::new();
    for tok in ports_csv.split(',') {
        let t = tok.trim();
        if t.is_empty() {
            continue;
        }
        ports.push(
            t.parse::<u16>()
                .map_err(|_| format!("bad upstream port: {t}"))?,
        );
    }
    if ports.is_empty() {
        return Err("no upstream port configured".to_string());
    }
    let i = if pin >= 0 {
        (pin as usize) % ports.len()
    } else {
        RR.fetch_add(1, Ordering::Relaxed) % ports.len()
    };
    Ok(ports[i])
}

/// 解析端口表 (供 failover 用): 返回全部端口 + 起始下标.
///
/// 起始下标: pin >= 0 -> pin % n (本 worker 的归属副本); pin < 0 -> 轮转.
/// 首个副本失败时, 调用方按 (start+1)%n ... 顺序尝试其余副本 (failover).
pub fn port_ring(ports_csv: &str, pin: i64) -> Result<(Vec<u16>, usize), String> {
    let mut ports: Vec<u16> = Vec::new();
    for tok in ports_csv.split(',') {
        let t = tok.trim();
        if t.is_empty() {
            continue;
        }
        ports.push(t.parse::<u16>().map_err(|_| format!("bad upstream port: {t}"))?);
    }
    if ports.is_empty() {
        return Err("no upstream port configured".to_string());
    }
    let start = if pin >= 0 {
        (pin as usize) % ports.len()
    } else {
        RR.fetch_add(1, Ordering::Relaxed) % ports.len()
    };
    Ok((ports, start))
}

/// 向 host:port 发起一次长度前缀 JSON 调用, 返回上游的响应 payload.
///
/// 帧格式: [u32 大端 total][u8 path_len][path][payload]; total 上限 MAX_FRAME.
pub fn upstream_call(
    host: &str,
    port: u16,
    path: &[u8],
    payload: &[u8],
    timeout_ms: u64,
) -> Result<Vec<u8>, String> {
    if path.len() > MAX_PATH {
        return Err(format!("path too long: {} bytes", path.len()));
    }
    let total = 1 + path.len() + payload.len();
    if total > MAX_FRAME {
        return Err(format!("payload too large: {} bytes", payload.len()));
    }
    let addr = resolve(host, port)?;
    let timeout = Duration::from_millis(if timeout_ms == 0 {
        DEFAULT_TIMEOUT_MS
    } else {
        timeout_ms
    });

    let mut frame = Vec::with_capacity(4 + total);
    frame.extend_from_slice(&(total as u32).to_be_bytes());
    frame.push(path.len() as u8);
    frame.extend_from_slice(path);
    frame.extend_from_slice(payload);

    // 1) 复用本线程到 (host, port) 的连接; 失败 -> 丢弃缓存, 落到 2).
    let reused = CONN.with(|c| {
        let mut slot = c.borrow_mut();
        match slot.as_mut() {
            Some(conn) if conn.host == host && conn.port == port => {
                match roundtrip(&mut conn.stream, &frame, timeout, addr) {
                    Ok(v) => Some(Ok(v)),
                    Err(_) => {
                        *slot = None;
                        None
                    }
                }
            }
            _ => None,
        }
    });
    if let Some(res) = reused {
        return res;
    }

    // 2) 新连接 (对端重启 / 首次调用): 成功则写入缓存供后续请求复用.
    let mut stream = TcpStream::connect_timeout(&addr, timeout)
        .map_err(|e| format!("connect {addr} failed: {e}"))?;
    // 请求-响应一来一回, Nagle 会白等 40ms —— 关掉.
    stream.set_nodelay(true).ok();
    let res = roundtrip(&mut stream, &frame, timeout, addr);
    if res.is_ok() {
        CONN.with(|c| {
            *c.borrow_mut() = Some(Conn { host: host.to_string(), port, stream });
        });
    }
    res
}

/// 一次请求-响应往返 (同一连接上可重复调用; keep-alive 帧通道).
fn roundtrip(
    stream: &mut TcpStream,
    frame: &[u8],
    timeout: Duration,
    addr: std::net::SocketAddr,
) -> Result<Vec<u8>, String> {
    stream.set_read_timeout(Some(timeout)).ok();
    stream.set_write_timeout(Some(timeout)).ok();
    stream
        .write_all(frame)
        .map_err(|e| format!("write to {addr} failed: {e}"))?;
    stream.flush().ok();

    let mut len_buf = [0u8; 4];
    read_exact(stream, &mut len_buf).map_err(|e| format!("read length from {addr} failed: {e}"))?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len < 2 {
        return Err(format!("upstream frame too short: {len} bytes"));
    }
    if len > MAX_FRAME {
        return Err(format!("upstream frame too large: {len} bytes"));
    }
    let mut resp = vec![0u8; len];
    read_exact(stream, &mut resp).map_err(|e| format!("read payload from {addr} failed: {e}"))?;
    let status = u16::from_be_bytes([resp[0], resp[1]]) as i64;
    LAST_STATUS.with(|c| c.set(status));
    Ok(resp[2..].to_vec())
}
