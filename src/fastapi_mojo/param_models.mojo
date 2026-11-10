# src/fastapi_mojo/param_models.mojo
#
# 决策-105 (上游 FastAPI 0.157.0 / PR #16573 · 0.159.0 / PR #16584 ·
# 0.160.0 / PR #16594): 参数模型组 (composed / optional / extra policy) 家法映射.
#
# 上游语义 (fastapi master, fastapi/dependencies/utils.py::
# _request_param_model_to_args + request_params_to_args, 逐行核实 2026-11-10):
#   1. **组合模型** (0.157.0): 同一 location 可声明多个参数模型; 每个模型
#      独立校验 (各自取自己的字段, 各自报错);
#   2. **可选模型** (0.159.0): 组内字段一个都没出现 且 无 extra 收集值
#      -> 模型缺席 (None; 不报 missing、不注入字段默认值); 任一字段出现
#      -> 正常校验 (缺必填 -> 422 missing);
#   3. **extra 策略** (0.160.0, breaking): ignore / allow / forbid 作用于
#      该模型的**未处理键** —— 即同一 location 里不属于该模型的提交键
#      (含兄弟模型的字段与个体参数):
#        ignore -> 丢弃;  allow -> 模型收到它们 (extra 字段);
#        forbid -> 每个未处理键 422 (type extra_forbidden, msg
#                  "Extra inputs are not permitted", loc = [location, 键]);
#   4. **未处理键** (processed_keys) 的判定 = 每个组字段的**选中别名**
#      (首个在请求中出现的候选, 都不出现 -> 第一个候选); header 面额外把
#      **未转换的字段名** (x_id) 也视为已处理 (上游 "Do not accept an
#      unconverted field name as an extra header");
#   5. 422 loc = [location, 字段] (模型字段与个体参数同形); header 面用
#      **HTTP header 名** (决策-103 语义, `_`->`-` 或显式别名);
#   6. OpenAPI: 模型字段**摊平**进该 location 的 parameters; 可选模型的
#      字段 required=False.
#
# 家法映射 (声明式; fastapi_mojo 无模型概念 —— 扁平声明表 + 组):
#   _param_models      = "filters=term:str|page:int=2;pagination=limit:int=10"
#                        (';' 分隔组; '|' 分隔组内字段; 字段 = 名字:类型规格,
#                         类型规格语法与 _param_types 完全一致)
#   _param_model_opts  = "filters=extra=allow,optional;pagination=extra=forbid"
#                        (';' 分隔组; ',' 分隔属性; 属性: extra=具体值 / optional)
#   _header_models / _header_model_opts  (header 面同形)
#   _cookie_models / _cookie_model_opts  (cookie 面同形)
#
# 字段的别名/描述/约束复用该 location 的既有共享表 (按字段名索引):
#   query: _param_aliases / _param_descs / _param_constraints
#   header: _reads_headers (field 必须在其中声明, wire 名 = 条目 wire)
#           / _param_descs / _param_constraints
#   cookie: _param_descs / _param_constraints (cookie 名 = 字段名原样)
#
# 注入键 (handler 可见; 对齐上游 "模型对象" 的扁平化):
#   query_<组>_<字段> / header_<组>_<字段> / cookie_<组>_<字段>;
#   extra=allow 的额外字段: <face>_<组>_x_<键>.
#
# 纯函数模块 (无 FFI / 无 fd / 无 env; FFI diff = 0).

from handler import Handler
from alias_choices import candidates_for, first_candidate
from json import json_escape


struct ParamModelGroup:
    """一个参数模型组 (上游: BaseModel 作 Query()/Header()/Cookie()/Form() 参数)."""
    var name: String
    var extra: String          # "ignore" | "allow" | "forbid"
    var optional: Bool
    var field_order: List[String]
    var field_specs: Dict[String, String]
    # 决策-107 (上游 0.161.0 / 0.161.1): form 面**模型 union** 分支绑定.
    # 多个组 `union=<名>` 绑成同一 union; 首个分支的 discriminator /
    # union_optional 决定整个 union 的策略. query/header/cookie 面不消费.
    var union_name: String
    var union_discriminator: String
    var union_optional: Bool

    def __init__(out self):
        self.name = ""
        self.extra = "ignore"
        self.optional = False
        self.field_order = List[String]()
        self.field_specs = Dict[String, String]()
        self.union_name = ""
        self.union_discriminator = ""
        self.union_optional = False

    def copy(self) -> ParamModelGroup:
        var g = ParamModelGroup()
        g.name = self.name
        g.extra = self.extra
        g.optional = self.optional
        g.field_order = self.field_order.copy()
        g.field_specs = self.field_specs.copy()
        g.union_name = self.union_name
        g.union_discriminator = self.union_discriminator
        g.union_optional = self.union_optional
        return g^


# ---------- 声明解析小工具 ----------

def _trim(s: String) -> String:
    """去首尾空白 (ASCII 空格/制表; 与 params_query_extra.split_csv 同款)."""
    var b = 0
    var e = s.byte_length()
    while b < e and (ord(s[byte=b]) == 32 or ord(s[byte=b]) == 9):
        b += 1
    while e > b and (ord(s[byte=e - 1]) == 32 or ord(s[byte=e - 1]) == 9):
        e -= 1
    if e <= b:
        return String("")
    return String(s[byte=b:e])


def _split_char(s: String, sep: Int) -> List[String]:
    """按单字符分隔 (trim + 丢空段)."""
    var out = List[String]()
    var n = s.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(s[byte=i]) == sep)
        if is_sep:
            if i > start:
                var piece = _trim(String(s[byte=start:i]))
                if piece != "":
                    out.append(piece)
            start = i + 1
        i += 1
    return out^


def _index_of(s: String, ch: Int) -> Int:
    """首个 ch 的下标; 无 -> -1."""
    var n = s.byte_length()
    var i = 0
    while i < n:
        if ord(s[byte=i]) == ch:
            return i
        i += 1
    return -1


def _parse_opts(opts: String) -> Dict[String, String]:
    """组属性表 -> Dict[组名] = 属性 CSV 原样 ("extra=allow,optional")."""
    var out = Dict[String, String]()
    for entry in _split_char(opts, 59):   # ';'
        var eq = _index_of(entry, 61)       # '='
        if eq <= 0:
            continue
        out[String(entry[byte=0:eq])] = String(entry[byte=eq + 1:entry.byte_length()])
    return out^


def _apply_attrs(mut g: ParamModelGroup, attrs: String):
    """把属性 CSV 应用到组 (extra=... / optional)."""
    for attr in _split_char(attrs, 44):   # ','
        if attr == "optional":
            g.optional = True
        elif attr == "allow":
            g.extra = "allow"
        elif attr == "forbid":
            g.extra = "forbid"
        elif attr == "ignore":
            g.extra = "ignore"
        elif attr.startswith("extra="):
            var v = String(attr[byte=6:attr.byte_length()])
            if v == "allow" or v == "forbid" or v == "ignore":
                g.extra = v
        elif attr == "union_optional":
            g.union_optional = True
        elif attr.startswith("union="):
            g.union_name = String(attr[byte=6:attr.byte_length()])
        elif attr.startswith("discriminator="):
            g.union_discriminator = String(attr[byte=14:attr.byte_length()])


def parse_param_models(spec: String, opts: String) raises -> List[ParamModelGroup]:
    """解析 _param_models + _param_model_opts -> 组列表.

    组条目: "组名=字段:规格|字段:规格" (';' 分隔组, '|' 分隔字段);
    字段规格语法同 _param_types ("int" / "int=10" / "int[]=" /
    "str[low,high]"). 畸形声明 / 组内字段重名 / 组名重复 / 无字段组
    -> raise (注册期 check_param_model_specs 把错误前移到启动)."""
    var groups = List[ParamModelGroup]()
    var opt_map = _parse_opts(opts)
    for entry in _split_char(spec, 59):   # ';' 组分隔
        var eq = _index_of(entry, 61)       # '='
        if eq <= 0:
            raise Error("param_models: group entry needs name=field:spec|...: " + entry)
        var gname = String(entry[byte=0:eq])
        if gname == "":
            raise Error("param_models: empty group name in: " + entry)
        for gi in range(len(groups)):
            if groups[gi].name == gname:
                raise Error("param_models: duplicate group name: " + gname)
        var g = ParamModelGroup()
        g.name = gname
        if gname in opt_map:
            _apply_attrs(g, opt_map[gname])
        var fields = String(entry[byte=eq + 1:entry.byte_length()])
        for fs in _split_char(fields, 124):   # '|' 字段分隔
            var colon = _index_of(fs, 58)     # ':'
            if colon <= 0:
                raise Error("param_models: field entry needs name:spec in group "
                            + gname + ": " + fs)
            var fname = String(fs[byte=0:colon])
            var fspec = String(fs[byte=colon + 1:fs.byte_length()])
            if fname == "" or fspec == "":
                raise Error("param_models: empty field name/spec in group "
                            + gname + ": " + fs)
            if fname in g.field_specs:
                raise Error("param_models: duplicate field in group " + gname
                            + ": " + fname)
            g.field_order.append(fname)
            g.field_specs[fname] = fspec
        if len(g.field_order) == 0:
            raise Error("param_models: group has no fields: " + gname)
        groups.append(g^)
    return groups^


# ---------- 声明读取 ----------

def get_param_models(handler: Handler) raises -> List[ParamModelGroup]:
    """_param_models + _param_model_opts (query 面的参数模型组)."""
    if "_param_models" not in handler.data:
        return List[ParamModelGroup]()
    var opts = String("")
    if "_param_model_opts" in handler.data:
        opts = handler.data["_param_model_opts"]
    return parse_param_models(handler.data["_param_models"], opts)


def get_header_models(handler: Handler) raises -> List[ParamModelGroup]:
    """_header_models + _header_model_opts (header 面的参数模型组)."""
    if "_header_models" not in handler.data:
        return List[ParamModelGroup]()
    var opts = String("")
    if "_header_model_opts" in handler.data:
        opts = handler.data["_header_model_opts"]
    return parse_param_models(handler.data["_header_models"], opts)


def get_cookie_models(handler: Handler) raises -> List[ParamModelGroup]:
    """_cookie_models + _cookie_model_opts (cookie 面的参数模型组)."""
    if "_cookie_models" not in handler.data:
        return List[ParamModelGroup]()
    var opts = String("")
    if "_cookie_model_opts" in handler.data:
        opts = handler.data["_cookie_model_opts"]
    return parse_param_models(handler.data["_cookie_models"], opts)


# ---------- 组查询 ----------

def model_field_specs(groups: List[ParamModelGroup]) -> Dict[String, String]:
    """所有组的字段 -> 类型规格 (合并表; 组间字段名不得重名 — 注册期校验)."""
    var out = Dict[String, String]()
    for gi in range(len(groups)):
        var g = groups[gi].copy()
        for f in g.field_order:
            out[f] = g.field_specs[f]
    return out^


def group_of_field(groups: List[ParamModelGroup], field: String) -> String:
    """字段所属组名; 不属于任何组 -> ""."""
    for gi in range(len(groups)):
        if field in groups[gi].field_specs:
            return groups[gi].name
    return String("")


def group_by_name(groups: List[ParamModelGroup], name: String) -> ParamModelGroup:
    """按名取组 (拷贝); 不存在 -> 空组."""
    for gi in range(len(groups)):
        if groups[gi].name == name:
            return groups[gi].copy()
    return ParamModelGroup()


def group_selected_alias(g: ParamModelGroup, field: String,
                         aliases: Dict[String, String],
                         values: Dict[String, String],
                         multi: Dict[String, List[String]]) raises -> String:
    """该字段的**选中别名** = 首个在请求中出现的候选; 都不出现 -> 第一个候选.

    上游 _get_param_aliases + "next((pair for pair in aliases if pair[1] in
    received_params), aliases[0])" — 与 query 串出现顺序无关, 只看声明序."""
    var cands = candidates_for(aliases, field)
    for c in cands:
        if c in values or c in multi:
            return c
    return first_candidate(cands)


def group_field_present(g: ParamModelGroup, aliases: Dict[String, String],
                        values: Dict[String, String],
                        multi: Dict[String, List[String]]) raises -> Bool:
    """组内是否**有任一字段**出现在请求里 (上游 own_names ∩ received_params;
    own_names = 字段的**全部**请求别名, 故任一候选在场即算出现 — 注意与
    processed_keys 的"仅选中别名"不同)."""
    for f in g.field_order:
        for c in candidates_for(aliases, f):
            if c in values or c in multi:
                return True
    return False


def group_processed_keys(g: ParamModelGroup, aliases: Dict[String, String],
                         values: Dict[String, String],
                         multi: Dict[String, List[String]],
                         header_face: Bool) raises -> List[String]:
    """该组**已处理**的提交键 = 每字段的选中别名 (上游 processed_keys).

    header 面额外把**未转换的字段名** (x_id vs wire x-id) 也记为已处理
    (上游 "Do not accept an unconverted field name as an extra header")."""
    var out = List[String]()
    for f in g.field_order:
        var sel = group_selected_alias(g, f, aliases, values, multi)
        out.append(sel)
        if header_face and sel != f:
            out.append(f)
    return out^


def group_extra_keys(g: ParamModelGroup, submitted: List[String],
                     aliases: Dict[String, String],
                     values: Dict[String, String],
                     multi: Dict[String, List[String]],
                     header_face: Bool) raises -> List[String]:
    """该组**未处理**的提交键 (extra=forbid 的拒绝对象 / extra=allow 的
    收集对象), 保持提交顺序."""
    var proc = group_processed_keys(g, aliases, values, multi, header_face)
    var out = List[String]()
    for k in submitted:
        var hit = False
        for p in proc:
            if p == k:
                hit = True
                break
        if not hit:
            out.append(k)
    return out^


def model_group_active(g: ParamModelGroup, aliases: Dict[String, String],
                       values: Dict[String, String],
                       multi: Dict[String, List[String]],
                       submitted: List[String],
                       header_face: Bool) raises -> Bool:
    """该组本轮**存在** (上游: 模型被校验 vs 被替换成 Undefined -> None).

    上游 _request_param_model_to_args:
      - **非可选**模型 (注解就是模型本身): 恒校验 —— 请求什么都没给时
        params_to_process = {} -> 逐字段 missing 422 (collect-all);
      - **可选**模型 (注解是 Optional[模型]): value = Undefined <=>
        NOT (own_names ∩ received_params 或
             (extra in ("allow","forbid") 且 params_to_process 非空))
        -> 组缺席 (不校验、不注入、不报 missing).

    故: 非可选 -> 恒 True; 可选 -> 任一字段出现 / extra=allow·forbid 且
    有未处理提交键 -> True, 否则 False."""
    if not g.optional:
        return True
    if group_field_present(g, aliases, values, multi):
        return True
    if g.extra == "allow" or g.extra == "forbid":
        if len(group_extra_keys(g, submitted, aliases, values, multi, header_face)) > 0:
            return True
    return False


def extra_forbidden_json(loc_kind: String, key: String,
                          input_json: String) -> String:
    """extra=forbid 的 422 错误对象 (上游 pydantic extra_forbidden).

    loc = [location, 键] / msg "Extra inputs are not permitted" /
    type "extra_forbidden"."""
    return "{\"loc\":[" + loc_kind + ",\"" + json_escape(key) + "\"],\"msg\":\"Extra inputs are not permitted\",\"type\":\"extra_forbidden\",\"input\":" + input_json + "}"


def model_group_key(group: String, field: String) -> String:
    """注入键 (组字段): <组>_<字段>."""
    return group + "_" + field


def model_extra_key(group: String, field: String) -> String:
    """注入键 (extra=allow 的额外字段): <组>_x_<字段>."""
    return group + "_x_" + field
