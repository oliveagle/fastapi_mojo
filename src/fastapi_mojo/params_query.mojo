# src/fastapi_mojo/params_query.mojo
#
# Mojo 原生 Path/Query 参数解析 (P4.4 拆分自 params.mojo).
#
#   - parse_query_params: URL-decode 到原始字节后 UTF-8 解码; 支持 ?flag
#     (无值)、值中含 '='、畸形 %XX (保留字面量)。
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

    def __init__(out self):
        self.has_error = False
        self.error_msg = ""
        self.param_count = 0
        self.values = Dict[String, String]()
        self.types = Dict[String, String]()

    def __init__(out self, param_count: Int, values: Dict[String, String]):
        self.has_error = False
        self.error_msg = ""
        self.param_count = param_count
        self.values = values.copy()
        self.types = Dict[String, String]()

    def __init__(out self, param_count: Int, values: Dict[String, String], types: Dict[String, String]):
        self.has_error = False
        self.error_msg = ""
        self.param_count = param_count
        self.values = values.copy()
        self.types = types.copy()

    def __init__(out self, error_msg: String):
        self.has_error = True
        self.error_msg = error_msg
        self.param_count = 0
        self.values = Dict[String, String]()
        self.types = Dict[String, String]()

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

    print("Mojo params (query/path) test completed!")
