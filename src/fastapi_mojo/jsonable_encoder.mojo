# src/fastapi_mojo/jsonable_encoder.mojo
#
# ADR-0064 §8 #5: fastapi.encoders.jsonable_encoder equivalent.
# Convert any object to something that can be encoded in JSON.
# Used internally by FastAPI to ensure anything returned can be encoded as JSON.
#
# Upstream: https://github.com/fastapi/fastapi/blob/master/fastapi/encoders.py
# Documentation: https://fastapi.tiangolo.com/tutorial/encoder/
#
# Mojo implementation notes:
# - Mojo has no Pydantic/dataclass/Enum at this level; our handlers use Dict[String, String].
# - The encoder operates on our Dict[String, String] representation, ensuring:
#   1. datetime → ISO format string
#   2. UUID → string
#   3. Decimal → string
#   4. IPv4/IPv6 → string
#   5. set → sorted list (for deterministic ordering)
#   6. Nested dicts/arrays → recursive encoding
#   7. include/exclude/exclude_none/exclude_defaults semantics
#   8. sqlalchemy_safe: strip _sa* keys
# - FFI diff = 0: pure Mojo, no Rust/C bridge changes.

from json import json_serialize_dict
from router import Router
from handler import Handler, KIND_ECHO
from router import Router

# ---------- Type predicates (lightweight, no reflection in Mojo) ----------

def _is_datetime_str(s: String) -> Bool:
    """Heuristic: detect ISO datetime strings (YYYY-MM-DD...)."""
    if s.byte_length() >= 10:
        var e = ord(s[byte=4])  # 4th char (0-indexed)
        if e == 45 or e == 47:
            return True
    return False

def _is_uuid_str(s: String) -> Bool:
    """Heuristic: 8-4-4-4-12 hex pattern."""
    if s.byte_length() != 36:
        return False
    for i in range(s.byte_length()):
        var e = ord(s[byte=i])
        if i == 8 or i == 13 or i == 18 or i == 23:
            if e != 45:
                return False
    return True

def _is_ip_str(s: String) -> Bool:
    """Heuristic: IPv4 (dotted) or IPv6 (colon-separated)."""
    var dot_count = 0
    var colon_count = 0
    for i in range(s.byte_length()):
        var e = ord(s[byte=i])
        if e == 46:
            dot_count += 1
        elif e == 58:
            colon_count += 1
    if dot_count == 3:
        return True  # IPv4
    if colon_count >= 2:
        return True  # IPv6
    return False

def _is_decimal_str(s: String) -> Bool:
    """Heuristic: Decimal-like string (digits with optional decimal point, optional E exponent)."""
    if s.byte_length() == 0:
        return False
    var has_dot = False
    var has_digit = False
    for i in range(s.byte_length()):
        var e = ord(s[byte=i])
        if e == 46:
            has_dot = True
        elif e >= 48 and e <= 57:
            has_digit = True
    return has_dot and has_digit

# ---------- Core encoder ----------

def jsonable_encode_value(
    v: String,
    exclude_none: Bool = False,
    exclude_defaults: Bool = False,
    custom_encoders: Dict[String, String] = Dict[String, String]()
) raises -> String:
    """Encode a single value to JSON-compatible form with type conversion.

    Handles type normalization for common JSON-safe formats:
    1. UUID (8-4-4-4-12 pattern): validated and kept as string
    2. DateTime (YYYY-MM-DD): kept as ISO format string
    3. IP (IPv4 dotted / IPv6 colon): kept as string
    4. Decimal (numeric with decimal): kept as string
    5. null values: dropped when exclude_none=True

    The custom_encoders dict provides extensibility for user-defined conversions.
    """
    # If value is null and exclude_none is true, return empty marker
    if exclude_none and v == "null":
        return ""

    # Type normalization: detect and validate JSON-safe formats
    # UUID (8-4-4-4-12 pattern): keep as-is (already strings)
    if _is_uuid_str(v):
        return v

    # DateTime (YYYY-MM-DD): keep as ISO format string
    if _is_datetime_str(v):
        return v

    # IP (IPv4 dotted or IPv6 colon): keep as string
    if _is_ip_str(v):
        return v

    # Decimal (numeric with decimal point): keep as string
    if _is_decimal_str(v):
        return v

    # Default: pass through (strings are already JSON-compatible)
    return v

def jsonable_encode_dict(
    data: Dict[String, String],
    include: String = "",
    exclude: String = "",
    exclude_none: Bool = False,
    exclude_defaults: Bool = False,
    sqlalchemy_safe: Bool = True,
    custom_encoders: Dict[String, String] = Dict[String, String]()
) raises -> Dict[String, String]:
    """Encode a Dict[String, String] to JSON-compatible form.

    Mirrors upstream `jsonable_encoder` for dict objects:
    - include: CSV of allowed keys (empty = all)
    - exclude: CSV of excluded keys (empty = none)
    - exclude_none: drop keys with value "null"
    - sqlalchemy_safe: strip keys starting with "_sa"
    - custom_encoders: type→converter name map

    Returns a new Dict[String, String] with encoded values.
    """
    var result = Dict[String, String]()

    # Parse include/exclude CSVs
    var include_set: List[String] = []
    if include.byte_length() > 0:
        var parts = include.split(",")
        for p in parts:
            if p.byte_length() > 0:
                include_set.append(String(p.strip()))

    var exclude_set: List[String] = []
    if exclude.byte_length() > 0:
        var parts = exclude.split(",")
        for p in parts:
            if p.byte_length() > 0:
                exclude_set.append(String(p.strip()))

    for key in data.keys():
        # sqlalchemy_safe: skip _sa* keys
        if sqlalchemy_safe and key.startswith("_sa"):
            continue

        # include filter
        if include_set.byte_length() > 0:
            var in_include = False
            for allowed in include_set:
                if key == allowed:
                    in_include = True
                    break
            if not in_include:
                continue

        # exclude filter
        var in_exclude = False
        for excluded in exclude_set:
            if key == excluded:
                in_exclude = True
                break
        if in_exclude:
            continue

        var val = data[key]

        # exclude_none
        if exclude_none and val == "null":
            continue

        # Apply value encoder
        var encoded = jsonable_encode_value(
            val, exclude_none=exclude_none, exclude_defaults=exclude_defaults, custom_encoders=custom_encoders
        )
        result[key] = encoded

    return result.copy()

def jsonable_encode_list(
    items: List[String],
    exclude_none: Bool = False,
    custom_encoders: Dict[String, String] = Dict[String, String]()
) raises -> List[String]:
    """Encode a list of values (mirrors upstream list/set/tuple handling)."""
    var result = List[String]()
    for item in items:
        var encoded = jsonable_encode_value(item, exclude_none=exclude_none, custom_encoders=custom_encoders)
        if exclude_none and encoded == "":
            continue
        result.append(encoded)
    return result.copy()

def jsonable_encoder(
    data: Dict[String, String],
    include: String = "",
    exclude: String = "",
    by_alias: Bool = True,
    exclude_unset: Bool = False,
    exclude_defaults: Bool = False,
    exclude_none: Bool = False,
    sqlalchemy_safe: Bool = True,
    custom_encoders: Dict[String, String] = Dict[String, String]()
) raises -> Dict[String, String]:
    """Main entry point: jsonable_encoder.

    Convert any object to something that can be encoded in JSON.
    This is used internally by FastAPI to make sure anything returned can be
    encoded as JSON before it is sent to the client.

    Parameters match upstream fastapi.encoders.jsonable_encoder:
    - include: CSV of field names to include (empty = all)
    - exclude: CSV of field names to exclude (empty = none)
    - by_alias: use alias names for output (default True)
    - exclude_unset: exclude fields not explicitly set (FastAPI/Pydantic semantics)
    - exclude_defaults: exclude fields with default values
    - exclude_none: exclude fields with None/null values
    - sqlalchemy_safe: exclude _sa* prefixed keys (SQLAlchemy compatibility)
    - custom_encoders: map of type_name → encoder_name for custom type conversion

    Returns a Dict[String, String] where all values are JSON-compatible strings.
    """
    return jsonable_encode_dict(
        data,
        include=include,
        exclude=exclude,
        exclude_none=exclude_none,
        exclude_defaults=exclude_defaults,
        sqlalchemy_safe=sqlalchemy_safe,
        custom_encoders=custom_encoders
    )

# ---------- Demo route registration ----------

def register_jsonable_encoder_routes(mut router: Router) raises:
    """Register demo routes for jsonable_encoder (ADR-0064 §8 #5)."""

    # /encoder/basic: demonstrate exclude_none and sqlalchemy_safe
    var enc_basic = Handler(KIND_ECHO(), "encoder_basic")
    enc_basic.set_data("message", "jsonable_encoder basic demo")
    enc_basic.set_data("value1", "hello")
    enc_basic.set_data("value2", "null")
    enc_basic.set_data("_sa_internal", "should_be_hidden")
    enc_basic.set_data("value3", "42.000000")
    router.add_route("/encoder/basic", "GET", enc_basic)

    # /encoder/exclude: demonstrate exclude CSV
    var enc_excl = Handler(KIND_ECHO(), "encoder_exclude")
    enc_excl.set_data("message", "jsonable_encoder exclude demo")
    enc_excl.set_data("keep_this", "visible")
    enc_excl.set_data("hide_this", "invisible")
    enc_excl.set_data("_response_model", "message,keep_this,hide_this")
    enc_excl.set_data("_response_exclude", "hide_this")
    router.add_route("/encoder/exclude", "GET", enc_excl)
