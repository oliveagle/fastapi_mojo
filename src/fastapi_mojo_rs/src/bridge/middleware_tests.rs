//! middleware_tests.rs — 决策-55 (ADR-0030) 用户自定义中间件单测.
//!
//! 纯 ctx 版入口 (apply_response_ctx / log_line_ctx / parse_spec) — 不触 env /
//! CurrentRequest 全局, 故可安全并行; 仍随 crate 统一 --test-threads=1
//! (env 全局副作用纪律, 教训-12 同款).

use super::middleware::*;
use super::request::ReqCtx;

fn ctx(m: &str, p: &str, q: &str, r: &str) -> (String, Vec<u8>, String, String, bool) {
    let c = ReqCtx { method: m.into(), path: p.into(), query: q.into(), req_id: r.into() };
    apply_response_ctx(&MwStack::default(), "200 OK", b"orig", Some("Allow: GET"), &c)
}

fn c4(m: &str, p: &str, q: &str, r: &str) -> ReqCtx {
    ReqCtx { method: m.into(), path: p.into(), query: q.into(), req_id: r.into() }
}

// ---------- parse ----------

#[test]
fn mw_parse_none_and_empty() {
    assert!(parse_spec(None).mws.is_empty());
    assert!(parse_spec(Some("")).mws.is_empty());
    assert!(parse_spec(Some("   ")).mws.is_empty());
    assert!(parse_spec(Some(";")).mws.is_empty());
}

#[test]
fn mw_parse_classifies_request_vs_response() {
    let st = parse_spec(Some("HDR:A:1,LOG;MAP:/a:/b,REQHDR:X:y;BLOCK:418:tp:*"));
    assert_eq!(st.mws.len(), 3);
    // mw1: HDR, LOG -> resp
    assert_eq!(st.mws[0].resp.len(), 2);
    assert_eq!(st.mws[0].resp[0], MwVerb::Hdr { name: "A".into(), value: "1".into() });
    assert_eq!(st.mws[0].resp[1], MwVerb::Log);
    assert!(st.mws[0].req.is_empty());
    // mw2: MAP, REQHDR -> req
    assert_eq!(st.mws[1].req.len(), 2);
    assert!(matches!(&st.mws[1].req[0], MwVerb::Map { .. }));
    assert!(matches!(&st.mws[1].req[1], MwVerb::ReqHdr { .. }));
    // mw3: BLOCK -> req
    assert_eq!(st.mws[2].req.len(), 1);
    assert!(matches!(&st.mws[2].req[0], MwVerb::Block { .. }));
}

#[test]
fn mw_parse_bad_verb_fails_whole_spec() {
    // 任一动词畸形 -> 整 spec 判空 (bridge 防御; 权威校验在 Mojo 启动期).
    assert!(parse_spec(Some("FROB:x")).mws.is_empty());
    assert!(parse_spec(Some("HDR:A:B:C")).mws.is_empty()); // ':' 入值 -> 4 字段
    assert!(parse_spec(Some("STATUS:20:201")).mws.is_empty());
    assert!(parse_spec(Some("MAP:rel:/b")).mws.is_empty());
    assert!(parse_spec(Some("BLOCK:404:b:relpath")).mws.is_empty());
}

#[test]
fn mw_parse_good_variants() {
    assert!(parse_spec(Some("LOG")).mws.len() == 1);
    assert!(parse_spec(Some("STATUS:*:418")).mws.len() == 1);
    assert!(parse_spec(Some("BODY:hello {method}")).mws.len() == 1);
    assert!(parse_spec(Some("BLOCK:418:tp:/*|/a/")).mws.len() == 1);
}

// ---------- apply_response_ctx ----------

#[test]
fn mw_apply_empty_stack_passthrough() {
    let (st, bd, ex, ct, lg) = ctx("GET", "/x", "q=1", "req-9");
    assert_eq!(st, "200 OK");
    assert_eq!(bd, b"orig".to_vec());
    assert_eq!(ex, "Allow: GET");
    assert!(ct.is_empty());
    assert!(!lg);
}

#[test]
fn mw_apply_status_remap_and_hdr_and_log() {
    let st = parse_spec(Some("STATUS:200:418,HDR:X-Mw:1,LOG"));
    let (st_out, bd, ex, ct, lg) =
        apply_response_ctx(&st, "200 OK", b"orig", Some("Allow: GET"), &c4("GET", "/x", "q=1", "req-9"));
    assert_eq!(st_out, "418 I'm a Teapot");
    assert_eq!(bd, b"orig".to_vec());
    // HDR 追加到既有 extra 之后
    assert_eq!(ex, "Allow: GET\r\nX-Mw: 1");
    assert!(ct.is_empty());
    assert!(lg);
}

#[test]
fn mw_apply_hdr_replaces_same_name_last_wins() {
    // 两个 mw: 内层 (mw1) 先写, 外层 (mw2) 后写 -> 外层胜 (P-MW-2)
    let st = parse_spec(Some("HDR:X-Mw:inner;HDR:X-Mw:outer"));
    let (_st, _bd, ex, _ct, _lg) =
        apply_response_ctx(&st, "200 OK", b"o", None, &c4("GET", "/x", "", "r"));
    // 只应有一条 X-Mw 行, 值 = outer
    let lines: Vec<&str> = ex.split("\r\n").collect();
    let hits: Vec<&str> = lines.iter().filter(|l| l.starts_with("X-Mw:")).copied().collect();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0], "X-Mw: outer");
}

#[test]
fn mw_apply_body_replaces_and_sets_ct() {
    let st = parse_spec(Some("BODY:GOT {method} {path} {status} {req_id}"));
    let (st_out, bd, ex, ct, lg) =
        apply_response_ctx(&st, "200 OK", b"orig", Some("K: V"), &c4("GET", "/p", "a=1", "req-77"));
    assert_eq!(st_out, "200 OK");
    assert_eq!(bd, b"GOT GET /p 200 req-77".to_vec());
    assert_eq!(ct, "text/plain; charset=utf-8");
    assert_eq!(ex, "K: V");
    assert!(!lg);
}

#[test]
fn mw_apply_status_star() {
    let st = parse_spec(Some("STATUS:*:503"));
    let (st_out, _, _, _, _) =
        apply_response_ctx(&st, "404 Not Found", b"o", None, &c4("GET", "/x", "", "r"));
    assert_eq!(st_out, "503 Service Unavailable");
}

#[test]
fn mw_apply_status_no_match_keeps() {
    let st = parse_spec(Some("STATUS:200:418"));
    let (st_out, _, _, _, _) =
        apply_response_ctx(&st, "404 Not Found", b"o", None, &c4("GET", "/x", "", "r"));
    assert_eq!(st_out, "404 Not Found");
}

// ---------- interpolate ----------

#[test]
fn mw_interpolate_known_and_unknown_placeholders() {
    let out = interpolate("a{method}b{path}c{query}d{status}e{req_id}f{foo}g",
        "GET", "/p", "q=1", "200", "req-3");
    assert_eq!(out, "aGETb/pcq=1d200ereq-3f{foo}g");
}

// ---------- log_line_ctx ----------

#[test]
fn mw_log_line_with_and_without_query() {
    assert_eq!(log_line_ctx("GET", "/x", "a=1", "req-5", "200 OK"),
        "[mw] req-5 GET /x?a=1 -> 200 OK");
    assert_eq!(log_line_ctx("GET", "/x", "", "req-5", "404 Not Found"),
        "[mw] req-5 GET /x -> 404 Not Found");
}

// ---------- status_name ----------

#[test]
fn mw_status_name_known_and_fallback() {
    assert_eq!(status_name("200"), "OK");
    assert_eq!(status_name("418"), "I'm a Teapot");
    assert_eq!(status_name("999"), "Unknown");
}

// ---------- 短路 (BLOCK 于 mwK → 响应仅过 mwK+1..mwN 响应动词, ADR-0030 §3.2) ----------

#[test]
fn mw_plan_path_map_exact_and_prefix() {
    // MAP:/api:/internal (TO 非 / 尾) → /api/users → /internal/users
    let (p2, k) = plan_request_path(&parse_spec(Some("MAP:/api:/internal")), "/api/users");
    assert_eq!(p2, "/internal/users");
    assert_eq!(k, None);
    // TO 以 / 尾 → 无双斜杠
    let (p2b, _) = plan_request_path(&parse_spec(Some("MAP:/api:/internal/")), "/api/users");
    assert_eq!(p2b, "/internal/users");
    // 精确
    let (p2c, _) = plan_request_path(&parse_spec(Some("MAP:/api:/internal")), "/api");
    assert_eq!(p2c, "/internal");
    // 不命中 → 原样
    let (p2d, _) = plan_request_path(&parse_spec(Some("MAP:/api:/internal")), "/other");
    assert_eq!(p2d, "/other");
}

#[test]
fn mw_plan_path_block_star_and_prefix() {
    // `*` = 全部
    let (_, k) = plan_request_path(&parse_spec(Some("BLOCK:418:tp:*")), "/x");
    assert_eq!(k, Some(0));
    // `prefix/` = 前缀
    let (_, kp) = plan_request_path(&parse_spec(Some("BLOCK:403:b:/secret/")), "/secret/x");
    assert_eq!(kp, Some(0));
    let (_, kn) = plan_request_path(&parse_spec(Some("BLOCK:403:b:/secret/")), "/public");
    assert_eq!(kn, None);
    // 精确
    let (_, ke) = plan_request_path(&parse_spec(Some("BLOCK:403:b:/ex")), "/ex");
    assert_eq!(ke, Some(0));
    let (_, kno) = plan_request_path(&parse_spec(Some("BLOCK:403:b:/ex")), "/extra");
    assert_eq!(kno, None);
}

#[test]
fn mw_plan_path_map_then_block_uses_rewritten_path() {
    // outer→inner: mw1(MAP) 在内, mw2(BLOCK) 在外. 请求 /a: mw2 先 (无 MAP, 无 BLOCK
    // 命中 /a?), 再 mw1 的 MAP. 此处 BLOCK 在外层且 paths=/a (原始) → 命中原始 /a.
    // 为验证 MAP 先于外层 BLOCK: 把 MAP 放外层, BLOCK 放内层.
    // spec: mw1(内)=BLOCK:418:tp:/b; mw2(外)=MAP:/a:/b. 请求 /a →
    // 外层 mw2 的 MAP 先 (/a→/b), 再内层 mw1 的 BLOCK 对 /b 命中 → 短路 at mw1 (index 0).
    let (p2, k) = plan_request_path(
        &parse_spec(Some("BLOCK:418:tp:/b;MAP:/a:/b")),
        "/a",
    );
    assert_eq!(p2, "/b");
    assert_eq!(k, Some(0));
}

#[test]
fn mw_short_circuit_only_outer_response_verbs_apply() {
    // env 序: mw1(内)=HDR:In:1; mw2=BLOCK:418:tp:*; mw3(外)=HDR:Out:1.
    // GET /x 命中 mw2 的 BLOCK(*) → 短路 at index 1: 仅 mw3(index 2) 响应动词应用.
    let st = parse_spec(Some("HDR:In:1;BLOCK:418:tp:*;HDR:Out:1"));
    let (_s, _bd, ex, _ct, _lg) =
        apply_response_ctx(&st, "418 I'm a Teapot", b"tp", None, &c4("GET", "/x", "", "r1"));
    assert_eq!(ex, "Out: 1"); // In:1 (内层) 与 blocker 自身均不出现
}

#[test]
fn mw_no_block_all_response_verbs_apply() {
    // 同 spec 但 BLOCK 精确 /zzz 不命中 /x → 无短路: inner 先, outer 后, 不同名两行.
    let st = parse_spec(Some("HDR:In:1;BLOCK:418:tp:/zzz;HDR:Out:1"));
    let (_s, _bd, ex, _ct, _lg) =
        apply_response_ctx(&st, "200 OK", b"o", None, &c4("GET", "/x", "", "r1"));
    assert_eq!(ex, "In: 1\r\nOut: 1");
}

#[test]
fn mw_short_circuit_body_uses_rewritten_path() {
    // mw1(内)=BODY:R{path}; mw2(外)=MAP:/a:/b + (响应面无). 请求 /a →
    // 无 BLOCK → 无短路; 响应动词仅 mw1 的 BODY, 插值用重写后 path /b.
    let st = parse_spec(Some("BODY:R{path};MAP:/a:/b"));
    let (_s, bd, _ex, ct, _lg) =
        apply_response_ctx(&st, "200 OK", b"orig", None, &c4("GET", "/a", "", "r1"));
    assert_eq!(bd, b"R/b".to_vec());
    assert_eq!(ct, "text/plain; charset=utf-8");
}
