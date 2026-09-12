# src/fastapi_mojo/body_validate_test.mojo
#
# Decision-38/57/58/61 executable body-validation tests (same-dir split keeps
# both production and test modules below the 500-line God-file threshold).

from body_schema import parse_body_schema, get_field, field_count, _is_num_lit
from body_validate import validate_body_schema, _check_body_spec
from body_coerce import _coerce_body_scalar
from float_repr import atof_f64, fmt_f64_repr, is_dec_f64_syntax
from handler import Handler
from params_json import parse_body_json
from params_query import ParsedParams

# ---------- 自测 ----------

import std.os

def check(cond: Bool, msg: String) raises:
    """真检查: Mojo 1.0.0 `assert` 是 no-op (实测 -O0/-O3 均不触发),
    必须用 std.os.abort() 产生非零退出."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def _has(s: String, sub: String) -> Bool:
    """子串检查 (自测用; Mojo 1.0.0 String 无 contains).

    字节级比较 (s.bytes() 迭代) — `s[byte=k]` 在 Mojo 1.0.0 要求 k 落在
    codepoint 边界, 逐字节 `s[byte=i+j]` 遇到多字节字符会 panic (决策-83 自测
    需检查含 "é" 的 422 JSON)."""
    var sl = List[UInt8]()
    for bb in s.bytes():
        sl.append(bb)
    var sub2 = List[UInt8]()
    for bb in sub.bytes():
        sub2.append(bb)
    var sn = len(sub2)
    if sn == 0 or sn > len(sl):
        return False
    for i in range(len(sl) - sn + 1):
        var ok = True
        for j in range(sn):
            if sl[i + j] != sub2[j]:
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

    var r1 = validate_body_schema(h, "POST", parse_body_json('{"name":"widget","price":9.99,"tags":["a","b"],"meta":{"city":"sh"}}'), '{"name":"widget","price":9.99,"tags":["a","b"],"meta":{"city":"sh"}}')
    check(r1[0] and r1[2]["name"] == "widget" and r1[2]["quantity"] == "10" and r1[2]["mode"] == "fast", "values+defaults")
    check(r1[2]["meta_city"] == "sh" and r1[2]["meta_zip"] == "0" and r1[2]["meta"] == '{"city":"sh"}', "nested")
    check(r1[2]["tags"] == '["a","b"]', "array raw")
    var r2 = validate_body_schema(h, "POST", parse_body_json('{"price":1}'), '{"price":1}')
    var r3 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":"abc"}'), '{"name":"x","price":"abc"}')
    check(not r3[0] and _has(r3[1][0], "float_parsing"), "wrong type")
    var r4 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":-5}'), '{"name":"x","price":-5}')
    check(not r4[0] and _has(r4[1][0], "Input should be greater than 0"), "gt")
    var r5 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"mode":"turbo"}'), '{"name":"x","price":1,"mode":"turbo"}')
    check(not r5[0] and _has(r5[1][0], "\"type\":\"enum\"") and _has(r5[1][0], "'fast' or 'slow'"), "enum")
    var r6 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"meta":{"city":"s"}}'), '{"name":"x","price":1,"meta":{"city":"s"}}')
    check(not r6[0] and len(r6[1]) == 2 and _has(r6[1][1], "[\"body\",\"meta\",\"city\"]") and _has(r6[1][1], "at least 2 character"), "nested len (err[1])")
    var r7 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"tags":["a","b","c","d","e","f"]}'), '{"name":"x","price":1,"tags":["a","b","c","d","e","f"]}')
    check(not r7[0] and _has(r7[1][0], "at most 5 item"), "items max")
    var r8 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"tags":[1,2]}'), '{"name":"x","price":1,"tags":[1,2]}')
    check(not r8[0] and _has(r8[1][0], "[\"body\",\"tags\",0]"), "elem loc")
    var r9 = validate_body_schema(h, "POST", parse_body_json('{"price":-1,"mode":"turbo"}'), '{"price":-1,"mode":"turbo"}')
    check(not r9[0] and len(r9[1]) == 5, "multi errors x5 (missing name + gt + enum + missing tags + missing meta)")

    # Decision-61: recursive validation inside arrays of nested objects.
    var nested_array_spec = "models:obj[]{id:int|ge=1;tag:str|len=2-3}|items=1-2"
    var nas = parse_body_schema(nested_array_spec)
    check(field_count(nas) == 1, "nested array field count")
    var naf = get_field(nas, 0)
    check(naf.is_array and naf.elem == "obj" and naf.nested_spec == "id:int|ge=1;tag:str|len=2-3",
          "obj[] carries nested schema")
    var nah = Handler(0, "validate_nested_models")
    nah.set_data("_body_schema", nested_array_spec)
    var na1 = validate_body_schema(
        nah, "POST", parse_body_json('{"models":[{"id":7,"tag":"ab"},{"id":9,"tag":"xyz"}]}'), '{"models":[{"id":7,"tag":"ab"},{"id":9,"tag":"xyz"}]}')
    check(na1[0] and na1[2]["models_0_id"] == "7" and na1[2]["models_1_tag"] == "xyz",
          "nested array valid + flattened values")
    var na2 = validate_body_schema(
        nah, "POST", parse_body_json('{"models":[{"id":0,"tag":"ab"},{"id":9,"tag":"x"}]}'), '{"models":[{"id":0,"tag":"ab"},{"id":9,"tag":"x"}]}')
    check(not na2[0] and len(na2[1]) == 2 and _has(na2[1][0], "[\"body\",\"models\",0,\"id\"]")
          and _has(na2[1][0], "greater_than_equal"), "nested array element constraints")
    var na3 = validate_body_schema(
        nah, "POST", parse_body_json('{"models":[{"tag":"ab"},{"id":9,"tag":"xyz"}]}'), '{"models":[{"tag":"ab"},{"id":9,"tag":"xyz"}]}')
    check(not na3[0] and _has(na3[1][0], "[\"body\",\"models\",0,\"id\"]")
          and _has(na3[1][0], "\"input\":{\"tag\":\"ab\"}"), "nested array missing input")
    # 决策-83: 数组长度错短路元素校验 (上游 pydantic 列表长度优先)
    var na4 = validate_body_schema(
        nah, "POST", parse_body_json('{"models":[{"tag":"ab"},{"id":9,"tag":"xyz"},'
                                     + '{"id":10,"tag":"abcd"}]}'), '{"models":[{"tag":"ab"},{"id":9,"tag":"xyz"},'
                                     + '{"id":10,"tag":"abcd"}]}')
    check(not na4[0] and len(na4[1]) == 1 and _has(na4[1][0], "\"type\":\"too_long\"")
          and _has(na4[1][0], "at most 2 items after validation, not 3"),
          "array length short-circuits element validation")
    var r10 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"tags":[],"meta":{"city":"ab"}}'), '{"name":"x","price":1,"tags":[],"meta":{"city":"ab"}}')
    check(r10[0] and r10[2]["quantity"] == "10" and r10[2]["mode"] == "fast" and r10[2]["meta_zip"] == "0", "defaults applied (quantity/mode/meta_zip)")
    var r11 = validate_body_schema(h, "POST", parse_body_json("{not json"), "{not json")
    check(not r11[0] and _has(r11[1][0], "json_invalid"), "json_invalid")
    check(validate_body_schema(h, "GET", parse_body_json("x"), "x")[0], "GET skip")
    # 决策-57: pat 约束 — 注册期解析 + 类型 fail-fast (FFI-free; 正则匹配行为走 e2e 真服务器).
    _ = _check_body_spec("code:str|pat=^[a-z0-9]+$")  # str 标量 + pat -> 注册通过
    check(get_field(parse_body_schema("code:str|pat=^[a-z0-9]+$"), 0).constraints == "pat=^[a-z0-9]+$", "pat parsed into constraints")
    var bad_pat = False
    try:
        _ = _check_body_spec("n:int|pat=^x$")
    except:
        bad_pat = True
    check(bad_pat, "pat on int -> registration fail")
    # Decision-58: elem-level constraints - registration fail-fast + elem len/ge (FFI-free; pat match via e2e).
    _ = _check_body_spec("t:str[]|items=0-3,len=1-3,pat=^[a-z]+$")  # str[] + len/pat -> elem-level, registration ok
    var bad_gt_arr = False
    try:
        _ = _check_body_spec("t:str[]|gt=0")
    except:
        bad_gt_arr = True
    check(bad_gt_arr, "gt on str[] -> registration fail")
    var bad_len_arr = False
    try:
        _ = _check_body_spec("t:int[]|len=1")
    except:
        bad_len_arr = True
    check(bad_len_arr, "len on int[] -> registration fail")
    var he = Handler(0, "validate_elems")
    he.set_data("_body_schema", "items:str[]|items=0-3,len=1-2;nums:int[]|items=0-3,ge=0")
    var q1 = validate_body_schema(he, "POST", parse_body_json('{"items":["a","bb"],"nums":[0,1]}'), '{"items":["a","bb"],"nums":[0,1]}')
    check(q1[0] and q1[2]["items"] == '["a","bb"]' and q1[2]["nums"] == "[0,1]", "elems valid + raw inject")
    var q2 = validate_body_schema(he, "POST", parse_body_json('{"items":["abc"],"nums":[0]}'), '{"items":["abc"],"nums":[0]}')
    check(not q2[0] and _has(q2[1][0], "string_too_long") and _has(q2[1][0], '["body","items",0]'), "elem len fail (idx loc)")
    var q3 = validate_body_schema(he, "POST", parse_body_json('{"items":["a"],"nums":[-1]}'), '{"items":["a"],"nums":[-1]}')
    check(not q3[0] and _has(q3[1][0], "greater_than_equal") and _has(q3[1][0], '["body","nums",0]'), "elem ge fail (idx loc)")
    # 决策-82 (ADR-0057): model 标量**跨 JSON 类型**强制 (pydantic lax model).
    var cx = Handler(0, "validate_cross")
    cx.set_data("_body_schema", "i:int;f:float;b:bool")
    var c1 = validate_body_schema(cx, "POST", parse_body_json('{"i":7.0,"f":1,"b":1}'), '{"i":7.0,"f":1,"b":1}')
    check(c1[0] and c1[2]["i"] == "7" and c1[2]["f"] == "1.0" and c1[2]["b"] == "true",
          "cross int<-float / float<-int / bool<-int")
    var c2 = validate_body_schema(cx, "POST", parse_body_json('{"i":1e2,"f":true,"b":0.0}'), '{"i":1e2,"f":true,"b":0.0}')
    check(c2[0] and c2[2]["i"] == "100" and c2[2]["f"] == "1.0" and c2[2]["b"] == "false",
          "cross exponent / float<-bool / bool<-0.0")
    var c3 = validate_body_schema(cx, "POST", parse_body_json('{"i":"7","f":"1.0","b":"1"}'), '{"i":"7","f":"1.0","b":"1"}')
    check(c3[0] and c3[2]["i"] == "7" and c3[2]["f"] == "1.0" and c3[2]["b"] == "true",
          "cross from JSON string")
    var c4 = validate_body_schema(cx, "POST", parse_body_json('{"i":7.5,"f":1,"b":1}'), '{"i":7.5,"f":1,"b":1}')
    check(not c4[0] and _has(c4[1][0], "int_from_float") and _has(c4[1][0], "fractional part"),
          "int_from_float (7.5)")
    var c5 = validate_body_schema(cx, "POST", parse_body_json('{"i":1,"f":1,"b":2}'), '{"i":1,"f":1,"b":2}')
    check(not c5[0] and _has(c5[1][0], "bool_parsing"), "bool_parsing (2)")
    var c6 = validate_body_schema(cx, "POST", parse_body_json('{"i":null,"f":null,"b":null}'), '{"i":null,"f":null,"b":null}')
    check(not c6[0] and len(c6[1]) == 3 and _has(c6[1][0], '\"type\":\"int_type\"')
          and _has(c6[1][1], '\"type\":\"float_type\"') and _has(c6[1][2], '\"type\":\"bool_type\"'),
          "null -> bare *_type")
    # 数组元素跨类型 + 规范化重建
    var ae = Handler(0, "validate_arr")
    ae.set_data("_body_schema", "is:int[];fs:float[];bs:bool[]")
    var a1 = validate_body_schema(ae, "POST", parse_body_json(
        '{"is":[7.0,1e2,true,"7"],"fs":[1,true,"1.0"],"bs":[1,0,1.0,-0.0,"1"]}'), 
        '{"is":[7.0,1e2,true,"7"],"fs":[1,true,"1.0"],"bs":[1,0,1.0,-0.0,"1"]}')
    check(a1[0] and a1[2]["is"] == "[7,100,1,7]" and a1[2]["fs"] == "[1.0,1.0,1.0]"
          and a1[2]["bs"] == "[true,false,true,false,true]",
          "array cross coercion + canonical rebuild")
    var a2 = validate_body_schema(ae, "POST", parse_body_json('{"is":[7.5],"fs":[],"bs":[]}'), '{"is":[7.5],"fs":[],"bs":[]}')
    check(not a2[0] and _has(a2[1][0], "int_from_float") and _has(a2[1][0], '["body","is",0]'),
          "array int_from_float + idx loc")
    var a3 = validate_body_schema(ae, "POST", parse_body_json('{"is":[null],"fs":[],"bs":[]}'), '{"is":[null],"fs":[],"bs":[]}')
    check(not a3[0] and _has(a3[1][0], '\"type\":\"int_type\"'), "array null -> int_type")
    # 决策-83 (ADR-0058): body 422 detail 逐字节对齐 (ctx/msg/multiple_of/字符计数/首违).
    var mo = Handler(0, "mo")
    mo.set_data("_body_schema", "n:int|mo=3;f:float|mo=0.5")
    check(validate_body_schema(mo, "POST", parse_body_json('{"n":9,"f":1.5}'), '{"n":9,"f":1.5}')[0], "multiple_of pass")
    var m2 = validate_body_schema(mo, "POST", parse_body_json('{"n":10,"f":1.5}'), '{"n":10,"f":1.5}')
    check(not m2[0] and _has(m2[1][0], '"type":"multiple_of"')
          and _has(m2[1][0], '"ctx":{"multiple_of":3}') and _has(m2[1][0], "Input should be a multiple of 3"),
          "multiple_of ctx+msg")
    var g = Handler(0, "g")
    g.set_data("_body_schema", "n:int|ge=10")
    var g1 = validate_body_schema(g, "POST", parse_body_json('{"n":5}'), '{"n":5}')
    check(not g1[0] and _has(g1[1][0], '"ctx":{"ge":10}') and _has(g1[1][0], '"input":5'), "ge ctx + input raw")
    var fo = Handler(0, "fo")
    fo.set_data("_body_schema", "n:int|ge=10,mo=3")
    var fo1 = validate_body_schema(fo, "POST", parse_body_json('{"n":5}'), '{"n":5}')
    check(not fo1[0] and len(fo1[1]) == 1 and _has(fo1[1][0], '"type":"multiple_of"'), "first-only mo>ge")
    var cl = Handler(0, "cl")
    cl.set_data("_body_schema", "s:str|len=3-5")
    var cl1 = validate_body_schema(cl, "POST", parse_body_json('{"s":"éé"}'), '{"s":"éé"}')
    check(not cl1[0] and _has(cl1[1][0], "at least 3 characters")
          and _has(cl1[1][0], '"ctx":{"min_length":3}'), "char-based len + ctx")
    var ar = Handler(0, "ar")
    ar.set_data("_body_schema", "xs:int[]|items=1-2")
    var ar1 = validate_body_schema(ar, "POST", parse_body_json('{"xs":[]}'), '{"xs":[]}')
    check(not ar1[0] and _has(ar1[1][0], "at least 1 item after validation, not 0")
          and _has(ar1[1][0], '"ctx":{"field_type":"List","min_length":1,"actual_length":0}'),
          "too_short singular + ctx")
    var ar2 = validate_body_schema(ar, "POST", parse_body_json('{"xs":[1,2,3]}'), '{"xs":[1,2,3]}')
    check(not ar2[0] and _has(ar2[1][0], "at most 2 items after validation, not 3"), "too_long plural")
    var em = Handler(0, "em")
    em.set_data("_body_schema", "xs:int[]|mo=3")
    var em1 = validate_body_schema(em, "POST", parse_body_json('{"xs":[3,4]}'), '{"xs":[3,4]}')
    check(not em1[0] and _has(em1[1][0], '"loc":["body","xs",1]')
          and _has(em1[1][0], '"type":"multiple_of"'), "elem multiple_of idx")
    var en = Handler(0, "en")
    en.set_data("_body_schema", "mode:str[fast,slow]")
    var en1 = validate_body_schema(en, "POST", parse_body_json('{"mode":"turbo"}'), '{"mode":"turbo"}')
    check(not en1[0] and _has(en1[1][0], "\"ctx\":{\"expected\":\"'fast' or 'slow'\"}"), "enum ctx.expected")
    # 决策-83: input 片段按 JSON 类型渲染 (JSON 字符串值恒带引号, 不按字面猜测).
    var ip = Handler(0, "ip")
    ip.set_data("_body_schema", "s:str|len=3-5;n:int")
    var ip1 = validate_body_schema(ip, "POST", parse_body_json('{"s":"12","n":1}'), '{"s":"12","n":1}')
    check(not ip1[0] and _has(ip1[1][0], '"input":"12"'), "string field numeric-look input quoted")
    var ip2 = validate_body_schema(ip, "POST", parse_body_json('{"s":"abcd","n":"1e1"}'), '{"s":"abcd","n":"1e1"}')
    check(not ip2[0] and _has(ip2[1][0], '"type":"int_parsing","input":"1e1"'), "int_parsing input quoted")
    # 决策-83 附带: parse_float_lax 负号修复 (原实现 range(i,n) 跳过符号位 -> 丢负号).
    check(_coerce_body_scalar("float", "string", "-1.5")[1] == "-1.5", "negative float coercion keeps sign")
    check(_coerce_body_scalar("float", "string", "-0.5")[1] == "-0.5", "negative float -0.5 preserved")
    # 决策-85 (ADR-0060): Content-Type 分派 + body 顶层值语义 (上游 strict_content_type 默认).
    var ct = Handler(0, "ct_dispatch")
    ct.set_data("_body_schema", "x:float")
    # 非 JSON CT -> 原始字符串 -> model_attributes_type (loc ["body"], input 带引号).
    var ct1 = validate_body_schema(ct, "POST", parse_body_json('{"x":1}'), '{"x":1}',
                                   "text/plain")
    check(not ct1[0] and _has(ct1[1][0], '"type":"model_attributes_type"')
          and _has(ct1[1][0], '\"loc\":[\"body\"]')
          and _has(ct1[1][0], '"input":"{\\"x\\":1}"'), "non-JSON CT -> model_attributes_type")
    var ct2 = validate_body_schema(ct, "POST", parse_body_json('{"x":1}'), '{"x":1}',
                                   "application/x-www-form-urlencoded")
    check(not ct2[0] and _has(ct2[1][0], '"type":"model_attributes_type"'),
          "form CT -> model_attributes_type (JSON body)")
    var ct3 = validate_body_schema(ct, "POST", parse_body_json('{"x":1}'), '{"x":1}',
                                   "application/json; charset=utf-8")
    check(ct3[0] and ct3[2]["x"] == "1.0", "JSON CT with charset parses")
    var ct4 = validate_body_schema(ct, "POST", parse_body_json('{"x":1}'), '{"x":1}',
                                   "application/vnd.api+json")
    check(ct4[0] and ct4[2]["x"] == "1.0", "application/*+json parses")
    # 无 body -> missing ["body"] input null.
    var ct5 = validate_body_schema(ct, "POST", ParsedParams(), "")
    check(not ct5[0] and _has(ct5[1][0], '"type":"missing"')
          and _has(ct5[1][0], '["body"]') and _has(ct5[1][0], '"input":null'),
          "empty body -> missing")
    # JSON null -> missing ["body"].
    var ct6 = validate_body_schema(ct, "POST", parse_body_json("null"), "null")
    check(not ct6[0] and _has(ct6[1][0], '"type":"missing"'), "null -> missing")
    # JSON 非 object -> model_attributes_type (input = 原值).
    var ct7 = validate_body_schema(ct, "POST", parse_body_json("[1,2]"), "[1,2]")
    check(not ct7[0] and _has(ct7[1][0], '"type":"model_attributes_type"')
          and _has(ct7[1][0], '"input":[1,2]'), "array -> model_attributes_type")
    var ct8 = validate_body_schema(ct, "POST", parse_body_json('"hi"'), '"hi"')
    check(not ct8[0] and _has(ct8[1][0], '"type":"model_attributes_type"')
          and _has(ct8[1][0], '"input":"hi"'), "string -> model_attributes_type")
    # json_invalid: loc ["body", pos] + ctx.error + input {} (合法 JSON 输出).
    var ct9 = validate_body_schema(ct, "POST", parse_body_json("{bad"), "{bad")
    check(not ct9[0] and _has(ct9[1][0], '"type":"json_invalid"')
          and _has(ct9[1][0], '["body",1]')
          and _has(ct9[1][0], '"input":{}')
          and _has(ct9[1][0], '"ctx":{"error":"Expecting property name enclosed in double quotes"}'),
          "json_invalid loc/ctx/input")
    # 非有限 number 常量 (CPython allow_nan): 顶层非 object; input 转义为合法 JSON 字符串
    # (上游渲染 500 — ADR-0060 §5 inf/nan 既有偏差, 此处仅保 detail 合法).
    var ct11 = validate_body_schema(ct, "POST", parse_body_json("NaN"), "NaN")
    check(not ct11[0] and _has(ct11[1][0], '"type":"model_attributes_type"')
          and _has(ct11[1][0], '"input":"NaN"'), "NaN top-level -> quoted input (valid JSON)")
    var ct10 = validate_body_schema(ct, "POST", parse_body_json('{"x":1}trailing'),
                                    '{"x":1}trailing')
    check(not ct10[0] and _has(ct10[1][0], '["body",7]')
          and _has(ct10[1][0], '"error":"Extra data"'), "json_invalid Extra data pos")
    # 决策-86 (ADR-0061): Body(embed=True) — 单 body 模型包裹在 <embed_key> 下.
    var mbd = Handler(0, "embed")
    mbd.set_data("_body_schema", "name:str;price:float")
    mbd.set_data("_body_embed", "item")
    var mbd1 = validate_body_schema(mbd, "POST",
                                   parse_body_json('{"item":{"name":"a","price":1.5}}'),
                                   '{"item":{"name":"a","price":1.5}}')
    check(mbd1[0] and mbd1[2]["name"] == "a" and mbd1[2]["price"] == "1.5",
          "embed ok: inner obj -> fields injected")
    var mbd2 = validate_body_schema(mbd, "POST",
                                   parse_body_json('{"name":"a","price":1.5}'),
                                   '{"name":"a","price":1.5}')
    check(not mbd2[0] and _has(mbd2[1][0], '"type":"missing"')
          and _has(mbd2[1][0], '["body","item"]') and _has(mbd2[1][0], '"input":null'),
          "embed key absent -> missing [body,item] input null")
    var mbd3 = validate_body_schema(mbd, "POST", parse_body_json('{"item":null}'), '{"item":null}')
    check(not mbd3[0] and _has(mbd3[1][0], '"type":"missing"')
          and _has(mbd3[1][0], '["body","item"]'), "embed item null -> missing")
    var mbd4 = validate_body_schema(mbd, "POST", parse_body_json('5'), '5')
    check(not mbd4[0] and _has(mbd4[1][0], '"type":"missing"')
          and _has(mbd4[1][0], '["body","item"]'), "embed top-level number -> missing")
    var mbd5 = validate_body_schema(mbd, "POST", parse_body_json('[1]'), '[1]')
    check(not mbd5[0] and _has(mbd5[1][0], '"type":"missing"'), "embed top-level array -> missing")
    var mbd6 = validate_body_schema(mbd, "POST", parse_body_json('null'), 'null')
    check(not mbd6[0] and _has(mbd6[1][0], '"type":"missing"'), "embed top-level null -> missing")
    var mbd7 = validate_body_schema(mbd, "POST", parse_body_json('{"item":"str"}'), '{"item":"str"}')
    check(not mbd7[0] and _has(mbd7[1][0], '"type":"model_attributes_type"')
          and _has(mbd7[1][0], '["body","item"]') and _has(mbd7[1][0], '"input":"str"'),
          "embed item string -> model_attributes_type input \"str\"")
    var mbd8 = validate_body_schema(mbd, "POST", parse_body_json('{"item":7}'), '{"item":7}')
    check(not mbd8[0] and _has(mbd8[1][0], '"type":"model_attributes_type"')
          and _has(mbd8[1][0], '"input":7'), "embed item number -> model_attributes_type input 7")
    # 字符串字面 "null" 不等于 JSON null (parse_body_json unescape -> type "string").
    var mbdn = validate_body_schema(mbd, "POST", parse_body_json('{"item":"null"}'), '{"item":"null"}')
    check(not mbdn[0] and _has(mbdn[1][0], '"type":"model_attributes_type"')
          and _has(mbdn[1][0], '"input":"null"'), "embed item string \"null\" -> model_attributes_type")
    var mbd9 = validate_body_schema(mbd, "POST", parse_body_json('{"item":{}}'), '{"item":{}}')
    check(not mbd9[0] and len(mbd9[1]) == 2
          and _has(mbd9[1][0], '["body","item","name"]')
          and _has(mbd9[1][1], '["body","item","price"]') and _has(mbd9[1][0], '"input":{}'),
          "embed item empty obj -> nested missing locs")
    var mbd10 = validate_body_schema(mbd, "POST", parse_body_json('{"item":{"name":"a"}}'),
                                    '{"item":{"name":"a"}}')
    check(not mbd10[0] and _has(mbd10[1][0], '["body","item","price"]')
          and _has(mbd10[1][0], '"input":{"name":"a"}'),
          "embed inner missing -> loc/input = inner object")
    var mbd11 = validate_body_schema(mbd, "POST", parse_body_json('{bad'), '{bad')
    check(not mbd11[0] and _has(mbd11[1][0], '"type":"json_invalid"')
          and _has(mbd11[1][0], '["body",1]'), "embed invalid JSON -> json_invalid pos")
    var mbd12 = validate_body_schema(mbd, "POST", parse_body_json('{"item":{"name":"a","price":1.5}}'),
                                    '{"item":{"name":"a","price":1.5}}', "text/plain")
    check(not mbd12[0] and _has(mbd12[1][0], '"type":"missing"')
          and _has(mbd12[1][0], '["body","item"]'),
          "embed non-JSON CT -> missing [body,item] (raw string)")
    var mbd13 = validate_body_schema(mbd, "POST", ParsedParams(), "")
    check(not mbd13[0] and _has(mbd13[1][0], '"type":"missing"')
          and _has(mbd13[1][0], '["body","item"]'), "embed no body -> missing [body,item]")
    # 决策-87 (ADR-0062): 正确舍入 float 解析/格式化 (libc atof + CPython repr 等价).
    check(fmt_f64_repr(1.0) == "1.0", "repr 1.0")
    check(fmt_f64_repr(1e16) == "1e+16", "repr 1e16 -> scientific")
    check(fmt_f64_repr(1e15) == "1000000000000000.0", "repr 1e15 -> fixed + .0")
    check(fmt_f64_repr(1e-4) == "0.0001", "repr 1e-4 fixed")
    check(fmt_f64_repr(1e-5) == "1e-05", "repr 1e-5 scientific")
    check(fmt_f64_repr(-0.0) == "-0.0", "repr -0.0")
    check(atof_f64("12345678901234567890.0") == atof_f64("1.2345678901234567e+19"),
          "atof long-digit decimal (correctly rounded)")
    # Mojo String(Float64) 非往返 BUG: repr 必须是最短往返串
    check(fmt_f64_repr(7.531168259201221e+16) == "7.531168259201221e+16",
          "repr round-trips (String(Float64) bug fix)")
    var lf = Handler(0, "longfloat")
    lf.set_data("_body_schema", "f:float")
    var lf1 = validate_body_schema(lf, "POST",
                                   parse_body_json('{"f":12345678901234567890.0}'),
                                   '{"f":12345678901234567890.0}')
    check(lf1[0] and lf1[2]["f"] == "1.2345678901234567e+19",
          "body long-digit float parses (was float_parsing)")
    var lf2 = validate_body_schema(lf, "POST",
                                   parse_body_json('{"f":123456789012345678901234567890.0}'),
                                   '{"f":123456789012345678901234567890.0}')
    check(lf2[0] and lf2[2]["f"] == "1.2345678901234568e+29",
          "body 30-digit float parses + repr")
    # 决策-87: 语法合法性判定回归守护 (atof 对垃圾串返回 0.0 → 不能靠 atof)。
    check(not is_dec_f64_syntax("zz") and not is_dec_f64_syntax("1.2.3")
          and not is_dec_f64_syntax("5abc") and not is_dec_f64_syntax("")
          and not is_dec_f64_syntax("1e"), "syntax reject garbage")
    check(is_dec_f64_syntax("5") and is_dec_f64_syntax("+5.0")
          and is_dec_f64_syntax(".5") and is_dec_f64_syntax("5.")
          and is_dec_f64_syntax("1e-5") and is_dec_f64_syntax("inf")
          and is_dec_f64_syntax("1.23456789012345678901e29"), "syntax accept")
    check(not _is_num_lit("zz") and not _is_num_lit("1.2.3")
          and _is_num_lit("5") and _is_num_lit("5.5"), "_is_num_lit syntax gate")
    print("Mojo body_schema (决策-38) test completed!")
