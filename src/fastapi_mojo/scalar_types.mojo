# src/fastapi_mojo/scalar_types.mojo
#
# 决策-79 (ADR-0054): pydantic 内建标量类型 (uuid/date/datetime/time/
# timedelta/decimal) 的参数解析 + 422 错误对象 + OpenAPI schema 构造。
# 上游 = FastAPI 0.141.1 / pydantic 2.13.4 / pydantic_core 2.46.4 实测。
#
# 依赖方向: scalar_types -> {date_types, time_types, json}; numlit ->
# scalar_types; params_typed/body_validate/form_params -> numlit (间接)。
#
# 错误对象 (house 键序 loc,msg,type,input[,ctx]): uuid/date/time/timedelta
# 带 ctx.error (= 子串); datetime 带 ctx; decimal 无 ctx。
# 覆盖边界见 ADR-0054 §3.5。

from date_types import parse_datetime, parse_date, bof, _lower, _starts
from time_types import parse_time, parse_timedelta
from json import json_escape


struct ScalarParse:
    # ok: 解析成功; value: 规范化字面量 (成功; 目前 = raw 原样);
    # err_type/err_msg/err_sub: 失败时的 422 字段 (err_sub="" = 无 ctx)
    var ok: Bool
    var value: String
    var err_type: String
    var err_msg: String
    var err_sub: String

    def __init__(out self):
        self.ok = False
        self.value = ""
        self.err_type = ""
        self.err_msg = ""
        self.err_sub = ""


def _okv(v: String) -> ScalarParse:
    var r = ScalarParse()
    r.ok = True
    r.value = v
    return r^


def _se(t: String, m: String, sub: String) -> ScalarParse:
    var r = ScalarParse()
    r.err_type = t
    r.err_msg = m
    r.err_sub = sub
    return r^


def scalar_canonical(name: String) -> String:
    """标量类型别名 -> 规范名 ("uuid"/"date"/"datetime"/"time"/
    "timedelta"/"decimal"); 非标量 -> ""."""
    var low = _lower(name)
    if low == "uuid":
        return "uuid"
    if low == "date":
        return "date"
    if low == "datetime":
        return "datetime"
    if low == "time":
        return "time"
    if low == "timedelta" or low == "duration":
        return "timedelta"
    if low == "decimal":
        return "decimal"
    return ""


def is_scalar_type(name: String) -> Bool:
    return scalar_canonical(name) != ""


def scalar_openapi_schema(name: String) -> String:
    """标量类型 -> OpenAPI 3.0 schema fragment (无 title; house 参数无 title)."""
    var c = scalar_canonical(name)
    if c == "uuid":
        return "{\"type\":\"string\",\"format\":\"uuid\"}"
    if c == "date":
        return "{\"type\":\"string\",\"format\":\"date\"}"
    if c == "datetime":
        return "{\"type\":\"string\",\"format\":\"date-time\"}"
    if c == "time":
        return "{\"type\":\"string\",\"format\":\"time\"}"
    if c == "timedelta":
        return "{\"type\":\"string\",\"format\":\"duration\"}"
    if c == "decimal":
        return "{\"anyOf\":[{\"type\":\"number\"},{\"type\":\"string\",\"pattern\":\"^(?!^[-+.]*$)[+-]?0*\\\\d*\\\\.?\\\\d*$\"}]}"
    return "{\"type\":\"string\"}"


def scalar_error_object(loc: String, raw: String, r: ScalarParse) -> String:
    """失败标量 -> 完整 422 错误对象 JSON 串 (house 键序)."""
    var out = ("{\"loc\":" + loc + ",\"msg\":\"" + json_escape(r.err_msg)
               + "\",\"type\":\"" + r.err_type + "\",\"input\":\"" + json_escape(raw) + "\"")
    if r.err_sub != "":
        out = out + ",\"ctx\":{\"error\":\"" + json_escape(r.err_sub) + "\"}"
    return out + "}"


# ---------- decimal ----------

def _trim_ws(s: String) -> String:
    """去掉首尾 ASCII 空白 (Python Decimal 前后空白容忍)."""
    var b = 0
    var e = s.byte_length()
    while b < e:
        var c = bof(s, b)
        if c == 32 or c == 9 or c == 10 or c == 13 or c == 11 or c == 12:
            b += 1
        else:
            break
    while e > b:
        var c2 = bof(s, e - 1)
        if c2 == 32 or c2 == 9 or c2 == 10 or c2 == 13 or c2 == 11 or c2 == 12:
            e -= 1
        else:
            break
    return String(s[byte=b:e])


def _parse_decimal(raw: String) -> ScalarParse:
    var s = _trim_ws(raw)
    var low = _lower(s)
    if (low == "nan" or low == "+nan" or low == "-nan" or low == "inf" or low == "+inf"
            or low == "-inf" or low == "infinity" or low == "+infinity" or low == "-infinity"):
        return _se("finite_number", "Input should be a finite number", "")
    var n = s.byte_length()
    if n == 0:
        return _se("decimal_parsing", "Input should be a valid decimal", "")
    var i = 0
    if bof(s, 0) == 43 or bof(s, 0) == 45:  # + -
        i = 1
    var digits = 0
    while i < n:
        var c = bof(s, i)
        if c >= 48 and c <= 57:
            digits += 1
            i += 1
        elif c == 95 and digits > 0 and i + 1 < n and bof(s, i + 1) >= 48 and bof(s, i + 1) <= 57:
            i += 1
        else:
            break
    if i < n and bof(s, i) == 46:  # '.'
        i += 1
        while i < n:
            var c2 = bof(s, i)
            if c2 >= 48 and c2 <= 57:
                digits += 1
                i += 1
            elif c2 == 95 and digits > 0 and i + 1 < n and bof(s, i + 1) >= 48 and bof(s, i + 1) <= 57:
                i += 1
            else:
                break
    if digits == 0:
        return _se("decimal_parsing", "Input should be a valid decimal", "")
    if i < n and (bof(s, i) == 101 or bof(s, i) == 69):  # e E
        i += 1
        if i < n and (bof(s, i) == 43 or bof(s, i) == 45):
            i += 1
        var ec = 0
        while i < n and bof(s, i) >= 48 and bof(s, i) <= 57:
            ec += 1
            i += 1
        if ec == 0:
            return _se("decimal_parsing", "Input should be a valid decimal", "")
    if i != n:
        return _se("decimal_parsing", "Input should be a valid decimal", "")
    return _okv(raw)


# ---------- uuid ----------

def _is_hex(b: Int) -> Bool:
    return (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70)


def _uuid_char(ch: String, index: Int) -> ScalarParse:
    var sub = "invalid character: found `" + ch + "` at " + String(index)
    return _se("uuid_parsing", "Input should be a valid UUID, " + sub, sub)


def _uuid_msg(sub: String) -> ScalarParse:
    return _se("uuid_parsing", "Input should be a valid UUID, " + sub, sub)


def _parse_uuid(s: String) -> ScalarParse:
    var n = s.byte_length()
    var lo = 0
    var hi = n
    var offset = 0
    var simple = True
    if n >= 2 and bof(s, 0) == 123 and bof(s, n - 1) == 125:  # { ... }
        lo = 1
        hi = n - 1
        offset = 1
        simple = False
    elif n >= 9 and bof(s, 0) == 117 and bof(s, 1) == 114 and bof(s, 2) == 110 \
            and bof(s, 3) == 58 and bof(s, 4) == 117 and bof(s, 5) == 117 \
            and bof(s, 6) == 105 and bof(s, 7) == 100 and bof(s, 8) == 58:  # urn:uuid:
        lo = 9
        hi = n
        offset = 9
        simple = False
    var hyphen_count = 0
    var gb = List[Int]()
    gb.append(0)
    gb.append(0)
    gb.append(0)
    gb.append(0)
    var i = lo
    while i < hi:
        var b = bof(s, i)
        if b >= 128:
            var clen = 1
            var cp = b
            if b >= 240:
                clen = 4
                cp = b & 7
            elif b >= 224:
                clen = 3
                cp = b & 15
            elif b >= 192:
                clen = 2
                cp = b & 31
            var k = 1
            while k < clen and i + k < hi:
                cp = (cp << 6) | (bof(s, i + k) & 63)
                k += 1
            return _uuid_char(chr(cp), i - lo + offset + 1)
        if b == 45:  # '-'
            if hyphen_count < 4:
                gb[hyphen_count] = i - lo
            hyphen_count += 1
        elif not _is_hex(b):
            return _uuid_char(chr(b), i - lo + offset + 1)
        i += 1
    if hyphen_count == 0 and simple:
        if n == 32:
            return _okv(_lower(s))
        return _uuid_msg("invalid length: expected length 32 for simple format, found " + String(n))
    if hyphen_count != 4:
        return _uuid_msg("invalid group count: expected 5, found " + String(hyphen_count + 1))
    var starts = List[Int]()
    starts.append(0)
    starts.append(9)
    starts.append(14)
    starts.append(19)
    starts.append(24)
    var sizes = List[Int]()
    sizes.append(8)
    sizes.append(4)
    sizes.append(4)
    sizes.append(4)
    sizes.append(12)
    for g in range(4):
        if gb[g] != starts[g + 1] - 1:
            return _uuid_msg("invalid group length in group " + String(g) + ": expected "
                             + String(sizes[g]) + ", found " + String(gb[g] - starts[g]))
    if hi - lo - starts[4] != 12:
        return _uuid_msg("invalid group length in group 4: expected 12, found " + String(n - starts[4]))
    return _okv(_lower(String(s[byte=lo:hi])))


# ---------- dispatch ----------

def parse_scalar(name: String, raw: String) -> ScalarParse:
    """按标量类型名解析 raw -> ScalarParse (ok / 422 字段)."""
    var c = scalar_canonical(name)
    if c == "uuid":
        return _parse_uuid(raw)
    if c == "decimal":
        return _parse_decimal(raw)
    if c == "datetime":
        var r = parse_datetime(raw)
        if r.ok:
            return _okv(raw)
        return _se("datetime_from_date_parsing",
                   "Input should be a valid datetime or date, " + r.sub, r.sub)
    if c == "date":
        var r2 = parse_date(raw)
        if r2.ok:
            return _okv(raw)
        if r2.sub == "year 0 is out of range":
            return _se("date_parsing",
                       "Input should be a valid date in the format YYYY-MM-DD, year 0 is out of range",
                       "year 0 is out of range")
        if r2.sub == "__inexact__":
            return _se("date_from_datetime_inexact",
                       "Datetimes provided to dates should have zero time - e.g. be exact dates", "")
        return _se("date_from_datetime_parsing",
                   "Input should be a valid date or datetime, " + r2.sub, r2.sub)
    if c == "time":
        var r3 = parse_time(raw)
        if r3.ok:
            return _okv(raw)
        return _se("time_parsing", "Input should be in a valid time format, " + r3.sub, r3.sub)
    if c == "timedelta":
        var r4 = parse_timedelta(raw)
        if r4.ok:
            return _okv(raw)
        return _se("time_delta_parsing", "Input should be a valid timedelta, " + r4.sub, r4.sub)
    return _se("unknown_type", "unknown type", "")
