# src/fastapi_mojo/middleware.mojo
#
# 中间件实体化 (P4.3): before/after 钩子 + 真实 timing 测量.
#
# Mojo 1.0.0 无闭包/函数指针, 钩子采用"按名字分派"结构:
#   MiddlewareChain 持有按顺序注册的中间件名; 每个钩子点 (before/after)
#   由一个具名函数实现, 内部按 chain.has(name) 决定是否执行该中间件.
# 新增中间件 = 注册名字 + 在对应钩子函数里加一个 if chain.has(...) 分支
# (与 ADR-0004 的 run_handler 单一扩展点同一模式).
#
# 钩子点:
#   mw_request_id(chain, req_num)  -> before: 生成请求 ID
#   mw_timing(chain, start_ms)     -> after:  返回 duration_ms (-1 = 未启用)
#   mw_logging(chain, ...)         -> after:  [req_id] METHOD path?query → status Nms

from std.ffi import external_call


struct Middleware:
    """中间件定义 (名字 + 启用开关)."""
    var name: String
    var enabled: Bool

    def __init__(out self, name: String):
        self.name = name
        self.enabled = True

    def __init__(out self, name: String, enabled: Bool):
        self.name = name
        self.enabled = enabled

    def copy(self) -> Middleware:
        var m = Middleware(self.name, self.enabled)
        return m^


struct MiddlewareChain:
    """中间件链: 有序名字列表, 钩子按名字分派 (Mojo 1.0.0 无函数指针)."""
    var middlewares: List[Middleware]

    def __init__(out self):
        self.middlewares = List[Middleware]()

    def add(mut self, mw: Middleware):
        self.middlewares.append(mw.copy())

    def has(self, name: String) -> Bool:
        for i in range(len(self.middlewares)):
            if self.middlewares[i].name == name and self.middlewares[i].enabled:
                return True
        return False


def now_ms() -> Int:
    """当前毫秒时间戳 (C 桥接 gettimeofday_ms)."""
    return external_call["gettimeofday_ms", Int]()


def mw_request_id(chain: MiddlewareChain, req_num: Int) -> String:
    """钩子 before: request_id 生成 req-N; 未启用返回空串."""
    if chain.has("request_id"):
        return "req-" + String(req_num)
    return ""


def mw_timing(chain: MiddlewareChain, start_ms: Int) -> Int:
    """钩子 after: timing 返回处理耗时 (ms); 未启用返回 -1 (响应不带该字段)."""
    if chain.has("timing"):
        return now_ms() - start_ms
    return -1


def _hex2(v: Int) -> String:
    var hexd = "0123456789abcdef"
    var hi = (v >> 4) & 15
    var lo = v & 15
    return String(hexd[byte=hi:hi+1]) + String(hexd[byte=lo:lo+1])


def _json_escape(s: String) -> String:
    """JSON 字符串转义 (\\/"/\n/\r/\t/控制字符) — F7 access log."""
    var out = String("")
    for i in range(s.byte_length()):
        var b = ord(s[byte=i])
        if b == 34:  # '"'
            out += '\\"'
        elif b == 92:  # '\\'
            out += '\\\\'
        elif b == 10:  # '\\n'
            out += '\\n'
        elif b == 13:  # '\\r'
            out += '\\r'
        elif b == 9:   # '\\t'
            out += '\\t'
        elif b < 32:
            out += '\\u00' + _hex2(b)
        else:
            out += String(s[byte=i])
    return out


def mw_logging(chain: MiddlewareChain, req_id: String, method: String,
               path: String, query: String, status: String, duration_ms: Int):
    """钩子 after: logging 输出 [req_id] METHOD path?query → status [Nms].
    FASTAPI_MOJO_ACCESS_LOG=json → 单行 JSON (F7, Goal-0002).
    """
    if not chain.has("logging"):
        return
    var mode = external_call["get_access_log_mode", Int]()
    if mode == 1:
        # JSON access log (single-line, machine-parseable).
        var full_path = path
        if query.byte_length() > 0:
            full_path += "?" + query
        var log = '{"req_id":"' + _json_escape(req_id)
        log += '","method":"' + _json_escape(method)
        log += '","path":"' + _json_escape(full_path)
        log += '","status":"' + _json_escape(status) + '"'
        if duration_ms >= 0:
            log += ',"duration_ms":' + String(duration_ms)
        log += '}'
        print(log)
        return
    var log = "[" + req_id + "] " + method + " " + path
    if query.byte_length() > 0:
        log += "?" + query
    log += " → " + status
    if duration_ms >= 0:
        log += " " + String(duration_ms) + "ms"
    print(log)


def main() raises:
    print("Testing middleware chain + hooks (no FFI in self-test)...")

    var chain = MiddlewareChain()
    chain.add(Middleware("request_id"))
    chain.add(Middleware("logging"))
    chain.add(Middleware("timing"))
    assert chain.has("request_id"), "request_id in chain"
    assert chain.has("timing"), "timing in chain"
    assert not chain.has("nonexistent"), "unknown not in chain"
    assert mw_request_id(chain, 7) == "req-7", "request_id hook"

    # 空链: request_id 未启用 -> ""
    var empty = MiddlewareChain()
    assert mw_request_id(empty, 7) == "", "empty chain no request_id"

    # 禁用开关
    var disabled = MiddlewareChain()
    disabled.add(Middleware("request_id", False))
    assert not disabled.has("request_id"), "disabled middleware not active"
    assert mw_request_id(disabled, 7) == "", "disabled -> no id"

    # 顺序保持
    var order = MiddlewareChain()
    order.add(Middleware("a"))
    order.add(Middleware("b"))
    assert len(order.middlewares) == 2, "two middlewares"
    assert order.middlewares[0].name == "a" and order.middlewares[1].name == "b", "order"

    print("Middleware tests passed!")
