# src/fastapi_mojo/params_typed.mojo
#
# F1: 类型化 Path/Query/Body 参数校验 (Goal-0002 §1.1).
#
# 设计:
#   - 声明式: 类型标注存在 Handler.data["_param_types"], 格式 "name:type;name:type".
#     value 格式: "int" | "float" | "bool" | "string" | "int=10" (带默认值).
#   - 必填: 缺失必填参数 (path/query 均无且无默认值) -> 422.
#   - 校验失败: 返回 TypedError {status: "422 Unprocessable Entity",
#     detail: "<param>: ..."}, JSON 响应统一 detail 字段 (FastAPI 语义).
#   - 校验通过: handler 无感, ParamDict 仍是 String (类型转换由 handler 视需要做).
#
# 显式 dispatch 扩展点 (与 ADR-0004 run_handler 模式一致):
#   validate_params(type_spec, path_params, query_params) -> TypedError
#   类型标注只在 register_routes 用 set_data("_param_types", ...) 声明.
#
# Mojo 1.0.0 约束: 无 match -> if/elif; 无闭包 -> 数据 + 单点 dispatch;
#   String[byte=i] 与 char 字面量比较用 ord() 统一处理 (避免 String/Span 混淆).

from handler import Handler
from json import json_escape


# ---------- 类型化错误结构 (F1) ----------

struct TypedError:
    """类型校验错误. status_line 必为 422, detail 字段给客户端 (FastAPI 语义)."""
    var has_error: Bool
    var status_line: String
    var detail: String  # 直接作为 JSON {"detail": "..."} 的 detail 字段

    def __init__(out self):
        self.has_error = False
        self.status_line = ""
        self.detail = ""

    def __init__(out self, status_line: String, detail: String):
        self.has_error = True
        self.status_line = status_line
        self.detail = detail


# ---------- 类型元数据解析 (parse "int=10" -> (base_type, default)) ----------

struct TypeSpec:
    """单个参数的类型规格. base_type 必填; default_value 空 = 无默认值."""
    var base_type: String     # "int" | "float" | "bool" | "string"
    var default_value: String  # "" = 无默认; 其它 = 默认值字符串 (字面量)

    def __init__(out self, base_type: String, default_value: String):
        self.base_type = base_type
        self.default_value = default_value

    def has_default(self) -> Bool:
        return self.default_value != ""


def _is_known_type(t: String) -> Bool:
    return t == "int" or t == "float" or t == "bool" or t == "string"


def parse_type_spec(raw: String) -> TypeSpec:
    """解析 "int" / "int=10" / "bool=false" / "string" -> TypeSpec.

    - base_type 必须已知, 否则返回 base_type=raw (由校验层判错).
    - 有 '=' 但 default 空 -> default_value="" (视为无默认, 由校验层判错).
    不 raise (hot path 友好): 错误留给 validate_params 报告."""
    var n = raw.byte_length()
    var eq = -1
    for i in range(n):
        if ord(raw[byte=i]) == 61:  # '='
            eq = i
            break
    if eq < 0:
        return TypeSpec(raw, "")
    var base = String(raw[byte=0:eq])
    var default = String(raw[byte=eq + 1:n])
    return TypeSpec(base, default)


# ---------- 基础类型解析 (决策-38: 支持 T[values] enum) ----------

struct ParsedBase:
    """基础类型解析结果 (ok + 类型名 + enum 值表)."""
    var ok: Bool
    var type_name: String
    var is_enum: Bool
    var values_csv: String

    def __init__(out self):
        self.ok = False
        self.type_name = ""
        self.is_enum = False
        self.values_csv = ""

    def __init__(out self, type_name: String, is_enum: Bool, values_csv: String):
        self.ok = True
        self.type_name = type_name
        self.is_enum = is_enum
        self.values_csv = values_csv


def parse_base(raw: String) -> ParsedBase:
    """解析基础类型: "int" / "str[low,high]" (enum, 决策-38). 畸形 -> ok=False."""
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
                return ParsedBase("str", True, vals)
            if base == "int" or base == "float" or base == "bool":
                return ParsedBase(base, True, vals)
            return ParsedBase()
        i += 1
    if raw == "str" or raw == "string":
        return ParsedBase("str", False, "")
    if raw == "int" or raw == "float" or raw == "bool":
        return ParsedBase(raw, False, "")
    return ParsedBase()


def _enum_in(v: String, csv: String) -> Bool:
    """v 是否在 enum 值表 (CSV) 中 (trim 后精确匹配)."""
    var n = csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(csv[byte=i]) == 44)
        if is_sep:
            if i > start:
                var piece = String(csv[byte=start:i])
                var b = 0
                var e = piece.byte_length()
                while b < e and (ord(piece[byte=b]) == 32 or ord(piece[byte=b]) == 9):
                    b += 1
                while e > b and (ord(piece[byte=e - 1]) == 32 or ord(piece[byte=e - 1]) == 9):
                    e -= 1
                if e > b and String(piece[byte=b:e]) == v:
                    return True
            start = i + 1
        i += 1
    return False


def _enum_msg(csv: String) -> String:
    """FastAPI enum 消息: "Input should be 'a' or 'b'". """
    var n = csv.byte_length()
    var start = 0
    var i = 0
    var sb = ""
    var count = 0
    var total = 0
    # 先数总数
    var j = 0
    while j <= n:
        var is_sep2 = (j == n) or (ord(csv[byte=j]) == 44)
        if is_sep2:
            if j > start:
                total += 1
            start = j + 1
        j += 1
    while i <= n:
        var is_sep = (i == n) or (ord(csv[byte=i]) == 44)
        if is_sep:
            if i > start:
                var piece = String(csv[byte=start:i])
                var b = 0
                var e = piece.byte_length()
                while b < e and (ord(piece[byte=b]) == 32 or ord(piece[byte=b]) == 9):
                    b += 1
                while e > b and (ord(piece[byte=e - 1]) == 32 or ord(piece[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    if count > 0:
                        sb = sb + (" or " if count == total - 1 else ", ")
                    sb = sb + "'" + String(piece[byte=b:e]) + "'"
                    count += 1
            start = i + 1
        i += 1
    return "Input should be " + sb


def _pe(loc: String, msg: String, type_name: String) -> String:
    """单个参数校验错误 JSON 对象 (FastAPI loc/msg/type, 决策-38)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\"}"


# ---------- 类型转换原语 ----------

def _is_int_literal(s: String) -> Bool:
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


def _is_float_literal(s: String) -> Bool:
    """True if s is a float literal (sign? intpart '.' intpart (exp)?).
    Accepts 'inf' / '-inf' / 'nan'. 必须含小数点或指数 (区别于 int)."""
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
            # exponent must be followed by at least one digit
            if i + 1 >= n:
                return False
            var j = i + 1
            var ej = ord(s[byte=j])
            if ej == 43 or ej == 45:  # '+' '-'
                j += 1
                if j >= n:
                    return False
            var exp_ok = False
            while j < n:
                var e2 = ord(s[byte=j])
                if e2 < 48 or e2 > 57:
                    return False
                exp_ok = True
                j += 1
            if not exp_ok:
                return False
            break
        elif c < 48 or c > 57:
            return False
        else:
            seen_digit = True
        i += 1
    if not seen_digit:
        return False
    return seen_dot or seen_exp


def _parse_bool_literal(s: String) -> Tuple[Bool, Bool]:
    """Parse bool literal -> (ok, value). Accepts true/false/True/False/1/0."""
    if s == "true" or s == "True" or s == "1":
        return (True, True)
    if s == "false" or s == "False" or s == "0":
        return (True, False)
    return (False, False)


def parse_typed_value(type_name: String, raw: String) -> Tuple[Bool, String]:
    """把字符串 raw 按 type_name 解析; 成功 -> (True, 类型化字面量字符串).
    类型化字面量 (与 json_serialize 一致):
      int/float -> 数字串; bool -> "true"/"false"; string -> 原样.
    失败 -> (False, "")."""
    if type_name == "string":
        return (True, raw)
    if type_name == "int":
        if not _is_int_literal(raw):
            return (False, "")
        return (True, raw)
    if type_name == "float":
        if not _is_float_literal(raw):
            return (False, "")
        return (True, raw)
    if type_name == "bool":
        var pr = _parse_bool_literal(raw)
        if not pr[0]:
            return (False, "")
        if pr[1]:
            return (True, "true")
        return (True, "false")
    return (False, "")


# ---------- 校验入口 (validate_params) ----------

def validate_params_collect(type_spec: Dict[String, String],
                            path_params: Dict[String, String],
                            query_params: Dict[String, String]) raises -> Tuple[Bool, List[String]]:
    """统一校验 (决策-38 collect 模式): 收集全部错误 (FastAPI loc/msg/type JSON 对象).
    优先 path_params; path 无则查 query_params; 都无则看 default_value.
    loc: path 参数 -> ["path",name]; query 参数 -> ["query",name].
    支持 T[values] enum (决策-38). 此函数不改入参 dict, 严格按声明顺序遍历."""
    var errs = List[String]()
    if len(type_spec) == 0:
        return (True, errs^)

    for k in type_spec:
        var spec = type_spec[k]
        var ts = parse_type_spec(spec)
        var pb = parse_base(ts.base_type)
        var in_path = k in path_params
        var loc = "[\"path\",\"" + json_escape(k) + "\"]"
        if not in_path:
            loc = "[\"query\",\"" + json_escape(k) + "\"]"
        if not pb.ok:
            errs.append(_pe(loc, "unknown type for parameter '" + k + "': " + ts.base_type, "unknown_type"))
            continue

        # 取值: path 优先 -> query -> default
        var raw = ""
        var has_value = False
        if in_path:
            raw = path_params[k]
            has_value = True
        elif k in query_params:
            raw = query_params[k]
            has_value = True
        elif ts.has_default():
            raw = ts.default_value
            has_value = True

        if not has_value:
            errs.append(_pe(loc, "field required", "missing"))
            continue

        if pb.is_enum:
            if not _enum_in(raw, pb.values_csv):
                errs.append(_pe(loc, _enum_msg(pb.values_csv), "enum"))
            continue

        # 类型校验
        var pr = parse_typed_value(pb.type_name, raw)
        if not pr[0]:
            if pb.type_name == "int":
                errs.append(_pe(loc, "Input should be a valid integer, unable to parse string as an integer", "int_parsing"))
            elif pb.type_name == "float":
                errs.append(_pe(loc, "Input should be a valid number, unable to parse string as a number", "float_parsing"))
            else:
                errs.append(_pe(loc, "Input should be a valid boolean", "bool_parsing"))

    return (len(errs) == 0, errs^)


def validate_params(type_spec: Dict[String, String],
                    path_params: Dict[String, String],
                    query_params: Dict[String, String]) raises -> TypedError:
    """(兼容入口) 统一校验; 失败时 detail = 首个错误对象. 主路径用 validate_params_collect."""
    var r = validate_params_collect(type_spec, path_params, query_params)
    if r[0]:
        return TypedError()
    return TypedError("422 Unprocessable Entity", r[1][0])


# ---------- 声明式类型标注 helpers (register_routes 用) ----------

def set_param_type(mut handler: Handler, name: String, type_spec: String) raises:
    """把类型规格写入 handler.data["_param_types"].
    注册时校验类型名/enum 值表/默认值合法性 (避免 hot path 失败)."""
    var ts = parse_type_spec(type_spec)
    var pb = parse_base(ts.base_type)
    if not pb.ok:
        raise Error("set_param_type: unknown type '" + ts.base_type + "' for '" + name + "'")
    if pb.is_enum:
        if ts.has_default() and not _enum_in(ts.default_value, pb.values_csv):
            raise Error("set_param_type: enum default '" + ts.default_value +
                        "' not in values for parameter '" + name + "'")
    elif ts.has_default():
        var pr = parse_typed_value(pb.type_name, ts.default_value)
        if not pr[0]:
            raise Error("set_param_type: bad default value '" + ts.default_value +
                        "' for type '" + pb.type_name + "' on parameter '" + name + "'")
    if "_param_types" not in handler.data:
        handler.data["_param_types"] = ""
    var existing = handler.data["_param_types"]
    if existing != "":
        existing = existing + ";"
    handler.data["_param_types"] = existing + name + ":" + type_spec


def get_param_types(handler: Handler) raises -> Dict[String, String]:
    """从 handler.data["_param_types"] 解析成 Dict[name, type_spec]."""
    var out = Dict[String, String]()
    if "_param_types" not in handler.data:
        return out^
    var raw = handler.data["_param_types"]
    if raw == "":
        return out^
    var n = raw.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(raw[byte=i]) == 59)  # ';'
        if is_sep:
            if i > start:
                var pair = String(raw[byte=start:i])
                var colon = -1
                for j in range(pair.byte_length()):
                    if ord(pair[byte=j]) == 58:  # ':'
                        colon = j
                        break
                if colon > 0:
                    var k = String(pair[byte=0:colon])
                    var v = String(pair[byte=colon + 1:pair.byte_length()])
                    out[k] = v
            start = i + 1
        i += 1
    return out^
