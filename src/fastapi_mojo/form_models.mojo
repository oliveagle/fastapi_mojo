# src/fastapi_mojo/form_models.mojo
#
# 决策-106 (上游 FastAPI 0.158.0 / PR #16577 · 0.158.1 / PR #16579 ·
# 0.158.2 / PR #16582): **form 面参数模型组**运行期 — 组合 / 可选 / extra.
#
# 上游语义 (fastapi/dependencies/utils.py, 逐行核实 2026-11-10):
#   _get_form_models(field) = Form + not embed + not JSON ->
#       [model] (单模型) 或 union 的模型列表;
#   _extract_form_items(model_fields, received_body):
#       ① 逐字段按候选序取值 (首个有值者) -> 产出该字段的 wire 键;
#       ② 再产出**所有不在 field_aliases 里的 body 键** (field=None) ——
#          即"不属于该模型任何字段/别名"的键都进模型 dict (extra 域);
#   _extract_form_model: `Optional[Model]` 且没有任何模型被提交
#       (_is_form_model_supplied = own_names ∩ body 或 (extra in allow/forbid
#       且 body 非空)) -> Undefined (不校验、不注入默认、不报 missing);
#       非可选模型恒校验 (空 dict -> 逐字段 missing).
#
# 与 决策-105 (query/header/cookie 组) 的差异: form 面的"已处理键" = 组内
# **全部候选别名** (上游 field_aliases 收到每个 alias, 故空标量既不成为字段
# 也不成为 extra —— 直接丢弃), 而非"选中别名".
#
# 纯函数模块 (FFI diff = 0; 无 fd / 无 env).
#
# 家法语法 (与 _param_models 完全同构):
#   _form_models      = "filters=term:str|page:int=2;page2=limit:int=10"
#   _form_model_opts  = "filters=extra=allow;page2=optional"
# 注入键: form_<组>_<字段>; extra=allow 的额外键 form_<组>_x_<键>.
# 已知偏差: 组字段只能是文本 form 字段 (File 参数不参与, 上游同款排除);
#           嵌套模型 / union 分支见 ADR-0071 §5.

from handler import Handler
from param_models import (ParamModelGroup, parse_param_models, extra_forbidden_json,
                          model_group_key, model_extra_key)
from form_params import validate_form_collect
from alias_choices import candidates_for, pick_in_multi
from params_query_extra import (is_list_spec, has_eq, default_part, list_default_csv,
                                join_values, split_csv)
from params_typed import parse_type_spec, parse_base, parse_typed_value
from json import json_escape


# ---------- 声明读取 ----------

def get_form_models(handler: Handler) raises -> List[ParamModelGroup]:
    """`_form_models` + `_form_model_opts` (form 面的参数模型组)."""
    if "_form_models" not in handler.data:
        return List[ParamModelGroup]()
    var opts = String("")
    if "_form_model_opts" in handler.data:
        opts = handler.data["_form_model_opts"]
    return parse_param_models(handler.data["_form_models"], opts)


# ---------- 组判定 (form 面请求键空间) ----------

def _form_processed_keys(g: ParamModelGroup,
                         aliases: Dict[String, String]) raises -> List[String]:
    """该组的**已处理键** = 组内每字段的**全部候选别名** (上游 field_aliases).

    form 面 field_aliases 收集候选（无论有值与否），故空标量既不成为字段值
    也不成为 extra（上游 _extract_form_items 的第一轮只在有值时 yield）。
    """
    var out = List[String]()
    for f in g.field_order:
        for c in candidates_for(aliases, f):
            out.append(c)
    return out^


def _form_extra_keys(g: ParamModelGroup,
                     submitted: List[String],
                     aliases: Dict[String, String]) raises -> List[String]:
    """该组**未处理**的提交键 (保持提交序; extra=forbid 的拒绝对象)."""
    var proc = _form_processed_keys(g, aliases)
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


def _form_field_present(g: ParamModelGroup,
                        aliases: Dict[String, String],
                        multi: Dict[String, List[String]]) raises -> Bool:
    """组内是否**有任一字段的任一候选**出现在 form body 里 (含空值 —
    上游 _is_form_model_supplied 用原始 body 键判定)."""
    for f in g.field_order:
        for c in candidates_for(aliases, f):
            if c in multi:
                return True
    return False


def form_group_active(g: ParamModelGroup,
                      aliases: Dict[String, String],
                      multi: Dict[String, List[String]],
                      submitted: List[String]) raises -> Bool:
    """该组本轮是否**存在** (上游: 模型被校验 vs 替换成 Undefined).

    非可选组恒校验 (空 body -> 逐字段 missing); 可选组 = 任一字段出现 或
    (extra=allow/forbid 且有未处理键)."""
    if not g.optional:
        return True
    if _form_field_present(g, aliases, multi):
        return True
    if g.extra == "allow" or g.extra == "forbid":
        if len(_form_extra_keys(g, submitted, aliases)) > 0:
            return True
    return False


# ---------- 值归一化 (成功路径注入) ----------

def _canon_form_value(type_name: String, v: String) raises -> String:
    if type_name == "int" or type_name == "float" or type_name == "bool":
        var pr = parse_typed_value(type_name, v)
        if pr[0]:
            return pr[1]
    return v


def _canon_form_csv(type_name: String, csv: String) raises -> String:
    if csv == "":
        return csv
    var out = List[String]()
    for part in split_csv(csv):
        out.append(_canon_form_value(type_name, part))
    return join_values(out^)


def _group_inject(mut inject: Dict[String, String],
                  g: ParamModelGroup,
                  aliases: Dict[String, String],
                  multi: Dict[String, List[String]]) raises:
    """组字段 -> inject["<组>_<字段>"] (list -> 全部 occurrence CSV; 标量
    -> last-wins; 缺失 -> 声明默认; int/float/bool 规范化)."""
    for f in g.field_order:
        var spec = g.field_specs[f]
        var ts = parse_type_spec(spec)
        var pb = parse_base(ts.base_type)
        var cands = candidates_for(aliases, f)
        var hit = pick_in_multi(cands, multi, not is_list_spec(spec))
        if is_list_spec(spec):
            var lv = String("")
            if hit != "":
                lv = join_values(multi[hit].copy())
            elif has_eq(spec):
                lv = list_default_csv(spec)
            if pb.ok:
                lv = _canon_form_csv(pb.type_name, lv)
            inject[model_group_key(g.name, f)] = lv
        else:
            var sv = String("")
            if hit != "":
                var lst = multi[hit].copy()
                if len(lst) > 0:
                    sv = lst[len(lst) - 1]
                if sv == "" and has_eq(spec):
                    sv = default_part(spec)
            elif has_eq(spec):
                sv = default_part(spec)
            if pb.ok:
                sv = _canon_form_value(pb.type_name, sv)
            inject[model_group_key(g.name, f)] = sv


def _form_extra_input_json(multi: Dict[String, List[String]],
                           key: String) raises -> String:
    """extra_forbidden 的 input: 单值 -> 字符串, 多值 -> 数组 (上游 FormData
    getlist 语义)."""
    if key not in multi:
        return "null"
    var lst = multi[key].copy()
    if len(lst) == 1:
        return "\"" + json_escape(lst[0]) + "\""
    var parts = List[String]()
    for i in range(len(lst)):
        parts.append("\"" + json_escape(lst[i]) + "\"")
    return "[" + ",".join(parts) + "]"


# ---------- 校验 + 注入 ----------

def validate_form_model_groups(groups: List[ParamModelGroup],
                               aliases: Dict[String, String],
                               multi: Dict[String, List[String]]) raises -> Tuple[Bool, List[String], Dict[String, String]]:
    """form 面组统一校验 -> (ok, errs, inject).

    组字段复用 validate_form_collect（类型/枚举/约束/默认 + last-wins /
    列表全部 occurrence），故语义与个体 form 字段完全一致；422 loc =
    ["body", 字段(候选)]。extra=forbid 逐键 422 extra_forbidden。
    """
    var errs = List[String]()
    var inject = Dict[String, String]()
    if len(groups) == 0:
        return (True, errs^, inject^)
    var submitted = List[String]()
    for k in multi:
        submitted.append(k)
    for gi in range(len(groups)):
        var g = groups[gi].copy()
        if not form_group_active(g, aliases, multi, submitted):
            continue
        var spec = Dict[String, String]()
        for f in g.field_order:
            spec[f] = g.field_specs[f]
        var res = validate_form_collect(spec, aliases, multi)
        if not res[0]:
            for e in res[1]:
                errs.append(e)
        else:
            _group_inject(inject, g, aliases, multi)
        if g.extra == "forbid":
            var ex = _form_extra_keys(g, submitted, aliases)
            for k in ex:
                errs.append(extra_forbidden_json(
                    "\"body\"", k, _form_extra_input_json(multi, k)))
    return (len(errs) == 0, errs^, inject^)


def apply_form_model_extras(mut params: Dict[String, String],
                           groups: List[ParamModelGroup],
                           aliases: Dict[String, String],
                           multi: Dict[String, List[String]]) raises:
    """成功路径: 组字段 -> params["form_<组>_<字段>"]；extra=allow 的额外键
    -> params["form_<组>_x_<键>"] (多值 CSV). 缺席可选组整组不注入."""
    if len(groups) == 0:
        return
    var submitted = List[String]()
    for k in multi:
        submitted.append(k)
    var inject = Dict[String, String]()
    for gi in range(len(groups)):
        var g = groups[gi].copy()
        if not form_group_active(g, aliases, multi, submitted):
            continue
        _group_inject(inject, g, aliases, multi)
        if g.extra == "allow":
            var ex = _form_extra_keys(g, submitted, aliases)
            for k in ex:
                var v = String("")
                if k in multi:
                    v = join_values(multi[k].copy())
                inject[model_extra_key(g.name, k)] = v
    for key in inject:
        params["form_" + key] = inject[key]
