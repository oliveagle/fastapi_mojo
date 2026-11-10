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
from param_models import (ParamModelGroup, parse_param_models, model_extra_key,
                          extra_forbidden_json)
from form_params import validate_form_collect
from form_model_core import (form_group_active, form_extra_keys, group_inject,
                             group_inject_as, form_extra_input_json,
                             union_names, plan_form_unions)
from params_query_extra import join_values
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
        if g.union_name != "":
            continue   # 决策-107: union 分支由 plan_form_unions 统一处理
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
            group_inject(inject, g, aliases, multi)
        if g.extra == "forbid":
            var ex = form_extra_keys(g, submitted, aliases)
            for k in ex:
                errs.append(extra_forbidden_json(
                    "\"body\"", k, form_extra_input_json(multi, k)))
    # 决策-107 (上游 0.161.0/0.161.1): form 面模型 union.
    var up = plan_form_unions(groups, aliases, multi)
    if not up[0]:
        for ue in up[1]:
            errs.append(ue)
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
        if g.union_name != "":
            continue   # 决策-107: union 分支单独注入 (`<union>_<字段>`)
        if not form_group_active(g, aliases, multi, submitted):
            continue
        group_inject(inject, g, aliases, multi)
        if g.extra == "allow":
            var ex = form_extra_keys(g, submitted, aliases)
            for k in ex:
                var v = String("")
                if k in multi:
                    v = join_values(multi[k].copy())
                inject[model_extra_key(g.name, k)] = v
    # 决策-107: union 选中分支 -> form_<union>_<字段> (+ allow 额外键).
    var up = plan_form_unions(groups, aliases, multi)
    var ulist = union_names(groups)
    for ui in range(len(up[2])):
        var chosen = up[2][ui]
        var uname = ulist[ui]
        var g2 = groups[chosen].copy()
        group_inject_as(inject, uname, g2, aliases, multi)
        if g2.extra == "allow":
            var ex2 = form_extra_keys(g2, submitted, aliases)
            for k2 in ex2:
                var v2 = String("")
                if k2 in multi:
                    v2 = join_values(multi[k2].copy())
                inject[uname + "_x_" + k2] = v2
    for key in inject:
        params["form_" + key] = inject[key]
