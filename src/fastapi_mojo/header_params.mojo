# src/fastapi_mojo/header_params.mojo
#
# 决策-53 (ADR-0028, Goal-0003 P2 矩阵 #7): Header 参数精化 — alias +
# 下划线→连字符转换 纯函数模块 (无 FFI, 无全局状态, ADR-0004 声明式
# 范式, FFI diff = 0)。
#
# 内容:
#   - header_wire_name — `_` 逐字符 → `-` (上游 convert_underscores=True
#     默认; x_token → x-token, x__token → x--token; P25-1/4)
#   - parse_header_entry — _reads_headers 条目: "name" (wire = 转换) /
#     "name=alias" (wire = alias 原样, P25-3; "name=name" = 字面 =
#     convert_underscores=False 逃生门)
#   - check_header_specs — 注册期校验 (畸形条目启动即 fail,
#     check_ws_specs/check_state_specs/check_openapi_specs 同策略)
#
# 上游探测: /tmp/exch_probe/p25*.py (fastapi 0.141.1 / uvicorn 0.52.4,
# 细节与偏差见 ADR-0028 §1/§3.5)。大小写不敏感匹配 + 多值取首 = bridge
# get_header_value_ci 既有 (FFI diff = 0)。

from router import Router
from handler import Handler


def header_wire_name(name: String) -> String:
    """`convert_underscores=True` 默认 (P25-1/4): 参数名逐 `_` → `-`
    (x_token → x-token; x__token → x--token; a_b_c → a-b-c; 其余字符
    原样). 无 `_` 的名字 (X-Custom / User-Agent) 不变."""
    var out = String("")
    var n = name.byte_length()
    var i = 0
    while i < n:
        var c = ord(name[byte=i])
        if c == 95:  # '_'
            out += "-"
        else:
            out += chr(c)
        i += 1
    return out


def parse_header_entry(entry: String) -> Tuple[String, String]:
    """_reads_headers 条目 → (参数名, wire 名). "name" → (name,
    header_wire_name(name)); "name=alias" → (name, alias 原样)
    (P25-3: alias 不做下划线转换; "name=name" = 字面 = 上游
    convert_underscores=False). 调用前条目已 trim + 非空."""
    var n = entry.byte_length()
    var eq = -1
    var i = 0
    while i < n:
        if ord(entry[byte=i]) == 61:  # '='
            eq = i
            break
        i += 1
    if eq < 0:
        return (entry, header_wire_name(entry))
    var nm = String(entry[byte=0:eq])
    var al = String(entry[byte=eq + 1:n])
    return (nm, al)


def _valid_header_token(s: String) -> Bool:
    """header 名最小合法性: 非空, 仅可打印非空白 ASCII (0x21-0x7E).
    (RFC 7230 token 粗检 — 拒绝空白/控制字符, 不放行 '=' 由条目
    切分先行保证)."""
    var n = s.byte_length()
    if n == 0:
        return False
    var i = 0
    while i < n:
        var c = ord(s[byte=i])
        if c < 33 or c > 126:
            return False
        i += 1
    return True


def check_header_specs(router: Router) raises:
    """决策-53 Header 声明注册期校验 (畸形 spec 启动即 fail,
    check_ws_specs/check_state_specs/check_openapi_specs 同策略):
    _reads_headers 条目 = "name" 或 "name=alias" (至多一个 '='; 两侧
    均非空; 可打印非空白 ASCII). 空条目跳过 (既有行为)."""
    for i in range(router.route_count()):
        var h = router.routes[i].handler.copy()
        if "_reads_headers" not in h.data:
            continue
        var entries = h.data["_reads_headers"].split(",")
        for j in range(len(entries)):
            var e = String(entries[j])
            var b = 0
            var en = e.byte_length()
            while b < en and (ord(e[byte=b]) == 32 or ord(e[byte=b]) == 9):
                b += 1
            while en > b and (ord(e[byte=en - 1]) == 32 or ord(e[byte=en - 1]) == 9):
                en -= 1
            var piece = String(e[byte=b:en])
            if piece == "":
                continue
            var pc = piece.byte_length()
            var eq_count = 0
            var k = 0
            while k < pc:
                if ord(piece[byte=k]) == 61:
                    eq_count += 1
                    if eq_count > 1:
                        raise Error("header: bad _reads_headers entry (need "
                                    "\"name\" or \"name=alias\") in " + h.name
                                    + ": " + piece)
                k += 1
            if eq_count == 0:
                if not _valid_header_token(piece):
                    raise Error("header: bad _reads_headers name (printable "
                                "non-blank ASCII required) in " + h.name
                                + ": " + piece)
            else:
                var eqp = -1
                var k2 = 0
                while k2 < pc:
                    if ord(piece[byte=k2]) == 61:
                        eqp = k2
                        break
                    k2 += 1
                var nm = String(piece[byte=0:eqp])
                var al = String(piece[byte=eqp + 1:pc])
                if not _valid_header_token(nm) or not _valid_header_token(al):
                    raise Error("header: bad _reads_headers entry (empty or "
                                "invalid name/alias) in " + h.name + ": " + piece)
