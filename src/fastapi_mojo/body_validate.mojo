# src/fastapi_mojo/body_validate.mojo
#
# 决策-38 (续): body 校验运行期 — 类型检查/约束/错误构造/FastAPI 422 detail (Goal-0003 P1).
# spec 解析在 body_schema.mojo; 本文件 = 校验层 + 自测 (拆分边界: 校验不反向 import spec 内部).

from body_schema import (FieldSpec, ParsedSchema, parse_body_schema, get_field, field_count,
                         fmt_num, err_obj, _in_enum_csv, _enum_or_msg, _split_top, _trim,
                         _parse_f64, _parse_range, _find_eq, _is_int_lit, _is_num_lit)
from handler import Handler
from router import Router
from params_query import ParsedParams
from params_json import parse_body_json
from json import json_escape

def _type_err(fs: FieldSpec) -> Tuple[String, String]:
    """类型错消息 (msg, type) — 按期望类型."""
    if fs.is_array or fs.type_name == "arr":
        return ("Input should be an array", "list_type")
    if fs.type_name == "str":
        return ("Input should be a valid string", "string_type")
    if fs.type_name == "int":
        return ("Input should be a valid integer, unable to parse string as an integer", "int_parsing")
    if fs.type_name == "float":
        return ("Input should be a valid number, unable to parse string as a number", "float_parsing")
    if fs.type_name == "bool":
        return ("Input should be a valid boolean", "bool_parsing")
    return ("Input should be an object", "model_type")


# ---------- 数组元素 ----------

def _split_json_array(raw: String) -> List[String]:
    """raw JSON 数组 "[a,b,c]" 切成元素 raw 串 (深度 0 逗号, 字符串/括号感知)."""
    var out = List[String]()
    var n = raw.byte_length()
    if n < 2 or not (raw[byte=0] == '[' and raw[byte=n - 1] == ']'):
        return out^
    if n == 2:
        return out^
    var depth = 0
    var in_str = False
    var esc = False
    var start = 1
    var i = 1
    while i < n - 1:
        var o = ord(raw[byte=i])
        if in_str:
            if esc:
                esc = False
            elif o == 92:
                esc = True
            elif o == 34:
                in_str = False
        else:
            if o == 34:
                in_str = True
            elif o == 123 or o == 91:
                depth += 1
            elif o == 125 or o == 93:
                depth -= 1
            elif o == 44 and depth == 0:
                out.append(_trim(String(raw[byte=start:i])))
                start = i + 1
        i += 1
    out.append(_trim(String(raw[byte=start:n - 1])))
    return out^


def _elem_check(elem_t: String, e: String) raises -> Tuple[Bool, String, String]:
    """元素类型检查 -> (ok, msg, type)."""
    var n = e.byte_length()
    if n == 0:
        return (False, "Input should be a valid string", "string_type")
    var c0 = ord(e[byte=0])
    if elem_t == "str":
        if c0 == 34:
            return (True, "", "")
        return (False, "Input should be a valid string", "string_type")
    if elem_t == "int":
        if _is_int_lit(e):
            return (True, "", "")
        return (False, "Input should be a valid integer, unable to parse string as an integer", "int_parsing")
    if elem_t == "float":
        if _is_num_lit(e):
            return (True, "", "")
        return (False, "Input should be a valid number, unable to parse string as a number", "float_parsing")
    if elem_t == "bool":
        if e == "true" or e == "false":
            return (True, "", "")
        return (False, "Input should be a valid boolean", "bool_parsing")
    if elem_t == "obj":
        if c0 == 123:
            return (True, "", "")
        return (False, "Input should be an object", "model_type")
    if c0 == 91:
        return (True, "", "")
    return (False, "Input should be an array", "list_type")


# ---------- 约束与校验 ----------

def _body_input(raw_body: String) -> String:
    """missing 的 input JSON 片段 (0.141.1 P3 实测: input = 收到的 body 对象;
    空 body -> null). 合法 JSON body 原文即对象字面量, 原样嵌入."""
    if raw_body == "":
        return "null"
    return raw_body


def _json_input_frag(v: String) raises -> String:
    """值 -> 合法 JSON 片段: 引号/括号/number/bool/null 开头 -> 原样;
    其它 (裸 token, 如坏元素 zz) -> 转义字符串 (保 detail JSON 合法)."""
    var n = v.byte_length()
    if n == 0:
        return "null"
    var c0 = ord(v[byte=0])
    if c0 == 34 or c0 == 123 or c0 == 91:
        return v
    if _is_num_lit(v) or _is_int_lit(v):
        return v
    if v == "true" or v == "false" or v == "null":
        return v
    return "\"" + json_escape(v) + "\""


def _apply_constraints(fs: FieldSpec, raw: String, elem_count: Int, floc: String,
                       mut errs: List[String]) raises:
    """应用 gt/ge/lt/le/len/items 约束 (elem_count = 数组元素数, 非数组 = -1)."""
    var cons = fs.constraints
    if cons == "":
        return
    var rv = _parse_f64(raw)
    for c in _split_top(cons, 44):
        var ct = _trim(c)
        if ct == "":
            continue
        var ck = _find_eq(ct)
        var key = String(ct[byte=0:ck])
        var val = String(ct[byte=ck + 1:ct.byte_length()])
        if key == "gt" or key == "ge" or key == "lt" or key == "le":
            if not rv[0]:
                continue
            var cv = _parse_f64(val)
            if not cv[0]:
                continue
            if key == "gt" and not (rv[1] > cv[1]):
                errs.append(err_obj(floc, "Input should be greater than " + fmt_num(cv[1]), "greater_than", _json_input_frag(raw)))
            elif key == "ge" and not (rv[1] >= cv[1]):
                errs.append(err_obj(floc, "Input should be greater than or equal to " + fmt_num(cv[1]), "greater_than_equal", _json_input_frag(raw)))
            elif key == "lt" and not (rv[1] < cv[1]):
                errs.append(err_obj(floc, "Input should be less than " + fmt_num(cv[1]), "less_than", _json_input_frag(raw)))
            elif key == "le" and not (rv[1] <= cv[1]):
                errs.append(err_obj(floc, "Input should be less than or equal to " + fmt_num(cv[1]), "less_than_equal", _json_input_frag(raw)))
        elif key == "len":
            var rl = raw.byte_length()
            var pr = _parse_range(val)
            if pr[0]:
                if pr[1] > 0 and rl < pr[1]:
                    errs.append(err_obj(floc, "String should have at least " + String(pr[1]) + " character(s)", "string_too_short", _json_input_frag(raw)))
                if pr[2] > 0 and rl > pr[2]:
                    errs.append(err_obj(floc, "String should have at most " + String(pr[2]) + " character(s)", "string_too_long", _json_input_frag(raw)))
        elif key == "items" and elem_count >= 0:
            var pr2 = _parse_range(val)
            if pr2[0]:
                if pr2[1] > 0 and elem_count < pr2[1]:
                    errs.append(err_obj(floc, "List should have at least " + String(pr2[1]) + " item(s)", "too_short", _json_input_frag(raw)))
                if pr2[2] > 0 and elem_count > pr2[2]:
                    errs.append(err_obj(floc, "List should have at most " + String(pr2[2]) + " item(s)", "too_long", _json_input_frag(raw)))


def _validate_fields(s: ParsedSchema, body: ParsedParams, prefix: String, loc: String,
                     raw_body: String, mut out: Dict[String, String], mut errs: List[String]) raises:
    """逐字段校验 (顶层与嵌套共用). prefix = 注入键前缀; loc = FastAPI loc 数组 (不含字段名)."""
    for i in range(len(s.fields)):
        var fs = get_field(s, i)
        var key = prefix + fs.name
        var floc = loc + ",\"" + fs.name + "\""
        if not (fs.name in body.values):
            if fs.has_default():
                out[key] = fs.default_value
            else:
                errs.append(err_obj(floc + "]", "Field required", "missing", _body_input(raw_body)))
            continue
        var raw = body.values[fs.name]
        var t = "string"
        if fs.name in body.types:
            t = body.types[fs.name]
        var ok_t = False
        if fs.is_array:
            ok_t = t == "array"
        elif fs.type_name == "str":
            ok_t = t == "string"
        elif fs.type_name == "int":
            ok_t = t == "int"
        elif fs.type_name == "float":
            ok_t = t == "int" or t == "float"
        elif fs.type_name == "bool":
            ok_t = t == "bool"
        elif fs.type_name == "obj":
            ok_t = t == "object"
        elif fs.type_name == "arr":
            ok_t = t == "array"
        if not ok_t:
            var te = _type_err(fs)
            errs.append(err_obj(floc + "]", te[0], te[1], _json_input_frag(raw)))
            continue
        if fs.is_enum and not _in_enum_csv(raw, fs.enum_values):
            errs.append(err_obj(floc + "]", _enum_or_msg(fs.enum_values), "enum", _json_input_frag(raw)))
            continue
        out[key] = raw
        if fs.is_array:
            var elems = _split_json_array(raw)
            for ei in range(len(elems)):
                var ec = _elem_check(fs.elem, elems[ei])
                if not ec[0]:
                    errs.append(err_obj(floc + "," + String(ei) + "]", ec[1], ec[2], _json_input_frag(elems[ei])))
            _apply_constraints(fs, raw, len(elems), floc + "]", errs)
        elif fs.type_name == "obj" and fs.nested_spec != "":
            var sub = parse_body_json(raw)
            if sub.has_error:
                errs.append(err_obj(floc + "]", "Input should be an object", "model_type", _json_input_frag(raw)))
            else:
                var subs = parse_body_schema(fs.nested_spec)
                _validate_fields(subs, sub, prefix + fs.name + "_", floc, raw_body, out, errs)
        else:
            _apply_constraints(fs, raw, -1, floc + "]", errs)


def validate_body_schema(handler: Handler, method: String,
                         body_params: ParsedParams, body_str: String) raises -> Tuple[Bool, List[String], Dict[String, String]]:
    """`validate_body_schema` (决策-38): 按 _body_schema 校验请求 body.

    返回 (ok, errors, values): ok=False -> errors = FastAPI detail 对象 (loc/msg/type);
    ok=True -> values = 字段 -> 校验值 (含默认值), dispatch 注入 body_<name>.
    仅 POST/PUT/PATCH 且声明 _body_schema 时生效; 其余直接 ok.
    """
    var ok_vals = Dict[String, String]()
    if "_body_schema" not in handler.data:
        return (True, List[String](), ok_vals^)
    if method != "POST" and method != "PUT" and method != "PATCH":
        return (True, List[String](), ok_vals^)
    var errs = List[String]()
    if body_params.has_error:
        errs.append(err_obj("[\"body\"]", "JSON decode error", "json_invalid", _json_input_frag(body_str)))
        return (False, errs^, ok_vals^)
    var fields = parse_body_schema(handler.data["_body_schema"])
    _validate_fields(fields, body_params, "", "[\"body\"", body_str, ok_vals, errs)
    if len(errs) > 0:
        return (False, errs^, ok_vals^)
    return (True, List[String](), ok_vals^)


def check_body_schemas(router: Router) raises:
    """注册期 _body_schema 语法检查 (决策-38): 畸形 spec 立即 fail, 不带入请求路径."""
    for i in range(router.route_count()):
        var h = router.routes[i].handler.copy()
        if "_body_schema" in h.data and h.data["_body_schema"] != "":
            _ = parse_body_schema(h.data["_body_schema"])


# ---------- 自测 ----------

import std.os

def check(cond: Bool, msg: String) raises:
    """真检查: Mojo 1.0.0 `assert` 是 no-op (实测 -O0/-O3 均不触发),
    必须用 std.os.abort() 产生非零退出."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def _has(s: String, sub: String) -> Bool:
    """子串检查 (自测用; Mojo 1.0.0 String 无 contains)."""
    var sn = sub.byte_length()
    if sn == 0 or sn > s.byte_length():
        return False
    for i in range(s.byte_length() - sn + 1):
        var ok = True
        for j in range(sn):
            if s[byte=i + j] != sub[byte=j]:
                ok = False
                break
        if ok:
            return True
    return False


def main() raises:
    print("Testing Mojo body_schema (决策-38)...")
    var spec = "name:str;price:float|gt=0;quantity:int=10;mode:str[fast,slow]=fast;tags:str[]|items=0-5;meta:obj{city:str|len=2-6;zip:int=0}"
    var s = parse_body_schema(spec)
    check(field_count(s) == 6, "field count")
    var f0 = get_field(s, 0)
    var f1 = get_field(s, 1)
    var f3 = get_field(s, 3)
    var f4 = get_field(s, 4)
    var f5 = get_field(s, 5)
    check(f0.name == "name" and f0.type_name == "str" and not f0.has_default(), "name")
    check(f1.type_name == "float" and f1.constraints == "gt=0", "price")
    check(f3.is_enum and f3.enum_values == "fast,slow" and f3.default_value == "fast", "enum")
    check(f4.is_array and f4.elem == "str" and f4.constraints == "items=0-5", "array")
    check(f5.nested_spec == "city:str|len=2-6;zip:int=0", "nested")
    var bad = False
    try:
        _ = parse_body_schema("x:badtype")
    except:
        bad = True
    check(bad, "bad type raises")
    var h = Handler(0, "validate_item")
    h.set_data("_body_schema", spec)

    var r1 = validate_body_schema(h, "POST", parse_body_json('{"name":"widget","price":9.99,"tags":["a","b"],"meta":{"city":"sh"}}'), "")
    check(r1[0] and r1[2]["name"] == "widget" and r1[2]["quantity"] == "10" and r1[2]["mode"] == "fast", "values+defaults")
    check(r1[2]["meta_city"] == "sh" and r1[2]["meta_zip"] == "0" and r1[2]["meta"] == '{"city":"sh"}', "nested")
    check(r1[2]["tags"] == '["a","b"]', "array raw")
    var r2 = validate_body_schema(h, "POST", parse_body_json('{"price":1}'), "")
    var r3 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":"abc"}'), "")
    check(not r3[0] and _has(r3[1][0], "float_parsing"), "wrong type")
    var r4 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":-5}'), "")
    check(not r4[0] and _has(r4[1][0], "Input should be greater than 0"), "gt")
    var r5 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"mode":"turbo"}'), "")
    check(not r5[0] and _has(r5[1][0], "\"type\":\"enum\"") and _has(r5[1][0], "'fast' or 'slow'"), "enum")
    var r6 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"meta":{"city":"s"}}'), "")
    check(not r6[0] and len(r6[1]) == 2 and _has(r6[1][1], "[\"body\",\"meta\",\"city\"]") and _has(r6[1][1], "at least 2 character"), "nested len (err[1])")
    var r7 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"tags":["a","b","c","d","e","f"]}'), "")
    check(not r7[0] and _has(r7[1][0], "at most 5 item"), "items max")
    var r8 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"tags":[1,2]}'), "")
    check(not r8[0] and _has(r8[1][0], "[\"body\",\"tags\",0]"), "elem loc")
    var r9 = validate_body_schema(h, "POST", parse_body_json('{"price":-1,"mode":"turbo"}'), "")
    check(not r9[0] and len(r9[1]) == 5, "multi errors x5 (missing name + gt + enum + missing tags + missing meta)")
    var r10 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"tags":[],"meta":{"city":"ab"}}'), "")
    check(r10[0] and r10[2]["quantity"] == "10" and r10[2]["mode"] == "fast" and r10[2]["meta_zip"] == "0", "defaults applied (quantity/mode/meta_zip)")
    var r11 = validate_body_schema(h, "POST", parse_body_json("{not json"), "")
    check(not r11[0] and _has(r11[1][0], "json_invalid"), "json_invalid")
    check(validate_body_schema(h, "GET", parse_body_json("x"), "")[0], "GET skip")
    print("Mojo body_schema (决策-38) test completed!")
