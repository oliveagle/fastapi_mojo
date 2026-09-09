# src/fastapi_mojo/form_params.mojo
#
# 决策-45 (ADR-0020, Goal-0003 P2 矩阵 #5): Form 参数精化 — 多值 List /
# alias / description + 422 detail parity (input 字段 / "Field required" /
# list collect-all)。
#
# 声明式 (handler.data, 决策-34/38/43/44 同模式):
#   - _form_types = "name:type;..." (与 _param_types 同语法, 决策-38/43):
#     "items:int[]" 必填 list / "fx:float[]=" 默认空 list / "count:int=0"
#     标量默认 / "str[low,high]" enum / "str" / "bool"
#   - _form_aliases = "name=alias;..." (上游 Form(alias=): wire key = alias,
#     原始名无绑定效力 — 只按 alias key 取值, 缺失 -> 默认/422, F8 实测)
#   - _param_descs = "name=desc;..." (OpenAPI description, 与 query 共享表)
#
# 值语义 (FastAPI 0.141.1 + pydantic 2.13.5 实测, /tmp/fm_probe):
#   - list: 同 key 全部 occurrence 按序 (F1); 单值 wrap (F1); 缺失 -> 默认
#     (带 '=') 或 422 missing (F2: "Field required" F 大写 + input null);
#     元素校验 **collect-all** (F4: 全收集, 顺序, loc ["body",name,i],
#     input = 元素 raw; 上游 query/body 同款, P1 更正 ADR-0018 前提)
#   - 标量: last-wins (F7, Starlette MultiDict.get); 缺失 -> 默认/422;
#     parse 失败 422 (input = last-wins raw, P4 实测)
#   - 内部表示: list = CSV join (决策-43 同约定), handler 读 form_<name>;
#     _form_fields 中未声明 _form_types 的字段 = 旧语义 (last-wins, 缺失
#     -> "", 不 422 — /login 存量兼容, ADR-0020 §3.5-5)
#   - 非 form Content-Type: 调用方传空 multi-map (上游同款: request.form()
#     空 -> 字段全缺失 -> 默认/422)
#
# 纯函数模块 (不碰 fd/env/FFI — 决策-44 把 form 解析归纯 Mojo 层的延续;
# FFI diff = 0)。依赖方向: form_params -> {request_response, params_typed,
# params_query_extra, json, handler}; http_server_final -> form_params (单向)。

from handler import Handler, KIND_ECHO
from request_response import parse_form_multi
from params_typed import parse_type_spec, parse_base, parse_typed_value
from params_query_extra import (parse_table, split_csv, join_values,
                                is_list_spec, has_eq, default_part,
                                list_default_csv, get_param_descs)
from json import json_escape


# ---------- 声明表解析 ----------

def get_form_types(handler: Handler) raises -> Dict[String, String]:
    """从 handler.data 读 _form_types 声明表 (name:type;..., 与 _param_types 同语法)."""
    if "_form_types" in handler.data:
        return parse_table(handler.data["_form_types"], 59, 58, True)
    return Dict[String, String]()


def get_form_aliases(handler: Handler) raises -> Dict[String, String]:
    """从 handler.data 读 _form_aliases 声明表 (name=alias;..., F8 实测语义)."""
    if "_form_aliases" in handler.data:
        return parse_table(handler.data["_form_aliases"], 59, 61, False)
    return Dict[String, String]()


def form_has_declaration(handler: Handler) raises -> Bool:
    """_form_fields 非空或 _form_types 非空 = 该路由声明 form body."""
    if "_form_fields" in handler.data and handler.data["_form_fields"] != "":
        return True
    if "_form_types" in handler.data and handler.data["_form_types"] != "":
        return True
    return False


def form_type_names_ordered(handler: Handler) raises -> List[String]:
    """_form_types 声明名按声明序 (OpenAPI schema 字段序用)."""
    var out = List[String]()
    if "_form_types" not in handler.data:
        return out^
    var raw = handler.data["_form_types"]
    var n = raw.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(raw[byte=i]) == 59)  # ';'
        if is_sep:
            if i > start:
                var piece = String(raw[byte=start:i])
                var colon = -1
                for j in range(piece.byte_length()):
                    if ord(piece[byte=j]) == 58:  # ':'
                        colon = j
                        break
                if colon > 0:
                    var name = String(piece[byte=0:colon])
                    if name != "":
                        out.append(name)
            start = i + 1
        i += 1
    return out^


def form_field_names_ordered(handler: Handler) raises -> List[String]:
    """_form_types ∪ _form_fields 的声明序名字列表 (去重, types 在前)."""
    var out = form_type_names_ordered(handler)
    if "_form_fields" in handler.data:
        for f in split_csv(handler.data["_form_fields"]):
            var seen = False
            for x in out:
                if x == f:
                    seen = True
                    break
            if not seen:
                out.append(f)
    return out^


# ---------- 错误对象 (决策-45: 含 input 字段, 上游 0.141.1 parity) ----------

def _fe(loc: String, msg: String, type_name: String, input_json: String) -> String:
    """单个 form 422 错误对象 (字段序 loc,msg,type,input — ADR-0020 §3.5-1).
    input_json: "null" 或 "<json 转义字符串>" (form 侧 input 恒为 string/null)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\",\"input\":" + input_json + "}"


def missing_err_json(k: String) raises -> String:
    """Field k canonical missing 422 error string (exact-match dedup,
    decision-46 dispatch: file part makes field present, drop missing)."""
    return _fe("[\"body\",\"" + json_escape(k) + "\"]", "Field required", "missing", "null")


def _elem_err_msg(type_name: String) -> Tuple[String, String]:
    """(msg, type): 元素/标量 parse 失败消息 (上游完整措辞, 与 params 侧同源)."""
    if type_name == "int":
        return ("Input should be a valid integer, unable to parse string as an integer", "int_parsing")
    if type_name == "float":
        return ("Input should be a valid number, unable to parse string as a number", "float_parsing")
    return ("Input should be a valid boolean, unable to interpret input", "bool_parsing")


# ---------- 校验 (422 detail: loc ["body",name(,i)]) ----------

def validate_form_collect(type_spec: Dict[String, String],
                          aliases: Dict[String, String],
                          multi: Dict[String, List[String]]) raises -> Tuple[Bool, List[String]]:
    """Form 422 校验 (决策-45): 收集全部错误 (上游 collect-all, F4/P1 实测).
    - list: wire key (alias 感知) 全部 occurrence; 缺失 -> 默认 CSV / 422
      missing (input null); 逐元素校验 (string/str 恒过, 其余 parse 校验)
    - 标量: last-wins (F7); 缺失 -> 默认 / 422; parse 失败 422
    multi 仅在 CT=form 时非空; 调用方对非 form body 传空 dict (上游同款).
    """
    var errs = List[String]()
    if len(type_spec) == 0:
        return (True, errs^)
    for k in type_spec:
        var spec = type_spec[k]
        var ts = parse_type_spec(spec)
        var pb = parse_base(ts.base_type)
        var loc = "[\"body\",\"" + json_escape(k) + "\"]"
        if not pb.ok:
            errs.append(_fe(loc, "unknown type for parameter '" + k + "': " + ts.base_type, "unknown_type", "null"))
            continue
        var lookup = k
        if k in aliases:
            lookup = aliases[k]
        var has_wire = lookup in multi
        if ts.is_list:
            var vals: List[String]
            if has_wire:
                vals = multi[lookup].copy()
            elif ts.has_default():
                vals = split_csv(ts.default_value)
            else:
                errs.append(_fe(loc, "Field required", "missing", "null"))
                continue
            var i = 0
            while i < len(vals):
                var v = vals[i]
                if pb.type_name != "string" and pb.type_name != "str":
                    var pr = parse_typed_value(pb.type_name, v)
                    if not pr[0]:
                        var m = _elem_err_msg(pb.type_name)
                        var eloc = "[\"body\",\"" + json_escape(k) + "\"," + String(i) + "]"
                        errs.append(_fe(eloc, m[0], m[1], "\"" + json_escape(v) + "\""))
                i += 1
            continue
        var raw = String("")
        var has_value = False
        if has_wire:
            var lst = multi[lookup].copy()
            if len(lst) > 0:
                raw = lst[len(lst) - 1]
                has_value = True
        if not has_value and ts.has_default():
            raw = ts.default_value
            has_value = True
        if not has_value:
            errs.append(_fe(loc, "Field required", "missing", "null"))
            continue
        var pr = parse_typed_value(pb.type_name, raw)
        if not pr[0]:
            var m = _elem_err_msg(pb.type_name)
            errs.append(_fe(loc, m[0], m[1], "\"" + json_escape(raw) + "\""))
    return (len(errs) == 0, errs^)


# ---------- 成功路径归一化 ----------

def apply_form_extras(mut params: Dict[String, String],
                      type_spec: Dict[String, String],
                      aliases: Dict[String, String],
                      multi: Dict[String, List[String]],
                      fields_csv: String) raises:
    """成功路径 form 归一化 (决策-45) -> params["form_<name>"]:
    - _form_types: list -> 全部 occurrence CSV (缺失 -> 默认 CSV);
      标量 -> last-wins (缺失 -> 默认); alias -> 原始名无绑定效力
      (form_<内部名> = 按 wire alias key 的绑定值, F8 实测)
    - _form_fields 中未声明 _form_types 的字段: 旧语义 (last-wins; 缺失 -> "")
    调用方: dispatch 注入段单点 (CT 非 form 时 multi 为空 -> 默认/旧语义).
    """
    for k in type_spec:
        var spec = type_spec[k]
        var lookup = k
        if k in aliases:
            lookup = aliases[k]
        var has_wire = lookup in multi
        if is_list_spec(spec):
            if has_wire:
                params["form_" + k] = join_values(multi[lookup].copy())
            elif has_eq(spec):
                params["form_" + k] = list_default_csv(spec)
            else:
                params["form_" + k] = ""
        else:
            if has_wire:
                var lst = multi[lookup].copy()
                params["form_" + k] = lst[len(lst) - 1]
            elif has_eq(spec):
                params["form_" + k] = default_part(spec)
            else:
                params["form_" + k] = ""
    var fields = split_csv(fields_csv)
    for i in range(len(fields)):
        var name = fields[i]
        if name in type_spec:
            continue
        var v = String("")
        if name in multi:
            var lst = multi[name].copy()
            v = lst[len(lst) - 1]
        params["form_" + name] = v


# ---------- OpenAPI (components.schemas + requestBody 数据源) ----------

def _cap_name(name: String) -> String:
    """字段名 -> schema title (上游: 首字母大写, F9/F10 实测)."""
    if name == "":
        return ""
    var c = ord(name[byte=0])
    var out = String("")
    if c >= 97 and c <= 122:
        out += chr(c - 32)
    else:
        out += chr(c)
    for i in range(1, name.byte_length()):
        out += chr(ord(name[byte=i]))
    return out


def _oapi_type(t: String) -> String:
    """Mojo 类型名 -> OpenAPI type (与 openapi._type_to_openapi 同源)."""
    if t == "int":
        return "integer"
    if t == "float":
        return "number"
    if t == "bool":
        return "boolean"
    return "string"


def _json_scalar(v: String, t: String) raises -> String:
    """标量默认值 -> JSON 字面量 (int/float/bool 裸值, 其它带引号)."""
    if t == "int" or t == "float" or t == "bool":
        return v
    return "\"" + json_escape(v) + "\""


def _openapi_form_field_schema(name: String, spec: String, desc: String) raises -> String:
    """单 form 字段 schema (F10 实测字段序):
    list -> {"items":{...},"type":"array","title":T[, "description":d][,
    "default":[...]} (default 仅显式 '='); 标量 -> {"type":t,"title":T
    [, "description":d][, "default":...}."""
    var tspec = parse_type_spec(spec)
    var pb = parse_base(tspec.base_type)
    var type_name = "str"
    if pb.ok:
        type_name = pb.type_name
    var oapi = _oapi_type(type_name)
    var title = json_escape(_cap_name(name))
    if is_list_spec(spec):
        var out = "{\"items\":{\"type\":\"" + oapi + "\"},\"type\":\"array\",\"title\":\"" + title + "\""
        if desc != "":
            out = out + ",\"description\":\"" + json_escape(desc) + "\""
        if has_eq(spec):
            var items = split_csv(list_default_csv(spec))
            var arr = "["
            for i in range(len(items)):
                if i > 0:
                    arr = arr + ","
                arr = arr + _json_scalar(items[i], type_name)
            out = out + ",\"default\":" + arr + "]"
        out = out + "}"
        return out^
    var out2 = "{\"type\":\"" + oapi + "\",\"title\":\"" + title + "\""
    if desc != "":
        out2 = out2 + ",\"description\":\"" + json_escape(desc) + "\""
    if has_eq(spec):
        out2 = out2 + ",\"default\":" + _json_scalar(default_part(spec), type_name)
    out2 = out2 + "}"
    return out2^


def lower_ascii(s: String) -> String:
    """ASCII 小写 (Mojo 1.0.0 String 无 .lower(); security_jwt._lower 同款)."""
    var out = String("")
    for i in range(s.byte_length()):
        var c = ord(s[byte=i])
        if c >= 65 and c <= 90:
            out += chr(c + 32)
        else:
            out += chr(c)
    return out

def form_openapi_schema(handler: Handler, method: String) raises -> String:
    """生成 components/schemas 条目 (F10 实测结构):
    {"type":"object","title":"Body_<name>_<method>","properties":{...}}.
    字段 = _form_types 声明序 ∪ _form_fields (未标注 -> string, ADR §3.5-5);
    description 复用 _param_descs 共享表 (决策-43).
    命名偏差: Body_<handler.name>_<method> (上游 = fn+route+method, §3.5-4)."""
    var name = "Body_" + handler.name + "_" + lower_ascii(method)

    var types = get_form_types(handler)
    var descs = get_param_descs(handler)
    var out = "{\"type\":\"object\",\"title\":\"" + json_escape(name) + "\",\"properties\":{"
    var names = form_field_names_ordered(handler)
    var first = True
    for i in range(len(names)):
        var n = names[i]
        if not first:
            out = out + ","
        first = False
        if n in types:
            var spec = types[n]
            var desc = ""
            if n in descs:
                desc = descs[n]
            out = out + "\"" + json_escape(n) + "\":" + _openapi_form_field_schema(n, spec, desc)
        else:
            out = out + "\"" + json_escape(n) + "\":{" + "\"type\":\"string\",\"title\":\"" + json_escape(_cap_name(n)) + "\"}"
    out = out + "}}"
    return out^


def form_request_body_required(handler: Handler) raises -> Bool:
    """判定 requestBody.required (F10 实测: 仅当存在无默认的 _form_types 字段).
    未标注 _form_types 的 _form_fields 字段不计 (ADR-0020 §3.5-5)."""
    var t = get_form_types(handler)
    for k in t:
        if not has_eq(t[k]):
            return True
    return False


# ---------- 自测 (mojo run: 纯逻辑, JIT 可达 — 无 FFI) ----------

import std.os


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def _has(s: String, sub: String) -> Bool:
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


def _multi(pairs_csv: String) raises -> Dict[String, List[String]]:
    """自测: "k1=v1&k2=v2" (可含 & 值) -> multi-map."""
    return parse_form_multi(pairs_csv)


def main() raises:
    print("Testing form params (multi/alias/422-parity, 决策-45)...")

    # parse_form_multi
    var m = _multi("a=1&a=2&q=x")
    check(len(m["a"]) == 2 and m["a"][0] == "1" and m["a"][1] == "2", "multi occ")
    check(len(m["q"]) == 1 and m["q"][0] == "x", "single occ")
    var m2 = _multi("a=%41%20b&a=+c")
    check(m2["a"][0] == "A b" and m2["a"][1] == " c", "url decode (+ space)")
    var m3 = _multi("bare&x%26y=v")
    check(len(m3["bare"]) == 1 and m3["bare"][0] == "", "bare key empty elem")
    check(m3["x&y"][0] == "v", "encoded ampersand key")
    var m4 = _multi("")
    check(len(m4) == 0, "empty body")

    # validate: missing required list (F 大写 + input null)
    var ts = Dict[String, String]()
    ts["items"] = "int[]"
    var r = validate_form_collect(ts, Dict[String, String](), Dict[String, List[String]]())
    check(not r[0] and _has(r[1][0], "[\"body\",\"items\"]") and _has(r[1][0], "\"msg\":\"Field required\"")
          and _has(r[1][0], "\"input\":null"), "missing list: Field required + input null")

    # validate: list two bad elements -> collect-all (F4)
    var mm = _multi("items=1&items=a&items=b")
    r = validate_form_collect(ts, Dict[String, String](), mm)
    check(not r[0] and len(r[1]) == 2 and _has(r[1][0], "[\"body\",\"items\",1]")
          and _has(r[1][1], "[\"body\",\"items\",2]") and _has(r[1][0], "\"input\":\"a\""),
          "collect-all two bad elements")
    # validate: list ok
    var mm2 = _multi("items=1&items=2")
    r = validate_form_collect(ts, Dict[String, String](), mm2)
    check(r[0], "list ok")

    # validate: list default
    var ts2 = Dict[String, String]()
    ts2["tags"] = "str[]="
    r = validate_form_collect(ts2, Dict[String, String](), Dict[String, List[String]]())
    check(r[0], "list empty default ok")

    # validate: scalar last-wins parse (P4: input raw)
    var ts3 = Dict[String, String]()
    ts3["b"] = "int=0"
    var mm3 = _multi("b=1&b=zz")
    r = validate_form_collect(ts3, Dict[String, String](), mm3)
    check(not r[0] and _has(r[1][0], "int_parsing") and _has(r[1][0], "\"input\":\"zz\""),
          "scalar last-wins parse err")
    # scalar default
    var r2 = validate_form_collect(ts3, Dict[String, String](), Dict[String, List[String]]())
    check(r2[0], "scalar default ok")
    # scalar missing no default
    var ts4 = Dict[String, String]()
    ts4["c"] = "int"
    r = validate_form_collect(ts4, Dict[String, String](), Dict[String, List[String]]())
    check(not r[0] and _has(r[1][0], "Field required"), "scalar missing")

    # validate: alias (F8: wire key = alias, original ignored)
    var ts5 = Dict[String, String]()
    ts5["labels"] = "str[]="
    var al = Dict[String, String]()
    al["labels"] = "tags"
    var mm4 = _multi("tags=x&tags=y")
    r = validate_form_collect(ts5, al, mm4)
    check(r[0], "alias wire key bound")
    var mm5 = _multi("labels=x")
    r = validate_form_collect(ts5, al, mm5)
    check(r[0], "alias original name ignored (default)")

    # apply: list CSV / default / scalar last-wins / alias / legacy fields
    var p = Dict[String, String]()
    apply_form_extras(p, ts5, al, mm4, "")
    check(p["form_labels"] == "x,y", "apply list CSV via alias")
    var p2 = Dict[String, String]()
    apply_form_extras(p2, ts2, Dict[String, String](), Dict[String, List[String]](), "")
    check(p2["form_tags"] == "", "apply list default empty")
    var p3 = Dict[String, String]()
    apply_form_extras(p3, ts3, Dict[String, String](), mm3, "")
    check(p3["form_b"] == "zz", "apply scalar last-wins raw")
    var p4 = Dict[String, String]()
    apply_form_extras(p4, ts4, Dict[String, String](), Dict[String, List[String]](), "c,other")
    check(p4["form_c"] == "", "apply missing -> empty (legacy compat)")
    check(p4["form_other"] == "", "apply untyped field -> empty")

    # openapi schema (F10 field order: items/type/title/description/default)
    var h = Handler(KIND_ECHO(), "form_multi")
    h.set_data("_form_types", "items:int[];count:int=0")
    h.set_data("_param_descs", "items=Numeric items (multi-occurrence)")
    var sch = form_openapi_schema(h, "POST")
    check(_has(sch, "\"title\":\"Body_form_multi_post\""), "schema title")
    check(_has(sch, "\"items\":{\"type\":\"integer\"},\"type\":\"array\",\"title\":\"Items\""
          ",\"description\":\"Numeric items (multi-occurrence)\""), "list schema F10 order")
    check(_has(sch, "\"type\":\"integer\",\"title\":\"Count\",\"default\":0"), "scalar default schema")
    check(form_request_body_required(h), "required flag (items no default)")
    var h2 = Handler(KIND_ECHO(), "demo")
    h2.set_data("_form_types", "a:str=hello")
    h2.set_data("_form_fields", "a,b")
    var sch2 = form_openapi_schema(h2, "POST")
    check(_has(sch2, "\"a\":{\"type\":\"string\",\"title\":\"A\",\"default\":\"hello\"}"), "scalar str default")
    check(_has(sch2, "\"b\":{\"type\":\"string\",\"title\":\"B\"}"), "untyped field string")
    check(not form_request_body_required(h2), "no required (all defaults)")

    print("form params test completed!")
