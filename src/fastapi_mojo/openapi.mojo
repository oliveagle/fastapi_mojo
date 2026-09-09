# src/fastapi_mojo/openapi.mojo
#
# F4: OpenAPI 3.0 文档生成 (Goal-0002 §1.1).
#
# 设计:
#   - 从 Router 路由表 + Handler.data 类型标注自动生成 OpenAPI 3.0 JSON.
#   - 来源:
#       * route.path + route.method -> paths 段
#       * {param} 段 -> parameters (in: path, required, type from _param_types)
#       * _reads_headers CSV -> parameters (in: header, name)
#       * _error_map -> responses (status: detail)
#       * handler.name -> operationId (默认 "<method>_<path>")
#   - 输出: 标准 OpenAPI 3.0 JSON 字符串, 由 dispatch 在 GET /openapi.json 时直接发.
#   - Swagger UI: 单独路由 GET /docs 返回 HTML, 引用 unpkg 的 swagger-ui-dist
#     (网络可用时即开即用; 离线场景下用户可下载 swagger-ui-dist 自包含部署).
#   - 不做: schema 校验、$ref 复用、components/schemas 抽取 (范围控制, 列入 v0.6.0).
#
# 显式扩展点: 仅 generate_openapi() 一处; 新路由自动出现 (注册 = 显式).
#
# Mojo 1.0.0 约束: 无 dict-of-dict/JSON 库 -> 直接 StringBuilder 拼 JSON; 字符串
# 转义用 json_escape.

from router import Router, Route
from handler import Handler
from params_typed import get_param_types
from params_query_extra import get_param_aliases, get_param_descs
from body_schema import (FieldSpec, ParsedSchema, parse_body_schema, get_field, field_count,
                         _split_top, _trim, _parse_range)
from openapi_schemas import (_type_to_openapi, _json_str_array, _json_list_array, _openapi_object_schema)
from form_params import (form_has_declaration, form_openapi_schema,
                         form_request_body_required, lower_ascii)
from string_builder import StringBuilder
from json import json_escape

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

def _openapi_param_schema(base: String, desc: String) raises -> String:
    """参数 schema (决策-38 enum + 决策-43 list/default/desc).
    "int" / "int=10" (默认) / "str[a,b]" (enum) / "int[]" (array) /
    "int[]=1,2" (array + CSV 默认). list -> {"type":"array","items":
    {"type":"t"},"default":[...]} (仅显式 '=' 带 default); enum ->
    {"type":"t","enum":[...],"default":...}; desc 非空 -> schema 级
    "description" (上游: description 同时出现在 parameter 与 schema)."""
    var n = base.byte_length()
    var eq = -1
    for i in range(n):
        if ord(base[byte=i]) == 61:
            eq = i
            break
    var spec = base
    var default_value = ""
    var has_default = False
    if eq >= 0:
        spec = String(base[byte=0:eq])
        default_value = String(base[byte=eq + 1:n])
        has_default = True
    var sn = spec.byte_length()
    var br = -1
    for i in range(sn):
        if ord(spec[byte=i]) == 91:
            br = i
            break
    var out = ""
    if br >= 0:
        var t = String(spec[byte=0:br])
        var j = br + 1
        var found = -1
        while j < sn:
            if ord(spec[byte=j]) == 93:
                found = j
                break
            j += 1
        var vals = ""
        if found > br:
            vals = String(spec[byte=br + 1:found])
        var ot = _type_to_openapi(t)
        if vals == "":
            # list (决策-43): array; 仅显式 '=' 时带 default
            out = "{\"type\":\"array\",\"items\":{\"type\":\"" + ot + "\"}"
            if has_default:
                out = out + ",\"default\":" + _json_list_array(t, default_value)
        else:
            out = "{\"type\":\"" + ot + "\",\"enum\":" + _json_str_array(vals)
            if has_default:
                out = out + ",\"default\":\"" + json_escape(default_value) + "\""
    else:
        out = "{\"type\":\"" + _type_to_openapi(spec) + "\""
        if has_default:
            if spec == "int" or spec == "float" or spec == "bool":
                out = out + ",\"default\":" + default_value
            else:
                out = out + ",\"default\":\"" + json_escape(default_value) + "\""
    if desc != "":
        out = out + ",\"description\":\"" + json_escape(desc) + "\""
    return out + "}"

def _generate_parameter(param_name: String, in_: String, type_spec: String, required: Bool, desc: String) raises -> String:
    """生成单个 OpenAPI parameter 对象 (type_spec = "int" / "int=10" / "int[]" / "str[a,b]=b").
    desc 非空 -> parameter 级 "description" (上游 Query/Path(description=...))."""
    var sb = StringBuilder()
    sb.append("{\"name\":\"" + json_escape(param_name) + "\",")
    sb.append("\"in\":\"" + in_ + "\",")
    sb.append("\"required\":" + ("true" if required else "false") + ",")
    if in_ == "path" or in_ == "query":
        sb.append("\"schema\":" + _openapi_param_schema(type_spec, desc))
    else:  # header
        sb.append("\"schema\":{\"type\":\"string\"")
        if desc != "":
            sb.append(",\"description\":\"" + json_escape(desc) + "\"")
        sb.append("}")
    if in_ != "header" and desc != "":
        sb.append(",\"description\":\"" + json_escape(desc) + "\"")
    sb.append("}")
    return sb.take()

def _generate_operation(route: Route) raises -> String:
    """生成单个 operation 对象 JSON 字符串. operationId = "<method>_<name>"."""
    var sb = StringBuilder()
    var method_lower = String("")
    # 简化: 取 method 小写
    for i in range(route.method.byte_length()):
        var c = ord(route.method[byte=i])
        if c >= 65 and c <= 90:  # A-Z
            method_lower += chr(c + 32)
        else:
            method_lower += String(route.method[byte=i])
    sb.append("\"operationId\":\"" + json_escape(method_lower + "_" + route.handler.name) + "\",")
    sb.append("\"summary\":\"" + json_escape(route.handler.name) + "\",")

    # tags (决策-37 APIRouter): handler.data["_tags"] CSV -> "tags":["a","b"].
    if "_tags" in route.handler.data:
        var tags_csv = route.handler.data["_tags"]
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
            sb.append("\"tags\":" + "[" + ",".join(tarr) + "],")

    # parameters: path 段 + _reads_headers + query(_param_types 里的 query)
    var params = List[String]()
    var path_params = _extract_path_params(route.path)
    var type_spec = get_param_types(route.handler)
    var aliases = get_param_aliases(route.handler)
    var descs = get_param_descs(route.handler)
    for p in path_params:
        var tn = "string"
        if p in type_spec:
            tn = type_spec[p]
        var ds = ""
        if p in descs:
            ds = descs[p]
        params.append(_generate_parameter(p, "path", tn, True, ds))

    # _reads_headers
    if "_reads_headers" in route.handler.data:
        var hdrs_csv = route.handler.data["_reads_headers"]
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
                        var hds = ""
                        if hn in descs:
                            hds = descs[hn]
                        params.append(_generate_parameter(hn, "header", "string", False, hds))
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
            var ds = ""
            if k in descs:
                ds = descs[k]
            var has_default = False
            for j in range(ts_str.byte_length()):
                if ord(ts_str[byte=j]) == 61:
                    has_default = True
                    break
            # query param: optional if has default (list: 显式 '=' = 空 list 默认), else required
            params.append(_generate_parameter(name, "query", ts_str, not has_default, ds))

    if len(params) > 0:
        sb.append("\"parameters\":[" + ",".join(params) + "],")

    # 决策-38: requestBody (from _body_schema declaration) -> $ref components/schemas/<name>
    if "_body_schema" in route.handler.data and route.handler.data["_body_schema"] != "":
        sb.append("\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/" + json_escape(route.handler.name) + "\"}}}},")

    # 决策-45: form requestBody (from _form_types/_form_fields) -> $ref
    # Body_<name>_<method> (与 _body_schema 互斥; _multipart 路由跳过 — ADR-0020)
    if "_multipart" not in route.handler.data and form_has_declaration(route.handler):
        var has_json_body = "_body_schema" in route.handler.data and route.handler.data["_body_schema"] != ""
        if not has_json_body:
            var rb_req = ""
            if form_request_body_required(route.handler):
                rb_req = "\"required\":true,"
            var rb_name = "Body_" + route.handler.name + "_" + lower_ascii(route.method)
            sb.append("\"requestBody\":{" + rb_req + "\"content\":{\"application/x-www-form-urlencoded\":{\"schema\":{\"$ref\":\"#/components/schemas/" + json_escape(rb_name) + "\"}}}},")

    # responses: default 200 + _error_map 派生错误码
    var responses = StringBuilder()
    responses.append("\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\"}}}}")
    if "_error_map" in route.handler.data:
        var errmap = route.handler.data["_error_map"]
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
                        responses.append(",\"" + status_str + "\":{\"description\":\"" + json_escape(detail) +
                                        "\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"properties\":{\"detail\":{\"type\":\"string\"}}}}}}")
                start = i + 1
            i += 1
    sb.append("\"responses\":{" + responses.take() + "}")
    # 决策-44: _auth=oauth2 -> operation-level security (OpenAPI 3.0 OAuth2 scheme 引用)
    if "_auth" in route.handler.data and route.handler.data["_auth"] == "oauth2":
        sb.append(",\"security\":[{\"OAuth2PasswordBearer\":[]}]")
    return sb.take()

def generate_openapi(router: Router, title: String, version: String) raises -> String:
    """从 Router 生成完整 OpenAPI 3.0 JSON 字符串.

    - 仅 HTTP 路由; WS 路由不导出 (OpenAPI 暂未标准化 WS).
    - 422 统一作为默认错误响应 (typed params 校验失败).
    """
    var sb = StringBuilder()
    sb.append("{\"openapi\":\"3.0.3\",")
    sb.append("\"info\":{\"title\":\"" + json_escape(title) + "\",\"version\":\"" + json_escape(version) + "\"},")
    # paths (决策-37: 同 path 多 method 合并进单个 key — 修复重复 key 产生非法 JSON;
    # APIRouter 合并后 app 路由表天然可能出现同 path 不同 method, 必须分组).
    sb.append("\"paths\":{")
    var first = True
    for i in range(router.route_count()):
        # 去重: 若同 path 已在更早 index 出现过则跳过 (逗号只加在实际输出的组之间)
        var seen = False
        for k in range(i):
            if router.routes[k].path == router.routes[i].path:
                seen = True
                break
        if seen:
            continue
        if not first:
            sb.append(",")
        first = False
        sb.append("\"" + json_escape(_path_to_openapi(router.routes[i].path)) + "\":{")
        var first_method = True
        for j in range(router.route_count()):
            if router.routes[j].path != router.routes[i].path:
                continue
            if not first_method:
                sb.append(",")
            first_method = False
            sb.append("\"" + router.routes[j].method + "\":{" + _generate_operation(router.routes[j]) + "}")
        sb.append("}")
    sb.append("}")
    # 决策-38: components/schemas (from _body_schema declaration, handler.name 去重)
    var schemas = List[String]()
    var s_names = List[String]()
    for i in range(router.route_count()):
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
    # 决策-45: form schemas (Body_<name>_<method>; 与 _body_schema/_multipart 互斥)
    var f_names = List[String]()
    for i in range(router.route_count()):
        var m = router.routes[i].method
        if ("_multipart" not in router.routes[i].handler.data
                and form_has_declaration(router.routes[i].handler)):
            var has_json = ("_body_schema" in router.routes[i].handler.data
                            and router.routes[i].handler.data["_body_schema"] != "")
            if has_json:
                continue
            var fname = "Body_" + router.routes[i].handler.name + "_" + lower_ascii(m)
            var dup2 = False
            for x in f_names:
                if x == fname:
                    dup2 = True
                    break
            if not dup2:
                f_names.append(fname)
                schemas.append("\"" + json_escape(fname) + "\":" + form_openapi_schema(router.routes[i].handler, m))
    # 决策-44: components = schemas (决策-38) + securitySchemes (oauth2 路由存在时)
    var comps = List[String]()
    if len(schemas) > 0:
        comps.append("\"schemas\":{" + ",".join(schemas) + "}")
    var has_oauth2 = False
    for i in range(router.route_count()):
        if "_auth" in router.routes[i].handler.data and router.routes[i].handler.data["_auth"] == "oauth2":
            has_oauth2 = True
            break
    if has_oauth2:
        comps.append("\"securitySchemes\":{\"OAuth2PasswordBearer\":{\"type\":\"http\",\"scheme\":\"bearer\",\"bearerFormat\":\"JWT\"}}")
    if len(comps) > 0:
        sb.append(",\"components\":{" + ",".join(comps) + "}")
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
