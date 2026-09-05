# src/fastapi_mojo/router.mojo
#
# Mojo 原生路由表实现（支持 pattern matching）
# Route 携带 Handler (ADR-0004): 路由 = 数据, 行为由 handler.kind 决定.

from handler import Handler, KIND_ECHO, KIND_STATIC, KIND_TEMPLATE, KIND_WS_ECHO, KIND_WS_COUNTER


# ========== 决策-37 (APIRouter) 辅助函数 ==========

def _merge_csv(a: String, b: String, sep: Int) -> String:
    """合并两个 CSV (sep: 44=',' / 59=';'); 空值跳过."""
    if a == "":
        return b
    if b == "":
        return a
    return a + chr(sep) + b


def _join_path(prefix: String, sub_prefix: String, path: String) -> String:
    """决策-37: 路径拼接 prefix + sub_prefix + path.

    规范化: 前导 / 保证; 不产生 //; 尾部 / 去除 (根 / 除外).
    例: ("/v1", "/items", "/{id}") -> "/v1/items/{id}";
        ("/api/items", "", "/")   -> "/api/items" (路由 '/' 归一).
    """
    var full = ""
    if prefix != "":
        if ord(prefix[byte=0]) == 47:  # '/'
            full = prefix
        else:
            full = "/" + prefix
    if sub_prefix != "":
        var sp = sub_prefix
        if ord(sp[byte=0]) != 47:  # '/'
            sp = "/" + sp
        while sp.byte_length() > 1 and ord(sp[byte=sp.byte_length() - 1]) == 47:
            var sp_cut = String(sp[byte=0:sp.byte_length() - 1])
            sp = sp_cut
        full += sp
    if full == "" or full == "/":
        return path
    var result = full + path
    while result.byte_length() > 1 and ord(result[byte=result.byte_length() - 1]) == 47:
        var result_cut = String(result[byte=0:result.byte_length() - 1])
        result = result_cut
    return result


struct RouteMatch:
    """路由匹配结果."""
    var matched: Bool
    var params: Dict[String, String]
    var handler: Handler

    def __init__(out self, matched: Bool, params: Dict[String, String], handler: Handler):
        self.matched = matched
        self.params = params.copy()
        self.handler = handler.copy()

    def __init__(out self):
        self.matched = False
        self.params = Dict[String, String]()
        self.handler = Handler(KIND_ECHO(), "")


struct Route:
    """路由条目 (path + method + Handler)."""
    var path: String
    var method: String
    var handler: Handler

    def __init__(out self, path: String, method: String, handler: Handler):
        self.path = path
        self.method = method
        self.handler = handler.copy()

    def match(self, path: String, method: String) -> Bool:
        """检查路由是否匹配（精确 + pattern）."""
        if self.method != method:
            return False
        return self.match_path_only(path)

    def match_path_only(self, path: String) -> Bool:
        """仅按路径匹配（忽略 method）.
        用于 405 检测：路径存在但方法未注册时，应回 405 + Allow 而不是 404。"""
        return self._match_path(path)

    def match_with_params(self, path: String, method: String) -> RouteMatch:
        """匹配路由并返回提取的参数."""
        if self.method != method:
            return RouteMatch()
        return self._match_path_with_params(path)

    def _match_path(self, path: String) -> Bool:
        """路径匹配（支持 {param} segment）。"""
        var path_parts = path.split("/")
        var pattern_parts = self.path.split("/")

        if len(path_parts) != len(pattern_parts):
            return False

        for i in range(len(pattern_parts)):
            var pp = pattern_parts[i]
            var ap = path_parts[i]
            if pp.startswith("{") and pp.endswith("}"):
                continue
            if pp != ap:
                return False
        return True

    def _match_path_with_params(self, path: String) -> RouteMatch:
        """路径匹配并提取参数值。"""
        var path_parts = path.split("/")
        var pattern_parts = self.path.split("/")
        var params = Dict[String, String]()

        if len(path_parts) != len(pattern_parts):
            return RouteMatch()

        for i in range(len(pattern_parts)):
            var pp = pattern_parts[i]
            var ap = path_parts[i]
            if pp.startswith("{") and pp.endswith("}"):
                # 提取参数名：byte slice → String
                var param_name = String(pp[byte=1 : pp.byte_length() - 1])
                # ap 是 StringSpan，需要转为 String
                params[param_name] = String(ap)
            elif pp != ap:
                return RouteMatch()
        return RouteMatch(True, params, self.handler)


struct WsRouteMatch:
    """WS 路由匹配结果 (ADR-0007; {param} 参数 ADR-0009)."""
    var matched: Bool
    var params: Dict[String, String]
    var handler: Handler

    def __init__(out self, matched: Bool, params: Dict[String, String], handler: Handler):
        self.matched = matched
        self.params = params.copy()
        self.handler = handler.copy()

    def __init__(out self):
        self.matched = False
        self.params = Dict[String, String]()
        self.handler = Handler(KIND_ECHO(), "")


struct WsRoute:
    """WS 端点 (path + Handler, ADR-0007: user code = data, 同 HTTP 路由模式).
    ADR-0009: 支持 {param} segment pattern (与 HTTP Route 同语义)."""
    var path: String
    var handler: Handler

    def __init__(out self, path: String, handler: Handler):
        self.path = path
        self.handler = handler.copy()

    def match_with_params(self, path: String) -> WsRouteMatch:
        """segment pattern 匹配 + 参数提取 ({param} 段, 与 HTTP Route 同语义)."""
        var path_parts = path.split("/")
        var pattern_parts = self.path.split("/")
        if len(path_parts) != len(pattern_parts):
            return WsRouteMatch()
        var params = Dict[String, String]()
        for i in range(len(pattern_parts)):
            var pp = pattern_parts[i]
            var ap = String(path_parts[i])
            if pp.startswith("{") and pp.endswith("}"):
                params[String(pp[byte=1 : pp.byte_length() - 1])] = ap
            elif pp != ap:
                return WsRouteMatch()
        return WsRouteMatch(True, params, self.handler)

    def match(self, path: String) -> Bool:
        return self.match_with_params(path).matched


struct Router:
    """Mojo 原生路由表."""
    var routes: List[Route]
    var ws_routes: List[WsRoute]
    var dependencies: List[Handler]
    # APIRouter (决策-37, FastAPI APIRouter): 本 router 的 prefix / tags / 基础依赖,
    # include_router 时合并进每条路由 (path 前缀拼接 / _tags CSV / _depends ';'-CSV).
    var prefix: String
    var tags: String
    var base_deps: String

    def __init__(out self):
        self.routes = List[Route]()
        self.ws_routes = List[WsRoute]()
        self.dependencies = List[Handler]()
        self.prefix = ""
        self.tags = ""
        self.base_deps = ""

    def set_prefix(mut self, p: String):
        """APIRouter prefix (决策-37): 本 router 所有路由的路径前缀."""
        self.prefix = p

    def set_tags(mut self, t: String):
        """APIRouter tags (决策-37): CSV, 应用到本 router 所有路由 (OpenAPI tags)."""
        self.tags = t

    def set_base_deps(mut self, d: String):
        """APIRouter 基础依赖 (决策-37): ';' 分隔 (与 _depends 同格式),
        本 router 所有路由都会注入这些依赖 (FastAPI APIRouter(dependencies=[...])).
        依赖名必须已注册为 KIND_DEPENDENCY handler (add_dependency)."""
        self.base_deps = d

    def add_route(mut self, path: String, method: String, handler: Handler):
        """添加路由 (handler = kind + name + data, ADR-0004)."""
        self.routes.append(Route(path, method, handler))

    def include_router(mut self, sub: Router, prefix: String = "",
                       tags: String = "", deps: String = "") raises:
        """`include_router` (决策-37, FastAPI APIRouter/include_router 语义).

        把 sub 的全部路由合并进 self:
          path = _join_path(prefix, sub.prefix, route.path)
          tags = include tags + sub.tags + 路由 _tags  -> handler.data["_tags"] (CSV)
          deps = include deps + sub.base_deps + 路由 _depends -> handler.data["_depends"]
                 (';' 分隔, 决策-33 依赖注入机制, 合并后 dispatch 零改动)
        同时合并 sub 的依赖表 (KIND_DEPENDENCY handlers, 供 find_handler_by_name)
        与 WS 路由 (同 prefix 语义). 合并后 sub 即被消费 (调用方通常丢弃).
        """
        for i in range(len(sub.routes)):
            var r = Route(sub.routes[i].path, sub.routes[i].method, sub.routes[i].handler)
            var new_path = _join_path(prefix, sub.prefix, r.path)
            var h = r.handler.copy()
            var merged_deps = _merge_csv(deps, sub.base_deps, 59)  # ';'
            if "_depends" in h.data and h.data["_depends"] != "":
                merged_deps = _merge_csv(merged_deps, h.data["_depends"], 59)
            if merged_deps != "":
                h.set_data("_depends", merged_deps)
            var merged_tags = _merge_csv(tags, sub.tags, 44)  # ','
            if "_tags" in h.data and h.data["_tags"] != "":
                merged_tags = _merge_csv(merged_tags, h.data["_tags"], 44)
            if merged_tags != "":
                h.set_data("_tags", merged_tags)
            self.add_route(new_path, r.method, h)
        for i in range(len(sub.dependencies)):
            self.add_dependency(sub.dependencies[i])
        for i in range(len(sub.ws_routes)):
            var w = WsRoute(sub.ws_routes[i].path, sub.ws_routes[i].handler)
            var new_wpath = _join_path(prefix, sub.prefix, w.path)
            var wh = w.handler.copy()
            var w_deps = _merge_csv(deps, sub.base_deps, 59)
            if "_depends" in wh.data and wh.data["_depends"] != "":
                w_deps = _merge_csv(w_deps, wh.data["_depends"], 59)
            if w_deps != "":
                wh.set_data("_depends", w_deps)
            var w_tags = _merge_csv(tags, sub.tags, 44)
            if "_tags" in wh.data and wh.data["_tags"] != "":
                w_tags = _merge_csv(w_tags, wh.data["_tags"], 44)
            if w_tags != "":
                wh.set_data("_tags", w_tags)
            self.add_ws_route(new_wpath, wh)

    def add_dependency(mut self, handler: Handler):
        """注册一个依赖 (F-DI, 决策-33). 依赖 = KIND_DEPENDENCY 的 Handler,
        按 name 被 dispatch 的 resolve_depends 查找 (不占用 HTTP 路径)."""
        self.dependencies.append(handler.copy())

    def match_route(self, path: String, method: String) -> Bool:
        """匹配路由（精确 + pattern）."""
        for i in range(len(self.routes)):
            if self.routes[i].match(path, method):
                return True
        return False

    def match_route_with_params(self, path: String, method: String) -> RouteMatch:
        """匹配路由并返回参数 + handler 名称."""
        for i in range(len(self.routes)):
            var result = self.routes[i].match_with_params(path, method)
            if result.matched:
                return result^
        return RouteMatch()

    def methods_for_path(self, path: String) -> List[String]:
        """返回某路径已注册的所有方法（pattern 感知）.
        空列表 = 该路径不存在（404）；非空但请求方法不在其中 = 405。"""
        var result = List[String]()
        for i in range(len(self.routes)):
            if self.routes[i].match_path_only(path):
                result.append(self.routes[i].method)
        return result.copy()

    def find_handler_by_name(self, name: String) -> Handler:
        """按 name 找一个已注册 handler (F-DI, 决策-33).
        先查依赖表 (dependencies), 再查路由表 (routes). 未找到 -> 返回空 handler
        (name == ""). 依赖注入用: resolve_depends 据此解析 _depends 声明."""
        for i in range(len(self.dependencies)):
            if self.dependencies[i].name == name:
                return self.dependencies[i].copy()
        for i in range(len(self.routes)):
            if self.routes[i].handler.name == name:
                return self.routes[i].handler.copy()
        return Handler(KIND_ECHO(), "")

    def route_count(self) -> Int:
        """获取路由数量."""
        return len(self.routes)


    def add_ws_route(mut self, path: String, handler: Handler):
        """添加 WS 端点 (handler.kind = 会话行为, ADR-0007)."""
        self.ws_routes.append(WsRoute(path, handler))

    def match_ws_route(self, path: String) -> WsRouteMatch:
        """匹配 WS 端点 (精确 + {param} pattern, ADR-0009)."""
        for i in range(len(self.ws_routes)):
            var m = self.ws_routes[i].match_with_params(path)
            if m.matched:
                return m^
        return WsRouteMatch()

    def ws_route_count(self) -> Int:
        """获取 WS 端点数量."""
        return len(self.ws_routes)


def main() raises:
    print("Testing Mojo router with pattern matching...")

    var router = Router()
    router.add_route("/", "GET", Handler(KIND_STATIC(), "index"))
    router.add_route("/hello", "GET", Handler(KIND_TEMPLATE(), "hello"))
    router.add_route("/items", "GET", Handler(KIND_STATIC(), "list_items"))
    router.add_route("/items", "POST", Handler(KIND_ECHO(), "create_item"))
    router.add_route("/items/{item_id}", "GET", Handler(KIND_ECHO(), "get_item"))

    print("Route count: " + String(router.route_count()))

    # 405 detection: methods_for_path
    var ms = router.methods_for_path("/items")
    if len(ms) != 2 or not ("GET" in ms and "POST" in ms):
        print("FAIL: /items methods_for_path expected [GET, POST], got " + ", ".join(ms))
    var ms2 = router.methods_for_path("/items/42")
    if len(ms2) != 1 or not ("GET" in ms2):
        print("FAIL: /items/42 methods_for_path expected [GET], got " + ", ".join(ms2))
    var ms3 = router.methods_for_path("/users")
    if len(ms3) != 0:
        print("FAIL: /users methods_for_path expected [], got " + ", ".join(ms3))
    if len(ms) == 2 and len(ms2) == 1 and len(ms3) == 0:
        print("OK: methods_for_path (405 detection)")

    # 精确匹配
    if router.match_route("/", "GET"):
        print("OK: / GET matched")

    if router.match_route("/items", "GET"):
        print("OK: /items GET matched")

    if router.match_route("/items", "POST"):
        print("OK: /items POST matched")

    # Pattern matching
    if router.match_route("/items/42", "GET"):
        print("OK: /items/42 GET matched (pattern)")

    if not router.match_route("/items/42", "POST"):
        print("OK: /items/42 POST not matched")

    # 不匹配
    if not router.match_route("/users", "GET"):
        print("OK: /users GET not matched")

    if not router.match_route("/items/42/extra", "GET"):
        print("OK: /items/42/extra not matched")

    # Pattern 提取参数
    var result = router.match_route_with_params("/items/42", "GET")
    if result.matched:
        print("OK: /items/42 matched, handler=" + result.handler.name)
        if "item_id" in result.params:
            print("OK: item_id=" + result.params["item_id"])

    # 多参数
    router.add_route("/users/{user_id}/items/{item_id}", "GET", Handler(KIND_ECHO(), "user_item"))
    var result2 = router.match_route_with_params("/users/123/items/456", "GET")
    if result2.matched:
        print("OK: /users/123/items/456 matched, handler=" + result2.handler.name)
        if "user_id" in result2.params and "item_id" in result2.params:
            print("OK: user_id=" + result2.params["user_id"] + ", item_id=" + result2.params["item_id"])

    # WS routes (ADR-0007): exact match, user code = data
    var ws_h = Handler(KIND_WS_ECHO(), "ws_echo")
    router.add_ws_route("/ws", ws_h)
    var ws_c = Handler(KIND_WS_COUNTER(), "ws_counter")
    ws_c.set_data("ws_sp", "chat")
    router.add_ws_route("/ws/counter", ws_c)
    assert router.ws_route_count() == 2, "ws route count"
    var wm = router.match_ws_route("/ws")
    assert wm.matched and wm.handler.name == "ws_echo", "ws match /ws"
    var wm2 = router.match_ws_route("/ws/counter")
    assert wm2.matched and wm2.handler.data["ws_sp"] == "chat", "ws match /ws/counter"
    var wm3 = router.match_ws_route("/nope")
    assert not wm3.matched, "ws no match"
    if wm.matched and wm2.matched and not wm3.matched:
        print("OK: ws routes (exact match + handler data)")

    # WS {param} pattern (ADR-0009): 与 HTTP Route 同 segment 语义
    var ws_g = Handler(KIND_WS_ECHO(), "ws_greet")
    router.add_ws_route("/ws/greet/{name}", ws_g)
    var wp = router.match_ws_route("/ws/greet/Alice")
    assert wp.matched and wp.params["name"] == "Alice", "ws pattern params"
    var wp2 = router.match_ws_route("/ws/greet")
    assert not wp2.matched, "ws pattern segment count"
    var wp3 = router.match_ws_route("/ws/greet/a/b")
    assert not wp3.matched, "ws pattern too deep"
    if wp.matched and not wp2.matched and not wp3.matched:
        print("OK: ws routes (pattern + params)")

    # APIRouter (决策-37): include_router prefix / tags / base_deps 合并
    var sub = Router()
    sub.set_prefix("/api/items")
    sub.set_tags("items,api")
    sub.set_base_deps("dep_a")
    var sub_get_h = Handler(KIND_ECHO(), "api_get")
    sub.add_route("/{id}", "GET", sub_get_h)
    sub.add_route("/", "GET", Handler(KIND_STATIC(), "api_list"))
    var app2 = Router()
    app2.include_router(sub)
    assert app2.route_count() == 2, "include route count"
    var im1 = app2.match_route_with_params("/api/items/42", "GET")
    assert im1.matched and im1.params["id"] == "42", "include prefix + pattern match"
    var im2 = app2.match_route_with_params("/api/items", "GET")
    assert im2.matched, "include route '/' normalized to prefix"
    assert not app2.match_route("/api/items/42/extra", "GET"), "include too deep"
    assert not app2.match_route("/api/itemsx/42", "GET"), "include path boundary"
    assert im1.handler.data["_tags"] == "items,api", "router tags merged"
    assert im1.handler.data["_depends"] == "dep_a", "router base deps merged"
    # include 级 prefix + tags + deps 与路由级 _depends 合并
    var sub2 = Router()
    var s2h = Handler(KIND_ECHO(), "v1_ping")
    s2h.set_data("_depends", "dep_b")
    s2h.set_data("_tags", "route_tag")
    sub2.add_route("/ping", "GET", s2h)
    var app3 = Router()
    app3.include_router(sub2, "/v1", "v1_tag", "dep_x")
    var im3 = app3.match_route_with_params("/v1/ping", "GET")
    assert im3.matched, "include-level prefix"
    assert im3.handler.data["_depends"] == "dep_x;dep_b", "include deps + route deps"
    assert im3.handler.data["_tags"] == "v1_tag,route_tag", "include tags + route tags"
    # 无 prefix 时 include 不改变路径 (回归: 普通 include_router)
    var sub3 = Router()
    sub3.add_route("/plain", "GET", Handler(KIND_ECHO(), "plain"))
    var app4 = Router()
    app4.include_router(sub3)
    assert app4.match_route("/plain", "GET"), "no-prefix include keeps path"
    # WS include: prefix 同样作用于 WS 路由
    var wsub = Router()
    wsub.set_prefix("/api/ws")
    wsub.add_ws_route("/echo", Handler(KIND_WS_ECHO(), "ws_api_echo"))
    var app5 = Router()
    app5.include_router(wsub)
    assert app5.match_ws_route("/api/ws/echo").matched, "ws include prefix"
    assert not app5.match_ws_route("/ws/echo").matched, "ws include no old path"
    # _join_path 边界
    assert _join_path("", "", "/x") == "/x", "join empty"
    assert _join_path("/", "", "/x") == "/x", "join root prefix"
    assert _join_path("/a/", "", "/x") == "/a/x", "join trailing slash prefix"
    assert _join_path("a", "b", "/x") == "/a/b/x", "join no-slash prefixes"
    assert _join_path("/api/items", "", "/") == "/api/items", "join route root"
    if im1.matched and im2.matched and im3.matched and app5.match_ws_route("/api/ws/echo").matched:
        print("OK: APIRouter include_router (prefix/tags/base_deps/WS, 决策-37)")

    print("Mojo router pattern matching test completed!")
