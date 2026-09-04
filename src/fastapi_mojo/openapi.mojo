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


def _type_to_openapi(t: String) -> String:
    """map Mojo 类型名 -> OpenAPI 3.0 type+format."""
    if t == "int": return "integer"
    if t == "float": return "number"
    if t == "bool": return "boolean"
    return "string"  # default


def _generate_parameter(param_name: String, in_: String, type_name: String, required: Bool) -> String:
    """生成单个 OpenAPI parameter 对象 JSON 字符串."""
    var sb = StringBuilder()
    sb.append("{\"name\":\"" + json_escape(param_name) + "\",")
    sb.append("\"in\":\"" + in_ + "\",")
    sb.append("\"required\":" + ("true" if required else "false") + ",")
    if in_ == "path" or in_ == "query":
        sb.append("\"schema\":{\"type\":\"" + _type_to_openapi(type_name) + "\"}}")
    else:  # header
        sb.append("\"schema\":{\"type\":\"string\"}}")
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

    # parameters: path 段 + _reads_headers + query(_param_types 里的 query)
    var params = List[String]()
    var path_params = _extract_path_params(route.path)
    var type_spec = get_param_types(route.handler)
    for p in path_params:
        var tn = "string"
        if p in type_spec:
            var ts_str = type_spec[p]
            # 解析 "int" / "int=10"
            var base = ts_str
            for k in range(ts_str.byte_length()):
                if ord(ts_str[byte=k]) == 61:  # '='
                    base = String(ts_str[byte=0:k])
                    break
            tn = base
        params.append(_generate_parameter(p, "path", tn, True))

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
                        params.append(_generate_parameter(String(piece[byte=b:e]), "header", "string", False))
                start = i + 1
            i += 1

    # query params (type_spec 中非 path 的项)
    for k in type_spec:
        var is_path = False
        for p in path_params:
            if p == k:
                is_path = True
                break
        if not is_path:
            var ts_str = type_spec[k]
            var base = ts_str
            var has_default = False
            for j in range(ts_str.byte_length()):
                if ord(ts_str[byte=j]) == 61:
                    base = String(ts_str[byte=0:j])
                    has_default = True
                    break
            # query param: optional if has default, else required
            params.append(_generate_parameter(k, "query", base, not has_default))

    if len(params) > 0:
        sb.append("\"parameters\":[" + ",".join(params) + "],")

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
    return sb.take()


def generate_openapi(router: Router, title: String, version: String) raises -> String:
    """从 Router 生成完整 OpenAPI 3.0 JSON 字符串.

    - 仅 HTTP 路由; WS 路由不导出 (OpenAPI 暂未标准化 WS).
    - 422 统一作为默认错误响应 (typed params 校验失败).
    """
    var sb = StringBuilder()
    sb.append("{\"openapi\":\"3.0.3\",")
    sb.append("\"info\":{\"title\":\"" + json_escape(title) + "\",\"version\":\"" + json_escape(version) + "\"},")
    # paths
    sb.append("\"paths\":{")
    var first = True
    for i in range(router.route_count()):
        if not first:
            sb.append(",")
        first = False
        sb.append("\"" + json_escape(_path_to_openapi(router.routes[i].path)) + "\":{")
        sb.append("\"" + router.routes[i].method + "\":{" + _generate_operation(router.routes[i]) + "}")
        sb.append("}")
    sb.append("}}")
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
