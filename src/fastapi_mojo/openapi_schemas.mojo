# src/fastapi_mojo/openapi_schemas.mojo
#
# 决策-45 (ADR-0020 模块抽取): 决策-38 的 body-schema OpenAPI 构造 helpers
# (从 openapi.mojo 纯搬运, 函数体零改动) — 使 openapi.mojo 回落到 <500 行
# 并给 form OpenAPI (form_params) 留出接线空间。
#
# 依赖方向: openapi_schemas -> {body_schema, string_builder, json};
# openapi -> openapi_schemas (单向; 与 form_params 无依赖).

from body_schema import (FieldSpec, ParsedSchema, parse_body_schema, get_field,
                         field_count, _split_top, _trim, _parse_range)
from param_constraints import (ConstraintSpec, constraint_schema_fragments,
                               parse_constraint_entry)
from numlit import parse_base, parse_typed_value
from string_builder import StringBuilder
from json import json_escape

def _type_to_openapi(t: String) -> String:
    """map Mojo 类型名 -> OpenAPI 3.0 type+format."""
    if t == "int": return "integer"
    if t == "float": return "number"
    if t == "bool": return "boolean"
    if t == "obj": return "object"
    if t == "arr": return "array"
    return "string"  # default


def _json_str_array(csv: String) raises -> String:
    """CSV -> JSON string 数组 ["a","b"] (决策-38 enum 输出)."""
    var items = _split_top(csv, 44)
    var sb = StringBuilder()
    var first = True
    for it in items:
        var t = _trim(it)
        if t == "":
            continue
        if not first:
            sb.append(",")
        first = False
        sb.append("\"" + json_escape(t) + "\"")
    return "[" + sb.take() + "]"


def _openapi_default_value(fs: FieldSpec) raises -> String:
    """default 的 JSON 字面量 (数字原样 / 字符串引号 / bool true-false / obj-arr raw)."""
    var d = fs.default_value
    if fs.type_name == "int" or fs.type_name == "float":
        return d
    if fs.type_name == "bool":
        if d == "true" or d == "false":
            return d
        return "null"
    if fs.type_name == "obj" or fs.type_name == "arr" or fs.is_array:
        return d
    return "\"" + json_escape(d) + "\""


def _body_numeric_fragments(cons: String) raises -> List[String]:
    """Body numeric constraints -> OpenAPI 3.0 fragments (same boolean
    exclusive encoding as parameter schemas in ADR-0029)."""
    var out = List[String]()
    var min_value = ""
    var min_exclusive = False
    var max_value = ""
    var max_exclusive = False
    for c in _split_top(cons, 44):
        var ct = _trim(c)
        if ct.startswith("gt="):
            min_value = String(ct[byte=3:ct.byte_length()])
            min_exclusive = True
        elif ct.startswith("ge="):
            if min_value == "":
                min_value = String(ct[byte=3:ct.byte_length()])
        elif ct.startswith("lt="):
            max_value = String(ct[byte=3:ct.byte_length()])
            max_exclusive = True
        elif ct.startswith("le="):
            if max_value == "":
                max_value = String(ct[byte=3:ct.byte_length()])
    if min_value != "":
        out.append("\"minimum\":" + min_value)
        if min_exclusive:
            out.append("\"exclusiveMinimum\":true")
    if max_value != "":
        out.append("\"maximum\":" + max_value)
        if max_exclusive:
            out.append("\"exclusiveMaximum\":true")
    return out^


def _openapi_field_schema(fs: FieldSpec) raises -> String:
    """单字段 schema (决策-38): type/format/enum/min-maxItems/min-maxLength/default."""
    var sb = StringBuilder()
    # Decision-61: an array of models uses the recursive object schema as its
    # OpenAPI `items` value; array size/default constraints remain outer-level.
    if fs.is_array and fs.elem == "obj" and fs.nested_spec != "":
        sb.append("{\"type\":\"array\",\"items\":" + _openapi_object_schema(fs.nested_spec))
        for c in _split_top(fs.constraints, 44):
            var ct = _trim(c)
            if ct.startswith("items="):
                var pr = _parse_range(String(ct[byte=6:ct.byte_length()]))
                if pr[0]:
                    if pr[1] > 0:
                        sb.append(",\"minItems\":" + String(pr[1]))
                    if pr[2] > 0:
                        sb.append(",\"maxItems\":" + String(pr[2]))
        if fs.has_default():
            sb.append(",\"default\":" + _openapi_default_value(fs))
        sb.append("}")
        return sb.take()
    if fs.is_array:
        # Decision-58: elem-level constraints live INSIDE the items schema;
        # minItems/maxItems stay on the array schema (outer level).
        sb.append("{\"type\":\"array\",\"items\":{\"type\":\"" + _type_to_openapi(fs.elem) + "\"")
        if fs.elem == "str":
            for c2 in _split_top(fs.constraints, 44):
                var ct2 = _trim(c2)
                if ct2.startswith("len="):
                    var pr3 = _parse_range(String(ct2[byte=4:ct2.byte_length()]))
                    if pr3[0]:
                        if pr3[1] > 0:
                            sb.append(",\"minLength\":" + String(pr3[1]))
                        if pr3[2] > 0:
                            sb.append(",\"maxLength\":" + String(pr3[2]))
            for c3 in _split_top(fs.constraints, 44):
                var ct3 = _trim(c3)
                if ct3.startswith("pat="):
                    sb.append(",\"pattern\":\"" + json_escape(String(ct3[byte=4:ct3.byte_length()])) + "\"")
        elif fs.elem == "int" or fs.elem == "float":
            for f in _body_numeric_fragments(fs.constraints):
                sb.append("," + f)
        sb.append("}")
        for c in _split_top(fs.constraints, 44):
            var ct = _trim(c)
            if ct.startswith("items="):
                var pr = _parse_range(String(ct[byte=6:ct.byte_length()]))
                if pr[0]:
                    if pr[1] > 0:
                        sb.append(",\"minItems\":" + String(pr[1]))
                    if pr[2] > 0:
                        sb.append(",\"maxItems\":" + String(pr[2]))
        if fs.has_default():
            sb.append(",\"default\":" + _openapi_default_value(fs))
        sb.append("}")
        return sb.take()
    if fs.type_name == "obj" and fs.nested_spec != "":
        return _openapi_object_schema(fs.nested_spec)
    if fs.is_enum:
        sb.append("{\"type\":\"" + _type_to_openapi(fs.type_name) + "\",\"enum\":" + _json_str_array(fs.enum_values))
        if fs.has_default():
            sb.append(",\"default\":" + _openapi_default_value(fs))
        sb.append("}")
        return sb.take()
    sb.append("{\"type\":\"" + _type_to_openapi(fs.type_name) + "\"")
    if fs.type_name == "int":
        sb.append(",\"format\":\"int32\"")
    if fs.type_name == "float":
        sb.append(",\"format\":\"double\"")
    if fs.type_name == "int" or fs.type_name == "float":
        for f in _body_numeric_fragments(fs.constraints):
            sb.append("," + f)
    if fs.type_name == "str":
        for c in _split_top(fs.constraints, 44):
            var ct = _trim(c)
            if ct.startswith("len="):
                var pr2 = _parse_range(String(ct[byte=4:ct.byte_length()]))
                if pr2[0]:
                    if pr2[1] > 0:
                        sb.append(",\"minLength\":" + String(pr2[1]))
                    if pr2[2] > 0:
                        sb.append(",\"maxLength\":" + String(pr2[2]))
        for c in _split_top(fs.constraints, 44):
            var ct = _trim(c)
            if ct.startswith("pat="):
                sb.append(",\"pattern\":\"" + json_escape(String(ct[byte=4:ct.byte_length()])) + "\"")
    if fs.has_default():
        sb.append(",\"default\":" + _openapi_default_value(fs))
    sb.append("}")
    return sb.take()


def _openapi_object_schema(spec: String) raises -> String:
    """_body_schema / 嵌套 obj{...} spec -> {"type":"object","properties":{...},"required":[...]}. """
    var s = parse_body_schema(spec)
    var sb = StringBuilder()
    sb.append("{\"type\":\"object\",\"properties\":{")
    var req = List[String]()
    var first = True
    for i in range(field_count(s)):
        var fs = get_field(s, i)
        if not first:
            sb.append(",")
        first = False
        sb.append("\"" + json_escape(fs.name) + "\":" + _openapi_field_schema(fs))
        if not fs.has_default():
            req.append("\"" + json_escape(fs.name) + "\"")
    sb.append("}")
    if len(req) > 0:
        sb.append(",\"required\":[" + ",".join(req) + "]")
    sb.append("}")
    return sb.take()


def _json_list_array(t: String, csv: String) raises -> String:
    """CSV -> JSON 数组 (决策-43 list 默认: int/float/bool 裸值, 其它带引号)."""
    var items = _split_top(csv, 44)
    var sb = StringBuilder()
    sb.append("[")
    var first = True
    for it in items:
        var v = _trim(it)
        if v == "":
            continue
        if not first:
            sb.append(",")
        first = False
        if t == "int" or t == "float" or t == "bool":
            sb.append(v)
        else:
            sb.append("\"" + json_escape(v) + "\"")
    sb.append("]")
    return sb.take()

# ---------- 参数 schema (决策-54: 自 openapi.mojo 移入 + 约束键) ----------

def _openapi_param_schema(base: String, desc: String, cons: ConstraintSpec) raises -> String:
    """参数 schema (决策-38 enum + 决策-43 list/default/desc + 决策-54 约束).
    键序 (ADR-0029 §3.5): type, [enum], minLength, maxLength, pattern,
    multipleOf, minimum, exclusiveMinimum, maximum, exclusiveMaximum,
    default, description. 约束键仅 scalar/enum (list+约束注册期已拒).
    隐式 str (base="string") 恒带 type 键 (§3.5-⑥ 偏差: 比上游更显式)."""
    var n = base.byte_length()
    var eq = -1
    for i in range(n):
        if ord(base[byte=i]) == 61:
            eq = i
            break
    var spec = base
    var default_value = ""
    var has_default = False
    if eq >= 0:
        spec = String(base[byte=0:eq])
        default_value = String(base[byte=eq + 1:n])
        has_default = True
    var sn = spec.byte_length()
    var br = -1
    for i in range(sn):
        if ord(spec[byte=i]) == 91:
            br = i
            break
    var sb = StringBuilder()
    if br >= 0:
        var t = String(spec[byte=0:br])
        var j = br + 1
        var found = -1
        while j < sn:
            if ord(spec[byte=j]) == 93:
                found = j
                break
            j += 1
        var vals = ""
        if found > br:
            vals = String(spec[byte=br + 1:found])
        var ot = _type_to_openapi(t)
        if vals == "":
            # list (决策-43): array; 仅显式 '=' 时带 default
            sb.append("{\"type\":\"array\",\"items\":{\"type\":\"" + ot + "\"}")
            if has_default:
                sb.append(",\"default\":" + _json_list_array(t, default_value))
        else:
            sb.append("{\"type\":\"" + ot + "\",\"enum\":" + _json_str_array(vals))
            for f in constraint_schema_fragments(cons):
                sb.append("," + f)
            if has_default:
                sb.append(",\"default\":\"" + json_escape(default_value) + "\"")
    else:
        sb.append("{\"type\":\"" + _type_to_openapi(spec) + "\"")
        for f in constraint_schema_fragments(cons):
            sb.append("," + f)
        if has_default:
            if spec == "int" or spec == "float" or spec == "bool":
                sb.append(",\"default\":" + default_value)
            else:
                sb.append(",\"default\":\"" + json_escape(default_value) + "\"")
    if desc != "":
        sb.append(",\"description\":\"" + json_escape(desc) + "\"")
    sb.append("}")
    return sb.take()


def _header_param_schema(type_spec: String, desc: String, cons: ConstraintSpec) raises -> String:
    """Header 参数 schema (ADR-0029 §3.5): type + 约束键 + default (类型化:
    int/float 数字, bool true/false, str 引号) + desc. 未类型化
    (type_spec="string") = {"type":"string"} (既有行为; 隐式 str 仍可带
    len/pat). required 由 _generate_parameter 调用方在 parameter 层处理."""
    var n = type_spec.byte_length()
    var eq = -1
    for i in range(n):
        if ord(type_spec[byte=i]) == 61:
            eq = i
            break
    var spec = type_spec
    var default_value = ""
    var has_default = False
    if eq >= 0:
        spec = String(type_spec[byte=0:eq])
        default_value = String(type_spec[byte=eq + 1:n])
        has_default = True
    var pb = parse_base(spec)
    var tname = "str"
    if pb.ok:
        tname = pb.type_name
    var sb = StringBuilder()
    sb.append("{\"type\":\"" + _type_to_openapi(tname) + "\"")
    for f in constraint_schema_fragments(cons):
        sb.append("," + f)
    if has_default:
        var tv = parse_typed_value(tname, default_value)
        if tname == "int" or tname == "float" or tname == "bool":
            if tv[0]:
                sb.append(",\"default\":" + tv[1])
            else:
                sb.append(",\"default\":" + default_value)
        else:
            sb.append(",\"default\":\"" + json_escape(default_value) + "\"")
    if desc != "":
        sb.append(",\"description\":\"" + json_escape(desc) + "\"")
    sb.append("}")
    return sb.take()


def _generate_parameter(param_name: String, in_: String, type_spec: String, required: Bool,
                        desc: String, cons: Dict[String, String]) raises -> String:
    """生成单个 OpenAPI parameter 对象 (决策-54: cons 字典按 param_name
    param_name 查后本点 parse_constraint_entry 按需解析). path/query schema 走
    _openapi_param_schema; header 走 _header_param_schema (typed header:
    类型化默认/约束; 未类型化 = string). desc 非空 -> parameter 级
    "description" (上游 Query/Path(description=...))."""
    var sb = StringBuilder()
    sb.append("{\"name\":\"" + json_escape(param_name) + "\",")
    sb.append("\"in\":\"" + in_ + "\",")
    sb.append("\"required\":" + ("true" if required else "false") + ",")
    if in_ == "path" or in_ == "query":
        if param_name in cons:
            sb.append("\"schema\":" + _openapi_param_schema(type_spec, desc,
                                                             parse_constraint_entry(cons[param_name], "")))
        else:
            sb.append("\"schema\":" + _openapi_param_schema(type_spec, desc, ConstraintSpec()))
    else:  # header
        if param_name in cons:
            sb.append("\"schema\":" + _header_param_schema(type_spec, desc,
                                                            parse_constraint_entry(cons[param_name], "")))
        else:
            sb.append("\"schema\":" + _header_param_schema(type_spec, desc, ConstraintSpec()))
    if in_ != "header" and desc != "":
        sb.append(",\"description\":\"" + json_escape(desc) + "\"")
    sb.append("}")
    return sb.take()
