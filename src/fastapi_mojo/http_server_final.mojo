# src/fastapi_mojo/http_server_final.mojo
#
# Final HTTP server: json.mojo + router.mojo + handler.mojo + params.mojo + static files
# Features: CORS, graceful shutdown, HEAD support, request ID, timing, static files
# Handler dispatch per ADR-0004: the core only calls run_handler(); the route
# table is built by register_routes() (user code = data).

from std.ffi import external_call, c_char, CStringSlice
from json import json_serialize_dict
from router import Router, RouteMatch
from handler import Handler, ServerInfo, run_handler, KIND_ECHO, KIND_STATIC, KIND_STATUS, KIND_ROUTES, KIND_TEMPLATE, KIND_HTML, KIND_RUN_CMD, KIND_WS_ECHO, KIND_WS_COUNTER, KIND_WS_GREET, KIND_OAUTH2_TOKEN
from params_query import parse_path_params, parse_query_params, url_decode, ParsedParams
from params_json import parse_body_json
from params_typed import validate_params_collect, get_param_types
from params_query_extra import apply_query_extras, get_param_aliases
from body_validate import validate_body_schema, check_body_schemas
from exceptions import build_exception_body, match_error_map, HTTPExceptionSpec, standard_status_line
from request_response import _parse_cookies, parse_form_multi, _split_csv, nest_dict, nest_list, nest_raw, parse_response_headers, response_model_body
from file_params import (validate_file_collect,
                         text_multi_map_filtered, apply_file_extras,
                         file_declared_names, get_file_types, get_file_aliases,
                         MpParts)
from dep_cache import DepCache, inject_dep_calls
from file_ops_ffi import snapshot_mp_parts, apply_file_ops
from openapi import generate_openapi, swagger_ui_html, redoc_html, swagger_ui_oauth2_redirect_html
from openapi_custom import check_openapi_specs  # 决策-52 (ADR-0027)
from header_params import parse_header_entry, check_header_specs  # 决策-53 (ADR-0028)
from std.os import getenv  # 决策-52: app 级 OPENAPI env (请求期读, 空 = 默认)
from streaming import build_sse_body, build_sse_body_fields, sse_event_count
from handler import KIND_SSE, KIND_FILE, KIND_REDIRECT
from handler import KIND_DEPENDENCY
from middleware import MiddlewareChain, Middleware, mw_request_id, mw_timing, mw_logging, now_ms
from mw_spec import MWSpec, parse_mw_spec, check_mw_spec, mw_plan_request
from string_builder import decode_utf8_bytes, next_codepoint_len, StringBuilder, span_to_str
from ws_session import run_ws_upgrade, handle_ws_data
from ws_directives import check_ws_specs  # 决策-51 (ADR-0026)
from ws_protocol_routes import register_ws_protocol_routes  # 决策-60 (ADR-0035)
from body_schema_routes import register_body_schema_routes  # 决策-38/57/58/61
from security import AuthResult, check_auth, _get_header
from form_params import (validate_form_collect, apply_form_extras, get_form_types, get_form_aliases, lower_ascii, missing_err_json)
from file_form_check import validate_file_vs_form, file_part_fields
from security_jwt import handle_oauth2_token, check_oauth2  # 决策-44: /token + _auth=oauth2
from lifespan import run_lifespan_startup, run_lifespan_shutdown
from exception_handlers import guarded_run_handler  # 决策-49 (ADR-0024)
from request_state import apply_state_set, inject_request_state, check_state_specs  # 决策-50 (ADR-0025)
from param_constraints import (check_param_constraints, get_param_constraints,
                               get_header_types, parse_reads_headers)
from param_constraints_run import validate_headers_collect, validate_implicit_constraints
from redirect_slashes import alt_slash_path, build_redirect_location  # 决策-71 (ADR-0046)


def inject_request_cookies(mut params: Dict[String, String], cookie_names_csv: String) raises:
    """F10 (v0.5.1): 把 _reads_cookies 声明的 cookie 名按名从 Cookie 头解析, 注入 params.
    key 前缀 cookie_<name>; 缺失 -> 空串. 与 inject_request_headers 同一模式.
    调用一次 extract_request_header("Cookie") 拿整段 Cookie 头, 然后本地 parse_cookies.
    RFC 6265 简化: ';' 分隔 '=' 切, 去空格.
    """
    var rc = external_call["extract_request_header", Int](
        "Cookie".as_c_string_slice())
    if rc != 0:
        return
    var sl = external_call["get_header_value_slice", CStringSlice[origin_of(String(""))]]()
    var cookie_str = span_to_str(sl.as_bytes())
    if cookie_str == "":
        return
    var cookies = _parse_cookies(cookie_str)
    var n = cookie_names_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = False
        if i == n:
            is_sep = True
        elif ord(cookie_names_csv[byte=i]) == 44:
            is_sep = True
        if is_sep:
            if i > start:
                var name = String(cookie_names_csv[byte=start:i])
                # trim
                var b = 0
                var e = name.byte_length()
                while b < e and (ord(name[byte=b]) == 32 or ord(name[byte=b]) == 9):
                    b += 1
                while e > b and (ord(name[byte=e - 1]) == 32 or ord(name[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    var clean = String(name[byte=b:e])
                    var v = String("")
                    if clean in cookies:
                        v = cookies[clean]
                    params["cookie_" + clean] = v
            start = i + 1
        i += 1
def _ct_is_form(ct: String) -> Bool:
    """Form Content-Type 判定 (ADR-0020): 小写化后
    忽略尾部 "; charset=..." — 仅 urlencoded 为真."""
    return lower_ascii(ct).startswith("application/x-www-form-urlencoded")

def _ct_is_multipart(ct: String) -> Bool:
    """Multipart Content-Type 判定 (decision-46): 小写化后
    前缀匹配 'multipart/form-data' (尾部 '; boundary=...' 忽略)."""
    return lower_ascii(ct).startswith("multipart/form-data")

def _exec_one_cmd(cmd_raw: String, timeout_ms: Int, do_log: Bool, tag: String,
                  req_id: String, method: String, path: String) raises:
    """决策-29 / 75: trim + 同步执行单条 shell 命令 (run_command_json FFI) + 日志.
    共享给 _run_background (tag="[bg]") 与 _run_dep_teardowns (tag="[dep-teardown]")."""
    var b = 0
    var e = cmd_raw.byte_length()
    while b < e and (ord(cmd_raw[byte=b]) == 32 or ord(cmd_raw[byte=b]) == 9):
        b += 1
    while e > b and (ord(cmd_raw[byte=e - 1]) == 32 or ord(cmd_raw[byte=e - 1]) == 9):
        e -= 1
    if e <= b:
        return
    var final_cmd = String(cmd_raw[byte=b:e])
    var slice = external_call["run_command_json", CStringSlice[origin_of(String(""))]](
        final_cmd.as_c_string_slice(), Int64(timeout_ms))
    var out = span_to_str(slice.as_bytes())
    _ = external_call["run_command_free", NoneType](slice)
    if do_log:
        print(tag + " req=" + req_id + " " + method + " " + path + " cmd=" + final_cmd
              + " out=" + out[byte=0:min(out.byte_length(), 200)])


def _run_dep_teardowns(teardowns: List[String], req_id: String, method: String,
                       path: String) raises:
    """决策-75 (ADR-0050): Depends(yield) 等价 —— 响应已 flush 后执行依赖 teardown.

    teardowns 元素 = 某依赖的 `_dep_teardown` (换行分隔多命令), 按依赖**解析完成序**
    追加 (子依赖先于父). 本函数**逆序**遍历 = LIFO (上游 `request_async_exit_stack`
    关闭序: 后进入的依赖先 teardown). 每条命令 2000ms timeout + "[dep-teardown]"
    日志 (与 `_background` 同机制, run_command_json FFI)。
    """
    var k = len(teardowns)
    while k > 0:
        k -= 1
        var raw = teardowns[k]
        var n = raw.byte_length()
        var start = 0
        var i = 0
        while i <= n:
            var is_sep = (i == n) or (ord(raw[byte=i]) == 10)  # '\n'
            if is_sep:
                if i > start:
                    _exec_one_cmd(String(raw[byte=start:i]), 2000, True,
                                  "[dep-teardown]", req_id, method, path)
                start = i + 1
            i += 1


def _run_background(handler: Handler, req_id: String, method: String,
                       path: String, query: String) raises:
    """F11 (v0.5.1): BackgroundTasks - 响应已发送后同步执行声明的命令.
    data["_background"] = "cmd1\ncmd2" (换行分隔, 命令内不允许含换行).
    data["_background_timeout_ms"] = "2000" (单条命令 timeout, 默认 2000ms).
    data["_background_log"] = "false" (默认 true: 失败命令日志输出 stdout/stderr/rc).
    对齐 FastAPI/Starlette BackgroundTasks 语义:
      - Starlette: 响应已 flush 后 await BackgroundTask(func) 在同一 event loop.
      - 我们: 响应已 flush 后同步执行 shell 命令 (复用 run_command_json FFI).
        pre-fork 多 worker + SO_REUSEPORT 隔离 worker 阻塞; timeout 防无限挂.
        不 fork/zombie: 同步执行符合 Starlette 语义, 客户端已收到响应.
    """
    if "_background" not in handler.data:
        return
    var cmds_raw = handler.data["_background"]
    if cmds_raw == "":
        return
    var timeout_ms: Int = 2000
    if "_background_timeout_ms" in handler.data:
        var tmo_str = handler.data["_background_timeout_ms"]
        try:
            timeout_ms = atol(String(tmo_str))
        except e:
            timeout_ms = 2000
    var do_log = True
    if "_background_log" in handler.data:
        do_log = handler.data["_background_log"] != "false"

    # 按 '\n' 分隔 (命令天然不含换行, 与现有 SSE 用 '|' / header 用 ',' 一致).
    var n = cmds_raw.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(cmds_raw[byte=i]) == 10)  # '\n'
        if is_sep:
            if i > start:
                _exec_one_cmd(String(cmds_raw[byte=start:i]), timeout_ms, do_log,
                              "[bg]", req_id, method, path)
            start = i + 1
        i += 1


def _finish_request(mw_chain: MiddlewareChain, req_id: String, method: String,
                    path: String, query: String, status: String, duration_ms: Int):
    """Single post-response telemetry hook: access log + optional OTel span.

    Decision-62 keeps tracing at the server boundary so static, OpenAPI, WS
    upgrade, middleware, route, and error paths share one completion semantic.
    FASTAPI_MOJO_OTEL=1 turns on the bounded in-process trace ring.
    """
    mw_logging(mw_chain, req_id, method, path, query, status, duration_ms)
    if getenv("FASTAPI_MOJO_OTEL") == "1":
        var full_path = path
        if query.byte_length() > 0:
            full_path += "?" + query
        var trace_method = method
        var trace_path = full_path
        var trace_query = query
        var trace_status = status
        _ = external_call["otel_trace_record", Int](
            trace_method.as_c_string_slice(),
            trace_path.as_c_string_slice(),
            trace_query.as_c_string_slice(),
            trace_status.as_c_string_slice(),
            duration_ms,
        )


def inject_request_headers(mut params: Dict[String, String], header_names_csv: String):
    """F3a: 把 _reads_headers 声明的 header 名按名从 C 桥读出, 注入 params.
    key 前缀 header_<name>; 缺失 -> 空串. 保持 String-only (与现有 handler 兼容).
    决策-53 (ADR-0028): 条目 = "name" (wire = 下划线→连字符转换, P25-1/4) /
    "name=alias" (wire = alias 原样, P25-3; "name=name" = 字面). 读取仍走
    bridge get_header_value_ci (ASCII 大小写不敏感 + 多值取首, FFI diff = 0)."""
    var n = header_names_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(header_names_csv[byte=i]) == 44)  # ','
        if is_sep:
            if i > start:
                var name = String(header_names_csv[byte=start:i])
                # trim
                var b = 0
                var e = name.byte_length()
                while b < e and (ord(name[byte=b]) == 32 or ord(name[byte=b]) == 9):
                    b += 1
                while e > b and (ord(name[byte=e - 1]) == 32 or ord(name[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    var clean = String(name[byte=b:e])
                    var pn = parse_header_entry(clean)
                    var v = String("")
                    var rc = external_call["extract_request_header", Int](
                        pn[1].as_c_string_slice())
                    # 决策-54 (ADR-0029): FFI 三态 — 0=在场(含空值) / -2=缺席(slice 已清空) /
                    # -1=出错. F3a 注入语义保持: 在场/缺席都注入 (缺席 = 空串).
                    if rc != -1:
                        var sl = external_call["get_header_value_slice", CStringSlice[origin_of(String(""))]]()
                        v = span_to_str(sl.as_bytes())
                    params["header_" + pn[0]] = v
            start = i + 1
        i += 1

def read_headers_present(header_names_csv: String) -> Dict[String, String]:
    """决策-54 (ADR-0029): typed header 校验用 — 逐 _reads_headers 条目读值.
    FFI 三态 (extract_request_header): rc==0 在场 (含空值) -> name->value;
    rc==-2 缺席 -> 不进 dict (missing 语义, 缺失+默认走 default 校验); rc==-1
    出错 -> 不进 dict. 与 inject_request_headers 同款 FFI (get_header_value_ci
    多值取首), 仅保留 present 集合."""
    var out = Dict[String, String]()
    var n = header_names_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(header_names_csv[byte=i]) == 44)  # ','
        if is_sep:
            if i > start:
                var name = String(header_names_csv[byte=start:i])
                var b = 0
                var e = name.byte_length()
                while b < e and (ord(name[byte=b]) == 32 or ord(name[byte=b]) == 9):
                    b += 1
                while e > b and (ord(name[byte=e - 1]) == 32 or ord(name[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    var clean = String(name[byte=b:e])
                    var pn = parse_header_entry(clean)
                    var nn = pn[1]  # wire (local: as_c_string_slice 需非 rvalue)
                    var rc = external_call["extract_request_header", Int](nn.as_c_string_slice())
                    if rc == 0:
                        var sl = external_call["get_header_value_slice", CStringSlice[origin_of(String(""))]]()
                        var kn = pn[0]
                        out[kn] = span_to_str(sl.as_bytes())
            start = i + 1
        i += 1
    return out^

# ---------- F-DI (Depends, 决策-33): 依赖注入 ----------

def _split_depends(s: String) -> List[String]:
    """F-DI: 按 ';' 切 _depends CSV, 去空白. 复用已 import 且已验证 byte-slice 的 _split_csv,
    分隔符由 ',' (44) 换为 ';' (59)."""
    return _split_csv(s, 59)


def dispatch_dep(router: Router,
                 dep: Handler,
                 mut target: Dict[String, String],
                 info: ServerInfo,
                 query: ParsedParams,
                 body: ParsedParams,
                 visited: List[String],
                 nocache: Bool,
                 mut cache: DepCache,
                 mut teardowns: List[String]) raises -> Bool:
    """F-DI + 决策-47 (ADR-0022): 递归解析并派发一个依赖 (KIND_DEPENDENCY),
    输出注入 target (前缀 depname_key).

    dep 自身的 runtime = dep.data + 其 _depends / _depends_nocache 子依赖输出
    (子依赖递归派发后并入), 使其 run_handler (返回非 '_' 前缀字段) 可见.
    use_cache 语义 (上游 0.141.1 probe P9-1..P9-5):
      - cached 引用 (nocache=False, upstream use_cache=True 默认): 本 dep name
        已有 memo -> 重注入, 跳过重新派发 (菱形/三重菱形 = 1 次, P9-1/P9-5);
      - nocache 引用 (nocache=True, upstream use_cache=False): 恒重新派发,
        结果追加 memo 表 (后续 cached 引用复用最新条, P9-3);
      - visited (当前依赖链) = 环检测基准: dep 是自身祖先 -> 跳过 (优先于 memo).
    Returns True = 至少注入一个输出 (含 memo 重注入).
    """
    if dep.name in visited:
        return False
    var child_visited = visited.copy()
    child_visited.append(dep.name)

    var runtime = dep.data.copy()
    if "_depends" in runtime:
        var names = _split_depends(runtime["_depends"])
        var i = 0
        while i < len(names):
            var nested = router.find_handler_by_name(names[i])
            if nested.name != "":
                # 子依赖输出并入 runtime (dep 自身的 runtime), 使其 run_handler 可见.
                # 默认 cached 引用 (upstream use_cache=True).
                dispatch_dep(router, nested, runtime, info, query, body,
                             child_visited, False, cache, teardowns)
            i += 1
    if "_depends_nocache" in runtime:
        var names_nc = _split_depends(runtime["_depends_nocache"])
        var j = 0
        while j < len(names_nc):
            var nested_nc = router.find_handler_by_name(names_nc[j])
            if nested_nc.name != "":
                # nocache 引用 (upstream use_cache=False).
                dispatch_dep(router, nested_nc, runtime, info, query, body,
                             child_visited, True, cache, teardowns)
            j += 1

    # memo 查找 (仅 cached 引用; P9-3: nocache 派发的结果同样入库).
    var mi = cache.find(dep.name)
    if mi >= 0 and not nocache:
        cache.inject(dep.name, mi, target)
        return True

    # 决策-75 (ADR-0050): Depends(yield) 等价 —— 该依赖**实际派发**时登记其
    # teardown (memo 命中不登记 -> use_cache=True 每请求一次; 子依赖已先登记 =
    # 解析完成序), 响应后逆序执行 (LIFO = 上游 request AsyncExitStack 关闭序).
    if "_dep_teardown" in dep.data and dep.data["_dep_teardown"] != "":
        teardowns.append(dep.data["_dep_teardown"])

    # 派发依赖 (KIND_DEPENDENCY 返回非 '_' 前缀字段, 含已并入的子依赖输出).
    var dep_h = Handler(dep.kind, dep.name)
    dep_h.data = runtime.copy()
    var rt = run_handler(dep_h, Dict[String, String](), query, body, info)
    var dep_outputs = rt[1].copy()
    # 入库: cached 引用 = 无 memo 时存; nocache = 恒追加新条 (P9-3 覆写语义).
    var okeys = List[String]()
    var ovals = List[String]()
    for k in dep_outputs:
        okeys.append(k)
        ovals.append(dep_outputs[k])
    cache.append(dep.name, okeys, ovals)
    for k in dep_outputs:
        target[dep.name + "_" + k] = dep_outputs[k]
    return len(dep_outputs) > 0

def resolve_depends(router: Router,
                    dep: Handler,
                    mut target: Dict[String, String],
                    info: ServerInfo,
                    query: ParsedParams,
                    body: ParsedParams,
                    visited: List[String],
                    mut cache: DepCache,
                    mut teardowns: List[String]) raises -> Bool:
    """F-DI (Depends, 决策-33/47): 解析主 handler 声明的 _depends (默认 cached)
    与 _depends_nocache (upstream use_cache=False), 派发每个直接依赖并注入
    输出到 target (前缀 depname_outputkey). 不派发 dep 自身 (由 dispatch 派发).
    语义对齐 FastAPI Depends(): 可复用计算 / 嵌套依赖 / 鉴权前置 + 每请求
    memo 表 (决策-47 use_cache). 解析序: 先 _depends (CSV 序) 后
    _depends_nocache (CSV 序). visited 为环检测基准 (含主 handler name).
    """
    var any = False
    var base_visited = visited.copy()
    base_visited.append(dep.name)
    if "_depends" in dep.data:
        var names = _split_depends(dep.data["_depends"])
        var i = 0
        while i < len(names):
            var nested = router.find_handler_by_name(names[i])
            if nested.name != "":
                if dispatch_dep(router, nested, target, info, query, body,
                                base_visited, False, cache, teardowns):
                    any = True
            i += 1
    if "_depends_nocache" in dep.data:
        var names_nc = _split_depends(dep.data["_depends_nocache"])
        var j = 0
        while j < len(names_nc):
            var nested_nc = router.find_handler_by_name(names_nc[j])
            if nested_nc.name != "":
                if dispatch_dep(router, nested_nc, target, info, query, body,
                                base_visited, True, cache, teardowns):
                    any = True
            j += 1
    return any

def build_error_response(status: String, message: String) -> Dict[String, String]:
    """Build error response data. FastAPI 语义: 统一 {detail, status} (Goal-0002 F2).
    向后兼容: e2e 只检查状态码, 不检查 body 字段名."""
    var resp = Dict[String, String]()
    resp["detail"] = message
    resp["status"] = status
    return resp^


def is_static_path(path: String) -> Bool:
    """Check if path should be served as a static file.

    Only paths with a known file extension are treated as static, so API
    routes (e.g. /hello, /items/42) are never misrouted. Previously ANY path
    containing a dot was treated as static (bug).
    """
    # Find the LAST dot (boundary-aware; '.' is ASCII so codepoint steps
    # always land on boundaries).
    var idx = -1
    var i = 0
    var n = path.byte_length()
    while i < n:
        if path[byte=i] == '.':
            idx = i
        i += next_codepoint_len(path, i)
    if idx < 0:
        return False
    var ext = path[byte=idx:]
    var known: List[String] = [
        ".html", ".htm", ".css", ".js", ".mjs", ".json", ".xml", ".txt",
        ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".webp",
        ".woff", ".woff2", ".pdf", ".map", ".css.map",
    ]
    for k in known:
        if ext == k:
            return True
    return False


# 路由表 (用户代码 = 纯数据, ADR-0004): 新增路由不需要改动核心 dispatch.
def register_routes(mut router: Router) raises:
    var index_h = Handler(KIND_STATIC(), "index")
    index_h.set_data("message", "Welcome to Mojo HTTP Server")
    index_h.set_data("version", "1.8.0")
    router.add_route("/", "GET", index_h)

    var health_h = Handler(KIND_STATIC(), "health")
    health_h.set_data("status", "healthy")
    health_h.set_data("uptime", "running")
    router.add_route("/health", "GET", health_h)

    router.add_route("/status", "GET", Handler(KIND_STATUS(), "status"))
    router.add_route("/routes", "GET", Handler(KIND_ROUTES(), "routes"))

    var hello_h = Handler(KIND_TEMPLATE(), "hello")
    hello_h.set_data("message", "Hello from Mojo!")
    hello_h.set_data("greeting", "Hello, {name}!")
    router.add_route("/hello", "GET", hello_h)

    var list_h = Handler(KIND_STATIC(), "list_items")
    list_h.set_data("items", "[]")
    list_h.set_data("message", "List all items")
    router.add_route("/items", "GET", list_h)

    var create_h = Handler(KIND_ECHO(), "create_item")
    create_h.set_data("message", "Item created")
    create_h.set_data("_body_prefix", "item_")
    router.add_route("/items", "POST", create_h)

    var get_h = Handler(KIND_ECHO(), "get_item")
    get_h.set_data("message", "Get item by ID")
    router.add_route("/items/{item_id}", "GET", get_h)

    var delete_h = Handler(KIND_ECHO(), "delete_item")
    delete_h.set_data("message", "Item deleted")
    router.add_route("/items/{item_id}", "DELETE", delete_h)

    # 验收路由 (ADR-0004 §4): 回显全部参数 — 注册 = 两行数据, 核心零改动
    router.add_route("/echo", "GET", Handler(KIND_ECHO(), "echo"))
    router.add_route("/echo", "POST", Handler(KIND_ECHO(), "echo"))

    # F1 类型化参数 demo (Goal-0002 §1.1): 声明式类型标注.
    #   /calc/{a}/{b}: a,b 必须为 int (path 参数强制必填).
    #   /typed?count=N&verbose=true: count int=5 (query 默认值), verbose bool (可选).
    var calc_h = Handler(KIND_ECHO(), "calc")
    calc_h.set_data("message", "Typed calc")
    calc_h.set_data("_param_types", "a:int;b:int")
    router.add_route("/calc/{a}/{b}", "GET", calc_h)

    var typed_h = Handler(KIND_ECHO(), "typed")
    typed_h.set_data("message", "Typed query")
    typed_h.set_data("_param_types", "count:int=5;verbose:bool")
    router.add_route("/typed", "GET", typed_h)

    # F2 声明式异常映射 demo (Goal-0002 §1.1): Handler.data["_error_map"]
    #   /errors/{item_id}: item_id=99 -> 404 (Item not found); 其它 int -> 422 (Invalid ID).
    #   命中时直接返回 {status, detail}, 不进 run_handler (FastAPI HTTPException 语义).
    var errors_h = Handler(KIND_ECHO(), "errors_demo")
    errors_h.set_data("message", "Error map demo")
    errors_h.set_data("_error_map", "item_id=99:404:Item not found;item_id=*:422:Invalid ID")
    router.add_route("/errors/{item_id}", "GET", errors_h)

    # F3 Request/Response + 嵌套 JSON demo (Goal-0002 §1.1):
    #   /ctx: 读 X-Custom header, 回显到 JSON 字段; 设 X-Handler: ctx 响应头; data 是嵌套 dict.
    #   /tags: tags 字段是嵌套 list.
    var ctx_h = Handler(KIND_ECHO(), "ctx")
    ctx_h.set_data("message", "ctx demo")
    ctx_h.set_data("_reads_headers", "X-Custom,User-Agent")
    ctx_h.set_data("_response_headers", "X-Handler: ctx;X-Server: fastapi_mojo")
    router.add_route("/ctx", "GET", ctx_h)

    # 决策-55 (ADR-0030): 用户中间件 demo 目标.
    #   /mw/hdr: HDR 动词目标 (响应体稳定, 外层 mw 加头).
    #   /mw/reqhdr: _reads_headers 回显合成请求头 (REQHDR 注入).
    #   /mw/map-new: 仅经 MAP:/mw/map-old:/mw/map-new 可达 (直连路径未注册).
    var mw_hdr_h = Handler(KIND_ECHO(), "mw_hdr")
    mw_hdr_h.set_data("message", "mw response target")
    router.add_route("/mw/hdr", "GET", mw_hdr_h)

    var mw_reqhdr_h = Handler(KIND_ECHO(), "mw_reqhdr")
    mw_reqhdr_h.set_data("message", "mw req header target")
    mw_reqhdr_h.set_data("_reads_headers", "X-Mw-Inj")
    router.add_route("/mw/reqhdr", "GET", mw_reqhdr_h)

    var mw_mapnew_h = Handler(KIND_ECHO(), "mw_map_new")
    mw_mapnew_h.set_data("message", "mapped here")
    router.add_route("/mw/map-new", "GET", mw_mapnew_h)

    # 嵌套 JSON demo: KIND_ECHO 自动把 resp_data 序列化, 我们构造 resp_data 注入嵌套.
    # 但 KIND_ECHO 当前直接 dict copy 不支持嵌套. 改用 KIND_STATIC + 预构造的 body
    # (用 nest_dict / nest_list 构造的 __nested__: 前缀字符串).
    var tags_h = Handler(KIND_STATIC(), "tags")
    # KIND_STATIC 直接以 handler.data 作为 JSON body 输出. 我们手工构造一个含嵌套的 dict
    # 通过 handler.data + nest_*; 但 handler.data 是 Dict[String,String], 仍受 String 约束.
    # 解决: 在 dispatch 里, KIND_STATIC + 包含 "__nested__:" value 的 dict 走 nest 序列化.
    # 这里简单: tags_h.data["tags"] = nest_list(["a", "b", "c"])
    var tag_items = List[String]()
    tag_items.append("a")
    tag_items.append("b")
    tag_items.append("c")
    var meta_d = Dict[String, String]()
    meta_d["user"] = "1"
    meta_d["role"] = "admin"
    tags_h.set_data("name", "demo")
    tags_h.set_data("tags", nest_list(tag_items))
    tags_h.set_data("meta", nest_dict(meta_d))
    router.add_route("/tags", "GET", tags_h)

    # F-DI (Depends, 决策-33): 依赖注入 demo (对齐 FastAPI Depends()).
    #   get_config (base 依赖): 返回 version/env.
    #   get_auth   (嵌套依赖): _depends=get_config, 返回 user (并"使用" get_config 输出).
    #   /di        (KIND_ECHO): _depends=get_auth, 回显被解析注入的依赖输出
    #                 (前缀 get_auth_outputkey, 嵌套输出双层前缀 get_auth_get_config_xxx).
    router.add_dependency(Handler(KIND_DEPENDENCY(), "get_config"))
    router.dependencies[len(router.dependencies) - 1].set_data("version", "v0.7.0")
    router.dependencies[len(router.dependencies) - 1].set_data("env", "demo")
    router.add_dependency(Handler(KIND_DEPENDENCY(), "get_auth"))
    router.dependencies[len(router.dependencies) - 1].set_data("user", "demo_user")
    router.dependencies[len(router.dependencies) - 1].set_data("_depends", "get_config")
    var di_h = Handler(KIND_ECHO(), "di")
    di_h.set_data("message", "DI demo (Depends)")
    di_h.set_data("_depends", "get_auth")
    router.add_route("/di", "GET", di_h)

    # 决策-47 (ADR-0022): Depends use_cache demo (上游 0.141.1 probe P9-1/2/3;
    # 每请求 memo 表: 默认 cached / _depends_nocache = use_cache=False):
    #   dc_tick  (base 依赖): 返回 tick=TICK.
    #   dc_auth  (_depends=dc_tick, 默认 cached):
    #     /di-cache (_depends=dc_auth;dc_tick) = 菱形 -> dc_tick 仅派发 1 次 (P9-1).
    #   dc_auth2 (_depends_nocache=dc_tick, 嵌套 nocache):
    #     /di-mix (_depends=dc_auth2;dc_tick) -> 直接 cached 引用复用 nocache
    #     派发的入库结果 -> dc_tick 仅 1 次 (P9-3).
    #   /di-nocache (_depends_nocache=dc_auth;dc_tick) -> 嵌套 cached + 直接
    #     nocache = 2 次派发 (P9-2).
    #   _dep_calls=true -> 响应注入 <dep>_calls = 每请求实际派发次数
    #   (observability 超集, 上游无此面; 未声明 = 零输出).
    router.add_dependency(Handler(KIND_DEPENDENCY(), "dc_tick"))
    router.dependencies[len(router.dependencies) - 1].set_data("tick", "TICK")
    router.add_dependency(Handler(KIND_DEPENDENCY(), "dc_auth"))
    router.dependencies[len(router.dependencies) - 1].set_data("user", "dc_user")
    router.dependencies[len(router.dependencies) - 1].set_data("_depends", "dc_tick")
    router.add_dependency(Handler(KIND_DEPENDENCY(), "dc_auth2"))
    router.dependencies[len(router.dependencies) - 1].set_data("user2", "dc_user2")
    router.dependencies[len(router.dependencies) - 1].set_data("_depends_nocache", "dc_tick")
    var dic_h = Handler(KIND_ECHO(), "di_cache")
    dic_h.set_data("message", "DI use_cache demo (diamond cached)")
    dic_h.set_data("_depends", "dc_auth;dc_tick")
    dic_h.set_data("_dep_calls", "true")
    router.add_route("/di-cache", "GET", dic_h)
    var din_h = Handler(KIND_ECHO(), "di_nocache")
    din_h.set_data("message", "DI nocache demo (route refs use_cache=False)")
    din_h.set_data("_depends_nocache", "dc_auth;dc_tick")
    din_h.set_data("_dep_calls", "true")
    router.add_route("/di-nocache", "GET", din_h)
    var dim_h = Handler(KIND_ECHO(), "di_mix")
    dim_h.set_data("message", "DI nested-nocache demo (cached reuses nocache memo)")
    dim_h.set_data("_depends", "dc_auth2;dc_tick")
    dim_h.set_data("_dep_calls", "true")
    router.add_route("/di-mix", "GET", dim_h)

    # 决策-75 (ADR-0050): Depends(yield) 等价 demo (上游 generator 依赖 cleanup).
    #   dep_td_inner (base): _dep_teardown = "echo INNER >> /tmp/fm_dep_td.log"
    #   dep_td_outer (_depends=dep_td_inner): _dep_teardown = "echo OUTER >> ..."
    #     /di-teardown (KIND_ECHO): _depends=dep_td_outer + _background="echo BG >> ..."
    #       响应后序 = BG (background) -> OUTER -> INNER (逆解析序 LIFO, 上游一致:
    #       background 先于 request AsyncExitStack 关闭).
    #     /di-teardown-raise: 同依赖 + _exception_raise -> 异常响应后仍 OUTER -> INNER.
    router.add_dependency(Handler(KIND_DEPENDENCY(), "dep_td_inner"))
    router.dependencies[len(router.dependencies) - 1].set_data("inner_val", "inner")
    router.dependencies[len(router.dependencies) - 1].set_data("_dep_teardown",
        "echo INNER >> /tmp/fm_dep_td.log")
    router.add_dependency(Handler(KIND_DEPENDENCY(), "dep_td_outer"))
    router.dependencies[len(router.dependencies) - 1].set_data("outer_val", "outer")
    router.dependencies[len(router.dependencies) - 1].set_data("_depends", "dep_td_inner")
    router.dependencies[len(router.dependencies) - 1].set_data("_dep_teardown",
        "echo OUTER >> /tmp/fm_dep_td.log")
    var dtd_h = Handler(KIND_ECHO(), "di_teardown")
    dtd_h.set_data("message", "DI teardown demo (Depends yield)")
    dtd_h.set_data("_depends", "dep_td_outer")
    dtd_h.set_data("_background", "echo BG >> /tmp/fm_dep_td.log")
    router.add_route("/di-teardown", "GET", dtd_h)
    var dtdr_h = Handler(KIND_ECHO(), "di_teardown_raise")
    dtdr_h.set_data("message", "DI teardown on exception")
    dtdr_h.set_data("_depends", "dep_td_outer")
    dtdr_h.set_data("_exception_raise", "TdBoom: x")
    dtdr_h.set_data("_exc_handlers", "TdBoom:418:boom")
    router.add_route("/di-teardown-raise", "GET", dtdr_h)
    var dtd2_h = Handler(KIND_ECHO(), "di_teardown_twice")
    dtd2_h.set_data("message", "DI teardown cached once (diamond)")
    dtd2_h.set_data("_depends", "dep_td_outer;dep_td_outer")
    router.add_route("/di-teardown-twice", "GET", dtd2_h)

    # APIRouter (决策-37, FastAPI APIRouter/include_router):
    #   items_api = APIRouter(prefix="/api/items", tags=["items"], dependencies=[api_env])
    #   app.include_router(items_api)
    #   -> 路由变 /api/items 与 /api/items/{item_id}; 全部路由携带 tags=items
    #      + 基础依赖 api_env (输出注入 api_env_env / api_env_ver, 决策-33 机制).
    # 路由用 KIND_ECHO (非 KIND_STATIC): ECHO 过滤 '_' 前缀内部字段, 避免
    # _tags/_depends 泄漏到响应体 (KIND_STATIC 全量 dump 为既有行为, 不在此改动).
    var items_api = Router()
    items_api.set_prefix("/api/items")
    items_api.set_tags("items")
    items_api.add_dependency(Handler(KIND_DEPENDENCY(), "api_env"))
    items_api.dependencies[len(items_api.dependencies) - 1].set_data("env", "api")
    items_api.dependencies[len(items_api.dependencies) - 1].set_data("ver", "v1")
    items_api.set_base_deps("api_env")
    var api_list_h = Handler(KIND_ECHO(), "api_list_items")
    api_list_h.set_data("message", "APIRouter list items")
    items_api.add_route("/", "GET", api_list_h)           # -> /api/items
    var api_get_h = Handler(KIND_ECHO(), "api_get_item")
    api_get_h.set_data("message", "APIRouter get item by ID")
    items_api.add_route("/{item_id}", "GET", api_get_h)   # -> /api/items/{item_id}
    router.include_router(items_api)

    # include 级 prefix (FastAPI app.include_router(r, prefix="/v1")):
    var v1_api = Router()
    v1_api.set_tags("v1")
    var v1_ping_h = Handler(KIND_ECHO(), "v1_ping")
    v1_ping_h.set_data("pong", "v1")
    v1_api.add_route("/ping", "GET", v1_ping_h)           # -> /v1/ping
    router.include_router(v1_api, "/v1")

    # WS APIRouter: prefix 同样作用于 WS 端点 (-> /api/ws/echo).
    var ws_api = Router()
    ws_api.set_prefix("/api/ws")
    ws_api.add_ws_route("/echo", Handler(KIND_WS_ECHO(), "ws_api_echo"))
    router.include_router(ws_api)

    # 决策-38/57/58/61: declarative body schema routes live in
    # body_schema_routes.mojo (including nested object arrays).
    register_body_schema_routes(router)

    # Enum 参数 (T-P1e): query 参数声明 T[values] (+ 可选 =default).
    var enum_h = Handler(KIND_ECHO(), "enum_demo")
    enum_h.set_data("message", "enum demo")
    enum_h.set_data("_param_types", "level:str[low,medium,high]=high")
    router.add_route("/enum", "GET", enum_h)

    # 决策-43 (Goal-0003 P2 #3): query 精化 — List 多值 / alias / description.
    #   tag:str[]= (可选空 list) / nums:int[]= (可选 list) /
    #   level alias=lvl / limit alias=lmt (alias: 原始 name 无绑定效力,
    #   只按 alias key 取值; OpenAPI parameter.name = alias).
    var qe_h = Handler(KIND_ECHO(), "query_extra")
    qe_h.set_data("message", "query extras demo")
    qe_h.set_data("_param_types",
                  "tag:str[]=;nums:int[]=;level:str[low,medium,high]=high;limit:int=10")
    qe_h.set_data("_param_aliases", "level=lvl;limit=lmt")
    qe_h.set_data("_param_descs", "tag=Comma separated tags;nums=Numeric list;level=Log level;limit=Page size")
    router.add_route("/query-extra", "GET", qe_h)

    # 必填 list (无 '=' 默认) -> 缺失 422 (loc ["query","n"]).
    var qr_h = Handler(KIND_ECHO(), "query_req_list")
    qr_h.set_data("message", "required list demo")
    qr_h.set_data("_param_types", "n:int[]")
    router.add_route("/query-req", "GET", qr_h)
    # 决策-45 (ADR-0020): Form 多值/alias/desc demo. _form_types 声明
    # 类型 (list 多值 / 标量默认 / float / bool); _param_descs ->
    # OpenAPI description. 必填 list 缺失 -> 422; count=0 标量默认.
    var fmt_h = Handler(KIND_ECHO(), "form_multi")
    fmt_h.set_data("message", "form multi demo")
    fmt_h.set_data("_form_fields", "items,tags,count,fx,fb")
    fmt_h.set_data("_form_types", "items:int[];tags:str[];count:int=0;fx:float[]=;fb:bool[]=")
    fmt_h.set_data("_param_descs", "items=Numeric items (multi-occurrence)")
    router.add_route("/form-multi", "POST", fmt_h)

    # Form alias demo: wire key = alias (tags); 原始名 (labels) 无
    # 绑定效力 (缺失 -> 默认); size 标量默认 2.
    var fali_h = Handler(KIND_ECHO(), "form_alias")
    fali_h.set_data("message", "form alias demo")
    fali_h.set_data("_form_types", "labels:str[]=;size:int=2")
    fali_h.set_data("_form_aliases", "labels=tags")
    router.add_route("/form-alias", "POST", fali_h)

    # F5 SSE 一次性推送 demo (Goal-0002 §1.1). 事件用 | 分隔 (避免与 data 内 , 冲突).
    var sse_h = Handler(KIND_SSE(), "sse_demo")
    sse_h.set_data("_stream_events", "hello\nworld|second event|multi\nline\nevent")
    sse_h.set_data("_response_headers", "Cache-Control: no-cache")
    router.add_route("/sse", "GET", sse_h)

    # F9 SSE 自定义 status_code demo (对齐上游 FastAPI 0.140.13 PR #15937).
    # 声明 _stream_status = "201 Created"; dispatch 走 send_sse_response_extra.
    var sse_created_h = Handler(KIND_SSE(), "sse_created")
    sse_created_h.set_data("_stream_events", "created")
    sse_created_h.set_data("_stream_status", "201 Created")
    sse_created_h.set_data("_response_headers", "Cache-Control: no-cache;X-Accel-Buffering: no")
    router.add_route("/sse/created", "POST", sse_created_h)

    # 决策-72 (ADR-0047): SSE ServerSentEvent 字段 demo (event/id/retry/comment).
    # wire: ": ping\nevent: msg\ndata: alpha\nid: 42\nretry: 3000\n\n" x2.
    var ssef_h = Handler(KIND_SSE(), "sse_fields_demo")
    ssef_h.set_data("_stream_events", "alpha|beta")
    ssef_h.set_data("_sse_event", "msg")
    ssef_h.set_data("_sse_id", "42")
    ssef_h.set_data("_sse_retry", "3000")
    ssef_h.set_data("_sse_comment", "ping")
    router.add_route("/sse/fields", "GET", ssef_h)

    # 决策-72: 尾空行保留 demo (上游 _split_sse_lines 保留尾空 -> "data: t\ndata: \n\n").
    var ssetail_h = Handler(KIND_SSE(), "sse_tail_demo")
    ssetail_h.set_data("_stream_events", "t\n")
    router.add_route("/sse/tail", "GET", ssetail_h)

    # 决策-48: FileResponse / StreamingResponse demo (Rust bridge file_serve/file_protocol).
    var file_h = Handler(KIND_FILE(), "file_demo")
    file_h.set_data("_file_path", "filedemo.bin")
    router.add_route("/file", "GET", file_h)

    var filename_h = Handler(KIND_FILE(), "file_name_demo")
    filename_h.set_data("_file_path", "filedemo.bin")
    filename_h.set_data("_file_name", "report.txt")
    router.add_route("/file-name", "GET", filename_h)

    var fileinline_h = Handler(KIND_FILE(), "file_inline_demo")
    fileinline_h.set_data("_file_path", "filedemo.bin")
    fileinline_h.set_data("_file_name", "a b.txt")
    fileinline_h.set_data("_file_cdt", "inline")
    router.add_route("/file-inline", "GET", fileinline_h)

    var filemissing_h = Handler(KIND_FILE(), "file_missing_demo")
    filemissing_h.set_data("_file_path", "nope.txt")
    router.add_route("/file-missing", "GET", filemissing_h)

    var file201_h = Handler(KIND_FILE(), "file_201_demo")
    file201_h.set_data("_file_path", "filedemo.bin")
    file201_h.set_data("_file_status", "201 Created")
    router.add_route("/file-201", "GET", file201_h)

    # StreamingResponse: media 未声明 → 无 Content-Type (上游 quirk); body 按 | 分块.
    var stream_h = Handler(KIND_SSE(), "stream_demo")
    stream_h.set_data("_stream_body", "hello |world|中")
    router.add_route("/stream", "GET", stream_h)

    var streamjson_h = Handler(KIND_SSE(), "stream_json_demo")
    streamjson_h.set_data("_stream_body", "{\"a\":0}|{\"a\":1}|{\"a\":2}")
    streamjson_h.set_data("_stream_media", "application/json")
    streamjson_h.set_data("_stream_status", "202 Accepted")
    streamjson_h.set_data("_response_headers", "X-Custom: cv")
    router.add_route("/stream-json", "GET", streamjson_h)

    var streamempty_h = Handler(KIND_SSE(), "stream_empty_demo")
    streamempty_h.set_data("_stream_body", "")
    router.add_route("/stream-empty", "GET", streamempty_h)

    # 决策-68 (ADR-0043): RedirectResponse demo (KIND_REDIRECT).
    # 307 默认 (上游 RedirectResponse(url=...) 默认)；URL 按上游 safe set 编码。
    var redir_h = Handler(KIND_REDIRECT(), "redirect_demo")
    redir_h.set_data("_redirect_url", "/target")
    router.add_route("/redirect", "GET", redir_h)

    var redir303_h = Handler(KIND_REDIRECT(), "redirect_303_demo")
    redir303_h.set_data("_redirect_url", "https://ex.com/x")
    redir303_h.set_data("_redirect_status", "303 See Other")
    router.add_route("/redirect/303", "GET", redir303_h)

    var redir301_h = Handler(KIND_REDIRECT(), "redirect_301_demo")
    redir301_h.set_data("_redirect_url", "/t2")
    redir301_h.set_data("_redirect_status", "301 Moved Permanently")
    router.add_route("/redirect/301", "GET", redir301_h)

    var redir308_h = Handler(KIND_REDIRECT(), "redirect_308_demo")
    redir308_h.set_data("_redirect_url", "/t3")
    redir308_h.set_data("_redirect_status", "308 Permanent Redirect")
    router.add_route("/redirect/308", "GET", redir308_h)

    # URL quoting: 空格 -> %20 (safe 集保留 :/%#?=@[]!$&'()*+,;)。
    var redirq_h = Handler(KIND_REDIRECT(), "redirect_quote_demo")
    redirq_h.set_data("_redirect_url", "/p a th?x=1&y=2#frag")
    router.add_route("/redirect/quote", "GET", redirq_h)

    # follow 语义 demo: 307 -> /health (fmtool testclient follow 得 200)。
    var redirf_h = Handler(KIND_REDIRECT(), "redirect_follow_demo")
    redirf_h.set_data("_redirect_url", "/health")
    router.add_route("/redirect/health", "GET", redirf_h)

    # 决策-71 (ADR-0046): Starlette redirect_slashes 等价 demo.
    # /slash/ (带尾斜杠) <- GET /slash 会 307 -> /slash/; /slashpost (无尾斜杠)
    # <- POST/GET /slashpost/ 会 307 -> /slashpost (method 无关, 上游 PARTIAL 同型).
    var slash_h = Handler(KIND_ECHO(), "slash_demo")
    slash_h.set_data("message", "slash demo")
    router.add_route("/slash/", "GET", slash_h)
    var slashpost_h = Handler(KIND_ECHO(), "slashpost_demo")
    slashpost_h.set_data("message", "slashpost demo")
    router.add_route("/slashpost", "POST", slashpost_h)

    # F10 (v0.5.1): Cookie 参数注入 demo. _reads_cookies = 声明读取的 cookie 名;
    # dispatch 从 Cookie 头解析 (RFC 6265: ';' 分隔 '=' 切) 注入 params["cookie_<name>"].
    var cookie_h = Handler(KIND_ECHO(), "cookies")
    cookie_h.set_data("_reads_cookies", "session_id,user_id")
    cookie_h.set_data("message", "cookie demo")
    router.add_route("/cookies", "GET", cookie_h)

    # 决策-56 (ADR-0031): TestClient cookie-jar 捕获+回放 demo 路由.
    # _response_headers "Set-Cookie: tc=jar1" -> jar 存储; 二次调用回显 jar1.
    var tc_jar_h = Handler(KIND_ECHO(), "tc_jar")
    tc_jar_h.set_data("_reads_cookies", "tc")
    tc_jar_h.set_data("message", "tc jar demo")
    tc_jar_h.set_data("_response_headers", "Set-Cookie: tc=jar1")
    router.add_route("/tc/jar", "GET", tc_jar_h)

    # F10b (v0.5.1): Form 参数 demo. _form_fields = 声明读取的字段名;
    # dispatch 检测 Content-Type=application/x-www-form-urlencoded 时
    # 解析 body 并注入 params["form_<name>"]. 注意: 必须 GET 回显才能看见 form_*.
    var form_h = Handler(KIND_ECHO(), "form_demo")
    form_h.set_data("_form_fields", "username,password,remember")
    form_h.set_data("message", "form demo")
    router.add_route("/login", "POST", form_h)

    # G3-v0.7 (2026-09-04): multipart/UploadFile demo (Goal-0002 P5.2 推迟项).
    # _multipart = "true" 声明接收 multipart/form-data; dispatch 自动解析:
    #   文本字段 -> form_<name>; 文件字段 -> file_<name>_filename/_size/_content_type/_body_b64.
    var up_h = Handler(KIND_ECHO(), "upload")
    up_h.set_data("_multipart", "true")
    up_h.set_data("message", "multipart upload demo")
    router.add_route("/upload", "POST", up_h)

    # 决策-46 (ADR-0021): UploadFile 对象 API demo — _file_types 声明文件
    # 字段 (file/bytes, = 可选, [] list) + 422 校验 (U2/U3/U4/U5);
    # _file_aliases (wire key = alias); 文本 part 供给 _form_types (U8);
    # _file_ops 对象操作; size = 实际 raw 字节 (U1).
    var uf_h = Handler(KIND_ECHO(), "upload_file")
    uf_h.set_data("_multipart", "true")
    uf_h.set_data("_file_types", "doc:file;opt:file=;docs:file[]")
    uf_h.set_data("_file_aliases", "doc=docfile")
    uf_h.set_data("_form_types", "note:str")
    uf_h.set_data("_file_ops", "doc:sha256")
    uf_h.set_data("_param_descs", "doc=The document to upload;note=A note;opt=Optional attachment")
    uf_h.set_data("message", "uploadfile demo")
    router.add_route("/upload-file", "POST", uf_h)

    # 决策-46: bytes 字段 demo (文本/文件均接受, U9) + ops
    # head:4 / range:1:3 / save -> /tmp/fm_upload/raw.bin.
    # All-optional fields (OpenAPI: no required key; U5: non-multipart CT -> 200).
    var ub_h = Handler(KIND_ECHO(), "upload_bytes")
    ub_h.set_data("_multipart", "true")
    ub_h.set_data("_file_types", "raw:bytes=;small:bytes=")
    ub_h.set_data("_file_ops", "raw:head:4;raw:range:1:3;raw:save:/tmp/fm_upload/raw.bin")
    ub_h.set_data("message", "uploadbytes demo")
    router.add_route("/upload-bytes", "POST", ub_h)


    # F11 (v0.5.1): BackgroundTasks demo. _background = 响应后同步执行的命令列表 (\n 分隔).
    # demo: GET /bg-write -> 响应后把 req_id 写到 /tmp/bg_<req_id>.txt (shell date 同步)
    var bg_h = Handler(KIND_ECHO(), "bg_write")
    bg_h.set_data("_background", "date -u +%Y-%m-%dT%H:%M:%SZ >> /tmp/bg_test.log")
    bg_h.set_data("message", "bg demo")
    router.add_route("/bg-write", "GET", bg_h)

    # 决策-34 (Goal-0003 P0): Security 认证 demo (HTTPBasic / HTTPBearer / APIKey).
    # 声明式 _auth 是请求级 gate; 失败 -> 401 + WWW-Authenticate, 成功 -> 注入 auth_* 参数.
    # /basic: HTTPBasic. 正确凭据 (admin:secret) -> 200 + auth_user; 错/缺 -> 401 + WWW-Authenticate: Basic.
    var basic_h = Handler(KIND_ECHO(), "secure_basic")
    basic_h.set_data("_auth", "basic")
    basic_h.set_data("_auth_users", "admin:secret;user:pass123")
    basic_h.set_data("_auth_realm", "MyApp")
    basic_h.set_data("message", "basic auth demo")
    router.add_route("/basic", "GET", basic_h)

    # 决策-69 (ADR-0044): _auth_scheme_name 覆盖默认 securityScheme 名 (上游 scheme_name=).
    var basic_alt_h = Handler(KIND_ECHO(), "secure_basic_alt")
    basic_alt_h.set_data("_auth", "basic")
    basic_alt_h.set_data("_auth_users", "admin:secret")
    basic_alt_h.set_data("_auth_scheme_name", "MyBasicAuth")
    basic_alt_h.set_data("message", "basic alt demo")
    router.add_route("/basic-alt", "GET", basic_alt_h)

    # /secure: HTTPBearer. 正确 token (tok123) -> 200 + auth_token; 错/缺 -> 401 + WWW-Authenticate: Bearer.
    var bearer_h = Handler(KIND_ECHO(), "secure_bearer")
    bearer_h.set_data("_auth", "bearer")
    bearer_h.set_data("_auth_tokens", "tok123;abcd456")
    bearer_h.set_data("_auth_realm", "MyApp")
    bearer_h.set_data("message", "bearer auth demo")
    router.add_route("/secure", "GET", bearer_h)

    # /api: APIKey (header). 正确 key (key_abc) -> 200 + auth_apikey; 错/缺 -> 401.
    var api_h = Handler(KIND_ECHO(), "secure_apikey")
    api_h.set_data("_auth", "apikey:header:X-Api-Key")
    api_h.set_data("_auth_tokens", "key_abc;key_def")
    api_h.set_data("message", "apikey header demo")
    router.add_route("/api", "GET", api_h)

    # /api-q: APIKey (query). ?key=key_abc -> 200 + auth_apikey.
    var apiq_h = Handler(KIND_ECHO(), "secure_apikey_query")
    apiq_h.set_data("_auth", "apikey:query:key")
    apiq_h.set_data("_auth_tokens", "key_abc")
    apiq_h.set_data("message", "apikey query demo")
    router.add_route("/api-q", "GET", apiq_h)

    # 决策-69 (ADR-0044): HTTPDigest stub parity demo.
    # /digest: Authorization scheme=digest (大小写不敏感) + 非空 credentials -> 200,
    # 注入 auth_scheme/auth_credentials (原样大小写); 缺/非 digest -> 401 + WWW-Authenticate: Digest.
    var digest_h = Handler(KIND_ECHO(), "secure_digest")
    digest_h.set_data("_auth", "digest")
    digest_h.set_data("message", "digest auth demo")
    router.add_route("/digest", "GET", digest_h)

    # 决策-70 (ADR-0045): OpenIdConnect stub parity demo.
    # /openid: Authorization 头存在 (任意 scheme) -> 200 + auth_credentials=原始头;
    #   缺失/空头 -> 401 + WWW-Authenticate: Bearer. OpenAPI: type=openIdConnect.
    var openid_h = Handler(KIND_ECHO(), "openid_demo")
    openid_h.set_data("_auth", "openid")
    openid_h.set_data("_openid_url", "/.well-known/openid-configuration")
    openid_h.set_data("message", "openid demo")
    router.add_route("/openid", "GET", openid_h)

    # 决策-70 (ADR-0045): OAuth2AuthorizationCodeBearer parity demo.
    # /authcode: Bearer token (scheme 大小写不敏感) -> 200 + auth_token;
    #   缺失/非 bearer -> 401 + WWW-Authenticate: Bearer.
    # OpenAPI: type=oauth2 + flows.authorizationCode {authorizationUrl, tokenUrl, scopes}.
    var ac_h = Handler(KIND_ECHO(), "authcode_demo")
    ac_h.set_data("_auth", "authcode")
    ac_h.set_data("_authcode_authorization_url", "/authorize")
    ac_h.set_data("_authcode_token_url", "/token")
    ac_h.set_data("_authcode_scopes", "items:read=Read items")
    ac_h.set_data("message", "authcode demo")
    router.add_route("/authcode", "GET", ac_h)

    # 决策-44 (Goal-0003 P2 #17): OAuth2 password flow + JWT (HS256) — 对标矩阵最后一项.
    # /token (POST form): OAuth2PasswordRequestForm 等价 (grant_type 可选/username/password
    #   必填); 凭据 admin:s3cret; 成功 -> 200 {access_token: HS256 JWT, token_type: bearer}.
    var tok_h = Handler(KIND_OAUTH2_TOKEN(), "oauth2_token")
    tok_h.set_data("_auth_users", "admin:s3cret;user:pass123")
    tok_h.set_data("_jwt_secret", "probe-secret-key-42")
    tok_h.set_data("_jwt_ttl_sec", "3600")
    # 决策-67: 签发 token 的 scope claim (RFC 6749 空格分隔; 声明用 ';')
    tok_h.set_data("_jwt_scopes", "items:read;items:write")
    # 决策-67: OAuth2PasswordBearer securityScheme 元数据 (scopes 描述 + tokenUrl)
    tok_h.set_data("_oauth2_scopes", "items:read=Read items;items:write=Write items;admin=Admin only")
    tok_h.set_data("_oauth2_token_url", "token")
    router.add_route("/token", "POST", tok_h)

    # /token-exp: 同 /token 但 ttl=-1 -> 签发即过期 (e2e: 过期 token 被 /secure-jwt 拒).
    var tokexp_h = Handler(KIND_OAUTH2_TOKEN(), "oauth2_token_exp")
    tokexp_h.set_data("_auth_users", "admin:s3cret;user:pass123")
    tokexp_h.set_data("_jwt_secret", "probe-secret-key-42")
    tokexp_h.set_data("_jwt_ttl_sec", "-1")
    router.add_route("/token-exp", "POST", tokexp_h)

    # /secure-jwt: _auth=oauth2 gate (get_current_user 等价): Bearer <JWT> 校验
    #   (alg/exp/nbf/sub/签名) -> auth_user=sub, auth_token=token; 失败 401 + www=Bearer.
    var sjwt_h = Handler(KIND_ECHO(), "secure_jwt")
    sjwt_h.set_data("_auth", "oauth2")
    sjwt_h.set_data("_jwt_secret", "probe-secret-key-42")
    sjwt_h.set_data("message", "oauth2 jwt demo")
    router.add_route("/secure-jwt", "GET", sjwt_h)

    # 决策-67: scope 保护路由 (Security(get_current_user, scopes=[...]) 等价).
    # token (来自 /token) 含 items:read;items:write -> /secure-jwt/items 200;
    # /secure-jwt/admin 需 admin -> 403 "Not enough permissions".
    var sjwt_items_h = Handler(KIND_ECHO(), "secure_jwt_items")
    sjwt_items_h.set_data("_auth", "oauth2")
    sjwt_items_h.set_data("_jwt_secret", "probe-secret-key-42")
    sjwt_items_h.set_data("_auth_scopes", "items:read")
    router.add_route("/secure-jwt/items", "GET", sjwt_items_h)

    var sjwt_admin_h = Handler(KIND_ECHO(), "secure_jwt_admin")
    sjwt_admin_h.set_data("_auth", "oauth2")
    sjwt_admin_h.set_data("_jwt_secret", "probe-secret-key-42")
    sjwt_admin_h.set_data("_auth_scopes", "admin")
    router.add_route("/secure-jwt/admin", "GET", sjwt_admin_h)

    # 决策-35/41 (Goal-0003): response_model 家族 demo (FastAPI 语义).
    # /profile: 模型 name/age/email/secret + exclude secret → 返回 name/age/email
    #   (决策-35 include + 决策-41 exclude: 从模型字段中剔除).
    var profile_h = Handler(KIND_STATIC(), "profile")
    profile_h.set_data("name", "Alice")
    profile_h.set_data("age", "30")
    profile_h.set_data("email", "alice@example.com")
    profile_h.set_data("secret", "do_not_expose")
    profile_h.set_data("_response_model", "name,age,email,secret")
    profile_h.set_data("_response_exclude", "secret")
    router.add_route("/profile", "GET", profile_h)

    # /profile-none: 模型 name/note + exclude_none=true → note(空串=null 等价)剔除
    var pnone_h = Handler(KIND_STATIC(), "profile_none")
    pnone_h.set_data("name", "Bob")
    pnone_h.set_data("note", "")
    pnone_h.set_data("_response_model", "name,note")
    pnone_h.set_data("_response_exclude_none", "true")
    router.add_route("/profile-none", "GET", pnone_h)

    # /profile-keep: 同数据但 exclude_none 缺省 → note:"" 保留 (回归对照)
    var pkeep_h = Handler(KIND_STATIC(), "profile_keep")
    pkeep_h.set_data("name", "Bob")
    pkeep_h.set_data("note", "")
    pkeep_h.set_data("_response_model", "name,note")
    router.add_route("/profile-keep", "GET", pkeep_h)

    # /rm-noop: 声明 _response_exclude 但**无** _response_model → no-op (FastAPI:
    # 无 response_model 时 include/exclude/exclude_none 不影响响应) — meta 字段全保留
    var rnoop_h = Handler(KIND_ECHO(), "rm_noop")
    rnoop_h.set_data("message", "noop")
    rnoop_h.set_data("_response_exclude", "message")
    rnoop_h.set_data("_response_exclude_none", "true")
    router.add_route("/rm-noop", "GET", rnoop_h)


    # WebSocket 端点 (ADR-0007): user code = data, 同 HTTP 路由注册模式。
    # 行为由 handler.kind 决定 (KIND_WS_*); "ws_sp" 数据项 = 必需子协议。
    router.add_ws_route("/ws", Handler(KIND_WS_ECHO(), "ws_echo"))

    var ws_counter_h = Handler(KIND_WS_COUNTER(), "ws_counter")
    router.add_ws_route("/ws/counter", ws_counter_h)

    var ws_chat_h = Handler(KIND_WS_ECHO(), "ws_chat")
    ws_chat_h.set_data("ws_sp", "chat")  # 客户端必须提供 Sec-WebSocket-Protocol: chat
    router.add_ws_route("/ws/chat", ws_chat_h)

    # Decision-60 (ADR-0035): application subprotocol matrix lives in
    # ws_protocol_routes.mojo (JSON-RPC / GraphQL WS / gRPC-Web binary bridge).
    register_ws_protocol_routes(router)

    # ADR-0009: {param} 路由 + 鉴权 (升级 query token)
    router.add_ws_route("/ws/greet/{name}", Handler(KIND_WS_GREET(), "ws_greet"))
    router.add_ws_route("/ws/room/{room}", Handler(KIND_WS_ECHO(), "ws_room"))

    var ws_private_h = Handler(KIND_WS_ECHO(), "ws_private")
    ws_private_h.set_data("ws_token", "secret")  # 升级 query 必须带 token=secret
    router.add_ws_route("/ws/private", ws_private_h)

    # 决策-51 (ADR-0026): WS 精化 demo (Goal-0003 矩阵 #23, P23 六场景) —
    # 声明式 _ws_* 指令 (解析/校验 = ws_directives, close-wait = bridge
    # phase 5, FASTAPI_MOJO_WS_CLOSE_WAIT env, 默认 10s).
    # P23-1: 回复后 close 1000 "bye" (+ close-wait)
    var wsc1_h = Handler(KIND_WS_ECHO(), "ws_close_1000")
    wsc1_h.set_data("_ws_close", "1000:bye")
    router.add_ws_route("/ws/close", wsc1_h)
    # P23-2: 无回复, close 4001 "custom reason" (+ close-wait)
    var wsc2_h = Handler(KIND_WS_ECHO(), "ws_close_4001")
    wsc2_h.set_data("_ws_no_reply", "1")
    wsc2_h.set_data("_ws_close", "4001:custom reason")
    router.add_ws_route("/ws/close/4001", wsc2_h)
    # P23-3: 未处理异常 — 无 close 帧, TCP close (客户端 1006); log [ws-exc]
    var wse1_h = Handler(KIND_WS_ECHO(), "ws_exc_boom")
    wse1_h.set_data("_ws_raise", "kaboom")
    router.add_ws_route("/ws-exc/boom", wse1_h)
    # P23-4: WebSocketException 等价 — 无回复, close 4002 "ws-exc"
    var wse2_h = Handler(KIND_WS_ECHO(), "ws_exc_close")
    wse2_h.set_data("_ws_exc_close", "4002:ws-exc")
    router.add_ws_route("/ws-exc/close", wse2_h)
    # P23-5: BINARY 回复 (零拷贝, NUL 安全)
    var wsb_h = Handler(KIND_WS_ECHO(), "ws_bin")
    wsb_h.set_data("_ws_binary", "1")
    router.add_ws_route("/ws/bin", wsb_h)
    # P23-6: compact JSON TEXT 回复 (原始 UTF-8, 模板原样发送)
    var wsj_h = Handler(KIND_WS_ECHO(), "ws_json")
    wsj_h.set_data("_ws_json", "{\"a\":1,\"b\":\"中文\",\"c\":[1,2]}")
    router.add_ws_route("/ws/json", wsj_h)

    # 决策-52 (ADR-0027): OpenAPI 精化 demo 路由
    # /meta/probe: 单路由覆盖全部 operation 级键 (tags 不在 root tags → 证明
    # 不并入; summary/description/response_description/operation_id 显式覆盖;
    # deprecated; _responses 额外 418)
    var mp_h = Handler(KIND_ECHO(), "meta_probe")
    mp_h.set_data("_tags", "probe,custom")
    mp_h.set_data("_summary", "Probe Sum")
    mp_h.set_data("_description", "Probe desc")
    mp_h.set_data("_response_description", "probe ok")
    mp_h.set_data("_operation_id", "probe_op")
    mp_h.set_data("_deprecated", "1")
    mp_h.set_data("_responses", "418:Teapot custom")
    router.add_route("/meta/probe", "GET", mp_h)
    # /meta/hidden: include_in_schema=False (200 可服务, spec 无此 path)
    var mh_h = Handler(KIND_ECHO(), "meta_hidden")
    mh_h.set_data("_include_in_schema", "0")
    router.add_route("/meta/hidden", "GET", mh_h)
    # /meta/made: status_code=201 (wire 201 + spec responses 主键 201)
    var mm_h = Handler(KIND_ECHO(), "meta_made")
    mm_h.set_data("_status_code", "201 Created")
    router.add_route("/meta/made", "GET", mm_h)
    # 决策-53 (ADR-0028): Header alias/转换 demo — x_token 读字面头
    # Token-Literal (alias 不转换, P25-3); client_id 读 client-id (默认 _→-)
    var hdr_h = Handler(KIND_ECHO(), "hdr_alias")
    hdr_h.set_data("_reads_headers", "x_token=Token-Literal,client_id")
    router.add_route("/hdr/alias", "GET", hdr_h)

    # 决策-54 (ADR-0029): 参数约束面 demo (矩阵 #2) — path/query/header 约束 + typed header
    # /con/path/{n}: 数值边界面 (n:int + gt=3,le=10)
    var con1 = Handler(KIND_ECHO(), "con_path_num")
    con1.set_data("_param_types", "n:int")
    con1.set_data("_param_constraints", "n=gt=3,le=10")
    router.add_route("/con/path/{n}", "GET", con1)

    # /con/str/{s}: 隐式 str 面 (len=2-4, pat=^[a-z]+$)
    var con2 = Handler(KIND_ECHO(), "con_path_str")
    con2.set_data("_param_constraints", "s=len=2-4,pat=^[a-z]+$")
    router.add_route("/con/str/{s}", "GET", con2)

    # /con/query: query 类型化 (q:int=5 + ge=0,lt=100) + 隐式 str (r=len=1-3) 混合
    var con3 = Handler(KIND_ECHO(), "con_query")
    con3.set_data("_param_types", "q:int=5")
    con3.set_data("_param_constraints", "q=ge=0,lt=100;r=len=1-3")
    router.add_route("/con/query", "GET", con3)

    # /con/hdr: typed header — x_token 转 wire x-token (required int: 缺失 422 /
    # "abc" int_parsing); x-app 无下划线 wire 原样 (bool 默认 true: 缺失 200 /
    # "xyz" bool_parsing 完整消息)
    var con4 = Handler(KIND_ECHO(), "con_hdr")
    con4.set_data("_reads_headers", "x_token,x-app")
    con4.set_data("_header_types", "x_token:int;x-app:bool=true")
    router.add_route("/con/hdr", "GET", con4)

    # /con/hdr2: alias wire (x-ver -> X-Ver) + 默认 + 数值 (ge/le/mo) / 字符串
    # (len/pat) 约束混合面
    var con5 = Handler(KIND_ECHO(), "con_hdr2")
    con5.set_data("_reads_headers", "x-ver=X-Ver,tag")
    con5.set_data("_header_types", "x-ver:int=1;tag:str=ab")
    con5.set_data("_param_constraints", "x-ver=ge=1,le=3,mo=1;tag=len=1-2,pat=^[0-9a-z]+$")
    router.add_route("/con/hdr2", "GET", con5)

    # /con/all/{n}: collect-all 群序断言路由 (ADR-0029 §7 增补, 超出 §3.7 五路由)
    # — 一个请求同时违 path (n=1<gt=3) + query (q=200>lt=100) + header (x-h
    # 缺失, 默认 2 违 ge=5, input=2 数字) -> detail 数组 path→query→header
    var con6 = Handler(KIND_ECHO(), "con_all")
    con6.set_data("_param_types", "n:int;q:int=1")
    con6.set_data("_reads_headers", "x-h")
    con6.set_data("_header_types", "x-h:int=2")
    con6.set_data("_param_constraints", "n=gt=3;q=lt=100;x-h=ge=5")
    router.add_route("/con/all/{n}", "GET", con6)

    # 决策-49 (ADR-0024): 任意异常类型 handler demo (Goal-0003 矩阵 #13).
    # _exception_raise = 声明式 raise 钩子 (endpoint body 抛异常的位置);
    # 无 env 表/路由表 -> 默认 500 "Internal Server Error" (P13-10);
    # FASTAPI_MOJO_EXCEPTION_HANDLERS / _exc_handlers 存在 -> 表驱动响应.
    var exc_ve_h = Handler(KIND_STATIC(), "exc_value_error")
    exc_ve_h.set_data("message", "ValueError demo")
    exc_ve_h.set_data("_exception_raise", "ValueError: bad value from handler")
    router.add_route("/exc/ve", "GET", exc_ve_h)

    var exc_unicorn_h = Handler(KIND_STATIC(), "exc_unicorn")
    exc_unicorn_h.set_data("message", "UnicornException demo")
    exc_unicorn_h.set_data("_exception_raise", "UnicornException: rainbow lost")
    router.add_route("/exc/unicorn", "GET", exc_unicorn_h)

    var exc_unhandled_h = Handler(KIND_STATIC(), "exc_unhandled")
    exc_unhandled_h.set_data("message", "unhandled exception demo")
    exc_unhandled_h.set_data("_exception_raise", "MysteryFailure: no entry for this")
    router.add_route("/exc/unhandled", "GET", exc_unhandled_h)

    var exc_plain_h = Handler(KIND_STATIC(), "exc_plain")
    exc_plain_h.set_data("message", "untagged raise demo")
    exc_plain_h.set_data("_exception_raise", "plain message no colon")
    router.add_route("/exc/raise-plain", "GET", exc_plain_h)

    var exc_ve2_h = Handler(KIND_STATIC(), "exc_json")
    exc_ve2_h.set_data("message", "json exception entry demo")
    exc_ve2_h.set_data("_exception_raise", "JsonExc: boom")
    router.add_route("/exc/ve2", "GET", exc_ve2_h)

    var exc_ovr_h = Handler(KIND_STATIC(), "exc_override")
    exc_ovr_h.set_data("message", "route-level table override demo")
    exc_ovr_h.set_data("_exception_raise", "ValueError: x")
    exc_ovr_h.set_data("_exc_handlers", "ValueError:429:overridden {exc}")
    router.add_route("/exc/override", "GET", exc_ovr_h)

    var exc_dup_h = Handler(KIND_STATIC(), "exc_dup")
    exc_dup_h.set_data("message", "last-wins per tag demo")
    exc_dup_h.set_data("_exception_raise", "Dup: d")
    router.add_route("/exc/dup", "GET", exc_dup_h)

    # 决策-74 (ADR-0049): HTTPException(status_code, detail, headers) parity —
    # 声明式自定义响应头 (_exc_headers = "TAG=Name: V|Name2: V2;..."; 精确 tag
    # 命中, 否则 Exception catch-all). 上游 probe: 418 + {"detail":"brewing"} +
    # X-Reason/WWW-Authenticate.
    var exc_hdr_h = Handler(KIND_STATIC(), "exc_headers")
    exc_hdr_h.set_data("message", "custom exception headers demo")
    exc_hdr_h.set_data("_exception_raise", "Teapot: brewing")
    exc_hdr_h.set_data("_exc_handlers", "Teapot:418:{\"detail\":\"brewing\"}:json")
    exc_hdr_h.set_data("_exc_headers",
        "Teapot=X-Reason: tea|WWW-Authenticate: Teapot")
    router.add_route("/exc/headers", "GET", exc_hdr_h)

    # 决策-50 (ADR-0025): Request.state demo (Goal-0003 矩阵 #22).
    # _state_set 声明写 (值 {param} 插值) -> _reads_state 声明读 -> state_<name>.
    # KIND_ECHO: run_handler 的 path_params 实参 = req_params, 故 state_<name>
    # 注入键会回显到 body (与 /ctx 的 header_ 同机制); "_" 前缀 data 键不回显.
    var st1 = Handler(KIND_ECHO(), "state_demo")
    st1.set_data("message", "request state demo")
    st1.set_data("_state_set", "user:alice;dept:eng")
    st1.set_data("_reads_state", "user,dept")
    router.add_route("/state", "GET", st1)

    var st2 = Handler(KIND_ECHO(), "state_dyn")
    st2.set_data("message", "state from params")
    st2.set_data("_state_set", "user:{who};greeting:hi {who}")
    st2.set_data("_reads_state", "user,greeting")
    router.add_route("/state-dyn/{who}", "GET", st2)

    var st3 = Handler(KIND_ECHO(), "state_missing")
    st3.set_data("message", "missing state read demo")
    # 无 _state_set: 本请求 state 必为空 -> user/ghost 双空 = 跨请求隔离证明
    # (即使前一请求 /state-dyn/bob 写过 user=bob, 本请求也读不到, P22-6).
    st3.set_data("_reads_state", "user,ghost")
    router.add_route("/state-missing", "GET", st3)

    # 决策-38: _body_schema 注册期语法检查 (畸形 spec 启动即 fail, 不带入请求路径)
    check_body_schemas(router)
    # 决策-50: _state_set 注册期语法检查 (同策略)
    check_state_specs(router)
    # 决策-51: _ws_* 指令注册期语法检查 (同策略)
    check_ws_specs(router)
    # 决策-52: OpenAPI 声明注册期语法检查 (_status_code/_responses/_deprecated/
    # _include_in_schema 畸形 → 启动即 fail, 同策略)
    check_openapi_specs(router)
    # 决策-53: _reads_headers 条目 (name / name=alias) 注册期校验 (同策略)
    check_header_specs(router)
    # 决策-54 (ADR-0029): _param_constraints/_header_types 注册期校验 (同策略)
    check_param_constraints(router)


def serve_forever(router: Router, mw_chain: MiddlewareChain, mw_spec: MWSpec) raises:
    """HTTP event loop (poll + dispatch + WS), reusable across applications.
    Routes come from the caller-supplied router (cp_app.mojo plugs in app routes).
    Returns when a shutdown signal is received.
    """
    var start_time = external_call["gettimeofday_ms", Int]()
    var req_num = 0

    # 连接级 WS 状态 (ADR-0008): fd -> 状态值 (如计数器累计); 会话结束事件清理
    var ws_state = Dict[Int, Int]()

    for _ in range(2000000000):
        if not external_call["is_running", Int]():
            print("\nShutdown signal received...")
            break

        # v11: the C bridge owns the socket I/O — a poll() event loop over
        # the listen socket plus every active connection. It blocks until
        # one request is fully parsed, then returns its fd (the fields are
        # in the bridge globals, exposed by get_*_len/read_*_byte). Keep-
        # alive works because idle connections no longer block the loop.
        # 0 = nothing to do right now: a connection was closed (client EOF,
        # idle timeout, Slowloris 408, or an error response) — loop again.
        var cfd = external_call["recv_and_parse", Int]()
        if cfd <= 0:
            continue

        # --- WS 事件 (ADR-0008): bridge poll 循环驱动会话, Mojo 逐条处理 ---
        var ws_ev = external_call["ws_event_type", Int]()
        if ws_ev == 1:
            # 数据帧就绪 (text/binary): 按连接 path 查 WS 路由并分派
            var ws_path = span_to_str(
                external_call["get_ws_path_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
            var ws_match = router.match_ws_route(ws_path)
            if ws_match.matched:
                var ws_op = external_call["ws_last_opcode", Int]()
                var ws_st = 0
                if cfd in ws_state:
                    ws_st = ws_state[cfd]
                ws_st = handle_ws_data(cfd, ws_match.handler, ws_match.params, ws_op, ws_st)
                ws_state[cfd] = ws_st
            external_call["ws_message_done", NoneType](cfd)
            external_call["ws_pump_now", NoneType](cfd)  # 尾块/新帧立即处理 (不等 poll)
            continue
        if ws_ev == 2:
            # WS 会话结束 (close/EOF/保活耗尽): 清理连接级状态
            if cfd in ws_state:
                _ = ws_state.pop(cfd)
            continue

        req_num += 1
        var req_id = mw_request_id(mw_chain, req_num)
        var start_ms = now_ms()

        # Request fields are transferred from the C bridge in bulk as
        # CStringSlice (pointer + length) and UTF-8 decoded here in
        # amortized O(n) (the C side already validated the UTF-8).
        var method = span_to_str(external_call["get_method_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
        var path = span_to_str(external_call["get_path_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
        var query = span_to_str(external_call["get_query_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
        var body_str = span_to_str(external_call["get_body_slice", CStringSlice[origin_of(String(""))]]().as_bytes())

        # 决策-55 (ADR-0030): 用户中间件请求面 (outermost→innermost, env 逆序).
        # set_req_id 在任何响应前 (bridge BODY {req_id} / LOG 行用);
        # REQHDR 注入合成头 (CI 先注入先胜); MAP 重写 path; BLOCK 短路早响应.
        _ = external_call["set_req_id", Int](req_id.as_c_string_slice())
        var mw_r = mw_plan_request(mw_spec, method, path, query, req_id)
        var hdr_n = len(mw_r.req_hdr_names)
        var hk = 0
        while hk < hdr_n:
            var hn = mw_r.req_hdr_names[hk]
            var hv = mw_r.req_hdr_vals[hk]
            _ = external_call["inject_request_header", Int](hn.as_c_string_slice(), hv.as_c_string_slice())
            hk += 1
        path = mw_r.path
        if mw_r.block_status.byte_length() > 0:
            var mw_sl = standard_status_line(Int(mw_r.block_status))
            var mw_body = mw_r.block_body
            var mw_dur = mw_timing(mw_chain, start_ms)
            _ = external_call["send_text_response_status", Int](cfd, mw_sl.as_c_string_slice(), mw_body.as_c_string_slice())
            _finish_request(mw_chain, req_id, method, mw_r.path, query, mw_sl, mw_dur)
            external_call["conn_done", NoneType](cfd, False)
            continue

        # Handle OPTIONS preflight (CORS)
        if method == "OPTIONS":
            var duration_ms = mw_timing(mw_chain, start_ms)
            # 决策-73 (ADR-0048): FFI 返回值 = HTTP 状态码 (200 真预检 / 204 通配
            # 超集 / 400 Disallowed CORS), 供 access log 记录真实状态.
            var pf_code = external_call["send_preflight_response", Int](cfd)
            _finish_request(mw_chain, req_id, method, path, query, standard_status_line(pf_code), duration_ms)
            external_call["conn_done", NoneType](cfd, False)  # preflight response announces Connection: close
        elif external_call["is_ws_upgrade", Int]() == 1:
            # WebSocket upgrade (RFC 6455, ADR-0006/0007/0008): WS route lookup +
            # 101 handshake + hand the connection to the bridge poll loop
            # (control frames / keepalive / UTF-8 handled in C; data frames are
            # dispatched one at a time via the ws_event_type branch above —
            # sessions no longer block dispatch, ADR-0008).
            var ws_match = router.match_ws_route(path)
            if ws_match.matched:
                var ws_status = run_ws_upgrade(cfd, ws_match.handler)
                var duration_ms = mw_timing(mw_chain, start_ms)
                if ws_status == 101:
                    ws_state[cfd] = 0  # 移交成功: 连接现为 WS 会话 (不 conn_done)
                    _finish_request(mw_chain, req_id, method, path, query, "101 Switching Protocols", duration_ms)
                    continue
                var ws_sl = "400 Bad Request"
                if ws_status == 403:
                    ws_sl = "403 Forbidden"
                elif ws_status == 500:
                    ws_sl = "500 Internal Server Error"
                _finish_request(mw_chain, req_id, method, path, query, ws_sl, duration_ms)
                external_call["conn_done", NoneType](cfd, False)
            else:
                var ws_resp = build_error_response("404", "Route not found")
                var ws_body = json_serialize_dict(ws_resp)
                _ = external_call["send_simple_response", Int](
                    cfd, "404 Not Found".as_c_string_slice(), ws_body.as_c_string_slice())
                var duration_ms = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, "404 Not Found", duration_ms)
                external_call["conn_done", NoneType](cfd, False)
        else:
            # Handle HEAD method (same as GET but no body)
            var is_head = method == "HEAD"
            var effective_method = method
            if is_head:
                effective_method = "GET"


            # F4: OpenAPI/Swagger UI (Goal-0002). 动态生成 spec + 内嵌 UI 引导页.
            # 这两个路径不进 route table, 在 dispatch 入口特判 (避免污染路由计数).
            if effective_method == "GET" and path == "/openapi.json":
                # 决策-52 (ADR-0027): app 级 9 env 请求期读 (空 = 默认/省略;
                # 畸形 → openapi_custom 内省略字段, 不 500)
                var oa_title = "fastapi_mojo API"
                var oa_version = "1.8.0"
                var oa_t = getenv("FASTAPI_MOJO_OPENAPI_TITLE")
                if oa_t != "":
                    oa_title = oa_t
                var oa_v = getenv("FASTAPI_MOJO_OPENAPI_VERSION")
                if oa_v != "":
                    oa_version = oa_v
                var oa_desc = getenv("FASTAPI_MOJO_OPENAPI_DESCRIPTION")
                var oa_terms = getenv("FASTAPI_MOJO_OPENAPI_TERMS")
                var oa_contact = getenv("FASTAPI_MOJO_OPENAPI_CONTACT")
                var oa_license = getenv("FASTAPI_MOJO_OPENAPI_LICENSE")
                var oa_servers = getenv("FASTAPI_MOJO_OPENAPI_SERVERS")
                var oa_tags = getenv("FASTAPI_MOJO_OPENAPI_TAGS")
                var oa_extdocs = getenv("FASTAPI_MOJO_OPENAPI_EXTERNAL_DOCS")
                var spec = generate_openapi(router, oa_title, oa_version, oa_desc,
                                            oa_terms, oa_contact, oa_license,
                                            oa_servers, oa_tags, oa_extdocs)
                var extra_empty = String("")
                _ = external_call["send_simple_response_extra", Int](
                    cfd,
                    "200 OK".as_c_string_slice(),
                    spec.as_c_string_slice(),
                    extra_empty.as_c_string_slice(),  # empty extra (F4 openapi 无自定义头)
                )
                var duration_ms = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, "200 OK (openapi)", duration_ms)
                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
                continue
            elif effective_method == "GET" and path == "/docs":
                # 决策-52: /docs 标题与 /openapi.json 同源 (env 或默认)
                var d_title = "fastapi_mojo API"
                var d_t = getenv("FASTAPI_MOJO_OPENAPI_TITLE")
                if d_t != "":
                    d_title = d_t
                var html = swagger_ui_html(d_title, "/openapi.json")
                _ = external_call["send_html_response", Int](
                    cfd,
                    "200 OK".as_c_string_slice(),
                    html.as_c_string_slice(),
                )
                var duration_ms_d = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, "200 OK (docs)", duration_ms_d)
                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
                continue

            elif effective_method == "GET" and path == "/redoc":
                # 决策-76 (ADR-0051): ReDoc 内置页 (上游 FastAPI 默认路由 /redoc).
                # 标题与 /openapi.json//docs 同源 (env FASTAPI_MOJO_OPENAPI_TITLE).
                var r_title = "fastapi_mojo API"
                var r_t = getenv("FASTAPI_MOJO_OPENAPI_TITLE")
                if r_t != "":
                    r_title = r_t
                var r_html = redoc_html(r_title, "/openapi.json")
                _ = external_call["send_html_response", Int](
                    cfd,
                    "200 OK".as_c_string_slice(),
                    r_html.as_c_string_slice(),
                )
                var duration_ms_rd = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, "200 OK (redoc)", duration_ms_rd)
                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
                continue

            elif effective_method == "GET" and path == "/docs/oauth2-redirect":
                # 决策-76 (ADR-0051): Swagger UI OAuth2 redirect (上游默认路由;
                # /docs 的 oauth2RedirectUrl 指向此路径).
                var o2_html = swagger_ui_oauth2_redirect_html()
                _ = external_call["send_html_response", Int](
                    cfd,
                    "200 OK".as_c_string_slice(),
                    o2_html.as_c_string_slice(),
                )
                var duration_ms_o2 = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, "200 OK (oauth2-redirect)", duration_ms_o2)
                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
                continue

            elif effective_method == "GET" and path == "/metrics":
                # F6: Prometheus 文本 (F6, Goal-0002). 专用 text/plain content-type.
                var m_slice = external_call["get_metrics_block", CStringSlice[origin_of(String(""))]]()
                var m_body = span_to_str(m_slice.as_bytes())
                _ = external_call["send_text_response", Int](
                    cfd, m_body.as_c_string_slice())
                var duration_ms_m = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, "200 OK (metrics)", duration_ms_m)
                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
                continue

            elif effective_method == "GET" and path == "/traces":
                # Decision-62: bounded in-process OTLP JSON trace export. This
                # response snapshots prior spans; the /traces request itself is
                # recorded by the shared _finish_request hook after rendering.
                var t_slice = external_call["get_traces_block", CStringSlice[origin_of(String(""))]]()
                var t_body = span_to_str(t_slice.as_bytes())
                _ = external_call["send_simple_response", Int](
                    cfd, "200 OK".as_c_string_slice(), t_body.as_c_string_slice())
                var duration_ms_t = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, "200 OK (traces)", duration_ms_t)
                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
                continue

            # Try static file serving for GET/HEAD requests
            if (effective_method == "GET") and is_static_path(path):
                if is_head:
                    # HEAD: headers only, no body (a body would violate HTTP)
                    _ = external_call["send_static_file_head", Int](
                        cfd,
                        path.as_c_string_slice(),
                    )
                else:
                    _ = external_call["send_static_file", Int](
                        cfd,
                        path.as_c_string_slice(),
                    )
                # Log the REAL status (the C side may have answered 403/404/413
                # for the static request).
                var sl_len = external_call["get_last_status_len", Int]()
                var sl = String("")
                for i in range(sl_len):
                    var sb = external_call["read_last_status_byte", Int](i)
                    if sb >= 0:
                        sl += chr(sb)

                var duration_ms = mw_timing(mw_chain, start_ms)
                _finish_request(mw_chain, req_id, method, path, query, sl + " (static)", duration_ms)

                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)
            else:
                # --- Route matching ---
                var route_result = router.match_route_with_params(path, effective_method)

                var query_params = parse_query_params(query)
                var body_params = ParsedParams()
                if (effective_method == "POST" or effective_method == "PUT" or effective_method == "PATCH") and body_str.byte_length() > 0:
                    body_params = parse_body_json(body_str)

                # --- Handler dispatch ---
                # (both branches below assign resp_data/status_line before use)
                var resp_data: Dict[String, String] = Dict[String, String]()
                var status_line: String = ""
                var is_405 = False
                var allow_methods = List[String]()
                var auth_www = ""  # 决策-34: 401 响应的 WWW-Authenticate 头 (auth 失败时非空)
                # 决策-75 (ADR-0050): 本请求依赖 teardown 收集器 (Depends(yield) 等价).
                # 每连接迭代重置; resolve_depends 实际派发的依赖按解析完成序追加;
                # 响应 flush 后 _run_dep_teardowns 逆序执行 (上游 ExitStack LIFO).
                var dep_teardowns = List[String]()

                if not route_result.matched:
                    # Path exists but method not registered -> 405 + Allow (RFC 7231).
                    # Path does not exist at all -> 404.
                    allow_methods = router.methods_for_path(path)
                    if len(allow_methods) > 0:
                        is_405 = True
                        status_line = "405 Method Not Allowed"
                        resp_data = build_error_response("405", "Method not allowed")
                    else:
                        # 决策-71 (ADR-0046): Starlette `redirect_slashes` 等价 ——
                        # 无路由匹配时, 若尾部斜杠取反后的路径存在 (method 无关) -> 307
                        # 重定向到绝对 URL (scheme://host<alt>?<query>); 否则 404.
                        var alt = alt_slash_path(path)
                        var alt_ok = False
                        if alt != "":
                            alt_ok = len(router.methods_for_path(alt)) > 0
                        if alt_ok:
                            var rscheme = "http"
                            if (getenv("FASTAPI_MOJO_TLS_CERT").byte_length() > 0
                                    and getenv("FASTAPI_MOJO_TLS_KEY").byte_length() > 0):
                                rscheme = "https"
                            var rhost = _get_header("Host")
                            if rhost == "":
                                rhost = "127.0.0.1:" + String(external_call["get_configured_port", Int]())
                            var rloc = build_redirect_location(rscheme, rhost, alt, query)
                            _ = external_call["send_redirect_response", Int](
                                cfd, "307 Temporary Redirect".as_c_string_slice(),
                                rloc.as_c_string_slice())
                            var sdur = mw_timing(mw_chain, start_ms)
                            _finish_request(mw_chain, req_id, method, path, query,
                                            "307 Temporary Redirect (slash-redirect)", sdur)
                            if external_call["get_close_after_response", Int]() != 0:
                                external_call["conn_done", NoneType](cfd, False)
                            else:
                                external_call["conn_done", NoneType](cfd, True)
                            continue
                        status_line = "404 Not Found"
                        resp_data = build_error_response("404", "Route not found")
                else:
                    # ADR-0004: 核心只调用 run_handler (单一 dispatch 扩展点).
                    # 新增路由 = register_routes 里加数据; 新增行为 = handler.mojo
                    # 加一个 KIND_x + run_handler 一个 elif.
                    var uptime_ms = external_call["gettimeofday_ms", Int]() - start_time
                    var uptime_s = uptime_ms // 1000
                    var route_keys = List[String]()
                    var route_names = List[String]()
                    for i in range(router.route_count()):
                        route_keys.append(router.routes[i].method + " " + router.routes[i].path)
                        route_names.append(router.routes[i].handler.name)
                    for i in range(router.ws_route_count()):
                        route_keys.append("WS " + router.ws_routes[i].path)
                        route_names.append(router.ws_routes[i].handler.name)
                    var info = ServerInfo("1.8.0", "request_id, logging, timing", uptime_s,
                                          req_num, route_keys, route_names)

                    # 决策-34 (Goal-0003 P0): Security / 认证 (HTTPBasic/HTTPBearer/APIKey).
                    # 声明式 _auth 是请求级 gate: 失败 -> 401 + WWW-Authenticate, 跳过 param 校验 + handler.
                    var do_handler = True
                    var auth_user_in = ""
                    var auth_token_in = ""
                    var auth_apikey_in = ""
                    var auth_scheme_in = ""
                    var auth_credentials_in = ""
                    if "_auth" in route_result.handler.data:
                        # 决策-44: oauth2 分支走 security_jwt (JWT 校验); 其余走 check_auth.
                        # 不并入 check_auth 的原因: 其 import 会拖入 FFI 闭包, 破坏
                        # security.mojo 的 JIT 自检 (JIT 只链 main 可达符号); dispatch
                        # 本身已属 JIT 不可链类别 (需完整 bridge), 无回归.
                        var auth: AuthResult
                        if route_result.handler.data["_auth"] == "oauth2":
                            auth = check_oauth2(route_result.handler)
                        else:
                            auth = check_auth(route_result.handler, query_params.values)
                        if not auth.ok:
                            do_handler = False
                            status_line = auth.status_line
                            auth_www = auth.www_authenticate
                            resp_data = Dict[String, String]()
                            resp_data["detail"] = auth.detail
                            # 决策-44: status 从 status_line 前 3 字节推导 (不再硬编码
                            # "401" — oauth2 空 token 等场景可产生 403 等其它码).
                            resp_data["status"] = String(auth.status_line[byte=0:3])
                        else:
                            auth_user_in = auth.auth_user
                            auth_token_in = auth.auth_token
                            auth_apikey_in = auth.auth_apikey
                            auth_scheme_in = auth.auth_scheme
                            auth_credentials_in = auth.auth_credentials

                    if do_handler:
                        # F1: 类型化参数校验 (Goal-0002 §1.1). 校验失败 -> 422 + detail.
                        # 校验通过 -> 继续 run_handler (handler 无感, ParamDict 仍是 String).
                        # 这是 dispatch 唯一一处"认识类型化"的代码; 新增类型化路由 = 仅在
                        # register_routes 用 set_data("_param_types", "name:type;name:type").
                        var type_spec = get_param_types(route_result.handler)
                        # 决策-54 (ADR-0029): 约束面 — 类型化参数约束 + 隐式 str (len/pat) + typed header
                        var constraints = get_param_constraints(route_result.handler)
                        var htypes = get_header_types(route_result.handler)
                        var aliases = get_param_aliases(route_result.handler)
                        # 决策-38 (Goal-0003 P1): 参数校验 + body 校验统一为 FastAPI 422 detail
                        # 数组 (loc/msg/type, 收集全部错误: 参数 -> ["path"/"query",x] (+
                        # 决策-43 list 元素下标 i; alias 按 alias key 取值);
                        # body -> ["body",x] + 嵌套/数组下标; Pydantic v2 风格).
                        var perr = validate_params_collect(type_spec, route_result.params,
                                                           query_params.values, query_params.multi_values, aliases, constraints)
                        # 隐式 str (未类型化 path/query) 约束 — dispatch 独立 pass (ADR-0029 §3.3)
                        var imp_errs = validate_implicit_constraints(constraints, type_spec, htypes,
                                                                       route_result.params, query_params.values)
                        # typed header: FFI 读值 (present = name->raw, 含空值) -> 纯校验 (param_constraints_run)
                        var herr_ok = True
                        var herr_list = List[String]()
                        var hvals = Dict[String, String]()
                        if len(htypes) > 0:
                            var present = read_headers_present(route_result.handler.data["_reads_headers"])
                            var reads = parse_reads_headers(route_result.handler.data["_reads_headers"])
                            var hres = validate_headers_collect(htypes, reads, present, constraints)
                            herr_ok = hres[0]
                            for he in hres[1]:
                                herr_list.append(he)
                            for hv in hres[2]:
                                hvals[hv] = hres[2][hv]
                        var sres = validate_body_schema(route_result.handler, effective_method, body_params, body_str)
                        # 决策-45 (ADR-0020): Form 多值/422 parity —
                        # CT 为 form 时 parse_form_multi 收全部 occurrence;
                        # 非 form CT 传空 multi (上游同款: 缺失->默认/422).
                        # 决策-46 (ADR-0021): CT 为 multipart -> Rust bridge 解析 parts
                        # (单一快照点); 文本 part 供给 form 字段 (U8,
                        # 已声明 file 名不进 map) + file 校验 (U2/U4/U5)
                        # + file->form 422 (U3 string_type).
                        var ct_hdr = _get_header("Content-Type")
                        var is_mp_ct = _ct_is_multipart(ct_hdr)
                        var mp_parts = MpParts()
                        var fmulti = Dict[String, List[String]]()
                        if is_mp_ct:
                            mp_parts = snapshot_mp_parts()
                            fmulti = text_multi_map_filtered(mp_parts,
                                                             file_declared_names(route_result.handler))
                        elif _ct_is_form(ct_hdr):
                            fmulti = parse_form_multi(body_str)
                        var ftypes = get_form_types(route_result.handler)
                        var fal = get_form_aliases(route_result.handler)
                        var ferr = validate_form_collect(ftypes, fal, fmulti)
                        var ft_file = get_file_types(route_result.handler)
                        var fal_file = get_file_aliases(route_result.handler)
                        var ffe = validate_file_collect(ft_file, fal_file, mp_parts)
                        var ffve: List[String]
                        var flagged: List[String]
                        if is_mp_ct:
                            flagged = file_part_fields(mp_parts, ftypes, fal,
                                                       ft_file, fal_file)
                            ffve = validate_file_vs_form(mp_parts, ftypes, fal,
                                                         ft_file, fal_file)
                        else:
                            flagged = List[String]()
                            ffve = List[String]()
                        var all_errs = List[String]()
                        if not perr[0]:
                            for pe in perr[1]:
                                all_errs.append(pe)
                        for ie in imp_errs:
                            all_errs.append(ie)
                        if not herr_ok:
                            for he in herr_list:
                                all_errs.append(he)
                        if not sres[0]:
                            for se in sres[1]:
                                all_errs.append(se)
                        if not ferr[0]:
                            # U3: a file part makes a form field PRESENT - drop
                            # its duplicate missing error (upstream: presence wins).
                            for fe in ferr[1]:
                                var drop = False
                                for fk in flagged:
                                    if fe == missing_err_json(fk):
                                        drop = True
                                        break
                                if not drop:
                                    all_errs.append(fe)
                        if not ffe[0]:
                            for fe2 in ffe[1]:
                                all_errs.append(fe2)
                        for fv in ffve:
                            all_errs.append(fv)
                        if len(all_errs) > 0:
                            status_line = "422 Unprocessable Entity"
                            resp_data = Dict[String, String]()
                            resp_data["detail"] = "__nested__:" + "[" + ",".join(all_errs) + "]"
                            resp_data["status"] = "422"
                        else:
                            # 决策-43 (Goal-0003 P2 #3): 成功路径 list 多值/alias 归一化 —
                            # values[key] = list CSV / alias 绑定值 (原始 name 覆写: 无绑定效力).
                            apply_query_extras(query_params, type_spec, aliases, route_result.params)
                            # F2: 声明式异常映射 (Goal-0002). 命中 -> 直接返回错误响应,
                            # 不进 run_handler. 这是 dispatch 唯一一处"认识 _error_map"的代码.
                            var exc = match_error_map(route_result.handler,
                                                      route_result.params, query_params.values)
                            if exc.status_code > 0:
                                status_line = exc.status_line
                                resp_data = build_exception_body(exc.detail, exc.status_code)
                            else:
                                # F3a: Request 读 headers (Goal-0002). 声明式 _reads_headers CSV.
                                # 注入 route_result.params 前缀 header_<name>; handler 直读.
                                var req_params = route_result.params.copy()
                                # 决策-38: 注入 body 校验值 (含默认值) body_<name> / <父>_<子>
                                for bk in sres[2]:
                                    req_params["body_" + bk] = sres[2][bk]
                                # 决策-34: 注入认证身份 (basic->auth_user / bearer->auth_token / apikey->auth_apikey)
                                if auth_user_in != "":
                                    req_params["auth_user"] = auth_user_in
                                if auth_token_in != "":
                                    req_params["auth_token"] = auth_token_in
                                if auth_apikey_in != "":
                                    req_params["auth_apikey"] = auth_apikey_in
                                if auth_scheme_in != "":
                                    req_params["auth_scheme"] = auth_scheme_in
                                if auth_credentials_in != "":
                                    req_params["auth_credentials"] = auth_credentials_in
                                if "_reads_headers" in route_result.handler.data:
                                    inject_request_headers(req_params, route_result.handler.data["_reads_headers"])
                                    # 决策-54: typed header 覆盖字符串注入 (在场 = raw 串; 缺失+默认 = 类型化字面量)
                                    for hn in hvals:
                                        req_params["header_" + hn] = hvals[hn]
                                if "_reads_cookies" in route_result.handler.data:
                                    inject_request_cookies(req_params, route_result.handler.data["_reads_cookies"])
                                # 决策-45: form 归一化单点注入 — typed
                                # list 全 occurrence CSV / 标量 last-wins /
                                # alias 绑定 / legacy 未标注字段 (缺失 -> "").
                                var ff_csv = ""
                                if "_form_fields" in route_result.handler.data:
                                    ff_csv = route_result.handler.data["_form_fields"]
                                apply_form_extras(req_params, ftypes, fal, fmulti, ff_csv)
                                # 决策-46: multipart 成功路径注入 —
                                # file part -> file_ key (size = 实际字节 U1;
                                # alias 字段按声明名 key); text part -> form_
                                # (与 apply_form_extras 一致); _file_ops (head/range/sha256/save)
                                # 走 FFI 快照重读 (conn 仍活跃).
                                if is_mp_ct:
                                    apply_file_extras(req_params, route_result.handler, mp_parts.copy())
                                    if "_file_ops" in route_result.handler.data and route_result.handler.data["_file_ops"] != "":
                                        apply_file_ops(req_params, mp_parts,
                                                       route_result.handler.data["_file_ops"],
                                                       fal_file)
                                # F-DI (Depends, 决策-33) + 决策-47 (use_cache):
                                # 解析 _depends (默认 cached) / _depends_nocache (upstream
                                # use_cache=False), 递归派发后注入 req_params (前缀
                                # depname_outputkey); 每请求 memo 表 = 上游 Depends
                                # use_cache 语义 (ADR-0022; P9-1 菱形 1 次 / P9-2 直
                                # 接 nocache 2 次 / P9-3 cached 复用 nocache 入库结果).
                                if "_depends" in route_result.handler.data or \
                                        "_depends_nocache" in route_result.handler.data:
                                    var dcache = DepCache()
                                    var _ = resolve_depends(router, route_result.handler, req_params,
                                                    info, query_params, body_params,
                                                    List[String](), dcache, dep_teardowns)
                                    # _dep_calls=true -> 注入各 dep 每请求实际派发次数
                                    # (observability 超集, 上游无此面; ADR-0022 §3.5-2).
                                    inject_dep_calls(route_result.handler.data, req_params, dcache)
                                # 决策-50 (ADR-0025): Request.state — 每请求 scope 存储
                                # (P22-2/6: 前置阶段写 -> handler 读, 每请求隔离).
                                # 写面 _state_set (值 {param} 插值, ctx = 全部已注入
                                # 参数 = 「middleware 先写」声明式等价); 读面
                                # _reads_state (CSV -> state_<name>, F10 同范式,
                                # 缺失 -> "" — 上游 500 偏差, ADR-0025 §3.5-1).
                                var state = Dict[String, String]()
                                if "_state_set" in route_result.handler.data and \
                                        route_result.handler.data["_state_set"] != "":
                                    apply_state_set(state,
                                                    route_result.handler.data["_state_set"],
                                                    req_params)
                                if "_reads_state" in route_result.handler.data and \
                                        route_result.handler.data["_reads_state"] != "":
                                    inject_request_state(req_params, state,
                                                         route_result.handler.data["_reads_state"])
                                # 决策-49 (ADR-0024): 路由级 try/except guard —
                                # _exception_raise 钩子 + run_handler; 捕获 Error ->
                                # 异常类型 handler 表 (env / _exc_handlers;
                                # 精确 tag -> Exception catch-all -> 默认 500).
                                var gres = guarded_run_handler(route_result.handler,
                                                               req_params,
                                                               query_params,
                                                               body_params, info)
                                if gres.is_exc:
                                    # 异常 handler 响应 (绕过 response_model, 原样发送)
                                    # 决策-74 (ADR-0049): 声明式自定义头 (_exc_headers /
                                    # FASTAPI_MOJO_EXCEPTION_HEADERS) → *_extra 入口.
                                    if gres.extra.byte_length() > 0:
                                        if gres.is_json:
                                            _ = external_call["send_simple_response_extra", Int](
                                                cfd, gres.status_line.as_c_string_slice(),
                                                gres.body.as_c_string_slice(),
                                                gres.extra.as_c_string_slice())
                                        else:
                                            _ = external_call["send_text_response_status_extra", Int](
                                                cfd, gres.status_line.as_c_string_slice(),
                                                gres.body.as_c_string_slice(),
                                                gres.extra.as_c_string_slice())
                                    elif gres.is_json:
                                        _ = external_call["send_simple_response", Int](
                                            cfd, gres.status_line.as_c_string_slice(),
                                            gres.body.as_c_string_slice())
                                    else:
                                        _ = external_call["send_text_response_status", Int](
                                            cfd, gres.status_line.as_c_string_slice(),
                                            gres.body.as_c_string_slice())
                                    var exc_dur = mw_timing(mw_chain, start_ms)
                                    _finish_request(mw_chain, req_id, method, path, query,
                                               gres.status_line + " (exc)", exc_dur)
                                    _run_dep_teardowns(dep_teardowns, req_id, method, path)
                                    if external_call["get_close_after_response", Int]() != 0:
                                        external_call["conn_done", NoneType](cfd, False)
                                    else:
                                        external_call["conn_done", NoneType](cfd, True)
                                    continue
                                status_line = gres.status_line
                                resp_data = gres.resp_data.copy()
                                # 决策-52: _status_code 声明 ("NNN Reason" 全 status
                                # line, 与 _stream_status/_file_status 同型) — 仅当
                                # handler 默认成功态 "200 OK" 时覆写 (异常/401/405
                                # 结果不覆写; spec responses 主键取前 3 位, 同源)
                                if "_status_code" in route_result.handler.data and route_result.handler.data["_status_code"] != "":
                                    if status_line == "200 OK":
                                        status_line = route_result.handler.data["_status_code"]

                                # F5: SSE 一次性推送 (跳过 run_handler, 直接构造 SSE body).
                                # F9 (v0.5.1): 支持自定义 status_code (对齐上游 FastAPI
                                # 0.140.13 PR #15937) + 修复 `_response_headers` 被解析
                                # 但从未发送的静默丢弃缺陷.
                                # 决策-48: 声明 `_stream_body` → StreamingResponse 分支
                                # (chunked; media_type 空 = 无 Content-Type, 上游 quirk).
                                # 键存在语义: 空串也必须走 streaming 路径 (S3 parity).
                                if route_result.handler.kind == KIND_SSE():
                                    if "_stream_body" in route_result.handler.data:
                                        var st_status = "200 OK"
                                        if "_stream_status" in route_result.handler.data:
                                            st_status = route_result.handler.data["_stream_status"]
                                        var st_media = ""
                                        if "_stream_media" in route_result.handler.data:
                                            st_media = route_result.handler.data["_stream_media"]
                                        var st_extra = ""
                                        if "_response_headers" in route_result.handler.data:
                                            var st_hdrs = parse_response_headers(route_result.handler)
                                            if len(st_hdrs) > 0:
                                                st_extra = "\r\n".join(st_hdrs)
                                        # Rust bridge send_streaming_response: TE: chunked,
                                        # 无 CT quirk, charset 规则, extra 头透传.
                                        _ = external_call["send_streaming_response", Int](
                                            cfd, st_status.as_c_string_slice(),
                                            route_result.handler.data["_stream_body"].as_c_string_slice(),
                                            st_media.as_c_string_slice(),
                                            st_extra.as_c_string_slice())
                                        var st_dur = mw_timing(mw_chain, start_ms)
                                        _finish_request(mw_chain, req_id, method, path, query,
                                                   st_status + " (stream)", st_dur)
                                        _run_dep_teardowns(dep_teardowns, req_id, method, path)
                                        if external_call["get_close_after_response", Int]() != 0:
                                            external_call["conn_done", NoneType](cfd, False)
                                        else:
                                            external_call["conn_done", NoneType](cfd, True)
                                        continue
                                    var events_csv = ""
                                    if "_stream_events" in route_result.handler.data:
                                        events_csv = route_result.handler.data["_stream_events"]
                                    # 决策-72 (ADR-0047): 路由级 SSE 字段 (上游 ServerSentEvent).
                                    var sse_ev = ""
                                    if "_sse_event" in route_result.handler.data:
                                        sse_ev = route_result.handler.data["_sse_event"]
                                    var sse_idv = ""
                                    if "_sse_id" in route_result.handler.data:
                                        sse_idv = route_result.handler.data["_sse_id"]
                                    var sse_retry = ""
                                    if "_sse_retry" in route_result.handler.data:
                                        sse_retry = route_result.handler.data["_sse_retry"]
                                    var sse_comment = ""
                                    if "_sse_comment" in route_result.handler.data:
                                        sse_comment = route_result.handler.data["_sse_comment"]
                                    var sse_body = build_sse_body_fields(events_csv, sse_ev,
                                                                        sse_idv, sse_retry, sse_comment)
                                    # 默认 200 OK; handler 可声明 _stream_status = "201 Created".
                                    var sse_status = "200 OK"
                                    if "_stream_status" in route_result.handler.data:
                                        sse_status = route_result.handler.data["_stream_status"]
                                    var sse_extra = ""
                                    if "_response_headers" in route_result.handler.data:
                                        var sse_hdrs = parse_response_headers(route_result.handler)
                                        if len(sse_hdrs) > 0:
                                            sse_extra = "\r\n".join(sse_hdrs)
                                    # send_sse_response_extra: status + extra 头统一透传
                                    # (不再硬编码 200, 不再丢弃声明的响应头).
                                    _ = external_call["send_sse_response_extra", Int](
                                        cfd, sse_status.as_c_string_slice(),
                                        sse_body.as_c_string_slice(), sse_extra.as_c_string_slice())
                                    var sse_dur = mw_timing(mw_chain, start_ms)
                                    _finish_request(mw_chain, req_id, method, path, query, sse_status + " (sse)", sse_dur)
                                    _run_dep_teardowns(dep_teardowns, req_id, method, path)
                                    if external_call["get_close_after_response", Int]() != 0:
                                        external_call["conn_done", NoneType](cfd, False)
                                    else:
                                        external_call["conn_done", NoneType](cfd, True)
                                    continue

                                # 决策-48: FileResponse — 完整协议在 Rust bridge file_serve
                                # (stat/Range/206 单段与 multipart/etag/CD/charset/If-Range/
                                # HEAD/400/416/500); 此处声明式透传 (SSE 同型特例: 需
                                # cfd + 静态目录, 跳过 run_handler 的 JSON 路径).
                                if route_result.handler.kind == KIND_FILE():
                                    var fpath = ""
                                    if "_file_path" in route_result.handler.data:
                                        fpath = route_result.handler.data["_file_path"]
                                    var fmedia = ""
                                    if "_file_media" in route_result.handler.data:
                                        fmedia = route_result.handler.data["_file_media"]
                                    var fname = ""
                                    if "_file_name" in route_result.handler.data:
                                        fname = route_result.handler.data["_file_name"]
                                    var fcdt = "attachment"
                                    if "_file_cdt" in route_result.handler.data:
                                        fcdt = route_result.handler.data["_file_cdt"]
                                    var fstatus = "200 OK"
                                    if "_file_status" in route_result.handler.data:
                                        fstatus = route_result.handler.data["_file_status"]
                                    var fextra = ""
                                    if "_response_headers" in route_result.handler.data:
                                        var fhdrs = parse_response_headers(route_result.handler)
                                        if len(fhdrs) > 0:
                                            fextra = "\r\n".join(fhdrs)
                                    _ = external_call["send_file_response", Int](
                                        cfd, fpath.as_c_string_slice(),
                                        fmedia.as_c_string_slice(),
                                        fname.as_c_string_slice(),
                                        fcdt.as_c_string_slice(),
                                        fstatus.as_c_string_slice(),
                                        fextra.as_c_string_slice())
                                    var fdur = mw_timing(mw_chain, start_ms)
                                    _finish_request(mw_chain, req_id, method, path, query,
                                               fstatus + " (file)", fdur)
                                    _run_dep_teardowns(dep_teardowns, req_id, method, path)
                                    if external_call["get_close_after_response", Int]() != 0:
                                        external_call["conn_done", NoneType](cfd, False)
                                    else:
                                        external_call["conn_done", NoneType](cfd, True)
                                    continue

                                # 决策-68 (ADR-0043): RedirectResponse 等价
                                # (上游 Starlette: 无 Content-Type + Content-Length: 0 +
                                # Location 头; URL 按上游 safe set 百分号编码).
                                # 声明 _redirect_url + 可选 _redirect_status
                                # (默认 "307 Temporary Redirect"; 303/301/308 同型).
                                if route_result.handler.kind == KIND_REDIRECT():
                                    var rurl = ""
                                    if "_redirect_url" in route_result.handler.data:
                                        rurl = route_result.handler.data["_redirect_url"]
                                    var rstatus = "307 Temporary Redirect"
                                    if "_redirect_status" in route_result.handler.data:
                                        rstatus = route_result.handler.data["_redirect_status"]
                                    _ = external_call["send_redirect_response", Int](
                                        cfd, rstatus.as_c_string_slice(),
                                        rurl.as_c_string_slice())
                                    var rdur = mw_timing(mw_chain, start_ms)
                                    _finish_request(mw_chain, req_id, method, path, query,
                                               rstatus + " (redirect)", rdur)
                                    _run_dep_teardowns(dep_teardowns, req_id, method, path)
                                    if external_call["get_close_after_response", Int]() != 0:
                                        external_call["conn_done", NoneType](cfd, False)
                                    else:
                                        external_call["conn_done", NoneType](cfd, True)
                                    continue

                                # 决策-44: OAuth2 token endpoint (POST form -> JWT 签发).
                                # 需要 body_str (run_handler 签名不带) -> 此特例覆写
                                # status_line/resp_data/www (SSE 同型先例). 不 continue:
                                # 落到公共 send 块 (带 WWW-Authenticate 头 + 公共 meta 字段).
                                if route_result.handler.kind == KIND_OAUTH2_TOKEN():
                                    var tok3 = handle_oauth2_token(route_result.handler, body_str)
                                    status_line = tok3[0]
                                    resp_data = tok3[1].copy()
                                    if tok3[2] != "":
                                        auth_www = tok3[2]

                # KIND_HTML: 直接以 text/html 发送 (动态前端页 / 运营面板).
                # 走 send_html_response (Content-Type: text/html), 不再包 JSON.
                if route_result.handler.kind == KIND_HTML():
                    var html_body = ""
                    if "html" in resp_data:
                        html_body = resp_data["html"]
                    var duration_ms = mw_timing(mw_chain, start_ms)
                    if is_head:
                        _ = external_call["send_html_response", Int](
                            cfd, status_line.as_c_string_slice(), html_body.as_c_string_slice())
                    else:
                        _ = external_call["send_html_response", Int](
                            cfd, status_line.as_c_string_slice(), html_body.as_c_string_slice())
                    _finish_request(mw_chain, req_id, method, path, query, status_line, duration_ms)
                    if external_call["get_close_after_response", Int]() != 0:
                        external_call["conn_done", NoneType](cfd, False)
                    else:
                        external_call["conn_done", NoneType](cfd, True)
                    continue

                resp_data["method"] = method
                resp_data["path"] = path
                resp_data["handler"] = route_result.handler.name
                resp_data["request_id"] = req_id

                for key in query_params.values:
                    resp_data["query_" + key] = query_params.values[key]

                var duration_ms = mw_timing(mw_chain, start_ms)
                if duration_ms >= 0:
                    resp_data["duration_ms"] = String(duration_ms)

                # 决策-35/41 (Goal-0003): response_model (include) + exclude + exclude_none
                # (FastAPI/Pydantic 语义, 单一调用点 response_model_body; ADR-0016).
                var body = response_model_body(route_result.handler, resp_data)

                # Use HEAD response for HEAD requests (headers only, no body);
                # 405 carries the Allow header.
                if is_head:
                    _ = external_call["send_head_response", Int](
                        cfd,
                        status_line.as_c_string_slice(),
                        body.as_c_string_slice(),
                    )
                elif is_405:
                    var allow_str = ", ".join(allow_methods)
                    _ = external_call["send_simple_response_allow", Int](
                        cfd,
                        status_line.as_c_string_slice(),
                        body.as_c_string_slice(),
                        allow_str.as_c_string_slice(),
                    )
                else:
                    # F3b: 自定义响应头 (Goal-0002). 声明式 _response_headers = "Name:value;Name:value".
                    # 命中 -> 用 send_simple_response_extra, 多行头用 \r\n 分隔 (build_response_headers
                    # 内部追加末尾 CRLF).
                    var extra = ""
                    if "_response_headers" in route_result.handler.data:
                        var hdrs = parse_response_headers(route_result.handler)
                        if len(hdrs) > 0:
                            extra = "\r\n".join(hdrs)
                    # 决策-34: 401 响应的 WWW-Authenticate 头 (auth 失败时)
                    if auth_www != "":
                        if extra != "":
                            extra = extra + "\r\nWWW-Authenticate: " + auth_www
                        else:
                            extra = "WWW-Authenticate: " + auth_www
                    if extra != "":
                        _ = external_call["send_simple_response_extra", Int](
                            cfd,
                            status_line.as_c_string_slice(),
                            body.as_c_string_slice(),
                            extra.as_c_string_slice(),
                        )
                    else:
                        _ = external_call["send_simple_response", Int](
                            cfd,
                            status_line.as_c_string_slice(),
                            body.as_c_string_slice(),
                        )


                _finish_request(mw_chain, req_id, method, path, query, status_line, duration_ms)

                # F11: BackgroundTasks 在响应已 flush 后同步执行声明的命令
                # (对齐 Starlette BackgroundTask 语义, 客户端已收到响应).
                _run_background(route_result.handler, req_id, method, path, query)

                # 决策-75 (ADR-0050): Depends(yield) teardown — 上游在
                # background tasks 之后关闭 request AsyncExitStack, 故此处逆序执行.
                _run_dep_teardowns(dep_teardowns, req_id, method, path)

                if external_call["get_close_after_response", Int]() != 0:
                    external_call["conn_done", NoneType](cfd, False)
                else:
                    external_call["conn_done", NoneType](cfd, True)

    external_call["server_shutdown", NoneType]()
    print("Server stopped gracefully.")

def main() raises:
    print("=== Mojo HTTP Server v1.8 ===")

    external_call["set_static_dir", NoneType]("./static".as_c_string_slice())
    external_call["set_max_body_size", NoneType](1048576)

    var router = Router()
    register_routes(router)   # 用户代码 = 数据 (ADR-0004)
    print("Routes: " + String(router.route_count()))

    var mw_chain = MiddlewareChain()
    mw_chain.add(Middleware("request_id"))
    mw_chain.add(Middleware("logging"))
    mw_chain.add(Middleware("timing"))
    print("Middleware: request_id, logging, timing")

    # 决策-55 (ADR-0030): 用户自定义中间件 env (声明式; 畸形 fail-fast, 服务不启动).
    var mw_env = getenv("FASTAPI_MOJO_MIDDLEWARE")
    var mw_spec = MWSpec()
    if mw_env != "":
        if not check_mw_spec(mw_env):
            external_call["bridge_fail", NoneType]()
            return
        mw_spec = parse_mw_spec(mw_env)
        print("User middleware: " + String(len(mw_spec.mws)) + " (FASTAPI_MOJO_MIDDLEWARE)")
    else:
        print("User middleware: (none)")

    # F6: metrics 初始化 (记录进程启动时间, 供 uptime gauge 派生).
    external_call["metrics_init", NoneType]()

    # Worker processes (ADR-0005): FASTAPI_MOJO_WORKERS=N (default 1 = single
    # process). Must run before create_bound_socket (SO_REUSEPORT binding).
    external_call["init_workers", NoneType]()

    # Listen port: CLI --port N > FASTAPI_MOJO_PORT env > 8000 (C side).
    var port = external_call["get_configured_port", Int]()
    var sfd = external_call["create_bound_socket", Int](port)
    # Mojo reads the C `int` return into a 64-bit Int: a -1 sentinel can arrive
    # as 0xffffffff. Valid listen fds are small non-negative C ints.
    if sfd < 0 or sfd > 2147483647:
        print("ERROR: bind failed on port " + String(port))
        external_call["bridge_fail", NoneType]()
        return
    var worker_id = external_call["get_worker_id", Int]()
    if worker_id > 0:
        print("Worker #" + String(worker_id) + " (multi-worker mode, ADR-0005)")
    var scheme = "http"
    if getenv("FASTAPI_MOJO_TLS_CERT").byte_length() > 0 and getenv("FASTAPI_MOJO_TLS_KEY").byte_length() > 0:
        scheme = "https"
    print("Listening on " + scheme + "://127.0.0.1:" + String(port))
    print("Press Ctrl+C to stop")

    # Lifespan (决策-36): startup 命令 — 仅主进程 (worker_id=0) 执行,
    # 在服务开始接请求之前; 任一命令失败 -> bridge_fail (服务不启动).
    run_lifespan_startup(worker_id)

    serve_forever(router, mw_chain, mw_spec)

    # Lifespan (决策-36): shutdown 命令 — serve_forever 返回 (收到停止信号) 后,
    # 仅主进程执行; 失败只记日志, 不阻塞进程退出.
    run_lifespan_shutdown(worker_id)
