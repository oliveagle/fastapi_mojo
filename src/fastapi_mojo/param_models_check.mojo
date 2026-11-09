# src/fastapi_mojo/param_models_check.mojo
#
# 决策-105: 参数模型组声明的**注册期 fail-fast** (check_header_specs /
# check_state_specs / check_openapi_specs 同策略 — 畸形声明启动即 fail,
# 不带入请求路径).
#
# 校验面:
#   1. 声明语法 (parse_param_models 内 raise): 组条目 "name=fields" / 字段
#      条目 "name:spec" / 组内字段重名 / 组无字段 / 组名重复;
#   2. query 面: 组字段名不得与个体 _param_types 参数重名 (上游 = Python
#      形参重名, 不可能);
#   3. header 面: 组字段**必须**在 _reads_headers 声明 (否则永不读取 ->
#      永远 missing), 且不得与个体 _header_types 重名;
#   4. cookie 面: 仅语法校验 (cookie 名即字段名, 无声明表).

from router import Router
from param_models import (get_param_models, get_header_models, get_cookie_models)
from params_typed import get_param_types
from param_constraints import get_header_types, parse_reads_headers


def check_param_model_specs(router: Router) raises:
    """注册期校验全部参数模型组声明 (畸形 / 重名 / 未声明 -> 启动即 fail)."""
    for i in range(router.route_count()):
        var h = router.routes[i].handler.copy()
        # query 面
        var qt = get_param_types(h)
        var pm = get_param_models(h)
        for gi in range(len(pm)):
            var g = pm[gi].copy()
            for f in g.field_order:
                if f in qt:
                    raise Error("param_models: field collides with _param_types: "
                                + f + " in " + h.name)
        # header 面
        var hm = get_header_models(h)
        if len(hm) > 0:
            var reads = Dict[String, String]()
            if "_reads_headers" in h.data:
                reads = parse_reads_headers(h.data["_reads_headers"])
            var ht = get_header_types(h)
            for hj in range(len(hm)):
                var g = hm[hj].copy()
                for f in g.field_order:
                    if f not in reads:
                        raise Error("header_models: field not declared in "
                                    "_reads_headers: " + f + " in " + h.name)
                    if f in ht:
                        raise Error("header_models: field collides with "
                                    "_header_types: " + f + " in " + h.name)
        # cookie 面 (仅语法)
        var _ = get_cookie_models(h)
