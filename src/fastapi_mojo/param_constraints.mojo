# src/fastapi_mojo/param_constraints.mojo
#
# 决策-54 (ADR-0029, Goal-0003 P2 矩阵 #2): 参数约束面统一落地 —
# path/query/header 约束 (gt/ge/lt/le/mo/len/pat) + typed header + 注册期
# 校验 + OpenAPI 3.0.3 约束 fragment. 声明式 (ADR-0004): _param_constraints
# = "name=k=v,k=v;..." (条目 ';' 分, 首个 '=' 切 name; CSV: 数值 gt/ge/lt/le/
# mo; 字符串 len=N(-M)/pat=REGEX(值可含 '='; 含 ',' = 歧义, 文档化));
# _header_types = "name:type=default;..." (同款语法; name 必须在
# _reads_headers — wire/alias 单一事实源, 决策-53).
#
# 运行期: 422 = house 键序 loc,msg,type,input + ctx 末位 (ADR-0029 §3.5-①
# 唯一结构增量; ctx 键 = 上游拼写); 每字段仅报首个违规 (数值 mo→ge→gt→le→lt;
# 字符串 min_length→max_length→pattern, P26-c/d/e); input = 在场值 raw 串 /
# 缺失+默认违反 = 类型化默认 (P26-b-8); mo=0 = no-op (上游 parity). 群序
# path→query→header 由 dispatch 装配 (P26-b-10). pattern 经自研
# bridge/regex.rs (FFI regex_match, FFI diff = +1). 依赖方向:
# param_constraints -> {numlit, params_query_extra, header_params, handler,
# router, json, std.ffi, string_builder} (无环; params_typed 单向反向).
# Mojo 1.0.0: assert no-op / dict subscript raises / ConstraintSpec (custom
# __init__) 非 ImplicitlyCopyable -> 容器存 raw CSV string (ADR-0029 §7).

from handler import Handler
from router import Router
from numlit import (is_int_literal, is_float_literal, parse_f64, fmt_num,
                   parse_type_spec, parse_base, parse_typed_value,
                   enum_in, enum_msg, _csv_parts)
from params_query_extra import parse_table
from header_params import parse_header_entry
from json import json_escape
from std.ffi import external_call, CStringSlice
from string_builder import span_to_str


def _trim(s: String) -> Tuple[Int, Int]:
    """首尾空白 trim -> (start, end) 偏移."""
    var n = s.byte_length()
    var b = 0
    var e = n
    while b < e and (ord(s[byte=b]) == 32 or ord(s[byte=b]) == 9):
        b += 1
    while e > b and (ord(s[byte=e - 1]) == 32 or ord(s[byte=e - 1]) == 9):
        e -= 1
    return (b, e)


# ---------- 约束规格 ----------

struct ConstraintSpec:
    """单个参数的约束集 (ADR-0029 §3.1). 空串/-1 = 未声明; 数值键值 =
    声明字面量原样 (消息/OpenAPI/ctx 原样, §3.5-⑦)."""
    var gt: String
    var ge: String
    var lt: String
    var le: String
    var mo: String
    var minl: Int
    var maxl: Int
    var pat: String

    def __init__(out self):
        self.gt = ""
        self.ge = ""
        self.lt = ""
        self.le = ""
        self.mo = ""
        self.minl = -1
        self.maxl = -1
        self.pat = ""

    def has_numeric(self) -> Bool:
        return self.gt != "" or self.ge != "" or self.lt != "" or self.le != "" or self.mo != ""

    def has_string(self) -> Bool:
        return self.minl >= 0 or self.maxl >= 0 or self.pat != ""

    def is_empty(self) -> Bool:
        return not self.has_numeric() and not self.has_string()


def _parse_len(val: String) raises -> Tuple[Bool, Int, Int]:
    """len 值 'N' 或 'N-M' -> (ok, min, max); 负数/畸形 -> (False, 0, 0)."""
    var d = -1
    for li in range(val.byte_length()):
        if ord(val[byte=li]) == 45:  # '-'
            d = li
            break
    if d < 0:
        if not is_int_literal(val):
            return (False, 0, 0)
        var mn = parse_f64(val)
        if not mn[0] or mn[1] < 0.0:
            return (False, 0, 0)
        var m = Int(mn[1])
        return (True, m, m)
    var mn2 = parse_f64(String(val[byte=0:d]))
    var mx2 = parse_f64(String(val[byte=d + 1:val.byte_length()]))
    if not is_int_literal(String(val[byte=0:d])) or not is_int_literal(String(val[byte=d + 1:val.byte_length()])):
        return (False, 0, 0)
    if not mn2[0] or not mx2[0] or mn2[1] < 0.0 or mx2[1] < 0.0:
        return (False, 0, 0)
    return (True, Int(mn2[1]), Int(mx2[1]))


def parse_constraint_entry(entry: String, ctx: String) raises -> ConstraintSpec:
    """约束 CSV "gt=3,le=10" / "len=2-4,pat=^x$" -> ConstraintSpec.
    未知键 / 数值键非数字字面量 / len 非 N(-M) 或负数 -> Error (注册期)."""
    var spec = ConstraintSpec()
    var n = entry.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(entry[byte=i]) == 44)  # ','
        if is_sep:
            if i > start:
                var part = String(entry[byte=start:i])
                var pe = -1
                for j in range(part.byte_length()):
                    if ord(part[byte=j]) == 61:  # 首个 '='
                        pe = j
                        break
                if pe <= 0:
                    raise Error("constraints: bad constraint part '" + part + "'" + ctx)
                var key = String(part[byte=0:pe])
                var val = String(part[byte=pe + 1:part.byte_length()])
                if key == "gt" or key == "ge" or key == "lt" or key == "le" or key == "mo":
                    if not (is_int_literal(val) or is_float_literal(val)):
                        raise Error("constraints: bad numeric value for '" + key + "': " + val + ctx)
                    if key == "gt":
                        spec.gt = val
                    elif key == "ge":
                        spec.ge = val
                    elif key == "lt":
                        spec.lt = val
                    elif key == "le":
                        spec.le = val
                    else:
                        spec.mo = val
                elif key == "len":
                    var lr = _parse_len(val)
                    if not lr[0]:
                        raise Error("constraints: bad len value '" + val + "' (need N or N-M, non-negative)" + ctx)
                    spec.minl = lr[1]
                    spec.maxl = lr[2]
                elif key == "pat":
                    spec.pat = val
                else:
                    raise Error("constraints: unknown key '" + key + "'" + ctx)
            start = i + 1
        i += 1
    return spec^


def get_param_constraints(handler: Handler) raises -> Dict[String, String]:
    """_param_constraints 声明 -> Dict[name, raw CSV] ("name=k=v,k=v;..."; 空条目
    跳过). Mojo 1.0.0: ConstraintSpec 非 ImplicitlyCopyable (Dict 迭代要求
    Copyable) — 容器存 raw CSV string, 使用点按需 parse_constraint_entry."""
    var out: Dict[String, String] = Dict[String, String]()
    if "_param_constraints" not in handler.data:
        return out^
    var raw = handler.data["_param_constraints"]
    var n = raw.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(raw[byte=i]) == 59)  # ';'
        if is_sep:
            if i > start:
                var t = _trim(String(raw[byte=start:i]))
                if t[1] > t[0]:
                    var trimmed = String(raw[byte=start + t[0]:start + t[1]])
                    var eq = -1
                    for j in range(trimmed.byte_length()):
                        if ord(trimmed[byte=j]) == 61:  # 首个 '=' 切 name
                            eq = j
                            break
                    if eq <= 0:
                        raise Error("constraints: bad _param_constraints entry '" + trimmed
                                    + "' (need name=k=v) in " + handler.name)
                    var name = String(trimmed[byte=0:eq])
                    var csv = String(trimmed[byte=eq + 1:trimmed.byte_length()])
                    out[name] = csv  # raw CSV (使用点按需解析; 注册期 check 校验)
            start = i + 1
        i += 1
    return out^


def get_header_types(handler: Handler) raises -> Dict[String, String]:
    """_header_types 声明 -> Dict[name, type_spec] (handler.data; _param_types 同款语法)."""
    if "_header_types" not in handler.data or handler.data["_header_types"] == "":
        return Dict[String, String]()
    return parse_table(handler.data["_header_types"], 59, 58, True)


def parse_reads_headers(csv: String) -> Dict[String, String]:
    """_reads_headers CSV -> Dict[name, wire] (注册期校验与 dispatch 共用)."""
    var out = Dict[String, String]()
    var n = csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(csv[byte=i]) == 44)  # ','
        if is_sep:
            if i > start:
                var t = _trim(String(csv[byte=start:i]))
                if t[1] > t[0]:
                    var pn = parse_header_entry(String(csv[byte=start + t[0]:start + t[1]]))
                    var kn = pn[0]
                    out[kn] = pn[1]
            start = i + 1
        i += 1
    return out^


def _path_param_names(path: String) -> List[String]:
    """提取 path 里的 {param} 名字列表 (按出现顺序)."""
    var out = List[String]()
    var n = path.byte_length()
    var i = 0
    while i < n:
        if ord(path[byte=i]) == 123:  # '{'
            var j = i + 1
            while j < n and ord(path[byte=j]) != 125:
                j += 1
            if j < n:
                out.append(String(path[byte=i + 1:j]))
                i = j + 1
                continue
        i += 1
    return out^


def _rgx_match(pattern: String, s: String) -> Int:
    """FFI: regex_match(pattern, s) -> 1 = match / 0 = no match / -1 = 编译失败."""
    var p = pattern
    var t = s
    return external_call["regex_match", Int](p.as_c_string_slice(), t.as_c_string_slice())


# ---------- 注册期校验 (fail-fast, check_* 同策略) ----------

def check_param_constraints(router: Router) raises:
    """决策-54 注册期校验 (ADR-0029 §3.2): _header_types 条目 (name 必须在
    _reads_headers; 类型/默认合法) + _param_constraints 条目 (目标可解析:
    数值键仅 int/float; len/pat 仅 str/隐式 str; bool 无约束; list+约束拒
    (上游 500, P26-g); gt+ge / lt+le 互斥; pattern 编译校验;
    未声明 query 键 = 隐式 str 声明 (§3.1: 声明即参数存在)."""
    for i in range(router.route_count()):
        var h = router.routes[i].handler.copy()
        var path_segs = _path_param_names(router.routes[i].path)
        var reads = Dict[String, String]()
        if "_reads_headers" in h.data:
            reads = parse_reads_headers(h.data["_reads_headers"])
        var htypes = get_header_types(h)
        # A: _header_types 条目 (name 必须在 _reads_headers + 类型/默认合法)
        for name in htypes:
            if name not in reads:
                raise Error("constraints: _header_types name '" + name
                            + "' not declared in _reads_headers in " + h.name)
            var ts = parse_type_spec(htypes[name])
            var pb = parse_base(ts.base_type)
            if not pb.ok:
                raise Error("constraints: unknown type '" + ts.base_type + "' in _header_types entry '"
                            + htypes[name] + "' in " + h.name)
            if ts.is_list:
                if pb.is_enum:
                    raise Error("constraints: enum-list header not expressible in " + h.name + ": " + htypes[name])
                if ts.has_default():
                    for dv in _csv_parts(ts.default_value):
                        if not parse_typed_value(pb.type_name, dv)[0]:
                            raise Error("constraints: bad list default element '" + dv + "' for type '"
                                        + pb.type_name + "' on header '" + name + "' in " + h.name)
            elif pb.is_enum:
                if ts.has_default() and not enum_in(ts.default_value, pb.values_csv):
                    raise Error("constraints: _header_types default '" + ts.default_value
                                + "' not in enum values on header '" + name + "' in " + h.name)
            elif ts.has_default():
                if not parse_typed_value(pb.type_name, ts.default_value)[0]:
                    raise Error("constraints: bad _header_types default '" + ts.default_value + "' for type '"
                                + pb.type_name + "' on header '" + name + "' in " + h.name)
        # B: _param_constraints 条目 (目标解析 + 类型匹配 + pattern 编译)
        var cons = get_param_constraints(h)
        var tspec = Dict[String, String]()
        if "_param_types" in h.data:
            tspec = parse_table(h.data["_param_types"], 59, 58, True)
        # Mojo 1.0.0: ConstraintSpec (custom __init__) 非 ImplicitlyCopyable —
        # Dict 迭代要求值类型 Copyable, 故容器存 raw CSV (String Copyable);
        # 使用点按需 parse_constraint_entry (函数返回值可绑局部, 每次解析产生
        # 新值, 按值传入 = move, 用后不再生效).
        # 一律 cons[name] 成员访问 / 按值传入 (move 共享, 非拷贝), 不绑定局部.
        for name in cons:
            var ctx = " in " + h.name
            var spec = parse_constraint_entry(cons[name], ctx)
            if spec.gt != "" and spec.ge != "":
                raise Error("constraints: both gt and ge declared for '" + name + "' (keep one)" + ctx)
            if spec.lt != "" and spec.le != "":
                raise Error("constraints: both lt and le declared for '" + name + "' (keep one)" + ctx)
            var is_num: Bool
            var is_str: Bool
            if name in htypes:
                var pb2 = parse_base(parse_type_spec(htypes[name]).base_type)
                is_num = (pb2.type_name == "int" or pb2.type_name == "float")
                is_str = (pb2.type_name == "str")
                if pb2.is_list and not spec.is_empty():
                    raise Error("constraints: list header + constraints rejected (upstream 500, P26-g) on '"
                                + name + "'" + ctx)
            elif name in tspec:
                var ts2 = parse_type_spec(tspec[name])
                var pb3 = parse_base(ts2.base_type)
                if not pb3.ok:
                    raise Error("constraints: unknown type in _param_types for constraint target '" + name + "'" + ctx)
                is_num = (pb3.type_name == "int" or pb3.type_name == "float")
                is_str = (pb3.type_name == "str")
                if ts2.is_list and not spec.is_empty():
                    raise Error("constraints: list param + constraints rejected (upstream 500, P26-g) on '"
                                + name + "'" + ctx)
            elif name in reads:
                is_num = False
                is_str = True  # 未类型化 header = 隐式 str
            elif name in path_segs:
                is_num = False
                is_str = True  # 未标注 path 段 = 隐式 str
            else:
                is_num = False  # 未声明 query 键 = 隐式 str 声明 (ADR-0029 §3.1;
                is_str = True  # 声明即存在; 拼写错误 -> 每请求 422 missing 自证;
                # 数值键拼写错误仍被上方 type-mismatch 拒)
            if spec.has_numeric() and not is_num:
                raise Error("constraints: numeric constraint (gt/ge/lt/le/mo) on non-numeric param '"
                            + name + "' (上游 no-op quirk, 本实现启动即暴露)" + ctx)
            if spec.has_string() and not is_str:
                raise Error("constraints: string constraint (len/pat) on non-string param '" + name + "'" + ctx)
            if spec.pat != "" and _rgx_match(spec.pat, "") == -1:
                raise Error("constraints: bad pattern for '" + name + "': " + spec.pat + ctx)


# ---------- 运行期: 约束校验 (每字段仅报首个违规) ----------

def check_num_constraints(val: Float64, spec: ConstraintSpec) raises -> Tuple[Bool, String, String, String]:
    """数值约束校验 (优先级 mo→ge→gt→le→lt, P26-c/d/e). 返回 (ok, msg, type,
    ctx_json); ctx 键 = 上游拼写, 值 = 声明字面量原样 (§3.5-⑦). mo=0 = no-op
    (上游 parity). 消息 = 上游精确串 (P26-a)."""
    var n = spec.mo
    if n != "":
        var cv = parse_f64(n)[1]
        if cv != 0.0:
            var q = val / cv
            if q < 9.0e15 and q > -9.0e15:
                var rem = val - Float64(Int(q)) * cv
                if rem < 0.0:
                    rem = -rem
                if rem > 1e-9:
                    return (False, "Input should be a multiple of " + fmt_num(cv),
                            "multiple_of", "{\"multiple_of\":" + n + "}")
    var n2 = spec.ge
    if n2 != "" and val < parse_f64(n2)[1]:
        return (False, "Input should be greater than or equal to " + fmt_num(parse_f64(n2)[1]),
                "greater_than_equal", "{\"ge\":" + n2 + "}")
    var n3 = spec.gt
    if n3 != "" and val <= parse_f64(n3)[1]:
        return (False, "Input should be greater than " + fmt_num(parse_f64(n3)[1]),
                "greater_than", "{\"gt\":" + n3 + "}")
    var n4 = spec.le
    if n4 != "" and val > parse_f64(n4)[1]:
        return (False, "Input should be less than or equal to " + fmt_num(parse_f64(n4)[1]),
                "less_than_equal", "{\"le\":" + n4 + "}")
    var n5 = spec.lt
    if n5 != "" and val >= parse_f64(n5)[1]:
        return (False, "Input should be less than " + fmt_num(parse_f64(n5)[1]),
                "less_than", "{\"lt\":" + n5 + "}")
    return (True, "", "", "")


def check_str_len_constraints(val: String, spec: ConstraintSpec) raises -> Tuple[Bool, String, String, String]:
    """字符串 min_length→max_length (纯逻辑, 无 FFI — JIT 自测可直调).
    len = byte_length (house 约定, 同 body 面). 返回同 check_num_constraints."""
    var bl = val.byte_length()
    if spec.minl >= 0 and bl < spec.minl:
        return (False, "String should have at least " + String(spec.minl) + " characters",
                "string_too_short", "{\"min_length\":" + String(spec.minl) + "}")
    if spec.maxl >= 0 and bl > spec.maxl:
        return (False, "String should have at most " + String(spec.maxl) + " characters",
                "string_too_long", "{\"max_length\":" + String(spec.maxl) + "}")
    return (True, "", "", "")


def check_str_pattern(val: String, spec: ConstraintSpec) raises -> Tuple[Bool, String, String, String]:
    """字符串 pattern (bridge regex_match FFI, search 语义, Python re 子集 §3.6;
    JIT 自测不得调用 — 符号在 JIT 二进制未链接). 返回同上."""
    if spec.pat != "" and _rgx_match(spec.pat, val) != 1:
        return (False, "String should match pattern '" + spec.pat + "'",
                "string_pattern_mismatch", "{\"pattern\":\"" + json_escape(spec.pat) + "\"}")
    return (True, "", "", "")


def check_str_constraints(val: String, spec: ConstraintSpec) raises -> Tuple[Bool, String, String, String]:
    """字符串约束组合入口 (生产): 优先级 min_length→max_length→pattern
    (P26-c/d/e); len = byte_length (house 约定, 同 body 面); pattern 经
    bridge regex_match (search 语义, Python re 子集 §3.6). 两半 =
    check_str_len_constraints (纯) + check_str_pattern (FFI); JIT 自测
    只调纯半避免 FFI 边. 返回同 check_num_constraints."""
    var r = check_str_len_constraints(val, spec)
    if not r[0]:
        return r
    return check_str_pattern(val, spec)


def _pe_ctx(loc: String, msg: String, type_name: String, input_json: String, ctx_json: String) -> String:
    """422 错误对象 (house 键序 loc,msg,type,input + ctx 末位, §3.5-①)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + \
           "\",\"input\":" + input_json + ",\"ctx\":" + ctx_json + "}"


def _pe(loc: String, msg: String, type_name: String, input_json: String) -> String:
    """422 错误对象 (house 键序, 无 ctx) — params_typed._pe 同款."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + \
           "\",\"input\":" + input_json + "}"


# ---------- OpenAPI 3.0.3 约束 fragment ----------

def _minmax_fragments(spec: ConstraintSpec) raises -> Tuple[List[String], Bool]:
    """min/max 键对 (gt -> exclusiveMinimum:true, 3.0 布尔形式 §3.5-④; 字面量原样
    §3.5-⑦). 返回 (fragments, 是否 exclusive)."""
    var out = List[String]()
    var min_val = ""
    var excl = False
    if spec.gt != "":
        min_val = spec.gt
        excl = True
    elif spec.ge != "":
        min_val = spec.ge
    if min_val != "":
        out.append("\"minimum\":" + min_val)
        if excl:
            out.append("\"exclusiveMinimum\":true")
    var max_val = ""
    var excl2 = False
    if spec.lt != "":
        max_val = spec.lt
        excl2 = True
    elif spec.le != "":
        max_val = spec.le
    if max_val != "":
        out.append("\"maximum\":" + max_val)
        if excl2:
            out.append("\"exclusiveMaximum\":true")
    return (out^, excl)


def constraint_schema_fragments(spec: ConstraintSpec) raises -> List[String]:
    """OpenAPI 3.0.3 约束 fragment 键序 (ADR-0029 §3.5): minLength, maxLength,
    pattern, multipleOf, minimum(+exclusiveMinimum), maximum(+exclusiveMaximum)."""
    var out = List[String]()
    if spec.minl >= 0:
        out.append("\"minLength\":" + String(spec.minl))
    if spec.maxl >= 0:
        out.append("\"maxLength\":" + String(spec.maxl))
    if spec.pat != "":
        out.append("\"pattern\":\"" + json_escape(spec.pat) + "\"")
    if spec.mo != "":
        out.append("\"multipleOf\":" + spec.mo)
    var mm = _minmax_fragments(spec)
    for f in mm[0]:
        out.append(f)
    return out^
