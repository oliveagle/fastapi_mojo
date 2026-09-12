# src/fastapi_mojo/body_schema.mojo
#
# 决策-38: Pydantic 式 body 校验 + Field 约束 + Enum (Goal-0003 P1, T-P1d+T-P1e).
#
#   - 声明式: Handler.data["_body_schema"] = "name:str;price:float|gt=0;quantity:int=10;..."
#   - 字段 spec: name:<BASE>[=default][|c1,c2,...]
#       BASE: str/int/float/bool/obj/arr | T[](数组) | T[v1,v2](enum) | obj{subspec}(嵌套)
#       约束: gt/ge/lt/le=N (数值) / len=N(-M) (字符串) / items=N(-M) (数组) / pat=REGEX (字符串, 决策-57)
#   - 校验失败 -> FastAPI 422 detail 数组 (loc/msg/type, Pydantic v2 风格, 全错误收集)
#   - 校验成功 -> 校验值表 (含默认值), dispatch 注入 body_<name> / <父>_<子>
#
# Mojo 1.0.0: struct 无隐式拷贝 -> List 存字段 spec 字符串, get_field() 返回新值 (move).

from json import json_escape
from scalar_types import is_scalar_type, scalar_canonical


# ---------- 字段 spec ----------
# 拆分边界: spec 解析在本文件; 运行期校验/错误构造在 body_validate.mojo (P4.4 params_* 同模式).


struct FieldSpec:
    """单个 body 字段规格 (决策-38). constraints = '|' 后的原始约束串 (CSV)."""
    var name: String
    var type_name: String    # str/int/float/bool/obj/arr
    var is_array: Bool
    var elem: String
    var is_enum: Bool
    var enum_values: String
    var default_value: String
    var nested_spec: String
    var constraints: String

    def __init__(out self):
        self.name = ""
        self.type_name = "str"
        self.is_array = False
        self.elem = ""
        self.is_enum = False
        self.enum_values = ""
        self.default_value = ""
        self.nested_spec = ""
        self.constraints = ""

    def has_default(self) -> Bool:
        return self.default_value != ""


# ---------- helpers ----------

def _split_top(s: String, sep: Int) -> List[String]:
    """按 sep 字节在括号深度 0 处切分 ({}/[] 嵌套内不切)."""
    var out = List[String]()
    var n = s.byte_length()
    var depth = 0
    var start = 0
    var i = 0
    while i < n:
        var o = ord(s[byte=i])
        if o == 123 or o == 91:
            depth += 1
        elif o == 125 or o == 93:
            depth -= 1
        elif o == sep and depth == 0:
            out.append(String(s[byte=start:i]))
            start = i + 1
        i += 1
    out.append(String(s[byte=start:n]))
    return out^


def _trim(s: String) -> String:
    var b = 0
    var e = s.byte_length()
    while b < e and (ord(s[byte=b]) == 32 or ord(s[byte=b]) == 9):
        b += 1
    while e > b and (ord(s[byte=e - 1]) == 32 or ord(s[byte=e - 1]) == 9):
        e -= 1
    return String(s[byte=b:e])


def _parse_f64(s: String) raises -> Tuple[Bool, Float64]:
    """解析 float 字面量; 失败 -> (False, 0.0)."""
    try:
        return (True, Float64(s))
    except:
        return (False, 0.0)


def _parse_int(s: String) raises -> Tuple[Bool, Int]:
    """解析 int 字面量; 失败 -> (False, 0)."""
    try:
        return (True, Int(s))
    except:
        return (False, 0)


def _find_eq(s: String) -> Int:
    for i in range(s.byte_length()):
        if ord(s[byte=i]) == 61:
            return i
    return -1


def _parse_range(val: String) raises -> Tuple[Bool, Int, Int]:
    """'N' 或 'N-M' -> (ok, min, max)."""
    var dash = _find_eq(val)
    # '-' 分隔: 找 '-' 字节
    var d = -1
    for li in range(val.byte_length()):
        if ord(val[byte=li]) == 45:
            d = li
            break
    _ = dash
    if d < 0:
        var p = _parse_int(val)
        if not p[0]:
            return (False, 0, 0)
        return (True, p[1], p[1])
    var p2 = _parse_int(String(val[byte=0:d]))
    var p3 = _parse_int(String(val[byte=d + 1:val.byte_length()]))
    if not p2[0] or not p3[0]:
        return (False, 0, 0)
    return (True, p2[1], p3[1])


def _is_int_lit(s: String) -> Bool:
    var n = s.byte_length()
    if n == 0:
        return False
    var i = 0
    if ord(s[byte=0]) == 45:
        if n == 1:
            return False
        i = 1
    while i < n:
        var c = ord(s[byte=i])
        if c < 48 or c > 57:
            return False
        i += 1
    return True


def _is_num_lit(s: String) raises -> Bool:
    """int 或 float 字面量 (数组元素类型检查)."""
    if _is_int_lit(s):
        return True
    return _parse_f64(s)[0]


def fmt_num(v: Float64) -> String:
    """约束消息数字格式: 0.0 -> "0", 9.99 -> "9.99" (对齐 FastAPI 消息)."""
    var i = Int(v)
    if Float64(i) == v:
        return String(i)
    return String(v)


def err_obj(loc_json: String, msg: String, type_name: String, input_json: String) -> String:
    """构造单个 FastAPI 422 detail 对象 (决策-45: loc/msg/type/input, 上游 0.141.1)."""
    return "{\"loc\":" + loc_json + ",\"msg\":\"" + json_escape(msg) + \
           "\",\"type\":\"" + json_escape(type_name) + "\",\"input\":" + input_json + "}"


def err_obj_ctx(loc_json: String, msg: String, type_name: String, input_json: String,
                ctx_json: String) -> String:
    """带 ctx 的 FastAPI 422 detail 对象 (决策-83: loc,msg,type,input,ctx 键序, 上游 0.141.1).

    ctx 仅约束类错误携带 (gt/ge/lt/le/multiple_of/min_length/max_length/pattern/
    List items/expected); 类型错/missing/json_invalid 用无 ctx 的 err_obj."""
    return "{\"loc\":" + loc_json + ",\"msg\":\"" + json_escape(msg) + \
           "\",\"type\":\"" + json_escape(type_name) + "\",\"input\":" + input_json + \
           ",\"ctx\":" + ctx_json + "}"


def _in_enum_csv(v: String, csv: String) -> Bool:
    var items = _split_top(csv, 44)
    for it in items:
        if _trim(it) == v:
            return True
    return False


def _enum_or_msg(csv: String) raises -> String:
    """FastAPI enum 消息: "Input should be 'fast' or 'slow'". """
    var items = _split_top(csv, 44)
    var sb = ""
    for i in range(len(items)):
        if i > 0:
            sb = sb + (" or " if i == len(items) - 1 else ", ")
        sb = sb + "'" + _trim(items[i]) + "'"
    return "Input should be " + sb



# ---------- spec 解析 ----------

struct ParsedSchema:
    """_body_schema 解析结果 (字段 spec 原始串列表; String 可拷贝, 可迭代)."""
    var fields: List[String]

    def __init__(out self):
        self.fields = List[String]()


def _parse_field(raw: String) raises -> FieldSpec:
    """解析单个字段 spec: name:BASE[=default][|c1,c2,...] (畸形 raise)."""
    var fs = FieldSpec()
    var n = raw.byte_length()
    var colon = -1
    var i = 0
    while i < n:
        if ord(raw[byte=i]) == 58:
            colon = i
            break
        i += 1
    if colon <= 0:
        raise Error("body_schema: bad field spec (missing ':'): " + raw)
    fs.name = String(raw[byte=0:colon])
    var rest = String(raw[byte=colon + 1:n])
    var j = 0
    var rn = rest.byte_length()
    while j < rn:
        var o = ord(rest[byte=j])
        if o == 91 or o == 61 or o == 124 or o == 123:
            break
        j += 1
    var base = String(rest[byte=0:j])
    if base == "str" or base == "string":
        fs.type_name = "str"
    elif base == "int" or base == "float" or base == "bool" or base == "obj" or base == "arr":
        fs.type_name = base
    elif is_scalar_type(base):
        # 决策-79: pydantic 标量类型 (uuid/date/datetime/time/timedelta/decimal)
        fs.type_name = scalar_canonical(base)
    else:
        raise Error("body_schema: unknown type '" + base + "' in field '" + fs.name + "'")
    if j < rn and ord(rest[byte=j]) == 91:  # [..] 数组 (空) / enum (值列表)
        var k = j + 1
        var found = -1
        while k < rn:
            if ord(rest[byte=k]) == 93:
                found = k
                break
            k += 1
        if found < 0:
            raise Error("body_schema: unbalanced '[' in field '" + fs.name + "'")
        var inner = String(rest[byte=j + 1:found])
        if inner == "":
            fs.is_array = True
            fs.elem = fs.type_name
        else:
            fs.is_enum = True
            fs.enum_values = inner
        j = found + 1
    if j < rn and ord(rest[byte=j]) == 123:  # obj{...} 嵌套 (仅 obj)
        if fs.type_name != "obj":
            raise Error("body_schema: nested obj{...} only for obj type (field '" + fs.name + "')")
        var k2 = j + 1
        var d = 1
        var found2 = -1
        while k2 < rn:
            var oc = ord(rest[byte=k2])
            if oc == 123:
                d += 1
            elif oc == 125:
                d -= 1
                if d == 0:
                    found2 = k2
                    break
            k2 += 1
        if found2 < 0:
            raise Error("body_schema: unbalanced '{' in field '" + fs.name + "'")
        fs.nested_spec = String(rest[byte=j + 1:found2])
        j = found2 + 1
    if j < rn and ord(rest[byte=j]) == 61:  # =default (到 '|' 或结尾)
        var eq_end = j + 1
        while eq_end < rn:
            if ord(rest[byte=eq_end]) == 124:
                break
            eq_end += 1
        fs.default_value = String(rest[byte=j + 1:eq_end])
        j = eq_end
    var cons = ""
    if j < rn:
        if ord(rest[byte=j]) == 124:  # |约束
            cons = String(rest[byte=j + 1:rn])
        else:
            raise Error("body_schema: unexpected char in field '" + fs.name + "'")
    # 约束语法检查 (值可解析; 类型匹配留给运行期)
    for c in _split_top(cons, 44):
        var ct = _trim(c)
        if ct == "":
            continue
        var ck = _find_eq(ct)
        if ck <= 0:
            raise Error("body_schema: bad constraint '" + ct + "' (field '" + fs.name + "')")
        var key = String(ct[byte=0:ck])
        var val = String(ct[byte=ck + 1:ct.byte_length()])
        if key == "gt" or key == "ge" or key == "lt" or key == "le" or key == "mo":
            if not _parse_f64(val)[0]:
                raise Error("body_schema: bad number '" + val + "' for " + key)
        elif key == "len" or key == "items":
            if not _parse_range(val)[0]:
                raise Error("body_schema: bad range '" + val + "' for " + key)
        elif key == "pat":
            if val == "":
                raise Error("body_schema: empty pattern for pat (field '" + fs.name + "')")
        else:
            raise Error("body_schema: unknown constraint '" + key + "' (field '" + fs.name + "')")
    fs.constraints = cons
    return fs^


def parse_body_schema(spec: String) raises -> ParsedSchema:
    """解析 _body_schema 全 spec (畸形 raise; 注册期 + 请求期共用)."""
    var out = ParsedSchema()
    for p in _split_top(spec, 59):
        var t = _trim(p)
        if t != "":
            _ = _parse_field(t)  # 语法检查 (畸形即 raise)
            out.fields.append(t)
    return out^


def field_count(s: ParsedSchema) -> Int:
    return len(s.fields)


def get_field(s: ParsedSchema, i: Int) raises -> FieldSpec:
    """取第 i 个字段的 FieldSpec (新值, move — Mojo 1.0.0 struct 无隐式拷贝)."""
    return _parse_field(s.fields[i])

