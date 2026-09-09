# src/fastapi_mojo/params_query_extra.mojo
#
# 决策-43 (ADR-0018, Goal-0003 P2 矩阵 #3): Query 参数精化 — 多值 List /
# alias / description 的声明式基础设施 (Mojo 1.0.0 无闭包 -> 声明式数据,
# 与 _param_types/_reads_headers/_body_schema 同模式)。
#
#   - _param_types 扩展: "name:int[]" = List[int] 参数 (空括号 = list;
#     与 str[low,high] enum 语法区分)。"name:int[]=" -> 默认空 list
#     (optional); "name:int[]" -> required; "name:int[]=1,2" -> 默认 [1,2]。
#   - _param_aliases: "name=alias;name2=alias2" — 查询 key = alias,
#     FastAPI Query(alias=...) 语义: 只按 alias key 绑定, 原始参数名被
#     忽略 (响应 query_<name> = 绑定值; OpenAPI parameter.name = alias)。
#   - _param_descs: "name=desc;..." — OpenAPI parameter/schema description。
#
# 值语义 (FastAPI 0.141.1 实测, /tmp/fm_probe):
#   - List 参数: ?k=a&k=b -> [a,b] (全部 occurrence, 顺序); 单值 ?k=a ->
#     [a] (wrap); 缺失 -> 默认或 422 missing。
#   - 标量参数: ?k=a&k=b -> "b" (last-wins, Starlette MultiDict.get)。
#   - 内部表示: String-dict 世界用 CSV join ("a,b") 承载 list 值,
#     handler 读 query_<key> 得 CSV (与 _reads_headers/_param_types 的
#     CSV 约定一致; 值本身含 ',' 的歧义 = 本 port 各 CSV 声明的已知
#     取舍, ADR-0018 §3.3 文档化)。
#
# 纯函数模块 (不碰 fd/env)。依赖方向: params_query_extra -> params_query;
# validate_list_values 函数内 back-import params_typed (避免模块级循环)。

from handler import Handler
from params_query import ParsedParams, parse_query_params


# ---------- 声明表解析 ----------

def parse_table(raw: String, sep: Int, keysep: Int, allow_empty_v: Bool) raises -> Dict[String, String]:
    """通用声明表: "k1<keysep>v1<sep>k2<keysep>v2" -> Dict[k, v].
    sep = 条目分隔 (ord), keysep = 键值分隔 (ord); 宽松: 无 keysep /
    空键跳过; 空值仅 allow_empty_v 时保留。_parse_table = (59,61,False);
    get_param_types (params_typed) = (59,58,True)."""
    var out = Dict[String, String]()
    if raw == "":
        return out^
    var n = raw.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(raw[byte=i]) == sep)
        if is_sep:
            if i > start:
                var piece = String(raw[byte=start:i])
                var pn = piece.byte_length()
                var eq = -1
                var j = 0
                while j < pn:
                    if ord(piece[byte=j]) == keysep:
                        eq = j
                        break
                    j += 1
                if eq > 0 and (allow_empty_v or eq < pn - 1):
                    out[String(piece[byte=0:eq])] = String(piece[byte=eq + 1:pn])
            start = i + 1
        i += 1
    return out^


def _parse_table(raw: String) raises -> Dict[String, String]:
    """解析 "k1=v1;k2=v2" -> Dict[k, v] (宽松: 无 '=' / 空 k / 空 v 跳过)."""
    return parse_table(raw, 59, 61, False)


def get_param_aliases(handler: Handler) raises -> Dict[String, String]:
    """从 handler.data 读 _param_aliases 声明表 (name=alias;..., 决策-43)."""
    if "_param_aliases" in handler.data:
        return _parse_table(handler.data["_param_aliases"])
    return Dict[String, String]()


def get_param_descs(handler: Handler) raises -> Dict[String, String]:
    """从 handler.data 读 _param_descs 声明表 (name=desc;..., 决策-43)."""
    if "_param_descs" in handler.data:
        return _parse_table(handler.data["_param_descs"])
    return Dict[String, String]()


def set_param_alias(mut handler: Handler, name: String, alias_name: String) raises:
    """声明式: handler.data["_param_aliases"] += "name=alias"."""
    if "_param_aliases" not in handler.data:
        handler.data["_param_aliases"] = ""
    var existing = handler.data["_param_aliases"]
    if existing != "":
        existing = existing + ";"
    handler.data["_param_aliases"] = existing + name + "=" + alias_name


def set_param_desc(mut handler: Handler, name: String, desc: String) raises:
    """声明式: handler.data["_param_descs"] += "name=desc"."""
    if "_param_descs" not in handler.data:
        handler.data["_param_descs"] = ""
    var existing = handler.data["_param_descs"]
    if existing != "":
        existing = existing + ";"
    handler.data["_param_descs"] = existing + name + "=" + desc


# ---------- type-spec 查询 ----------

def _type_part(spec: String) -> String:
    """spec 的 type 部分 (第一个 '=' 之前; 无 '=' = 整个)."""
    var n = spec.byte_length()
    var i = 0
    while i < n:
        if ord(spec[byte=i]) == 61:
            return String(spec[byte=0:i])
        i += 1
    return spec


def is_list_spec(spec: String) -> Bool:
    """"int[]" / "str[]" -> True (list 标记: 空括号); "str[a,b]" enum -> False."""
    var t = _type_part(spec)
    var n = t.byte_length()
    if n < 3:
        return False
    return t[byte=n-1] == ']' and t[byte=n-2] == '['


def has_eq(spec: String) -> Bool:
    """Spec 是否带 '=' (显式默认标记; list 的有默认判据)."""
    var n = spec.byte_length()
    var i = 0
    while i < n:
        if ord(spec[byte=i]) == 61:
            return True
        i += 1
    return False


def default_part(spec: String) -> String:
    """Spec 默认值部分 (首个 '=' 之后; 无 '=' -> "")."""
    var n = spec.byte_length()
    var i = 0
    while i < n:
        if ord(spec[byte=i]) == 61:
            return String(spec[byte=i+1:n])
        i += 1
    return ""


def list_default_csv(spec: String) -> String:
    """List 参数默认值 CSV ("int[]=1,2" -> "1,2"; 无 '=' -> "")."""
    return default_part(spec)


def split_csv(s: String) raises -> List[String]:
    """CSV 切分 + trim (声明值用; 无空项)."""
    var out = List[String]()
    if s == "":
        return out^
    var n = s.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(s[byte=i]) == 44)
        if is_sep:
            if i > start:
                var piece = String(s[byte=start:i])
                var b = 0
                var e = piece.byte_length()
                while b < e and (ord(piece[byte=b]) == 32 or ord(piece[byte=b]) == 9):
                    b += 1
                while e > b and (ord(piece[byte=e-1]) == 32 or ord(piece[byte=e-1]) == 9):
                    e -= 1
                if e > b:
                    out.append(String(piece[byte=b:e]))
            start = i + 1
        i += 1
    return out^


def join_values(values: List[String]) -> String:
    """List 值 -> CSV join (内部表示)."""
    var s = ""
    for i in range(len(values)):
        if i > 0:
            s = s + ","
        s = s + values[i]
    return s


# ---------- 请求侧归一化 (dispatch 成功路径调用) ----------

def apply_query_extras(mut query: ParsedParams,
                       type_spec: Dict[String, String],
                       aliases: Dict[String, String],
                       path_params: Dict[String, String]) raises:
    """请求侧归一化: 把 List/alias 参数写进 values 字典, 供 handler 与响应注入.

    语义 (ADR-0018 §3.3):
      - list 参数: values[key] = 全部 occurrence 的 CSV (无值 -> 默认 CSV;
        无默认 -> 不动, missing 422 由 validate 处理, 成功路径不会到这)
      - alias 参数: 原始 name 无绑定效力 (FastAPI Query(alias)) — values[name]
        恒覆写为绑定值 (alias key 在请求 -> 其 last-wins 值; 否则 -> 默认值)
      - path 参数跳过 (alias 只适用 query, ADR-0018 §3.2)
    """
    for k in type_spec:
        if k in path_params:
            continue
        var spec = type_spec[k]
        var key = k
        if k in aliases:
            key = aliases[k]
        var in_request = key in query.multi_values
        if is_list_spec(spec):
            if in_request:
                query.values[key] = join_values(query.get_multi(key))
            elif has_eq(spec):
                # 显式默认 (含 "str[]=" 空 list -> "", FastAPI 返回 [] 的
                # String 世界等价)
                query.values[key] = list_default_csv(spec)
        if key != k:
            var bound = ""
            var has_bound = False
            if in_request:
                if is_list_spec(spec):
                    bound = join_values(query.get_multi(key))
                elif key in query.values:
                    bound = query.values[key]
                has_bound = True
            elif has_eq(spec):
                if is_list_spec(spec):
                    bound = list_default_csv(spec)
                else:
                    bound = default_part(spec)
                has_bound = True
            if has_bound:
                query.values[k] = bound


# ---------- 自测 ----------

import std.os


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing query extras (alias/desc/list specs)...")

    var t = _parse_table("a=1;b=2;bad;c=")
    check(t["a"] == "1", "table a")
    check(t["b"] == "2", "table b")
    check("bad" not in t, "table skips no-eq")
    check("c" not in t, "table skips empty v")

    var pt = parse_table("a:1;b:", 59, 58, True)
    check(pt["a"] == "1" and pt["b"] == "", "generic table (59,58,True)")

    check(is_list_spec("int[]") == True, "list int[]")
    check(is_list_spec("str[]") == True, "list str[]")
    check(is_list_spec("int[]=1,2") == True, "list with default")
    check(is_list_spec("str[low,high]") == False, "enum not list")
    check(is_list_spec("int") == False, "scalar not list")
    check(is_list_spec("bool=1") == False, "bool scalar not list")

    check(list_default_csv("int[]=1,2") == "1,2", "list default")
    check(list_default_csv("int[]") == "", "no default")
    check(default_part("int=10") == "10", "scalar default")

    var v = split_csv("a, b ,c,, d")
    check(v == ["a", "b", "c", "d"], "split csv trim")

    check(join_values(["a", "b"]) == "a,b", "join")
    check(join_values(List[String]()) == "", "join empty")

    # apply_query_extras: list CSV 归一化 + alias 回写 (请求用 alias key)
    var q = parse_query_params("tag=a&tag=b&lmt=5&lvl=low")
    var spec = Dict[String, String]()
    spec["tag"] = "str[]="
    spec["limit"] = "int=10"
    spec["level"] = "str[low,medium,high]=high"
    var al = Dict[String, String]()
    al["limit"] = "lmt"
    al["level"] = "lvl"
    var pp = Dict[String, String]()
    apply_query_extras(q, spec, al, pp)
    check(q.values["tag"] == "a,b", "list csv normalized")
    check(q.values["lmt"] == "5", "alias value kept")
    check(q.values["limit"] == "5", "alias -> name backfill")
    check(q.values["lvl"] == "low", "alias 2 value")
    check(q.values["level"] == "low", "alias 2 -> name backfill")

    # list 缺省默认
    var q2 = parse_query_params("x=1")
    var spec2 = Dict[String, String]()
    spec2["nums"] = "int[]="
    var al2 = Dict[String, String]()
    var pp2 = Dict[String, String]()
    apply_query_extras(q2, spec2, al2, pp2)
    check(q2.values["nums"] == "", "empty default list -> empty string")

    # alias: 请求只带原始 name (无 alias key) -> 原始值被默认值覆写 (无绑定效力)
    var q3 = parse_query_params("level=low")
    var spec3 = Dict[String, String]()
    spec3["level"] = "str[low,medium,high]=high"
    var al3 = Dict[String, String]()
    al3["level"] = "lvl"
    var pp3 = Dict[String, String]()
    apply_query_extras(q3, spec3, al3, pp3)
    check(q3.values["level"] == "high", "raw name ignored -> default")
    check("lvl" not in q3.values, "no alias key inserted")

    # alias: 请求同时带两 key -> alias key 赢, 原始被覆写
    var q4 = parse_query_params("lvl=a&level=b")
    apply_query_extras(q4, spec3, al3, pp3)
    check(q4.values["level"] == "a", "alias key wins over raw")

    # path 参数不受 alias 影响
    var q5 = parse_query_params("id=9")
    var spec5 = Dict[String, String]()
    spec5["id"] = "int"
    var al5 = Dict[String, String]()
    al5["id"] = "uid"
    var pp5 = Dict[String, String]()
    pp5["id"] = "9"
    apply_query_extras(q5, spec5, al5, pp5)
    check(q5.values["id"] == "9", "path param untouched")

    print("query extras test completed!")


def make_error_json(loc: String, msg: String, type_name: String) raises -> String:
    """单个参数校验错误 JSON 对象 (与 params_typed._pe 同构, loc/msg/type)."""
    from json import json_escape
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\"}"


def validate_list_values(type_name: String, values: List[String],
                         param_name: String, mut errs: List[String]) raises:
    """决策-43: List 参数逐元素校验.

    FastAPI 0.141.1 实测语义: 首个失败元素即报 (不继续收集), loc 带数组
    下标 ["query",name,i]. string 元素恒过 (enum list 语法不可表达,
    注册期 set_param_type 拒绝)."""
    from params_typed import parse_typed_value
    var i = 0
    while i < len(values):
        var v = values[i]
        if type_name != "string" and type_name != "str":
            var pr = parse_typed_value(type_name, v)
            if not pr[0]:
                var loc = "[\"query\",\"" + param_name + "\"," + String(i) + "]"
                if type_name == "int":
                    errs.append(make_error_json(loc, "Input should be a valid integer, unable to parse string as an integer", "int_parsing"))
                elif type_name == "float":
                    errs.append(make_error_json(loc, "Input should be a valid number, unable to parse string as a number", "float_parsing"))
                else:
                    # pydantic v2 实测措辞 (标量 bool 短消息是决策-38 既有
                    # 简化; list 元素用上游完整措辞, ADR-0018 §3.4)
                    errs.append(make_error_json(loc, "Input should be a valid boolean, unable to interpret input", "bool_parsing"))
                return  # 首个失败即停 (上游同款)
        i += 1
