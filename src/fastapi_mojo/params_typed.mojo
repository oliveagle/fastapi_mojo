# src/fastapi_mojo/params_typed.mojo
#
# F1: 类型化 Path/Query 参数校验 (Goal-0002 §1.1) + 决策-43 List 多值/alias.
#
# 声明式 (扩展点在 register_routes, 核心零改动): _param_types =
#   "name:type;..." ("int" / "int=10" / "int[]" (List) / "int[]=1,2" /
#   "str[low,high]" (enum, 决策-38); 空括号 = list, 非空 = enum);
#   _param_aliases = "name=alias" (决策-43: query key = alias, 原始 name
#   无绑定效力). 校验失败 -> 422 + FastAPI detail 数组 (loc/msg/type, 全收集;
#   list 元素 loc 带下标 i, collect-all (0.141.1 实测, 决策-45)). 错误对象含
#   input 字段 (决策-45: 上游 0.141.1 全 422 均带 input). 标量多值 = last-wins
#   (Starlette); list = 全部 occurrence. 校验通过 -> handler 无感 (String dict).
#
# 依赖方向: params_typed -> params_query_extra -> params_query (无环;
# validate_list_values 在 params_query_extra, 函数内 back-import 本模块).
# Mojo 1.0.0: 无 match -> if/elif; String[byte=i] 字节比较用 ord() 统一.

from handler import Handler
from params_query_extra import validate_list_values, split_csv, parse_table
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
    return ParsedBase()


def _enum_in(v: String, csv: String) raises -> Bool:
    """v 是否在 enum 值表 (CSV) 中 (split_csv trim 后精确匹配)."""
    var pieces = split_csv(csv)
    for piece in pieces:
        if piece == v:
            return True
    return False


def _enum_msg(csv: String) raises -> String:
    """FastAPI enum 消息: "Input should be 'a' or 'b'". """
    var pieces = split_csv(csv)
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


def _pe(loc: String, msg: String, type_name: String, input_json: String) -> String:
    """单个参数校验错误 JSON 对象 (决策-45: loc/msg/type/input, 上游 0.141.1)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\",\"input\":" + input_json + "}"


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


def _parse_bool_literal(s: String) -> Tuple[Bool, Bool]:
    """Parse bool literal -> (ok, value). Accepts true/false/True/False/1/0."""
    if s == "true" or s == "True" or s == "1":
        return (True, True)
    if s == "false" or s == "False" or s == "0":
        return (True, False)
    return (False, False)


def parse_typed_value(type_name: String, raw: String) -> Tuple[Bool, String]:
    """把字符串 raw 按 type_name 解析; 成功 -> (True, 类型化字面量字符串).
    类型化字面量 (与 json_serialize 一致): int/float -> 数字串; bool ->
    "true"/"false"; string -> 原样. 失败 -> (False, "")."""
    if type_name == "string" or type_name == "str":
        return (True, raw)
    if type_name == "int" or type_name == "float":
        var ok = _is_int_literal(raw)
        if type_name == "float":
            # 决策-45: float 接受 int 字面量 (上游 pydantic v2 parity:
            # "1" -> 1.0); 小数点/指数仍由 _is_float_literal 判定.
            ok = _is_float_literal(raw) or _is_int_literal(raw)
        if not ok:
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


# ---------- 校验入口 ----------

def validate_params_collect(type_spec: Dict[String, String],
                            path_params: Dict[String, String],
                            query_params: Dict[String, String],
                            query_multi: Dict[String, List[String]],
                            aliases: Dict[String, String]) raises -> Tuple[Bool, List[String]]:
    """统一校验 (决策-38 collect + 决策-43 list/alias + 决策-45 input/collect-all):
    收集全部错误 (loc/msg/type/input). 优先 path; 否则 query (alias 声明时
    按 alias key); 都无则看 default. loc: path -> ["path",name]; query ->
    ["query",name] (list 元素 + 下标 i). 标量 = last-wins; list = 全部
    occurrence 逐元素校验 (collect-all, 0.141.1 实测, 决策-45). 不改入参 dict."""
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
            errs.append(_pe(loc, "unknown type for parameter '" + k + "': " + ts.base_type, "unknown_type", "null"))
            continue

        # 取值: path 优先 (alias 不适用 path); query 按 alias key
        var lookup = k
        if not in_path and k in aliases:
            lookup = aliases[k]

        if ts.is_list:
            # 决策-43: list 参数 (path 命中时按单值校验 — path 恒单值, 宽松)
            if in_path:
                var one = List[String]()
                one.append(path_params[k])
                validate_list_values(pb.type_name, one^, k, errs)
                continue
            var vals: List[String]
            if lookup in query_multi:
                vals = query_multi[lookup].copy()
            elif ts.has_default():
                var d = ts.default_value
                vals = split_csv(d)
            else:
                errs.append(_pe(loc, "Field required", "missing", "null"))
                continue
            validate_list_values(pb.type_name, vals^, k, errs)
            continue

        var raw = ""
        var has_value = False
        if in_path:
            raw = path_params[k]
            has_value = True
        elif lookup in query_params:
            raw = query_params[lookup]
            has_value = True
        elif ts.has_default():
            raw = ts.default_value
            has_value = True

        if not has_value:
            errs.append(_pe(loc, "Field required", "missing", "null"))
            continue

        if pb.is_enum:
            if not _enum_in(raw, pb.values_csv):
                errs.append(_pe(loc, _enum_msg(pb.values_csv), "enum", "\"" + json_escape(raw) + "\""))
            continue

        # 类型校验
        var pr = parse_typed_value(pb.type_name, raw)
        if not pr[0]:
            if pb.type_name == "int":
                errs.append(_pe(loc, "Input should be a valid integer, unable to parse string as an integer", "int_parsing", "\"" + json_escape(raw) + "\""))
            elif pb.type_name == "float":
                errs.append(_pe(loc, "Input should be a valid number, unable to parse string as a number", "float_parsing", "\"" + json_escape(raw) + "\""))
            else:
                errs.append(_pe(loc, "Input should be a valid boolean", "bool_parsing", "\"" + json_escape(raw) + "\""))

    return (len(errs) == 0, errs^)


def validate_params(type_spec: Dict[String, String],
                    path_params: Dict[String, String],
                    query_params: Dict[String, String]) raises -> TypedError:
    """(兼容入口) 统一校验; 失败时 detail = 首个错误对象. 主路径用 collect.
    无 list/alias 输入 (传空 dict; 决策-43 能力走 validate_params_collect)."""
    var r = validate_params_collect(type_spec, path_params, query_params,
                                    Dict[String, List[String]](), Dict[String, String]())
    if r[0]:
        return TypedError()
    return TypedError("422 Unprocessable Entity", r[1][0])


# ---------- 声明式类型标注 helpers (register_routes 用) ----------

def set_param_type(mut handler: Handler, name: String, type_spec: String) raises:
    """把类型规格写入 handler.data["_param_types"].
    注册时校验类型名/enum 值表/默认值合法性 (避免 hot path 失败).
    决策-43: list 默认 CSV 逐元素校验; enum list 不可表达 -> 拒绝."""
    var ts = parse_type_spec(type_spec)
    var pb = parse_base(ts.base_type)
    if not pb.ok:
        raise Error("set_param_type: unknown type '" + ts.base_type + "' for '" + name + "'")
    if ts.is_list:
        if pb.is_enum:
            raise Error("set_param_type: enum-list not expressible for '" + name +
                        "' (non-empty brackets = enum, empty = list)")
        if ts.has_default():
            var defs = split_csv(ts.default_value)
            var i = 0
            while i < len(defs):
                var pr = parse_typed_value(pb.type_name, defs[i])
                if not pr[0]:
                    raise Error("set_param_type: bad list default element '" + defs[i] +
                                "' for type '" + pb.type_name + "' on parameter '" + name + "'")
                i += 1
    elif pb.is_enum:
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
    if "_param_types" not in handler.data:
        return Dict[String, String]()
    return parse_table(handler.data["_param_types"], 59, 58, True)


# ---------- 自测 ----------

import std.os
from params_query import parse_query_params


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def _has(s: String, sub: String) -> Bool:
    """子串检查 (自测)."""
    var sn = sub.byte_length()
    var sl = s.byte_length()
    if sn == 0 or sn > sl:
        return False
    for i in range(sl - sn + 1):
        var j = 0
        while j < sn:
            if s[byte=i + j] != sub[byte=j]:
                break
            j += 1
        if j == sn:
            return True
    return False


def _t(csv: String) raises -> Dict[String, String]:
    """自测输入: 紧凑 "k=v;..." 表 -> Dict."""
    return parse_table(csv, 59, 61, True)


def vrun(spec: String, path: String, flat: String, multi: String, alias_name: String) raises -> Tuple[Bool, List[String]]:
    var tm = _t(multi)
    var qm = Dict[String, List[String]]()
    for k in tm:
        qm[k] = split_csv(tm[k])
    return validate_params_collect(parse_table(spec, 59, 58, True), _t(path), _t(flat), qm, _t(alias_name))


def main() raises:
    print("Testing typed params (list/alias, 决策-43)...")

    var ts = parse_type_spec("int[]")
    check(ts.is_list and not ts.has_default(), "int[] list no default")
    ts = parse_type_spec("int[]=")
    check(ts.is_list and ts.has_default() and ts.default_value == "", "int[]= empty default")
    check(parse_type_spec("int[]=1,2").default_value == "1,2", "list csv default")
    check(parse_type_spec("int=10").has_default() and not parse_type_spec("int=10").is_list, "scalar default")
    check(not parse_type_spec("str[low,high]").is_list, "enum not list")
    check(parse_base("int[]").is_list and not parse_base("int[]").is_enum, "parse_base int[]")

    var r = vrun("n:int[]", "", "", "n=1,2,3", "")
    check(r[0], "list multi ok")
    r = vrun("n:int[]", "", "", "", "")
    check(not r[0] and _has(r[1][0], "missing") and _has(r[1][0], "[\"query\",\"n\"]"), "list missing loc")
    r = vrun("n:int[]", "", "", "n=1,zz", "")
    check(not r[0] and _has(r[1][0], "[\"query\",\"n\",1]") and _has(r[1][0], "int_parsing"), "list bad elem idx")
    r = vrun("n:int[]=", "", "", "", "")
    check(r[0] and vrun("n:int[]=1,2", "", "", "", "")[0], "list defaults (empty/csv) pass")
    check(not vrun("n:bool[]", "", "", "n=zz", "")[0], "list bool bad elem")

    r = vrun("limit:int=10", "", "lmt=5", "", "limit=lmt")
    check(r[0], "alias lookup ok")
    r = vrun("limit:int=10", "", "limit=9", "", "limit=lmt")
    check(r[0], "raw name ignored (default used)")
    check(parse_query_params("q=1&q=2").values["q"] == "2", "scalar last-wins")
    r = vrun("q:int", "", "q=zz", "", "")
    check(not r[0] and _has(r[1][0], "int_parsing"), "scalar int parse error")
    check(vrun("item_id:int", "item_id=42", "item_id=99", "", "")[0], "path priority")
    r = vrun("level:str[low,high]=high", "", "level=mid", "", "")
    check(not r[0] and _has(r[1][0], "enum"), "enum reject")

    print("typed params test completed!")
