# src/fastapi_mojo/body_json_test.mojo
#
# 决策-85 (ADR-0060) executable tests for body_json (strict JSON scan +
# Content-Type dispatch). Same-dir split keeps both production and test
# modules below the 500-line God-file threshold.

from body_json import validate_body_json, content_type_is_json



def _assert_ok(body: String, kind: String) raises:
    var r = validate_body_json(body)
    if not r.ok or r.top_kind != kind:
        raise Error("body_json selftest: expected ok/" + kind + " for " + body)


def _assert_err(body: String, pos: Int, msg: String) raises:
    var r = validate_body_json(body)
    if r.ok or r.err_pos != pos or r.err_msg != msg:
        raise Error("body_json selftest: expected err " + msg + "@" +
                    String(pos) + " for " + body + " (got " + r.err_msg +
                    "@" + String(r.err_pos) + ")")


def main() raises:
    print("Testing body_json (strict JSON scan + content-type dispatch)...")
    _assert_ok('{"a":1}', "object")
    _assert_ok('  [1, 2]  ', "array")
    _assert_ok('"hi"', "string")
    _assert_ok('5', "number")
    _assert_ok('-1.5e3', "number")
    _assert_ok('NaN', "number")
    _assert_ok('-Infinity', "number")
    _assert_ok('true', "bool")
    _assert_ok('null', "null")
    _assert_ok('{}', "object")
    _assert_ok('{"a":{"b":[1,{"c":null}]}}', "object")
    _assert_err('{bad', 1, "Expecting property name enclosed in double quotes")
    _assert_err('{"x":1}trailing', 7, "Extra data")
    _assert_err('   ', 3, "Expecting value")
    _assert_err('{', 1, "Expecting property name enclosed in double quotes")
    _assert_err('[', 1, "Expecting value")
    _assert_err('[1,', 3, "Expecting value")
    _assert_err('[1 2]', 3, "Expecting ',' delimiter")
    _assert_err('{"x":}', 5, "Expecting value")
    _assert_err('{"x" 1}', 5, "Expecting ':' delimiter")
    _assert_err('{"a":1,}', 7, "Expecting property name enclosed in double quotes")
    _assert_err('{1:2}', 1, "Expecting property name enclosed in double quotes")
    _assert_err('{"x":01}', 6, "Expecting ',' delimiter")
    _assert_err('{"x":1.}', 6, "Expecting ',' delimiter")
    _assert_err('{"x":.5}', 5, "Expecting value")
    _assert_err('{"x":+1}', 5, "Expecting value")
    _assert_err('{"x":-}', 5, "Expecting value")
    _assert_err('{"x":tru}', 5, "Expecting value")
    _assert_err('{"x":"abc}', 5, "Unterminated string starting at")
    _assert_err('{"x":"a\\qb"}', 7, "Invalid \\escape")
    _assert_err('{"x":"a\\u12zz"}', 8, "Invalid \\uXXXX escape")
    _assert_err('5x', 1, "Extra data")
    _assert_err('nul', 0, "Expecting value")
    _assert_err('falsee', 5, "Extra data")
    _assert_err('{"a":{"b":}}', 10, "Expecting value")
    _assert_err('[1,2', 4, "Expecting ',' delimiter")
    _assert_err('{"x":1}{', 7, "Extra data")
    # content-type dispatch
    if not content_type_is_json("application/json"):
        raise Error("ct json")
    if not content_type_is_json("application/json; charset=utf-8"):
        raise Error("ct json param")
    if not content_type_is_json("APPLICATION/JSON"):
        raise Error("ct case")
    if not content_type_is_json("application/vnd.api+json"):
        raise Error("ct +json")
    if not content_type_is_json(" application/json "):
        raise Error("ct ws")
    if content_type_is_json("text/json"):
        raise Error("ct text/json must be non-json")
    if content_type_is_json("application/jsonx"):
        raise Error("ct jsonx must be non-json")
    if content_type_is_json("application/x-www-form-urlencoded"):
        raise Error("ct form must be non-json")
    if content_type_is_json(""):
        raise Error("ct empty must be non-json")
    if content_type_is_json("multipart/form-data; boundary=x"):
        raise Error("ct multipart must be non-json")
    print("body_json selftest OK")
