# src/fastapi_mojo/json_canon.mojo
#
# 决策-88 (ADR-0063): body 422 detail `input` 的 CPython/Starlette 反序列化-重序列化
# 规范化 (叶模块; 仅依赖 float_repr)。
#
# 上游 FastAPI 用 Starlette JSONResponse, 其 `json.dumps(..., ensure_ascii=False,
# separators=(",", ":"), allow_nan=False)` 把 pydantic error 的 `input` (已反序列化
# 的 Python 对象) **重新序列化**: 去空白 / 数字规范化 (`1.50`->`1.5`, `1e2`->`100.0`,
# `-0`->`0`) / 字符串解码重编码 (`"\u0041"`->`"A"`, `"caf\u00e9"`->`"café"`,
# `\/`->`/`)。本实现此前回显**原始 JSON span** (形态差异, 语义一致)。
#
# `canon_json(span)`: 输入必须是合法 JSON 值 span; 输出等价 Starlette json.dumps
# 紧凑串。任何解析失败 / 非有限 float (上游 allow_nan=False -> 500, 另立偏差) /
# 孤立代理 -> 原样返回 span (安全回退, 不破坏 detail JSON 合法性)。
#
# 依赖方向: {body_constraints, body_validate} -> json_canon -> float_repr (叶, 无环)。

from float_repr import atof_f64, fmt_f64_repr


def _hex2(v: Int) -> String:
    var hx = "0123456789abcdef"
    return String(hx[byte=(v >> 4) & 15:(v >> 4) & 15 + 1]) + \
        String(hx[byte=v & 15:v & 15 + 1])


def _cpython_escape(v: String) -> String:
    """CPython `json.dumps(ensure_ascii=False)` 字符串转义 (`\\b`/`\\f` 短转义)。"""
    var out = String("")
    var n = v.byte_length()
    var ab = v.as_bytes()
    var i = 0
    while i < n:
        var b = Int(ab[i])
        if b >= 0x80:
            var blen = 2
            if b >= 0xF0:
                blen = 4
            elif b >= 0xE0:
                blen = 3
            if i + blen > n:
                blen = n - i
            out += String(v[byte=i:i + blen])
            i += blen
            continue
        if b == 34:
            out += "\\\""
        elif b == 92:
            out += "\\\\"
        elif b == 8:
            out += "\\b"
        elif b == 12:
            out += "\\f"
        elif b == 10:
            out += "\\n"
        elif b == 13:
            out += "\\r"
        elif b == 9:
            out += "\\t"
        elif b < 0x20:
            out += "\\u00" + _hex2(b)
        else:
            out += chr(b)
        i += 1
    return out^


struct _Canon:
    """单遍递归下降: 校验 + 重序列化 (bad=True -> 调用方回退原 span)。"""
    var s: String
    var n: Int
    var pos: Int
    var bad: Bool

    def __init__(out self, s: String):
        self.s = s
        self.n = s.byte_length()
        self.pos = 0
        self.bad = False

    def _b(self, i: Int) -> Int:
        return Int(self.s.as_bytes()[i])

    def _ws(mut self):
        while self.pos < self.n:
            var b = self._b(self.pos)
            if b == 32 or b == 9 or b == 10 or b == 13:
                self.pos += 1
            else:
                break

    def _string(mut self) -> String:
        """解析 JSON 字符串字面量 (pos 在 `"`) -> 重编码串 (带引号); 失败 bad。"""
        var decoded = String("")
        self.pos += 1
        while self.pos < self.n:
            var b = self._b(self.pos)
            if b == 34:
                self.pos += 1
                return "\"" + _cpython_escape(decoded) + "\""
            if b == 92:
                self.pos += 1
                if self.pos >= self.n:
                    self.bad = True
                    return ""
                var e = self._b(self.pos)
                if e == 34:
                    decoded += "\""
                elif e == 92:
                    decoded += "\\"
                elif e == 47:
                    decoded += "/"
                elif e == 98:
                    decoded += chr(8)
                elif e == 102:
                    decoded += chr(12)
                elif e == 110:
                    decoded += chr(10)
                elif e == 114:
                    decoded += chr(13)
                elif e == 116:
                    decoded += chr(9)
                elif e == 117:
                    var cp = self._hex4(self.pos + 1)
                    if cp < 0:
                        self.bad = True
                        return ""
                    self.pos += 4
                    if cp >= 0xD800 and cp <= 0xDBFF:
                        # high surrogate: 需要 \uDC00-\uDFFF
                        if self.pos + 1 < self.n and self._b(self.pos + 1) == 92 \
                                and self._b(self.pos + 2) == 117:
                            var lo = self._hex4(self.pos + 3)
                            if lo >= 0xDC00 and lo <= 0xDFFF:
                                var comb = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                                decoded += chr(comb)
                                self.pos += 6
                            else:
                                self.bad = True
                                return ""
                        else:
                            self.bad = True
                            return ""
                    elif cp >= 0xDC00 and cp <= 0xDFFF:
                        self.bad = True
                        return ""
                    else:
                        decoded += chr(cp)
                else:
                    self.bad = True
                    return ""
                self.pos += 1
                continue
            elif b < 0x20:
                self.bad = True
                return ""
            elif b >= 0x80:
                var blen = 2
                if b >= 0xF0:
                    blen = 4
                elif b >= 0xE0:
                    blen = 3
                if self.pos + blen > self.n:
                    self.bad = True
                    return ""
                decoded += String(self.s[byte=self.pos:self.pos + blen])
                self.pos += blen
                continue
            else:
                decoded += chr(b)
            self.pos += 1
        self.bad = True
        return ""

    def _hex4(mut self, start: Int) -> Int:
        if start + 3 >= self.n:
            return -1
        var v = 0
        for k in range(4):
            var b = self._b(start + k)
            var d = -1
            if b >= 48 and b <= 57:
                d = b - 48
            elif b >= 97 and b <= 102:
                d = b - 87
            elif b >= 65 and b <= 70:
                d = b - 55
            if d < 0:
                return -1
            v = v * 16 + d
        return v

    def _number(mut self) -> String:
        var start = self.pos
        if self.pos < self.n and self._b(self.pos) == 45:
            self.pos += 1
        while self.pos < self.n:
            var b = self._b(self.pos)
            if b >= 48 and b <= 57:
                self.pos += 1
            else:
                break
        var is_float = False
        if self.pos < self.n and self._b(self.pos) == 46:
            is_float = True
            self.pos += 1
            while self.pos < self.n and self._b(self.pos) >= 48 and self._b(self.pos) <= 57:
                self.pos += 1
        if self.pos < self.n and (self._b(self.pos) == 101 or self._b(self.pos) == 69):
            is_float = True
            self.pos += 1
            if self.pos < self.n and (self._b(self.pos) == 43 or self._b(self.pos) == 45):
                self.pos += 1
            while self.pos < self.n and self._b(self.pos) >= 48 and self._b(self.pos) <= 57:
                self.pos += 1
        var tok = String(self.s[byte=start:self.pos])
        if is_float:
            var f = atof_f64(tok)
            var r = fmt_f64_repr(f)
            if r == "inf" or r == "-inf" or r == "nan":
                # 非有限: 上游 json.dumps allow_nan=False -> 500 (另立偏差); 回退原串.
                self.bad = True
                return ""
            return r
        # 整数: Python int -> str (`-0` -> `0`)
        var neg = tok.byte_length() > 0 and Int(tok.as_bytes()[0]) == 45
        var body = tok if not neg else String(tok[byte=1:tok.byte_length()])
        var z = 0
        while z < body.byte_length() and Int(body.as_bytes()[z]) == 48:
            z += 1
        if z == body.byte_length():
            return "0"
        var out = String(body[byte=z:body.byte_length()])
        return ("-" + out) if neg else out

    def _literal(mut self, lit: String) -> String:
        if self.pos + lit.byte_length() > self.n:
            self.bad = True
            return ""
        if String(self.s[byte=self.pos:self.pos + lit.byte_length()]) == lit:
            self.pos += lit.byte_length()
            return lit
        self.bad = True
        return ""

    def _value(mut self) -> String:
        self._ws()
        if self.pos >= self.n:
            self.bad = True
            return ""
        var b = self._b(self.pos)
        if b == 34:
            return self._string()
        if b == 123:
            return self._object()
        if b == 91:
            return self._array()
        if b == 116:
            return self._literal("true")
        if b == 102:
            return self._literal("false")
        if b == 110:
            return self._literal("null")
        if b == 45 or (b >= 48 and b <= 57):
            return self._number()
        self.bad = True
        return ""

    def _object(mut self) -> String:
        self.pos += 1
        var keys = List[String]()
        var vals = List[String]()
        self._ws()
        if self.pos < self.n and self._b(self.pos) == 125:
            self.pos += 1
            return "{}"
        while True:
            self._ws()
            if self.pos >= self.n or self._b(self.pos) != 34:
                self.bad = True
                return ""
            var ks = self._string()
            if self.bad:
                return ""
            self._ws()
            if self.pos >= self.n or self._b(self.pos) != 58:
                self.bad = True
                return ""
            self.pos += 1
            var vs = self._value()
            if self.bad:
                return ""
            # CPython dict: 重复键后者胜 (覆盖原位置的值)
            var found = -1
            for k in range(len(keys)):
                if keys[k] == ks:
                    found = k
                    break
            if found >= 0:
                vals[found] = vs
            else:
                keys.append(ks)
                vals.append(vs)
            self._ws()
            if self.pos >= self.n:
                self.bad = True
                return ""
            var c = self._b(self.pos)
            if c == 44:
                self.pos += 1
                continue
            if c == 125:
                self.pos += 1
                var out = "{"
                for k in range(len(keys)):
                    if k > 0:
                        out += ","
                    out += keys[k] + ":" + vals[k]
                return out + "}"
            self.bad = True
            return ""

    def _array(mut self) -> String:
        self.pos += 1
        var out = "["
        var first = True
        self._ws()
        if self.pos < self.n and self._b(self.pos) == 93:
            self.pos += 1
            return "[]"
        while True:
            var vs = self._value()
            if self.bad:
                return ""
            if not first:
                out += ","
            first = False
            out += vs
            self._ws()
            if self.pos >= self.n:
                self.bad = True
                return ""
            var c = self._b(self.pos)
            if c == 44:
                self.pos += 1
                continue
            if c == 93:
                self.pos += 1
                return out + "]"
            self.bad = True
            return ""


def json_string_literal(v: String) -> String:
    """已解码字符串 -> CPython `json.dumps(..., ensure_ascii=False)` 串字面量。"""
    return "\"" + _cpython_escape(v) + "\""


def canon_json(span: String) -> String:
    """合法 JSON 值 span -> Starlette `json.dumps(ensure_ascii=False,
    separators=(",",":"))` 紧凑等价串; 失败 -> 原样返回 (安全回退)。"""
    if span == "":
        return span
    var c = _Canon(span)
    var out = c._value()
    if c.bad:
        return span
    c._ws()
    if c.pos != c.n:
        return span
    return out^
