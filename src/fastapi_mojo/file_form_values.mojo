# src/fastapi_mojo/file_form_values.mojo
#
# 决策-102 (上游 0.143.5 parity): urlencoded CT 下的 File / bytes 声明字段.
#
# 上游语义 (权威来源 fastapi/params.py + fastapi/dependencies/utils.py):
#   - `class File(Form)` -> routing.py 的 is_body_form 对 File 参数同样为真
#     -> request.form() 对 urlencoded 体收 FormData(字符串值).
#   - `_get_multidict_value` 单值分支: 值 == "" -> Undefined (缺失);
#     序列分支: getlist 全量, 仅过滤 _is_empty_file_input (UploadFile 且
#     filename=="" 且 size==0) — 字符串项永不命中.
#   - `_extract_form_body` (PR #9383): bytes 序列的字符串项**原样保留**
#     (不再当 UploadFile 读) -> `files: list[bytes] | None = File(None)`
#     + urlencoded `files=` -> count=1 且 size=0; 不带该键 -> count=0.
#   - file 基础 (UploadFile) 收到字符串值 -> 422 value_error
#     (Expected UploadFile, received: <class 'str'>).
#
# 依赖: file_form_values -> {file_params (声明表 + b64), json, handler};
# 单向 (file_params 不反向依赖本模块).

from handler import Handler
from json import json_escape
from file_params import (get_file_types, get_file_aliases, _parse_file_spec,
                         _b64_encode)
from alias_choices import candidates_for, pick_in_multi


def _fe(loc: String, msg: String, type_name: String, input_json: String) -> String:
    """单个 422 错误对象 (字段序 loc,msg,type,input — ADR-0020 §3.5-1)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\",\"input\":" + input_json + "}"


def _sbytes(s: String) -> List[Int]:
    """String -> UTF-8 原始字节 (as_bytes 逐字节; 上游 str->bytes 走
    UTF-8 编码, size 即字节数)."""
    var out = List[Int]()
    var n = s.byte_length()
    var i = 0
    while i < n:
        out.append(Int(s.as_bytes()[i]))
        i += 1
    return out^


def _item_json(filename: String, ct: String, size: Int, b64: String) -> String:
    """bytes 列表项 JSON (与 multipart 路径同形状:
    {"filename","content_type","size","body_b64"})."""
    var obj = "{\"filename\":\"" + json_escape(filename) + "\","
    obj = obj + "\"content_type\":\"" + json_escape(ct) + "\","
    obj = obj + "\"size\":" + String(size) + ","
    obj = obj + "\"body_b64\":\"" + json_escape(b64) + "\"}"
    return obj


def form_map_without_files(multi: Dict[String, List[String]],
    excl: List[String]) raises -> Dict[String, List[String]]:
    """urlencoded 表单 map 去掉被 file 字段占用的键 (上游: 同一参数不能既是
    File 又是 Form — multipart 路径用 text_multi_map_filtered 同语义)."""
    var out = Dict[String, List[String]]()
    for k in multi:
        var skip = False
        for x in excl:
            if x == k:
                skip = True
                break
        if not skip:
            out[k] = multi[k].copy()
    return out^


def validate_file_collect_form(type_spec: Dict[String, String],
    aliases: Dict[String, String],
    multi: Dict[String, List[String]]) raises -> Tuple[Bool, List[String]]:
    """urlencoded CT 下 File/bytes 声明字段的 422 校验 (上游 0.143.5):
    - 键缺失 -> missing (无声明默认时 422)
    - bytes 标量: 最后一个值 (上游 values.get); 空串 -> 缺失 (上游 "" ->
      Undefined); 有默认则用默认
    - bytes 列表: 全量 occurrence 保留 (空串元素保留 — PR #9383)
    - file 基础: 值存在即 422 value_error (上游 Expected UploadFile,
      received: <class 'str'>)"""
    var errs = List[String]()
    if len(type_spec) == 0:
        return (True, errs^)
    for k in type_spec:
        var fs = _parse_file_spec(type_spec[k])
        var base = fs[0]
        var loc = "[\"body\",\"" + json_escape(k) + "\"]"
        if base != "file" and base != "bytes":
            errs.append(_fe(loc, "unknown type for parameter '" + k + "': " + base,
            "unknown_type", "null"))
            continue
        # 决策-104: 候选序命中 (首个有值者生效; 标量空串视为缺席 — 上游
        # _get_multidict_value 单值分支 "" -> Undefined).
        var cands = candidates_for(aliases, k)
        var lookup = pick_in_multi(cands, multi, not fs[1])
        if lookup == "":
            if not fs[2]:
                errs.append(_fe(loc, "Field required", "missing", "null"))
            continue
        if fs[1]:
            # 序列: 全量保留 (空串元素保留 — 上游 PR #9383)
            continue
        var vals = multi[lookup].copy()
        var last = vals[len(vals) - 1]
        if base == "file":
            errs.append(_fe(loc,
            "Value error, Expected UploadFile, received: <class 'str'>",
            "value_error", "\"" + json_escape(last) + "\""))
            continue
        if last == "":
            if not fs[2]:
                errs.append(_fe(loc, "Field required", "missing", "null"))
    return (len(errs) == 0, errs^)


def apply_file_form_values(mut params: Dict[String, String], handler: Handler,
    multi: Dict[String, List[String]]) raises:
    """urlencoded CT -> File/bytes 声明字段注入 (上游 0.143.5):
    - bytes 标量: 最后一个值 (上游 values.get); 空串 -> 缺失 (不注入);
      否则 file_<name>_filename("")/_content_type("")/_size(UTF-8 字节数)/
      _body_b64.
    - bytes 列表: 全部 occurrence (空串保留) -> file_<name>_count +
      _list_json (同 multipart 形状) + 标量键取最后一个值 (与 multipart
      路径的 last-wins 约定一致).
    - file 基础: urlencoded 只能给字符串 -> 422 value_error (校验层拦截,
      不会走到这里)."""
    var types = get_file_types(handler)
    var aliases = get_file_aliases(handler)
    for k in types:
        var fs = _parse_file_spec(types[k])
        if fs[0] != "bytes":
            continue
        # 决策-104: 候选序命中 (首个有值者生效)
        var cands = candidates_for(aliases, k)
        var lookup = pick_in_multi(cands, multi, not fs[1])
        if lookup == "":
            continue
        var vals = multi[lookup].copy()
        var last = vals[len(vals) - 1]
        var lastb = _sbytes(last)
        if fs[1]:
            params["file_" + k + "_count"] = String(len(vals))
            var arr = List[String]()
            for v in vals:
                var vb = _sbytes(v)
                arr.append(_item_json("", "", len(vb), _b64_encode(vb)))
            params["file_" + k + "_list_json"] = "[" + ",".join(arr) + "]"
            params["file_" + k + "_filename"] = ""
            params["file_" + k + "_content_type"] = ""
            params["file_" + k + "_size"] = String(len(lastb))
            params["file_" + k + "_body_b64"] = _b64_encode(lastb)
        else:
            if last == "":
                continue
            params["file_" + k + "_filename"] = ""
            params["file_" + k + "_content_type"] = ""
            params["file_" + k + "_size"] = String(len(lastb))
            params["file_" + k + "_body_b64"] = _b64_encode(lastb)
