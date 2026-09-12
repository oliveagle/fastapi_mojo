# src/fastapi_mojo/body_json.mojo
#
# 决策-85 (ADR-0060): 请求 body 顶层 JSON 严格校验 + Content-Type 分派 —
# 对齐 CPython `json.loads` 的错误消息与位置 (FastAPI 请求体解析契约, 决定
# 422 `json_invalid` detail 的 `loc[1]`/`ctx.error`), 以及 upstream
# `strict_content_type` 默认语义 (仅 application/json 或 application/*+json
# 触发 JSON 解析; 否则 body 作为原始字符串)。
#
# 叶子模块 (零 import): 纯字节扫描, 全 `as_bytes()` 访问 (决策-84/ADR-0059
# 字节安全约束), 不依赖任何其它 Mojo 模块。
#
# 消费方: body_validate (JSON CT 时先严格校验 -> 合法 object 才进字段校验;
# 合法非 object -> model_attributes_type; 非法 -> json_invalid)。


def _is_hexd(b: Int) -> Int:
    """Hex digit value (0-15) or -1."""
    if b >= 48 and b <= 57:
        return b - 48
    if b >= 97 and b <= 102:
        return b - 87
    if b >= 65 and b <= 70:
        return b - 55
    return -1


def _is_ws_b(b: Int) -> Bool:
    return b == 32 or b == 9 or b == 10 or b == 13


struct JsonScan:
    """严格 JSON 顶层校验结果 (决策-85).

    ok=True:  top_kind ∈ {"object","array","string","number","bool","null"},
              [val_start, val_end) = 顶层值原始 span.
    ok=False: err_pos = 失败字节偏移, err_msg = CPython json 消息 (不含位置).
    """
    var ok: Bool
    var top_kind: String
    var val_start: Int
    var val_end: Int
    var err_pos: Int
    var err_msg: String

    def __init__(out self):
        self.ok = False
        self.top_kind = ""
        self.val_start = 0
        self.val_end = 0
        self.err_pos = 0
        self.err_msg = ""


struct _JScan:
    """CPython `json` 等价递归下降扫描器 (仅校验 + 记录首个错误位置)."""
    var s: String
    var n: Int
    var pos: Int
    var err: Bool
    var epos: Int
    var emsg: String

    def __init__(out self, s: String):
        self.s = s
        self.n = s.byte_length()
        self.pos = 0
        self.err = False
        self.epos = 0
        self.emsg = ""

    def _b(self, i: Int) -> Int:
        return Int(self.s.as_bytes()[i])

    def fail(mut self, pos: Int, msg: String):
        """记录首个错误 (后续 fail 不覆盖)."""
        if not self.err:
            self.err = True
            self.epos = pos
            self.emsg = msg

    def skip_ws(mut self):
        while self.pos < self.n and _is_ws_b(self._b(self.pos)):
            self.pos += 1

    def _match_at(self, i: Int, lit: String) -> Bool:
        var m = lit.byte_length()
        if i + m > self.n:
            return False
        var lb = lit.as_bytes()
        for k in range(m):
            if self._b(i + k) != Int(lb[k]):
                return False
        return True

    def scan_lit(mut self, lit: String) -> Bool:
        """true/false/null 精确匹配; 失败 -> Expecting value @ start."""
        if not self._match_at(self.pos, lit):
            self.fail(self.pos, "Expecting value")
            return False
        self.pos += lit.byte_length()
        return True

    def scan_string(mut self) -> Bool:
        """自 `"` 起扫描字符串; 复刻 CPython 消息/位置."""
        var start = self.pos
        self.pos += 1
        while self.pos < self.n:
            var c = self._b(self.pos)
            if c == 34:  # '"'
                self.pos += 1
                return True
            if c == 92:  # '\'
                var ep = self.pos
                self.pos += 1
                if self.pos >= self.n:
                    break
                var e = self._b(self.pos)
                if e == 34 or e == 92 or e == 47 or e == 98 or e == 102 \
                        or e == 110 or e == 114 or e == 116:
                    self.pos += 1
                elif e == 117:  # 'u'
                    var up = self.pos
                    self.pos += 1
                    var k = 0
                    while k < 4:
                        if self.pos >= self.n or _is_hexd(self._b(self.pos)) < 0:
                            self.fail(up, "Invalid \\uXXXX escape")
                            return False
                        self.pos += 1
                        k += 1
                else:
                    self.fail(ep, "Invalid \\escape")
                    return False
                continue
            if c < 32:
                self.fail(self.pos, "Invalid control character at")
                return False
            self.pos += 1
        self.fail(start, "Unterminated string starting at")
        return False

    def scan_number(mut self) -> Bool:
        """JSON number 文法 + CPython allow_nan 常量 (NaN/Infinity/-Infinity)."""
        var start = self.pos
        if self._match_at(start, "NaN"):
            self.pos = start + 3
            return True
        if self._match_at(start, "Infinity"):
            self.pos = start + 8
            return True
        var p = start
        if self._b(p) == 45:  # '-'
            p += 1
        if self._match_at(p, "Infinity"):
            self.pos = p + 8
            return True
        if p >= self.n:
            self.fail(start, "Expecting value")
            return False
        var c = self._b(p)
        if c == 48:  # '0'
            p += 1
        elif c >= 49 and c <= 57:
            while p < self.n and self._b(p) >= 48 and self._b(p) <= 57:
                p += 1
        else:
            self.fail(start, "Expecting value")
            return False
        # 小数部分: '.' + 至少一位数字 (否则 '.' 留给容器报分隔符错)
        if p + 1 < self.n and self._b(p) == 46 \
                and self._b(p + 1) >= 48 and self._b(p + 1) <= 57:
            p += 1
            while p < self.n and self._b(p) >= 48 and self._b(p) <= 57:
                p += 1
        # 指数部分: [eE][+-]?数字 (不完整则整体不匹配, 留给容器)
        if p < self.n and (self._b(p) == 101 or self._b(p) == 69):
            var q = p + 1
            if q < self.n and (self._b(q) == 43 or self._b(q) == 45):
                q += 1
            if q < self.n and self._b(q) >= 48 and self._b(q) <= 57:
                while q < self.n and self._b(q) >= 48 and self._b(q) <= 57:
                    q += 1
                p = q
        self.pos = p
        return True

    def scan_value(mut self) -> Bool:
        self.skip_ws()
        if self.pos >= self.n:
            self.fail(self.n, "Expecting value")
            return False
        var c = self._b(self.pos)
        if c == 123:  # '{'
            return self.scan_object()
        if c == 91:  # '['
            return self.scan_array()
        if c == 34:  # '"'
            return self.scan_string()
        if c == 116:  # 't'
            return self.scan_lit("true")
        if c == 102:  # 'f'
            return self.scan_lit("false")
        if c == 110:  # 'n'
            return self.scan_lit("null")
        if c == 45 or (c >= 48 and c <= 57) or c == 78 or c == 73:
            return self.scan_number()
        self.fail(self.pos, "Expecting value")
        return False

    def scan_object(mut self) -> Bool:
        self.pos += 1  # '{'
        self.skip_ws()
        if self.pos < self.n and self._b(self.pos) == 125:  # '}'
            self.pos += 1
            return True
        while True:
            self.skip_ws()
            if self.pos >= self.n or self._b(self.pos) != 34:
                self.fail(self.pos,
                          "Expecting property name enclosed in double quotes")
                return False
            if not self.scan_string():
                return False
            self.skip_ws()
            if self.pos >= self.n or self._b(self.pos) != 58:  # ':'
                self.fail(self.pos, "Expecting ':' delimiter")
                return False
            self.pos += 1
            if not self.scan_value():
                return False
            self.skip_ws()
            if self.pos >= self.n:
                self.fail(self.pos, "Expecting ',' delimiter")
                return False
            var c = self._b(self.pos)
            if c == 44:  # ','
                self.pos += 1
                continue
            if c == 125:  # '}'
                self.pos += 1
                return True
            self.fail(self.pos, "Expecting ',' delimiter")
            return False

    def scan_array(mut self) -> Bool:
        self.pos += 1  # '['
        self.skip_ws()
        if self.pos < self.n and self._b(self.pos) == 93:  # ']'
            self.pos += 1
            return True
        while True:
            if not self.scan_value():
                return False
            self.skip_ws()
            if self.pos >= self.n:
                self.fail(self.pos, "Expecting ',' delimiter")
                return False
            var c = self._b(self.pos)
            if c == 44:  # ','
                self.pos += 1
                continue
            if c == 93:  # ']'
                self.pos += 1
                return True
            self.fail(self.pos, "Expecting ',' delimiter")
            return False


def validate_body_json(body: String) -> JsonScan:
    """严格校验 body 是否为单个合法 JSON 值 (可带首尾空白).

    返回 ok/顶层 kind/顶层值 span, 或首个错误的 (pos, CPython 消息)."""
    var r = JsonScan()
    var sc = _JScan(body)
    sc.skip_ws()
    if sc.pos >= sc.n:
        r.err_pos = sc.n
        r.err_msg = "Expecting value"
        return r^
    var start = sc.pos
    var c = sc._b(sc.pos)
    var kind: String
    if c == 123:
        kind = "object"
        _ = sc.scan_object()
    elif c == 91:
        kind = "array"
        _ = sc.scan_array()
    elif c == 34:
        kind = "string"
        _ = sc.scan_string()
    elif c == 116 or c == 102:
        kind = "bool"
        _ = sc.scan_lit("true" if c == 116 else "false")
    elif c == 110:
        kind = "null"
        _ = sc.scan_lit("null")
    elif c == 45 or (c >= 48 and c <= 57) or c == 78 or c == 73:
        kind = "number"
        _ = sc.scan_number()
    else:
        r.err_pos = sc.pos
        r.err_msg = "Expecting value"
        return r^
    if sc.err:
        r.err_pos = sc.epos
        r.err_msg = sc.emsg
        return r^
    var vend = sc.pos
    sc.skip_ws()
    if sc.pos < sc.n:
        r.err_pos = sc.pos
        r.err_msg = "Extra data"
        return r^
    r.ok = True
    r.top_kind = kind
    r.val_start = start
    r.val_end = vend
    return r^


def _eq_ci(s: String, a: Int, b: Int, lit: String) -> Bool:
    """s[a:b] == lit (ASCII 大小写不敏感)."""
    if b - a != lit.byte_length():
        return False
    var ab = s.as_bytes()
    var lb = lit.as_bytes()
    for k in range(lit.byte_length()):
        var x = Int(ab[a + k])
        var y = Int(lb[k])
        if x >= 65 and x <= 90:
            x += 32
        if y >= 65 and y <= 90:
            y += 32
        if x != y:
            return False
    return True


def _has_suffix_ci(s: String, lo: Int, hi: Int, suffix: String) -> Bool:
    var m = suffix.byte_length()
    if hi - lo < m:
        return False
    return _eq_ci(s, hi - m, hi, suffix)


def content_type_is_json(ct: String) -> Bool:
    """决策-85: upstream `strict_content_type=True` 默认 JSON 判定 —
    `application/json` 或 `application/*+json` (大小写不敏感, 忽略 `;` 后参数)."""
    var n = ct.byte_length()
    var ab = ct.as_bytes()
    var semi = n
    var i = 0
    while i < n:
        if Int(ab[i]) == 59:  # ';'
            semi = i
            break
        i += 1
    var a = 0
    var b = semi
    while a < b and _is_ws_b(Int(ab[a])):
        a += 1
    while b > a and _is_ws_b(Int(ab[b - 1])):
        b -= 1
    var slash = -1
    var k = a
    while k < b:
        if Int(ab[k]) == 47:  # '/'
            slash = k
            break
        k += 1
    if slash < 0:
        return False
    if not _eq_ci(ct, a, slash, "application"):
        return False
    if _eq_ci(ct, slash + 1, b, "json"):
        return True
    return _has_suffix_ci(ct, slash + 1, b, "+json")
