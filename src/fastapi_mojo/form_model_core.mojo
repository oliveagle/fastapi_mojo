# src/fastapi_mojo/form_model_core.mojo
#
# 决策-106/107: form 面参数模型组的**共享叶子底座** —
#   组判定 (processed / extra / present / active) / 注入 (值归一化) /
#   union 计划 (分支选择 / discriminator / 422 loc 重定位).
#
# 分层: 本模块只依赖 param_models (组结构) + form_params (字段校验)
# + alias_choices / params_query_extra / params_typed / json;
# form_models (声明读取 + 两个入口) 与 form_params (OpenAPI) 单向依赖本模块.
# 纯函数 (无 FFI / fd / env): FFI diff = 0.

from param_models import (ParamModelGroup, extra_forbidden_json,
                          model_group_key)
from form_params import validate_form_collect
from alias_choices import candidates_for, pick_in_multi
from params_query_extra import (is_list_spec, has_eq, default_part, list_default_csv,
                                join_values, split_csv)
from params_typed import parse_type_spec, parse_base, parse_typed_value
from json import json_escape


# ---------- 组判定 (form 面请求键空间) ----------

def form_processed_keys(g: ParamModelGroup,
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


def form_extra_keys(g: ParamModelGroup,
                     submitted: List[String],
                     aliases: Dict[String, String]) raises -> List[String]:
    """该组**未处理**的提交键 (保持提交序; extra=forbid 的拒绝对象)."""
    var proc = form_processed_keys(g, aliases)
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


def form_field_present(g: ParamModelGroup,
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
    if form_field_present(g, aliases, multi):
        return True
    if g.extra == "allow" or g.extra == "forbid":
        if len(form_extra_keys(g, submitted, aliases)) > 0:
            return True
    return False


# ---------- 值归一化 (成功路径注入) ----------

def canon_form_value(type_name: String, v: String) raises -> String:
    if type_name == "int" or type_name == "float" or type_name == "bool":
        var pr = parse_typed_value(type_name, v)
        if pr[0]:
            return pr[1]
    return v


def canon_form_csv(type_name: String, csv: String) raises -> String:
    if csv == "":
        return csv
    var out = List[String]()
    for part in split_csv(csv):
        out.append(canon_form_value(type_name, part))
    return join_values(out^)


def group_inject(mut inject: Dict[String, String],
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
                lv = canon_form_csv(pb.type_name, lv)
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
                sv = canon_form_value(pb.type_name, sv)
            inject[model_group_key(g.name, f)] = sv


def form_extra_input_json(multi: Dict[String, List[String]],
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


# ---------- 决策-107: form 面模型 union (上游 0.161.0 / 0.161.1) ----------
#
# 上游 (fastapi 0.162.2 `_get_form_union_models` / `_extract_form_model` /
# `_normalize_form_model`):
#   - `Form()` 参数注解为 `Union[ModelA, ModelB, ...]` (>1 个模型) -> union;
#   - 提取阶段先收全部 form 键 -> 每个分支 `_normalize_form_model` 用**该分支
#     字段集**重抽 (字段别名全收 + 其余键作 extra) -> pydantic union 校验
#     (discriminator 时按 Literal 分支, 否则 smart / left_to_right);
#   - `Optional[Union[...]]` 且无任何分支被提交 -> Undefined (不校验/不注入);
#   - 非可选 union 且 body 为空 -> 422 missing loc ["body"] (0.161.1 语义);
#   - discriminator 缺 tag -> `union_tag_not_found` (loc ["body"]);
#     tag 空串/非法 -> `union_tag_invalid` (loc ["body"]);
#   - 分支字段错误 loc = ["body", <tag>, <字段>]; forbid 的额外键同形.
#
# 家法: 多个组用 `union=<名>` 绑成同一 union (声明序 = 分支序); 首个分支的
# `discriminator=<字段>` / `union_optional` 决定整组策略. 无 discriminator 时
# 取**首个校验通过**的分支 (上游默认 smart union 的确定性近似, ADR-0072 §5).

def union_names(groups: List[ParamModelGroup]) raises -> List[String]:
    """声明序的 union 名列表 (去重)."""
    var out = List[String]()
    for gi in range(len(groups)):
        var un = groups[gi].union_name
        if un == "":
            continue
        var seen = False
        for u in out:
            if u == un:
                seen = True
                break
        if not seen:
            out.append(un)
    return out^


def _branch_spec(g: ParamModelGroup) raises -> Dict[String, String]:
    var out = Dict[String, String]()
    for f in g.field_order:
        out[f] = g.field_specs[f]
    return out^


def _csv_has(csv: String, v: String) raises -> Bool:
    for part in split_csv(csv):
        if part == v:
            return True
    return False


def _body_input_json(multi: Dict[String, List[String]]) raises -> String:
    """union_tag_* 的 input: 提交 body 的 JSON 对象 (单值字符串 / 多值数组)."""
    var parts = List[String]()
    for k in multi:
        parts.append("\"" + json_escape(k) + "\":" + form_extra_input_json(multi, k))
    return "{" + ",".join(parts) + "}"


def _disc_value(multi: Dict[String, List[String]],
                aliases: Dict[String, String],
                field: String) raises -> Tuple[Bool, String]:
    """discriminator 字段的提交值 (首个在场候选的末值)."""
    for c in candidates_for(aliases, field):
        if c in multi:
            var lst = multi[c].copy()
            if len(lst) > 0:
                return (True, lst[len(lst) - 1])
            return (True, "")
    return (False, "")


def _find_str(hay: String, needle: String) -> Int:
    var hn = hay.byte_length()
    var nn = needle.byte_length()
    if nn == 0 or nn > hn:
        return -1
    var i = 0
    while i + nn <= hn:
        var ok = True
        for j in range(nn):
            if hay[byte=i + j] != needle[byte=j]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _rebase_loc(err: String, tag: String) raises -> String:
    """把 422 loc 的 ["body", ...] 重定位成 ["body", <tag>, ...] (上游
    discriminated union 的错误 loc 含选中分支 tag)."""
    var needle = "\"loc\":[\"body\""
    var idx = _find_str(err, needle)
    if idx < 0:
        return err
    var cut = idx + needle.byte_length()
    var head = String(err[byte=0:cut])
    var tail = String(err[byte=cut:err.byte_length()])
    return head + ",\"" + json_escape(tag) + "\"" + tail


def _union_tag_not_found(disc: String, input_json: String) raises -> String:
    return ("{\"type\":\"union_tag_not_found\",\"loc\":[\"body\"],"
            + "\"msg\":\"Unable to extract tag using discriminator '"
            + json_escape(disc) + "'\",\"input\":" + input_json + "}")


def _union_tag_invalid(disc: String, tag: String, tags_csv: String,
                       input_json: String) raises -> String:
    var expected = String("")
    var parts = split_csv(tags_csv)
    for i in range(len(parts)):
        if i > 0:
            expected += ", "
        expected += "'" + parts[i] + "'"
    return ("{\"type\":\"union_tag_invalid\",\"loc\":[\"body\"],"
            + "\"msg\":\"Input tag '" + json_escape(tag)
            + "' found using '" + json_escape(disc)
            + "' does not match any of the expected tags: " + expected
            + "\",\"input\":" + input_json
            + ",\"ctx\":{\"discriminator\":\"'" + json_escape(disc) + "'\","
            + "\"tag\":\"'" + json_escape(tag) + "'\"}}")


def _union_tags(groups: List[ParamModelGroup], br: List[Int],
                disc: String) raises -> String:
    """union 各分支 discriminator 的枚举值 CSV (声明序)."""
    var parts = List[String]()
    for bi in range(len(br)):
        var g = groups[br[bi]].copy()
        if disc in g.field_specs:
            var pb = parse_base(parse_type_spec(g.field_specs[disc]).base_type)
            if pb.ok and pb.is_enum:
                for v in split_csv(pb.values_csv):
                    parts.append(v)
    return ",".join(parts)


def group_inject_as(mut inject: Dict[String, String],
                     prefix: String,
                     g: ParamModelGroup,
                     aliases: Dict[String, String],
                     multi: Dict[String, List[String]]) raises:
    """同 `group_inject`, 但注入键前缀用 union 名 (`<union>_<字段>`)."""
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
                lv = canon_form_csv(pb.type_name, lv)
            inject[prefix + "_" + f] = lv
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
                sv = canon_form_value(pb.type_name, sv)
            inject[prefix + "_" + f] = sv


def plan_form_unions(groups: List[ParamModelGroup],
                     aliases: Dict[String, String],
                     multi: Dict[String, List[String]]) raises -> Tuple[Bool, List[String], List[Int], List[String]]:
    """union 统一计划 -> (ok, errs, 选中分支下标, 选中 tag).

    `errs` 非空 = 请求不合法; `选中分支` 用于成功路径注入 (与 union_names 对齐).
    """
    var errs = List[String]()
    var sel_idx = List[Int]()
    var sel_tag = List[String]()
    var unames = union_names(groups)
    if len(unames) == 0:
        return (True, errs^, sel_idx^, sel_tag^)
    var submitted = List[String]()
    for k in multi:
        submitted.append(k)
    var input_json = _body_input_json(multi)
    for ui in range(len(unames)):
        var un = unames[ui]
        var br = List[Int]()
        for gi in range(len(groups)):
            if groups[gi].union_name == un:
                br.append(gi)
        if len(br) == 0:
            continue
        var opt = groups[br[0]].copy().union_optional
        var disc = groups[br[0]].copy().union_discriminator
        var active = False
        for bi in range(len(br)):
            var g = groups[br[bi]].copy()
            if form_field_present(g, aliases, multi):
                active = True
                break
        if not active:
            for bi in range(len(br)):
                var g = groups[br[bi]].copy()
                if (g.extra == "allow" or g.extra == "forbid") and \
                        len(form_extra_keys(g, submitted, aliases)) > 0:
                    active = True
                    break
        if not active:
            if opt:
                continue
            # 非可选 union 且 body 为空 -> 422 missing loc ["body"] (0.161.1).
            errs.append("{\"type\":\"missing\",\"loc\":[\"body\"],"
                        + "\"msg\":\"Field required\",\"input\":null}")
            continue
        if disc != "":
            var dv = _disc_value(multi, aliases, disc)
            if not dv[0]:
                errs.append(_union_tag_not_found(disc, input_json))
                continue
            if dv[1] == "":
                errs.append(_union_tag_invalid(disc, dv[1],
                                               _union_tags(groups, br, disc),
                                               input_json))
                continue
            var chosen = -1
            for bi in range(len(br)):
                var g = groups[br[bi]].copy()
                if disc in g.field_specs:
                    var pb = parse_base(parse_type_spec(g.field_specs[disc]).base_type)
                    if pb.ok and pb.is_enum and _csv_has(pb.values_csv, dv[1]):
                        chosen = br[bi]
                        break
            if chosen < 0:
                errs.append(_union_tag_invalid(disc, dv[1],
                                               _union_tags(groups, br, disc),
                                               input_json))
                continue
            var g2 = groups[chosen].copy()
            var res = validate_form_collect(_branch_spec(g2), aliases, multi)
            if not res[0]:
                for e in res[1]:
                    errs.append(_rebase_loc(e, dv[1]))
                continue
            var bad = False
            if g2.extra == "forbid":
                var ex = form_extra_keys(g2, submitted, aliases)
                for k in ex:
                    errs.append(_rebase_loc(extra_forbidden_json(
                        "\"body\"", k, form_extra_input_json(multi, k)), dv[1]))
                    bad = True
            if bad:
                continue
            sel_idx.append(chosen)
            sel_tag.append(dv[1])
        else:
            var chosen = -1
            var first_errs = List[String]()
            for bi in range(len(br)):
                var g = groups[br[bi]].copy()
                var res = validate_form_collect(_branch_spec(g), aliases, multi)
                if res[0]:
                    chosen = br[bi]
                    break
                if bi == 0:
                    first_errs = res[1].copy()
            if chosen < 0:
                for e in first_errs:
                    errs.append(e)
                continue
            var gf = groups[chosen].copy()
            var bad2 = False
            if gf.extra == "forbid":
                var ex2 = form_extra_keys(gf, submitted, aliases)
                for k2 in ex2:
                    errs.append(extra_forbidden_json(
                        "\"body\"", k2, form_extra_input_json(multi, k2)))
                    bad2 = True
            if bad2:
                continue
            sel_idx.append(chosen)
            sel_tag.append("")
    return (len(errs) == 0, errs^, sel_idx^, sel_tag^)


