# src/fastapi_mojo/numlit.mojo
#
# 决策-54 (ADR-0029, Goal-0003 P2 矩阵 #2): 参数类型字面量原语 — 叶子模块
# (零 import, 纯字符串/数值逻辑)。从 params_typed 抽出 (TypeSpec/parse_type_spec/
# ParsedBase/parse_base/parse_typed_value/int-float-bool 字面量判定) + body_schema
# 同款 f64 解析/数字格式化 (body_schema 保留私有副本, 面隔离)。
#
# 消费方: params_typed (类型化 path/query) / param_constraints (约束数值比较 +
# typed header) / openapi_schemas (header schema 类型化默认)。依赖方向:
# {params_typed, param_constraints, openapi_schemas} -> numlit (单向, 无环).

from scalar_types import is_scalar_type, scalar_canonical, parse_scalar


def is_int_literal(s: String) -> Bool:
    """True if s is a non-empty integer literal (optional leading '-')."""
    var n = s.byte_length()
    if n == 0:
        return False
    var i = 0
    if ord(s[byte=0]) == 45:  # '-'
        if n == 1:
            return False
        i = 1
    while i < n:
        var c = ord(s[byte=i])
        if c < 48 or c > 57:
            return False
        i += 1
    return True


def is_float_literal(s: String) -> Bool:
    """True if s is a float literal (sign? intpart '.' intpart (exp)?).
    Accepts 'inf' / '-inf' / 'nan'; 必须含小数点或指数 (区别于 int)."""
    var n = s.byte_length()
    if n == 0:
        return False
    if s == "inf" or s == "-inf" or s == "nan":
        return True
    var i = 0
    if ord(s[byte=0]) == 45:  # '-'
        if n == 1:
            return False
        i = 1
    var seen_digit = False
    var seen_dot = False
    var seen_exp = False
    while i < n:
        var c = ord(s[byte=i])
        if c == 46:  # '.'
            if seen_dot or seen_exp:
                return False
            seen_dot = True
        elif c == 101 or c == 69:  # 'e' 'E'
            if seen_exp:
                return False
            seen_exp = True
            var j = i + 1
            if j < n and (ord(s[byte=j]) == 43 or ord(s[byte=j]) == 45):  # '+' '-'
                j += 1
            if j >= n:
                return False  # 指数必须至少一位数字
            while j < n:
                var e2 = ord(s[byte=j])
                if e2 < 48 or e2 > 57:
                    return False
                j += 1
            break
        elif c < 48 or c > 57:
            return False
        else:
            seen_digit = True
        i += 1
    if not seen_digit:
        return False
    return seen_dot or seen_exp


def _lower_ascii(s: String) -> String:
    """ASCII lowercase (only A-Z folded; other bytes copied verbatim)."""
    var out = String("")
    for i in range(s.byte_length()):
        var c = ord(s[byte=i])
        if c >= 65 and c <= 90:
            out += chr(c + 32)
        else:
            out += chr(c)
    return out^


def parse_bool_literal(s: String) -> Tuple[Bool, Bool]:
    """Parse bool literal -> (ok, value). pydantic lax set (大小写不敏感):
    true/t/yes/y/on/1 -> True; false/f/no/n/off/0 -> False (决策-81)."""
    var l = _lower_ascii(s)
    if l == "true" or l == "t" or l == "yes" or l == "y" or l == "on" or l == "1":
        return (True, True)
    if l == "false" or l == "f" or l == "no" or l == "n" or l == "off" or l == "0":
        return (True, False)
    return (False, False)


def parse_int_lax(s: String) -> Tuple[Bool, String]:
    """pydantic 宽松 int 字符串解析 -> (ok, 规范化十进制) (决策-81).

    接受 [+-]? 数字 (允许 Python 式 '_' 数字分隔, 必须夹在数字之间);
    另接**整值小数** [+-]? 数字 '.' 0+ (上游 pydantic v2: "2.0"->2, "12.00"->12,
    但 "2."/"2.5"/"1e2" -> int_parsing; 见 ADR-0056 §4). 规范化: 去 '+'/前导零 /
    '-0'->'0' / 丢弃全零小数部分."""
    var n = s.byte_length()
    if n == 0:
        return (False, "")
    var i = 0
    var neg = False
    var c0 = ord(s[byte=0])
    if c0 == 43 or c0 == 45:  # '+' '-'
        neg = (c0 == 45)
        i = 1
    if i >= n:
        return (False, "")
    var digits = List[Int]()
    var prev_digit = False
    var seen_dot = False
    var frac_any = False
    var frac_all_zero = True
    while i < n:
        var c = ord(s[byte=i])
        if c == 95:  # '_'
            if not prev_digit or seen_dot:
                return (False, "")
            prev_digit = False
        elif c >= 48 and c <= 57:
            if seen_dot:
                frac_any = True
                if c != 48:
                    frac_all_zero = False
            else:
                digits.append(c - 48)
            prev_digit = True
        elif c == 46 and not seen_dot and prev_digit:  # '.'
            seen_dot = True
            prev_digit = False
        else:
            return (False, "")
        i += 1
    if not prev_digit or len(digits) == 0:
        return (False, "")
    if seen_dot and (not frac_any or not frac_all_zero):
        return (False, "")
    var k = 0
    while k < len(digits) - 1 and digits[k] == 0:
        k += 1
    var body = String("")
    for j in range(k, len(digits)):
        body += chr(48 + digits[j])
    if neg and body != "0":
        return (True, "-" + body)
    return (True, body)


def parse_float_lax(s: String) -> Tuple[Bool, String]:
    """pydantic 宽松 float 字符串解析 -> (ok, Python repr 等价规范化) (决策-81).

    接受 [+-]? (数字[_]* ['.' 数字[_]*]? | '.' 数字[_]+) [eE[+-]?数字[_]+]?;
    另接 inf/infinity/nan (大小写不敏感, 带符号); 也接纯 int 字面量 (上游
    float("42") -> 42.0). 规范化 = Float64 -> String (与 CPython repr 一致:
    1.0->"1.0", 1.50->"1.5", 1e3->"1000.0", -0.0->"-0.0")."""
    var n = s.byte_length()
    if n == 0:
        return (False, "")
    var i = 0
    var sign = ""
    var c0 = ord(s[byte=0])
    if c0 == 43 or c0 == 45:
        if c0 == 45:
            sign = "-"
        i = 1
    # inf / infinity / nan 家族
    var rest = _lower_ascii(String(s[byte=i:n]))
    if rest == "inf" or rest == "infinity":
        return (True, sign + "inf")
    if rest == "nan":
        return (True, "nan")
    # 数值文法校验 (记录是否为合法十进制)
    var seen_digit = False
    var seen_dot = False
    var seen_exp = False
    var last_us = False
    var j = i
    while j < n:
        var c = ord(s[byte=j])
        if c == 95:  # '_'
            if not seen_digit or last_us:
                return (False, "")
            last_us = True
        elif c >= 48 and c <= 57:
            seen_digit = True
            last_us = False
        elif c == 46:  # '.'
            if seen_dot or seen_exp:
                return (False, "")
            seen_dot = True
            last_us = False
        elif c == 101 or c == 69:  # 'e' 'E'
            if seen_exp or not seen_digit or last_us:
                return (False, "")
            var k = j + 1
            if k < n and (ord(s[byte=k]) == 43 or ord(s[byte=k]) == 45):
                k += 1
            if k >= n:
                return (False, "")
            var eprev = False
            var eus = False
            while k < n:
                var e2 = ord(s[byte=k])
                if e2 == 95:
                    if not eprev or eus:
                        return (False, "")
                    eus = True
                elif e2 >= 48 and e2 <= 57:
                    eprev = True
                    eus = False
                else:
                    return (False, "")
                k += 1
            if not eprev:
                return (False, "")
            break
        else:
            return (False, "")
        j += 1
    if not seen_digit or last_us:
        return (False, "")
    # 去掉 '_' 后交给 Float64 (Mojo 不认 '_')
    var cleaned = String("")
    for t in range(i, n):
        if ord(s[byte=t]) != 95:
            cleaned += chr(ord(s[byte=t]))
    try:
        var v = Float64(cleaned)
        return (True, String(v))
    except:
        return (False, "")


def parse_f64(s: String) raises -> Tuple[Bool, Float64]:
    """解析 float 字面量; 失败 -> (False, 0.0) (body_schema._parse_f64 同款)."""
    try:
        return (True, Float64(s))
    except:
        return (False, 0.0)


def fmt_num(v: Float64) -> String:
    """约束消息数字格式: 0.0 -> "0", 9.99 -> "9.99" (对齐 FastAPI 消息)."""
    var i = Int(v)
    if Float64(i) == v:
        return String(i)
    return String(v)


# ---------- 类型元数据解析 (parse "int=10" -> (base_type, default)) ----------

struct TypeSpec:
    """单个参数的类型规格. base_type 必填; default_value 空 = 无默认值."""
    var base_type: String     # "int" | "float" | "bool" | "string"
    var default_value: String  # "" = 无默认; 其它 = 默认值字符串 (字面量/list CSV)
    var is_list: Bool
    var default_present: Bool  # spec 是否显式带 '=' (list 的有默认判据)

    def __init__(out self, base_type: String, default_value: String, is_list: Bool, default_present: Bool):
        self.base_type = base_type
        self.default_value = default_value
        self.is_list = is_list
        self.default_present = default_present

    def has_default(self) -> Bool:
        if self.is_list:
            # list: 仅显式 '=' 算有默认 ("int[]=" = 空 list 默认, FastAPI Query([]))
            return self.default_present
        return self.default_value != ""


def parse_type_spec(raw: String) -> TypeSpec:
    """解析 "int" / "int=10" / "int[]" -> TypeSpec.
    - base_type 必须已知, 否则返回 base_type=raw (由校验层判错).
    - 有 '=' 但 default 空 -> list = 空默认; 标量 = 由校验层判错.
    不 raise (hot path 友好): 错误留给校验层报告."""
    var n = raw.byte_length()
    var eq = -1
    for i in range(n):
        if ord(raw[byte=i]) == 61:  # '='
            eq = i
            break
    if eq < 0:
        return TypeSpec(raw, "", parse_base(raw).is_list, False)
    var base = String(raw[byte=0:eq])
    var default = String(raw[byte=eq + 1:n])
    return TypeSpec(base, default, parse_base(base).is_list, True)


# ---------- 基础类型解析 (决策-38 enum + 决策-43 list) ----------

struct ParsedBase:
    """基础类型解析结果. ok=False = 畸形/未知类型."""
    var ok: Bool
    var type_name: String
    var is_enum: Bool
    var is_list: Bool  # 决策-43: 空括号 "int[]"
    var values_csv: String

    def __init__(out self):
        self.ok = False
        self.type_name = ""
        self.is_enum = False
        self.is_list = False
        self.values_csv = ""

    def __init__(out self, type_name: String, is_enum: Bool, values_csv: String):
        self.ok = True
        self.type_name = type_name
        self.is_enum = is_enum
        self.is_list = False
        self.values_csv = values_csv

    def __init__(out self, type_name: String, is_enum: Bool, values_csv: String, is_list: Bool):
        self.ok = True
        self.type_name = type_name
        self.is_enum = is_enum
        self.is_list = is_list
        self.values_csv = values_csv


def parse_base(raw: String) -> ParsedBase:
    """解析基础类型: "int" / "str[low,high]" (enum) / "int[]" (list). 畸形 -> ok=False."""
    var n = raw.byte_length()
    var i = 0
    while i < n:
        if ord(raw[byte=i]) == 91:  # '['
            var j = i + 1
            var found = -1
            while j < n:
                if ord(raw[byte=j]) == 93:
                    found = j
                    break
                j += 1
            if found < 0:
                return ParsedBase()
            var base = String(raw[byte=0:i])
            var vals = String(raw[byte=i + 1:found])
            if base == "str" or base == "string":
                if vals == "":
                    return ParsedBase("str", False, "", True)
                return ParsedBase("str", True, vals)
            # 决策-79: 标量类型 (uuid/date/.../decimal) 的 list = 空括号;
            # 非空括号 (enum) 对标量不可表达 -> 拒绝
            if is_scalar_type(base):
                if vals == "":
                    return ParsedBase(scalar_canonical(base), False, "", True)
                return ParsedBase()
            if base == "int" or base == "float" or base == "bool":
                if vals == "":
                    return ParsedBase(base, False, "", True)
                return ParsedBase(base, True, vals)
            return ParsedBase()
        i += 1
    if raw == "str" or raw == "string":
        return ParsedBase("str", False, "")
    if raw == "int" or raw == "float" or raw == "bool":
        return ParsedBase(raw, False, "")
    if is_scalar_type(raw):
        return ParsedBase(scalar_canonical(raw), False, "")
    return ParsedBase()


def _csv_parts(s: String) raises -> List[String]:
    """CSV 切 ',' (trim 空白, 丢弃空段) — 叶子模块本地实现 (不 import
    params_query_extra, 保 numlit 零依赖)."""
    var out = List[String]()
    var n = s.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(s[byte=i]) == 44)  # ','
        if is_sep:
            if i > start:
                var piece = String(s[byte=start:i])
                var b = 0
                var e = piece.byte_length()
                while b < e and (ord(piece[byte=b]) == 32 or ord(piece[byte=b]) == 9):
                    b += 1
                while e > b and (ord(piece[byte=e - 1]) == 32 or ord(piece[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    out.append(String(piece[byte=b:e]))
            start = i + 1
        i += 1
    return out^


def enum_in(v: String, csv: String) raises -> Bool:
    """是否 v 在 enum 值表 (CSV) 中 (trim 后精确匹配)."""
    var pieces = _csv_parts(csv)
    for piece in pieces:
        if piece == v:
            return True
    return False


def enum_msg(csv: String) raises -> String:
    """FastAPI enum 消息: "Input should be 'a' or 'b'" (逗号 + or 连接)."""
    var pieces = _csv_parts(csv)
    var parts = List[String]()
    for piece in pieces:
        parts.append("'" + piece + "'")
    var sb = ""
    var n = len(parts)
    for i in range(n):
        if i > 0:
            sb = sb + (" or " if i == n - 1 else ", ")
        sb = sb + parts[i]
    return "Input should be " + sb


def parse_typed_value(type_name: String, raw: String) -> Tuple[Bool, String]:
    """把字符串 raw 按 type_name 解析; 成功 -> (True, 类型化字面量字符串).
    类型化字面量 (与 json_serialize 一致): int/float -> 数字串; bool ->
    "true"/"false"; string -> 原样. 失败 -> (False, "")."""
    if type_name == "string" or type_name == "str":
        return (True, raw)
    if type_name == "int":
        # 决策-81 (ADR-0056): 宽松解析 + 规范化 (007 -> 7, +5 -> 5, 1_0 -> 10)
        return parse_int_lax(raw)
    if type_name == "float":
        # 决策-45/81: float 接受 int 字面量 ("1" -> "1.0"); 规范化 = repr 等价
        return parse_float_lax(raw)
    if type_name == "bool":
        var pr = parse_bool_literal(raw)
        if not pr[0]:
            return (False, "")
        if pr[1]:
            return (True, "true")
        return (True, "false")
    if is_scalar_type(type_name):
        var sp = parse_scalar(type_name, raw)
        if sp.ok:
            return (True, sp.value)
        return (False, "")
    return (False, "")
