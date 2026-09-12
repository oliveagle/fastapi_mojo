# src/fastapi_mojo/params_query.mojo
#
# Mojo 原生 Path/Query 参数解析 (P4.4 拆分自 params.mojo).
#
#   - parse_query_params: URL-decode 到原始字节后 UTF-8 解码; 支持 ?flag
#     (无值)、值中含 '='、畸形 %XX (保留字面量)。
#   - 多值 (决策-43): multi_values 保留每个 key 的全部 occurrence (occurrence
#     顺序); values = 扁平视图 (last-wins, Starlette MultiDict.get 语义 —
#     与 FastAPI 标量参数行为一致: ?q=a&q=b -> "b")。
#   - parse_path_params: 按 {param} 模式提取路径参数。
#   - ParsedParams: values + types (类型标记, P4.4 类型化)。
#
# Body JSON 解析见 params_json.mojo。

from string_builder import decode_utf8_bytes, StringBuilder, next_codepoint_len


struct ParsedParams:
    """Parsed parameter result (P4.4: values + type markers)."""
    var has_error: Bool
    var error_msg: String
    var param_count: Int
    var values: Dict[String, String]
    var types: Dict[String, String]  # "string"/"int"/"float"/"bool"/"null"/"object"/"array"
    var multi_values: Dict[String, List[String]]  # 决策-43: 每 key 全部 occurrence (顺序)

    def __init__(out self):
        self.has_error = False
        self.error_msg = ""
        self.param_count = 0
        self.values = Dict[String, String]()
        self.types = Dict[String, String]()
        self.multi_values = Dict[String, List[String]]()

    def __init__(out self, param_count: Int, values: Dict[String, String]):
        self.has_error = False
        self.error_msg = ""
        self.param_count = param_count
        self.values = values.copy()
        self.types = Dict[String, String]()
        self.multi_values = Dict[String, List[String]]()

    def __init__(out self, param_count: Int, values: Dict[String, String], types: Dict[String, String]):
        self.has_error = False
        self.error_msg = ""
        self.param_count = param_count
        self.values = values.copy()
        self.types = types.copy()
        self.multi_values = Dict[String, List[String]]()

    def __init__(out self, error_msg: String):
        self.has_error = True
        self.error_msg = error_msg
        self.param_count = 0
        self.values = Dict[String, String]()
        self.types = Dict[String, String]()
        self.multi_values = Dict[String, List[String]]()

    def get_multi(self, key: String) raises -> List[String]:
        """决策-43: key 的全部 occurrence; 无该 key -> 空 List (不插入)."""
        if key in self.multi_values:
            return self.multi_values[key].copy()
        return List[String]()

    def type_of(self, key: String) raises -> String:
        """Value type; untyped params (query/path) are "string"."""
        if key in self.types:
            return self.types[key]
        return "string"

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


def url_decode_path(s: String) -> String:
    """Percent-decode a URL *path* (RFC 3986 §3.3): '+' is NOT a space.

    决策-80 (ADR-0055): uvicorn percent-decodes the request path before
    Starlette routes it, so path params arrive decoded and an encoded slash
    (`%2F`) splits segments. Mirror that here: every `%XX` becomes one byte,
    other bytes are copied verbatim (the bridge already validated UTF-8), and
    the byte run is UTF-8 decoded with U+FFFD replacement (invalid sequences /
    lone `%` keep sane semantics — `%` not followed by two hex digits stays a
    literal `%`, matching `url_decode`)."""
    var bs = List[Int]()
    var n = s.byte_length()
    var i = 0
    while i < n:
        var c = s[byte=i]
        if c == '%' and i + 2 < n:
            var hi = _hexval(s, i + 1)
            var lo = _hexval(s, i + 2)
            if hi >= 0 and lo >= 0:
                bs.append(hi * 16 + lo)
                i += 3
                continue
        bs.append(ord(c))  # literal byte (ASCII or a raw UTF-8 continuation)
        i += 1
    return decode_utf8_bytes(bs)


def parse_query_params(query: String) raises -> ParsedParams:
    """Parse query string into key-value Dict (URL-decoded)."""
    if query == "":
        return ParsedParams(0, Dict[String, String]())

    var params = Dict[String, String]()
    var multi = Dict[String, List[String]]()
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
        var uk: String
        var uv: String
        if eq < 0:
            # ?flag — boolean flag, empty value
            uk = url_decode(pair)
            uv = ""
        else:
            uk = url_decode(String(pair[byte=0 : eq]))
            uv = url_decode(String(pair[byte=eq+1 : pair.byte_length()]))
        # values = 扁平 last-wins (FastAPI 标量语义); multi = 全部 occurrence
        params[uk] = uv
        if uk in multi:
            multi[uk].append(uv)
        else:
            multi[uk] = [uv]

    var out = ParsedParams(len(params), params)
    out.multi_values = multi^
    return out^


# ---------- 自测 ----------

import std.os

def check(cond: Bool, msg: String) raises:
    """真检查: Mojo 1.0.0 `assert` 是 no-op (实测, 决策-38 教训);
    用 std.os.abort() 产生非零退出."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing Mojo params (query/path)...")

    var r1 = parse_path_params("/items/42", "/items/{item_id}")
    assert r1.values["item_id"] == "42", "path param"
    assert r1.type_of("item_id") == "string", "path param type"

    var r2 = parse_path_params("/users/123/items/456", "/users/{user_id}/items/{item_id}")
    assert r2.values["user_id"] == "123" and r2.values["item_id"] == "456", "multi path"

    var r3 = parse_query_params("name=Mojo&age=30")
    assert r3.values["name"] == "Mojo" and r3.values["age"] == "30", "query"
    assert r3.type_of("name") == "string", "query type"

    var r3b = parse_query_params("greeting=hello%20world&flag")
    assert r3b.values["greeting"] == "hello world" and "flag" in r3b.values, "url decode + flag"
    assert r3b.type_of("flag") == "string", "flag type"

    var r3c = parse_query_params("a=b=c")
    assert r3c.values["a"] == "b=c", "value with ="

    var r3d = parse_query_params("msg=%C3%A9%20ok")
    assert r3d.values["msg"] == "é ok", "utf8 percent decode"

    var r3e = parse_query_params("bad=%zz%41")
    assert r3e.values["bad"] == "%zzA", "malformed %XX kept"

    var r5 = parse_query_params("")
    assert r5.param_count == 0, "empty query"

    # 决策-43: 多值 (List 参数) + 扁平 last-wins (Starlette/FastAPI 标量语义)
    var r6 = parse_query_params("tag=a&tag=b&tag=c")
    check(r6.values["tag"] == "c", "multi scalar last-wins")
    check(r6.multi_values["tag"] == ["a", "b", "c"], "multi list all occurrences")
    check(r6.get_multi("nope") == [], "get_multi absent -> empty")

    var r7 = parse_query_params("n=1&x=9&n=2")
    check(r7.multi_values["n"] == ["1", "2"], "interleaved order")
    check(r7.multi_values["x"] == ["9"], "single occurrence")
    check(r7.values["x"] == "9", "single flat value")

    var r8 = parse_query_params("flag&flag2=v")
    check(r8.multi_values["flag"] == [""], "bare flag -> empty value")
    check(r8.multi_values["flag2"] == ["v"], "flag2")

    # 决策-80 (ADR-0055): path percent-decode — '+' 非空格 / %XX 单字节 / 畸形保留
    # / 非法 UTF-8 -> U+FFFD (对齐 uvicorn unquote(errors="replace")).
    check(url_decode_path("/items/a%20b") == "/items/a b", "path decode space")
    check(url_decode_path("/items/%7Bx%7D") == "/items/{x}", "path decode brace")
    check(url_decode_path("/items/a+b") == "/items/a+b", "path '+' not space")
    check(url_decode_path("/items/%E4%B8%AD") == "/items/中", "path decode utf8")
    check(url_decode_path("/items/%2F") == "/items//", "path decode slash")
    check(url_decode_path("/items/%252F") == "/items/%2F", "path single decode")
    check(url_decode_path("/items/%") == "/items/%", "path lone % literal")
    check(url_decode_path("/items/%zz") == "/items/%zz", "path malformed % kept")
    check(url_decode_path("/items/%FF") == "/items/" + chr(0xFFFD), "path invalid utf8 -> U+FFFD")

    print("Mojo params (query/path) test completed!")
