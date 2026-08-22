# src/fastapi_mojo/params.mojo
#
# Mojo native Path/Query/Body parameter parsing


struct ParsedParams:
    var has_error: Bool
    var error_msg: String
    var param_count: Int

    def __init__(out self):
        self.has_error = False
        self.error_msg = ""
        self.param_count = 0

    def __init__(out self, param_count: Int):
        self.has_error = False
        self.error_msg = ""
        self.param_count = param_count

    def __init__(out self, error_msg: String):
        self.has_error = True
        self.error_msg = error_msg
        self.param_count = 0


def parse_path_params(path: String, pattern: String) -> ParsedParams:
    var path_parts = path.split("/")
    var pattern_parts = pattern.split("/")

    if len(path_parts) != len(pattern_parts):
        return ParsedParams("length mismatch")

    var matched = 0
    for i in range(len(pattern_parts)):
        var pp = pattern_parts[i]
        if pp.startswith("{") and pp.endswith("}"):
            matched += 1

    return ParsedParams(matched)


def parse_query_params(query: String) -> ParsedParams:
    if query == "":
        return ParsedParams(0)

    var pairs = query.split("&")
    var count = 0
    for i in range(len(pairs)):
        var kv = pairs[i].split("=")
        if len(kv) == 2:
            count += 1

    return ParsedParams(count)


def parse_body_json(body: String) -> ParsedParams:
    if body == "":
        return ParsedParams("empty body")

    var content = body.strip()
    if not content.startswith("{"):
        return ParsedParams("not JSON object")
    if not content.endswith("}"):
        return ParsedParams("not JSON object")

    # count comma-separated fields
    var pairs = content.split(",")
    # subtract 1 for opening brace, 1 for closing brace approximation
    return ParsedParams(len(pairs))


def main():
    print("Testing Mojo params parsing...")

    var r1 = parse_path_params(
        "/users/123/items/456", "/users/{user_id}/items/{item_id}"
    )
    print("Path params matched: " + String(r1.param_count))

    var r2 = parse_query_params("name=John&age=30&city=NYC")
    print("Query params count: " + String(r2.param_count))

    var r3 = parse_body_json('{"name":"John","age":"30"}')
    print("Body fields: " + String(r3.param_count))

    print("Mojo params parsing test completed!")
