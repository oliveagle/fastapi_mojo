# src/fastapi_mojo/openapi_security.mojo
#
# 决策-69 (ADR-0044): OpenAPI securityScheme + operation security 生成.
# 从 openapi.mojo 拆出 (respect God-package <500 行阈值), 单一职责 =
# 把路由表的 `_auth` / `_auth_scopes` / `_auth_scheme_name` / `_oauth2_*`
# 声明映射成 OpenAPI 3.0 securitySchemes / operation security 片段.
#
# 上游形态 (fastapi 0.141.1 实测):
#   basic  -> {"type":"http","scheme":"basic"}            (HTTPBasic)
#   bearer -> {"type":"http","scheme":"bearer"}           (HTTPBearer)
#   digest -> {"type":"http","scheme":"digest"}           (HTTPDigest)
#   apikey -> {"type":"apiKey","in":"<pos>","name":"<n>"} (APIKeyHeader/Query/Cookie)
#   oauth2 -> {"type":"oauth2","flows":{"password":{"scopes":{...},"tokenUrl":".."}}}
#   operation security = [{"<scheme>":[...scopes]}] (非 oauth2 恒 []).

from router import Router, Route
from handler import Handler
from json import json_escape


def _split_semi(s: String) -> List[String]:
    """按 `;` 切 + trim + 去空 (决策-67 scope 声明; 局部实现避免跨模块 import)."""
    var out = List[String]()
    var n = s.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        if (i == n) or (ord(s[byte=i]) == 59):  # ';'
            if i > start:
                var b = start
                var e = i
                while b < e and (ord(s[byte=b]) == 32 or ord(s[byte=b]) == 9):
                    b += 1
                while e > b and (ord(s[byte=e - 1]) == 32 or ord(s[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    out.append(String(s[byte=b:e]))
            start = i + 1
        i += 1
    return out^


def _security_scopes_json(handler: Handler) raises -> String:
    """`_auth_scopes` (决策-67, `;` 分隔) -> OpenAPI security scope 数组 JSON."""
    var out = ""
    if "_auth_scopes" in handler.data:
        for sc in _split_semi(handler.data["_auth_scopes"]):
            if out.byte_length() > 0:
                out += ","
            out += "\"" + json_escape(sc) + "\""
    return out


def _has_prefix(s: String, p: String) -> Bool:
    """s 是否以 p 开头 (按字节)."""
    if s.byte_length() < p.byte_length():
        return False
    var i = 0
    while i < p.byte_length():
        if s[byte=i] != p[byte=i]:
            return False
        i += 1
    return True


def _apikey_in_name(auth: String) -> Tuple[String, String]:
    """`apikey:<in>:<name>` -> (in, name); 畸形 -> ("","")."""
    var n = auth.byte_length()
    if n <= 7:  # len("apikey:")
        return ("", "")
    var ci = -1
    var k = 7
    while k < n:
        if ord(auth[byte=k]) == 58:  # ':'
            ci = k
            break
        k += 1
    if ci < 0:
        return ("", "")
    return (String(auth[byte=7:ci]), String(auth[byte=ci + 1:n]))


def _default_scheme_name(auth: String) -> String:
    """`_auth` 声明 -> 上游默认 securityScheme 名 (类名; `scheme_name=` 可覆盖)."""
    if auth == "basic":
        return "HTTPBasic"
    if auth == "bearer":
        return "HTTPBearer"
    if auth == "digest":
        return "HTTPDigest"
    if auth == "oauth2":
        return "OAuth2PasswordBearer"
    if auth == "authcode":
        return "OAuth2AuthorizationCodeBearer"
    if auth == "openid":
        return "OpenIdConnect"
    if _has_prefix(auth, "apikey:"):
        var parts = _apikey_in_name(auth)
        if parts[0] == "header":
            return "APIKeyHeader"
        if parts[0] == "query":
            return "APIKeyQuery"
        if parts[0] == "cookie":
            return "APIKeyCookie"
    return ""


def _auth_scheme_name(h: Handler) raises -> String:
    """operation/组件引用的 securityScheme 名 (`_auth_scheme_name` 覆盖默认)."""
    if "_auth" not in h.data or h.data["_auth"] == "":
        return ""
    if "_auth_scheme_name" in h.data and h.data["_auth_scheme_name"] != "":
        return h.data["_auth_scheme_name"]
    return _default_scheme_name(h.data["_auth"])


def _auth_scheme_json(auth: String, h: Handler) raises -> String:
    """非 oauth2 的 securityScheme JSON 对象 (上游键序 type[, scheme|in,name]).
    oauth2 / authcode / 未知 -> "" (oauth2 族由 flows 形态单独生成).
    openid 需要 handler 上的 `_openid_url` (上游 openIdConnectUrl=)."""
    if auth == "basic":
        return "{\"type\":\"http\",\"scheme\":\"basic\"}"
    if auth == "bearer":
        return "{\"type\":\"http\",\"scheme\":\"bearer\"}"
    if auth == "digest":
        return "{\"type\":\"http\",\"scheme\":\"digest\"}"
    if auth == "openid":
        var oid_url = ""
        if "_openid_url" in h.data:
            oid_url = h.data["_openid_url"]
        return "{\"type\":\"openIdConnect\",\"openIdConnectUrl\":\"" + json_escape(oid_url) + "\"}"
    if _has_prefix(auth, "apikey:"):
        var parts = _apikey_in_name(auth)
        if parts[0] == "" or parts[1] == "":
            return ""
        return "{\"type\":\"apiKey\",\"in\":\"" + json_escape(parts[0])
            + "\",\"name\":\"" + json_escape(parts[1]) + "\"}"
    return ""


def _oauth2_scheme_scopes_json(router: Router, code: Bool) raises -> Tuple[String, String, String]:
    """扫描路由表: token handler 声明的 scopes (`name=desc;...`) ->
    (scopes 对象 JSON, tokenUrl, authorizationUrl).

    code=False -> password flow: 键 `_oauth2_scopes` / `_oauth2_token_url`
    (默认 "token")。code=True -> authorizationCode flow: 键 `_authcode_scopes` /
    `_authcode_token_url` / `_authcode_authorization_url`。两套键故意分离,
    避免 password 与 authorizationCode 两个 scheme 互相污染 tokenUrl/scopes。"""
    var scopes_json = ""
    var token_url = "token"
    var authz_url = ""
    var scopes_key = "_oauth2_scopes"
    var token_key = "_oauth2_token_url"
    var authz_key = "_oauth2_authorization_url"
    if code:
        token_url = ""
        scopes_key = "_authcode_scopes"
        token_key = "_authcode_token_url"
        authz_key = "_authcode_authorization_url"
    var total = router.route_count()
    for i in range(total):
        if token_key in router.routes[i].handler.data:
            var tu = router.routes[i].handler.data[token_key]
            if tu != "":
                token_url = tu
        if authz_key in router.routes[i].handler.data:
            var au = router.routes[i].handler.data[authz_key]
            if au != "":
                authz_url = au
        if scopes_key in router.routes[i].handler.data:
            var spec = router.routes[i].handler.data[scopes_key]
            for pair in _split_semi(spec):
                # 首个 '=' 切 name / desc
                var eq = -1
                for k in range(pair.byte_length()):
                    if ord(pair[byte=k]) == 61:  # '='
                        eq = k
                        break
                if eq <= 0:
                    continue
                var nm = String(pair[byte=0:eq])
                var desc = String(pair[byte=eq + 1:pair.byte_length()])
                if scopes_json.byte_length() > 0:
                    scopes_json += ","
                scopes_json += "\"" + json_escape(nm) + "\":\"" + json_escape(desc) + "\""
    return (scopes_json, token_url, authz_url)

def _hidden(r: Route) raises -> Bool:
    """`_include_in_schema="0"` 路由不进 spec (决策-52, P24-13)."""
    return ("_include_in_schema" in r.handler.data
            and r.handler.data["_include_in_schema"] == "0")


def operation_security_json(h: Handler) raises -> String:
    """operation-level `,"security":[...]` 片段 (无 _auth -> "").

    决策-44/67/69: securityScheme 名 = 路由声明派生 (`_auth_scheme_name` 覆盖);
    oauth2 用 `_auth_scopes` (`;` 分隔) 填 scope 数组, 其余方案 scope 恒空 `[]`.
    """
    var op_scheme = _auth_scheme_name(h)
    if op_scheme == "":
        return ""
    return ",\"security\":[{\"" + json_escape(op_scheme) + "\":[" + _security_scopes_json(h) + "]}]"


def security_schemes_json(router: Router) raises -> String:
    """components 内 `"securitySchemes":{...}` 片段 (无 _auth 路由 -> "").

    按路由序去重; basic/bearer/digest -> http, apikey -> apiKey (in/name),
    oauth2 -> oauth2 password flow.
    """
    var total = router.route_count()
    var ss_names = List[String]()
    var ss_jsons = List[String]()
    for i in range(total):
        if _hidden(router.routes[i]):
            continue
        var h_i = router.routes[i].handler.copy()
        var nm = _auth_scheme_name(h_i)
        if nm == "":
            continue
        var dup = False
        for x in ss_names:
            if x == nm:
                dup = True
                break
        if dup:
            continue
        ss_names.append(nm)
        var auth_kind = h_i.data["_auth"] if "_auth" in h_i.data else ""
        if auth_kind == "oauth2":
            var osj = _oauth2_scheme_scopes_json(router, False)
            ss_jsons.append("\"" + json_escape(nm) + "\":{\"type\":\"oauth2\",\"flows\":{\"password\":{\"scopes\":{" + osj[0] + "},\"tokenUrl\":\"" + json_escape(osj[1]) + "\"}}}")
        elif auth_kind == "authcode":
            var osj2 = _oauth2_scheme_scopes_json(router, True)
            ss_jsons.append("\"" + json_escape(nm) + "\":{\"type\":\"oauth2\",\"flows\":{\"authorizationCode\":{\"scopes\":{" + osj2[0] + "},\"authorizationUrl\":\"" + json_escape(osj2[2]) + "\",\"tokenUrl\":\"" + json_escape(osj2[1]) + "\"}}}")
        else:
            var sj = _auth_scheme_json(auth_kind, h_i)
            if sj == "":
                continue
            ss_jsons.append("\"" + json_escape(nm) + "\":" + sj)
    if len(ss_jsons) == 0:
        return ""
    return "\"securitySchemes\":{" + ",".join(ss_jsons) + "}"
