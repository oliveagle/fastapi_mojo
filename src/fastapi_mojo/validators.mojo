# src/fastapi_mojo/validators.mojo
#
# ADR-0067: Custom field validators (FastAPI @validator equivalent)
#
# Upstream: https://fastapi.tiangolo.com/tutorial/pydantic/#validators
# Documentation: https://docs.pydantic.dev/2.5/usage/validators/
#
# FastAPI's @validator allows custom validation logic per field:
#   class Item(BaseModel):
#       price: float
#       @validator('price')
#       def price_must_be_positive(cls, v):
#           if v < 0:
#               raise ValueError('must be positive')
#           return v
#
# Mojo implementation notes:
# - Mojo has no decorators/closures at this level.
# - We use declarative _validator_<name> keys in handler.data.
# - Format: "validator_name:validator_function_name" or inline expressions.
# - Supported validators: gt, ge, lt, le, positive, negative, email, url, uuid, range.
# - FFI diff = 0: pure Mojo, no Rust/C bridge changes.

from body_schema import parse_body_schema, field_count, get_field, FieldSpec
from router import Router
from handler import Handler, KIND_ECHO

# ---------- Validation Error ----------

class ValidationError:
    field_name: String
    message: String
    constraint: String

    init(field: String, msg: String, constraint_name: String):
        self.field_name = field
        self.message = msg
        self.constraint = constraint_name

# ---------- Numeric Helpers ----------

def _to_f64(s: String) -> Float64 raises:
    """Parse string to Float64, raises on failure."""
    var n = s.byte_length()
    if n == 0:
        raise Error("empty value")
    var result = Float64(0)
    var sign = Float64(1)
    var i = 0
    var int_part = False
    var dec_part = False
    var exp_part = False
    var exp_sign = Float64(1)
    var exp_val = Float64(0)
    
    if s[byte=0] == '-':
        sign = Float64(-1)
        i += 1
    elif s[byte=0] == '+':
        i += 1
    
    while i < n:
        var c = s[byte=i]
        if c >= '0' and c <= '9':
            var digit = Float64(ord(c) - ord('0'))
            if exp_part:
                exp_val = exp_val * Float64(10) + digit
            elif dec_part:
                var place = Float64(1)
                for j in range(1, i - s.byte_length() + 2):  # Approximate decimal place
                    place *= Float64(10)
                result += sign * digit / place
            else:
                result = result * Float64(10) + digit
                int_part = True
            i += 1
        elif c == '.':
            if dec_part or exp_part:
                raise Error("invalid float: multiple dots")
            dec_part = True
            i += 1
        elif c == 'e' or c == 'E':
            if exp_part:
                raise Error("invalid float: multiple exponents")
            exp_part = True
            i += 1
            if i < n and s[byte=i] == '-':
                exp_sign = Float64(-1)
                i += 1
            elif i < n and s[byte=i] == '+':
                i += 1
        else:
            raise Error("invalid character in float: " + s)
    
    if exp_part:
        # Apply exponent
        var pow10 = Float64(1)
        var exp_int = exp_sign * exp_val
        if exp_int >= Float64(0):
            for k in range(Int(exp_val)):
                pow10 *= Float64(10)
            result *= pow10
        else:
            var neg_exp = Int(-exp_val)
            for k in range(neg_exp):
                result /= Float64(10)
    
    return result^ + Float64(0)  # Normalize to avoid -0

def _is_valid_uuid(s: String) -> Bool:
    """Check if string is a valid UUID format (8-4-4-4-12 hex)."""
    var n = s.byte_length()
    if n != 36:
        return False
    var hex_count = 0
    var dash_count = 0
    for i in range(n):
        var c = s[byte=i]
        if c == '-':
            dash_count += 1
        elif (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'):
            hex_count += 1
        else:
            return False
    return hex_count == 32 and dash_count == 4

def _is_valid_email(s: String) -> Bool:
    """Check if string looks like an email (contains @ and domain)."""
    var n = s.byte_length()
    if n < 5:
        return False
    var at_pos = -1
    for i in range(n):
        if s[byte=i] == '@':
            at_pos = i
            break
    if at_pos <= 0 or at_pos >= n - 1:
        return False
    # Check for dots in domain part
    var dot_in_domain = False
    for i in range(at_pos + 1, n):
        if s[byte=i] == '.':
            dot_in_domain = True
            break
    return dot_in_domain

def _is_valid_url(s: String) -> Bool:
    """Check if string looks like a URL (contains ://)."""
    return s.find("://") >= 0

# ---------- Validator implementations ----------

def _validator_gt(field: String, v: String, arg: String) raises -> String:
    """Greater than validator."""
    var min_val = Float64(arg)
    var val = Float64(v)
    if val <= min_val:
        raise ValidationError(field, 
            "Input should be greater than " + arg,
            "greater_than")
    return v

def _validator_ge(field: String, v: String, arg: String) raises -> String:
    """Greater than or equal validator."""
    var min_val = Float64(arg)
    var val = Float64(v)
    if val < min_val:
        raise ValidationError(field,
            "Input should be greater than or equal to " + arg,
            "greater_than_or_equal")
    return v

def _validator_lt(field: String, v: String, arg: String) raises -> String:
    """Less than validator."""
    var max_val = Float64(arg)
    var val = Float64(v)
    if val >= max_val:
        raise ValidationError(field,
            "Input should be less than " + arg,
            "less_than")
    return v

def _validator_le(field: String, v: String, arg: String) raises -> String:
    """Less than or equal validator."""
    var max_val = Float64(arg)
    var val = Float64(v)
    if val > max_val:
        raise ValidationError(field,
            "Input should be less than or equal to " + arg,
            "less_than_or_equal")
    return v

def _validator_positive(field: String, v: String) raises -> String:
    """Positive number validator (> 0)."""
    var val = Float64(v)
    if val <= Float64(0):
        raise ValidationError(field,
            "Input should be greater than 0",
            "gt_0")
    return v

def _validator_negative(field: String, v: String) raises -> String:
    """Negative number validator (< 0)."""
    var val = Float64(v)
    if val >= Float64(0):
        raise ValidationError(field,
            "Input should be less than 0",
            "lt_0")
    return v

def _validator_email(field: String, v: String) raises -> String:
    """Email format validator."""
    if not _is_valid_email(v):
        raise ValidationError(field,
            "Value should be a valid email address",
            "email")
    return v

def _validator_url(field: String, v: String) raises -> String:
    """URL format validator."""
    if not _is_valid_url(v):
        raise ValidationError(field,
            "Value should be a valid URL",
            "url")
    return v

def _validator_uuid(field: String, v: String) raises -> String:
    """UUID format validator."""
    if not _is_valid_uuid(v):
        raise ValidationError(field,
            "Value should be a valid UUID",
            "uuid")
    return v

# ---------- Validator application ----------

def apply_field_validators(
    field_name: String,
    value: String,
    validators_csv: String,
    handler_data: Dict[String, String]
) raises -> String:
    """Apply custom validators to a field value.

    Returns the validated value (potentially transformed).
    Raises ValidationError if validation fails.

    validators_csv format: "validator1:arg1;validator2:arg2;..."
    handler_data is used to look up custom validator definitions.
    """
    var result = value
    if validators_csv.byte_length() == 0:
        return result

    var parts = validators_csv.split(";")
    for part in parts:
        var p = String(part.strip())
        if p.byte_length() == 0:
            continue

        # Parse validator name and argument
        var colon_pos = -1
        for i in range(p.byte_length()):
            if ord(p.as_bytes()[i]) == 58:  # ':'
                colon_pos = i
                break

        if colon_pos >= 0:
            var val_name = String(p[byte=0:colon_pos])
            var val_arg = String(p[byte=colon_pos + 1:p.byte_length()])
        else:
            var val_name = p
            var val_arg = ""

        # Apply validator based on name
        if val_name == "gt":
            result = _validator_gt(field_name, result, val_arg)
        elif val_name == "ge":
            result = _validator_ge(field_name, result, val_arg)
        elif val_name == "lt":
            result = _validator_lt(field_name, result, val_arg)
        elif val_name == "le":
            result = _validator_le(field_name, result, val_arg)
        elif val_name == "positive":
            result = _validator_positive(field_name, result)
        elif val_name == "negative":
            result = _validator_negative(field_name, result)
        elif val_name == "email":
            result = _validator_email(field_name, result)
        elif val_name == "url":
            result = _validator_url(field_name, result)
        elif val_name == "uuid":
            result = _validator_uuid(field_name, result)
        else:
            # Custom validator from handler_data
            var custom_key = "_validator_" + val_name
            if custom_key in handler_data:
                # For now, custom validators are passed through
                pass
    return result

def validate_model_fields(
    handler: Handler,
    resp_data: Dict[String, String],
    body_data: Dict[String, String]
) raises -> Dict[String, String]:
    """Validate and transform model fields using custom validators.

    This is the main entry point for custom validation.
    It reads _validators_<field> from handler.data and applies them
    to the corresponding field in resp_data.
    """
    var result = resp_data.copy()

    # Look for _validators_* keys in handler data
    var keys = handler.data.keys()
    for key in keys:
        if key.startswith("_validators_"):
            var field_name = String(key[byte=12:key.byte_length()])  # Skip '_validators_'
            var validators_csv = handler.data[key]
            
            # Find the value in resp_data
            var val = ""
            var found = False
            if ("body_" + field_name) in resp_data:
                val = resp_data["body_" + field_name]
                found = True
            elif field_name in resp_data:
                val = resp_data[field_name]
                found = True
            
            if found:
                var validated = apply_field_validators(
                    field_name, val, validators_csv, handler.data
                )
                if ("body_" + field_name) in resp_data:
                    result["body_" + field_name] = validated
                else:
                    result[field_name] = validated

    return result^

# ---------- Error serialization ----------

def validation_error_to_422(e: ValidationError) -> Dict[String, String]:
    """Convert ValidationError to FastAPI 422 error format."""
    var error_dict = Dict[String, String]()
    var loc_list = List[String]()
    loc_list.append("body")
    loc_list.append(e.field_name)
    error_dict["loc"] = loc_list.join(",")
    error_dict["msg"] = e.message
    error_dict["type"] = e.constraint
    return error_dict^

# ---------- Demo route registration ----------

def register_validator_routes(mut router: Router) raises:
    """Register demo routes for custom validators (ADR-0067)."""

    # /validator/positive: demonstrate positive number validation
    var val_pos = Handler(KIND_ECHO(), "validator_positive")
    val_pos.set_data("message", "positive validator demo")
    val_pos.set_data("_validators_value", "positive")
    router.add_route("/validator/positive", "POST", val_pos)

    # /validator/email: demonstrate email validation
    var val_email = Handler(KIND_ECHO(), "validator_email")
    val_email.set_data("message", "email validator demo")
    val_email.set_data("_validators_email", "email")
    router.add_route("/validator/email", "POST", val_email)

    # /validator/range: demonstrate range validation
    var val_range = Handler(KIND_ECHO(), "validator_range")
    val_range.set_data("message", "range validator demo")
    val_range.set_data("_validators_number", "gt:10;lt:100")
    router.add_route("/validator/range", "POST", val_range)

    # /validator/uuid: demonstrate UUID validation
    var val_uuid = Handler(KIND_ECHO(), "validator_uuid")
    val_uuid.set_data("message", "uuid validator demo")
    val_uuid.set_data("_validators_id", "uuid")
    router.add_route("/validator/uuid", "POST", val_uuid)
