# src/fastapi_mojo/date_types.mojo
#
# 决策-79 (ADR-0054): 标量日期/时间类型解析原语 — 叶子模块 (零 import)。
# 对齐 FastAPI/pydantic v2 内建标量类型 `datetime.datetime` / `datetime.date` /
# `datetime.time` / `datetime.timedelta` 的字符串解析与错误子串 (上游
# pydantic_core 2.46.4 实测)。返回 (ok, sub)：sub = 失败时的错误子串
# (上游 msg = "Input should be a valid …, " + sub; ctx.error = sub)。
#
# 依赖方向: scalar_types -> date_types (单向); numlit -> scalar_types。
#
# 覆盖边界 (ADR-0054 §3.5 偏差记录): epoch 数值串极端年份 / 少量 speedate
# 畸形分支 (如 "4 seconds" 类多词单位) 按最近观察行为回退; 常见合法/畸形
# 输入逐字节对齐。

struct DtParse:
    # ok: 解析成功; sub: 失败子串 (成功 = ""); exact: 时间部分全零 (date 用)
    var ok: Bool
    var sub: String
    var exact: Bool

    def __init__(out self):
        self.ok = False
        self.sub = ""
        self.exact = False


def bof(s: String, i: Int) -> Int:
    """字节安全取值 (Mojo 1.0.0: String[byte=i] 在码点内部下标会 assert;
    as_bytes() span 取原始字节, 避免多字节输入崩溃)。"""
    return Int(s.as_bytes()[i])


def _d(c: Int) -> Bool:
    """ASCII 十进制数字."""
    return c >= 48 and c <= 57


def _okp() -> DtParse:
    var r = DtParse()
    r.ok = True
    r.exact = True
    return r^


def _err(sub: String) -> DtParse:
    var r = DtParse()
    r.sub = sub
    return r^


def _starts(s: String, pre: String) -> Bool:
    var sl = s.byte_length()
    var pl = pre.byte_length()
    if pl > sl:
        return False
    for i in range(pl):
        if bof(s, i) != bof(pre, i):
            return False
    return True


def _lower(s: String) -> String:
    """ASCII 小写 (字节级; 非 ASCII 原样)."""
    var out = String()
    for i in range(s.byte_length()):
        var c = bof(s, i)
        if c >= 65 and c <= 90:
            out += chr(c + 32)
        else:
            out += chr(c)
    return out^


def _digits2(s: String, i: Int) -> Int:
    """两位数字 -> 值; 非数字 -> -1."""
    if i + 2 > s.byte_length():
        return -1
    var a = bof(s, i)
    var b = bof(s, i + 1)
    if not _d(a) or not _d(b):
        return -1
    return (a - 48) * 10 + (b - 48)


def is_leap(y: Int) -> Bool:
    if y % 4 != 0:
        return False
    if y % 100 != 0:
        return True
    return y % 400 == 0


def days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _year4(s: String) -> Int:
    return ((bof(s, 0) - 48) * 1000 + (bof(s, 1) - 48) * 100
            + (bof(s, 2) - 48) * 10 + (bof(s, 3) - 48))


# ---------- datetime ----------

def parse_datetime(s: String) -> DtParse:
    """ISO-8601 datetime / date 或 epoch 数值串 -> DtParse."""
    var n = s.byte_length()
    if n == 0:
        return _err("input is too short")
    var num = _epoch_seconds(s)
    if num[0]:
        return _from_epoch(num[1])
    return _parse_iso_datetime(s)


def _epoch_seconds(s: String) -> Tuple[Bool, Float64]:
    """宽松数值串 -> (True, seconds): 整数/浮点且年份落在 1..9999; 否则回退."""
    var n = s.byte_length()
    var i = 0
    if n > 0 and (bof(s, 0) == 45 or bof(s, 0) == 43):  # - +
        i = 1
    if i >= n:
        return (False, 0.0)
    var seen_digit = False
    var seen_dot = False
    while i < n:
        var c = bof(s, i)
        if _d(c):
            seen_digit = True
        elif c == 46 and not seen_dot:
            seen_dot = True
        else:
            return (False, 0.0)
        i += 1
    if not seen_digit:
        return (False, 0.0)
    var v: Float64
    try:
        v = Float64(s)
    except:
        return (False, 0.0)
    if v < -62135596800.0 or v > 253402300799.0:
        return (False, 0.0)
    return (True, v)


def _floor_div(a: Int, b: Int) -> Int:
    var q = a // b
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q -= 1
    return q


def _civil_from_days(z: Int) -> Tuple[Int, Int, Int]:
    """Howard Hinnant civil_from_days (天 -> 年月日; 1970-01-01 = day 0)."""
    var zz = z + 719468
    var era = _floor_div(zz, 146097)
    var doe = zz - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    var yy = y + 1 if m <= 2 else y
    return (yy, m, d)


def _from_epoch(v: Float64) -> DtParse:
    var days_f = v / 86400.0
    var days = Int(days_f)
    if Float64(days) > days_f:
        days -= 1
    var rem = v - Float64(days) * 86400.0
    if rem < 0.0:
        days -= 1
        rem += 86400.0
    var hour = Int(rem / 3600.0)
    rem -= Float64(hour) * 3600.0
    var minute = Int(rem / 60.0)
    rem -= Float64(minute) * 60.0
    var second = Int(rem)
    var frac = rem - Float64(second)
    var micro = Int(frac * 1000000.0 + 0.5)
    if micro >= 1000000:
        micro -= 1000000
        second += 1
    var exact = hour == 0 and minute == 0 and second == 0 and micro == 0
    var r = DtParse()
    r.ok = True
    r.exact = exact
    return r^


def _parse_iso_datetime(s: String) -> DtParse:
    var n = s.byte_length()
    if n < 10:
        return _err("input is too short")
    for k in range(4):
        if not _d(bof(s, k)):
            return _err("invalid character in year")
    if bof(s, 4) != 45:
        return _err("invalid date separator, expected `-`")
    var m = _digits2(s, 5)
    if m < 0:
        return _err("invalid character in month")
    if bof(s, 7) != 45:
        return _err("invalid date separator, expected `-`")
    var d = _digits2(s, 8)
    if d < 0:
        return _err("invalid character in day")
    var y = _year4(s)
    if m < 1 or m > 12:
        return _err("month value is outside expected range of 1-12")
    if d < 1 or d > days_in_month(y, m):
        return _err("day value is outside expected range")
    var i = 10
    if i >= n:
        return _okp()
    var sep = bof(s, i)
    if sep == 84 or sep == 116 or sep == 32 or sep == 95:  # T t space _
        i += 1
    else:
        return _err("unexpected extra characters at the end of the input")
    if i >= n:
        return _err("input is too short")
    var h = _digits2(s, i)
    if h < 0:
        return _err("invalid character in hour")
    i += 2
    if h > 23:
        return _err("unexpected extra characters at the end of the input")
    if i >= n:
        return _err("unexpected extra characters at the end of the input")
    if bof(s, i) != 58:  # ':'
        return _err("invalid character in hour")
    i += 1
    if i + 2 > n:
        return _err("input is too short")
    var mi = _digits2(s, i)
    if mi < 0:
        return _err("invalid character in minute")
    i += 2
    if mi > 59:
        return _err("unexpected extra characters at the end of the input")
    var se = 0
    var micro = 0
    if i < n and bof(s, i) == 58:  # ':'
        i += 1
        if i + 2 > n:
            return _err("invalid character in second")
        se = _digits2(s, i)
        if se < 0:
            return _err("invalid character in second")
        i += 2
        if se > 59:
            return _err("unexpected extra characters at the end of the input")
        if i < n and bof(s, i) == 46:  # '.'
            i += 1
            var cnt = 0
            while i < n and _d(bof(s, i)):
                if cnt < 6:
                    micro = micro * 10 + (bof(s, i) - 48)
                cnt += 1
                i += 1
            if cnt == 0:
                return _err("second fraction digits missing after `.`")
            while cnt < 6:
                micro *= 10
                cnt += 1
    if i < n:
        var c = bof(s, i)
        if c == 90 or c == 122:  # Z z
            i += 1
        elif c == 43 or c == 45:  # + -
            i += 1
            if _digits2(s, i) < 0:
                return _err("unexpected extra characters at the end of the input")
            i += 2
            if i < n and bof(s, i) == 58:
                i += 1
            if _digits2(s, i) < 0:
                return _err("unexpected extra characters at the end of the input")
            i += 2
        else:
            return _err("unexpected extra characters at the end of the input")
    if i != n:
        return _err("unexpected extra characters at the end of the input")
    var r = DtParse()
    r.ok = True
    r.exact = h == 0 and mi == 0 and se == 0 and micro == 0
    return r^


# ---------- date ----------

def parse_date(s: String) -> DtParse:
    """date 类型: 纯 YYYY-MM-DD (year 0 特判) 或 datetime 全零时刻."""
    var n = s.byte_length()
    if n == 10 and bof(s, 4) == 45 and bof(s, 7) == 45:
        if not (_d(bof(s, 0)) and _d(bof(s, 1)) and _d(bof(s, 2))
                and _d(bof(s, 3)) and _d(bof(s, 5)) and _d(bof(s, 6))
                and _d(bof(s, 8)) and _d(bof(s, 9))):
            return _err("input is too short")
        var m = _digits2(s, 5)
        var d = _digits2(s, 8)
        var y = _year4(s)
        if y == 0:
            return _err("year 0 is out of range")
        if m < 1 or m > 12:
            return _err("month value is outside expected range of 1-12")
        if d < 1 or d > days_in_month(y, m):
            return _err("day value is outside expected range")
        return _okp()
    var dt = parse_datetime(s)
    if not dt.ok:
        return dt^
    if not dt.exact:
        return _err("__inexact__")
    return _okp()
