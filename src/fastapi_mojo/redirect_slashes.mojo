# src/fastapi_mojo/redirect_slashes.mojo
#
# 决策-71 (ADR-0046): Starlette Router `redirect_slashes` 等价 (默认行为).
#
# 上游 starlette 1.6.0 routing.py Router.__call__:
#   if scope["type"] == "http" and self.redirect_slashes and route_path != "/":
#       redirect_scope = dict(scope)
#       if route_path.endswith("/"):
#           redirect_scope["path"] = redirect_scope["path"].rstrip("/")
#       else:
#           redirect_scope["path"] = redirect_scope["path"] + "/"
#       for route in self.routes:
#           match, child_scope = route.matches(redirect_scope)
#           if match != Match.NONE:            # path 匹配即可 (method 无关, FULL|PARTIAL)
#               response = RedirectResponse(url=str(URL(scope=redirect_scope)))
#               ...
# Location = scheme://host<alt_path>?<query> (绝对 URL, 307 Temporary Redirect).
#
# 本文件 = 纯逻辑 (无 FFI), 可 `mojo run redirect_slashes.mojo` 自检; dispatch 侧
# 只做 host/scheme 取值 + send_redirect_response (决策-68 复用).


def alt_slash_path(path: String) -> String:
    """Starlette 的 slash-redirect 候选路径.

    path 以 "/" 结尾 -> 去掉**全部**尾部 "/" (rstrip 语义); 否则追加 "/".
    "/" / 空串 -> "" (上游 `route_path != "/"` 排除, 不重定向)."""
    if path == "" or path == "/":
        return ""
    var n = path.byte_length()
    # 决策-83/ADR-0058: 字节安全 (Mojo 1.0.0 String[byte=i] 在码点内部 assert;
    # 原始多字节 path (如 /café) 尾字节是续字节 -> 崩溃).
    if Int(path.as_bytes()[n - 1]) == 47:  # '/'
        var e = n
        while e > 0 and Int(path.as_bytes()[e - 1]) == 47:
            e -= 1
        return String(path[byte=0:e])
    return path + "/"


def build_redirect_location(scheme: String, host: String, path: String,
                            query: String) -> String:
    """绝对 URL: scheme://host<path>[?<query>] (上游 URL(scope=redirect_scope))."""
    var loc = scheme + "://" + host + path
    if query != "":
        loc += "?" + query
    return loc^


def main() raises:
    check(alt_slash_path("/items") == "/items/", "add slash")
    check(alt_slash_path("/items/") == "/items", "strip slash")
    check(alt_slash_path("/items//") == "/items", "rstrip all trailing")
    check(alt_slash_path("/only//") == "/only", "rstrip all trailing 2")
    check(alt_slash_path("/") == "", "root excluded")
    check(alt_slash_path("") == "", "empty excluded")
    check(alt_slash_path("//") == "", "double slash -> empty")
    check(alt_slash_path("/a/b") == "/a/b/", "nested add")
    check(build_redirect_location("http", "h:8000", "/items/", "") == "http://h:8000/items/", "loc no query")
    check(build_redirect_location("https", "h", "/items", "x=1&y=2") == "https://h/items?x=1&y=2", "loc with query")
    print("redirect_slashes self-test: OK")


def check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)
