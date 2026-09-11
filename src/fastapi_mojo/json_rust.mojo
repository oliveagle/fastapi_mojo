# src/fastapi_mojo/json_rust.mojo
#
# Decision-66: opt-in Rust JSON serialization for large response objects.
#
# Default behavior remains the pure-Mojo json.mojo implementation. Setting:
#   FASTAPI_MOJO_JSON_SERIALIZER=rust
# selects the Rust bridge writer only when the flat response dict is at least
# FASTAPI_MOJO_JSON_RUST_MIN_BYTES input bytes (default 64 KiB). The threshold
# keeps small responses on the lower-overhead Mojo path and avoids per-field FFI
# cost unless byte-heavy escaping is likely to dominate.
#
# Compatibility:
#   - Mojo Dict iteration order remains the source of field order;
#   - "__nested__:<raw JSON>" members keep their raw passthrough semantics;
#   - ordinary strings use the same escaping alphabet as json.mojo;
#   - any FFI/setup failure falls back to json_serialize_dict (no 500 path).

from std.ffi import external_call, CStringSlice
from std.os import getenv
from string_builder import span_to_str
from json import json_serialize_dict


def JSON_RUST_DEFAULT_MIN_BYTES() -> Int:
    """Module constant as function (Mojo 1.0 module-level let restriction)."""
    return 65536


def _json_rust_enabled() -> Bool:
    """Opt-in switch; default off preserves existing behavior."""
    return getenv("FASTAPI_MOJO_JSON_SERIALIZER") == "rust"


def _json_rust_min_bytes() raises -> Int:
    """Parse the threshold once per call; invalid/empty values use the default."""
    var raw = getenv("FASTAPI_MOJO_JSON_RUST_MIN_BYTES")
    if raw.byte_length() == 0:
        return JSON_RUST_DEFAULT_MIN_BYTES()
    var n = atol(raw)
    if n <= 0:
        return JSON_RUST_DEFAULT_MIN_BYTES()
    return n


def _response_input_bytes(data: Dict[String, String]) raises -> Int:
    """Estimate whether byte-heavy escaping is likely to dominate FFI cost."""
    var total = 0
    for key in data:
        total += key.byte_length() + data[key].byte_length() + 6
    return total


def rust_serialize_dict(data: Dict[String, String]) raises -> String:
    """Stream one flat Mojo response dict through the Rust JSON writer."""
    var begin_rc = external_call["fm_json_object_begin", Int]()
    if begin_rc != 0:
        return json_serialize_dict(data)

    for key in data:
        var name = key
        var value = data[key]
        var raw = 0
        if value.startswith("__nested__:"):
            raw = 1
        var add_rc = external_call["fm_json_object_add", Int](
            name.as_c_string_slice(),
            Int64(name.byte_length()),
            value.as_c_string_slice(),
            Int64(value.byte_length()),
            raw,
        )
        if add_rc != 0:
            return json_serialize_dict(data)

    var slice = external_call["fm_json_object_finish", CStringSlice[origin_of(String(""))]]()
    var body = span_to_str(slice.as_bytes())
    _ = external_call["fm_json_object_free", NoneType](slice)
    if body.byte_length() == 0:
        return json_serialize_dict(data)
    return body


def serialize_dict_opt_in(data: Dict[String, String]) raises -> String:
    """Decision-66 dispatch point: Mojo by default, Rust above the threshold."""
    if _json_rust_enabled() and _response_input_bytes(data) >= _json_rust_min_bytes():
        return rust_serialize_dict(data)
    return json_serialize_dict(data)
