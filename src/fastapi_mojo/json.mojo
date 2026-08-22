# src/fastapi_mojo/json.mojo
#
# Mojo 原生 JSON 序列化实现


struct JSONObject:
    """JSON 对象。"""
    var data: String
    
    def __init__(out self, data: String):
        self.data = data
    
    def __str__(self) -> String:
        return self.data


struct JSONArray:
    """JSON 数组。"""
    var data: String
    
    def __init__(out self, data: String):
        self.data = data
    
    def __str__(self) -> String:
        return self.data


def json_serialize(value: String) -> String:
    """序列化字符串为 JSON。"""
    return '"' + value + '"'


def json_serialize(value: Int) -> String:
    """序列化整数为 JSON。"""
    return String(value)


def json_serialize(value: Float64) -> String:
    """序列化浮点数为 JSON。"""
    return String(value)


def json_serialize(value: Bool) -> String:
    """序列化布尔值为 JSON。"""
    if value:
        return "true"
    else:
        return "false"


def json_serialize(value: None) -> String:
    """序列化 null 为 JSON。"""
    return "null"


def json_serialize_key_value(key: String, value: String) -> String:
    """序列化键值对为 JSON。"""
    return json_serialize(key) + ": " + value


def json_serialize_dict(data: Dict[String, String]) raises -> String:
    """序列化字典为 JSON。"""
    var items = List[String]()
    for key in data:
        items.append(json_serialize_key_value(key, json_serialize(data[key])))
    return "{" + ", ".join(items) + "}"


def json_serialize_list(data: List[String]) -> String:
    """序列化列表为 JSON。"""
    var items = List[String]()
    for item in data:
        items.append(json_serialize(item))
    return "[" + ", ".join(items) + "]"


def main() raises:
    print("Testing Mojo JSON serialization...")
    
    # 测试字符串序列化
    var str_json = json_serialize("Hello, World!")
    print("String JSON: " + str_json)
    
    # 测试整数序列化
    var int_json = json_serialize(42)
    print("Int JSON: " + int_json)
    
    # 测试浮点数序列化
    var float_json = json_serialize(3.14)
    print("Float JSON: " + float_json)
    
    # 测试布尔值序列化
    var bool_json = json_serialize(True)
    print("Bool JSON: " + bool_json)
    
    # 测试 null 序列化
    var null_json = json_serialize(None)
    print("Null JSON: " + null_json)
    
    # 测试字典序列化
    var dict_data = Dict[String, String]()
    dict_data["name"] = "John"
    dict_data["age"] = "30"
    var dict_json = json_serialize_dict(dict_data)
    print("Dict JSON: " + dict_json)
    
    # 测试列表序列化
    var list_data = List[String]()
    list_data.append("apple")
    list_data.append("banana")
    list_data.append("cherry")
    var list_json = json_serialize_list(list_data)
    print("List JSON: " + list_json)
    
    print("JSON serialization test completed!")
