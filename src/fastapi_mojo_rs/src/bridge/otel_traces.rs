//! bridge/otel_traces.rs — staged OpenTelemetry trace support.
//!
//! Decision-62 intentionally provides an in-process, bounded OTLP-JSON-shaped
//! export buffer rather than a network exporter:
//!   * one server span per completed HTTP request;
//!   * FASTAPI_MOJO_OTEL=1 enables recording (Mojo side);
//!   * /traces renders the last spans as OTLP JSON resourceSpans;
//!   * the buffer is per worker, matching the existing /metrics process model.
//!
//! A future decision can drain this same representation to OTLP/HTTP or
//! OTLP/protobuf without changing request dispatch.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use super::response::json_escape;
use super::time_util::now_ms;

const TRACE_CAPACITY: usize = 128;
const RENDER_CAPACITY: usize = 1024 * 1024;

static NEXT_SPAN_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
struct TraceSpan {
    trace_id: String,
    span_id: String,
    name: String,
    start_ns: u64,
    end_ns: u64,
    method: String,
    path: String,
    query: String,
    status_code: u16,
    duration_ms: i64,
}

#[derive(Default)]
struct TraceRing {
    spans: VecDeque<TraceSpan>,
}

static TRACE_RING: OnceLock<Mutex<TraceRing>> = OnceLock::new();

fn trace_ring() -> &'static Mutex<TraceRing> {
    TRACE_RING.get_or_init(|| Mutex::new(TraceRing::default()))
}

fn bounded(src: &str, max: usize) -> String {
    src.chars().take(max).collect()
}

fn status_code(status: &str) -> u16 {
    let digits: String = status.chars().take(3).filter(char::is_ascii_digit).collect();
    digits.parse().unwrap_or(0)
}

fn hex_id(seq: u64, width: usize) -> String {
    format!("{seq:0width$x}", width = width)
}

/// Record one completed HTTP request. Invalid UTF-8 is replaced rather than
/// allowing a malformed trace export to break the response path.
pub fn trace_record(method: &str, path: &str, query: &str, status: &str, duration_ms: i64) {
    let seq = NEXT_SPAN_SEQ.fetch_add(1, Ordering::Relaxed);
    let end_ns = now_ms().saturating_mul(1_000_000);
    let duration_ns = if duration_ms > 0 {
        (duration_ms as u64).saturating_mul(1_000_000)
    } else {
        0
    };
    let start_ns = end_ns.saturating_sub(duration_ns);
    let method = bounded(&method.replace('\0', ""), 32);
    let path = bounded(&path.replace('\0', ""), 2048);
    let query = bounded(&query.replace('\0', ""), 1024);
    let status = bounded(&status.replace('\0', ""), 64);
    let status_code = status_code(&status);
    let span = TraceSpan {
        trace_id: hex_id(seq, 32),
        span_id: hex_id(seq, 16),
        name: format!("{method} {path}"),
        start_ns,
        end_ns,
        status_code,
        duration_ms,
        method,
        path,
        query,
    };
    let mut ring = trace_ring().lock().unwrap_or_else(|e| e.into_inner());
    if ring.spans.len() == TRACE_CAPACITY {
        ring.spans.pop_front();
    }
    ring.spans.push_back(span);
}

pub fn traces_clear() {
    let mut ring = trace_ring().lock().unwrap_or_else(|e| e.into_inner());
    ring.spans.clear();
    NEXT_SPAN_SEQ.store(1, Ordering::Relaxed);
}

fn json_string(value: &str) -> String {
    let escaped = String::from_utf8_lossy(&json_escape(value.as_bytes())).into_owned();
    format!("\"{escaped}\"")
}

fn render_span(span: &TraceSpan) -> String {
    let otel_status = if span.status_code >= 500 { 2 } else { 1 };
    format!(
        "{{\"traceId\":\"{id}\",\"spanId\":\"{sid}\",\"parentSpanId\":\"\",\
         \"name\":{name},\"kind\":2,\"startTimeUnixNano\":{start},\
         \"endTimeUnixNano\":{end},\"attributes\":[\
         {{\"key\":\"http.request.method\",\"value\":{{\"stringValue\":{method}}}}},\
         {{\"key\":\"url.path\",\"value\":{{\"stringValue\":{path}}}}},\
         {{\"key\":\"url.query\",\"value\":{{\"stringValue\":{query}}}}},\
         {{\"key\":\"http.response.status_code\",\"value\":{{\"intValue\":{code}}}}},\
         {{\"key\":\"fastapi_mojo.duration_ms\",\"value\":{{\"intValue\":{duration}}}}}],\
         \"status\":{{\"code\":{otel_status}}}}}",
        id = span.trace_id,
        sid = span.span_id,
        name = json_string(&span.name),
        start = span.start_ns,
        end = span.end_ns,
        method = json_string(&span.method),
        path = json_string(&span.path),
        query = json_string(&span.query),
        code = span.status_code,
        duration = span.duration_ms,
    )
}

/// Render OTLP JSON 1.0-shaped export payload into a NUL-terminated static
/// buffer. The lock is held while formatting so a concurrent clear cannot
/// mutate the deque underneath this snapshot.
pub fn traces_render_json() -> &'static [u8] {
    static mut BUF: [u8; RENDER_CAPACITY] = [0u8; RENDER_CAPACITY];
    static mut LEN: usize = 0;
    let ring = trace_ring().lock().unwrap_or_else(|e| e.into_inner());
    let spans: Vec<String> = ring.spans.iter().map(render_span).collect();
    let mut body = String::from(
        "{\"resourceSpans\":[{\"resource\":{\"attributes\":[\
         {\"key\":\"service.name\",\"value\":{\"stringValue\":\"fastapi_mojo\"}}]}},\
         \"scopeSpans\":[{\"scope\":{\"name\":\"fastapi_mojo.bridge\"},\"spans\":[",
    );
    body.push_str(&spans.join(","));
    body.push_str("]}]}]}");
    unsafe {
        let n = body.len().min(RENDER_CAPACITY - 1);
        BUF[..n].copy_from_slice(&body.as_bytes()[..n]);
        BUF[n] = 0;
        LEN = n;
        &BUF[..LEN]
    }
}

pub fn traces_get_slice() -> (usize, *const u8) {
    let slice = traces_render_json();
    (slice.len(), slice.as_ptr())
}
