# src/fastapi_mojo/body_validate.mojo
#
# 决策-38 (续): body 校验运行期 — 类型检查/约束/错误构造/FastAPI 422 detail (Goal-0003 P1).
# spec 解析在 body_schema.mojo; 本文件 = 校验层 + 自测 (拆分边界: 校验不反向 import spec 内部).
# 决策-57: + pat=REGEX 约束 (bridge/regex.rs FFI regex_match, 复用 param_constraints 同款引擎).
# 决策-83 (ADR-0058): 约束应用层 (ctx/首违/mo/codepoint len/列表短路) 拆到
# body_constraints.mojo (God package 阈值); 本文件保留类型检查 + input + 校验循环.

from body_schema import (FieldSpec, ParsedSchema, parse_body_schema, get_field, field_count,
                         err_obj, err_obj_ctx, _in_enum_csv, _enum_or_msg, _split_top, _trim,
                         _find_eq, _is_int_lit, _is_num_lit)
from body_coerce import _coerce_body_scalar, _elem_type_err, _elem_json_type
from body_json import validate_body_json, content_type_is_json
from body_constraints import (_json_input_frag, _json_input_frag_typed,
                              _apply_constraints, _apply_elem_constraints)
from json_canon import canon_json, json_string_literal
from handler import Handler
from router import Router
from params_query import ParsedParams
from params_json import parse_body_json
from json import json_escape
from scalar_types import is_scalar_type, parse_scalar, scalar_error_object


def _type_err(fs: FieldSpec) -> Tuple[String, String]:
    """类型错消息 (msg, type) — 按期望类型."""
    if fs.is_array or fs.type_name == "arr":
        return ("Input should be an array", "list_type")
    if fs.type_name == "str":
        return ("Input should be a valid string", "string_type")
    if fs.type_name == "int":
        return ("Input should be a valid integer", "int_type")
    if fs.type_name == "float":
        return ("Input should be a valid number", "float_type")
    if fs.type_name == "bool":
        return ("Input should be a valid boolean", "bool_type")
    if is_scalar_type(fs.type_name):
        return ("Input should be a valid string", "string_type")
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
        # 决策-83: 字节安全扫描 (Mojo 1.0.0 String[byte=i] 在码点内部下标 assert;
        # 多字节字符串元素 (如 ["é"]) 曾致 server 崩溃).
        var o = Int(raw.as_bytes()[i])
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
    # 决策-88 (ADR-0063): CPython/Starlette 反序列化-重序列化 (去空白等)。
    return canon_json(raw_body)


def _strip_quotes(v: String) -> String:
    """Strip outer JSON quotes of an elem raw: "\"abc\"" -> "abc" (unquoted if not quoted)."""
    var n = v.byte_length()
    if n >= 2 and ord(v[byte=0]) == 34 and Int(v.as_bytes()[n - 1]) == 34:
        return String(v[byte=1:n - 1])
    return v


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
            # 决策-81/82: pydantic lax — JSON string/float/bool 也可 ("007"->7 / 7.0->7 / true->1)
            ok_t = t == "int" or t == "float" or t == "bool" or t == "string"
        elif fs.type_name == "float":
            ok_t = t == "int" or t == "float" or t == "bool" or t == "string"
        elif fs.type_name == "bool":
            ok_t = t == "bool" or t == "int" or t == "float" or t == "string"
        elif fs.type_name == "obj":
            ok_t = t == "object"
        elif fs.type_name == "arr":
            ok_t = t == "array"
        elif is_scalar_type(fs.type_name):
            ok_t = t == "string"
        if not ok_t:
            var te = _type_err(fs)
            errs.append(err_obj(floc + "]", te[0], te[1], _json_input_frag_typed(t, raw)))
            continue
        if fs.is_enum and not _in_enum_csv(raw, fs.enum_values):
            # 决策-83: enum 错误带 ctx.expected (= msg 去掉 "Input should be " 前缀;
            # 上游 pydantic 键序 loc,msg,type,input,ctx).
            var emsg = _enum_or_msg(fs.enum_values)
            var eexp = String(emsg[byte=16:emsg.byte_length()])
            errs.append(err_obj_ctx(floc + "]", emsg, "enum", _json_input_frag_typed(t, raw),
                                    "{\"expected\":\"" + json_escape(eexp) + "\"}"))
            continue
        if is_scalar_type(fs.type_name) and not fs.is_array:
            var sv = _strip_quotes(raw)
            var sp = parse_scalar(fs.type_name, sv)
            if not sp.ok:
                errs.append(scalar_error_object(floc + "]", sv, sp))
                continue
            out[key] = raw
            continue
        if (fs.type_name == "int" or fs.type_name == "float" or fs.type_name == "bool") and not fs.is_array:
            # 决策-81/82 (ADR-0056/0057): 标量跨类型规范化 (pydantic lax model) —
            # JSON string "007"->7 / JSON float 7.0->7 (非整值 -> int_from_float) /
            # JSON bool true->1 / 1.50->1.5 / 1->true; 失败 -> 上游 parse 错误.
            var cr = _coerce_body_scalar(fs.type_name, t, raw)
            if not cr[0]:
                errs.append(err_obj(floc + "]", cr[2], cr[3], _json_input_frag_typed(t, raw)))
                continue
            out[key] = cr[1]
            _apply_constraints(fs, raw, cr[1], -1,
                               _json_input_frag_typed(t, raw), floc + "]", errs)
            continue
        out[key] = raw
        if fs.is_array:
            var elems = _split_json_array(raw)
            # 决策-83: 数组长度约束先于元素校验 (上游 pydantic: 长度错短路元素校验).
            var nerr0 = len(errs)
            _apply_constraints(fs, raw, raw, len(elems), _json_input_frag(raw),
                               floc + "]", errs)
            if len(errs) > nerr0:
                continue
            for ei in range(len(elems)):
                var eloc = floc + "," + String(ei) + "]"
                if is_scalar_type(fs.elem):
                    var sv2 = _strip_quotes(elems[ei])
                    var sp2 = parse_scalar(fs.elem, sv2)
                    if not sp2.ok:
                        errs.append(scalar_error_object(eloc, sv2, sp2))
                    continue
                if fs.elem == "int" or fs.elem == "float" or fs.elem == "bool":
                    # 决策-82 (ADR-0057): int/float/bool 数组元素跨类型强制
                    # (JSON float/bool/string; null/{}/[] -> 裸 *_type 错).
                    var et = _elem_json_type(elems[ei])
                    if et == "null" or et == "object" or et == "array" or et == "unknown":
                        var ete = _elem_type_err(fs.elem)
                        errs.append(err_obj(eloc, ete[0], ete[1], _json_input_frag(elems[ei])))
                        continue
                    var etext = elems[ei]
                    if et == "string":
                        etext = _strip_quotes(elems[ei])
                    var ecr = _coerce_body_scalar(fs.elem, et, etext)
                    if not ecr[0]:
                        errs.append(err_obj(eloc, ecr[2], ecr[3], _json_input_frag(elems[ei])))
                    else:
                        _apply_elem_constraints(fs.elem, elems[ei], ecr[1], fs, eloc, errs)
                    continue
                var ec = _elem_check(fs.elem, elems[ei])
                if not ec[0]:
                    errs.append(err_obj(eloc, ec[1], ec[2], _json_input_frag(elems[ei])))
                elif fs.elem == "obj" and fs.nested_spec != "":
                    # Decision-61: obj[]{subspec} validates every array element
                    # against the same recursive body schema. Missing-field input
                    # is the element object (not the entire request body).
                    var item = parse_body_json(elems[ei])
                    if item.has_error:
                        errs.append(err_obj(eloc, "Input should be an object", "model_type",
                                            _json_input_frag(elems[ei])))
                    else:
                        var item_schema = parse_body_schema(fs.nested_spec)
                        _validate_fields(item_schema, item,
                                         prefix + fs.name + "_" + String(ei) + "_",
                                         floc + "," + String(ei), elems[ei], out, errs)
                else:
                    _apply_elem_constraints(fs.elem, elems[ei], _strip_quotes(elems[ei]), fs, eloc, errs)
            if fs.elem == "int" or fs.elem == "float" or fs.elem == "bool":
                # 决策-81/82: int/float/bool 数组元素规范化 (JSON 文本重建; 跨类型).
                var rebuilt = "["
                for er in range(len(elems)):
                    var ce = elems[er]
                    var etr = _elem_json_type(ce)
                    var cer = ce
                    if etr == "string":
                        cer = _strip_quotes(ce)
                    var epr = _coerce_body_scalar(fs.elem, etr, cer)
                    if epr[0]:
                        ce = epr[1]
                    if er > 0:
                        rebuilt += ","
                    rebuilt += ce
                out[key] = rebuilt + "]"
        elif fs.type_name == "obj" and fs.nested_spec != "":
            var sub = parse_body_json(raw)
            if sub.has_error:
                errs.append(err_obj(floc + "]", "Input should be an object", "model_type", _json_input_frag(raw)))
            else:
                var subs = parse_body_schema(fs.nested_spec)
                _validate_fields(subs, sub, prefix + fs.name + "_", floc, raw_body, out, errs)
        else:
            _apply_constraints(fs, raw, raw, -1, _json_input_frag_typed(t, raw),
                               floc + "]", errs)


def _validate_body_embed(handler: Handler, embed_key: String, body_params: ParsedParams,
                         body_str: String, content_type: String,
                         mut out: Dict[String, String], mut errs: List[String]) raises -> Bool:
    """决策-86 (ADR-0061): Body(embed=True) 语义 — 单 body 模型包裹在 <embed_key> 下.

    上游 (fastapi 0.141.1) `Body(embed=True)` 把单一 body 参数包成单字段模型
    `{<param>: Model}`; 运行期 `received_body.get(<param>)` 语义:
    顶层非 dict (无 body / 非 JSON CT 的原始字符串 / JSON null / 数组 / 数字 / bool)
    -> `.get` 不存在或键缺失 -> `missing ["body", <param>]` (input null);
    键值为 dict -> 内层模型校验 (loc 前缀 `["body", <param>]`);
    键值非 dict (str / number / bool / array) -> `model_attributes_type ["body", <param>]`
    (input = 内层原值). 非法 JSON 仍 `json_invalid` (`["body", pos]` + ctx, 与未嵌入同).
    校验值注入键与非嵌入一致 (`body_<field>`, 本层 prefix 空)."""
    var key_json = "\"" + json_escape(embed_key) + "\""
    var miss_loc = "[\"body\"," + key_json + "]"
    var loc_base = "[\"body\"," + key_json
    var miss = err_obj(miss_loc, "Field required", "missing", "null")
    var has_body = body_str.byte_length() > 0 or body_params.has_error \
        or body_params.param_count > 0
    if not has_body:
        errs.append(miss)
        return False
    if not content_type_is_json(content_type):
        # 非 JSON CT: body = 原始字符串 -> 原始串无 `.get` -> missing (上游实测).
        errs.append(miss)
        return False
    var scan = validate_body_json(body_str)
    if not scan.ok:
        errs.append(err_obj_ctx("[\"body\"," + String(scan.err_pos) + "]",
                                "JSON decode error", "json_invalid", "{}",
                                "{\"error\":\"" + json_escape(scan.err_msg) + "\"}"))
        return False
    if scan.top_kind != "object":
        # JSON null / 数组 / 字符串 / 数字 / bool 顶层 -> `.get` 不存在 -> missing.
        errs.append(miss)
        return False
    if embed_key not in body_params.values:
        errs.append(miss)
        return False
    var raw = body_params.values[embed_key]
    var t = "string"
    if embed_key in body_params.types:
        t = body_params.types[embed_key]
    if t == "null":
        # JSON null (type 标记), 非字符串字面 "null" -> `.get` 得 None -> missing.
        errs.append(miss)
        return False
    if t != "object":
        errs.append(err_obj(miss_loc,
                            "Input should be a valid dictionary or object to extract fields from",
                            "model_attributes_type", _json_input_frag_typed(t, raw)))
        return False
    var inner = parse_body_json(raw)
    if inner.has_error:
        errs.append(err_obj(miss_loc,
                            "Input should be a valid dictionary or object to extract fields from",
                            "model_attributes_type", _json_input_frag(raw)))
        return False
    var fields = parse_body_schema(handler.data["_body_schema"])
    _validate_fields(fields, inner, "", loc_base, raw, out, errs)
    return len(errs) == 0


def validate_body_schema(handler: Handler, method: String,
                         body_params: ParsedParams, body_str: String,
                         content_type: String = "application/json") raises -> Tuple[Bool, List[String], Dict[String, String]]:
    """`validate_body_schema` (决策-38, 决策-85): 按 _body_schema 校验请求 body.

    返回 (ok, errors, values): ok=False -> errors = FastAPI detail 对象 (loc/msg/type);
    ok=True -> values = 字段 -> 校验值 (含默认值), dispatch 注入 body_<name>.
    仅 POST/PUT/PATCH 且声明 _body_schema 时生效; 其余直接 ok.

    决策-85 (ADR-0060): 顶层值语义 + CT 分派对齐上游 `strict_content_type=True`
    默认 —— 仅 JSON CT (`content_type_is_json`) 才解析 JSON body, 否则 body 视为
    原始字符串 -> `model_attributes_type`; 无 body -> `missing`; JSON `null` ->
    `missing`; JSON 非 object -> `model_attributes_type`; 非法 JSON ->
    `json_invalid` (loc `["body", pos]` + `ctx.error`, input `{}`).

    决策-86 (ADR-0061): `_body_embed` 声明 -> `Body(embed=True)` 语义 (单模型包裹在
    `<embed_key>` 下; 内层字段 loc `["body", <embed_key>, ...]`)."""
    var ok_vals = Dict[String, String]()
    if "_body_schema" not in handler.data:
        return (True, List[String](), ok_vals^)
    if method != "POST" and method != "PUT" and method != "PATCH":
        return (True, List[String](), ok_vals^)
    if "_body_embed" in handler.data and handler.data["_body_embed"] != "":
        var embed_errs = List[String]()
        var embed_ok = _validate_body_embed(handler, handler.data["_body_embed"], body_params,
                                            body_str, content_type, ok_vals, embed_errs)
        return (embed_ok, embed_errs^, ok_vals^)
    var errs = List[String]()
    # 无 wire body 判定: dispatch 传 body_str="" + 空 ParsedParams(); 单元测试可能只传
    # body_params (body_str="") -> 以 param_count/has_error 补偿识别"确实有 body".
    var has_body = body_str.byte_length() > 0 or body_params.has_error \
        or body_params.param_count > 0
    if not has_body:
        errs.append(err_obj("[\"body\"]", "Field required", "missing", "null"))
        return (False, errs^, ok_vals^)
    if not content_type_is_json(content_type):
        # 非 JSON CT: 上游 body = body_bytes (原始字符串) -> 模型无法提取字段.
        errs.append(err_obj("[\"body\"]",
                            "Input should be a valid dictionary or object to extract fields from",
                            "model_attributes_type",
                            json_string_literal(body_str)))
        return (False, errs^, ok_vals^)
    var scan = validate_body_json(body_str)
    if not scan.ok:
        errs.append(err_obj_ctx("[\"body\"," + String(scan.err_pos) + "]",
                                "JSON decode error", "json_invalid", "{}",
                                "{\"error\":\"" + json_escape(scan.err_msg) + "\"}"))
        return (False, errs^, ok_vals^)
    if scan.top_kind == "null":
        errs.append(err_obj("[\"body\"]", "Field required", "missing", "null"))
        return (False, errs^, ok_vals^)
    if scan.top_kind != "object":
        var raw = String(body_str[byte=scan.val_start:scan.val_end])
        # 保 detail 恒为合法 JSON: 非有限 number 常量 NaN/Infinity 非合法 JSON 字面量
        # -> 转义为字符串 (CPython allow_nan 解析成功; 上游渲染 500 = ADR-0060 §5 既有
        # inf/nan 偏差, 此处只保证本实现 detail 合法). 其余数组/对象/数字/字符串原样.
        var inp = _json_input_frag(raw)
        if raw == "NaN" or raw == "Infinity" or raw == "-Infinity":
            inp = "\"" + raw + "\""
        errs.append(err_obj("[\"body\"]",
                            "Input should be a valid dictionary or object to extract fields from",
                            "model_attributes_type", inp))
        return (False, errs^, ok_vals^)
    if body_params.has_error:
        # 严格校验已通过 -> object; 解析器理论不应报错 (防御).
        errs.append(err_obj_ctx("[\"body\",0]", "JSON decode error", "json_invalid",
                                "{}", "{\"error\":\"invalid JSON\"}"))
        return (False, errs^, ok_vals^)
    var fields = parse_body_schema(handler.data["_body_schema"])
    _validate_fields(fields, body_params, "", "[\"body\"", body_str, ok_vals, errs)
    if len(errs) > 0:
        return (False, errs^, ok_vals^)
    return (True, List[String](), ok_vals^)


def check_body_schemas(router: Router) raises:
    """注册期 _body_schema 语法检查 (决策-38): 畸形 spec 立即 fail, 不带入请求路径.
    决策-57: pat=REGEX 仅 str 标量字段 (非 str / 数组 / enum -> fail-fast)."""
    for i in range(router.route_count()):
        var h = router.routes[i].handler.copy()
        if "_body_schema" in h.data and h.data["_body_schema"] != "":
            _check_body_spec(h.data["_body_schema"])


def _check_body_spec(spec: String) raises:
    """Recursive spec validation (decision-58 fail-fast): constraint key vs field type
    mismatch -> raise at registration. pat/len: str scalar or str[] (elem-level, no enum);
    gt/ge/lt/le/mo: int/float scalar or int[]/float[] (elem-level); items: arrays only."""
    var s = parse_body_schema(spec)
    for i in range(field_count(s)):
        var fs = get_field(s, i)
        for c in _split_top(fs.constraints, 44):
            var ct = _trim(c)
            if ct == "":
                continue
            var ck = _find_eq(ct)
            var key = String(ct[byte=0:ck])
            if key == "pat" or key == "len":
                if fs.is_enum or not ((fs.type_name == "str" and not fs.is_array) or (fs.is_array and fs.elem == "str")):
                    raise Error("body_schema: " + key + "= constraint requires a str field (field '" + fs.name + "')")
            elif key == "gt" or key == "ge" or key == "lt" or key == "le" or key == "mo":
                if not (fs.type_name == "int" or fs.type_name == "float" or (fs.is_array and (fs.elem == "int" or fs.elem == "float"))):
                    raise Error("body_schema: " + key + "= constraint requires an int/float field (field '" + fs.name + "')")
            elif key == "items":
                if not fs.is_array:
                    raise Error("body_schema: items= constraint requires an array field (field '" + fs.name + "')")
        if fs.type_name == "obj" and fs.nested_spec != "":
            _check_body_spec(fs.nested_spec)
