//! bridge/metrics.rs — Prometheus 文本格式 metrics (Goal-0002 F6).
//!
//! 原子计数器 (无锁, 无第三方):
//!   - requests_total: 处理过的 HTTP 请求总数 (recv_and_parse 返回后).
//!   - active_conns: 当前活跃连接数 (alloc/close 增量).
//!   - uptime_seconds: 进程启动至今秒数 (派生, 调用时算).
//!
//! 输出格式: Prometheus 文本 (OpenMetrics), 每行 `<name> <value>`.
//!
//! 设计: 跨 worker 汇总 —— 每个 worker 进程持有独立计数器, /metrics 端点返回
//! 本进程的实时值. 多 worker 模式下 Prometheus scrape 需配置 worker label
//! (由部署层聚合). 这是单 binary 零依赖的务实折衷.

use std::sync::atomic::{AtomicU64, AtomicI64, Ordering};

use super::time_util::now_ms;

// ---------- 计数器 (跨请求跨连接) ----------

/// 已处理 HTTP 请求总数.
pub static REQUESTS_TOTAL: AtomicU64 = AtomicU64::new(0);
/// 当前活跃连接数 (gauge).
pub static ACTIVE_CONNS: AtomicI64 = AtomicI64::new(0);
/// 进程启动毫秒时间戳 (供 uptime_seconds 计算). now_ms() 返回 u64.
pub static START_MS: AtomicU64 = AtomicU64::new(0);

/// 初始化 (在 init_workers 里调用).
pub fn metrics_init() {
    let now = now_ms();
    START_MS.store(now, Ordering::Relaxed);
}

/// 递增 requests_total (recv_and_parse 完整处理一个请求后调用).
pub fn metrics_inc_request() {
    REQUESTS_TOTAL.fetch_add(1, Ordering::Relaxed);
}

/// 连接分配 (alloc).
pub fn metrics_conn_alloc() {
    ACTIVE_CONNS.fetch_add(1, Ordering::Relaxed);
}

/// 连接释放 (close / reset_for_close).
pub fn metrics_conn_close() {
    ACTIVE_CONNS.fetch_sub(1, Ordering::Relaxed);
}

/// 派生 gauge: 当前 uptime 秒数.
pub fn metrics_uptime_s() -> u64 {
    let start = START_MS.load(Ordering::Relaxed);
    if start == 0 {
        return 0;
    }
    let now = now_ms();
    let diff = now.saturating_sub(start);
    diff / 1000
}

// ---------- Prometheus 文本渲染 ----------

/// 渲染当前 metrics 为 Prometheus 文本 (多行, 末尾带换行).
/// 每行: <metric_name> <value>\n
/// 输出到静态缓冲 (供 CSlice ptr 指向), 单线程 worker 内调用安全.
pub fn metrics_render_text() -> &'static [u8] {
    static mut BUF: [u8; 4096] = [0u8; 4096];
    static mut LEN: usize = 0;
    let req = REQUESTS_TOTAL.load(Ordering::Relaxed);
    let conns = ACTIVE_CONNS.load(Ordering::Relaxed);
    let up = metrics_uptime_s();
    let body = format!(
        "# HELP fastapi_mojo_requests_total Total HTTP requests processed.\n\
         # TYPE fastapi_mojo_requests_total counter\n\
         fastapi_mojo_requests_total {}\n\
         # HELP fastapi_mojo_active_connections Current active connections.\n\
         # TYPE fastapi_mojo_active_connections gauge\n\
         fastapi_mojo_active_connections {}\n\
         # HELP fastapi_mojo_uptime_seconds Seconds since process start.\n\
         # TYPE fastapi_mojo_uptime_seconds gauge\n\
         fastapi_mojo_uptime_seconds {}\n",
        req, conns, up
    );
    unsafe {
        let n = body.len().min(4095);
        BUF[..n].copy_from_slice(body.as_bytes());
        BUF[n] = 0;
        LEN = n;
        &BUF[..LEN]
    }
}

/// 返回 slice 指针 (与 fmc_slice 语义一致).
pub fn metrics_get_slice() -> (usize, *const u8) {
    let slice = metrics_render_text();
    (slice.len(), slice.as_ptr())
}
