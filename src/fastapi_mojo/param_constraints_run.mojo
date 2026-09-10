# src/fastapi_mojo/param_constraints_run.mojo
#
# 决策-54 (ADR-0029): 参数约束面运行期 collect 层 — typed header 统一校验 +
# 隐式 str (未类型化 path/query) 独立 pass. 拆分自 param_constraints.mojo
# (500 行规则: spec/注册/OpenAPI 在 param_constraints, 运行期 collect 在此).
# 依赖方向: param_constraints_run -> param_constraints -> numlit (单向, 无环).
#
# 语义 (ADR-0029 §3.3): header 缺失有默认 -> 校验默认 (违 -> 422, input =
# 类型化默认, P26-b-7/8; 过 -> 注入默认字面量); 缺失无默认 -> 422 missing
# (input null, loc = wire 名); 在场 -> 类型解析 (失败 -> 422 完整消息 §3.4)
# -> 约束 (同优先级; input = raw 串) -> 注入原始字符串 (F1 String dict).
# 隐式 str: path 段恒在场 / query 缺失 -> missing (声明即必填); 数值键注册
# 期已拒, 运行期不出现. 群序 path→query→header 由 dispatch 装配 (P26-b-10).

from numlit import (parse_type_spec, parse_base, parse_typed_value,
                   enum_in, enum_msg, parse_f64)
from json import json_escape
from param_constraints import (_pe, _pe_ctx, _rgx_match, parse_constraint_entry,
                               check_num_constraints, check_str_constraints)

def _hdr_parse_err(loc: String, type_name: String, raw: String) -> String:
    """parse 失败 422 (完整上游消息 §3.4; bool = 三面对齐完整串, 决策-54 §3.4)."""
    if type_name == "int":
        return _pe(loc, "Input should be a valid integer, unable to parse string as an integer",
                   "int_parsing", "\"" + json_escape(raw) + "\"")
    if type_name == "float":
        return _pe(loc, "Input should be a valid number, unable to parse string as a number",
                   "float_parsing", "\"" + json_escape(raw) + "\"")
    return _pe(loc, "Input should be a valid boolean, unable to interpret input",
               "bool_parsing", "\"" + json_escape(raw) + "\"")


# ---------- 运行期: typed header ----------

def validate_headers_collect(header_types: Dict[String, String],
                             reads: Dict[String, String],
                             present: Dict[String, String],
                             constraints: Dict[String, String]) raises -> Tuple[Bool, List[String], Dict[String, String]]:
    """Header 统一校验 (ADR-0029 §3.3). 返回 (ok, errs, inject_values):
    缺失: 有默认 -> 校验默认 (违 -> 422, input = 类型化默认, P26-b-7/8; 过 ->
    注入默认字面量); 无默认 -> 422 missing (input null, loc = wire 名).
    在场: 类型解析 (失败 -> 422 完整消息) -> 约束 (同优先级; input = raw 串)
    -> 注入原始字符串 (handler 无感, F1 String dict). list header: 多值取首
    按元素类型标量校验; 约束注册期已拒. inject_values 仅全部成功时有效."""
    var errs = List[String]()
    var vals = Dict[String, String]()
    if len(header_types) == 0:
        return (True, errs^, vals^)
    for name in header_types:
        var ts = parse_type_spec(header_types[name])
        var pb = parse_base(ts.base_type)
        var wire = name
        if name in reads:
            wire = reads[name]
        var loc = "[\"header\",\"" + json_escape(wire) + "\"]"
        if name not in present:
            if not ts.has_default():
                errs.append(_pe(loc, "Field required", "missing", "null"))
                continue
            var dpr = parse_typed_value(pb.type_name, ts.default_value)
            if not dpr[0]:
                errs.append(_hdr_parse_err(loc, pb.type_name, ts.default_value))
                continue
            if name in constraints and not pb.is_list:
                if parse_constraint_entry(constraints[name], "").has_numeric():
                    var crd = check_num_constraints(parse_f64(ts.default_value)[1],
                                                    parse_constraint_entry(constraints[name], ""))
                    if not crd[0]:
                        errs.append(_pe_ctx(loc, crd[1], crd[2], dpr[1], crd[3]))
                        continue
                if parse_constraint_entry(constraints[name], "").has_string():
                    var crd2 = check_str_constraints(ts.default_value,
                                                     parse_constraint_entry(constraints[name], ""))
                    if not crd2[0]:
                        errs.append(_pe_ctx(loc, crd2[1], crd2[2],
                                            "\"" + json_escape(ts.default_value) + "\"", crd2[3]))
                        continue
            vals[name] = dpr[1]
            continue
        var raw = present[name]
        if ts.is_list:
            if not parse_typed_value(pb.type_name, raw)[0]:
                errs.append(_hdr_parse_err(loc, pb.type_name, raw))
                continue
            vals[name] = raw
            continue
        if pb.is_enum:
            if not enum_in(raw, pb.values_csv):
                errs.append(_pe(loc, enum_msg(pb.values_csv), "enum", "\"" + json_escape(raw) + "\""))
            elif name in constraints:
                if parse_constraint_entry(constraints[name], "").has_string():
                    var cre = check_str_constraints(raw, parse_constraint_entry(constraints[name], ""))
                    if not cre[0]:
                        errs.append(_pe_ctx(loc, cre[1], cre[2], "\"" + json_escape(raw) + "\"", cre[3]))
            continue
        var pr = parse_typed_value(pb.type_name, raw)
        if not pr[0]:
            errs.append(_hdr_parse_err(loc, pb.type_name, raw))
            continue
        var cont = True
        if name in constraints:
            if parse_constraint_entry(constraints[name], "").has_numeric():
                var cr = check_num_constraints(parse_f64(raw)[1],
                                               parse_constraint_entry(constraints[name], ""))
                if not cr[0]:
                    # 在场值违反约束: input = 原始字符串 (上游 stage 语义, P26-a)
                    errs.append(_pe_ctx(loc, cr[1], cr[2], "\"" + json_escape(raw) + "\"", cr[3]))
                    cont = False
            if cont and parse_constraint_entry(constraints[name], "").has_string():
                var cr2 = check_str_constraints(raw, parse_constraint_entry(constraints[name], ""))
                if not cr2[0]:
                    errs.append(_pe_ctx(loc, cr2[1], cr2[2], "\"" + json_escape(raw) + "\"", cr2[3]))
        if cont:
            vals[name] = raw
    return (len(errs) == 0, errs^, vals^)


# ---------- 运行期: 隐式 str (未类型化 path/query) ----------

def validate_implicit_constraints(constraints: Dict[String, String],
                                  type_spec: Dict[String, String],
                                  header_types: Dict[String, String],
                                  path_params: Dict[String, String],
                                  query_values: Dict[String, String]) raises -> List[String]:
    """未类型化 (不在 _param_types/_header_types) 但声明 len/pat 的隐式 str
    参数 (path 段 / query 键): dispatch 独立 pass (值恒 str). path 段恒在场;
    query 缺失 -> 422 missing (声明即必填). 数值键注册期已拒, 运行期不出现."""
    var errs = List[String]()
    if len(constraints) == 0:
        return errs^
    for name in constraints:
        if name in type_spec or name in header_types:
            continue
        var loc = "[\"query\",\"" + json_escape(name) + "\"]"
        var has_value = False
        var raw = ""
        if name in path_params:
            loc = "[\"path\",\"" + json_escape(name) + "\"]"
            raw = path_params[name]
            has_value = True
        elif name in query_values:
            raw = query_values[name]
            has_value = True
        if not has_value:
            errs.append(_pe(loc, "Field required", "missing", "null"))
            continue
        if parse_constraint_entry(constraints[name], "").has_string():
            var cr = check_str_constraints(raw, parse_constraint_entry(constraints[name], ""))
            if not cr[0]:
                errs.append(_pe_ctx(loc, cr[1], cr[2], "\"" + json_escape(raw) + "\"", cr[3]))
    return errs^

