# src/fastapi_mojo/alias_choices.mojo
#
# 决策-104 (上游 FastAPI 0.156.3~0.156.7 / PR #16555, #16557, #16559,
# #16560, #16562, #16564): AliasChoices 多候选别名 (validation_alias =
# AliasChoices) 的纯函数底座。
#
# 上游语义 (fastapi master, fastapi/dependencies/utils.py::_get_param_aliases
# + request_params_to_args + request_body_to_args, 逐行核实):
#   - 候选按**声明顺序**尝试; 请求中**首个出现**的候选生效;
#     一个都没出现 -> 用**第一个**候选 (作 loc / 默认来源)。
#   - 候选是**字面名**: header 候选也不做 `_` -> `-` 转换 (上游 "Explicit
#     choices are literal names, including underscores in headers")。
#   - 422 loc 用**命中的候选** (上游 loc = (in_, request_key)); 都没命中时
#     用第一个候选。
#   - path 面 (上游 0.156.5 / PR #16560): 候选里**首个出现在路由 path 模板名**
#     的那个生效 (analyze_param 里把 validation_alias 钉成该 choice)。
#
# 声明式: 既有 alias 表的**值**用 '|' (124) 分隔多候选 —
#   _param_aliases = "q=alt1|alt2"   (query / path)
#   _form_aliases   = "f=alt1|alt2"   (form)
#   _file_aliases   = "f=alt1|alt2"   (file)
#   _reads_headers  = "h=alt1|alt2"   (header)
#   _body_aliases   = "b=alt1|alt2"   (body — 决策-104 新增表)
# 单候选写法 ("name=alias") 与既有语义**完全等价** (零回归)。
#
# 纯函数模块 (无 FFI / fd / env): 叶子模块, 各参数面按需 import。

def alias_candidates(spec: String) -> List[String]:
    """'a|b|c' -> ['a','b','c']; 'a' -> ['a']; '' -> [] (空段丢弃).

    候选分隔符 '|' (124) — 与 _body_schema 内的 '|' (约束分隔符) 不同表,
    互不干扰."""
    var out = List[String]()
    var n = spec.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(spec[byte=i]) == 124)
        if is_sep:
            if i > start:
                out.append(String(spec[byte=start:i]))
            start = i + 1
        i += 1
    return out^


def candidates_for(aliases: Dict[String, String], name: String) raises -> List[String]:
    """名字的候选别名列表: 声明了 alias -> 候选集 (按声明序); 未声明 ->
    [name] (既有无别名语义). 空候选集 -> [name] (防御)."""
    if name in aliases:
        var c = alias_candidates(aliases[name])
        if len(c) > 0:
            return c^
    var out = List[String]()
    out.append(name)
    return out^


def pick_in_dict(cands: List[String], d: Dict[String, String]) raises -> String:
    """首个在 d 中**存在**的候选 (query / body 标量面); 无命中 -> ''.

    命中判据 = key 在场 (上游 "next((pair for pair in aliases if pair[1] in
    received_params), aliases[0])")."""
    for c in cands:
        if c in d:
            return c
    return ""


def pick_in_multi(cands: List[String], d: Dict[String, List[String]],
                  skip_empty: Bool) raises -> String:
    """首个在 d 中**存在**的候选 (form / file 多值面); 无命中 -> ''.

    skip_empty=True (标量): 候选末值为空串 -> 视为缺席, 继续试下一个候选
    (上游 0.149.0 空标量视为缺失; 上游 _get_multidict_value 对 FormData
    的空串返回 Undefined -> 继续试下一个 alias).
    skip_empty=False (list): 候选有 occurrence 即命中 (列表内空串保留 —
    上游 0.149.0 只对**标量**空串生效)."""
    for c in cands:
        if c in d:
            if skip_empty:
                var lst = d[c].copy()
                if len(lst) > 0 and lst[len(lst) - 1] == "":
                    continue
            return c
    return ""


def first_candidate(cands: List[String]) -> String:
    """第一个候选 (都没命中时的 loc / 默认来源); 空列表 -> ''."""
    if len(cands) == 0:
        return ""
    return cands[0]


def pick_path_name(cands: List[String], path_params: Dict[String, String],
                   name: String) raises -> String:
    """Path 面生效名 (上游 0.156.5 / PR #16560): 候选里**首个出现在路由 path
    模板名**的那个; 无候选命中但 name 本身是模板名 -> name (既有语义,
    零回归); 否则 '' (非 path 参数)."""
    var hit = pick_in_dict(cands, path_params)
    if hit != "":
        return hit
    if name in path_params:
        return name
    return ""
