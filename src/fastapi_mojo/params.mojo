# src/fastapi_mojo/params.mojo
#
# Mojo native Path/Query/Body parameter parsing.
#
# v3 (hardened):
#   - parse_body_json: real JSON object parser (strings with escapes, commas/
#     colons inside string values, nested values kept as raw JSON,
#     surrogate pairs combined; lone surrogates -> U+FFFD, never chr() on a
#     surrogate which would abort the process).
#   - parse_query_params: URL-decodes to raw bytes, then UTF-8 decodes;
#     handles ?flag (no value), values with '=', malformed %XX (kept literal).
#   - All string building is linear (StringBuilder), no O(n^2) concatenation.

from string_builder import decode_utf8_bytes, StringBuilder, next_codepoint_len

struct ParsedParams:
    """Parsed parameter result."""
    var has_error: Bool
    var error_msg: String
    var param_count: Int
    var values: Dict[String, String]

    def __init__(out self):
        self.has_error = False
        self.error_msg = ""
        self.param_count = 0
        self.values = Dict[String, String]()

    def __init__(out self, param_count: Int, values: Dict[String, String]):
        self.has_error = False
        self.error_msg = ""
        self.param_count = param_count
        self.values = values.copy()

    def __init__(out self, error_msg: String):
        self.has_error = True
        self.error_msg = error_msg
        self.param_count = 0
        self.values = Dict[String, String]()


def parse_path_params(path: String, pattern: String) -> ParsedParams:
    """Parse path params, return extracted values."""
    var path_parts = path.split("/")
    var pattern_parts = pattern.split("/")

    if len(path_parts) != len(pattern_parts):
        return ParsedParams("length mismatch")

    var params = Dict[String, String]()
    for i in range(len(pattern_parts)):
        var pp = pattern_parts[i]
        var ap = path_parts[i]
        if pp.startswith("{") and pp.endswith("}"):
            var param_name = String(pp[byte=1 : pp.byte_length() - 1])
            params[param_name] = String(ap)

    return ParsedParams(len(params), params)


# ---------- URL decoding ----------

def _hexval(s: String, i: Int) -> Int:
    """Hex digit value of s[byte=i] (0-15), or -1 if not a hex digit.

    Lookup table is "0-9" (k=0..9), "a-f" (k=10..15), "A-F" (k=16..21);
    uppercase maps via k-6, not k%16 (which would give 0..5)."""
    var h = "0123456789abcdefABCDEF"
    for k in range(h.byte_length()):
        if s[byte=i] == h[byte=k]:
            if k <= 15:
                return k
            return k - 6
    return -1


def url_decode(s: String) -> String:
    """Decode a percent-encoded (URL) string to a UTF-8 String.

    '+' becomes space; %XX becomes the raw byte XX (bytes are then UTF-8
    decoded, so %C3%A9 -> é). Malformed %XX keeps the literal '%'."""
    var bs = List[Int]()
    var n = s.byte_length()
    var i = 0
    while i < n:
        var c = s[byte=i]
        if c == '%':
            if i + 2 < n:
                var hi = _hexval(s, i + 1)
                var lo = _hexval(s, i + 2)
                if hi >= 0 and lo >= 0:
                    bs.append(hi * 16 + lo)
                    i += 3
                    continue
            bs.append(0x25)  # literal '%'
            i += 1
        elif c == '+':
            bs.append(0x20)
            i += 1
        else:
            var cp = ord(c)
            if cp < 0x80:
                bs.append(cp)
                i += 1
            else:
                # raw non-ASCII in a query string is not valid per RFC 3986
                # (should be percent-encoded): replace the whole codepoint
                # with '?' and skip its bytes (ord() would assert on the
                # continuation bytes).
                bs.append(0x3F)
                if cp < 0x800:
                    i += 2
                elif cp < 0x10000:
                    i += 3
                else:
                    i += 4
    return decode_utf8_bytes(bs)


def parse_query_params(query: String) -> ParsedParams:
    """Parse query string into key-value Dict (URL-decoded)."""
    if query == "":
        return ParsedParams(0, Dict[String, String]())

    var params = Dict[String, String]()
    var pairs = query.split("&")
    for i in range(len(pairs)):
        var pair = String(pairs[i])
        if pair == "":
            continue
        var eq = -1
        var k = 0
        var pn = pair.byte_length()
        while k < pn:
            if pair[byte=k] == '=':
                eq = k
                break
            k += next_codepoint_len(pair, k)
        if eq < 0:
            # ?flag — boolean flag, empty value
            params[url_decode(pair)] = ""
        else:
            var key = String(pair[byte=0 : eq])
            var val = String(pair[byte=eq+1 : pair.byte_length()])
            params[url_decode(key)] = url_decode(val)

    return ParsedParams(len(params), params)


# ---------- JSON parsing ----------

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


def _parse_value_raw(s: String, i: Int) -> Tuple[String, Int]:
    """Parse a JSON value. Strings -> unescaped; others -> raw JSON text.
    Return (text, index_after)."""
    var n = s.byte_length()
    var j = _skip_ws(s, i)
    if j >= n:
        return ("", j)
    var c = s[byte=j]
    if c == '"':
        return _parse_string(s, j)
    if c == '{' or c == '[':
        var start = j
        var depth = 0
        var in_str = False
        var esc = False
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
    # scalar (number/true/false/null): scan to delimiter, do not consume it
    var start = j
    while j < n:
        var cc = s[byte=j]
        if cc == ',' or cc == '}' or cc == ']' or _is_ws(s, j):
            break
        j += 1
    return (String(s[byte=start : j]), j)


def parse_body_json(body: String) -> ParsedParams:
    """Parse a JSON object body into key-value Dict.
    String values are unescaped; other values are raw JSON text."""
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
        var val_pair = _parse_value_raw(body, j)
        var val = val_pair[0]
        j = val_pair[1]
        params[key] = val
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

    return ParsedParams(len(params), params)


def main() raises:
    print("Testing Mojo params parsing...")

    # Path params
    var r1 = parse_path_params("/items/42", "/items/{item_id}")
    if r1.values["item_id"] == "42":
        print("OK: path param item_id=42")

    var r2 = parse_path_params("/users/123/items/456", "/users/{user_id}/items/{item_id}")
    if r2.values["user_id"] == "123" and r2.values["item_id"] == "456":
        print("OK: multi path params")

    # Query params
    var r3 = parse_query_params("name=Mojo&age=30")
    if r3.values["name"] == "Mojo" and r3.values["age"] == "30":
        print("OK: query params")

    var r3b = parse_query_params("greeting=hello%20world&flag")
    if r3b.values["greeting"] == "hello world" and "flag" in r3b.values:
        print("OK: url decode + flag")

    var r3c = parse_query_params("a=b=c")
    if r3c.values["a"] == "b=c":
        print("OK: value with =")

    var r3d = parse_query_params("msg=%C3%A9%20ok")
    if r3d.values["msg"] == "é ok":
        print("OK: utf8 percent decode")

    var r3e = parse_query_params("bad=%zz%41")
    if r3e.values["bad"] == "%zzA":
        print("OK: malformed %XX kept literal")

    # Body JSON
    var r4 = parse_body_json('{"name":"John","age":"30"}')
    if r4.values["name"] == "John" and r4.values["age"] == "30":
        print("OK: body json simple")

    var r4b = parse_body_json('{"msg":"a,b:c","n":42,"ok":true}')
    if r4b.values["msg"] == "a,b:c" and r4b.values["n"] == "42" and r4b.values["ok"] == "true":
        print("OK: body json commas/colons/numbers/bools")

    var r4c = parse_body_json('{"s":"he said \\"hi\\"\\n"}')
    if r4c.values["s"] == "he said \"hi\"\n":
        print("OK: body json escapes")

    var r4d = parse_body_json('{"emoji":"\\uD83D\\uDE00"}')
    if r4d.values["emoji"] == "😀":
        print("OK: surrogate pair -> U+1F600")

    var r4e = parse_body_json('{"uni":"\\u00e9"}')
    if r4e.values["uni"] == "é":
        print("OK: \\u00e9 -> é")

    var r4f = parse_body_json('{"bad":"\\ud800"}')
    if r4f.values["bad"] == "�":
        print("OK: lone surrogate -> U+FFFD")

    var r5 = parse_query_params("")
    if r5.param_count == 0:
        print("OK: empty query")

    var r6 = parse_body_json("")
    if r6.has_error:
        print("OK: empty body error")

    var r7 = parse_body_json("not json")
    if r7.has_error:
        print("OK: invalid json error")

    print("Mojo params parsing test completed!")
