# mw_spec.mojo — 用户自定义中间件: spec 解析/校验 + 请求面计划 (决策-55, ADR-0030).
#
# 声明式 env `FASTAPI_MOJO_MIDDLEWARE` (Mojo 1.0.0 无闭包 —
# `@app.middleware("http")` / `BaseHTTPMiddleware` 等价; GZip 决策-40 /
# CORS 决策-42 / 异常 handler 决策-49 先例):
#
#   FASTAPI_MOJO_MIDDLEWARE="<mw1>;<mw2>;...;<mwN>"
#     <mwK>  = "<verb1>,<verb2>,..."      (书写序 = 执行序)
#     <verb> = "NAME[:A[:B[:C]]]"         (位置字段, `:` 分隔)
#
# 栈序 (上游活体探测 P-MW-1/2, fastapi 0.141.1): mw1 = 先添加 = innermost,
# mwN = 后添加 = outermost. **请求面** (本模块) 执行 outermost→innermost
# (env 逆序), 在 dispatch 读完全量字段后、OPTIONS/WS/路由分派前;
# **响应面** (HDR/STATUS/BODY/LOG) 在 bridge `send_response` 单点执行
# innermost→outermost (env 正序), GZip 前. 短路 (BLOCK 于 mwK): 响应仅过
# mwK+1..mwN (外层) 响应动词 (bridge `plan_request_path` 判定, ADR-0030 §3.2).
#
# 请求面动词:
#   MAP:FROM:TO          路径重写 (P-MW-7 `scope["path"]` 等价).
#   REQHDR:NAME:VALUE    合成请求头注入 (FFI inject_request_header).
#   BLOCK:STATUS:BODY:PATHS  早期响应 / 短路 (P-MW-3).
#
# 纯模块 (FFI 仅在 dispatch 调用点); selftest main() FFI-free
# (CI 普通 mojo run 循环可跑, 无需 JIT 桩).
#
# Mojo 1.0.0 结构约定: 含 String/List 字段的 struct 需显式 __init__
# (不可零初始化); 列表元素拷贝用显式 copy() (house 同款, middleware.mojo).

from std.os import abort

# ---------- 结构 ----------

struct Mw:
    """单个中间件单元: req/resp = 动词的逗号分隔串 (书写序)."""
    var req: String
    var resp: String

    def __init__(out self):
        self.req = ""
        self.resp = ""

    def copy(self) -> Mw:
        var m = Mw()
        m.req = self.req
        m.resp = self.resp
        return m^

struct MWSpec:
    """解析后的 spec: mws (mw0=innermost ... mwN-1=outermost) + err."""
    var mws: List[Mw]
    var err: String

    def __init__(out self):
        self.mws = List[Mw]()
        self.err = ""

struct MwRq:
    """请求面计划结果 (outermost→innermost 求值, 短路即停):
    path = MAP 重写后的路径; block_status/block_body = 命中的 BLOCK (空=无);
    req_hdr_names/req_hdr_vals = 收集到的合成头 (outermost→innermost 序)."""
    var path: String
    var block_status: String
    var block_body: String
    var req_hdr_names: List[String]
    var req_hdr_vals: List[String]

    def __init__(out self):
        self.path = ""
        self.block_status = ""
        self.block_body = ""
        self.req_hdr_names = List[String]()
        self.req_hdr_vals = List[String]()

# ---------- 字符串工具 (byte 域, 与 house 约定一致) ----------

def _substring(s: String, start: Int, end: Int) -> String:
    var a = start
    var e = end
    if e > s.byte_length():
        e = s.byte_length()
    if a < 0:
        a = 0
    if a >= e:
        return ""
    return String(s[byte=a:e])

def _trim(s: String) -> String:
    var b = 0
    var e = s.byte_length()
    while b < e and (ord(s[byte=b]) == 32 or ord(s[byte=b]) == 9):
        b += 1
    while e > b and (ord(s[byte=e - 1]) == 32 or ord(s[byte=e - 1]) == 9):
        e -= 1
    return _substring(s, b, e)

def _upper(s: String) -> String:
    var out = String("")
    var tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    var i = 0
    while i < s.byte_length():
        var c = ord(s[byte=i])
        if c >= 97 and c <= 122:
            out += String(tbl[byte=(c - 97):(c - 96)])
        else:
            out += _substring(s, i, i + 1)
        i += 1
    return out

def _split(s: String, sep: String) -> List[String]:
    var out = List[String]()
    var st = 0
    var i = 0
    while i <= s.byte_length():
        var is_sep = (i == s.byte_length()) or (_substring(s, i, i + 1) == sep)
        if is_sep:
            if i > st:
                var seg = _trim(_substring(s, st, i))
                if seg.byte_length() > 0:
                    out.append(seg)
            st = i + 1
        i += 1
    return out^

def _starts_with(s: String, prefix: String) -> Bool:
    if prefix.byte_length() > s.byte_length():
        return False
    return _substring(s, 0, prefix.byte_length()) == prefix

def _ends_with(s: String, suffix: String) -> Bool:
    if suffix.byte_length() > s.byte_length():
        return False
    return _substring(s, s.byte_length() - suffix.byte_length(), s.byte_length()) == suffix

# ---------- 校验 ----------

def _check_value(v: String, allow_bar: Bool) -> String:
    """值内禁止结构分隔符; 返回 "" = OK, 否则错误消息."""
    var i = 0
    while i < v.byte_length():
        var c = ord(v[byte=i])
        if c == 59 or c == 44 or c == 58 or (c == 124 and not allow_bar):
            return "value '" + v + "' contains a reserved separator"
        i += 1
    return ""

def _is_code3(s: String) -> Bool:
    if s.byte_length() != 3:
        return False
    var i = 0
    while i < 3:
        if not (ord(s[byte=i]) >= 48 and ord(s[byte=i]) <= 57):
            return False
        i += 1
    return True

def _validate_verb(v: String) -> String:
    """单动词校验; 返回 "" = OK, 否则错误消息."""
    if v.byte_length() == 0:
        return "empty verb entry"
    var parts = _split(v, ':')
    var tag = _upper(parts[0])
    var n = len(parts)
    if tag == "LOG":
        if n != 1:
            return "LOG takes no arguments: " + v
        return ""
    if tag == "HDR" or tag == "REQHDR":
        if n != 3:
            return tag + " needs NAME:VALUE (3 fields): " + v
        if parts[1].byte_length() == 0:
            return tag + " needs a non-empty name: " + v
        var e = _check_value(parts[2], False)
        if e != "":
            return tag + ": " + e
        return ""
    if tag == "STATUS":
        if n != 3:
            return "STATUS needs FROM:TO (3 fields): " + v
        if parts[1] != "*" and not _is_code3(parts[1]):
            return "STATUS FROM must be 3-digit code or '*': " + v
        if not _is_code3(parts[2]):
            return "STATUS TO must be 3-digit code: " + v
        return ""
    if tag == "BODY":
        if n != 2:
            return "BODY needs a template: " + v
        if parts[1].byte_length() == 0:
            return "BODY needs a non-empty template: " + v
        var e = _check_value(parts[1], False)
        if e != "":
            return "BODY: " + e
        return ""
    if tag == "MAP":
        if n != 3:
            return "MAP needs FROM:TO (3 fields): " + v
        if not parts[1].startswith("/") or parts[1] == "/" or not parts[2].startswith("/"):
            return "MAP needs absolute paths (FROM != '/'): " + v
        return ""
    if tag == "BLOCK":
        if n != 4:
            return "BLOCK needs STATUS:BODY:PATHS (4 fields): " + v
        if not _is_code3(parts[1]):
            return "BLOCK status must be 3-digit: " + v
        if parts[2].byte_length() == 0:
            return "BLOCK needs a non-empty body: " + v
        var e = _check_value(parts[2], False)
        if e != "":
            return "BLOCK body: " + e
        var paths = _split(parts[3], '|')
        if len(paths) == 0:
            return "BLOCK needs at least one path (or '*'): " + v
        var k = 0
        while k < len(paths):
            if paths[k] != "*" and not paths[k].startswith("/"):
                return "BLOCK path '" + paths[k] + "' must be '*' or absolute"
            k += 1
        return ""
    return "unknown verb '" + parts[0] + "'"

# ---------- 解析 ----------

def parse_mw_spec(s: String) -> MWSpec:
    var spec = MWSpec()
    var t = _trim(s)
    if t.byte_length() == 0:
        return spec^
    var mw_list = _split(t, ';')
    var i = 0
    while i < len(mw_list):
        var mw = Mw()
        var vlist = _split(mw_list[i], ',')
        var j = 0
        while j < len(vlist):
            var v = vlist[j]
            var e = _validate_verb(v)
            if e != "":
                spec.err = e
                return spec^
            var tag = _upper(_split(v, ':')[0])
            if tag == "MAP" or tag == "REQHDR" or tag == "BLOCK":
                if mw.req.byte_length() > 0:
                    mw.req = mw.req + ","
                mw.req = mw.req + v
            else:
                if mw.resp.byte_length() > 0:
                    mw.resp = mw.resp + ","
                mw.resp = mw.resp + v
            j += 1
        if mw.req.byte_length() > 0 or mw.resp.byte_length() > 0:
            spec.mws.append(mw.copy())
        i += 1
    return spec^

def check_mw_spec(s: String) -> Bool:
    """启动期 fail-fast (check_* 同策略): 畸形 → 打印 + False (main abort)."""
    var spec = parse_mw_spec(s)
    if spec.err.byte_length() > 0:
        print("ERROR: FASTAPI_MOJO_MIDDLEWARE: " + spec.err)
        return False
    return True

# ---------- 插值 ----------

def _try_tok(t: String, i: Int, name: String) -> Bool:
    var nl = name.byte_length()
    if i + nl + 2 > t.byte_length():
        return False
    if _substring(t, i, i + 1) != "{":
        return False
    if _substring(t, i + 1, i + 1 + nl) != name:
        return False
    return _substring(t, i + 1 + nl, i + 2 + nl) == "}"

def mw_interp(t: String, method: String, path: String, query: String, status: String, req_id: String) -> String:
    """`{method}{path}{query}{status}{req_id}` 单次扫描插值; 未知 `{...}` 保留字面."""
    var out = String("")
    var i = 0
    var n = t.byte_length()
    while i < n:
        var ch = _substring(t, i, i + 1)
        if ch == "{":
            var adv = 0
            if _try_tok(t, i, "method"):
                out += method
                adv = 8
            elif _try_tok(t, i, "path"):
                out += path
                adv = 6
            elif _try_tok(t, i, "query"):
                out += query
                adv = 7
            elif _try_tok(t, i, "status"):
                out += status
                adv = 8
            elif _try_tok(t, i, "req_id"):
                out += req_id
                adv = 8
            if adv == 0:
                out += ch
                adv = 1
            i += adv
        else:
            out += ch
            i += 1
    return out

# ---------- 请求面计划 (镜像 bridge plan_request_path: 同算法保两侧一致) ----------

def _map_path(p: String, frm: String, dst: String) -> String:
    if p == frm:
        return dst
    var prefix = frm + "/"
    if _starts_with(p, prefix):
        var rest = _substring(p, prefix.byte_length(), p.byte_length())
        if _ends_with(dst, "/"):
            return dst + rest
        return dst + "/" + rest
    return p

def _block_match(path: String, paths: List[String]) -> Bool:
    var k = 0
    while k < len(paths):
        if paths[k] == "*":
            return True
        if _ends_with(paths[k], "/"):
            if _starts_with(path, paths[k]):
                return True
        elif path == paths[k]:
            return True
        k += 1
    return False

def mw_plan_request(spec: MWSpec, method: String, path: String, query: String, req_id: String) -> MwRq:
    """请求面: outermost → innermost (env 逆序); 单 mw 内按书写序.
    BLOCK 命中即返回 (短路: 更内层不再执行; 响应面由 bridge `plan_request_path`
    判定 "仅外层响应动词"). 返回: path (MAP 重写后) / block_status / block_body /
    合成头对 (req_hdr_names/req_hdr_vals). 纯函数 (spec 按值借读, 不改)."""
    var r = MwRq()
    r.path = path
    var n = len(spec.mws)
    var i = n - 1
    while i >= 0:
        var req_str = spec.mws[i].req
        var vlist = _split(req_str, ',')
        var j = 0
        while j < len(vlist):
            var parts = _split(vlist[j], ':')
            var tag = _upper(parts[0])
            if tag == "MAP":
                r.path = _map_path(r.path, parts[1], parts[2])
            elif tag == "REQHDR":
                var hn = parts[1]
                var hv = parts[2]
                r.req_hdr_names.append(hn)
                r.req_hdr_vals.append(hv)
            elif tag == "BLOCK":
                var paths = _split(parts[3], '|')
                if _block_match(r.path, paths):
                    r.block_status = parts[1]
                    r.block_body = mw_interp(parts[2], method, r.path, query, parts[1], req_id)
                    return r^
            j += 1
        i -= 1
    return r^

# ---------- selftest (FFI-free; CI 普通 mojo run 循环) ----------

def _expect(cond: Bool, msg: String):
    if not cond:
        print("MW-SPEC FAIL: " + msg)
        abort()
    print("ok: " + msg)

def main() raises:
    print("mw_spec selftest (决策-55 / ADR-0030, FFI-free)...")
    var n_ok = 0

    # 1. 解析: 3 中间件, req/resp 归类
    var s1b = parse_mw_spec("HDR:X:1,LOG;MAP:/old:/new;BLOCK:418:tp:*")
    _expect(len(s1b.mws) == 3 and s1b.err == "", "1. parse 3 mws")
    _expect(s1b.mws[0].resp == "HDR:X:1,LOG" and s1b.mws[0].req == "", "1b. mw0 resp")
    _expect(s1b.mws[1].req == "MAP:/old:/new" and s1b.mws[1].resp == "", "1c. mw1 req")
    _expect(s1b.mws[2].req == "BLOCK:418:tp:*", "1d. mw2 req")
    n_ok += 1

    # 2. 空 spec = 零中间件
    var s2 = parse_mw_spec("   ")
    _expect(len(s2.mws) == 0 and s2.err == "", "2. empty spec")
    n_ok += 1

    # 3. 未知动词
    var s3 = parse_mw_spec("FROB:x")
    _expect(s3.err.byte_length() > 0 and len(s3.mws) == 0, "3. unknown verb rejected")
    n_ok += 1

    # 4. 值含 ':' (4 字段)
    var s4 = parse_mw_spec("HDR:A:B:C")
    _expect(s4.err.byte_length() > 0, "4. reserved ':' in value rejected")
    n_ok += 1

    # 5. 非 3 位状态码
    var s5 = parse_mw_spec("STATUS:21:300")
    _expect(s5.err.byte_length() > 0, "5. 2-digit status rejected")
    n_ok += 1

    # 6-8. MAP (无 BLOCK 干扰, 2 mw: mw0 resp / mw1 MAP)
    var s1 = parse_mw_spec("HDR:X:1,LOG;MAP:/old:/new")
    var p6 = mw_plan_request(s1, "GET", "/old", "", "req-1")
    _expect(p6.path == "/new", "6. MAP exact /old -> /new (got " + p6.path + ")")
    n_ok += 1
    var p7 = mw_plan_request(s1, "GET", "/old/x", "", "req-1")
    _expect(p7.path == "/new/x", "7. MAP prefix /old/x -> /new/x (got " + p7.path + ")")
    n_ok += 1
    var p8 = mw_plan_request(s1, "GET", "/other", "", "req-1")
    _expect(p8.path == "/other", "8. MAP no-match unchanged")
    n_ok += 1

    # 9. BLOCK 命中 (s1b 的 mw2 BLOCK:418:tp:*) — 请求 /anything 命中 *
    var p9 = mw_plan_request(s1b, "GET", "/anything", "", "req-9")
    _expect(p9.block_status == "418", "9a. BLOCK matched (418)")
    _expect(p9.block_body == "tp", "9b. BLOCK body (got " + p9.block_body + ")")
    n_ok += 1

    # 10. BLOCK 前缀 + 插值: /secret/ 前缀, BODY 含 {method}{path}
    var s10 = parse_mw_spec("BLOCK:403:denied {method} {path}:/secret/")
    var p10 = mw_plan_request(s10, "GET", "/secret/x", "", "req-2")
    _expect(p10.block_body == "denied GET /secret/x", "10. BLOCK interp (got " + p10.block_body + ")")
    n_ok += 1

    print("mw_spec selftest passed: 10/10")
