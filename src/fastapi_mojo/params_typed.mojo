# src/fastapi_mojo/params_typed.mojo
#
# F1: 类型化 Path/Query 参数校验 (Goal-0002 §1.1) + 决策-43 List 多值/alias +
# 决策-54 (ADR-0029) 约束面 (数值 gt/ge/lt/le/mo; str len/pat; 每字段仅报
# 首个违规; 422 = house 键序 + ctx 末位; 群序 path→query 两段遍历).
#
# 声明式 (扩展点在 register_routes, 核心零改动): _param_types =
#   "name:type;..." ("int" / "int=10" / "int[]" (List) / "int[]=1,2" /
#   "str[low,high]" (enum, 决策-38); 空括号 = list, 非空 = enum);
#   _param_aliases = "name=alias" (决策-43: query key = alias, 原始 name
#   无绑定效力); _param_constraints = "name=k=v;..." (决策-54, 解析/校验
#   在 param_constraints/param_constraints_run). 校验失败 -> 422 + FastAPI
#   detail 数组 (loc/msg/type/input, collect-all; list 元素 loc 带下标 i).
#   标量多值 = last-wins (Starlette); list = 全部 occurrence. 校验通过 ->
#   handler 无感 (String dict).
#
# 类型字面量原语 (TypeSpec/parse_type_spec/ParsedBase/parse_base/
# parse_typed_value/bool-int-float 字面量) 已抽至 numlit (决策-54, 供
# param_constraints 共用, 回边消除).
#
# 依赖方向: params_typed -> {numlit, param_constraints, params_query_extra,
# handler, json}; params_query_extra 仅函数内 back-import parse_typed_value
# (既有模式, 无模块级环). Mojo 1.0.0: 无 match -> if/elif; String[byte=i]
# 字节比较用 ord() 统一; ConstraintSpec 非 ImplicitlyCopyable (容器存 raw CSV
# string, 使用点按需解析, ADR-0029 §7).

from handler import Handler
from params_query_extra import validate_list_values, split_csv, parse_table
from numlit import (TypeSpec, parse_type_spec, ParsedBase, parse_base,
                   parse_typed_value, parse_f64, enum_in, enum_msg)
from param_constraints import (_pe_ctx, parse_constraint_entry,
                               check_num_constraints, check_str_constraints)
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


def _pe(loc: String, msg: String, type_name: String, input_json: String) -> String:
    """单个参数校验错误 JSON 对象 (决策-45: loc/msg/type/input, 上游 0.141.1)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\",\"input\":" + input_json + "}"


# ---------- 单参数校验 (validate_params_collect 循环体) ----------

def _vpc_one(k: String, type_spec: Dict[String, String], path_params: Dict[String, String],
             query_params: Dict[String, String], query_multi: Dict[String, List[String]],
             aliases: Dict[String, String], constraints: Dict[String, String],
             mut errs: List[String]) raises:
    """单参数校验: loc = path->["path",k] / query->["query",k] (list 元素 +
    下标 i); 取值 path 优先 -> query (alias) -> default; enum / 类型解析
    (失败 -> 完整消息, 决策-54 §3.4) / 约束 (每字段仅首个违规, 决策-54)."""
    var spec = type_spec[k]
    var ts = parse_type_spec(spec)
    var pb = parse_base(ts.base_type)
    var in_path = k in path_params
    var loc = "[\"path\",\"" + json_escape(k) + "\"]"
    if not in_path:
        loc = "[\"query\",\"" + json_escape(k) + "\"]"
    if not pb.ok:
        errs.append(_pe(loc, "unknown type for parameter '" + k + "': " + ts.base_type, "unknown_type", "null"))
        return
    var lookup = k
    if not in_path and k in aliases:
        lookup = aliases[k]
    if ts.is_list:
        # 决策-43: list 参数 (path 命中时按单值校验 — path 恒单值, 宽松)
        # 决策-54: list + 约束注册期已拒, 运行期不查
        if in_path:
            var one = List[String]()
            one.append(path_params[k])
            validate_list_values(pb.type_name, one^, k, errs)
            return
        var vals: List[String]
        if lookup in query_multi:
            vals = query_multi[lookup].copy()
        elif ts.has_default():
            var d = ts.default_value
            vals = split_csv(d)
        else:
            errs.append(_pe(loc, "Field required", "missing", "null"))
            return
        validate_list_values(pb.type_name, vals^, k, errs)
        return
    var raw = ""
    var has_value = False
    var from_default = False
    if in_path:
        raw = path_params[k]
        has_value = True
    elif lookup in query_params:
        raw = query_params[lookup]
        has_value = True
    elif ts.has_default():
        raw = ts.default_value
        has_value = True
        from_default = True
    if not has_value:
        errs.append(_pe(loc, "Field required", "missing", "null"))
        return
    if pb.is_enum:
        if not enum_in(raw, pb.values_csv):
            errs.append(_pe(loc, enum_msg(pb.values_csv), "enum", "\"" + json_escape(raw) + "\""))
        elif k in constraints and parse_constraint_entry(constraints[k], "").has_string():
            # 决策-54: enum 值通过后再查字符串约束 (数值约束对 enum 注册期已拒)
            var cre = check_str_constraints(raw, parse_constraint_entry(constraints[k], ""))
            if not cre[0]:
                errs.append(_pe_ctx(loc, cre[1], cre[2], "\"" + json_escape(raw) + "\"", cre[3]))
        return
    var pr = parse_typed_value(pb.type_name, raw)
    if not pr[0]:
        if pb.type_name == "int":
            errs.append(_pe(loc, "Input should be a valid integer, unable to parse string as an integer", "int_parsing", "\"" + json_escape(raw) + "\""))
        elif pb.type_name == "float":
            errs.append(_pe(loc, "Input should be a valid number, unable to parse string as a number", "float_parsing", "\"" + json_escape(raw) + "\""))
        else:
            # 决策-54 §3.4: 完整上游串 (矩阵 #3 标量 bool 短消息偏差销账,
            # 与 form/list 面三面对齐)
            errs.append(_pe(loc, "Input should be a valid boolean, unable to interpret input", "bool_parsing", "\"" + json_escape(raw) + "\""))
        return
    # 决策-54: 类型解析成功后查约束 (每字段仅首个违规; 在场值 input = raw 串
    # (上游 stage 语义 P26-a); 缺失+默认违反 input = 类型化字面量 (int/float
    # 裸数字 / P26-b-8 同源); 数值键对 str / str 键对数值 注册期已拒
    if k in constraints:
        var cont = True
        if parse_constraint_entry(constraints[k], "").has_numeric():
            var cr = check_num_constraints(parse_f64(raw)[1],
                                           parse_constraint_entry(constraints[k], ""))
            if not cr[0]:
                var in_json = "\"" + json_escape(raw) + "\""
                if from_default:
                    in_json = raw  # 默认 = 注册期已校验数字字面量 -> 裸 JSON 数字
                errs.append(_pe_ctx(loc, cr[1], cr[2], in_json, cr[3]))
                cont = False
        if cont and parse_constraint_entry(constraints[k], "").has_string():
            var cr2 = check_str_constraints(raw, parse_constraint_entry(constraints[k], ""))
            if not cr2[0]:
                errs.append(_pe_ctx(loc, cr2[1], cr2[2], "\"" + json_escape(raw) + "\"", cr2[3]))


# ---------- 校验入口 ----------

def validate_params_collect(type_spec: Dict[String, String],
                            path_params: Dict[String, String],
                            query_params: Dict[String, String],
                            query_multi: Dict[String, List[String]],
                            aliases: Dict[String, String],
                            constraints: Dict[String, String]) raises -> Tuple[Bool, List[String]]:
    """统一校验 (决策-38 collect + 决策-43 list/alias + 决策-45 input/
    collect-all + 决策-54 约束): 收集全部错误 (loc/msg/type/input [+ctx]).
    群序: 先 path 段后 query (两段遍历, P26-b-10 path→query 群序; 组内 =
    dict 迭代序). list 元素 loc 带下标 i, collect-all. 不改入参 dict."""
    var errs = List[String]()
    if len(type_spec) == 0:
        return (True, errs^)
    for k in type_spec:
        if k in path_params:
            _vpc_one(k, type_spec, path_params, query_params, query_multi, aliases, constraints, errs)
    for k in type_spec:
        if k not in path_params:
            _vpc_one(k, type_spec, path_params, query_params, query_multi, aliases, constraints, errs)
    return (len(errs) == 0, errs^)


def validate_params(type_spec: Dict[String, String],
                    path_params: Dict[String, String],
                    query_params: Dict[String, String]) raises -> TypedError:
    """(兼容入口) 统一校验; 失败时 detail = 首个错误对象. 主路径用 collect.
    无 list/alias/约束输入 (传空 dict; 决策-43/54 能力走 collect)."""
    var r = validate_params_collect(type_spec, path_params, query_params,
                                    Dict[String, List[String]](), Dict[String, String](),
                                    Dict[String, String]())
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
        if ts.has_default() and not enum_in(ts.default_value, pb.values_csv):
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
    return validate_params_collect(parse_table(spec, 59, 58, True), _t(path), _t(flat), qm, _t(alias_name),
                                   Dict[String, String]())


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
