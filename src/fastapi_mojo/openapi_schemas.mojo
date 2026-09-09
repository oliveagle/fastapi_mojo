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
from string_builder import StringBuilder
from json import json_escape

def _type_to_openapi(t: String) -> String:
    """map Mojo 类型名 -> OpenAPI 3.0 type+format."""
    if t == "int": return "integer"
    if t == "float": return "number"
    if t == "bool": return "boolean"
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


def _openapi_field_schema(fs: FieldSpec) raises -> String:
    """单字段 schema (决策-38): type/format/enum/min-maxItems/min-maxLength/default."""
    var sb = StringBuilder()
    if fs.is_array:
        sb.append("{\"type\":\"array\",\"items\":{\"type\":\"" + _type_to_openapi(fs.elem) + "\"}")
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
