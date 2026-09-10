// testclient_tests.rs — pure unit tests (no network).

use super::http::{HttpOpts, build_body, redirect_method};
use super::{Action, CookieJar, RcvKind, cookie_header, parse_action, parse_url, url_encode};

// ---------- parse_url ----------

#[test]
fn parse_url_http_full() {
    let p = parse_url("http://example.com:8080/api/v1").expect("parse");
    assert_eq!(p.host, "example.com");
    assert_eq!(p.port, 8080);
    assert_eq!(p.path, "/api/v1");
}

#[test]
fn parse_url_ws_full() {
    let p = parse_url("ws://127.0.0.1:8117/ws/chat").expect("parse");
    assert_eq!(p.host, "127.0.0.1");
    assert_eq!(p.port, 8117);
    assert_eq!(p.path, "/ws/chat");
}

#[test]
fn parse_url_no_port_default_80() {
    let p = parse_url("http://example.com/x").expect("parse");
    assert_eq!(p.port, 80);
    assert_eq!(p.path, "/x");
}

#[test]
fn parse_url_bare_path_local_default() {
    let p = parse_url("/health").expect("parse");
    assert_eq!(p.host, "127.0.0.1");
    assert_eq!(p.port, 8000);
    assert_eq!(p.path, "/health");
}

// ---------- url_encode ----------

#[test]
fn url_encode_space_to_plus() {
    assert_eq!(url_encode("a b c"), "a+b+c");
}

#[test]
fn url_encode_special_chars() {
    assert_eq!(url_encode("a&b=c"), "a%26b%3Dc");
}

#[test]
fn url_encode_unicode() {
    assert_eq!(url_encode("héllo"), "h%C3%A9llo");
}

#[test]
fn url_encode_keeps_unreserved() {
    assert_eq!(url_encode("A-z._~09"), "A-z._~09");
}

// ---------- parse_action ----------

#[test]
fn parse_action_send_text() {
    match parse_action("send-text:hi there").expect("parse") {
        Action::SendText(p) => assert_eq!(p, "hi there"),
        _ => panic!("wrong variant"),
    }
}

#[test]
fn parse_action_send_json() {
    match parse_action("send-json:{\"a\":1}").expect("parse") {
        Action::SendJson(p) => assert_eq!(p, "{\"a\":1}"),
        _ => panic!("wrong variant"),
    }
}

#[test]
fn parse_action_send_bytes() {
    match parse_action("send-bytes:deadbeef").expect("parse") {
        Action::SendBytes(b) => assert_eq!(b, vec![0xde, 0xad, 0xbe, 0xef]),
        _ => panic!("wrong variant"),
    }
}

#[test]
fn parse_action_close_with_reason() {
    match parse_action("close:4001:see you").expect("parse") {
        Action::Close(c, r) => {
            assert_eq!(c, 4001);
            assert_eq!(r, "see you");
        }
        _ => panic!("wrong variant"),
    }
}

#[test]
fn parse_action_expect_close_reason_with_space() {
    match parse_action("expect-close:4001:custom reason").expect("parse") {
        Action::ExpectClose(c, r) => {
            assert_eq!(c, 4001);
            assert_eq!(r.as_deref(), Some("custom reason"));
        }
        _ => panic!("wrong variant"),
    }
}

#[test]
fn parse_action_receive_text_expect() {
    match parse_action("receive-text:hello").expect("parse") {
        Action::Receive(k, e) => {
            assert!(matches!(k, RcvKind::Text));
            assert_eq!(e.as_deref(), Some("hello"));
        }
        _ => panic!("wrong variant"),
    }
}

#[test]
fn parse_action_receive_bare_raw_none() {
    match parse_action("receive").expect("parse") {
        Action::Receive(k, e) => {
            assert!(matches!(k, RcvKind::Raw));
            assert!(e.is_none());
        }
        _ => panic!("wrong variant"),
    }
}

#[test]
fn parse_action_bad_close_code() {
    assert!(parse_action("close:abc").is_err());
}

#[test]
fn parse_action_unknown_verb() {
    assert!(parse_action("nope:1").is_err());
}

// ---------- CookieJar ----------

#[test]
fn jar_empty_header_none() {
    let j = CookieJar { entries: Vec::new() };
    assert!(cookie_header(&j.entries).is_none());
}

#[test]
fn jar_set_replaces_and_joins() {
    let mut j = CookieJar { entries: Vec::new() };
    j.set("a", "1");
    j.set("b", "2");
    j.set("a", "3");
    assert_eq!(cookie_header(&j.entries).as_deref(), Some("b=2; a=3")); // update moves entry to tail (LRU)
}

#[test]
fn jar_load_replaces_duplicates() {
    let p = std::env::temp_dir().join("fm_tcl_test_jar_load.txt");
    std::fs::write(&p, "a=1\nb=2\na=9\n").expect("write");
    let j = CookieJar::load(p.to_str().unwrap());
    assert_eq!(cookie_header(&j.entries).as_deref(), Some("b=2; a=9")); // later same-name line wins, moves to tail
    let _ = std::fs::remove_file(&p);
}

#[test]
fn jar_save_roundtrip() {
    let p = std::env::temp_dir().join("fm_tcl_test_jar_save.txt");
    let mut j = CookieJar { entries: Vec::new() };
    j.set("x", "y z");
    j.save(p.to_str().unwrap()).expect("save");
    let j2 = CookieJar::load(p.to_str().unwrap());
    assert_eq!(cookie_header(&j2.entries).as_deref(), Some("x=y z"));
    let _ = std::fs::remove_file(&p);
}

// ---------- redirect_method ----------

#[test]
fn redirect_303_always_get_drop() {
    let (m, drop) = redirect_method(303, "POST");
    assert_eq!(m, "GET");
    assert!(drop);
}

#[test]
fn redirect_301_post_downgrades() {
    let (m, drop) = redirect_method(301, "POST");
    assert_eq!(m, "GET");
    assert!(drop);
}

#[test]
fn redirect_302_get_preserves() {
    let (m, drop) = redirect_method(302, "GET");
    assert_eq!(m, "GET");
    assert!(!drop);
}

#[test]
fn redirect_307_preserves_post() {
    let (m, drop) = redirect_method(307, "POST");
    assert_eq!(m, "POST");
    assert!(!drop);
}

#[test]
fn redirect_200_preserves() {
    let (m, drop) = redirect_method(200, "PATCH");
    assert_eq!(m, "PATCH");
    assert!(!drop);
}

// ---------- build_body ----------

#[test]
fn build_body_form_encodes_pairs() {
    let o = HttpOpts { data_body: Some("a=1&b=2 c".to_string()), ..Default::default() };
    assert_eq!(build_body(&o), "a=1&b=2+c".as_bytes());
}

#[test]
fn build_body_raw_when_no_eq_amp() {
    let o = HttpOpts { data_body: Some("hi".to_string()), ..Default::default() };
    assert_eq!(build_body(&o), b"hi");
}

#[test]
fn build_body_json_normalizes_compact() {
    let o = HttpOpts { json_body: Some("{\"a\": 1, \"b\":[1, 2]}".to_string()), ..Default::default() };
    assert_eq!(build_body(&o), "{\"a\":1,\"b\":[1,2]}".as_bytes());
}

#[test]
fn build_body_bad_json_stays_raw() {
    let o = HttpOpts { json_body: Some("{bad".to_string()), ..Default::default() };
    assert_eq!(build_body(&o), b"{bad");
}
