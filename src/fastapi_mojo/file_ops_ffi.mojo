# src/fastapi_mojo/file_ops_ffi.mojo
#
# 决策-46 (ADR-0021): file 对象操作的 FFI 层 (head/range/sha256/save)
# + multipart 快照 (mp_parse_current FFI 边界).
#
# 与 file_params 分离的原因: mojo run JIT 链接不了 Rust bridge 符号
# (决策-38 教训) — file_params 保持 100% 纯 Mojo (可 JIT 自检);
# 本模块含 external_call, 由编译链路 (build_single) 链接, e2e MP2-*
# 守护.
#
# FFI: mp_part_save (新, 决策-46) + mp_part_field_* field 3/5 (复用,
# 逐字节纯整数返回, CStringSlice ABI 歧义规避 — 决策-32).
# 依赖: file_ops_ffi -> file_params (单向); http_server_final -> 本模块.

from file_params import MpParts, _b64_encode
from string_builder import decode_utf8_bytes

from std.ffi import external_call


def mp_ffi_read_field(part_i: Int, field: Int) -> String:
    """part 字段逐字节读 (field: 0=name 1=filename 2=ct 3=body 4=b64
    5=sha256hex). 非 ASCII 走 decode_utf8_bytes (中文文件名/文本字段)."""
    var fld_len = external_call["mp_part_field_len", Int](Int64(part_i), Int64(field))
    if fld_len <= 0:
        return ""
    var bytes = List[Int]()
    var i = 0
    while i < fld_len:
        var bval = external_call["mp_part_field_byte", Int](Int64(part_i), Int64(field), Int64(i))
        if bval < 0:
            break
        bytes.append(bval)
        i += 1
    return decode_utf8_bytes(bytes)


def mp_ffi_read_bytes(part_i: Int, field: Int, start: Int, count: Int) -> List[Int]:
    """字段 [start, start+count) 字节区间 (head/range ops; 越界少返)."""
    var out = List[Int]()
    var i = 0
    while i < count:
        var bval = external_call["mp_part_field_byte", Int](Int64(part_i), Int64(field), Int64(start + i))
        if bval < 0:
            break
        out.append(bval)
        i += 1
    return out^


def snapshot_mp_parts() raises -> MpParts:
    """mp_parse_current + 逐 part 字段读 (dispatch 校验段单一 FFI
    快照点). 失败 (非 multipart / 坏 boundary / 无 conn) -> 空 —
    上游等价「字段全缺失」(U5)."""
    var out = MpParts()
    var n_parts = external_call["mp_parse_current", Int]()
    if n_parts <= 0:
        return out^
    var i = 0
    while i < n_parts:
        var raw_len = external_call["mp_part_field_len", Int](Int64(i), Int64(3))
        out.names.append(mp_ffi_read_field(i, 0))
        out.filenames.append(mp_ffi_read_field(i, 1))
        out.cts.append(mp_ffi_read_field(i, 2))
        out.b64s.append(mp_ffi_read_field(i, 4))
        out.raw_lens.append(max(0, raw_len))
        out.idxs.append(i)
        i += 1
    return out^


def find_last(parts: MpParts, lookup: String) -> Int:
    """last occurrence 的快照下标 (U4); 未找到 -> -1."""
    var found = -1
    var i = 0
    while i < parts.count():
        if parts.names[i] == lookup:
            found = i
        i += 1
    return found


def _split_colons(s: String) -> List[String]:
    """':' 切分 (save 的 path 保留其余段, 调用方拼回)."""
    var out = List[String]()
    var start = 0
    var n = s.byte_length()
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(s[byte=i]) == 58)
        if is_sep:
            if i > start:
                out.append(String(s[byte=start:i]))
            start = i + 1
        i += 1
    return out^


def _atoi(s: String) -> Int:
    """小整数解析 (op 参数; 非数字 -> 0, 调用方 clamp)."""
    var v = 0
    for i in range(s.byte_length()):
        var c = ord(s[byte=i])
        if c < 48 or c > 57:
            break
        v = v * 10 + (c - 48)
    return v


def _path_safe(path: String) -> Bool:
    """save 路径穿越防护: 含 ".." -> 拒 (上游无此检查 — 安全超集)."""
    var n = path.byte_length()
    var i = 0
    while i + 1 < n:
        if ord(path[byte=i]) == 46 and ord(path[byte=i + 1]) == 46:
            return False
        i += 1
    return True


def apply_file_ops(mut params: Dict[String, String],
                   parts: MpParts, ops_csv: String,
                   aliases: Dict[String, String]) raises:
    """_file_ops: "name:op[:a1][:a2];..." 逐条执行. name = 声明名
    (alias 字段先经 aliases 声明->wire 解析, 决策-45 同语义; 输出 key
    统一用声明名, 与 apply_file_extras 一致).
    op: head:N / range:S:L / sha256 / save:PATH. 取 last occurrence
    (U4); 未出现/坏 entry (无 ':') -> no-op."""
    var n = ops_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(ops_csv[byte=i]) == 59)  # ';'
        if is_sep:
            if i > start:
                apply_one_op(params, parts, String(ops_csv[byte=start:i]), aliases)
            start = i + 1
        i += 1


def apply_one_op(mut params: Dict[String, String], parts: MpParts,
                 entry: String, aliases: Dict[String, String]) raises:
    """单条 op: name:op[:a1][:a2]."""
    var pieces = _split_colons(entry)
    if len(pieces) < 2:
        return
    var name = pieces[0]
    var op = pieces[1]
    var lookup = name
    if name in aliases:
        lookup = aliases[name]
    var pi = find_last(parts, lookup)
    if pi < 0:
        return
    var pref = "file_" + name
    if op == "head":
        var cnt = 0
        if len(pieces) > 2:
            cnt = _atoi(pieces[2])
        if cnt < 0 or cnt > parts.raw_lens[pi]:
            cnt = max(0, min(cnt, parts.raw_lens[pi]))
        params[pref + "_head_b64"] = _b64_encode(
            mp_ffi_read_bytes(parts.idxs[pi], 3, 0, cnt))
    elif op == "range":
        var off = 0
        var cnt = 0
        if len(pieces) > 2:
            off = _atoi(pieces[2])
        if len(pieces) > 3:
            cnt = _atoi(pieces[3])
        if off < 0:
            off = 0
        if off > parts.raw_lens[pi]:
            off = parts.raw_lens[pi]
        if cnt < 0:
            cnt = 0
        if off + cnt > parts.raw_lens[pi]:
            cnt = parts.raw_lens[pi] - off
        params[pref + "_range_b64"] = _b64_encode(
            mp_ffi_read_bytes(parts.idxs[pi], 3, off, cnt))
    elif op == "sha256":
        params[pref + "_sha256"] = mp_ffi_read_field(parts.idxs[pi], 5)
    elif op == "save":
        var path = ""
        if len(pieces) > 2:
            path = pieces[2]
            for j in range(3, len(pieces)):
                path = path + ":" + pieces[j]
        var ok = False
        if path != "" and _path_safe(path):
            var rc = external_call["mp_part_save", Int](
                Int64(parts.idxs[pi]), path.as_c_string_slice())
            ok = (rc == 0)
        params[pref + "_saved_ok"] = "true" if ok else "false"
        params[pref + "_saved_path"] = path
