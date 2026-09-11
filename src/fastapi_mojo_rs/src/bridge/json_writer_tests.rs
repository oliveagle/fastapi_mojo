use super::json_writer::{JsonObjectWriter, NESTED_PREFIX};

#[test]
fn empty_object_is_empty_braces() {
    let mut w = JsonObjectWriter::new();
    assert_eq!(w.finish(), b"{}");
}

#[test]
fn ordinary_members_use_json_mojo_spacing() {
    let mut w = JsonObjectWriter::new();
    w.add_field(b"message", b"hello", false);
    w.add_field(b"count", b"42", false);
    assert_eq!(w.finish(), b"{\"message\": \"hello\", \"count\": \"42\"}");
}

#[test]
fn escapes_match_mojo_contract() {
    let mut w = JsonObjectWriter::new();
    w.add_field(b"s", b"a\"b\\c\nd\re\tf\x08g\x0ch\x01\xff", false);
    let mut expected =
        b"{\"s\": \"a\\\"b\\\\c\\nd\\re\\tf\\u0008g\\u000ch\\u0001".to_vec();
    expected.push(0xff);
    expected.push(b'"');
    expected.push(b'}');
    assert_eq!(w.finish(), expected);
}

#[test]
fn nested_marker_suffix_is_raw_json() {
    let mut value = NESTED_PREFIX.to_vec();
    value.extend_from_slice(b"{\"a\":1}");
    let mut w = JsonObjectWriter::new();
    w.add_field(b"data", &value, true);
    assert_eq!(w.finish(), b"{\"data\": {\"a\":1}}");
}

#[test]
fn non_raw_nested_marker_is_escaped_like_mojo() {
    let mut value = NESTED_PREFIX.to_vec();
    value.extend_from_slice(b"42");
    let mut w = JsonObjectWriter::new();
    w.add_field(b"data", &value, false);
    assert_eq!(w.finish(), b"{\"data\": \"__nested__:42\"}");
}

#[test]
fn embedded_nul_is_json_escaped_not_terminated() {
    let mut w = JsonObjectWriter::new();
    w.add_field(b"k", b"a\0b", false);
    assert_eq!(w.finish(), b"{\"k\": \"a\\u0000b\"}");
}

#[test]
fn writer_is_reusable_after_finish() {
    let mut w = JsonObjectWriter::new();
    w.add_field(b"a", b"1", false);
    assert_eq!(w.finish(), b"{\"a\": \"1\"}");
    w.add_field(b"b", b"2", false);
    assert_eq!(w.finish(), b"{\"b\": \"2\"}");
}
