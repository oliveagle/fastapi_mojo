use super::otel_traces::{trace_record, traces_clear, traces_get_slice, traces_render_json};

fn reset() {
    traces_clear();
}

#[test]
fn trace_ring_renders_otlp_json_with_valid_ids() {
    reset();
    trace_record("GET", "/health", "", "200 OK", 2);
    trace_record("POST", "/items", "q=1", "201 Created", 4);
    let json = String::from_utf8_lossy(traces_render_json()).into_owned();
    assert!(json.starts_with("{\"resourceSpans\":["));
    assert!(json.contains("\"scope\":{\"name\":\"fastapi_mojo.bridge\"}"));
    assert!(json.contains("\"traceId\":\""));
    assert!(json.contains("\"spanId\":\""));
    assert!(json.contains("\"name\":\"GET /health\""));
    assert!(json.contains("\"key\":\"http.request.method\",\"value\":{\"stringValue\":\"GET\"}"));
    assert!(json.contains("\"key\":\"url.path\",\"value\":{\"stringValue\":\"/health\"}"));
    assert!(json.contains("\"key\":\"http.response.status_code\",\"value\":{\"intValue\":200}"));
    assert!(json.contains("\"name\":\"POST /items\""));
    assert!(json.contains("\"key\":\"http.response.status_code\",\"value\":{\"intValue\":201}"));
    assert!(json.rfind("GET /health").unwrap() < json.rfind("POST /items").unwrap());
    reset();
}

#[test]
fn trace_export_slice_is_nul_terminated() {
    reset();
    trace_record("GET", "/health", "", "204 No Content", 0);
    let (len, ptr) = traces_get_slice();
    assert!(len > 0);
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len + 1) };
    assert_eq!(bytes[len], 0, "FFI CStringSlice contract requires BUF[len]=0");
    reset();
}
