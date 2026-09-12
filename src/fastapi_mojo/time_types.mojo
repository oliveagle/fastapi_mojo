# src/fastapi_mojo/time_types.mojo
#
# 决策-79 (ADR-0054): time / timedelta 标量解析原语 (自 date_types 拆出,
# 500 行阈值)。依赖: time_types -> date_types (DtParse + 数字/错误 helpers)。
# 覆盖边界同 ADR-0054 §3.5。

from date_types import DtParse, bof, _d, _okp, _err, _digits2, _starts, _lower


# ---------- time ----------

def parse_time(s: String) -> DtParse:
    """time 类型 (HH:MM[:SS[.frac]][tz])."""
    var n = s.byte_length()
    if n < 3:
        return _err("input is too short")
    var h = _digits2(s, 0)
    if h < 0:
        return _err("invalid character in hour")
    if h > 23:
        return _err("hour value is outside expected range of 0-23")
    var i = 2
    if i >= n or bof(s, i) != 58:  # ':'
        return _err("input is too short")
    i += 1
    if i + 2 > n:
        return _err("input is too short")
    var mi = _digits2(s, i)
    if mi < 0:
        return _err("invalid character in minute")
    if mi > 59:
        return _err("minute value is outside expected range of 0-59")
    i += 2
    if i < n and bof(s, i) == 58:  # ':'
        i += 1
        if i + 2 > n:
            return _err("invalid character in second")
        var se = _digits2(s, i)
        if se < 0:
            return _err("invalid character in second")
        if se > 59:
            return _err("second value is outside expected range of 0-59")
        i += 2
        if i < n and bof(s, i) == 46:  # '.'
            i += 1
            var cnt = 0
            while i < n and _d(bof(s, i)):
                cnt += 1
                i += 1
            if cnt == 0:
                return _err("second fraction digits missing after `.`")
    if i < n:
        var c = bof(s, i)
        if c == 90 or c == 122:  # Z z
            i += 1
        elif c == 43 or c == 45:  # + -
            i += 1
            if _digits2(s, i) < 0:
                return _err("invalid timezone hour")
            i += 2
            if i < n and bof(s, i) == 58:
                i += 1
            if _digits2(s, i) < 0:
                return _err("invalid timezone minute")
            i += 2
        else:
            return _err("input is too short")
    if i != n:
        return _err("input is too short")
    return _okp()


# ---------- timedelta ----------

def _td_hms(s: String, i0: Int, after_day: Bool) -> DtParse:
    """[H]H:MM:SS[.frac] 片段 (i0 起点, 必须消费到串尾)."""
    var n = s.byte_length()
    var i = i0
    var h = 0
    var hcnt = 0
    while i < n and _d(bof(s, i)):
        h = h * 10 + (bof(s, i) - 48)
        hcnt += 1
        i += 1
    if hcnt == 0:
        return _err("invalid character in hour")
    if after_day:
        if h > 23:
            return _err("durations may not exceed 999,999,999 hours")
    elif h > 999999999:
        return _err("durations may not exceed 999,999,999 hours")
    if i >= n:
        return _err("input is too short")
    if bof(s, i) != 58:
        return _err("invalid character in hour")
    i += 1
    if _digits2(s, i) < 0:
        return _err("invalid character in minute")
    i += 2
    if i >= n:
        return _err("input is too short")
    if bof(s, i) != 58:
        return _err("invalid character in second")
    i += 1
    if _digits2(s, i) < 0:
        return _err("invalid character in second")
    i += 2
    if i < n and bof(s, i) == 46:
        i += 1
        var cnt = 0
        while i < n and _d(bof(s, i)):
            cnt += 1
            i += 1
        if cnt == 0:
            return _err("second fraction digits missing after `.`")
    if i != n:
        return _err("unexpected extra characters at the end of the input")
    return _okp()


def _td_iso(s: String, i0: Int) -> DtParse:
    var n = s.byte_length()
    var tpos = -1
    for k in range(i0, n):
        var c = bof(s, k)
        if c == 84 or c == 116:
            tpos = k
            break
    var dend = n if tpos < 0 else tpos
    var has_date = dend > i0
    if not has_date and tpos < 0:
        return _err("input is too short")
    var days = 0
    var i = i0
    while i < dend:
        if not _d(bof(s, i)):
            return _err("invalid digit in duration")
        var num = 0
        while i < dend and _d(bof(s, i)):
            num = num * 10 + (bof(s, i) - 48)
            i += 1
        if i >= dend:
            return _err("invalid digit in duration")
        var u = bof(s, i)
        i += 1
        if u == 89 or u == 121:      # Y y
            days += num * 365
        elif u == 77 or u == 109:    # M m
            days += num * 30
        elif u == 87 or u == 119:    # W w
            days += num * 7
        elif u == 68 or u == 100:    # D d
            days += num
        else:
            return _err("quantity invalid in date part of duration")
    if days > 999999999:
        return _err("durations may not exceed 999,999,999 days")
    if tpos < 0:
        return _okp()
    var j = tpos + 1
    if j >= n:
        if has_date:
            return _okp()
        return _err("input is too short")
    var hours = 0
    while j < n:
        if not _d(bof(s, j)):
            return _err("invalid digit in duration")
        var num2 = 0
        while j < n and _d(bof(s, j)):
            num2 = num2 * 10 + (bof(s, j) - 48)
            j += 1
        if j >= n:
            return _err("invalid digit in duration")
        var u2 = bof(s, j)
        j += 1
        if u2 == 72 or u2 == 104:    # H h
            hours += num2
        elif u2 == 77 or u2 == 109:  # M m
            _ = num2
        elif u2 == 83 or u2 == 115:  # S s
            _ = num2
        else:
            return _err("invalid digit in duration")
    if hours > 999999999:
        return _err("durations may not exceed 999,999,999 hours")
    return _okp()


def parse_timedelta(s: String) -> DtParse:
    """timedelta 类型: ISO-8601 duration 或 `[N day[s]][, H:MM:SS]` / `H:MM:SS`."""
    var n = s.byte_length()
    if n == 0:
        return _err("input is too short")
    var i = 0
    if bof(s, 0) == 45 or bof(s, 0) == 43:  # - +
        i = 1
    if i < n and (bof(s, i) == 80 or bof(s, i) == 112):  # P p
        return _td_iso(s, i + 1)
    # human: 需要至少一位数字
    var has_digit = False
    for k in range(i, n):
        if _d(bof(s, k)):
            has_digit = True
            break
    if not has_digit:
        return _err("invalid digit in duration")
    # 前导数字 -> 可选 "day(s)" 单位
    var j = i
    while j < n and _d(bof(s, j)):
        j += 1
    if j == i:
        return _err("invalid character in hour")
    var k2 = j
    while k2 < n and bof(s, k2) == 32:
        k2 += 1
    var tail = _lower(String(s[byte=k2:n]))
    var is_day = _starts(tail, "days") or _starts(tail, "day")
    if is_day:
        var ynum = 0
        for q in range(i, j):
            ynum = ynum * 10 + (bof(s, q) - 48)
        if ynum > 999999999:
            return _err("durations may not exceed 999,999,999 days")
        var adv = 4 if _starts(tail, "days") else 3
        var r = k2 + adv
        while r < n and bof(s, r) == 32:
            r += 1
        if r < n and bof(s, r) == 44:  # ','
            r += 1
            while r < n and bof(s, r) == 32:
                r += 1
        if r >= n:
            return _okp()
        return _td_hms(s, r, True)
    # 非 day: 仅 digits/':' 且冒号 < 2 -> day 标识符格式错
    var simple = True
    var colons = 0
    for x in range(i, n):
        var c = bof(s, x)
        if c == 58:
            colons += 1
        elif not _d(c):
            simple = False
            break
    if simple and colons < 2:
        return _err("\"day\" identifier in duration not correctly formatted")
    return _td_hms(s, i, False)
