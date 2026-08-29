# src/fastapi_mojo/router.mojo
#
# Mojo 原生路由表实现（支持 pattern matching）
# Route 携带 Handler (ADR-0004): 路由 = 数据, 行为由 handler.kind 决定.

from handler import Handler, KIND_ECHO, KIND_STATIC, KIND_TEMPLATE, KIND_WS_ECHO, KIND_WS_COUNTER


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

    def __init__(out self):
        self.routes = List[Route]()
        self.ws_routes = List[WsRoute]()

    def add_route(mut self, path: String, method: String, handler: Handler):
        """添加路由 (handler = kind + name + data, ADR-0004)."""
        self.routes.append(Route(path, method, handler))

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

    print("Mojo router pattern matching test completed!")
