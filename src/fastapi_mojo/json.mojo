# src/fastapi_mojo/json.mojo
#
# Mojo native JSON serialization implementation (linear time).

from string_builder import StringBuilder



def _has_nested_prefix(v: String) -> Bool:
    """True if v starts with "__nested__:" (11 bytes, raw JSON 透传标记, F3c).
    逐字节比较避免 String slice 类型开销."""
    if v.byte_length() <= 10:
        return False
    # "__nested__:" = _ _ n e s t e d _ _ :
    return ord(v[byte=0]) == 95 and ord(v[byte=1]) == 95 and \
           ord(v[byte=2]) == 110 and ord(v[byte=3]) == 101 and \
           ord(v[byte=4]) == 115 and ord(v[byte=5]) == 116 and \
           ord(v[byte=6]) == 101 and ord(v[byte=7]) == 100 and \
           ord(v[byte=8]) == 95 and ord(v[byte=9]) == 95 and \
           ord(v[byte=10]) == 58


def _hex2(v: Int) -> String:
    """Two lowercase hex digits of v (0-255)."""
    var h = "0123456789abcdef"
    var hi = v >> 4
    var lo = v & 0xF
    return String(h[byte=hi]) + String(h[byte=lo])


def json_escape(value: String) -> String:
    """Escape special characters in a string (linear time).

    Handles ", \\, \\n, \\r, \\t and all control chars < 0x20 as \\u00XX.
    NOTE: ord() on a 1-byte span at a codepoint boundary returns the codepoint
    of the character (not the raw byte), so UTF-8 byte length is derived from
    the codepoint value. Multi-byte codepoints are copied as whole byte runs
    and need no JSON escaping."""
    var sb = StringBuilder()
    var i = 0
    var n = value.byte_length()
    while i < n:
        var b = value[byte=i]
        var cp = ord(b)
        if cp < 0x80:
            if b == '"':
                sb.append("\\\"")
            elif b == '\\':
                sb.append("\\\\")
            elif b == '\n':
                sb.append("\\n")
            elif b == '\r':
                sb.append("\\r")
            elif b == '\t':
                sb.append("\\t")
            elif cp < 0x20:
                sb.append("\\u00" + _hex2(cp))
            else:
                sb.append(String(b))
            i += 1
        else:
            var blen = 2
            if cp >= 0x800:
                blen = 3
            if cp >= 0x10000:
                blen = 4
            sb.append(String(value[byte=i:i+blen]))
            i += blen
    return sb.take()


def json_serialize(value: String) -> String:
    """Serialize string to JSON."""
    return '"' + json_escape(value) + '"'


def json_serialize(value: Int) -> String:
    """Serialize integer to JSON."""
    return String(value)


def json_serialize(value: Float64) -> String:
    """Serialize float to JSON."""
    return String(value)


def json_serialize(value: Bool) -> String:
    """Serialize bool to JSON."""
    if value:
        return "true"
    else:
        return "false"


def json_serialize(value: None) -> String:
    """Serialize null to JSON."""
    return "null"


def json_serialize_key_value(key: String, value: String) -> String:
    """Serialize key-value pair to JSON."""
    return json_serialize(key) + ": " + value


def json_serialize_dict(data: Dict[String, String]) raises -> String:
    """Serialize dict to JSON (linear time).

    Nested marker (F3c, Goal-0002): if value starts with "__nested__:",
    append the rest raw (already-formatted JSON object/array), skipping
    json_serialize wrap. This lets handler nest Dict/List under a key.
    """
    var items = StringBuilder()
    var first = True
    for key in data:
        if not first:
            items.append(", ")
        first = False
        var v = data[key]
        # "__nested__:" prefix detection (F3c)
        if _has_nested_prefix(v):
            items.append(json_serialize(key) + ": " + String(v[byte=11:v.byte_length()]))
        else:
            items.append(json_serialize_key_value(key, json_serialize(v)))
    return "{" + items.take() + "}"


def json_serialize_list(data: List[String]) -> String:
    """Serialize list to JSON (linear time)."""
    var items = StringBuilder()
    var first = True
    for item in data:
        if not first:
            items.append(", ")
        first = False
        items.append(json_serialize(item))
    return "[" + items.take() + "]"


def json_serialize_nested_dict(key: String, data: Dict[String, String]) raises -> String:
    """Serialize nested dict to JSON."""
    return json_serialize(key) + ": " + json_serialize_dict(data)


def json_serialize_nested_list(key: String, data: List[String]) raises -> String:
    """Serialize nested list to JSON."""
    return json_serialize(key) + ": " + json_serialize_list(data)


def main() raises:
    print("Testing Mojo JSON serialization...")

    # String escaping
    var str_json = json_serialize("Hello, World!")
    if str_json == '"Hello, World!"':
        print("OK: string")

    var escape_json = json_serialize('He said "hi" and left\nNew line')
    if escape_json == '"He said \\"hi\\" and left\\nNew line"':
        print("OK: escapes")

    var ctrl_json = json_serialize("a\x01b")
    if ctrl_json == '"a\\u0001b"':
        print("OK: control char -> \\u0001")

    var emoji_json = json_serialize("é😀")
    if emoji_json == '"é😀"':
        print("OK: multibyte passthrough")

    # Int / Float / Bool / null
    if json_serialize(42) == "42":
        print("OK: int")
    if json_serialize(3.14) == "3.14":
        print("OK: float")
    if json_serialize(True) == "true" and json_serialize(False) == "false":
        print("OK: bool")
    if json_serialize(None) == "null":
        print("OK: null")

    # Dict
    var dict_data = Dict[String, String]()
    dict_data["name"] = "John"
    dict_data["age"] = "30"
    var dict_json = json_serialize_dict(dict_data)
    if dict_json == '{"name": "John", "age": "30"}':
        print("OK: dict")

    # List
    var list_data = List[String]()
    list_data.append("apple")
    list_data.append("banana")
    list_data.append("cherry")
    var list_json = json_serialize_list(list_data)
    if list_json == '["apple", "banana", "cherry"]':
        print("OK: list")

    # Nested
    var nested_json = "{" + json_serialize_nested_dict("user", dict_data) + ", " + json_serialize_nested_list("fruits", list_data) + "}"
    if nested_json == '{"user": {"name": "John", "age": "30"}, "fruits": ["apple", "banana", "cherry"]}':
        print("OK: nested")

    # Performance: 256KB string must escape fast (was O(n^2) minutes)
    var big = StringBuilder()
    for _ in range(256 * 1024):
        big.append_byte(0x61)
    var big_json = json_escape(big.take())
    if big_json.byte_length() == 262144:
        print("OK: 256KB escaped linearly")

    print("JSON serialization test completed!")
