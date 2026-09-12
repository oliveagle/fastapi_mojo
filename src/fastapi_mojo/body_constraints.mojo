# src/fastapi_mojo/body_constraints.mojo
#
# 决策-83 (ADR-0058): body 422 detail 约束应用层 — 从 body_validate.mojo 拆出
# (保持 God package 阈值 < 500)。约束语义: 数值 mo/le/lt/ge/gt 首违 +
# str codepoint len/pat + 列表 items(too_short/too_long + 短路); ctx 构造对齐
# 上游 pydantic v2 (ctx 末位, 见 ADR-0029 §3.7)。

from body_schema import (FieldSpec, err_obj_ctx, fmt_num, _split_top, _trim,
                         _find_eq, _parse_f64, _parse_range, _is_int_lit, _is_num_lit)
from json import json_escape
from json_canon import canon_json, json_string_literal
from std.ffi import external_call, CStringSlice


def _body_rgx_match(pattern: String, s: String) -> Int:
    """决策-57 FFI: regex_match(pattern, s) -> 1=match / 0=no / -1=编译失败 (bridge/regex.rs)."""
    var p = pattern
    var t = s
    return external_call["regex_match", Int](p.as_c_string_slice(), t.as_c_string_slice())


def _json_input_frag(v: String) raises -> String:
    """值 (合法 JSON 值 span) -> detail `input` 片段.

    决策-88 (ADR-0063): 对合法 JSON 值走 `canon_json` (CPython/Starlette
    `json.dumps(ensure_ascii=False, separators=(",",":"))` 等价: 去空白 / 数字
    规范化 / 字符串解码重编码)。无法识别的裸 token (如坏元素 zz) -> 转义字符串
    (保 detail JSON 合法)。`canon_json` 解析失败时原样返回 (安全回退)。"""
    var n = v.byte_length()
    if n == 0:
        return "null"
    var c0 = ord(v[byte=0])
    if c0 == 34 or c0 == 123 or c0 == 91:
        return canon_json(v)
    if _is_num_lit(v) or _is_int_lit(v):
        return canon_json(v)
    if v == "true" or v == "false" or v == "null":
        return v
    return "\"" + json_escape(v) + "\""

def _json_input_frag_typed(json_type: String, v: String) raises -> String:
    """决策-83: input 片段按 JSON 类型渲染 — JSON string 值恒加引号.

    上游 pydantic input 保留原 JSON 类型: JSON 字符串 "123"/"1e1" 报错时
    input 是字符串 (带引号), 而非数字。原 `_json_input_frag` 仅按字面形状猜测,
    把 "123" 误渲染为裸 123 (parity bug, 实测上游 string_too_short input="1").

    决策-88: string 分支走 `json_string_literal` (CPython 转义: \b/\f 短转义)。"""
    if json_type == "string":
        return json_string_literal(v)
    return _json_input_frag(v)

def _item_word(n: Int) -> String:
    """决策-83: 上游列表长度消息复数 (min/max == 1 -> "item", 否则 "items")."""
    if n == 1:
        return "item"
    return "items"

def _parse_constraint_kv(cons: String) raises -> Dict[String, String]:
    """决策-83: 约束 CSV -> {key: 字面量} (空条目跳过; 重复 key 后者胜)."""
    var kv = Dict[String, String]()
    for c in _split_top(cons, 44):
        var ct = _trim(c)
        if ct == "":
            continue
        var ck = _find_eq(ct)
        kv[String(ct[byte=0:ck])] = String(ct[byte=ck + 1:ct.byte_length()])
    return kv^

def _num_constraint_err(kv: Dict[String, String], v: Float64, inp_json: String,
                        floc: String) raises -> String:
    """决策-83: 数值约束首违, 返回 error JSON 或 "".

    优先序 = 上游 pydantic 内建序 (实测 pydantic 2.13.x): multiple_of -> le -> lt ->
    ge -> gt (同字段仅报首个违规). ctx 键 = 上游拼写, 值 = 声明字面量原样."""
    if "mo" in kv:
        var cv = _parse_f64(kv["mo"])
        if cv[0] and cv[1] != 0.0:
            var q = v / cv[1]
            if q < 9.0e15 and q > -9.0e15:
                var rem = v - Float64(Int(q)) * cv[1]
                if rem < 0.0:
                    rem = -rem
                if rem > 1e-9:
                    return err_obj_ctx(floc, "Input should be a multiple of " + fmt_num(cv[1]),
                                       "multiple_of", inp_json,
                                       "{\"multiple_of\":" + kv["mo"] + "}")
    if "le" in kv:
        var cv = _parse_f64(kv["le"])
        if cv[0] and not (v <= cv[1]):
            return err_obj_ctx(floc, "Input should be less than or equal to " + fmt_num(cv[1]),
                               "less_than_equal", inp_json, "{\"le\":" + kv["le"] + "}")
    if "lt" in kv:
        var cv = _parse_f64(kv["lt"])
        if cv[0] and not (v < cv[1]):
            return err_obj_ctx(floc, "Input should be less than " + fmt_num(cv[1]),
                               "less_than", inp_json, "{\"lt\":" + kv["lt"] + "}")
    if "ge" in kv:
        var cv = _parse_f64(kv["ge"])
        if cv[0] and not (v >= cv[1]):
            return err_obj_ctx(floc, "Input should be greater than or equal to " + fmt_num(cv[1]),
                               "greater_than_equal", inp_json, "{\"ge\":" + kv["ge"] + "}")
    if "gt" in kv:
        var cv = _parse_f64(kv["gt"])
        if cv[0] and not (v > cv[1]):
            return err_obj_ctx(floc, "Input should be greater than " + fmt_num(cv[1]),
                               "greater_than", inp_json, "{\"gt\":" + kv["gt"] + "}")
    return ""

def _apply_constraints(fs: FieldSpec, inp: String, valtxt: String, elem_count: Int,
                       inp_json: String, floc: String, mut errs: List[String]) raises:
    """应用约束 (决策-83 重写): 数值标量 mo/le/lt/ge/gt、str 标量 len(min/max 字符
    计数)/pat、数组 items(min/max); **同字段仅报首个违规** (上游 pydantic).
    inp = 原始 JSON 文本 (input 片段); valtxt = 规范化文本 (数值比较/str 长度).
    elem_count = 数组元素数 (非数组 = -1)."""
    var cons = fs.constraints
    if cons == "":
        return
    var kv = _parse_constraint_kv(cons)
    if not fs.is_array and (fs.type_name == "int" or fs.type_name == "float"):
        var rv = _parse_f64(valtxt)
        if rv[0]:
            var ce = _num_constraint_err(kv, rv[1], inp_json, floc)
            if ce != "":
                errs.append(ce)
                return
    if not fs.is_array and fs.type_name == "str" and not fs.is_enum:
        if "len" in kv:
            var pr = _parse_range(kv["len"])
            if pr[0]:
                var rl = len(inp.codepoints())
                if pr[1] > 0 and rl < pr[1]:
                    errs.append(err_obj_ctx(floc, "String should have at least " + String(pr[1]) + " characters",
                                            "string_too_short", inp_json,
                                            "{\"min_length\":" + String(pr[1]) + "}"))
                    return
                if pr[2] > 0 and rl > pr[2]:
                    errs.append(err_obj_ctx(floc, "String should have at most " + String(pr[2]) + " characters",
                                            "string_too_long", inp_json,
                                            "{\"max_length\":" + String(pr[2]) + "}"))
                    return
        if "pat" in kv:
            var ret = _body_rgx_match(kv["pat"], inp)
            if ret == 0:
                errs.append(err_obj_ctx(floc, "String should match pattern '" + kv["pat"] + "'",
                                        "string_pattern_mismatch", inp_json,
                                        "{\"pattern\":\"" + json_escape(kv["pat"]) + "\"}"))
                return
    if fs.is_array and elem_count >= 0 and "items" in kv:
        var pr2 = _parse_range(kv["items"])
        if pr2[0]:
            if pr2[1] > 0 and elem_count < pr2[1]:
                errs.append(err_obj_ctx(floc, "List should have at least " + String(pr2[1]) + " "
                                        + _item_word(pr2[1]) + " after validation, not " + String(elem_count),
                                        "too_short", inp_json,
                                        "{\"field_type\":\"List\",\"min_length\":" + String(pr2[1])
                                        + ",\"actual_length\":" + String(elem_count) + "}"))
                return
            if pr2[2] > 0 and elem_count > pr2[2]:
                errs.append(err_obj_ctx(floc, "List should have at most " + String(pr2[2]) + " "
                                        + _item_word(pr2[2]) + " after validation, not " + String(elem_count),
                                        "too_long", inp_json,
                                        "{\"field_type\":\"List\",\"max_length\":" + String(pr2[2])
                                        + ",\"actual_length\":" + String(elem_count) + "}"))
                return

def _apply_elem_constraints(elem_t: String, inp: String, valtxt: String, fs: FieldSpec,
                            eloc: String, mut errs: List[String]) raises:
    """决策-58/83: 逐元素约束 (str: len/pat; int/float: mo/le/lt/ge/gt), 每元素首违.

    inp = 元素原始 JSON 文本 (input 片段); valtxt = 规范化文本 (str 已剥引号 /
    数值 canonical). 消息 + ctx 对齐上游 (ctx 见决策-83)."""
    var cons = fs.constraints
    if cons == "":
        return
    var kv = _parse_constraint_kv(cons)
    var inp_json = _json_input_frag(inp)
    if elem_t == "str":
        if "len" in kv:
            var pr = _parse_range(kv["len"])
            if pr[0]:
                var rl = len(valtxt.codepoints())
                if pr[1] > 0 and rl < pr[1]:
                    errs.append(err_obj_ctx(eloc, "String should have at least " + String(pr[1]) + " characters",
                                            "string_too_short", inp_json,
                                            "{\"min_length\":" + String(pr[1]) + "}"))
                    return
                if pr[2] > 0 and rl > pr[2]:
                    errs.append(err_obj_ctx(eloc, "String should have at most " + String(pr[2]) + " characters",
                                            "string_too_long", inp_json,
                                            "{\"max_length\":" + String(pr[2]) + "}"))
                    return
        if "pat" in kv:
            var ret = _body_rgx_match(kv["pat"], valtxt)
            if ret == 0:
                errs.append(err_obj_ctx(eloc, "String should match pattern '" + kv["pat"] + "'",
                                        "string_pattern_mismatch", inp_json,
                                        "{\"pattern\":\"" + json_escape(kv["pat"]) + "\"}"))
                return
        return
    if elem_t == "int" or elem_t == "float":
        var rv = _parse_f64(valtxt)
        if rv[0]:
            var ce = _num_constraint_err(kv, rv[1], inp_json, eloc)
            if ce != "":
                errs.append(ce)
