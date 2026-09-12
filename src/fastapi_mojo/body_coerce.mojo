# src/fastapi_mojo/body_coerce.mojo
#
# 决策-82 (ADR-0057): body JSON model 标量跨类型强制转换 (pydantic v2 model lax).
# 拆出校验层 (body_validate.mojo < 500 行 God 阈值): 纯字符串/数值变换, 无 FFI / fd / env.

from body_schema import _parse_f64, _is_int_lit, _is_num_lit
from numlit import parse_typed_value


def _coerce_body_scalar(tn: String, t: String, raw: String) raises -> Tuple[Bool, String, String, String]:
    """决策-82 (ADR-0057): model 标量字段**跨类型**强制 (pydantic v2 lax model 语义).

    tn = 目标类型 (int/float/bool); t = JSON 值类型 (int/float/bool/string);
    raw = JSON 值文本 (string 已 unquote). 返回 (ok, canonical, msg, type);
    ok=False -> msg/type = 上游 pydantic_core 错误对象.
    规则 (实测 pydantic 2.13.x / fastapi 0.141.1, ADR-0057 §4):
      int   <- JSON float 整值 (7.0->7 / 1e2->100) / 非整值 -> int_from_float
               <- JSON bool (true->1 / false->0); <- string (parse_int_lax)
      float <- JSON bool (true->1.0 / false->0.0); <- int/float/string (parse_float_lax)
      bool  <- JSON int/float 0/1 (-0.0->false / 1.0->true); 其它数值 -> bool_parsing
               <- bool/string (parse_bool_literal lax 集)
    """
    if tn == "int":
        if t == "bool":
            if raw == "true":
                return (True, "1", "", "")
            return (True, "0", "", "")
        if t == "float":
            var fpr = _parse_f64(raw)
            if fpr[0]:
                # Mojo Int(Float64) 不 raises (实测: 整值精确转换, 非整/超界/NaN
                # 截断或饱和 → Float64(iv)==v 为 false) → 无需 try.
                var iv = Int(fpr[1])
                if Float64(iv) == fpr[1]:
                    return (True, String(iv), "", "")
            return (False, "", "Input should be a valid integer, got a number with a fractional part", "int_from_float")
        var spr = parse_typed_value("int", raw)
        if spr[0]:
            return (True, spr[1], "", "")
        return (False, "", "Input should be a valid integer, unable to parse string as an integer", "int_parsing")
    if tn == "float":
        if t == "bool":
            if raw == "true":
                return (True, "1.0", "", "")
            return (True, "0.0", "", "")
        var sprf = parse_typed_value("float", raw)
        if sprf[0]:
            return (True, sprf[1], "", "")
        return (False, "", "Input should be a valid number, unable to parse string as a number", "float_parsing")
    # bool
    if t == "int" or t == "float":
        var num = -1.0
        if t == "int":
            var ipr = parse_typed_value("int", raw)
            if ipr[0]:
                if ipr[1] == "0":
                    num = 0.0
                elif ipr[1] == "1":
                    num = 1.0
            else:
                return (False, "", "Input should be a valid boolean, unable to interpret input", "bool_parsing")
        else:
            var fpr2 = _parse_f64(raw)
            if fpr2[0]:
                num = fpr2[1]
        if num == 0.0:
            return (True, "false", "", "")
        if num == 1.0:
            return (True, "true", "", "")
        return (False, "", "Input should be a valid boolean, unable to interpret input", "bool_parsing")
    var spb = parse_typed_value("bool", raw)
    if spb[0]:
        return (True, spb[1], "", "")
    return (False, "", "Input should be a valid boolean, unable to interpret input", "bool_parsing")


def _elem_type_err(elem_t: String) -> Tuple[String, String]:
    """元素裸类型错 (msg, type) — 完整 JSON 类型不匹配/null/object/array (决策-82).

    实测 pydantic 2.13.x: int[]/float[]/bool[] 元素为 null/{}/[] ->
    `int_type`/`float_type`/`bool_type` 裸类型错 (非 *_parsing)."""
    if elem_t == "int":
        return ("Input should be a valid integer", "int_type")
    if elem_t == "float":
        return ("Input should be a valid number", "float_type")
    if elem_t == "bool":
        return ("Input should be a valid boolean", "bool_type")
    return ("Input should be an array", "list_type")


def _elem_json_type(e: String) raises -> String:
    """元素 raw JSON 文本 -> JSON 类型标签 (与 params_json._parse_value_raw 同规则)."""
    var n = e.byte_length()
    if n == 0:
        return "unknown"
    var c0 = ord(e[byte=0])
    if c0 == 34:
        return "string"
    if c0 == 123:
        return "object"
    if c0 == 91:
        return "array"
    if e == "true" or e == "false":
        return "bool"
    if e == "null":
        return "null"
    if _is_int_lit(e):
        return "int"
    if _is_num_lit(e):
        return "float"
    return "unknown"
