# src/fastapi_mojo/body_validate_test.mojo
#
# Decision-38/57/58/61 executable body-validation tests (same-dir split keeps
# both production and test modules below the 500-line God-file threshold).

from body_schema import parse_body_schema, get_field, field_count
from body_validate import validate_body_schema, _check_body_spec
from handler import Handler
from params_json import parse_body_json

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
        nah, "POST", parse_body_json('{"models":[{"id":7,"tag":"ab"},{"id":9,"tag":"xyz"}]}'), "")
    check(na1[0] and na1[2]["models_0_id"] == "7" and na1[2]["models_1_tag"] == "xyz",
          "nested array valid + flattened values")
    var na2 = validate_body_schema(
        nah, "POST", parse_body_json('{"models":[{"id":0,"tag":"ab"},{"id":9,"tag":"x"}]}'), "")
    check(not na2[0] and len(na2[1]) == 2 and _has(na2[1][0], "[\"body\",\"models\",0,\"id\"]")
          and _has(na2[1][0], "greater_than_equal"), "nested array element constraints")
    var na3 = validate_body_schema(
        nah, "POST", parse_body_json('{"models":[{"tag":"ab"},{"id":9,"tag":"xyz"},'
                                     + '{"id":10,"tag":"abcd"}]}'), "")
    check(not na3[0] and _has(na3[1][0], "[\"body\",\"models\",0,\"id\"]")
          and _has(na3[1][0], "\"input\":{\"tag\":\"ab\"}"), "nested array missing input")
    var r10 = validate_body_schema(h, "POST", parse_body_json('{"name":"x","price":1,"tags":[],"meta":{"city":"ab"}}'), "")
    check(r10[0] and r10[2]["quantity"] == "10" and r10[2]["mode"] == "fast" and r10[2]["meta_zip"] == "0", "defaults applied (quantity/mode/meta_zip)")
    var r11 = validate_body_schema(h, "POST", parse_body_json("{not json"), "")
    check(not r11[0] and _has(r11[1][0], "json_invalid"), "json_invalid")
    check(validate_body_schema(h, "GET", parse_body_json("x"), "")[0], "GET skip")
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
    var q1 = validate_body_schema(he, "POST", parse_body_json('{"items":["a","bb"],"nums":[0,1]}'), "")
    check(q1[0] and q1[2]["items"] == '["a","bb"]' and q1[2]["nums"] == "[0,1]", "elems valid + raw inject")
    var q2 = validate_body_schema(he, "POST", parse_body_json('{"items":["abc"],"nums":[0]}'), "")
    check(not q2[0] and _has(q2[1][0], "string_too_long") and _has(q2[1][0], '["body","items",0]'), "elem len fail (idx loc)")
    var q3 = validate_body_schema(he, "POST", parse_body_json('{"items":["a"],"nums":[-1]}'), "")
    check(not q3[0] and _has(q3[1][0], "greater_than_equal") and _has(q3[1][0], '["body","nums",0]'), "elem ge fail (idx loc)")
    print("Mojo body_schema (决策-38) test completed!")
