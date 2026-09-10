# src/fastapi_mojo/openapi.mojo
#
# F4: OpenAPI 3.0 文档生成 (Goal-0002 §1.1) + 决策-52 精化 (ADR-0027).
# 从 Router 路由表 + Handler.data 声明式生成 spec: paths/{param}/
# _reads_headers/_param_types/_error_map/_body_schema/multipart/form;
# operation 键序 P24-4 (tags? summary? description? operationId ...
# responses, security?, deprecated?); 根键序 P24-10 (openapi, info,
# servers?, paths, components?, tags?, externalDocs?). GET /docs =
# Swagger UI (unpkg CDN; 离线用户自部署 swagger-ui-dist). 不做: schema
# 校验 / $ref 复用 / 3.1.0 迁移 (另立决策). Mojo 1.0.0 无 JSON 库 →
# StringBuilder 直拼 + json_escape.

from router import Router, Route
from handler import Handler
from params_typed import get_param_types
from params_query_extra import get_param_aliases, get_param_descs
from header_params import parse_header_entry  # 决策-53 (ADR-0028): header param 名 = wire 名
from param_constraints import get_param_constraints, get_header_types
from numlit import parse_type_spec, parse_base
from body_schema import (FieldSpec, ParsedSchema, parse_body_schema, get_field, field_count,
                         _split_top, _trim, _parse_range)
from openapi_schemas import _openapi_object_schema, _generate_parameter
from form_params import (form_has_declaration, form_openapi_schema,
                         form_request_body_required, lower_ascii,
                         form_field_names_ordered, get_form_types,
                         get_form_aliases, _cap_name, _openapi_form_field_schema)
from string_builder import StringBuilder
from openapi_multipart import (multipart_openapi_schema, multipart_request_body_required, multipart_route)
from json import json_escape
from openapi_custom import (default_summary, default_operation_id,
                             openapi_info_json, openapi_servers_json,
                             openapi_root_tags_json, openapi_external_docs_json,
                             parse_response_entries, primary_status_key)

def _path_to_openapi(path: String) -> String:
    """把 /items/{item_id} -> /items/{item_id} (OpenAPI 兼容, 不改)."""
    return path

def _extract_path_params(path: String) -> List[String]:
    """提取 path 里的 {param} 名字列表. 顺序按 path 出现顺序."""
    var out = List[String]()
    var n = path.byte_length()
    var i = 0
    while i < n:
        if ord(path[byte=i]) == 123:  # '{'
            var j = i + 1
            while j < n and ord(path[byte=j]) != 125:
                j += 1
            if j < n:
                out.append(String(path[byte=i + 1:j]))
                i = j + 1
                continue
        i += 1
    return out^
def _route_hidden(r: Route) raises -> Bool:
    """`include_in_schema=False` 声明 (决策-52, P24-13): `_include_in_schema="0"`
    → 路由可服务但不进 spec paths/components."""
    return ("_include_in_schema" in r.handler.data
            and r.handler.data["_include_in_schema"] == "0")


def _generate_operation(route: Route) raises -> String:
    """生成单个 operation 对象 JSON 字符串. 键序 P24-4 (决策-52, ADR-0027):
    tags?, summary?, description?, operationId, parameters?, requestBody?,
    responses, security?, deprecated?. summary 默认 = name title-case
    (P24-5); operationId 默认 = {name}{path 逐 /{ }→_}_{method} (P24-6);
    responses 主键 = _status_code 前 3 位 (缺省 "200"), 描述 =
    _response_description 或 "Successful Response" (P24-7/8); _responses
    追加额外状态码 (仅 description); _error_map (决策-24 F2) 保留原行为."""
    var sb = StringBuilder()
    var h = route.handler.copy()
    var started = False

    # tags (决策-37 APIRouter): handler.data["_tags"] CSV -> "tags":["a","b"].
    if "_tags" in h.data:
        var tags_csv = h.data["_tags"]
        var tarr = List[String]()
        var tn = tags_csv.byte_length()
        var tstart = 0
        var ti = 0
        while ti <= tn:
            var tis = (ti == tn) or (ord(tags_csv[byte=ti]) == 44)  # ','
            if tis:
                if ti > tstart:
                    var tp = String(tags_csv[byte=tstart:ti])
                    var tb = 0
                    var te = tp.byte_length()
                    while tb < te and (ord(tp[byte=tb]) == 32 or ord(tp[byte=tb]) == 9):
                        tb += 1
                    while te > tb and (ord(tp[byte=te - 1]) == 32 or ord(tp[byte=te - 1]) == 9):
                        te -= 1
                    if te > tb:
                        tarr.append("\"" + json_escape(String(tp[byte=tb:te])) + "\"")
                tstart = ti + 1
            ti += 1
        if len(tarr) > 0:
            if started:
                sb.append(",")
            sb.append("\"tags\":" + "[" + ",".join(tarr) + "]")
            started = True

    # summary (P24-5: 显式 _summary; 空/缺 → name title-case; 仍空 → 省略键)
    var sum = ""
    if "_summary" in h.data:
        sum = h.data["_summary"]
    if sum == "":
        sum = default_summary(h.name)
    if sum != "":
        if started:
            sb.append(",")
        sb.append("\"summary\":" + "\"" + json_escape(sum) + "\"")
        started = True

    # description (P24-4: 缺省/空 → 省略键)
    if "_description" in h.data and h.data["_description"] != "":
        if started:
            sb.append(",")
        sb.append("\"description\":" + "\"" + json_escape(h.data["_description"]) + "\"")
        started = True

    # operationId (P24-6 默认公式; 显式 _operation_id 覆盖)
    var opid = ""
    if "_operation_id" in h.data and h.data["_operation_id"] != "":
        opid = h.data["_operation_id"]
    if opid == "":
        opid = default_operation_id(h.name, route.path, route.method)
    if started:
        sb.append(",")
    sb.append("\"operationId\":" + "\"" + json_escape(opid) + "\"")
    started = True

    # parameters: path 段 + _reads_headers + query(_param_types 里的 query)
    var params = List[String]()
    var path_params = _extract_path_params(route.path)
    var type_spec = get_param_types(h)
    var cons = get_param_constraints(h)
    var htypes = get_header_types(h)
    var aliases = get_param_aliases(h)
    var descs = get_param_descs(h)
    for p in path_params:
        var tn = "string"
        if p in type_spec:
            tn = type_spec[p]
        var ds = ""
        if p in descs:
            ds = descs[p]
        params.append(_generate_parameter(p, "path", tn, True, ds, cons))

    # _reads_headers
    if "_reads_headers" in h.data:
        var hdrs_csv = h.data["_reads_headers"]
        var n = hdrs_csv.byte_length()
        var start = 0
        var i = 0
        while i <= n:
            var is_sep = (i == n) or (ord(hdrs_csv[byte=i]) == 44)  # ','
            if is_sep:
                if i > start:
                    var piece = String(hdrs_csv[byte=start:i])
                    # trim
                    var b = 0
                    var e = piece.byte_length()
                    while b < e and (ord(piece[byte=b]) == 32 or ord(piece[byte=b]) == 9):
                        b += 1
                    while e > b and (ord(piece[byte=e - 1]) == 32 or ord(piece[byte=e - 1]) == 9):
                        e -= 1
                    if e > b:
                        var hn = String(piece[byte=b:e])
                        # 决策-53 (ADR-0028): _reads_headers 条目 "name=alias" / "name"
                        var hp = parse_header_entry(hn)
                        # 决策-54 (ADR-0029): htypes/descs/cons 全部按声明名 keyed —
                        # 查找必须用 hp[0] (声明名), 输出名 = hp[1] (wire).
                        # cons 表: _generate_parameter 按 param_name (wire) 查;
                        # wire≠声明时注入别名条目, 否则 alias header 的约束全部丢失
                        # (X-Ver 只剩 {"type":"string"}).
                        if hp[0] != hp[1] and hp[0] in cons:
                            cons[hp[1]] = cons[hp[0]]
                        var hds = ""
                        if hp[0] in descs:
                            hds = descs[hp[0]]
                        var hspec = "string"
                        var hreq = False
                        if hp[0] in htypes:
                            hspec = htypes[hp[0]]
                            var hts = parse_type_spec(htypes[hp[0]])
                            var hpb = parse_base(hts.base_type)
                            if hpb.ok:
                                if hts.is_list:
                                    hreq = not hts.default_present
                                else:
                                    hreq = hts.default_value == ""
                        params.append(_generate_parameter(hp[1], "header", hspec, hreq, hds, cons))
                start = i + 1
            i += 1

    # query params (type_spec 中非 path 的项; 决策-43: name = alias 或 key)
    for k in type_spec:
        var is_path = False
        for p in path_params:
            if p == k:
                is_path = True
                break
        if not is_path:
            var ts_str = type_spec[k]
            var name = k
            if k in aliases:
                name = aliases[k]
                # 决策-54: cons 按声明名 keyed, _generate_parameter 按 (alias) 名查 —
                # 加别名条目 (与 header 分支同型)
                if k in cons:
                    cons[name] = cons[k]
            var ds = ""
            if k in descs:
                ds = descs[k]
            var has_default = False
            for j in range(ts_str.byte_length()):
                if ord(ts_str[byte=j]) == 61:
                    has_default = True
                    break
            # query param: optional if has default (list: 显式 '=' = 空 list 默认), else required
            params.append(_generate_parameter(name, "query", ts_str, not has_default, ds, cons))

    if len(params) > 0:
        if started:
            sb.append(",")
        sb.append("\"parameters\":" + "[" + ",".join(params) + "]")
        started = True

    # 决策-38: requestBody (from _body_schema declaration) -> $ref components/schemas/<name>
    if "_body_schema" in h.data and h.data["_body_schema"] != "":
        if started:
            sb.append(",")
        sb.append("\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/" + json_escape(h.name) + "\"}}}}")
        started = True

    # 决策-45/46: requestBody — multipart 路由 (文件字段, 或
    # _multipart + form 声明) -> multipart/form-data $ref; 否则 urlencoded
    # form 声明 (与 _body_schema 互斥; Body_<name>_<method> 命名偏差 ADR-0020 §3.5-4)
    var has_json_body = "_body_schema" in h.data and h.data["_body_schema"] != ""
    var rb_name = "Body_" + h.name + "_" + lower_ascii(route.method)
    if multipart_route(h) and not has_json_body:
        var rb_req = ""
        if multipart_request_body_required(h):
            rb_req = "\"required\":true,"
        if started:
            sb.append(",")
        sb.append("\"requestBody\":{" + rb_req + "\"content\":{\"multipart/form-data\":{\"schema\":{\"$ref\":\"#/components/schemas/" + json_escape(rb_name) + "\"}}}}")
        started = True
    elif not multipart_route(h) and form_has_declaration(h) and not has_json_body:
        var rb_req2 = ""
        if form_request_body_required(h):
            rb_req2 = "\"required\":true,"
        if started:
            sb.append(",")
        sb.append("\"requestBody\":{" + rb_req2 + "\"content\":{\"application/x-www-form-urlencoded\":{\"schema\":{\"$ref\":\"#/components/schemas/" + json_escape(rb_name) + "\"}}}}")
        started = True

    # responses: 主键 primary_status_key (_status_code 前 3 位, 缺省 "200")
    # + 描述 (_response_description 或 "Successful Response") + content
    # (决策-52 P24-7/8); _responses 额外状态码 (P24-9 仅 description);
    # _error_map (决策-24 F2) 派生错误码 (原行为保留)
    var pk = primary_status_key(h)
    var rd = ""
    if "_response_description" in h.data and h.data["_response_description"] != "":
        rd = h.data["_response_description"]
    if rd == "":
        rd = "Successful Response"
    var responses = StringBuilder()
    responses.append("\"" + pk + "\":{\"description\":\"" + json_escape(rd) + "\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\"}}}}")
    if "_responses" in h.data and h.data["_responses"] != "":
        var extra = parse_response_entries(h.data["_responses"])
        for i in range(len(extra)):
            responses.append(",\"" + extra[i][0] + "\":{\"description\":" + "\""
                             + json_escape(extra[i][1]) + "\"}")
    if "_error_map" in h.data:
        var errmap = h.data["_error_map"]
        var n = errmap.byte_length()
        var start = 0
        var i = 0
        while i <= n:
            var is_sep = (i == n) or (ord(errmap[byte=i]) == 59)
            if is_sep:
                if i > start:
                    var entry = String(errmap[byte=start:i])
                    # find second colon (after status code)
                    var c1 = -1
                    for j in range(entry.byte_length()):
                        if ord(entry[byte=j]) == 58:
                            c1 = j
                            break
                    var c2 = -1
                    for j in range(c1 + 1, entry.byte_length()):
                        if ord(entry[byte=j]) == 58:
                            c2 = j
                            break
                    if c1 > 0 and c2 > 0:
                        var status_str = String(entry[byte=c1 + 1:c2])
                        var detail = String(entry[byte=c2 + 1:entry.byte_length()])
                        responses.append(",\"" + status_str + "\":{\"description\":\"" + json_escape(detail) + "\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"properties\":{\"detail\":{\"type\":\"string\"}}}}}}")
                start = i + 1
            i += 1
    if started:
        sb.append(",")
    sb.append("\"responses\":{" + responses.take() + "}")
    # 决策-44: _auth=oauth2 -> operation-level security (OpenAPI 3.0 OAuth2 scheme 引用)
    if "_auth" in h.data and h.data["_auth"] == "oauth2":
        sb.append(",\"security\":[{\"OAuth2PasswordBearer\":[]}]")
    # P24-4: deprecated (仅 true 时出现; check_openapi_specs 已注册期校验 ∈ {"","1"})
    if "_deprecated" in h.data and h.data["_deprecated"] == "1":
        sb.append(",\"deprecated\":true")
    return sb.take()

def generate_openapi(router: Router, title: String, version: String, description: String,
                     terms: String, contact: String, license: String, servers_csv: String,
                     tags_csv: String, extdocs: String) raises -> String:
    """从 Router 生成完整 OpenAPI 3.0 JSON 字符串 (决策-52, ADR-0027).

    - 仅 HTTP 路由; WS 路由不导出 (OpenAPI 暂未标准化 WS).
    - 根键序 P24-10: openapi, info, servers?, paths, components?, tags?,
      externalDocs? (缺省项省略).
    - info 键序 P24-1 (openapi_info_json; 畸形 env → 省略字段, 不 500).
    - `_include_in_schema="0"` 路由不进 paths/components (P24-13: 仍可服务).
    """
    var sb = StringBuilder()
    sb.append("{\"openapi\":\"3.0.3\",")
    sb.append("\"info\":" + openapi_info_json(title, version, description, terms, contact, license) + ",")
    # servers (P24-3: 键序 url, description; url 原样透传; 空/全无效 → 省略键)
    var servers_json = openapi_servers_json(servers_csv)
    if servers_json != "[]":
        sb.append("\"servers\":" + servers_json + ",")
    # paths (决策-37: 同 path 多 method 合并进单个 key; 决策-52: 跳过 hidden
    # 路由 — `_include_in_schema="0"` 可服务但不进 spec).
    sb.append("\"paths\":{")
    var total = router.route_count()
    var first = True
    for i in range(total):
        if _route_hidden(router.routes[i]):
            continue
        # 去重: 仅统计更早的**可见**同 path 路由 (首个可见 = 组头;
        # hidden 先行时不阻止后续可见路由成组)
        var seen = False
        for k in range(i):
            if router.routes[k].path == router.routes[i].path and not _route_hidden(router.routes[k]):
                seen = True
                break
        if seen:
            continue
        if not first:
            sb.append(",")
        first = False
        sb.append("\"" + json_escape(_path_to_openapi(router.routes[i].path)) + "\":{")
        var first_method = True
        for j in range(total):
            if router.routes[j].path != router.routes[i].path:
                continue
            if _route_hidden(router.routes[j]):
                continue
            if not first_method:
                sb.append(",")
            first_method = False
            sb.append("\"" + router.routes[j].method + "\":{" + _generate_operation(router.routes[j]) + "}")
        sb.append("}")
    sb.append("}")
    # 决策-38: components/schemas (from _body_schema declaration, handler.name 去重)
    # 决策-52: 跳过 hidden 路由 (其 schema 不被任何 paths $ref 引用)
    var schemas = List[String]()
    var s_names = List[String]()
    for i in range(total):
        if _route_hidden(router.routes[i]):
            continue
        if "_body_schema" in router.routes[i].handler.data and router.routes[i].handler.data["_body_schema"] != "":
            var nm = router.routes[i].handler.name
            var dup = False
            for x in s_names:
                if x == nm:
                    dup = True
                    break
            if not dup:
                s_names.append(nm)
                var sch = _openapi_object_schema(router.routes[i].handler.data["_body_schema"])
                schemas.append("\"" + json_escape(nm) + "\":" + sch)
    # 决策-45/46: body schemas — multipart (文件字段 /
    # _multipart+form) 与 urlencoded form (与 _body_schema 互斥)
    var f_names = List[String]()
    for i in range(total):
        if _route_hidden(router.routes[i]):
            continue
        var m = router.routes[i].method
        var has_json = ("_body_schema" in router.routes[i].handler.data
                        and router.routes[i].handler.data["_body_schema"] != "")
        if has_json:
            continue
        var is_mp = multipart_route(router.routes[i].handler)
        if not is_mp and not form_has_declaration(router.routes[i].handler):
            continue
        var fname = "Body_" + router.routes[i].handler.name + "_" + lower_ascii(m)
        var dup2 = False
        for x in f_names:
            if x == fname:
                dup2 = True
                break
        if not dup2:
            f_names.append(fname)
            if is_mp:
                schemas.append("\"" + json_escape(fname) + "\":" + multipart_openapi_schema(router.routes[i].handler, m))
            else:
                schemas.append("\"" + json_escape(fname) + "\":" + form_openapi_schema(router.routes[i].handler, m))
    # 决策-44: components = schemas (决策-38) + securitySchemes (oauth2 路由存在时)
    var comps = List[String]()
    if len(schemas) > 0:
        comps.append("\"schemas\":{" + ",".join(schemas) + "}")
    var has_oauth2 = False
    for i in range(total):
        if _route_hidden(router.routes[i]):
            continue
        if "_auth" in router.routes[i].handler.data and router.routes[i].handler.data["_auth"] == "oauth2":
            has_oauth2 = True
            break
    if has_oauth2:
        comps.append("\"securitySchemes\":{\"OAuth2PasswordBearer\":{\"type\":\"http\",\"scheme\":\"bearer\",\"bearerFormat\":\"JWT\"}}")
    if len(comps) > 0:
        sb.append(",\"components\":{" + ",".join(comps) + "}")
    # 根 tags (P24-2 / §3.5-9: openapi_tags 独立 — 路由级 tags **不**并入;
    # 空/全无效 → 省略键)
    var root_tags = openapi_root_tags_json(tags_csv)
    if root_tags != "[]":
        sb.append(",\"tags\":" + root_tags)
    # externalDocs (P24-10 键序: description 先, url 后; 空/无效 → 省略键)
    var ext = openapi_external_docs_json(extdocs)
    if ext != "":
        sb.append(",\"externalDocs\":" + ext)
    sb.append("}")
    return sb.take()

def swagger_ui_html(title: String, openapi_url: String) -> String:
    """返回 Swagger UI 嵌入式 HTML (引用 unpkg CDN). 离线场景用户可替换为本地 swagger-ui-dist."""
    return (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"/>" +
        "<title>" + title + " - Swagger UI</title>" +
        "<link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui.css\"/>" +
        "</head><body><div id=\"swagger-ui\"></div>" +
        "<script src=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js\" crossorigin></script>" +
        "<script>window.onload=()=>SwaggerUIBundle({url:\"" + openapi_url + "\",dom_id:\"#swagger-ui\"});</script>" +
        "</body></html>"
    )
