# src/fastapi_mojo/params_json.mojo
#
# Mojo 原生 Body JSON 解析 (P4.4 拆分自 params.mojo, 并类型化).
#
#   - parse_body_json: 真实 JSON object 解析器 (字符串转义/值内逗号冒号/
#     嵌套值保留 raw JSON/代理对合并; 孤立代理 -> U+FFFD, 绝不 chr() 代理
#     — 那会 abort 进程).
#   - P4.4 类型化: 每个值带类型标记 "string"/"int"/"float"/"bool"/
#     "null"/"object"/"array" (ParsedParams.types + type_of()).
#
# Query/Path 参数解析见 params_query.mojo。

from string_builder import StringBuilder, next_codepoint_len
from params_query import ParsedParams, _hexval


def _is_ws(s: String, i: Int) -> Bool:
    var c = s[byte=i]
    return c == ' ' or c == '\t' or c == '\n' or c == '\r'


def _skip_ws(s: String, i: Int) -> Int:
    var n = s.byte_length()
    var j = i
    while j < n:
        if _is_ws(s, j):
            j += 1
        else:
            break
    return j


def _parse_unicode_escape(s: String, j: Int) -> Tuple[Int, Int]:
    """Parse a \\uXXXX escape whose 'u' sits at index j.

    Returns (codepoint, index_after). Combines surrogate pairs
    (\\uD83D\\uDE00 -> U+1F600); lone surrogates / bad hex -> U+FFFD.
    Never returns a surrogate codepoint (chr() would abort on them)."""
    var n = s.byte_length()
    if j + 4 >= n:
        return (0xFFFD, j + 1)
    var code = 0
    var k = 1
    while k <= 4:
        var d = _hexval(s, j + k)
        if d < 0:
            return (0xFFFD, j + 1)
        code = code * 16 + d
        k += 1
    if 0xD800 <= code <= 0xDBFF:
        # possible surrogate pair: expect "\uXXXX" low surrogate right after
        if j + 10 < n and s[byte=j+5] == '\\' and s[byte=j+6] == 'u':
            var code2 = 0
            var ok = True
            var k2 = 1
            while k2 <= 4:
                var d2 = _hexval(s, j + 6 + k2)
                if d2 < 0:
                    ok = False
                    break
                code2 = code2 * 16 + d2
                k2 += 1
            if ok and 0xDC00 <= code2 <= 0xDFFF:
                var cp = 0x10000 + ((code - 0xD800) << 10) + (code2 - 0xDC00)
                return (cp, j + 11)
        return (0xFFFD, j + 5)  # lone high surrogate
    if 0xDC00 <= code <= 0xDFFF:
        return (0xFFFD, j + 5)  # lone low surrogate
    return (code, j + 5)


def _parse_string(s: String, i: Int) -> Tuple[String, Int]:
    """Parse a JSON string at opening quote. Return (unescaped, index_after).

    Linear time (StringBuilder); handles all JSON escapes including
    \\uXXXX and surrogate pairs."""
    var n = s.byte_length()
    if i >= n or not (s[byte=i] == '"'):
        return ("", i)
    var j = i + 1
    var sb = StringBuilder()
    while j < n:
        var c = s[byte=j]
        # j is always on a codepoint boundary; multi-byte codepoints are
        # copied as whole runs (a continuation byte is never a JSON token)
        if ord(c) >= 0x80:
            sb.append(String(s[byte=j:j+next_codepoint_len(s, j)]))
            j += next_codepoint_len(s, j)
            continue
        if c == '"':
            return (sb.take(), j + 1)
        if c == '\\':
            j += 1
            if j >= n:
                break
            var e = s[byte=j]
            if e == '"':
                sb.append('"')
                j += 1
            elif e == '\\':
                sb.append("\\")
                j += 1
            elif e == '/':
                sb.append('/')
                j += 1
            elif e == 'b':
                sb.append('\b')
                j += 1
            elif e == 'f':
                sb.append('\f')
                j += 1
            elif e == 'n':
                sb.append('\n')
                j += 1
            elif e == 'r':
                sb.append('\r')
                j += 1
            elif e == 't':
                sb.append('\t')
                j += 1
            elif e == 'u':
                var pair = _parse_unicode_escape(s, j)
                sb.append_codepoint(pair[0])
                j = pair[1]
            else:
                sb.append(String(e))
                j += 1
        else:
            sb.append(String(c))
            j += 1
    return (sb.take(), j)


def _scan_container(s: String, i: Int) -> Tuple[String, Int]:
    """扫描 JSON 容器 ({...} 或 [...]) 从 i 开始. 返回 (raw JSON, index_after)."""
    var n = s.byte_length()
    var start = i
    var depth = 0
    var in_str = False
    var esc = False
    var j = i
    while j < n:
        var cc = s[byte=j]
        if ord(cc) >= 0x80:
            # multi-byte codepoint: cannot be a JSON structural char
            j += next_codepoint_len(s, j)
            continue
        if in_str:
            if esc:
                esc = False
            elif cc == '\\':
                esc = True
            elif cc == '"':
                in_str = False
        else:
            if cc == '"':
                in_str = True
            elif cc == '{' or cc == '[':
                depth += 1
            elif cc == '}' or cc == ']':
                depth -= 1
                if depth == 0:
                    j += 1
                    break
        j += 1
    return (String(s[byte=start : j]), j)


def _parse_value_raw(s: String, i: Int) -> Tuple[String, String, Int]:
    """解析 JSON 值. 返回 (value, type, index_after).
    string -> (unescaped, "string"); object -> (raw JSON, "object");
    array -> (raw JSON, "array"); number -> (raw, "int"|"float");
    true/false -> (raw, "bool"); null -> ("null", "null")."""
    var n = s.byte_length()
    var j = _skip_ws(s, i)
    if j >= n:
        return ("", "null", j)
    var c = s[byte=j]
    if c == '"':
        var p = _parse_string(s, j)
        return (p[0], "string", p[1])
    if c == '{':
        var t = _scan_container(s, j)
        return (t[0], "object", t[1])
    if c == '[':
        var t2 = _scan_container(s, j)
        return (t2[0], "array", t2[1])
    # scalar (number/true/false/null): scan to delimiter, do not consume it
    var start = j
    while j < n:
        var cc = s[byte=j]
        if cc == ',' or cc == '}' or cc == ']' or _is_ws(s, j):
            break
        j += 1
    var raw = String(s[byte=start : j])
    if raw == "true" or raw == "false":
        return (raw, "bool", j)
    if raw == "null":
        return (raw, "null", j)
    var is_float = False
    for k in range(raw.byte_length()):
        var ch = raw[byte=k]
        if ch == '.' or ch == 'e' or ch == 'E':
            is_float = True
            break
    if is_float:
        return (raw, "float", j)
    return (raw, "int", j)

def parse_body_json(body: String) -> ParsedParams:
    """解析 JSON object body 为带类型标记的 key-value 对 (P4.4 类型化).
    string 值 unescape ("string"); number -> "int"/"float"; true/false ->
    "bool"; null -> "null"; 嵌套 object/array 保留 raw JSON 文本
    ("object"/"array")."""
    if body == "":
        return ParsedParams("empty body")

    var n = body.byte_length()
    var j = _skip_ws(body, 0)
    if j >= n or not (body[byte=j] == '{'):
        return ParsedParams("not JSON object")
    j += 1
    j = _skip_ws(body, j)
    if j < n and body[byte=j] == '}':
        return ParsedParams(0, Dict[String, String]())

    var params = Dict[String, String]()
    var types = Dict[String, String]()
    while j < n:
        j = _skip_ws(body, j)
        if j >= n:
            break
        if not (body[byte=j] == '"'):
            return ParsedParams("invalid JSON: key not a string")
        var key_pair = _parse_string(body, j)
        var key = key_pair[0]
        j = key_pair[1]
        j = _skip_ws(body, j)
        if j >= n or not (body[byte=j] == ':'):
            return ParsedParams("invalid JSON: expected ':'")
        j += 1
        var val = _parse_value_raw(body, j)
        params[key] = val[0]
        types[key] = val[1]
        j = val[2]
        j = _skip_ws(body, j)
        if j < n:
            if body[byte=j] == ',':
                j += 1
                continue
            elif body[byte=j] == '}':
                break
            else:
                return ParsedParams("invalid JSON: expected ',' or '}'")
        else:
            break

    return ParsedParams(len(params), params, types)

def main() raises:
    print("Testing Mojo params (JSON body)...")

    var r4 = parse_body_json('{"name":"John","age":"30"}')
    assert r4.values["name"] == "John" and r4.type_of("name") == "string", "body json simple"
    assert r4.values["age"] == "30" and r4.type_of("age") == "string", "age is a JSON string"

    var r4b = parse_body_json('{"msg":"a,b:c","n":42,"ok":true}')
    assert r4b.values["msg"] == "a,b:c", "commas/colons in string"
    assert r4b.values["n"] == "42" and r4b.type_of("n") == "int", "int type"
    assert r4b.values["ok"] == "true" and r4b.type_of("ok") == "bool", "bool type"

    var r4c = parse_body_json('{"s":"he said \\"hi\\"\\n"}')
    assert r4c.values["s"] == 'he said "hi"\n' and r4c.type_of("s") == "string", "escapes"

    var r4d = parse_body_json('{"emoji":"\\uD83D\\uDE00"}')
    assert r4d.values["emoji"] == "\U0001F600" and r4d.type_of("emoji") == "string", "surrogate pair"

    var r4e = parse_body_json('{"uni":"\\u00e9"}')
    assert r4e.values["uni"] == "é" and r4e.type_of("uni") == "string", "unicode escape decoded"

    # P4.4 类型化断言
    var rt = parse_body_json('{"i":42,"f":3.14,"s":"hi","b":false,"n":null,"neg":-5,"exp":1e3}')
    assert rt.type_of("i") == "int" and rt.values["i"] == "42", "int 42"
    assert rt.type_of("f") == "float" and rt.values["f"] == "3.14", "float 3.14"
    assert rt.type_of("s") == "string", "string"
    assert rt.type_of("b") == "bool" and rt.values["b"] == "false", "bool false"
    assert rt.type_of("n") == "null" and rt.values["n"] == "null", "null"
    assert rt.type_of("neg") == "int" and rt.values["neg"] == "-5", "negative int"
    assert rt.type_of("exp") == "float" and rt.values["exp"] == "1e3", "exponent float"

    var ro = parse_body_json('{"o":{"a":1},"arr":[1,2]}')
    assert ro.type_of("o") == "object" and ro.values["o"] == '{"a":1}', "nested object raw"
    assert ro.type_of("arr") == "array" and ro.values["arr"] == "[1,2]", "nested array raw"

    var r6 = parse_body_json("")
    assert r6.has_error, "empty body error"
    var r7 = parse_body_json("not json")
    assert r7.has_error, "invalid json error"

    print("Mojo params (JSON body) test completed!")
