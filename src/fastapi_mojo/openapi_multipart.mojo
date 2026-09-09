# src/fastapi_mojo/openapi_multipart.mojo
#
# Decision-46 (ADR-0021): OpenAPI 3.0 multipart body schema (U7) —
# split out from openapi.mojo (500-line threshold). Pure logic,
# no FFI.
#
# Value semantics: upstream 0.141.1 measured (p3/p3b/p5 probes,
# /tmp/fm_probe): file/bytes -> string + contentMediaType
# application/octet-stream; optional -> anyOf[...,null]; list ->
# array of items; required only when a required field exists;
# key order properties/type/required/title.
#
# Dependencies: openapi_multipart -> {handler, form_params, file_params,
# params_query_extra, json}; openapi -> openapi_multipart (one-way).

from handler import Handler
from form_params import (form_has_declaration, form_field_names_ordered,
                         get_form_types, get_form_aliases, _cap_name,
                         _openapi_form_field_schema, lower_ascii)
from file_params import (get_file_types, get_file_aliases,
                         file_has_declaration, file_field_names_ordered,
                         _parse_file_spec)
from params_query_extra import get_param_descs, has_eq
from json import json_escape

def _file_field_schema(prop_name: String, spec: String, desc: String) raises -> String:
    """U7: single file/bytes field schema (upstream 0.141.1 measured field
    order, p3/p5): non-list -> {"type":"string",
    "contentMediaType":"application/octet-stream","title":T[,"description":d]};
    optional (=) -> {"anyOf":[{...},{"type":"null"}],"title":T}; list ([]) ->
    {"items":{...},"type":"array","title":T}; optional list -> anyOf[array,
    null]. title = property name first letter capitalized; description =
    _param_descs shared table (decision-43)."""
    var fs = _parse_file_spec(spec)
    var core = "{\"type\":\"string\",\"contentMediaType\":\"application/octet-stream\"}"
    var t = json_escape(_cap_name(prop_name))
    var d = ""
    if desc != "":
        d = ",\"description\":\"" + json_escape(desc) + "\""
    if fs[1] and not fs[2]:
        return "{\"items\":" + core + ",\"type\":\"array\",\"title\":\"" + t + "\"" + d + "}"
    if fs[1] and fs[2]:
        return "{\"anyOf\":[{\"items\":" + core + ",\"type\":\"array\"},{\"type\":\"null\"}],\"title\":\"" + t + "\"" + d + "}"
    if not fs[1] and fs[2]:
        return "{\"anyOf\":[" + core + ",{\"type\":\"null\"}],\"title\":\"" + t + "\"" + d + "}"
    return "{\"type\":\"string\",\"contentMediaType\":\"application/octet-stream\",\"title\":\"" + t + "\"" + d + "}"


def _in_list(lst: List[String], v: String) -> Bool:
    for x in lst:
        if x == v:
            return True
    return False


def multipart_request_body_required(handler: Handler) raises -> Bool:
    """U7: requestBody.required only when there is a file/form declared
    field without '=' (upstream p3: all-optional body -> no required key)."""
    var t = get_file_types(handler)
    for k in t:
        if not _parse_file_spec(t[k])[2]:
            return True
    var tf = get_form_types(handler)
    for k in tf:
        if not has_eq(tf[k]):
            return True
    return False


def multipart_route(handler: Handler) raises -> Bool:
    """Decision-46: this route is a multipart body route = declares
    _file_types, or _multipart="true" and form declaration (file fields
    imply multipart; form-only multipart requires the flag)."""
    if file_has_declaration(handler):
        return True
    if ("_multipart" in handler.data and handler.data["_multipart"] == "true"
            and form_has_declaration(handler)):
        return True
    return False


def multipart_openapi_schema(handler: Handler, method: String) raises -> String:
    """U7: components/schemas Body_<handler.name>_<method> (multipart body
    schema, upstream measured key order properties/type/required/title):
    file fields first (declaration order, contentMediaType schema), then
    form fields (declaration order; _form_fields untyped -> string);
    property name = alias if any else declared name; required = fields
    without '=' (omit key when empty). Naming deviation: Body_<handler.name>
    _<method> (upstream = fn+route+method, ADR-0020 §3.5-4 same convention)."""
    var name = "Body_" + handler.name + "_" + lower_ascii(method)
    var ftypes = get_file_types(handler)
    var fal = get_file_aliases(handler)
    var ftypes_form = get_form_types(handler)
    var fal_form = get_form_aliases(handler)
    var descs = get_param_descs(handler)
    var props = List[String]()
    var reqs = List[String]()
    var seen = List[String]()
    var fnames = file_field_names_ordered(handler)
    for i in range(len(fnames)):
        var n = fnames[i]
        var prop = n
        if n in fal:
            prop = fal[n]
        if _in_list(seen, prop):
            continue
        seen.append(prop)
        if n in ftypes:
            var spec = ftypes[n]
            var desc = ""
            if n in descs:
                desc = descs[n]
            props.append("\"" + json_escape(prop) + "\":" + _file_field_schema(prop, spec, desc))
            if not _parse_file_spec(spec)[2]:
                reqs.append("\"" + json_escape(prop) + "\"")
        else:
            # _file_fields legacy (untyped) -> plain string (ADR-0020 §3.5-5 same rule)
            props.append("\"" + json_escape(prop) + ":{\"type\":\"string\",\"title\":\"" + json_escape(_cap_name(prop)) + "\"}")
    var mnames = form_field_names_ordered(handler)
    for i in range(len(mnames)):
        var n2 = mnames[i]
        var prop2 = n2
        if n2 in fal_form:
            prop2 = fal_form[n2]
        if _in_list(seen, prop2):
            continue
        seen.append(prop2)
        if n2 in ftypes_form:
            var spec2 = ftypes_form[n2]
            var desc2 = ""
            if n2 in descs:
                desc2 = descs[n2]
            # title follows the property name (upstream; alias aware) —
            # _openapi_form_field_schema uses name only for the title
            props.append("\"" + json_escape(prop2) + "\":" + _openapi_form_field_schema(prop2, spec2, desc2))
            if not has_eq(spec2):
                reqs.append("\"" + json_escape(prop2) + "\"")
        else:
            props.append("\"" + json_escape(prop2) + ":{\"type\":\"string\",\"title\":\"" + json_escape(_cap_name(prop2)) + "\"}")
    var out = "{\"properties\":{" + ",".join(props) + "},\"type\":\"object\""
    if len(reqs) > 0:
        out = out + ",\"required\":[" + ",".join(reqs) + "]"
    out = out + ",\"title\":\"" + json_escape(name) + "\"}"
    return out^

