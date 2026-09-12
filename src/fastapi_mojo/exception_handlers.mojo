# src/fastapi_mojo/exception_handlers.mojo
#
# 决策-49 (ADR-0024, Goal-0003 矩阵 #13): 任意异常类型 handler.
#
# Mojo 1.0.0 异常面 (P13-M1..M8 探测):
#   - 异常类型仅一个 = Error (无子类/别名/内省, P13-M2/M5)
#   - try/except; String(e) 返回被捕获 Error 的 message (P13-M4)
#   - std.os.getenv 原生可读 (P13-M7)
#   - try 块内声明的变量在 except 块不可见 (P13-M6)
#   - 含 String 字段的 struct 无自动无参构造 (须显式 __init__)
# 故"异常类型"用字符串 tag 约定承载:
#       raise Error("TAG: message")
# handler 表 (声明式, 同 TAG 后者胜 — 上游 P13-2):
#   全局:  env FASTAPI_MOJO_EXCEPTION_HANDLERS = "TAG:STATUS:BODY[:json];..."
#   路由:  handler.data["_exc_handlers"] = 同格式 (整体替换, 超集 — §3.5-7)
# 声明式 raise 钩子 (上游 endpoint body 抛异常的位置, P13-9):
#   handler.data["_exception_raise"] = "TAG: message"
# 查找顺序 (模拟上游双层 map, P13-9):
#   精确 tag -> "Exception" catch-all (= 500/Exception 键) -> 默认 500
#   (text/plain "Internal Server Error", P13-10 逐字 parity)

from std.os import getenv

from handler import Handler, ServerInfo, run_handler
from params_query import ParsedParams
from exceptions import standard_status_line
from middleware import _json_escape


struct GuardResult:
    """guarded_run_handler 结果.

    is_exc=False -> status_line/resp_data = run_handler 正常响应 (语义不变);
    is_exc=True  -> status_line/body/is_json = 异常 handler 响应
                    (resp_data 未用, 保持空).
    """
    var is_exc: Bool
    var status_line: String
    var resp_data: Dict[String, String]
    var body: String
    var is_json: Bool
    # 决策-74 (ADR-0049): 异常响应自定义头 (\r\n 分隔 "Name: value" 行; 空 = 无).
    # 声明式 _exc_headers / FASTAPI_MOJO_EXCEPTION_HEADERS.
    var extra: String

    def __init__(out self):
        self.is_exc = False
        self.status_line = ""
        self.resp_data = Dict[String, String]()
        self.body = ""
        self.is_json = False
        self.extra = ""


def _split_exc_msg(msg: String) -> Tuple[String, String]:
    """第一个 ':' 切分 -> (tag, message). 无 ':' -> ("", 全消息).

    第一个冒号而非最后一个: tag 约定在消息最前; message 自由文本
    (可再含冒号, 如 "oops: a:b" -> tag="oops", msg="a:b").
    """
    var n = msg.byte_length()
    var i = 0
    while i < n:
        if ord(msg[byte=i]) == 58:  # ':'
            var j = i + 1
            while j < n and ord(msg[byte=j]) == 32:  # 跳过 "TAG: " 的空白
                j += 1
            var rest = ""
            if j < n:
                rest = String(msg[byte=j:n])
            return (String(msg[byte=0:i]), rest)
        i += 1
    return ("", msg)


def _entry_colons(entry: String) -> Tuple[Int, Int]:
    """前两个 ':' 的字节下标 (找不到 -> -1)."""
    var n = entry.byte_length()
    var c1 = -1
    var c2 = -1
    var i = 0
    while i < n:
        if ord(entry[byte=i]) == 58:
            if c1 < 0:
                c1 = i
            else:
                c2 = i
                break
        i += 1
    return (c1, c2)


def _parse_entry(entry: String) -> Bool:
    """校验单条目 "TAG:STATUS:BODY[:json]".

    TAG 非空; STATUS 恰 3 位数字; BODY 非空 (第 2 个冒号之后全部,
    可再含冒号); 尾部 ":json" = JSON 发送标志 (body 恰为 ":json" =
    空 body, 非法).
    """
    var (c1, c2) = _entry_colons(entry)
    if c1 <= 0 or c2 < 0:
        return False
    var status_str = String(entry[byte=c1 + 1:c2])
    if status_str.byte_length() != 3:
        return False
    var k = 0
    while k < 3:
        var b = ord(status_str[byte=k])
        if b < 48 or b > 57:  # 非 ASCII 数字
            return False
        k += 1
    var n = entry.byte_length()
    var raw = ""
    if n > c2 + 1:
        raw = String(entry[byte=c2 + 1:n])
    var rb = raw.byte_length()
    if rb >= 5 and String(raw[byte=rb - 5:rb]) == ":json":
        if rb == 5:
            return False  # body 恰为 ":json" -> 空 body 非法
        var tmp = String(raw[byte=0:rb - 5])
        raw = tmp
    return raw != ""


def _entry_fields(entry: String) -> Tuple[Int, String, Bool]:
    """已校验条目 -> (status, body_tpl, is_json). body_tpl 可再含冒号;
    尾部 ":json" 剥除."""
    var (c1, c2) = _entry_colons(entry)
    var status_str = String(entry[byte=c1 + 1:c2])
    var d = 0
    var k = 0
    while k < 3:
        d = d * 10 + (ord(status_str[byte=k]) - 48)
        k += 1
    var n = entry.byte_length()
    var is_json = False
    var raw = ""
    if n > c2 + 1:
        raw = String(entry[byte=c2 + 1:n])
    var rb = raw.byte_length()
    if rb >= 5 and String(raw[byte=rb - 5:rb]) == ":json":
        is_json = True
        if rb > 5:
            var tmp = String(raw[byte=0:rb - 5])
            raw = tmp
        else:
            raw = ""
    return (d, raw, is_json)


def parse_exc_table(spec: String) -> Dict[String, String]:
    """';' 分隔条目 -> **tag -> 原条目串** 表; 同 TAG 后者胜 (P13-2).

    非法条目静默跳过: env 是进程级配置, 单条畸形不应拖垮整表 — 其
    tag 退化为未处理路径 (500, 行为可见, 不静默吞).
    """
    var out = Dict[String, String]()
    var n = spec.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(spec[byte=i]) == 59)  # ';'
        if is_sep:
            if i > start:
                var es = String(spec[byte=start:i])
                if _parse_entry(es):
                    var (tag, _) = _split_exc_msg(es)
                    out[tag] = es  # 覆盖 = 后者胜
            start = i + 1
        i += 1
    return out^


def load_exc_table(handler: Handler) raises -> Dict[String, String]:
    """路由级 `_exc_handlers` 存在时整体替换全局表 (超集, §3.5-7),
    否则读 env FASTAPI_MOJO_EXCEPTION_HANDLERS (std.os.getenv, P13-M7)."""
    var raw = getenv("FASTAPI_MOJO_EXCEPTION_HANDLERS")
    if "_exc_handlers" in handler.data:
        raw = handler.data["_exc_handlers"]
    return parse_exc_table(raw)


def _has_colon(s: String) -> Bool:
    """头行须含 ':' (Name: Value)."""
    var n = s.byte_length()
    for i in range(n):
        if ord(s[byte=i]) == 58:
            return True
    return False


def parse_exc_headers(spec: String) -> Dict[String, String]:
    """决策-74 (ADR-0049): ';' 分隔 `TAG=H1|H2` 条目 -> tag -> "\r\n" 分隔头行.

    H1/H2 = "Name: Value" ('|' 分隔多头); 非法条目 (无 '=' / 空 tag / 头无 ':')
    静默跳过 (与 parse_exc_table 同款容错). 头值内含 '|' / ';' 不支持 (文档化).
    """
    var out = Dict[String, String]()
    var n = spec.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(spec[byte=i]) == 59)  # ';'
        if is_sep:
            if i > start:
                var es = String(spec[byte=start:i])
                var eq = -1
                var m = es.byte_length()
                var k = 0
                while k < m:
                    if ord(es[byte=k]) == 61:  # '='
                        eq = k
                        break
                    k += 1
                if eq > 0:
                    var tag = String(es[byte=0:eq])
                    var hlist = ""
                    if m > eq + 1:
                        hlist = String(es[byte=eq + 1:m])
                    var hb = ""
                    var hn = hlist.byte_length()
                    var hs = 0
                    var j = 0
                    while j <= hn:
                        var hsep = (j == hn) or (ord(hlist[byte=j]) == 124)  # '|'
                        if hsep:
                            if j > hs:
                                var one = String(hlist[byte=hs:j])
                                if _has_colon(one):
                                    if hb.byte_length() > 0:
                                        hb += "\r\n"
                                    hb += one
                            hs = j + 1
                        j += 1
                    if hb.byte_length() > 0:
                        out[tag] = hb
            start = i + 1
        i += 1
    return out^


def load_exc_headers(handler: Handler) raises -> Dict[String, String]:
    """路由级 `_exc_headers` 存在时整体替换全局 env FASTAPI_MOJO_EXCEPTION_HEADERS
    (与 load_exc_table 同款: 路由级 = 超集, §3.5-7)."""
    var raw = getenv("FASTAPI_MOJO_EXCEPTION_HEADERS")
    if "_exc_headers" in handler.data:
        raw = handler.data["_exc_headers"]
    return parse_exc_headers(raw)


def _substitute(tpl: String, tag: String, msg: String) -> String:
    """替换全部 "{exc}" / "{tag}" (Mojo 1.0.0 无 format 内建, 手动扫描)."""
    var out = ""
    var n = tpl.byte_length()
    var i = 0
    while i < n:
        if i + 5 <= n and String(tpl[byte=i:i + 5]) == "{exc}":
            out += msg
            i += 5
            continue
        if i + 5 <= n and String(tpl[byte=i:i + 5]) == "{tag}":
            out += tag
            i += 5
            continue
        out += chr(ord(tpl[byte=i]))
        i += 1
    return out


def _log_exc(tag: String, status_line: String, msg: String, is_specific: Bool):
    """P13-8 quirk 模拟: 具体 tag 命中 -> 单行 (上游: 无 traceback);
    Exception catch-all / 未处理 -> 完整 message 行 (上游: 仍打全 traceback,
    Mojo 无 traceback 机制 — 线形对等)."""
    if is_specific:
        print("[exc] " + tag + " handled -> " + status_line)
    else:
        var t = tag
        if t == "":
            t = "<untagged>"
        print("[exc] " + t + " -> " + status_line + " | msg: " + msg)


def resolve_exception_response(msg: String, handler: Handler) raises -> GuardResult:
    """raised 异常 -> 响应. 查找: 精确 tag -> Exception catch-all -> 默认 500
    (P13-10: text/plain "Internal Server Error")."""
    var (tag, rest) = _split_exc_msg(msg)
    var table = load_exc_table(handler)
    var out = GuardResult()
    out.is_exc = True
    var has_exact = tag in table
    var has_catchall = "Exception" in table
    var raw = ""
    var is_specific = True
    var hkey = ""
    if has_exact:
        raw = table[tag]
        hkey = tag
    elif has_catchall:
        raw = table["Exception"]
        is_specific = False
        hkey = "Exception"
    if raw != "":
        var (st, tpl, isj) = _entry_fields(raw)
        var vt = tag
        var vm = rest
        if isj:
            vt = _json_escape(vt)
            vm = _json_escape(vm)
        out.body = _substitute(tpl, vt, vm)
        out.status_line = standard_status_line(st)
        out.is_json = isj
        # 决策-74 (ADR-0049): 命中 tag (或 catch-all) 的声明式自定义头.
        var htab = load_exc_headers(handler)
        if hkey in htab:
            out.extra = htab[hkey]
        _log_exc(tag, out.status_line, msg, is_specific)
    else:
        # 未处理: 上游 ServerErrorMiddleware 默认 = 500 PlainText (P13-10)
        out.status_line = "500 Internal Server Error"
        out.body = "Internal Server Error"
        out.is_json = False
        _log_exc(tag, out.status_line, msg, False)
    return out^


def guarded_run_handler(handler: Handler, path_params: Dict[String, String],
                        query: ParsedParams, body: ParsedParams,
                        info: ServerInfo) raises -> GuardResult:
    """路由级 try/except guard (= 上游 route wrap_app_handling_exceptions).

    评估顺序: 声明式 _exception_raise 钩子 (endpoint body 抛异常的位置,
    在 Depends 之后) -> run_handler. 捕获任意 Error ->
    resolve_exception_response (String(e) 取 message, P13-M4).
    正常路径 (is_exc=False) 行为与直接调 run_handler 逐字节一致.
    """
    var out = GuardResult()
    try:
        if "_exception_raise" in handler.data:
            raise Error(handler.data["_exception_raise"])
        var r = run_handler(handler, path_params, query, body, info)
        out.is_exc = False
        out.status_line = r[0]
        out.resp_data = r[1].copy()
        return out^
    except e:
        return resolve_exception_response(String(e), handler)
