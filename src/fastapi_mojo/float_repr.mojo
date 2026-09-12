# src/fastapi_mojo/float_repr.mojo
#
# 决策-87 (ADR-0062): 正确舍入的 float <-> 十进制字符串原语 (纯 Mojo + libc).
#
#   - atof_f64: 十进制 -> Float64 (libc atof / strtod(nptr, NULL), 正确舍入
#     round-to-nearest-even)。Mojo 1.0.0 `Float64(String)` 内部按 int64 累加整数
#     部分 -> 对 >~20 位有效数字/长整数部分的字面量失败 (抛错), 把 float64 范围
#     内合法十进制 (如 12345678901234567890.0) 误判为非法。
#
#   - fmt_f64_repr: Float64 -> 十进制字符串, 语义等价 CPython `repr(float)`:
#     最短往返位数 + Python 记法 (decpt<=-4 || decpt>16 用科学记数; 其余定点,
#     整值补 ".0")。Mojo 1.0.0 `String(Float64)` 偶发**非最短且不往返**
#     (实测 String(7.531168259201221e+16) = "7.53116825920122e+16", 回读不等)。
#
# 依赖: 仅 libc (atof / strfromd) —— North Star 允许的基础运行时; 零新 crate /
# 零 Rust / 零新 FFI 符号 (均为既有 libc 符号)。
# 依赖方向: {numlit, body_schema} -> float_repr (叶, 单向无环)。

from std.ffi import external_call


def atof_f64(s: String) -> Float64:
    """正确舍入的十进制 -> Float64 (libc atof, 即 strtod(nptr, NULL)).

    `s` 必须已过文法校验 (非法串 -> 0.0; 调用方先行判定)。"""
    var cs = s
    return external_call["atof", Float64](cs.as_c_string_slice())


def _sfmt_e(v: Float64, sig: Int) -> String:
    """libc strfromd "%.{sig-1}e" -> 科学记数串 (sig 位有效数字, 正确舍入)."""
    var buf = List[UInt8]()
    buf.resize(64, UInt8(0))
    var fmt = "%." + String(sig - 1) + "e"
    var n = external_call["strfromd", Int](
        buf.unsafe_ptr(), Int64(64), fmt.as_c_string_slice(), v)
    var out = String("")
    for i in range(n):
        if buf[i] == 0:
            break
        out += chr(Int(buf[i]))
    return out^


def _parse_exp(s: String) -> Int:
    """解析 "e" 之后的指数串 ("+16" / "-05") -> Int."""
    var i = 0
    var neg = False
    if s.byte_length() > 0 and (Int(s.as_bytes()[0]) == 43 or Int(s.as_bytes()[0]) == 45):
        neg = Int(s.as_bytes()[0]) == 45
        i = 1
    var v = 0
    var n = s.byte_length()
    while i < n:
        var c = Int(s.as_bytes()[i])
        if c >= 48 and c <= 57:
            v = v * 10 + (c - 48)
        i += 1
    return -v if neg else v


def fmt_f64_repr(v: Float64) -> String:
    """CPython `repr(float)` 等价 (最短往返 + Python 记法阈值)."""
    var p1 = _sfmt_e(v, 1)
    if p1 == "nan":
        return "nan"
    if p1 == "inf":
        return "inf"
    if p1 == "-inf":
        return "-inf"
    var neg = Int(p1.as_bytes()[0]) == 45
    var a = -v if neg else v
    if a == 0.0:
        return "-0.0" if neg else "0.0"
    # 最短往返位数: p=1..17 首个 atof 回读等于 a 的
    var chosen = ""
    for p in range(1, 18):
        var s = _sfmt_e(a, p)
        if atof_f64(s) == a:
            chosen = s
            break
    if chosen == "":
        chosen = _sfmt_e(a, 17)
    # 拆 "D.DDDDe±XX"
    var ei = 0
    var n = chosen.byte_length()
    for i in range(n):
        if Int(chosen.as_bytes()[i]) == 101:
            ei = i
            break
    var mant = String(chosen[byte=0:ei])
    var exp = _parse_exp(String(chosen[byte=ei + 1:n]))
    # digits = 去掉 '.' ; 去尾零 (最小 p 通常无尾零, 兜底)
    var digits = String("")
    for i in range(mant.byte_length()):
        if Int(mant.as_bytes()[i]) != 46:
            digits += String(mant[byte=i:i + 1])
    var dlen = digits.byte_length()
    while dlen > 1 and Int(digits.as_bytes()[dlen - 1]) == 48:
        dlen -= 1
    var ds = String(digits[byte=0:dlen])
    var decpt = exp + 1
    var out: String
    if decpt <= -4 or decpt > 16:
        if ds.byte_length() == 1:
            out = ds
        else:
            out = String(ds[byte=0:1]) + "." + String(ds[byte=1:ds.byte_length()])
        var e2 = decpt - 1
        var eabs = e2 if e2 >= 0 else -e2
        var etxt = String(eabs)
        if eabs < 10:
            etxt = "0" + etxt
        out = out + "e" + ("+" if e2 >= 0 else "-") + etxt
    else:
        if decpt <= 0:
            var z = String("")
            var k = 0
            while k < -decpt:
                z += "0"
                k += 1
            out = "0." + z + ds
        elif decpt >= ds.byte_length():
            var z = String("")
            var k = decpt - ds.byte_length()
            while k > 0:
                z += "0"
                k -= 1
            out = ds + z + ".0"
        else:
            out = String(ds[byte=0:decpt]) + "." + String(ds[byte=decpt:ds.byte_length()])
    return ("-" + out) if neg else out


def is_dec_f64_syntax(s: String) -> Bool:
    """True iff `s` 是合法的十进制 float 字面量文法 (strtod 接受面, 无尾随垃圾).

    文法: [+-]? ( digits ('.' digits*)? | '.' digits+ ) ([eE][+-]? digits+)?
    另接受 inf/infinity/nan (大小写不敏感, 可带符号)。用于 *替代* Mojo
    `Float64(String)` 的合法性判定 (后者对 >~20 位有效数字误判非法, 且对
    "1.2.3" 等尾随垃圾误判合法) —— 调用方据此给出 float_parsing。"""
    var n = s.byte_length()
    if n == 0:
        return False
    var i = 0
    if Int(s.as_bytes()[0]) == 43 or Int(s.as_bytes()[0]) == 45:
        i = 1
    if i >= n:
        return False
    # inf / infinity / nan 家族 (大小写不敏感)
    var lower = String("")
    for k in range(i, n):
        var c = Int(s.as_bytes()[k])
        if c >= 65 and c <= 90:
            lower += chr(c + 32)
        else:
            lower += chr(c)
    if lower == "inf" or lower == "infinity" or lower == "nan":
        return True
    var seen_int = False
    var seen_frac = False
    var seen_dot = False
    while i < n:
        var c = Int(s.as_bytes()[i])
        if c >= 48 and c <= 57:
            if seen_dot:
                seen_frac = True
            else:
                seen_int = True
            i += 1
        elif c == 46 and not seen_dot:
            seen_dot = True
            i += 1
        else:
            break
    if not seen_int and not seen_frac:
        return False
    if i == n:
        return True
    # 指数部分
    var e0 = Int(s.as_bytes()[i])
    if e0 != 101 and e0 != 69:
        return False
    i += 1
    if i < n and (Int(s.as_bytes()[i]) == 43 or Int(s.as_bytes()[i]) == 45):
        i += 1
    if i >= n:
        return False
    while i < n:
        var c2 = Int(s.as_bytes()[i])
        if c2 < 48 or c2 > 57:
            return False
        i += 1
    return True
