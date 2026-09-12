# src/fastapi_mojo/openapi_custom.mojo
#
# 决策-52 (ADR-0027, Goal-0003 P2 矩阵 #16): OpenAPI 精化 — 顶层 tags/info/
# servers/externalDocs + 路由级自定义 纯函数模块 (无 FFI, 无全局状态,
# ADR-0004 声明式范式, FFI diff = 0)。
#
# 内容:
#   - title_case / default_summary — summary 默认 = Python str.title() 算法
#     (_/- → 空格, 词首大写其余小写, 数字后字母大写; P24-5 全向量)
#   - default_operation_id — {name}{path: /,{,} → _}_{method 小写} (P24-6)
#   - url_host_quirk — pydantic AnyUrl 复刻: host-only URL 追加尾 / (P24-12)
#   - openapi_info_json / openapi_servers_json / openapi_root_tags_json /
#     openapi_external_docs_json — app 级 JSON 构造 (键序逐 P24 对齐)
#   - parse_response_entries — _responses CSV 解析 (首个 : 切)
#   - primary_status_key — spec responses 主键 (_status_code 前 3 位 / "200")
#   - check_openapi_specs — 注册期校验 (畸形 spec 启动即 fail,
#     check_state_specs/check_ws_specs/check_body_schemas 同策略)
#
# 上游探测: /tmp/exch_probe/p24*.py (fastapi 0.141.1 / starlette 1.6.0,
# 细节与偏差见 ADR-0027 §1/§3.5)。

from router import Router
from handler import Handler
from json import json_escape


def _is_alpha(c: Int) -> Bool:
    """ASCII 字母判定 (title_case 用)."""
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90)


def title_case(name: String) -> String:
    """Python str.title() 等价 (P24-5 全向量): 先把 _ / - 替换为空格, 每词首
    字母大写其余小写; 数字后字母视为词首大写。
    foo_bar → Foo Bar / v2api → V2Api / apiV2 → Apiv2 / UPPER → Upper /
    a__b → A  B / x-1 → X 1 / a1_b2 → A1 B2."""
    var out = String("")
    var prev_alpha = False
    var n = name.byte_length()
    var i = 0
    while i < n:
        var c = ord(name[byte=i])
        if c == 95 or c == 45:  # '_' / '-'
            out += " "
            prev_alpha = False
        elif _is_alpha(c):
            if not prev_alpha and c >= 97:
                c -= 32
            elif prev_alpha and c <= 90:
                c += 32
            out += chr(c)
            prev_alpha = True
        else:
            out += chr(c)
            prev_alpha = False
        i += 1
    return out


def default_summary(name: String) -> String:
    """`summary` 默认 = 路由名标题化 (P24-5: 上游 = endpoint 函数名同款
    字符串约定, ADR-0027 §3.5-7)."""
    return title_case(name)


def default_operation_id(name: String, path: String, method: String) -> String:
    """`operationId` 默认公式 (P24-6): {name}{path 逐字符 / { } → _}_{method 小写}.
    foo_bar @ /x/y/{z} GET → foo_bar_x_y__z__get; another_one @ /a/{id}/b
    POST → another_one_a__id_b_post."""
    var out = String("")
    var n = path.byte_length()
    var i = 0
    while i < n:
        var c = ord(path[byte=i])
        if c == 47 or c == 123 or c == 125:  # '/' '{' '}'
            out += "_"
        else:
            out += chr(c)
        i += 1
    return name + out + "_" + _lower_ascii(method)


def _lower_ascii(s: String) -> String:
    """小写化 (form_params.lower_ascii 同语义, 避免跨模块耦合).

    决策-83/ADR-0058: 全字节安全 (非 ASCII 码点整体透传, 续字节跳过)."""
    var out = String("")
    var n = s.byte_length()
    var ab = s.as_bytes()
    var i = 0
    while i < n:
        var b = Int(ab[i])
        if b >= 0x80 and b < 0xC0:
            i += 1
            continue
        var c = ord(s[byte=i])
        if c >= 65 and c <= 90:
            c += 32
        out += chr(c)
        i += 1
    return out


def url_host_quirk(url: String) -> String:
    """`url` 尾 `/` quirk (pydantic AnyUrl 2.13.5 规范化复刻, P24-12):
    `://` 之后 path 为空时 — 无 / ? # → 追加尾 /; 首个 special 为 ? / #
    (path 空, 有 query/fragment) → 在其前插入 /; 首个 special 为 / (有
    path) → 不变; 无 `://` (mailto:/相对串) → 不变。
    https://support.example → https://support.example/; https://x:8080 →
    https://x:8080/; https://host?x → https://host/?x; https://x.y/a/b 不变。
    适用: contact.url / license.url / externalDocs.url (上游纯 AnyUrl);
    **servers url 不适用** (Server.url = AnyUrl|str, str 精确匹配优先 →
    原样, P24-12 修正)."""
    var scheme_end = url.find("://")
    if scheme_end < 0:
        return url
    var n = url.byte_length()
    var i = scheme_end + 3
    var first_special = -1
    while i < n:
        var c = ord(url[byte=i])
        if c == 47 or c == 63 or c == 35:  # '/' '?' '#'
            first_special = i
            break
        i += 1
    if first_special < 0:
        return url + "/"
    if ord(url[byte=first_special]) == 47:
        return url
    var head = String(url[byte=0:first_special])
    var tail = String(url[byte=first_special:n])
    return head + "/" + tail


def openapi_info_json(title: String, version: String, description: String,
                      terms: String, contact: String, license: String) -> String:
    """`info` 对象 (P24-1 键序: title, description?, termsOfService?, contact?,
    license?, version; 缺省项省略)。contact = "name|url|email" (url 经
    host quirk); license = "name|url" (url 经 host quirk); 畸形 (段数/空段)
    → 省略该字段 (env 请求期读, 不 fail — ADR-0027 §3.5-4)."""
    var out = "{\"title\":\"" + json_escape(title) + "\""
    if description != "":
        out += ",\"description\":\"" + json_escape(description) + "\""
    if terms != "":
        out += ",\"termsOfService\":\"" + json_escape(terms) + "\""
    if contact != "":
        var cp = contact.split("|")
        if len(cp) == 3:
            var cn = String(cp[0])
            var cu = String(cp[1])
            var ce = String(cp[2])
            if cn != "" and cu != "" and ce != "":
                out += ",\"contact\":{\"name\":\"" + json_escape(cn) + "\""
                out += ",\"url\":\"" + json_escape(url_host_quirk(cu)) + "\""
                out += ",\"email\":\"" + json_escape(ce) + "\"}"
    if license != "":
        var lp = license.split("|")
        if len(lp) == 2:
            var ln = String(lp[0])
            var lu = String(lp[1])
            if ln != "" and lu != "":
                out += ",\"license\":{\"name\":\"" + json_escape(ln) + "\""
                out += ",\"url\":\"" + json_escape(url_host_quirk(lu)) + "\"}"
    out += ",\"version\":\"" + json_escape(version) + "\"}"
    return out


def _find_byte_from(s: String, ch: Int, start: Int) -> Int:
    """Index of the first byte equal to ch at or after start; -1 if absent."""
    var n = s.byte_length()
    var i = start
    while i < n:
        if ord(s[byte=i]) == ch:
            return i
        i += 1
    return -1


def _split_url_desc(e: String) -> Tuple[String, String]:
    """Split servers CSV entry "url:desc" (P24-3 env format): the delimiter
    is the first `:` after `://` (if any); if the segment immediately
    following that colon is all digits (1-5) it is a **port**, not desc —
    then the next `:` (if any) delimits desc; no `://` (relative url) →
    split at first `:`. desc may be empty and may contain colons.
    https://s.example/v1:Prod → ("https://s.example/v1","Prod");
    https://s.example:8080 → (whole, ""); https://s.example:8080:Prod →
    ("https://s.example:8080","Prod")."""
    var scheme_end = e.find("://")
    var start = 0
    if scheme_end >= 0:
        start = scheme_end + 3
    var ci = _find_byte_from(e, 58, start)
    if ci < 0:
        return (e, "")
    var seg_end = e.byte_length()
    var i = ci + 1
    while i < seg_end:
        var c = ord(e[byte=i])
        if c == 47 or c == 63 or c == 35 or c == 58:  # '/' '?' '#' ':'
            seg_end = i
            break
        i += 1
    var seg = String(e[byte=ci + 1:seg_end])
    var sl = seg.byte_length()
    var is_port = sl >= 1 and sl <= 5
    var j = 0
    while is_port and j < sl:
        if ord(seg[byte=j]) < 48 or ord(seg[byte=j]) > 57:
            is_port = False
        j += 1
    if is_port:
        var ci2 = _find_byte_from(e, 58, seg_end)
        if ci2 < 0:
            return (e, "")
        return (String(e[byte=0:ci2]), String(e[byte=ci2 + 1:e.byte_length()]))
    return (String(e[byte=0:ci]), String(e[byte=ci + 1:e.byte_length()]))


def openapi_servers_json(csv: String) -> String:
    """根 servers 数组 (P24-3 键序 url, description): "url:desc;url2:desc2"
    → [{"url":"...","description":"..."},...]。条目切分 = _split_url_desc
    (`://` 后首个 `:`; 紧随段全数字 1-5 位 → 视为端口再找下一个 `:`; 无
    scheme 相对 url 按首个 `:` 切); desc 可省 (省略键); url **原样透传** (上游 Server.url =
    AnyUrl|str, str 精确匹配优先 → 不规范化); 空条目跳过; 全空 → "[]" (调用方据此省略键)."""
    var out = "["
    var entries = csv.split(";")
    var first = True
    for i in range(len(entries)):
        var e = String(entries[i])
        if e == "":
            continue
        var ud = _split_url_desc(e)
        var url = ud[0]
        var desc = ud[1]
        if url == "":
            continue
        if not first:
            out += ","
        first = False
        out += "{\"url\":\"" + json_escape(url) + "\""
        if desc != "":
            out += ",\"description\":\"" + json_escape(desc) + "\""
        out += "}"
    out += "]"
    return out


def openapi_root_tags_json(csv: String) -> String:
    """根 tags 数组 (P24-2/§3.5-9: 原样透传, 路由 operation 级 tags **不**
    并入): "name:desc;name2:desc2" → [{"name":"...","description":"..."}]
    (desc 可省; 空条目跳过; 全空 → "[]")."""
    var out = "["
    var entries = csv.split(";")
    var first = True
    for i in range(len(entries)):
        var e = String(entries[i])
        if e == "":
            continue
        var ci = e.find(":")
        var nm = e
        var desc = ""
        if ci >= 0:
            nm = String(e[byte=0:ci])
            desc = String(e[byte=ci + 1:e.byte_length()])
        if nm == "":
            continue
        if not first:
            out += ","
        first = False
        out += "{\"name\":\"" + json_escape(nm) + "\""
        if desc != "":
            out += ",\"description\":\"" + json_escape(desc) + "\""
        out += "}"
    out += "]"
    return out


def openapi_external_docs_json(spec: String) -> String:
    """`externalDocs` (P24-10 键序 **description 先**, url 后): "url|desc"
    → {"description":"...","url":"..."} (desc 可省; url 经 host quirk;
    url 空 → "" (调用方省略键))."""
    var parts = spec.split("|")
    var url = ""
    var desc = ""
    if len(parts) >= 1:
        url = String(parts[0])
    if len(parts) >= 2:
        desc = String(parts[1])
    if url == "":
        return ""
    var out = "{"
    if desc != "":
        out += "\"description\":\"" + json_escape(desc) + "\""
        out += ","
    out += "\"url\":\"" + json_escape(url_host_quirk(url)) + "\"}"
    return out


def parse_response_entries(csv: String) -> List[Tuple[String, String]]:
    """_responses = "404:Not found;418:Teapot" → [(status, desc), ...]
    (首个 ':' 切 status/desc; desc 可再含 ':'; 空条目/无冒号跳过 —
    错误报告由 check_openapi_specs 承担)."""
    var out = List[Tuple[String, String]]()
    var entries = csv.split(";")
    for i in range(len(entries)):
        var e = String(entries[i])
        if e == "":
            continue
        var ci = e.find(":")
        if ci < 0:
            continue
        var st = String(e[byte=0:ci])
        var desc = String(e[byte=ci + 1:e.byte_length()])
        out.append((st, desc))
    return out.copy()


def primary_status_key(h: Handler) raises -> String:
    """The spec responses 主键 (P24-7): _status_code 前 3 位 (合法时), 否则默认 "200"."""
    if "_status_code" in h.data:
        var sc = h.data["_status_code"]
        var n = sc.byte_length()
        if n >= 3:
            var a = ord(sc[byte=0])
            var b = ord(sc[byte=1])
            var c = ord(sc[byte=2])
            if a >= 48 and a <= 57 and b >= 48 and b <= 57 and c >= 48 and c <= 57:
                return String(sc[byte=0:3])
    return "200"


def _valid_status_prefix(sc: String) -> Bool:
    """_status_code = "NNN Reason": 3 位数字 100-599 + 空格 + 非空 reason."""
    var n = sc.byte_length()
    if n < 5:
        return False
    var a = ord(sc[byte=0])
    var b = ord(sc[byte=1])
    var c = ord(sc[byte=2])
    if not (a >= 48 and a <= 57 and b >= 48 and b <= 57 and c >= 48 and c <= 57):
        return False
    if ord(sc[byte=3]) != 32:
        return False
    var code = (a - 48) * 100 + (b - 48) * 10 + (c - 48)
    return code >= 100 and code <= 599


def _valid_response_entry(e: String) -> Bool:
    """_responses 条目 = "NNN:desc": 3 位数字 100-599 + ':' + 非空 desc."""
    var n = e.byte_length()
    if n < 5:
        return False
    var a = ord(e[byte=0])
    var b = ord(e[byte=1])
    var c = ord(e[byte=2])
    if not (a >= 48 and a <= 57 and b >= 48 and b <= 57 and c >= 48 and c <= 57):
        return False
    if ord(e[byte=3]) != 58:
        return False
    var code = (a - 48) * 100 + (b - 48) * 10 + (c - 48)
    return code >= 100 and code <= 599


def check_openapi_specs(router: Router) raises:
    """决策-52 OpenAPI 路由级声明注册期校验 (畸形 spec 启动即 fail,
    check_state_specs/check_ws_specs/check_body_schemas 同策略):
    _deprecated ∈ {"","1"} / _include_in_schema ∈ {"","0"} /
    _status_code = "NNN Reason" / _responses 每条目 "NNN:desc" 且
    不与主键重复 (ADR-0027 §3.5-8: 上游用户 dict 覆盖语义 → 本实现
    fail-fast)。_summary/_description/_response_description/_operation_id
    = 任意串 (空 = 默认, 不校验)."""
    for i in range(router.route_count()):
        var h = router.routes[i].handler.copy()
        if "_deprecated" in h.data and h.data["_deprecated"] != "" and h.data["_deprecated"] != "1":
            raise Error("openapi: bad _deprecated (need \"1\") in "
                        + h.name + ": " + h.data["_deprecated"])
        if "_include_in_schema" in h.data and h.data["_include_in_schema"] != "" and h.data["_include_in_schema"] != "0":
            raise Error("openapi: bad _include_in_schema (need \"0\") in "
                        + h.name + ": " + h.data["_include_in_schema"])
        if "_status_code" in h.data and h.data["_status_code"] != "":
            if not _valid_status_prefix(h.data["_status_code"]):
                raise Error("openapi: bad _status_code (need \"NNN Reason\") in "
                            + h.name + ": " + h.data["_status_code"])
        if "_responses" in h.data and h.data["_responses"] != "":
            var entries = h.data["_responses"].split(";")
            for j in range(len(entries)):
                var e = String(entries[j])
                if e == "":
                    continue
                if not _valid_response_entry(e):
                    raise Error("openapi: bad _responses entry (need \"NNN:desc\") in "
                                + h.name + ": " + e)
                var st = String(e[byte=0:3])
                if st == primary_status_key(h):
                    raise Error("openapi: _responses status " + st
                                + " duplicates primary status in " + h.name)
