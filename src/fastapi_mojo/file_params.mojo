# src/fastapi_mojo/file_params.mojo
#
# 决策-46 (ADR-0021, Goal-0003 P2 矩阵 #6): UploadFile 对象 API —
# multipart 文件参数声明 / 422 校验 (上游 0.141.1 parity) / List[UploadFile] /
# 对象操作声明解析. **100% 纯 Mojo (零 FFI)** — mojo run JIT 自检可达
# (决策-38: JIT 链接不了 Rust bridge 符号; FFI 层在同目录 file_ops_ffi.mojo).
#
# 声明式 (handler.data, 决策-32/44/45 同模式):
#   - _multipart = "true" (既有, 决策-32: 全 part 注入; 无 422)
#   - _file_types = "doc:file;opt:file=;pics:file[];raw:bytes"
#       file  = UploadFile 等价: part 须有 filename; 文本 part -> 422 value_error
#       bytes = bytes 等价: 文本或文件 part 均接受 (U9 偏差)
#       "=" = 可选 (File(None)); "[]" = list
#   - _file_aliases = "name=alias;..." (wire key = alias, 决策-45 同语义)
#   - _file_ops = "name:op[:a1][:a2];..." (head/range/sha256/save; file_ops_ffi)
#   - _param_descs 共享 description 表 (OpenAPI)
#
# 值语义: 上游 0.141.1 + pydantic 2.13.5 + starlette 1.6.0 raw multipart
# 实测 U1-U9 (ADR-0021 §1): U1 size = 实际 raw 字节 (修复决策-32 b64
# 长度 BUG); U2 文本->file 422 value_error; U3 文件->form 422 string_type;
# U4 非 List last-wins / List 全 occurrence; U5 非 multipart CT 字段全缺失;
# U8 文本 part 供给 Form; U9 上游 List[bytes] 含文本 = 500 bug 接受.
#
# 分层: mp 解析 + ops FFI 在 Rust bridge / file_ops_ffi (ADR-0010);
# 本模块 = 快照数据结构 + 纯逻辑. Mojo 1.0.0 无 class — MpParts =
# 并行 List + 显式 copy() (ServerInfo 同模式).
# 依赖: file_params -> {handler, form_params, params_query_extra, json, string_builder}; openapi / http_server_final -> file_params (单向, 无反向).
from handler import Handler
from params_query_extra import parse_table, split_csv
from json import json_escape
from string_builder import decode_utf8_bytes, StringBuilder
from form_params import get_form_types, get_form_aliases

# ---------- 快照数据结构 ----------

struct MpParts:
    """multipart part 快照 (并行 List — 可复制, ServerInfo 同模式;
    各字段同长度, 下标 i 平行对应一个 part)."""
    var names: List[String]
    var filenames: List[String]
    var cts: List[String]
    var b64s: List[String]
    var raw_lens: List[Int]
    var idxs: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.filenames = List[String]()
        self.cts = List[String]()
        self.b64s = List[String]()
        self.raw_lens = List[Int]()
        self.idxs = List[Int]()

    def copy(self) -> MpParts:
        var p = MpParts()
        p.names = self.names.copy()
        p.filenames = self.filenames.copy()
        p.cts = self.cts.copy()
        p.b64s = self.b64s.copy()
        p.raw_lens = self.raw_lens.copy()
        p.idxs = self.idxs.copy()
        return p^

    def count(self) -> Int:
        return len(self.names)

    def is_file(self, i: Int) -> Bool:
        return self.filenames[i] != ""

# ---------- b64 (协议层归 Mojo, ADR-0010) ----------

def _b64_tbl_char(idx: Int) -> String:
    """b64 字母表单字符 (RFC 4648 标准表)."""
    var TBL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return String(TBL[byte=idx])


def _b64_encode(bytes: List[Int]) -> String:
    """标准 base64 (Rust b64_encode 镜像; 仅 ops head/range 区间用 —
    全量 body_b64 由 bridge 预编码, 零 FFI 成本)."""
    var sb = StringBuilder()
    var n = len(bytes)
    var i = 0
    while i + 2 < n:
        var t = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]
        sb.append(_b64_tbl_char((t >> 18) & 63))
        sb.append(_b64_tbl_char((t >> 12) & 63))
        sb.append(_b64_tbl_char((t >> 6) & 63))
        sb.append(_b64_tbl_char(t & 63))
        i += 3
    var rem = n - i
    if rem == 1:
        var t1 = bytes[i] << 16
        sb.append(_b64_tbl_char((t1 >> 18) & 63))
        sb.append(_b64_tbl_char((t1 >> 12) & 63))
        sb.append("=")
        sb.append("=")
    elif rem == 2:
        var t2 = (bytes[i] << 16) | (bytes[i + 1] << 8)
        sb.append(_b64_tbl_char((t2 >> 18) & 63))
        sb.append(_b64_tbl_char((t2 >> 12) & 63))
        sb.append(_b64_tbl_char((t2 >> 6) & 63))
        sb.append("=")
    return sb.take()


def _b64_decode_bytes(s: String) -> List[Int]:
    """标准 base64 -> raw 字节 (文本 part 值还原; 再 decode_utf8_bytes)."""
    var out = List[Int]()
    var val = 0
    var bits = 0
    var n = s.byte_length()
    for i in range(n):
        var c = ord(s[byte=i])
        if c == 61:
            break
        var v = -1
        if c >= 65 and c <= 90:
            v = c - 65
        elif c >= 97 and c <= 122:
            v = c - 71
        elif c >= 48 and c <= 57:
            v = c + 4
        elif c == 43:
            v = 62
        elif c == 47:
            v = 63
        if v < 0:
            continue
        val = (val << 6) | v
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append((val >> bits) & 255)
            val = val & ((1 << bits) - 1)
    return out^


def _part_text(parts: MpParts, i: Int) raises -> String:
    """文本 part 字符串值 (b64 -> bytes -> UTF-8)."""
    return decode_utf8_bytes(_b64_decode_bytes(parts.b64s[i]))
# ---------- 声明表 ----------

def get_file_types(handler: Handler) raises -> Dict[String, String]:
    """_file_types 声明表 (name:spec;..., 与 _form_types 同语法)."""
    if "_file_types" in handler.data:
        return parse_table(handler.data["_file_types"], 59, 58, True)
    return Dict[String, String]()


def get_file_aliases(handler: Handler) raises -> Dict[String, String]:
    """_file_aliases (name=alias;...; wire key = alias, 决策-45 同语义)."""
    if "_file_aliases" in handler.data:
        return parse_table(handler.data["_file_aliases"], 59, 61, False)
    return Dict[String, String]()


def file_has_declaration(handler: Handler) raises -> Bool:
    if "_file_types" in handler.data and handler.data["_file_types"] != "":
        return True
    if "_file_fields" in handler.data and handler.data["_file_fields"] != "":
        return True
    return False


def file_field_names_ordered(handler: Handler) raises -> List[String]:
    """_file_types ∪ _file_fields 声明序 (去重, types 在前; OpenAPI 字段序)."""
    var out = List[String]()
    if "_file_types" in handler.data:
        var raw = handler.data["_file_types"]
        var n = raw.byte_length()
        var start = 0
        var i = 0
        while i <= n:
            var is_sep = (i == n) or (ord(raw[byte=i]) == 59)  # ';'
            if is_sep:
                if i > start:
                    var piece = String(raw[byte=start:i])
                    var colon = -1
                    for j in range(piece.byte_length()):
                        if ord(piece[byte=j]) == 58:  # ':'
                            colon = j
                            break
                    if colon > 0:
                        var nm = String(piece[byte=0:colon])
                        if nm != "":
                            out.append(nm)
                start = i + 1
            i += 1
    if "_file_fields" in handler.data:
        for f in split_csv(handler.data["_file_fields"]):
            var seen = False
            for x in out:
                if x == f:
                    seen = True
                    break
            if not seen:
                out.append(f)
    return out^


def _parse_file_spec(spec: String) -> Tuple[String, Bool, Bool]:
    """(base, is_list, has_default). spec = "file"/"file="/"file[]"/
    "file[]="/"bytes"/"bytes="/"bytes[]". base 须 file|bytes (校验层判错)."""
    var n = spec.byte_length()
    var eq = -1
    var i = 0
    while i < n:
        if ord(spec[byte=i]) == 61:
            eq = i
            break
        i += 1
    var has_default = False
    var end = n
    if eq >= 0:
        has_default = True
        end = eq
    var is_list = False
    var base_end = end
    if end >= 2:
        if ord(spec[byte=end - 2]) == 91 and ord(spec[byte=end - 1]) == 93:  # "[]"
            is_list = True
            base_end = end - 2
    var base = String(spec[byte=0:base_end])
    return (base, is_list, has_default)

# ---------- 422 校验 (上游 0.141.1 parity: U2/U4/U5, collect-all) ----------

def _fe(loc: String, msg: String, type_name: String, input_json: String) -> String:
    """单个 file 422 错误对象 (字段序 loc,msg,type,input — ADR-0020
    §3.5-1 与 form 同约定; 字段集合/值对齐上游)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\",\"input\":" + input_json + "}"


def _uploadfile_value_err(loc: String, text_val: String) -> String:
    """U2: 文本 part 送 UploadFile 参数 (上游 0.141.1 完整措辞)."""
    return _fe(loc, "Value error, Expected UploadFile, received: <class 'str'>",
               "value_error", "\"" + json_escape(text_val) + "\"")


def validate_file_collect(type_spec: Dict[String, String],
                          aliases: Dict[String, String],
                          parts: MpParts) raises -> Tuple[Bool, List[String]]:
    """File 422 校验 (声明序, collect-all): 无 occurrence -> 必填
    missing ("Field required" F 大写 + input null) / 可选 (=) 通过;
    非 list last-wins (U4; base=file 且 last 是文本 part ->
    value_error; bytes 任意); list 逐 occurrence (base=file 文本
    occurrence -> value_error loc ["body",name,i]; bytes 全接受,
    U9 上游 500 bug). parts 空 (非 multipart / 解析失败) = 上游
    「字段全缺失」(U5)."""
    var errs = List[String]()
    if len(type_spec) == 0:
        return (True, errs^)
    for k in type_spec:
        var fs = _parse_file_spec(type_spec[k])
        var base = fs[0]
        var loc = "[\"body\",\"" + json_escape(k) + "\"]"
        if base != "file" and base != "bytes":
            errs.append(_fe(loc, "unknown type for parameter '" + k + "': " + base,
                            "unknown_type", "null"))
            continue
        var lookup = k
        if k in aliases:
            lookup = aliases[k]
        var occ = List[Int]()
        var pi = 0
        while pi < parts.count():
            if parts.names[pi] == lookup:
                occ.append(pi)
            pi += 1
        if len(occ) == 0:
            if not fs[2]:
                errs.append(_fe(loc, "Field required", "missing", "null"))
            continue
        if not fs[1]:
            var last = occ[len(occ) - 1]
            if base == "file" and not parts.is_file(last):
                errs.append(_uploadfile_value_err(loc, _part_text(parts, last)))
            continue
        var j = 0
        while j < len(occ):
            var pi2 = occ[j]
            if base == "file" and not parts.is_file(pi2):
                var eloc = "[\"body\",\"" + json_escape(k) + "\"," + String(j) + "]"
                errs.append(_uploadfile_value_err(eloc, _part_text(parts, pi2)))
            j += 1
    return (len(errs) == 0, errs^)


def _decl_of(wire: String, types: Dict[String, String],
             aliases: Dict[String, String]) raises -> String:
    """wire name -> declared name: declared name direct hit (return as-is)
    or alias reverse lookup (value == wire -> key); empty string if no hit.
    types = declared->spec, aliases = declared->wire (F8/F10 convention)."""
    if wire in types:
        return wire
    for k in aliases:
        if aliases[k] == wire:
            return k
    return ""


def _is_bytes_decl(types: Dict[String, String], k: String) raises -> Bool:
    """Declared field base = bytes (text part also accepted, U9)."""
    if k in types:
        return _parse_file_spec(types[k])[0] == "bytes"
    return False


def file_declared_names(handler: Handler) raises -> List[String]:
    """_file_types declared names ∪ aliases (text_multi_map filter: names
    claimed by file fields do not enter the form map)."""
    var types = get_file_types(handler)
    var aliases = get_file_aliases(handler)
    var out = List[String]()
    for k in types:
        out.append(k)
        if k in aliases:
            out.append(aliases[k])
    return out^


def text_multi_map_filtered(parts: MpParts, exclude: List[String]) raises -> Dict[String, List[String]]:
    """U8 + declaration priority: multipart text parts -> form multi-map
    (same shape as parse_form_multi); file parts do not enter the map
    (belongs to file parameters); text parts whose name hits a declared
    file field (name or alias) do not enter the map either (upstream: the
    same parameter cannot be both File and Form simultaneously)."""
    var out = Dict[String, List[String]]()
    var i = 0
    while i < parts.count():
        var nm = parts.names[i]
        if parts.is_file(i) or nm == "":
            i += 1
            continue
        var excl = False
        for x in exclude:
            if x == nm:
                excl = True
                break
        if not excl:
            var val = _part_text(parts, i)
            if nm in out:
                out[nm].append(val)
            else:
                var one = List[String]()
                one.append(val)
                out[nm] = one^
        i += 1
    return out^


def text_multi_map(parts: MpParts) raises -> Dict[String, List[String]]:
    """U8: multipart text part -> form multi-map (no-exclude convenience
    entry; dispatch uses the filtered version)."""
    return text_multi_map_filtered(parts, List[String]())

# ---------- Success-path injection ----------

def apply_file_extras(mut params: Dict[String, String], handler: Handler,
                      parts: MpParts) raises:
    """Success path (decision-32 superset + decision-46): file part ->
    file_<declared>_filename/_content_type/_size(actual bytes, U1)/
    _body_b64 (U4); text part -> form_<declared> (last-wins); text part
    hitting a declared bytes field -> file_ keys (bytes accepts both, U9);
    list declaration -> file_<declared>_count + _list_json
    ([{"filename","content_type","size","body_b64"},...] in order);
    alias fields are keyed by the **declared name** (wire alias has no
    binding force, same convention as form decision-45); undeclared names
    use the wire name as-is (decision-32 compat); _file_ops runs in
    file_ops_ffi."""
    var types = get_file_types(handler)
    var aliases = get_file_aliases(handler)
    var ftypes = get_form_types(handler)
    var fali = get_form_aliases(handler)
    var i = 0
    while i < parts.count():
        var nm = parts.names[i]
        if nm != "":
            var decl = nm
            var as_file = parts.is_file(i)
            if as_file:
                var fd = _decl_of(nm, types, aliases)
                if fd != "":
                    decl = fd
            else:
                var fdecl = _decl_of(nm, types, aliases)
                if fdecl != "":
                    # Text part hitting a declared file field: base=bytes
                    # is legal (U9) -> file_ keys; base=file is 422 at the
                    # validation layer and never reaches here.
                    decl = fdecl
                    as_file = _is_bytes_decl(types, fdecl)
                else:
                    var ddecl = _decl_of(nm, ftypes, fali)
                    if ddecl != "":
                        decl = ddecl
            if as_file:
                params["file_" + decl + "_filename"] = parts.filenames[i]
                params["file_" + decl + "_content_type"] = parts.cts[i]
                params["file_" + decl + "_size"] = String(parts.raw_lens[i])
                params["file_" + decl + "_body_b64"] = parts.b64s[i]
            else:
                params["form_" + decl] = _part_text(parts, i)
        i += 1
    for k in types:
        var fs = _parse_file_spec(types[k])
        if not fs[1]:
            continue
        var lookup = k
        if k in aliases:
            lookup = aliases[k]
        var occ = List[Int]()
        var pi = 0
        while pi < parts.count():
            if parts.names[pi] == lookup:
                occ.append(pi)
            pi += 1
        params["file_" + k + "_count"] = String(len(occ))
        var arr = List[String]()
        for oi in occ:
            var obj = "{\"filename\":\"" + json_escape(parts.filenames[oi]) + "\","
            obj = obj + "\"content_type\":\"" + json_escape(parts.cts[oi]) + "\","
            obj = obj + "\"size\":" + String(parts.raw_lens[oi]) + ","
            obj = obj + "\"body_b64\":\"" + json_escape(parts.b64s[oi]) + "\"}"
            arr.append(obj)
        params["file_" + k + "_list_json"] = "[" + ",".join(arr) + "]"
