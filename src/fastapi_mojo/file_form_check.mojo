# src/fastapi_mojo/file_form_check.mojo
#
# Decision-46 (ADR-0021, U3): file part sent to a declared form field ->
# 422 string_type check. Split from file_params.mojo (500-line
# threshold). Pure Mojo (zero FFI).
#
# Value semantics: upstream 0.141.1 measured (p4/p7 probes,
# /tmp/fm_probe): scalar = last-wins (last occurrence a file part ->
# string_type; file-then-text -> 200 text); list = per-occurrence (loc
# index = position in full occurrence sequence). input = stable subset
# of the upstream UploadFile dict (filename/size/headers; impl-detail
# fields excluded, ADR-0021 §3.5-2). File parts claimed by declared
# file fields (name or alias) do not participate.
#
# Dependencies: file_form_check -> {file_params (MpParts/_decl_of), json};
# file_params_selftest / http_server_final -> file_form_check (one-way).

from file_params import MpParts, _decl_of
from json import json_escape


def _fe(loc: String, msg: String, type_name: String, input_json: String) -> String:
    """Single 422 error object (field order loc,msg,type,input — ADR-0020
    §3.5-1 convention, same as form_params._fe)."""
    return "{\"loc\":" + loc + ",\"msg\":\"" + json_escape(msg) + "\",\"type\":\"" + type_name + "\",\"input\":" + input_json + "}"

def _file_obj_input(parts: MpParts, i: Int) -> String:
    """U3 422 input approximation: stable subset of the upstream
    UploadFile object dict (filename/size/headers; the upstream
    _file/_max_size/_rolled/_TemporaryFileArgs/_max_mem_size are
    impl details that vary by env, excluded — ADR-0021 §3.5-2).
    headers = the part's own headers (content-disposition + content-type
    if present, starlette measured)."""
    var cd = "form-data; name=\"" + parts.names[i] + "\""
    if parts.filenames[i] != "":
        cd = cd + "; filename=\"" + parts.filenames[i] + "\""
    var hdrs = "{\"content-disposition\":\"" + json_escape(cd) + "\""
    if parts.cts[i] != "":
        hdrs = hdrs + ",\"content-type\":\"" + json_escape(parts.cts[i]) + "\""
    hdrs = hdrs + "}"
    return ("{\"filename\":\"" + json_escape(parts.filenames[i]) + "\","
            + "\"size\":" + String(parts.raw_lens[i]) + ","
            + "\"headers\":" + hdrs + "}")


def validate_file_vs_form(parts: MpParts, ftypes: Dict[String, String],
                          fal: Dict[String, String],
                          file_types: Dict[String, String],
                          file_aliases: Dict[String, String]) raises -> List[String]:
    """U3: file part sent to a declared form field -> 422 string_type
    ("Input should be a valid string", input = file object approximation).
    Scalar = last-wins (last occurrence is a file part -> error; file-then-
    text -> 200 text, measured); list = check all occurrences (loc index
    = position in the full occurrence sequence). File parts claimed by a
    declared file field (name or alias) do not participate (declared name
    priority)."""
    var errs = List[String]()
    if len(ftypes) == 0 or parts.count() == 0:
        return errs^
    for k in ftypes:
        var spec = ftypes[k]
        var lookup = k
        if k in fal:
            lookup = fal[k]
        var claimed = _decl_of(lookup, file_types, file_aliases) != ""
        if claimed:
            continue
        var occ = List[Int]()
        var pi = 0
        while pi < parts.count():
            if parts.names[pi] == lookup:
                occ.append(pi)
            pi += 1
        if len(occ) == 0:
            continue
        var is_list = False
        var sn = spec.byte_length()
        if sn >= 2 and ord(spec[byte=sn - 2]) == 91 and ord(spec[byte=sn - 1]) == 93:
            is_list = True
        if is_list:
            var j = 0
            while j < len(occ):
                var pi2 = occ[j]
                if parts.is_file(pi2):
                    var eloc = "[\"body\",\"" + json_escape(k) + "\"," + String(j) + "]"
                    errs.append(_fe(eloc, "Input should be a valid string",
                                    "string_type", _file_obj_input(parts, pi2)))
                j += 1
        else:
            var last = occ[len(occ) - 1]
            if parts.is_file(last):
                var loc = "[\"body\",\"" + json_escape(k) + "\"]"
                errs.append(_fe(loc, "Input should be a valid string",
                                "string_type", _file_obj_input(parts, last)))
    return errs^




def file_part_fields(parts: MpParts, ftypes: Dict[String, String],
                     fal: Dict[String, String],
                     file_types: Dict[String, String],
                     file_aliases: Dict[String, String]) raises -> List[String]:
    """Declared form field names (k) that have at least one file part
    occurrence (claimed fields excluded). dispatch uses this to drop the
    duplicate "missing" 422 for those fields (upstream: presence wins —
    a file part makes the field present, not missing)."""
    var out = List[String]()
    if len(ftypes) == 0 or parts.count() == 0:
        return out^
    for k in ftypes:
        var lookup = k
        if k in fal:
            lookup = fal[k]
        if _decl_of(lookup, file_types, file_aliases) != "":
            continue
        var any_file = False
        var pi = 0
        while pi < parts.count():
            if parts.names[pi] == lookup and parts.is_file(pi):
                any_file = True
                break
            pi += 1
        if any_file:
            out.append(k)
    return out^
