# src/fastapi_mojo/request_state.mojo
#
# 决策-50 (ADR-0025, Goal-0003 矩阵 #22): Request.state — 每请求状态存储.
#
# 上游 (starlette 1.6.0, P22-1..6): Request.state = property 由
# scope["state"] 承载 (middleware 与 endpoint 共享同一 scope dict, 每请求
# 新 scope = 新 state); 属性/ dict 双写读面; 缺失读 ->
# AttributeError/KeyError -> 500; 1.6.0 无下划线前缀禁止 (源码无 check).
# 声明式映射 (本仓库范式, ADR-0004):
#   写面 `_state_set = "key:value;key2:value2"` — 值支持 `{param}` 插值
#       (复用 substitute_params; 缺失键保留字面量), 评估位置 = 全部注入
#       之后 = 「middleware 先写、endpoint 后读」的声明式等价;
#   读面 `_reads_state = "user,dept"` — CSV -> params["state_<name>"]
#       (F10 _reads_headers/_reads_cookies 同范式; 缺失键 -> "" = 与
#       header/cookie 既有约定一致, 上游为 500 — 偏差 §3.5-1).
# 存储 = dispatch 每请求 Dict[String, String] (P22-2/6 语义: 前置阶段写
# -> handler 读, 每请求隔离); 零 FFI (纯 Mojo, JIT 可达).

from handler import Handler, substitute_params
from router import Router


def _entry_colon(entry: String) -> Int:
    """首个 ':' 下标 (无 -> -1)."""
    var n = entry.byte_length()
    var j = 0
    while j < n:
        if ord(entry[byte=j]) == 58:
            return j
        j += 1
    return -1


def validate_state_set(spec: String) -> Bool:
    """注册期校验 `_state_set`: 条目 = `key:value`（首个 ':' 切分）;
    key 非空（不含 ':' — 切分强制; ';' 为条目分隔符）; 空条目跳过.
    value 可再含 ':'（如 URL/时间戳）."""
    var n = spec.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(spec[byte=i]) == 59)
        if is_sep:
            if i > start:
                var entry = String(spec[byte=start:i])
                if _entry_colon(entry) <= 0:
                    return False
            start = i + 1
        i += 1
    return True


def apply_state_set(mut state: Dict[String, String], spec: String,
                    ctx: Dict[String, String]) raises:
    """解析 `key:value;…` 写入每请求 state.

    值支持 `{param}` 插值（ctx = path+query+body+auth 等已注入参数;
    缺失键保留 `{key}` 字面量 — KIND_RUN_CMD 同款语义, 防静默填空）;
    无 `{` 的值原样写入（热路径零成本）.
    """
    var n = spec.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(spec[byte=i]) == 59)
        if is_sep:
            if i > start:
                var entry = String(spec[byte=start:i])
                var c = _entry_colon(entry)
                if c > 0:
                    var key = String(entry[byte=0:c])
                    var raw = ""
                    if entry.byte_length() > c + 1:
                        raw = String(entry[byte=c + 1:entry.byte_length()])
                    var val = raw  # 回退: 插值失败保留原值 (KIND_RUN_CMD 同款)
                    if raw.find("{") >= 0:
                        try:
                            val = substitute_params(raw, ctx)
                        except e:
                            pass
                    state[key] = val
            start = i + 1
        i += 1


def inject_request_state(mut params: Dict[String, String],
                         state: Dict[String, String], names_csv: String) raises:
    """CSV 键名 -> `params["state_<name>"]`; 缺失键 -> `""`
    （F10 header_/cookie_ 既有约定, ADR-0025 §3.5-1）."""
    var n = names_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(names_csv[byte=i]) == 44)
        if is_sep:
            if i > start:
                var name = String(names_csv[byte=start:i])
                # trim
                var b = 0
                var e = name.byte_length()
                while b < e and (ord(name[byte=b]) == 32 or ord(name[byte=b]) == 9):
                    b += 1
                while e > b and (ord(name[byte=e - 1]) == 32 or ord(name[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    var trimmed = String(name[byte=b:e])
                    if trimmed in state:
                        params["state_" + trimmed] = state[trimmed]
                    else:
                        params["state_" + trimmed] = ""
            start = i + 1
        i += 1


def check_state_specs(router: Router) raises:
    """注册期 `_state_set` 语法检查（决策-50）: 畸形 spec 启动即 fail,
    不带入请求路径（check_body_schemas 同策略）."""
    for i in range(router.route_count()):
        var h = router.routes[i].handler.copy()
        if "_state_set" in h.data and h.data["_state_set"] != "":
            if not validate_state_set(h.data["_state_set"]):
                raise Error("request_state: bad _state_set entry "
                            "(need non-empty key before ':') in "
                            + h.name + ": " + h.data["_state_set"])
