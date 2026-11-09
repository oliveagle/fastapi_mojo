# src/fastapi_mojo/header_models.mojo
#
# 决策-105 (上游 0.157.0 / 0.159.0 / 0.160.0): header / cookie 面的参数模型组
# 运行期 — 校验 + 注入. 纯函数模块 (FFI 读取在 dispatch, 本模块只吃现成 dict;
# FFI diff = 0).
#
# header 面: 组字段必须在 _reads_headers 声明 (注册期 fail-fast), wire 名 =
# 条目 wire (决策-103 语义). **偏差**: extra 域 = 该路由声明且在场的 header
# (本实现只读声明面), 上游 = 请求**全部** header —— 记入 ADR-0070.
# cookie 面: reads = 恒等映射 (cookie 名原样, 不做 `_`->`-`), extra 域 =
# 全部解析出的 cookie (上游同面: 请求全部 cookie).
#
# 组字段校验复用 validate_headers_collect (类型/枚举/约束/默认 + 注入值),
# 故 header/cookie 面的字段语义与个体 typed header 完全一致.

from param_models import (ParamModelGroup, group_extra_keys, extra_forbidden_json,
                          model_group_active, model_group_key, model_extra_key)
from param_constraints_run import validate_headers_collect
from header_params import header_loc_name
from json import json_escape


def group_identity_aliases(groups: List[ParamModelGroup]) -> Dict[String, String]:
    """组字段的**请求键**映射 = 恒等 (字段名 -> 字段名).

    header 面 `_reads_headers` / cookie 面 `present` 都以**声明名**为键
    (`read_headers_present` 的 out[decl] = 值, 命中 wire 名另存 loc 表), 故
    组存在性 / 未处理键判定必须用恒等映射; `reads` (decl -> wire) **只**用于
    422 loc 命名 (决策-103 语义)。cookie 面两者等价 (cookie 名 = 字段名)."""
    var out = Dict[String, String]()
    for gi in range(len(groups)):
        var g = groups[gi].copy()
        for f in g.field_order:
            out[f] = f
    return out^


def validate_model_groups(groups: List[ParamModelGroup],
                          reads: Dict[String, String],
                          present: Dict[String, String],
                          constraints: Dict[String, String],
                          loc_kind: String,
                          header_face: Bool) raises -> Tuple[Bool, List[String], Dict[String, String]]:
    """header / cookie 面参数模型组统一校验 -> (ok, errs, inject).

    inject 键 = "<组>_<字段>" (dispatch 加 "<face>_" 前缀); 422 loc =
    [loc_kind, wire 名] (header: HTTP header 名 / cookie: 原样).
    reads 仅用于 loc 命名; 组逻辑用恒等映射 (见 group_identity_aliases)."""
    var errs = List[String]()
    var inject = Dict[String, String]()
    if len(groups) == 0:
        return (True, errs^, inject^)
    var submitted = List[String]()
    for k in present:
        submitted.append(k)
    var empty_multi = Dict[String, List[String]]()
    var amap = group_identity_aliases(groups)
    for gi in range(len(groups)):
        var g = groups[gi].copy()
        if not model_group_active(g, amap, present, empty_multi,
                                   submitted, header_face):
            continue
        var htypes = Dict[String, String]()
        for f in g.field_order:
            htypes[f] = g.field_specs[f]
        var res = validate_headers_collect(htypes, reads, present,
                                            constraints, loc_kind)
        if not res[0]:
            for e in res[1]:
                errs.append(e)
        else:
            for f in g.field_order:
                if f in res[2]:
                    inject[model_group_key(g.name, f)] = res[2][f]
        if g.extra == "forbid":
            var ex = group_extra_keys(g, submitted, amap, present,
                                       empty_multi, header_face)
            for k in ex:
                var raw = String("")
                if k in present:
                    raw = present[k]
                errs.append(extra_forbidden_json(
                    "\"" + loc_kind + "\"", header_loc_name(k, reads),
                    "\"" + json_escape(raw) + "\""))
    return (len(errs) == 0, errs^, inject^)


def apply_model_group_extras(mut params: Dict[String, String],
                             groups: List[ParamModelGroup],
                             reads: Dict[String, String],
                             present: Dict[String, String],
                             loc_kind: String,
                             header_face: Bool) raises:
    """extra=allow 的额外字段注入: "<face>_<组>_x_<键>" = raw 值."""
    if len(groups) == 0:
        return
    var submitted = List[String]()
    for k in present:
        submitted.append(k)
    var empty_multi = Dict[String, List[String]]()
    var amap = group_identity_aliases(groups)
    for gi in range(len(groups)):
        var g = groups[gi].copy()
        if g.extra != "allow":
            continue
        if not model_group_active(g, amap, present, empty_multi,
                                   submitted, header_face):
            continue
        var ex = group_extra_keys(g, submitted, amap, present,
                                   empty_multi, header_face)
        for k in ex:
            var raw = String("")
            if k in present:
                raw = present[k]
            params[loc_kind + "_" + model_extra_key(g.name, k)] = raw
