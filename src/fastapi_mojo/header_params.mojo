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
#   - header_loc_name — header 422 loc 用的 **HTTP header 名** (决策-103,
#     上游 0.152.0 / PR #16538: loc 报 HTTP header 名而非 Python 字段名;
#     显式别名原样保留, 默认 `_`→`-`)
#
# 决策-103 (上游 0.152.0): 上游把 header 参数的校验错误 loc 从 Python
# 字段名 (int_val) 改为 HTTP header 名 (int-val); 显式别名、
# convert_underscores=False、loc_by_alias=False 保持原行为。fastapi_mojo
# 的 header 参数是扁平声明 (_reads_headers + _header_types), loc 早已用
# wire 名; 本次补齐两处缺口: ① 退化态 (只声明 _header_types 而未在
# _reads_headers 出现) 的 loc 也用 HTTP header 名; ② 该退化态改为
# 注册期 fail fast (声明了类型却从不读该 header -> 永远 missing 422).
#
# 上游探测: /tmp/exch_probe/p25*.py (fastapi 0.141.1 / uvicorn 0.52.4,
# 细节与偏差见 ADR-0028 §1/§3.5)。大小写不敏感匹配 + 多值取首 = bridge
# get_header_value_ci 既有 (FFI diff = 0)。

from router import Router
from handler import Handler
from alias_choices import alias_candidates


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


def header_entry_parts(entry: String) -> Tuple[String, List[String]]:
    """_reads_headers 条目 -> (声明名, wire 候选列表) (决策-104 AliasChoices).

    "name"       -> (name, [header_wire_name(name)])  (convert_underscores=True)
    "name=alias" -> (name, ["alias"])                 (显式别名原样, P25-3)
    "name=a|b"   -> (name, ["a", "b"])                (多候选: **字面名**,
                    上游 "Explicit choices are literal names, including
                    underscores in headers" — 候选不做下划线转换)."""
    var n = entry.byte_length()
    var eq = -1
    var i = 0
    while i < n:
        if ord(entry[byte=i]) == 61:  # '='
            eq = i
            break
        i += 1
    if eq < 0:
        var out0 = List[String]()
        out0.append(header_wire_name(entry))
        return (entry, out0^)
    var nm = String(entry[byte=0:eq])
    var al = String(entry[byte=eq + 1:n])
    if al == "":
        var out1 = List[String]()
        out1.append(header_wire_name(nm))
        return (nm, out1^)
    var cands = alias_candidates(al)
    if len(cands) == 0:
        cands.append(al)
    return (nm, cands^)


def header_candidates(entry: String) -> List[String]:
    """_reads_headers 条目 -> wire 候选列表 (决策-104; 便捷入口)."""
    var parts = header_entry_parts(entry)
    var cands = parts[1].copy()
    return cands^


def header_loc_name(name: String, reads: Dict[String, String]) raises -> String:
    """Header 422 loc 用的 **HTTP header 名** (上游 0.152.0 / PR #16538:
    "Validation errors for header parameter models now report the HTTP
    header name, such as `int-val`, instead of the Python field name,
    `int_val`"). 规则:
      - 显式别名 (_reads_headers 的 "name=alias") -> alias 原样
        (上游 "Explicit aliases ... keep their existing behavior");
      - 否则 -> 参数名 `_` -> `-` (上游 convert_underscores=True 默认;
        convert_underscores=False 的逃生门 = "name=name" 显式字面).
    reads = _reads_headers 解析结果 (参数名 -> wire 名)."""
    if name in reads:
        return reads[name]
    return header_wire_name(name)


def _header_type_names(spec: String) -> List[String]:
    """_header_types 声明的**参数名**列表 ("a:int;b:str=ab" -> ["a","b"]).
    分隔 ';' (59), 键值分隔 '=' (58); 与 get_header_types 的
    parse_table(spec, 59, 58, True) 同规则 (无 '=' / 空键跳过; 不 trim).
    本地实现 (保持本模块纯函数依赖面 — 不引 params_query_extra)."""
    var out = List[String]()
    var n = spec.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(spec[byte=i]) == 59)
        if is_sep:
            if i > start:
                var piece = String(spec[byte=start:i])
                var pn = piece.byte_length()
                var eq = -1
                var j = 0
                while j < pn:
                    if ord(piece[byte=j]) == 58:
                        eq = j
                        break
                    j += 1
                if eq > 0:
                    out.append(String(piece[byte=0:eq]))
        start = i + 1
        i += 1
    return out^


def _reads_param_names(csv: String) -> List[String]:
    """_reads_headers CSV -> 参数名列表 (条目 "name" / "name=alias" 的 name
    部分; 空条目跳过). 与 parse_reads_headers (param_constraints) 同规则;
    本地实现避免反向依赖 (param_constraints 已 import 本模块)."""
    var out = List[String]()
    var n = csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(csv[byte=i]) == 44)
        if is_sep:
            if i > start:
                var t = String(csv[byte=start:i])
                var b = 0
                var e = t.byte_length()
                while b < e and (ord(t[byte=b]) == 32 or ord(t[byte=b]) == 9):
                    b += 1
                while e > b and (ord(t[byte=e - 1]) == 32 or ord(t[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    var pe = parse_header_entry(String(t[byte=b:e]))
                    out.append(pe[0])
        start = i + 1
        i += 1
    return out^


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
        # 决策-103 (上游 0.152.0): _header_types 的每个名字必须在
        # _reads_headers 的参数名集合内 — 否则该 header 永不读取 (永远
        # missing 422), 且 422 loc 的 HTTP header 名无从确定 -> 启动即
        # fail (与畸形 _reads_headers 同策略).
        if "_header_types" in h.data and h.data["_header_types"] != "":
            var reads_csv = ""
            if "_reads_headers" in h.data:
                reads_csv = h.data["_reads_headers"]
            var read_names = _reads_param_names(reads_csv)
            for tn in _header_type_names(h.data["_header_types"]):
                var found = False
                for rn in read_names:
                    if rn == tn:
                        found = True
                if not found:
                    raise Error("header: _header_types name not in _reads_headers: "
                                + tn + " in " + h.name)
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
