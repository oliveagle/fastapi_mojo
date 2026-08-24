# src/fastapi_mojo/params.mojo
#
# Mojo native Path/Query/Body parameter parsing


struct ParsedParams:
    """解析后的参数结果。"""
    var has_error: Bool
    var error_msg: String
    var param_count: Int
    var values: Dict[String, String]

    def __init__(out self):
        self.has_error = False
        self.error_msg = ""
        self.param_count = 0
        self.values = Dict[String, String]()

    def __init__(out self, param_count: Int, values: Dict[String, String]):
        self.has_error = False
        self.error_msg = ""
        self.param_count = param_count
        self.values = values.copy()

    def __init__(out self, error_msg: String):
        self.has_error = True
        self.error_msg = error_msg
        self.param_count = 0
        self.values = Dict[String, String]()


def parse_path_params(path: String, pattern: String) -> ParsedParams:
    """解析路径参数，返回提取的参数值。"""
    var path_parts = path.split("/")
    var pattern_parts = pattern.split("/")

    if len(path_parts) != len(pattern_parts):
        return ParsedParams("length mismatch")

    var params = Dict[String, String]()
    for i in range(len(pattern_parts)):
        var pp = pattern_parts[i]
        var ap = path_parts[i]
        if pp.startswith("{") and pp.endswith("}"):
            var param_name = String(pp[byte=1 : pp.byte_length() - 1])
            params[param_name] = String(ap)

    return ParsedParams(len(params), params)


def parse_query_params(query: String) -> ParsedParams:
    """解析查询参数，返回 key-value Dict。"""
    if query == "":
        return ParsedParams(0, Dict[String, String]())

    var params = Dict[String, String]()
    var pairs = query.split("&")
    for i in range(len(pairs)):
        var kv = pairs[i].split("=")
        if len(kv) == 2:
            params[String(kv[0])] = String(kv[1])

    return ParsedParams(len(params), params)


def parse_body_json(body: String) -> ParsedParams:
    """解析 JSON body，返回 key-value Dict（简单 JSON object）。"""
    if body == "":
        return ParsedParams("empty body")

    var content = body.strip()
    if not content.startswith("{"):
        return ParsedParams("not JSON object")
    if not content.endswith("}"):
        return ParsedParams("not JSON object")

    # 去掉外层 { }
    var inner = content[byte=1 : content.byte_length() - 1]
    var params = Dict[String, String]()

    if inner.byte_length() == 0:
        return ParsedParams(0, params)

    var pairs = inner.split(",")
    for i in range(len(pairs)):
        var kv = pairs[i].split(":")
        if len(kv) == 2:
            var raw_key = String(kv[0])
            var raw_val = String(kv[1])
            var key = String(raw_key.strip().strip('"'))
            var val = String(raw_val.strip().strip('"'))
            params[key] = val

    return ParsedParams(len(params), params)


def main() raises:
    print("Testing Mojo params parsing...")

    # Path params
    var r1 = parse_path_params("/items/42", "/items/{item_id}")
    print("Path params count: " + String(r1.param_count))
    if "item_id" in r1.values:
        print("OK: item_id=" + r1.values["item_id"])

    # Multi path params
    var r2 = parse_path_params("/users/123/items/456", "/users/{user_id}/items/{item_id}")
    print("Multi path params count: " + String(r2.param_count))
    if "user_id" in r2.values and "item_id" in r2.values:
        print("OK: user_id=" + r2.values["user_id"] + ", item_id=" + r2.values["item_id"])

    # Query params
    var r3 = parse_query_params("name=Mojo&age=30")
    print("Query params count: " + String(r3.param_count))
    if "name" in r3.values and "age" in r3.values:
        print("OK: name=" + r3.values["name"] + ", age=" + r3.values["age"])

    # Body JSON
    var r4 = parse_body_json('{"name":"John","age":"30"}')
    print("Body params count: " + String(r4.param_count))
    if "name" in r4.values and "age" in r4.values:
        print("OK: name=" + r4.values["name"] + ", age=" + r4.values["age"])

    # Empty
    var r5 = parse_query_params("")
    print("Empty query count: " + String(r5.param_count))

    var r6 = parse_body_json("")
    print("Empty body error: " + r6.error_msg)

    print("Mojo params parsing test completed!")
