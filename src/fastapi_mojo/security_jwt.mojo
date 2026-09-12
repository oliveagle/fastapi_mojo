# src/fastapi_mojo/security_jwt.mojo
#
# 决策-44 (Goal-0003 P2 #17): OAuth2 password flow + JWT (HS256) — 对标矩阵最后一项.
# FastAPI 0.141.1 对齐 (逐条 probe 验证: /tmp/fm_probe, fastapi 0.141.1 + pyjwt 2.13.0):
#   - /token (POST form) ≈ OAuth2PasswordRequestForm 宽松模型: grant_type 可选
#     (存在时须匹配 ^password$ 否则 422 string_pattern_mismatch); username/password
#     必填 (缺失 -> 422 missing, 全部收集); 凭据错 -> 401 "Incorrect email or
#     password" + WWW-Authenticate: Bearer; 成功 -> 200 {access_token, token_type}.
#   - get_current_user 等价 (check_oauth2, security.check_auth 在 _auth=oauth2 分派):
#     无 Authorization / scheme(不区分大小写) != bearer -> 401 "Not authenticated";
#     bearer -> param (首个空格后全部, 可为空) 交 JWT 校验; 校验失败 (alg 非 HS256 /
#     签名 / exp / nbf / sub / 垃圾) -> 401 "Could not validate credentials";
#     成功 -> auth_user = sub, auth_token = param. (以上均带 WWW-Authenticate: Bearer)
# 分层 (ADR-0010): SHA-256/HMAC/base64url 原语 = Rust bridge crypto.rs; 本文件只做
#   协议解析. FFI: fm_hmac_sha256_b64url(key,len,msg,len) -> CSlice (malloc+NUL,
#   决策-36; free 走 _free). Mojo 1.0.0: 无 match/闭包; JSON 字段 = 手写扫描器
#   (payload 为 flat object; 不可信 input 只影响 401 结果, 签名校验独立).
#   自检 main() 仅纯逻辑 (JIT 链不了 FFI; 签名路径由 e2e OT-* 覆盖).

from std.ffi import external_call, CStringSlice
from handler import Handler
from string_builder import StringBuilder, span_to_str, decode_utf8_bytes
from security import AuthResult, _get_header, _realm_part, b64_decode
from request_response import _parse_form_body, _split_csv
from json import json_escape
from middleware import now_ms


# ---------- base64url 编码 (RFC 7515 §2.1, 纯 Mojo; 解码复用 security.b64_decode) ----------

def _b64url_char(v: Int) -> Int:
    """6-bit 值 -> ASCII code. URL-safe 字母表: '-' = 62, '_' = 63."""
    if v < 26:
        return 65 + v          # A-Z
    if v < 52:
        return 97 + (v - 26)   # a-z
    if v < 62:
        return 48 + (v - 52)   # 0-9
    if v == 62:
        return 45              # '-'
    return 95                  # '_'


def b64url_encode(s: String) -> String:
    """Base64url 编码 (无 padding). JWT header/payload 段."""
    var sb = StringBuilder()
    var n = s.byte_length()
    var i = 0
    while i < n:
        var b0 = ord(s[byte=i])
        var b1 = 0
        var b2 = 0
        if i + 1 < n:
            b1 = ord(s[byte=i + 1])
        if i + 2 < n:
            b2 = ord(s[byte=i + 2])
        var t = (b0 << 16) | (b1 << 8) | b2
        sb.append_byte(_b64url_char((t >> 18) & 63))
        sb.append_byte(_b64url_char((t >> 12) & 63))
        if i + 1 < n:
            sb.append_byte(_b64url_char((t >> 6) & 63))
        if i + 2 < n:
            sb.append_byte(_b64url_char(t & 63))
        i += 3
    return sb.take()


# ---------- JWT 3-part 切分 ----------

def _jwt_parts(token: String) -> Tuple[Bool, List[String]]:
    """按 '.' 切; 必须恰好 3 段且每段非空 (pyjwt: "Not enough segments" 等)."""
    var parts = List[String]()
    var n = token.byte_length()
    var start = 0
    var i = 0
    var ok = True
    while i <= n:
        var is_sep = (i == n) or (ord(token[byte=i]) == 46)  # '.'
        if is_sep:
            if i > start:
                parts.append(String(token[byte=start:i]))
            else:
                ok = False  # 空段 (如 "a..c")
            start = i + 1
        i += 1
    if len(parts) != 3:
        ok = False
    return (ok, parts^)


# ---------- 最小 JSON 字段扫描 (flat object; 本模块 payload 由本文件生成) ----------

def _json_field(obj: String, key: String) -> String:
    """找 key 的 value (string/number/bool/null). 返回 "" = 未找到.
    约束: key 前一个字符必须是 '{' 或 ',' (flat 顶层近似); 字符串值处理常见
    转义, 多字节 UTF-8 经 decode_utf8_bytes 还原."""
    var kq = '"' + key + '"'
    var kn = kq.byte_length()
    var n = obj.byte_length()
    var i = 0
    while i + kn <= n:
        var matched = True
        for j in range(kn):
            if obj[byte=i + j] != kq[byte=j]:
                matched = False
                break
        if matched:
            if i > 0:
                var prev = ord(obj[byte=i - 1])
                if prev != 123 and prev != 44:  # '{' / ','
                    matched = False
            if matched:
                var k = i + kn
                while k < n and (ord(obj[byte=k]) == 32 or ord(obj[byte=k]) == 9):
                    k += 1
                if k < n and ord(obj[byte=k]) == 58:  # ':'
                    k += 1
                    while k < n and (ord(obj[byte=k]) == 32 or ord(obj[byte=k]) == 9):
                        k += 1
                    if k < n and ord(obj[byte=k]) == 34:  # 字符串
                        var m = k + 1
                        var raw = List[Int]()
                        while m < n:
                            var cm = ord(obj[byte=m])
                            if cm == 92:  # '\\' escape
                                if m + 1 < n:
                                    var cn = ord(obj[byte=m + 1])
                                    if cn == 34:
                                        raw.append(34)
                                    elif cn == 92:
                                        raw.append(92)
                                    elif cn == 47:
                                        raw.append(47)
                                    elif cn == 110:
                                        raw.append(10)
                                    elif cn == 114:
                                        raw.append(13)
                                    elif cn == 116:
                                        raw.append(9)
                                    else:
                                        raw.append(cn)
                                    m += 2
                                    continue
                                else:
                                    break
                            elif cm == 34:
                                break
                            else:
                                raw.append(cm)
                            m += 1
                        return decode_utf8_bytes(raw)
                    else:  # number / true / false / null: 读到 , } ] 或空白
                        var m2 = k
                        while m2 < n:
                            var c2 = ord(obj[byte=m2])
                            if c2 == 44 or c2 == 125 or c2 == 93 or c2 == 32:
                                break
                            m2 += 1
                        return String(obj[byte=k:m2])
        i += 1
    return ""


def _int_or(s: String, default: Int) -> Int:
    """安全 int 解析 (可选前导 '-'); 非法/空 -> default (不 panic)."""
    if s == "":
        return default
    var neg = False
    var i = 0
    if ord(s[byte=0]) == 45:  # '-'
        neg = True
        i = 1
    if i >= s.byte_length():
        return default
    var v = 0
    while i < s.byte_length():
        var c = ord(s[byte=i])
        if c < 48 or c > 57:
            return default
        v = v * 10 + (c - 48)
        i += 1
    if neg:
        v = -v
    return v


def _lower(s: String) -> String:
    """小写化 (A-Z -> a-z; 其它原样). scheme 比较大小写不敏感 (0.141.1)."""
    var sb = StringBuilder()
    var n = s.byte_length()
    for i in range(n):
        var c = ord(s[byte=i])
        if c >= 65 and c <= 90:
            sb.append_byte(c + 32)
        else:
            sb.append_byte(c)
    return sb.take()


# ---------- JWT claims 校验 (纯逻辑: alg / exp / nbf / sub; 无 FFI) ----------

struct JwtVerify:
    """JWT 校验结果. ok=False -> detail 已填 (调用方映射 401)."""
    var ok: Bool
    var sub: String
    var detail: String
    var scopes: String   # 决策-67: RFC 6749 `scope` claim (空格分隔; 缺失 = "")

    def __init__(out self):
        self.ok = False
        self.sub = ""
        self.detail = "Could not validate credentials"
        self.scopes = ""


def _check_claims(header_json: String, payload_json: String, now_s: Int) -> JwtVerify:
    """纯 claims 校验: alg 必须 HS256 (拒 none/HS512/垃圾); exp: now>=exp 过期;
    nbf: now<nbf 未生效; sub 必须存在且非空.
    (0.141.1 教程 get_current_user: sub 仅查 None; 本实现空串也拒 — 更严格,
    ADR-0019 偏差-1.)"""
    var alg = _json_field(header_json, "alg")
    if alg != "HS256":
        var r0 = JwtVerify()
        return r0^
    var sub = _json_field(payload_json, "sub")
    if sub == "":
        var r1 = JwtVerify()
        return r1^
    var exp_s = _json_field(payload_json, "exp")
    if exp_s != "" and now_s >= _int_or(exp_s, 0):
        var r2 = JwtVerify()
        return r2^
    var nbf_s = _json_field(payload_json, "nbf")
    if nbf_s != "" and now_s < _int_or(nbf_s, 0):
        var r3 = JwtVerify()
        return r3^
    var r4 = JwtVerify()
    r4.ok = True
    r4.sub = sub
    r4.detail = "ok"
    r4.scopes = _json_field(payload_json, "scope")
    return r4^


def _hmac_b64url(key: String, msg: String) -> String:
    """FFI: HMAC-SHA256(key, msg) -> base64url (Rust bridge crypto.rs).
    空 key/msg 合法 (HMAC 对空输入有定义)."""
    var k = key
    var m = msg
    var sl = external_call["fm_hmac_sha256_b64url", CStringSlice[origin_of(String(""))]](
        k.as_c_string_slice(), Int64(k.byte_length()),
        m.as_c_string_slice(), Int64(m.byte_length()))
    return span_to_str(sl.as_bytes())


def jwt_encode_hs256(header_json: String, payload_json: String, secret: String) -> String:
    """签发 HS256 JWT: b64url(header).b64url(payload).b64url(HMAC)."""
    var h = header_json
    var p = payload_json
    var sec = secret
    var h64 = b64url_encode(h)
    var p64 = b64url_encode(p)
    var signing_input = h64 + "." + p64
    return signing_input + "." + _hmac_b64url(sec, signing_input)


def jwt_verify_hs256(token: String, secret: String, now_s: Int) -> JwtVerify:
    """完整 HS256 校验: 3-part 切分 -> b64url 解码 -> claims -> 签名重算比对.
    任一环节失败 -> ok=False, detail="Could not validate credentials"
    (与 pyjwt 各异常路径在 0.141.1 教程流程中统一映射的 401 一致)."""
    var pre = _jwt_parts(token)
    if not pre[0]:
        var r0 = JwtVerify()
        return r0^
    var header_json = b64_decode(pre[1][0])
    var payload_json = b64_decode(pre[1][1])
    var cl = _check_claims(header_json, payload_json, now_s)
    if not cl.ok:
        return cl^
    var expect = _hmac_b64url(secret, pre[1][0] + "." + pre[1][1])
    if pre[1][2] != expect:
        var r1 = JwtVerify()
        return r1^
    return cl^


# ---------- OAuth2 作用域 (决策-67: SecurityScopes / Security(scopes=[...]) 等价) ----------

def _scopes_of(spec: String) -> List[String]:
    """声明串 -> scope list. `;` 分隔 (scope 名可含 `:`), 去空/trim. 空串 -> 空 list."""
    if spec.byte_length() == 0:
        return List[String]()
    return _split_csv(spec, 59)


def _has_scope(claim: String, scope: String) -> Bool:
    """token `scope` claim (空格分隔, RFC 6749) 是否含 scope."""
    var n = claim.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(claim[byte=i]) == 32)
        if is_sep:
            if i > start and String(claim[byte=start:i]) == scope:
                return True
            start = i + 1
        i += 1
    return False


# ---------- OAuth2PasswordBearer + get_current_user 等价 (请求级 gate) ----------

def check_oauth2(handler: Handler) raises -> AuthResult:
    """_auth=oauth2 的请求级校验 (security.check_auth 分派至此).

    0.141.1 OAuth2PasswordBearer.__call__:
      无 Authorization 或 scheme(小写) != "bearer" -> 401 "Not authenticated" (www=Bearer)
      否则返回 param (首个空格后全部; "Bearer" 无空格 / "Bearer " 空值 -> param="").
    之后等价教程 get_current_user: pyjwt decode 失败 (含空 token) ->
      401 "Could not validate credentials" (www=Bearer); 成功 -> sub.
    """
    var realm = ""
    if "_auth_realm" in handler.data:
        realm = handler.data["_auth_realm"]
    var www = "Bearer" + _realm_part(realm)

    var authz = _get_header("Authorization")
    if authz == "":
        var f1 = AuthResult()
        f1.detail = "Not authenticated"
        f1.www_authenticate = www
        return f1^

    var scheme: String
    var param: String
    var n = authz.byte_length()
    var sp = -1
    var i = 0
    while i < n:
        if ord(authz[byte=i]) == 32:  # 首个空格
            sp = i
            break
        i += 1
    if sp >= 0:
        scheme = String(authz[byte=0:sp])
        param = String(authz[byte=sp + 1:n])
    else:
        scheme = authz
        param = ""

    if _lower(scheme) != "bearer":
        var f2 = AuthResult()
        f2.detail = "Not authenticated"
        f2.www_authenticate = www
        return f2^

    var secret = ""
    if "_jwt_secret" in handler.data:
        secret = handler.data["_jwt_secret"]
    var v = jwt_verify_hs256(param, secret, now_ms() // 1000)
    # 决策-67: 声明 `_auth_scopes` 时, 教程 `authenticate_value` =
    # `Bearer scope="<space-joined>"` (用于 401 坏 token / 403 缺 scope 两个分支).
    var required = List[String]()
    if "_auth_scopes" in handler.data:
        required = _scopes_of(handler.data["_auth_scopes"])
    var scoped_www = www
    if len(required) > 0:
        scoped_www = "Bearer scope=\"" + " ".join(required) + "\""
    if not v.ok:
        var f3 = AuthResult()
        f3.detail = "Could not validate credentials"
        f3.www_authenticate = scoped_www
        return f3^

    # 决策-67: token `scope` claim 必须覆盖全部声明 scope, 否则 403
    # "Not enough permissions" (教程 get_current_user 等价).
    if len(required) > 0:
        for sc in required:
            if not _has_scope(v.scopes, sc):
                var f4 = AuthResult()
                f4.status_line = "403 Forbidden"
                f4.detail = "Not enough permissions"
                f4.www_authenticate = scoped_www
                return f4^

    var ok = AuthResult()
    ok.ok = True
    ok.status_line = "200 OK"
    ok.detail = "ok"
    ok.auth_user = v.sub
    ok.auth_token = param
    return ok^


# ---------- /token (OAuth2PasswordRequestForm 等价) ----------

def _check_form(fields: Dict[String, String]) raises -> Tuple[Int, String]:
    """form 校验 (纯逻辑). 返回 (status_code, detail):
    200 通过; 422 = Pydantic 风格 nested detail (detail 串含 "__nested__:" 前缀).
    grant_type 缺省 = 通过 (0.141.1 宽松模型); 存在且 != "password" -> pattern 错.
    username/password 缺失 -> missing (全部收集)."""
    if "grant_type" in fields and fields["grant_type"] != "password":
        var d = "__nested__:[{\"type\":\"string_pattern_mismatch\",\"loc\":[\"body\",\"grant_type\"],"
        d = d + "\"msg\":\"String should match pattern '^password$'\",\"input\":\""
        d = d + json_escape(fields["grant_type"])
        d = d + "\",\"ctx\":{\"pattern\":\"^password$\"}}]"
        return (422, d^)
    var missing = List[String]()
    if not ("username" in fields):
        missing.append("{\"type\":\"missing\",\"loc\":[\"body\",\"username\"],\"msg\":\"Field required\",\"input\":null}")
    if not ("password" in fields):
        missing.append("{\"type\":\"missing\",\"loc\":[\"body\",\"password\"],\"msg\":\"Field required\",\"input\":null}")
    if len(missing) > 0:
        return (422, "__nested__:[" + ",".join(missing) + "]")
    return (200, "")


def handle_oauth2_token(handler: Handler, body_str: String) raises -> Tuple[String, Dict[String, String], String]:
    """POST /token: form 校验 -> 凭据校验 (_auth_users CSV) -> 签发 JWT.
    返回 (status_line, resp_data, www_authenticate); www 空 = 无 WWW-Authenticate 头.

    为何在 dispatch 而非 run_handler: 需要 body_str (form 原文), run_handler 签名
    不带 body (SSE 同型特例, 决策-43 之前 F5 先例)."""
    var realm = ""
    if "_auth_realm" in handler.data:
        realm = handler.data["_auth_realm"]
    var www = "Bearer" + _realm_part(realm)

    var fields = _parse_form_body(body_str)
    var fv = _check_form(fields)
    if fv[0] == 422:
        var d1 = Dict[String, String]()
        d1["detail"] = fv[1]
        d1["status"] = "422"
        return ("422 Unprocessable Entity", d1^, "")

    var username = ""
    if "username" in fields:
        username = fields["username"]
    var password = ""
    if "password" in fields:
        password = fields["password"]

    var users_csv = ""
    if "_auth_users" in handler.data:
        users_csv = handler.data["_auth_users"]
    var ok_cred = False
    for up in _split_csv(users_csv, 59):  # 'u:p;u:p'
        var cp = _split_csv(up, 58)       # 首个 ':' 切 (name 不含 ':')
        if len(cp) == 2 and cp[0] == username and cp[1] == password:
            ok_cred = True
            break
    if not ok_cred:
        var d2 = Dict[String, String]()
        d2["detail"] = "Incorrect email or password"
        d2["status"] = "401"
        return ("401 Unauthorized", d2^, www)

    var secret = ""
    if "_jwt_secret" in handler.data:
        secret = handler.data["_jwt_secret"]
    var ttl = _int_or(handler.data["_jwt_ttl_sec"], 3600) if "_jwt_ttl_sec" in handler.data else 3600
    var now = now_ms() // 1000
    # 决策-67: 可选 `_jwt_scopes` (声明 `;` 分隔) -> RFC 6749 `scope` claim
    # (空格分隔). 空/缺失 = 不签发 scope claim (既有 token 形态不变).
    var payload = "{\"sub\":\"" + json_escape(username) + "\",\"username\":\""
    payload = payload + json_escape(username) + "\""
    if "_jwt_scopes" in handler.data:
        var granted = _scopes_of(handler.data["_jwt_scopes"])
        if len(granted) > 0:
            payload = payload + ",\"scope\":\"" + " ".join(granted) + "\""
    payload = payload + ",\"iat\":" + String(now) + ",\"exp\":" + String(now + ttl) + "}"
    var token = jwt_encode_hs256("{\"alg\":\"HS256\",\"typ\":\"JWT\"}", payload, secret)
    var d3 = Dict[String, String]()
    d3["access_token"] = token
    d3["token_type"] = "bearer"
    return ("200 OK", d3^, "")


import std.os


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing security_jwt (决策-44, 纯逻辑部分; 签名 FFI 路径由 e2e 覆盖)...")

    # b64url 编码 (RFC 7515 §2.1 向量)
    check(b64url_encode("") == "" and b64url_encode("f") == "Zg", "b64url empty/f")
    check(b64url_encode("fo") == "Zm8" and b64url_encode("foo") == "Zm9v", "b64url fo/foo")
    check(b64url_encode("foob") == "Zm9vYg" and b64url_encode("fooba") == "Zm9vYmE", "b64url foob/fooba")
    check(b64url_encode("foobar") == "Zm9vYmFy", "b64url foobar")

    # 3-part 切分
    var p1 = _jwt_parts("a.b.c")
    check(p1[0] and len(p1[1]) == 3, "3 parts ok")
    check(not _jwt_parts("a.b")[0] and not _jwt_parts("a.b.c.d")[0], "2/4 parts reject")
    check(not _jwt_parts("a..c")[0] and not _jwt_parts("")[0], "empty seg/token reject")

    # JSON 字段扫描 + 小工具
    var oj = "{\"sub\":\"admin\",\"username\":\"admin\",\"exp\":9999999999}"
    check(_json_field(oj, "sub") == "admin" and _json_field(oj, "exp") == "9999999999", "json sub/exp")
    check(_json_field(oj, "nope") == "", "json missing")
    check(_json_field("{\"a\":\"x\",\"sub\":\"y\"}", "sub") == "y", "json after comma")
    check(_int_or("123", -1) == 123 and _int_or("-5", -1) == -5, "int ok/neg")
    check(_int_or("abc", -1) == -1 and _int_or("", -1) == -1, "int bad/empty default")
    check(_lower("BeArEr") == "bearer", "lower")

    # claims 校验 (注入 now)
    var hdr_ok = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
    var pl_ok = "{\"sub\":\"admin\",\"username\":\"admin\",\"iat\":1788979200,\"exp\":9999999999}"
    var c1 = _check_claims(hdr_ok, pl_ok, 1788979200)
    check(c1.ok and c1.sub == "admin", "claims ok")
    check(not _check_claims("{\"alg\":\"none\",\"typ\":\"JWT\"}", pl_ok, 1000).ok, "alg none reject")
    check(not _check_claims("{\"alg\":\"HS512\"}", pl_ok, 1000).ok, "alg HS512 reject")
    check(not _check_claims(hdr_ok, "{\"sub\":\"a\",\"exp\":999}", 1000).ok, "expired reject")
    check(not _check_claims(hdr_ok, "{\"sub\":\"a\",\"exp\":1000}", 1000).ok, "now==exp reject")
    check(_check_claims(hdr_ok, "{\"sub\":\"a\",\"exp\":1001}", 1000).ok, "future exp ok")
    check(not _check_claims(hdr_ok, "{\"sub\":\"a\",\"exp\":9999,\"nbf\":1001}", 1000).ok, "nbf future reject")
    check(_check_claims(hdr_ok, "{\"sub\":\"a\",\"exp\":9999,\"nbf\":1000}", 1000).ok, "now==nbf ok")
    check(not _check_claims(hdr_ok, "{\"username\":\"a\",\"exp\":9999}", 1000).ok, "no sub reject")

    # form 校验 (纯逻辑)
    var f1 = Dict[String, String]()
    f1["grant_type"] = "password"
    f1["username"] = "u"
    f1["password"] = "p"
    check(_check_form(f1)[0] == 200, "form ok")
    var f2 = Dict[String, String]()
    f2["grant_type"] = "refresh"
    f2["username"] = "u"
    f2["password"] = "p"
    var rv2 = _check_form(f2)
    check(rv2[0] == 422 and rv2[1].find("string_pattern_mismatch") >= 0, "form pattern 422")
    var f3 = Dict[String, String]()
    f3["grant_type"] = "password"
    var rv3 = _check_form(f3)
    check(rv3[0] == 422 and rv3[1].find("username") >= 0 and rv3[1].find("password") >= 0, "form both missing 422")
    var f4 = Dict[String, String]()
    f4["username"] = "u"
    f4["password"] = "p"
    check(_check_form(f4)[0] == 200, "form grant missing ok (0.141.1 permissive)")

    # 决策-67 作用域 (纯逻辑)
    var sr = _scopes_of("items:read; me ")
    check(len(sr) == 2 and sr[0] == "items:read" and sr[1] == "me", "scopes_of split+trim")
    check(len(_scopes_of("")) == 0 and len(_scopes_of(";;")) == 0, "scopes_of empty")
    check(_has_scope("items:read me", "me") and _has_scope("items:read me", "items:read"), "has_scope hit")
    check(not _has_scope("items:read", "me") and not _has_scope("", "me"), "has_scope miss")
    check(not _has_scope("item", "it"), "has_scope no prefix match")
    var cs = _check_claims(hdr_ok, "{\"sub\":\"a\",\"exp\":9999,\"scope\":\"items:read me\"}", 1000)
    check(cs.ok and cs.scopes == "items:read me", "claims scope parsed")
    check(_check_claims(hdr_ok, "{\"sub\":\"a\",\"exp\":9999}", 1000).scopes == "", "claims scope absent empty")

    print("Mojo security_jwt test completed!")
