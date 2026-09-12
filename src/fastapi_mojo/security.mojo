# src/fastapi_mojo/security.mojo
#
# 决策-34 (Goal-0003 P0): FastAPI 安全 / 认证 (API security).
#
# 对标 FastAPI `fastapi.security` 三大基础认证:
#   - HTTPBasic   : Authorization: Basic base64(user:pass)
#   - HTTPBearer  : Authorization: Bearer <token>
#   - APIKey      : header / query / cookie 三位置携带 key
#
# 声明式 (与 ADR-0004 run_handler 模式一致):
#   Handler.data["_auth"] =
#       "basic"                         -> HTTPBasic (需 _auth_users)
#       "bearer"                        -> HTTPBearer (需 _auth_tokens)
#       "apikey:header:<name>"          -> APIKey 从 header <name>
#       "apikey:query:<name>"           -> APIKey 从 query ?<name>=
#       "apikey:cookie:<name>"          -> APIKey 从 Cookie <name>
#   Handler.data["_auth_users"]  = "admin:secret;user:pass123"   (basic: user:pass CSV)
#   Handler.data["_auth_tokens"] = "tok1;tok2"                    (bearer/apikey: 允许的 key/token CSV)
#   Handler.data["_auth_realm"]  = "MyRealm"                       (可选, WWW-Authenticate realm)
#
# 语义 (对齐 FastAPI/Starlette):
#   - 校验失败 -> 401 + WWW-Authenticate (basic/bearer); apikey 无 WWW-Authenticate (RFC 无标准).
#   - 校验成功 -> 注入 params: auth_user (basic) / auth_token (bearer) / auth_apikey (apikey).
#   - Authorization 头缺失 / 前缀错误 / 凭据错误 -> 一律 401 (不泄露"缺凭据还是错凭据").
#
# 显式 dispatch 扩展点: check_auth 单一函数; 新增认证 = 本文件加一个 elif (对齐 run_handler).
#
# Mojo 1.0.0 约束: 无 match -> if/elif; 无闭包; base64 解码纯 Mojo 实现
#   (base64 属协议层, 归 Mojo; 字节级 I/O 才归 Rust bridge — ADR-0010 分层).

from handler import Handler
from string_builder import StringBuilder, span_to_str, next_codepoint_len
from std.ffi import external_call, CStringSlice


# ---------- 字节子串 (StringSpan -> String, 供前缀/切片用) ----------

def _bstr(s: String, start: Int, end: Int) -> String:
    """按字节 [start, end) 切 s -> String. start/end 越界则截断到合法范围."""
    var n = s.byte_length()
    var a = start
    var b = end
    if a < 0:
        a = 0
    if b > n:
        b = n
    if b < a:
        b = a
    return String(s[byte=a:b])


def _starts_with(s: String, p: String) -> Bool:
    """s 是否以 p 开头 (按字节)."""
    if s.byte_length() < p.byte_length():
        return False
    var i = 0
    while i < p.byte_length():
        if s[byte=i] != p[byte=i]:
            return False
        i += 1
    return True


# ---------- base64 解码 (纯 Mojo, HTTPBasic 需要) ----------

def _eq_ci(s: String, lower: String) -> Bool:
    """s 与全小写字面量 lower 的大小写不敏感相等 (ASCII)."""
    if s.byte_length() != lower.byte_length():
        return False
    var i = 0
    while i < s.byte_length():
        var a = ord(s[byte=i])
        if a >= 65 and a <= 90:
            a += 32
        if a != ord(lower[byte=i]):
            return False
        i += 1
    return True


def _b64_val(c: Int) -> Int:
    """base64 字符 -> 6-bit 值; 非字母表 (含 padding '=') -> -1.
    兼容标准 (+/) 与 URL-safe (-_) 两种字母表 (RFC 4648)."""
    if c >= 65 and c <= 90:
        return c - 65          # A-Z
    if c >= 97 and c <= 122:
        return c - 71          # a-z
    if c >= 48 and c <= 57:
        return c + 4           # 0-9 (0=52,1=53,...,9=61)
    if c == 43:
        return 62              # +
    if c == 47:
        return 63              # /
    if c == 45:
        return 62              # - (URL-safe)
    if c == 95:
        return 63              # _ (URL-safe)
    return -1


def b64_decode(s: String) -> String:
    """标准 base64 -> 原始字节 (UTF-8 容器; HTTPBasic 的 user:pass 语义是 ASCII).
    跳过空白与 '='; 未知字符忽略 (对齐 decode ignore_invalid 行为)."""
    var sb = StringBuilder()
    var val = 0
    var bits = 0
    var n = s.byte_length()
    for i in range(n):
        var c = ord(s[byte=i])
        if c == 61:            # '=' padding
            break
        if c == 13 or c == 10 or c == 32 or c == 9:   # 跳过空白
            continue
        var v = _b64_val(c)
        if v < 0:
            continue
        val = (val << 6) | v
        bits += 6
        if bits >= 8:
            bits -= 8
            sb.append_byte((val >> bits) & 255)
            # mask val 到 pending bits (丢弃已消费的高位, 防 64-bit Int 溢出)
            val = val & ((1 << bits) - 1)
    return sb.take()


# ---------- 认证结果 ----------

struct AuthResult:
    """认证结果. ok=False -> 401 (status_line/detail/www_authenticate 已填).
    ok=True  -> 至少一个 auth_* 字段非空 (注入 params)."""
    var ok: Bool
    var status_line: String        # "401 Unauthorized"
    var detail: String             # 响应 body 的 detail 字段
    var www_authenticate: String   # 响应头值 (basic/bearer 非空; apikey 空)
    var auth_user: String          # basic: 用户名
    var auth_token: String         # bearer: token
    var auth_apikey: String        # apikey: key
    var auth_scheme: String        # digest: Authorization scheme (原样大小写)
    var auth_credentials: String   # digest: credentials 部分

    def __init__(out self):
        self.ok = False
        self.status_line = "401 Unauthorized"
        self.detail = "Not authenticated"
        self.www_authenticate = ""
        self.auth_user = ""
        self.auth_token = ""
        self.auth_apikey = ""
        self.auth_scheme = ""
        self.auth_credentials = ""


def _realm_part(realm: String) -> String:
    """WWW-Authenticate 的 realm 片段: 有 realm -> ' realm="X"', 无 -> 空."""
    if realm == "":
        return ""
    return ' realm="' + realm + '"'


# ---------- 读取请求头 (FFI, 复用既有 extract_request_header/get_header_value_slice) ----------

def _get_header(name: String) -> String:
    """读取请求头值; 不存在/空 -> ""."""
    var n = name   # 局部可变更绑定 (参数是 rvalue, 不能直接调 mutating as_c_string_slice)
    var rc = external_call["extract_request_header", Int](n.as_c_string_slice())
    if rc != 0:
        return ""
    var sl = external_call["get_header_value_slice", CStringSlice[origin_of(String(""))]]()
    return span_to_str(sl.as_bytes())


def _split_csv(s: String, sep: Int) -> List[String]:
    """按 sep (ord) 切 CSV, 去首尾空白. sep 默认 ';' (59)."""
    var out = List[String]()
    var n = s.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(s[byte=i]) == sep)
        if is_sep:
            if i > start:
                var seg = _bstr(s, start, i)
                var b = 0
                var e = seg.byte_length()
                while b < e and (ord(seg[byte=b]) == 32 or ord(seg[byte=b]) == 9):
                    b += 1
                while e > b and (ord(seg[byte=e-1]) == 32 or ord(seg[byte=e-1]) == 9):
                    e -= 1
                if e > b:
                    out.append(_bstr(seg, b, e))
            start = i + 1
        i += 1
    return out^


def _trim(s: String) -> String:
    """去首尾空白 (空格/tab)."""
    var b = 0
    var e = s.byte_length()
    while b < e and (ord(s[byte=b]) == 32 or ord(s[byte=b]) == 9):
        b += 1
    while e > b and (ord(s[byte=e-1]) == 32 or ord(s[byte=e-1]) == 9):
        e -= 1
    return _bstr(s, b, e)


# ---------- 认证主体 (单一 dispatch 扩展点) ----------

def check_auth(handler: Handler, query_values: Dict[String, String]) raises -> AuthResult:
    """按 handler.data["_auth"] 声明校验请求凭据.

    返回 AuthResult: ok=False -> 401; ok=True -> auth_* 字段供 dispatch 注入 params.
    新增认证类型 = 这里加一个 elif (与 run_handler 同模式).
    """
    var auth_spec = ""
    if "_auth" in handler.data:
        auth_spec = handler.data["_auth"]
    if auth_spec == "":
        var r = AuthResult()
        r.ok = True
        return r^

    var realm = ""
    if "_auth_realm" in handler.data:
        realm = handler.data["_auth_realm"]

    # ---- HTTPBasic ----
    if auth_spec == "basic":
        var users_csv = ""
        if "_auth_users" in handler.data:
            users_csv = handler.data["_auth_users"]
        var authz = _get_header("Authorization")
        if not _starts_with(authz, "Basic "):
            var f1 = AuthResult()
            f1.ok = False
            f1.detail = "Not authenticated"
            f1.www_authenticate = "Basic" + _realm_part(realm)
            return f1^
        var cred = b64_decode(_bstr(authz, 6, authz.byte_length()))
        # 按第一个 ':' 切 user:pass (按 codepoint 边界找 ':', 防 multi-byte UTF-8 边界崩溃)
        var us = ""
        var ps = ""
        var found_colon = False
        var colon_byte = -1
        var ci = 0
        var cn = cred.byte_length()
        while ci < cn:
            var cl = next_codepoint_len(cred, ci)
            if ord(cred[byte=ci]) == 58:  # ':' (ASCII, 不会是 UTF-8 续字节)
                colon_byte = ci
                found_colon = True
                break
            ci += cl
        if found_colon:
            us = _bstr(cred, 0, colon_byte)
            ps = _bstr(cred, colon_byte + 1, cn)   # colon+1 = next codepoint 起点
        else:
            us = cred
        var ok_user = False
        for u in _split_csv(users_csv, 59):
            var sub = u.split(":")
            if len(sub) >= 2 and String(sub[0]) == us and String(sub[1]) == ps:
                ok_user = True
                break
        if not ok_user:
            var f2 = AuthResult()
            f2.ok = False
            f2.detail = "Invalid credentials"
            f2.www_authenticate = "Basic" + _realm_part(realm)
            return f2^
        var s1 = AuthResult()
        s1.ok = True
        s1.auth_user = us
        return s1^

    # ---- HTTPBearer ----
    elif auth_spec == "bearer":
        var tokens_csv = ""
        if "_auth_tokens" in handler.data:
            tokens_csv = handler.data["_auth_tokens"]
        var authz2 = _get_header("Authorization")
        if not _starts_with(authz2, "Bearer "):
            var f3 = AuthResult()
            f3.ok = False
            f3.detail = "Not authenticated"
            f3.www_authenticate = "Bearer" + _realm_part(realm)
            return f3^
        var token = _trim(_bstr(authz2, 7, authz2.byte_length()))
        if token == "":
            var f3b = AuthResult()
            f3b.ok = False
            f3b.detail = "Not authenticated"
            f3b.www_authenticate = "Bearer" + _realm_part(realm)
            return f3b^
        var ok_tok = False
        for t in _split_csv(tokens_csv, 59):
            if t == token:
                ok_tok = True
                break
        if not ok_tok:
            var f4 = AuthResult()
            f4.ok = False
            f4.detail = "Invalid token"
            f4.www_authenticate = "Bearer" + _realm_part(realm)
            return f4^
        var s2 = AuthResult()
        s2.ok = True
        s2.auth_token = token
        return s2^

    # ---- APIKey (header / query / cookie) ----
    elif _starts_with(auth_spec, "apikey:"):
        var tokens_csv2 = ""
        if "_auth_tokens" in handler.data:
            tokens_csv2 = handler.data["_auth_tokens"]
        var rest = _bstr(auth_spec, 7, auth_spec.byte_length())   # "<pos>:<name>"
        var ci = -1
        for k in range(rest.byte_length()):
            if ord(rest[byte=k]) == 58:  # ':'
                ci = k
                break
        if ci < 0:
            var f5 = AuthResult()
            f5.ok = False
            f5.detail = "Invalid auth spec"
            return f5^
        var pos = _bstr(rest, 0, ci)
        var name = _bstr(rest, ci + 1, rest.byte_length())
        var key = ""
        if pos == "header":
            key = _get_header(name)
        elif pos == "query":
            if name in query_values:
                key = query_values[name]
        elif pos == "cookie":
            var cookie_hdr = _get_header("Cookie")
            if cookie_hdr != "" and name != "":
                var parts = cookie_hdr.split(";")
                for p in parts:
                    var ps = String(p)
                    var eq = -1
                    for m in range(ps.byte_length()):
                        if ord(ps[byte=m]) == 61:
                            eq = m
                            break
                    if eq > 0:
                        var ck = _trim(_bstr(ps, 0, eq))
                        var cv = _trim(_bstr(ps, eq + 1, ps.byte_length()))
                        if ck == name:
                            key = cv
                            break
        else:
            var f6 = AuthResult()
            f6.ok = False
            f6.detail = "Invalid auth spec"
            return f6^
        var ok_key = False
        for tk in _split_csv(tokens_csv2, 59):
            if tk == key:
                ok_key = True
                break
        if not ok_key:
            var f7 = AuthResult()
            f7.ok = False
            f7.detail = "Invalid API key"
            return f7^
        var s3 = AuthResult()
        s3.ok = True
        s3.auth_apikey = key
        return s3^

    # ---- HTTPDigest (上游 stub parity: 只校验 scheme, 不实现完整 digest) ----
    elif auth_spec == "digest":
        var authz3 = _get_header("Authorization")
        var scheme3 = ""
        var creds3 = ""
        var sp = -1
        for k in range(authz3.byte_length()):
            if ord(authz3[byte=k]) == 32:  # ' '
                sp = k
                break
        if sp > 0:
            scheme3 = _bstr(authz3, 0, sp)
        if sp >= 0:
            creds3 = _trim(_bstr(authz3, sp + 1, authz3.byte_length()))
        if authz3 == "" or scheme3 == "" or creds3 == "" or not _eq_ci(scheme3, "digest"):
            var f9 = AuthResult()
            f9.ok = False
            f9.detail = "Not authenticated"
            f9.www_authenticate = "Digest"
            return f9^
        var s4 = AuthResult()
        s4.ok = True
        s4.auth_scheme = scheme3
        s4.auth_credentials = creds3
        return s4^

    # ---- OAuth2AuthorizationCodeBearer (决策-70, 上游: 与 OAuth2PasswordBearer 同 runtime,
    #      只提取 Bearer token, scheme 大小写不敏感, param 可为空) ----
    elif auth_spec == "authcode":
        var authz4 = _get_header("Authorization")
        var sp4 = -1
        for k in range(authz4.byte_length()):
            if ord(authz4[byte=k]) == 32:  # ' '
                sp4 = k
                break
        var scheme4 = authz4
        var param4 = ""
        if sp4 >= 0:
            scheme4 = _bstr(authz4, 0, sp4)
            param4 = _trim(_bstr(authz4, sp4 + 1, authz4.byte_length()))
        if authz4 == "" or not _eq_ci(scheme4, "bearer"):
            var f10 = AuthResult()
            f10.ok = False
            f10.detail = "Not authenticated"
            f10.www_authenticate = "Bearer" + _realm_part(realm)
            return f10^
        var s5 = AuthResult()
        s5.ok = True
        s5.auth_token = param4
        return s5^

    # ---- OpenIdConnect (决策-70, 上游 stub: 只校验 Authorization 头存在, 原样返回整个头) ----
    elif auth_spec == "openid":
        var authz5 = _get_header("Authorization")
        if authz5 == "":
            var f11 = AuthResult()
            f11.ok = False
            f11.detail = "Not authenticated"
            f11.www_authenticate = "Bearer" + _realm_part(realm)
            return f11^
        var s6 = AuthResult()
        s6.ok = True
        s6.auth_credentials = authz5
        return s6^

    # ---- 未知 spec ----
    else:
        var f8 = AuthResult()
        f8.ok = False
        f8.detail = "Unsupported auth scheme"
        return f8^


def main() raises:
    print("Testing Mojo security (决策-34)...")

    # base64 解码
    assert b64_decode("dXNlcjpwYXNz") == "user:pass", "b64 user:pass"
    assert b64_decode("YWRtaW46c2VjcmV0") == "admin:secret", "b64 admin:secret"
    assert b64_decode("YWJj") == "abc", "b64 abc"
    assert b64_decode("YWJjZA==") == "abcd", "b64 abcd padding"
    assert b64_decode("") == "", "b64 empty"

    # 前缀
    assert _starts_with("Basic abc", "Basic "), "starts_with hit"
    assert not _starts_with("Bearer abc", "Basic "), "starts_with miss"
    assert not _starts_with("Bas", "Basic "), "starts_with short"

    # 未声明 _auth -> ok (宽松)
    var h0 = Handler(0, "noauth")
    var r0 = check_auth(h0, Dict[String, String]())
    assert r0.ok, "no _auth -> ok"

    # 未知 spec
    var h1 = Handler(0, "bogus")
    h1.set_data("_auth", "wat")
    var r1 = check_auth(h1, Dict[String, String]())
    assert not r1.ok and r1.status_line == "401 Unauthorized", "unknown spec -> 401"

    print("Mojo security test completed!")
