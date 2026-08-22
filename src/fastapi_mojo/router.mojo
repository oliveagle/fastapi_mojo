# src/fastapi_mojo/router.mojo
#
# Mojo 原生路由表实现


struct Route:
    """路由条目。"""
    var path: String
    var method: String
    
    def __init__(out self, path: String, method: String):
        self.path = path
        self.method = method
    
    def match(self, path: String, method: String) -> Bool:
        """检查路由是否匹配。"""
        return self.path == path and self.method == method


struct Router:
    """Mojo 原生路由表。"""
    var routes: List[Route]
    
    def __init__(out self):
        self.routes = List[Route]()
    
    def add_route(mut self, path: String, method: String):
        """添加路由。"""
        self.routes.append(Route(path, method))
    
    def match_route(self, path: String, method: String) -> Bool:
        """匹配路由。"""
        for i in range(len(self.routes)):
            if self.routes[i].match(path, method):
                return True
        return False
    
    def route_count(self) -> Int:
        """获取路由数量。"""
        return len(self.routes)


def hello_handler():
    """Hello 路由处理器。"""
    print("Hello from Mojo router!")


def items_handler():
    """Items 路由处理器。"""
    print("Items from Mojo router!")


def main():
    print("Testing Mojo router...")
    
    # 创建路由表
    var router = Router()
    
    # 添加路由
    router.add_route("/", "GET")
    router.add_route("/items", "GET")
    router.add_route("/items", "POST")
    
    print("Route count: " + String(router.route_count()))
    
    # 测试路由匹配
    if router.match_route("/", "GET"):
        print("Matched route: / GET")
    
    if router.match_route("/items", "GET"):
        print("Matched route: /items GET")
    
    if router.match_route("/items", "POST"):
        print("Matched route: /items POST")
    
    if not router.match_route("/users", "GET"):
        print("No match for: /users GET")
    
    print("Mojo router test completed!")
