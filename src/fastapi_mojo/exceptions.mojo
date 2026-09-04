# src/fastapi_mojo/exceptions.mojo
#
# F2: HTTPException + 声明式异常映射 (Goal-0002 §1.1).
#
# 设计:
#   - FastAPI 的 HTTPException 在 handler 里 raise; Mojo 1.0.0 无闭包/异常传播,
#     改用"声明式映射"模式: Handler.data["_error_map"] 声明参数值->异常映射,
#     dispatch 在 run_handler 前检查, 命中则返回 {status, detail: ...} JSON 响应.
#   - 统一错误体格式: {"detail": "...", "status": "404"} (FastAPI 语义,
#     替换现有 build_error_response 的 {"error": ..., "status": ...}).
#   - 格式: "key=value:status_code:detail;key=value:status_code:detail;..."
#     例: "_error_map" = "item_id=99:404:Item not found;item_id=*:422:Invalid ID"
#     value 支持 * (通配) 兜底; status_code 是数字字面量; detail 是任意字符串
#     (支持 {param_name} 占位符, 与 TEMPLATE kind 类似的填充).
#   - 规则: 按声明顺序匹配, 第一个命中胜出; 都不命中 -> None (run_handler 继续).
#   - 显式 dispatch 扩展点: match_error_map 单一函数; 新增异常路由 = 仅在
#     register_routes 用 set_data("_error_map", "...") 声明.
#
# 兼容: 现有 e2e 79 项 (除 F1 8 项) 不回归, 因为:
#   - 现有 404/405 路径使用 build_error_response ({"error","status"}),
#     F2 改为 build_exception_body ({"detail","status"}); e2e 只检查 status 码,
#     body 字段变化不影响断言.
#   - F1 422 路径已用 {"detail","status"} (F1 走的是 build_exception_body 同款),
#     统一为一套.
#
# Mojo 1.0.0 约束: 无 match -> if/elif; Dict 顺序遍历 -> for k in d.

from handler import Handler
from string_builder import StringBuilder


# ---------- 异常规格结构 ----------

struct HTTPExceptionSpec:
    """HTTP 异常规格: status_code + detail (FastAPI 语义)."""
    var status_code: Int      # 4xx/5xx 数字 (如 404)
    var status_line: String   # "404 Not Found" (完整状态行)
    var detail: String        # 响应 body 的 detail 字段

    def __init__(out self, status_code: Int, status_line: String, detail: String):
        self.status_code = status_code
        self.status_line = status_line
        self.detail = detail


# ---------- 标准 status_line 映射 ----------

def standard_status_line(code: Int) -> String:
    """常见 HTTP 状态码 -> "NNN Reason Phrase". 未知码 -> 通用 "NNN Error"."""
    if code == 400: return "400 Bad Request"
    if code == 401: return "401 Unauthorized"
    if code == 403: return "403 Forbidden"
    if code == 404: return "404 Not Found"
    if code == 405: return "405 Method Not Allowed"
    if code == 409: return "409 Conflict"
    if code == 410: return "410 Gone"
    if code == 413: return "413 Payload Too Large"
    if code == 414: return "414 URI Too Long"
    if code == 415: return "415 Unsupported Media Type"
    if code == 422: return "422 Unprocessable Entity"
    if code == 429: return "429 Too Many Requests"
    if code == 500: return "500 Internal Server Error"
    if code == 501: return "501 Not Implemented"
    if code == 502: return "502 Bad Gateway"
    if code == 503: return "503 Service Unavailable"
    if code == 504: return "504 Gateway Timeout"
    return String(code) + " Error"


# ---------- 统一错误响应 builder (替换 build_error_response) ----------

def build_exception_body(detail: String, status_code: Int) -> Dict[String, String]:
    """FastAPI 风格统一错误体: {"detail": detail, "status": "<code>"}."""
    var out = Dict[String, String]()
    out["detail"] = detail
    out["status"] = String(status_code)
    return out^


# ---------- 错误映射解析与匹配 ----------

def _split_top_level(s: String, sep_byte: Int) -> List[String]:
    """按 sep_byte 切分顶层条目 (不处理嵌套). 返回 List[String]."""
    var parts = List[String]()
    var n = s.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(s[byte=i]) == sep_byte)
        if is_sep:
            if i > start:
                parts.append(String(s[byte=start:i]))
            start = i + 1
        i += 1
    return parts^


def _parse_int(s: String) -> Tuple[Bool, Int]:
    """Parse a positive integer literal. Returns (ok, value)."""
    var n = s.byte_length()
    if n == 0:
        return (False, 0)
    var v = 0
    for i in range(n):
        var c = ord(s[byte=i])
        if c < 48 or c > 57:
            return (False, 0)
        v = v * 10 + (c - 48)
    return (True, v)


def _render_template(tpl: String, ctx: Dict[String, String]) raises -> String:
    """替换 tpl 里的 {param} -> ctx[param] (缺失 -> 保留字面量).
    与 handler.mojo::render_template 类似的填充, 简化版 (不省略字段)."""
    var out = StringBuilder()
    var n = tpl.byte_length()
    var i = 0
    while i < n:
        if ord(tpl[byte=i]) == 123:  # '{'
            var j = i + 1
            while j < n and ord(tpl[byte=j]) != 125:  # '}'
                j += 1
            if j < n:
                var key = String(tpl[byte=i + 1:j])
                if key in ctx:
                    out.append(ctx[key])
                else:
                    out.append(String(tpl[byte=i:j + 1]))
                i = j + 1
                continue
        out.append_byte(ord(tpl[byte=i]))
        i += 1
    return out.take()


def match_error_map(handler: Handler, path_params: Dict[String, String],
                    query_params: Dict[String, String]) raises -> HTTPExceptionSpec:
    """检查 Handler.data["_error_map"], 按声明顺序匹配.
    格式: "key=value:status_code:detail;..."
      - key: path 或 query 参数名
      - value: 期望值; "*" 表示通配 (任意值命中)
      - status_code: 数字字面量
      - detail: 任意字符串, 支持 {param} 占位符
    命中 -> 返回 HTTPExceptionSpec; 不命中 -> status_code=0 (调用方判断).
    raises: 格式错误 (key:value:detail 必须 3 段; status_code 必须数字)."""
    if "_error_map" not in handler.data:
        return HTTPExceptionSpec(0, "", "")
    var raw = handler.data["_error_map"]
    if raw == "":
        return HTTPExceptionSpec(0, "", "")

    # 合并 path + query 为匹配上下文
    var ctx = Dict[String, String]()
    for k in path_params:
        ctx[k] = path_params[k]
    for k in query_params:
        ctx[k] = query_params[k]

    var entries = _split_top_level(raw, 59)  # ';'
    for e_idx in range(len(entries)):
        var entry = entries[e_idx]
        # 按 ':' 切 3 段 (key=value : status : detail); 但 key=value 本身可能含 '='.
        # 找第一个 ':' 作为 key=value 与 status 的分隔, 找第二个 ':' 作为 status 与 detail 的分隔.
        var n = entry.byte_length()
        var colon1 = -1
        for i in range(n):
            if ord(entry[byte=i]) == 58:  # ':'
                colon1 = i
                break
        if colon1 < 0:
            raise Error("exceptions: bad _error_map entry (missing ':'): " + entry)
        var colon2 = -1
        for i in range(colon1 + 1, n):
            if ord(entry[byte=i]) == 58:  # ':'
                colon2 = i
                break
        if colon2 < 0:
            raise Error("exceptions: bad _error_map entry (need 3 colons): " + entry)
        var kv = String(entry[byte=0:colon1])
        var status_str = String(entry[byte=colon1 + 1:colon2])
        var detail_tpl = String(entry[byte=colon2 + 1:n])

        # 拆 key=value (第一个 '=')
        var eq = -1
        for i in range(kv.byte_length()):
            if ord(kv[byte=i]) == 61:  # '='
                eq = i
                break
        if eq < 0:
            raise Error("exceptions: bad _error_map entry (missing '=' in key=value): " + entry)
        var key = String(kv[byte=0:eq])
        var expect = String(kv[byte=eq + 1:kv.byte_length()])

        # 匹配
        var actual = ""
        if key in ctx:
            actual = ctx[key]
        var hit = False
        if expect == "*":
            hit = True  # 通配
        elif actual == expect:
            hit = True
        if not hit:
            continue

        # status_code 解析
        var pr = _parse_int(status_str)
        if not pr[0]:
            raise Error("exceptions: bad status code in _error_map: " + status_str)
        var code = pr[1]
        var detail = _render_template(detail_tpl, ctx)
        return HTTPExceptionSpec(code, standard_status_line(code), detail)

    return HTTPExceptionSpec(0, "", "")


# ---------- 注册 helpers ----------

def set_error_map(mut handler: Handler, error_map: String) raises:
    """注册时校验 _error_map 格式 (避免 hot path 失败)."""
    if error_map == "":
        return
    var entries = _split_top_level(error_map, 59)
    for e_idx in range(len(entries)):
        var entry = entries[e_idx]
        var n = entry.byte_length()
        var c1 = -1
        for i in range(n):
            if ord(entry[byte=i]) == 58:
                c1 = i
                break
        var c2 = -1
        for i in range(c1 + 1, n):
            if ord(entry[byte=i]) == 58:
                c2 = i
                break
        if c1 < 0 or c2 < 0 or c2 == c1 + 1 or c2 == n - 1:
            raise Error("exceptions: bad _error_map entry (need key=status:detail): " + entry)
        var status_str = String(entry[byte=c1 + 1:c2])
        var pr = _parse_int(status_str)
        if not pr[0] or pr[1] < 100 or pr[1] >= 600:
            raise Error("exceptions: bad status code in _error_map: " + status_str)
        var kv = String(entry[byte=0:c1])
        var eq = -1
        for i in range(kv.byte_length()):
            if ord(kv[byte=i]) == 61:
                eq = i
                break
        if eq < 0:
            raise Error("exceptions: bad _error_map key=value: " + kv)
    handler.data["_error_map"] = error_map
