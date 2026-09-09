# src/fastapi_mojo/file_params_selftest.mojo
#
# 决策-46 (ADR-0021): file_params 纯逻辑自检 (mojo run — JIT 可达,
# 零 FFI: 只测 spec 解析 / 422 校验 / 注入 / text_multi_map / b64.
# FFI 依赖路径 (snapshot_mp_parts / head/range/save ops) 由 e2e MP2-*
# 守护.

import std.os

from file_params import (MpParts, get_file_types, get_file_aliases,
                         file_has_declaration, file_field_names_ordered,
                         _parse_file_spec, _b64_encode, _b64_decode_bytes,
                         validate_file_collect, text_multi_map,
                         text_multi_map_filtered, apply_file_extras,
                         file_declared_names)
from file_form_check import validate_file_vs_form
from handler import Handler, KIND_ECHO


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def _has(s: String, sub: String) -> Bool:
    var sn = sub.byte_length()
    var sl = s.byte_length()
    if sn == 0 or sn > sl:
        return False
    for i in range(sl - sn + 1):
        var j = 0
        while j < sn:
            if ord(s[byte=i + j]) != ord(sub[byte=j]):
                break
            j += 1
        if j == sn:
            return True
    return False


def _add(mut parts: MpParts, name: String, filename: String, ct: String,
         b64: String, raw_len: Int) raises:
    parts.names.append(name)
    parts.filenames.append(filename)
    parts.cts.append(ct)
    parts.b64s.append(b64)
    parts.raw_lens.append(raw_len)
    parts.idxs.append(parts.count())


def main() raises:
    print("Testing file params (UploadFile API, 决策-46)...")

    # spec 解析
    var s1 = _parse_file_spec("file")
    check(s1[0] == "file" and not s1[1] and not s1[2], "spec file")
    var s2 = _parse_file_spec("file=")
    check(s2[0] == "file" and not s2[1] and s2[2], "spec file= (optional)")
    var s3 = _parse_file_spec("file[]")
    check(s3[0] == "file" and s3[1] and not s3[2], "spec file[] (list)")
    var s4 = _parse_file_spec("file[]=")
    check(s4[0] == "file" and s4[1] and s4[2], "spec file[]= (optional list)")
    var s5 = _parse_file_spec("bytes=")
    check(s5[0] == "bytes" and not s5[1] and s5[2], "spec bytes=")

    # b64 往返 (known vector: "hello" -> aGVsbG8=)
    check(_b64_encode([104, 101, 108, 108, 111]) == "aGVsbG8=", "b64 encode hello")
    var dec = _b64_decode_bytes("aGVsbG8=")
    check(len(dec) == 5 and dec[0] == 104 and dec[4] == 111, "b64 decode hello")
    check(_b64_encode([65]) == "QQ==", "b64 pad1")
    check(_b64_encode([65, 66]) == "QUI=", "b64 pad2")

    # 422: 必填缺失 (F 大写 + input null)
    var ts = Dict[String, String]()
    ts["doc"] = "file"
    var r = validate_file_collect(ts, Dict[String, String](), MpParts())
    check(not r[0] and _has(r[1][0], "[\"body\",\"doc\"]")
          and _has(r[1][0], "\"msg\":\"Field required\"")
          and _has(r[1][0], "\"input\":null"), "missing required file")

    # 422: 可选缺失 -> 通过
    var ts2 = Dict[String, String]()
    ts2["opt"] = "file="
    r = validate_file_collect(ts2, Dict[String, String](), MpParts())
    check(r[0], "missing optional file ok")

    # 422: 文本 part 送 file -> value_error, input = 文本
    var p1 = MpParts()
    _add(p1, "doc", "", "", "dGhpcyBpcyBhIHRleHQ=", 14)
    r = validate_file_collect(ts, Dict[String, String](), p1.copy())
    check(not r[0] and _has(r[1][0], "value_error")
          and _has(r[1][0], "Expected UploadFile, received: <class 'str'>")
          and _has(r[1][0], "\"input\":\"this is a text\""), "text -> file 422")

    # last-wins: text 后 file -> 通过
    var p2 = MpParts()
    _add(p2, "doc", "", "", "dGhpcyBpcyBhIHRleHQ=", 14)
    _add(p2, "doc", "a.bin", "text/plain", "aGVsbG8=", 5)
    r = validate_file_collect(ts, Dict[String, String](), p2.copy())
    check(r[0], "text-then-file last-wins ok")

    # file 后 text -> 422 (last = text)
    var p3 = MpParts()
    _add(p3, "doc", "a.bin", "text/plain", "aGVsbG8=", 5)
    _add(p3, "doc", "", "", "dGV4dA==", 4)
    r = validate_file_collect(ts, Dict[String, String](), p3.copy())
    check(not r[0] and _has(r[1][0], "value_error")
          and _has(r[1][0], "\"input\":\"text\""), "file-then-text 422")

    # list: 逐 occurrence (file, text@1 -> loc idx 1)
    var ts3 = Dict[String, String]()
    ts3["pics"] = "file[]"
    var p4 = MpParts()
    _add(p4, "pics", "a.bin", "", "QQ==", 1)
    _add(p4, "pics", "", "", "dGV4dA==", 4)
    r = validate_file_collect(ts3, Dict[String, String](), p4.copy())
    check(not r[0] and len(r[1]) == 1
          and _has(r[1][0], "[\"body\",\"pics\",1]")
          and _has(r[1][0], "\"input\":\"text\""), "list mixed loc idx")

    # list 全 file -> 通过; 可选 list 缺失 -> 通过
    var p5 = MpParts()
    _add(p5, "pics", "a.bin", "", "QQ==", 1)
    _add(p5, "pics", "b.bin", "", "Qg==", 1)
    r = validate_file_collect(ts3, Dict[String, String](), p5.copy())
    check(r[0], "list all-file ok")
    var ts4 = Dict[String, String]()
    ts4["pics"] = "file[]="
    r = validate_file_collect(ts4, Dict[String, String](), MpParts())
    check(r[0], "optional list missing ok")

    # 未知类型
    var ts5 = Dict[String, String]()
    ts5["x"] = "weird"
    r = validate_file_collect(ts5, Dict[String, String](), MpParts())
    check(not r[0] and _has(r[1][0], "unknown_type"), "unknown type 422")

    # bytes: 文本 part 接受 (U9 偏差: 上游 List[bytes] 此处 500)
    var ts6 = Dict[String, String]()
    ts6["raw"] = "bytes"
    var p10 = MpParts()
    _add(p10, "raw", "", "", "dGhpcyBpcyBhIHRleHQ=", 14)
    r = validate_file_collect(ts6, Dict[String, String](), p10.copy())
    check(r[0], "bytes accepts text part")

    # alias: wire key = alias (原始名无效力)
    var ts7 = Dict[String, String]()
    ts7["doc"] = "file"
    var al = Dict[String, String]()
    al["doc"] = "docfile"
    var p6 = MpParts()
    _add(p6, "docfile", "a.bin", "", "QQ==", 1)
    r = validate_file_collect(ts7, al, p6.copy())
    check(r[0], "alias wire key ok")
    var p7 = MpParts()
    _add(p7, "doc", "a.bin", "", "QQ==", 1)
    r = validate_file_collect(ts7, al, p7.copy())
    check(not r[0] and _has(r[1][0], "Field required"), "alias: original ignored")

    # text_multi_map (U8): 文本 part 进 map, 文件 part 不进
    var p8 = MpParts()
    _add(p8, "note", "", "", "aGVsbG8=", 5)
    _add(p8, "doc", "a.bin", "", "aGVsbG8=", 5)
    var mm = text_multi_map(p8.copy())
    check(len(mm["note"]) == 1 and mm["note"][0] == "hello", "text_multi_map")
    check(not ("doc" in mm), "text_multi_map skips file parts")

    # apply: 注入 (U1 size = raw; form_ / file_ 前缀; alias)
    var h = Handler(KIND_ECHO(), "up")
    h.set_data("_file_types", "doc:file;opt:file=")
    h.set_data("_file_aliases", "doc=docfile")
    var p9 = MpParts()
    _add(p9, "docfile", "a.bin", "text/plain", "aGVsbG8=", 5)
    _add(p9, "note", "", "", "aGVsbG8=", 5)
    var params = Dict[String, String]()
    apply_file_extras(params, h, p9.copy())
    check(params["file_doc_filename"] == "a.bin", "inject filename (alias)")
    check(params["file_doc_content_type"] == "text/plain", "inject ct")
    check(params["file_doc_size"] == "5", "inject size = raw len (U1)")
    check(params["file_doc_body_b64"] == "aGVsbG8=", "inject body_b64")
    check(params["form_note"] == "hello", "inject form text")

    # apply: list count + json
    var h2 = Handler(KIND_ECHO(), "up2")
    h2.set_data("_file_types", "pics:file[]")
    var params2 = Dict[String, String]()
    apply_file_extras(params2, h2, p5.copy())
    check(params2["file_pics_count"] == "2", "list count")
    check(_has(params2["file_pics_list_json"],
               "[{\"filename\":\"a.bin\",\"content_type\":\"\","
               "\"size\":1,\"body_b64\":\"QQ==\"},")
          and _has(params2["file_pics_list_json"], "\"b.bin\""),
          "list json array (got " + params2["file_pics_list_json"] + ")")

    # 声明表解析
    check(file_has_declaration(h), "has_declaration true")
    check(not file_has_declaration(Handler(KIND_ECHO(), "plain")),
          "has_declaration false")
    var names = file_field_names_ordered(h)
    check(len(names) == 2 and names[0] == "doc" and names[1] == "opt",
          "names ordered")
    check(get_file_aliases(h)["doc"].byte_length() > 0, "aliases table")
    check(get_file_types(h)["opt"] == "file=", "types table")

    # U3: file part -> declared form field -> 422 string_type (input 近似)
    var ft1 = Dict[String, String]()
    ft1["note"] = "str"
    var fali1 = Dict[String, String]()
    var ft_empty = Dict[String, String]()
    var p11 = MpParts()
    _add(p11, "note", "f.txt", "text/plain", "ZmlsZWRhdGE=", 8)
    var e3 = validate_file_vs_form(p11.copy(), ft1, fali1, ft_empty, ft_empty)
    check(len(e3) == 1
          and _has(e3[0], "\"loc\":[\"body\",\"note\"]")
          and _has(e3[0], "\"msg\":\"Input should be a valid string\"")
          and _has(e3[0], "\"type\":\"string_type\"")
          and _has(e3[0], "\"input\":{\"filename\":\"f.txt\",\"size\":8")
          and _has(e3[0], "content-disposition"), "U3 file->form string_type")

    # U3 last-wins: file-then-text -> 通过 (last = text)
    var p12 = MpParts()
    _add(p12, "note", "f.txt", "", "ZmlsZWRhdGE=", 8)
    _add(p12, "note", "", "", "dHh0dmFs", 6)
    var e3b = validate_file_vs_form(p12.copy(), ft1, fali1, ft_empty, ft_empty)
    check(len(e3b) == 0, "U3 file-then-text ok")

    # U3 list: text-then-file -> loc idx 1
    var ft2 = Dict[String, String]()
    ft2["tags"] = "str[]"
    var p13 = MpParts()
    _add(p13, "tags", "", "", "dDE=", 2)
    _add(p13, "tags", "g.txt", "", "ZmlsZWRhdGE=", 8)
    var e3c = validate_file_vs_form(p13.copy(), ft2, fali1, ft_empty, ft_empty)
    check(len(e3c) == 1 and _has(e3c[0], "\"loc\":[\"body\",\"tags\",1]"),
          "U3 list idx")

    # 声明名优先: file part 命中已声明 file 字段名 -> 不进 U3
    var ft3 = Dict[String, String]()
    ft3["note"] = "str"
    var ftypes3 = Dict[String, String]()
    ftypes3["doc"] = "file"
    var p14 = MpParts()
    _add(p14, "doc", "a.bin", "", "QQ==", 1)
    var e3d = validate_file_vs_form(p14.copy(), ft3, fali1, ftypes3, ft_empty)
    check(len(e3d) == 0, "U3 file-declared skip")

    # text_multi_map_filtered: 声明 file 字段名 (含 alias) 不进 map
    var p15 = MpParts()
    _add(p15, "note", "", "", "aGVsbG8=", 5)
    _add(p15, "docfile", "", "", "dGV4dA==", 4)
    _add(p15, "other", "", "", "dHdv", 3)
    var excl = file_declared_names(h)  # h: doc(file, alias docfile) + opt
    var mmf = text_multi_map_filtered(p15.copy(), excl)
    check(("note" in mmf) and not ("docfile" in mmf) and ("other" in mmf),
          "text map filtered by file decls")

    # bytes 字段收 text part -> file_ keys (U9)
    var h3 = Handler(KIND_ECHO(), "up3")
    h3.set_data("_file_types", "raw:bytes")
    var p16 = MpParts()
    _add(p16, "raw", "", "", "ZGVjcA==", 4)
    var params3 = Dict[String, String]()
    apply_file_extras(params3, h3, p16.copy())
    check(params3["file_raw_size"] == "4" and params3["file_raw_body_b64"] == "ZGVjcA==",
          "bytes field accepts text part -> file_ keys")
    check(not ("form_raw" in params3), "bytes text not form_")

    print("file_params self-test: all checks passed")
