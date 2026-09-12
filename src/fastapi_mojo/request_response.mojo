# src/fastapi_mojo/request_response.mojo
#
# F3: Request/Response 对象 + 嵌套 JSON 序列化 (Goal-0002 §1.1).
#
# 设计:
#   - Mojo 1.0.0 无闭包/对象, 全部声明式 (与 ADR-0004 / F1 / F2 同模式):
#       * Request 读 headers/cookies: Handler.data["_reads_headers"] / "_reads_cookies"
#         格式 "name1,name2" -> dispatch 把值注入 route_result.params, key 前缀
#         "header_<name>" / "cookie_<name>". handler 直接读 params["header_X-Token"].
#       * Response 自定义 headers: Handler.data["_response_headers"]
#         格式 "Name1:value1;Name2:value2". dispatch 读出, 注入 response headers.
#       * 嵌套 JSON: 特殊前缀 "__nested__:" 标记的 value 在 json_serialize_dict
#         时跳过 json_serialize 包裹 (直传). 提供 nest_dict / nest_list helpers
#         给 handler 构造嵌套 JSON (目标: {"data": {"a": 1, "b": [..]}}).
#
#   单一 dispatch 扩展点: collect_request_extensions (在 type check 之后,
#     run_handler 之前调用一次; 集中处理 reads_* 把值注入 params).
#   单一 dispatch 扩展点: collect_response_headers (run_handler 之后; 收集
#     _response_headers + 拼成"Name: value"串, 透传给 send_simple_response_extra).
#
# 兼容:
#   - 不动现有 F1/F2 路径.
#   - 不改 FFI 表面 (新增 send_simple_response_extra 走 extern "C" 包装层,
#     后续 D-阶段如必要再上).
#   - 默认 200 响应不带自定义 header (行为不变, 现有 79+14 e2e 不回归).
#
# F3c 实现细节 (避免双重序列化):
#   json_serialize_dict 当前对每个 value 调 json_serialize (会再 escape 字符串).
#   嵌套场景: handler 想让某个 value 直接是 JSON object/array, 不能用 escape.
#   解法: value 以 "__nested__:" 开头, json_serialize_dict 检测后直接
#   append(value[10:]) (剥前缀), 不再 json_serialize.

from handler import Handler
from string_builder import StringBuilder
from json import json_serialize_dict, json_serialize_list, json_escape
from json_rust import serialize_dict_opt_in
from params_query import url_decode  # _parse_form_body (决策-44 从 http_server_final 移入)


def _bof(s: String, i: Int) -> Int:
    """字节安全取值 (Mojo 1.0.0: String[byte=i] 在码点内部下标会 assert;
    as_bytes() span 取原始字节, 避免多字节输入 (如 form/cookie 值含 UTF-8) 崩溃)。
    仅用于 ASCII 分隔字节比较 — 多字节首字节 >= 0xC2, 永不等于 ASCII 分隔符。"""
    return Int(s.as_bytes()[i])


# ---------- 嵌套 JSON helpers ----------

def nest_dict(d: Dict[String, String]) raises -> String:
    """包一个 Dict 成 __nested__:<raw JSON>, 用于 handler resp 字段值.
    用法: resp["data"] = nest_dict({\"a\": \"1\"}) -> resp json: {\"data\": {\"a\": 1}}."""
    return "__nested__:" + json_serialize_dict(d)


def nest_list(items: List[String]) -> String:
    """包一个 List 成 __nested__:<raw JSON>, 用于 handler resp 字段值.
    用法: resp["tags"] = nest_list([\"a\", \"b\"]) -> resp json: {\"tags\": [\"a\", \"b\"]}."""
    return "__nested__:" + json_serialize_list(items)


def nest_raw(json_str: String) -> String:
    """直接标记一段 JSON 字符串为 raw (handler 自行构造的 JSON 片段).
    用途: 比 nest_dict 更灵活, handler 可以拼任意 JSON 形态 (含数字 bool null)."""
    return "__nested__:" + json_str


# ---------- Request 扩展 (读 headers/cookies 注入 params) ----------

def _split_csv(s: String, sep_byte: Int = 44) -> List[String]:
    """按 ',' 切 CSV, 去空."""
    var out = List[String]()
    var n = s.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (_bof(s, i) == sep_byte)  # 分隔字节 (默认 ,)
        if is_sep:
            if i > start:
                var piece = String(s[byte=start:i])
                # trim
                var b = 0
                var e = piece.byte_length()
                while b < e and (_bof(piece, b) == 32 or _bof(piece, b) == 9):
                    b += 1
                while e > b and (_bof(piece, e - 1) == 32 or _bof(piece, e - 1) == 9):
                    e -= 1
                if e > b:
                    out.append(String(piece[byte=b:e]))
            start = i + 1
        i += 1
    return out^


def _collect_reads(handler: Handler) raises -> Tuple[List[String], List[String]]:
    """从 handler.data 解析 _reads_headers / _reads_cookies CSV 列表."""
    var hdrs = List[String]()
    var cks = List[String]()
    if "_reads_headers" in handler.data:
        hdrs = _split_csv(handler.data["_reads_headers"])
    if "_reads_cookies" in handler.data:
        cks = _split_csv(handler.data["_reads_cookies"])
    return (hdrs^, cks^)


# ---------- form body 解析 (决策-44: 从 http_server_final.mojo 移入, 供 security_jwt 复用; 避免 http_server_final -> security_jwt -> request_response 循环) ----------

def _parse_form_body(body: String) -> Dict[String, String]:
    """Parse application/x-www-form-urlencoded body: key1=val1&key2=val2.
    每个 key/value 做 url_decode (percent + '+')."""
    var out = Dict[String, String]()
    if body == "":
        return out^
    var n = body.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (_bof(body, i) == 38)  # '&'
        if is_sep:
            if i > start:
                var pair = String(body[byte=start:i])
                var eq = -1
                for j in range(pair.byte_length()):
                    if _bof(pair, j) == 61:  # '='
                        eq = j
                        break
                if eq > 0:
                    var k = url_decode(String(pair[byte=0:eq]))
                    var v = url_decode(String(pair[byte=eq + 1:pair.byte_length()]))
                    out[k] = v
                elif eq < 0:
                    # 裸 key 无值 (FastAPI 兼容)
                    var k = url_decode(pair)
                    out[k] = ""
            start = i + 1
        i += 1
    return out^


def parse_form_multi(body: String) raises -> Dict[String, List[String]]:
    """决策-45: _parse_form_body 的 multi 姊妹函数 — 同 key 全部 occurrence
    按序 append (上游 Starlette MultiDict.getlist 语义; F1/F7 实测).
    每 key/value url_decode (percent + '+'); 裸 key (无 '=') -> 空串元素;
    与 _parse_form_body 同宽松规则 (eq=0 空 key 跳过)."""
    var out = Dict[String, List[String]]()
    if body == "":
        return out^
    var n = body.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (_bof(body, i) == 38)  # '&'
        if is_sep:
            if i > start:
                var pair = String(body[byte=start:i])
                var eq = -1
                for j in range(pair.byte_length()):
                    if _bof(pair, j) == 61:  # '='
                        eq = j
                        break
                var k = String("")
                var v = String("")
                if eq > 0:
                    k = url_decode(String(pair[byte=0:eq]))
                    v = url_decode(String(pair[byte=eq + 1:pair.byte_length()]))
                elif eq < 0:
                    k = url_decode(pair)
                    v = ""
                if k != "":
                    if k in out:
                        out[k].append(v)
                    else:
                        var one = List[String]()
                        one.append(v)
                        out[k] = one^
            start = i + 1
        i += 1
    return out^


def _parse_cookies(cookie_header: String) -> Dict[String, String]:
    """从 Cookie 头解析 key=value 对 (RFC 6265 简化: ';' 分隔, '=' 切, 去空格)."""
    var out = Dict[String, String]()
    if cookie_header == "":
        return out^
    var n = cookie_header.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (_bof(cookie_header, i) == 59)  # ';'
        if is_sep:
            if i > start:
                var piece = String(cookie_header[byte=start:i])
                # trim leading space
                var b = 0
                while b < piece.byte_length() and _bof(piece, b) == 32:
                    b += 1
                var eq = -1
                for j in range(b, piece.byte_length()):
                    if _bof(piece, j) == 61:  # '='
                        eq = j
                        break
                if eq > b:
                    var k = String(piece[byte=b:eq])
                    var v = String(piece[byte=eq + 1:piece.byte_length()])
                    out[k] = v
            start = i + 1
        i += 1
    return out^


# ---------- Response 扩展 (自定义 headers) ----------

def parse_response_headers(handler: Handler) raises -> List[String]:
    """解析 handler.data["_response_headers"] -> ["Name: value", ...] 列表.
    格式: "Name1:value1;Name2:value2". 缺省 -> 空 list.
    raises: 格式错误 (缺 ':')."""
    var out = List[String]()
    if "_response_headers" not in handler.data:
        return out^
    var raw = handler.data["_response_headers"]
    if raw == "":
        return out^
    var n = raw.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (_bof(raw, i) == 59)  # ';'
        if is_sep:
            if i > start:
                var piece = String(raw[byte=start:i])
                var colon = -1
                for j in range(piece.byte_length()):
                    if _bof(piece, j) == 58:  # ':'
                        colon = j
                        break
                if colon < 0:
                    raise Error("request_response: bad _response_headers entry (missing ':'): " + piece)
                out.append(String(piece[byte=0:colon + 1]) + String(piece[byte=colon + 1:piece.byte_length()]))
            start = i + 1
        i += 1
    return out^


# ---------- json.mojo 扩展: __nested__ 前缀直通 ----------

def is_nested_marker(v: String) -> Bool:
    """True if v starts with __nested__: (raw JSON 透传标记)."""
    return v.byte_length() > 10 and _bof(v, 0) == 95 and _bof(v, 1) == 95 and \
           _bof(v, 2) == 110 and _bof(v, 3) == 101 and _bof(v, 4) == 115 and \
           _bof(v, 5) == 116 and _bof(v, 6) == 101 and _bof(v, 7) == 100 and \
           _bof(v, 8) == 95 and _bof(v, 9) == 95 and _bof(v, 10) == 58


# ---------- 决策-41: response_model exclude/include/exclude_none (ADR-0016) ----------

def _csv_contains(csv: List[String], v: String) -> Bool:
    """v 是否在 CSV 列表 (手动 trim 后精确匹配; Mojo 1.0.0 String 无 .trim())."""
    for it in csv:
        var b = 0
        var e = it.byte_length()
        while b < e and (_bof(it, b) == 32 or _bof(it, b) == 9):
            b += 1
        while e > b and (_bof(it, e - 1) == 32 or _bof(it, e - 1) == 9):
            e -= 1
        if e > b:
            if String(it[byte=b:e]) == v:
                return True
        elif v == "":
            return True
    return False


def _is_null_value(v: String) -> Bool:
    """exclude_none 判定: 空串, 或 __nested__:null (真实 JSON null).
    注意: 普通值 "null" 会被序列化为 JSON 字符串 "null", 不算 null (FastAPI
    语义里 exclude_none 只去 None, 不去 "null" 字符串)."""
    if v == "":
        return True
    return v.startswith("__nested__:null")


def response_model_body(handler: Handler, resp_data: Dict[String, String]) raises -> String:
    """决策-41: response_model 过滤 (FastAPI/Pydantic 语义) — 单一 dispatch 调用点.

    声明式 (handler.data):
      - _response_model      = "f1,f2,..."  include: 只返回模型字段 (决策-35 既有)
      - _response_exclude    = "a,b"        exclude: 从模型字段中剔除 (FastAPI
        response_model_exclude 语义: 作用于模型字段, 无模型时 no-op — 上游对齐)
      - _response_exclude_none = "true"     exclude_none: 剔除 null 值字段
        (扁平 string dict 等价: 空串 / __nested__:null)
    应用序: include -> exclude -> exclude_none. 未声明 _response_model 时
    整体 no-op (FastAPI: 无 response_model 时 include/exclude 不影响响应).
    """
    if "_response_model" not in handler.data:
        return serialize_dict_opt_in(resp_data)
    var model_fields = _split_csv(handler.data["_response_model"])
    var exclude = List[String]()
    if "_response_exclude" in handler.data:
        exclude = _split_csv(handler.data["_response_exclude"])
    var exclude_none = "_response_exclude_none" in handler.data and handler.data["_response_exclude_none"] == "true"
    var filtered = Dict[String, String]()
    for f in model_fields:
        if f in resp_data and not _csv_contains(exclude, f):
            var v = resp_data[f]
            if not (exclude_none and _is_null_value(v)):
                filtered[f] = v
    return serialize_dict_opt_in(filtered)
