# src/fastapi_mojo/field_validators.mojo
#
# ADR-0073: Field validators (Pydantic @validator equivalence)
#
# Upstream: Pydantic supports field validators via:
#   @validator('field_name')
#   def validate_field(cls, v):
#       if v < 0:
#           raise ValueError('must be positive')
#       return v
#
# Mojo implementation notes:
# - We use declarative _field_validator_<field> keys.
# - Format: "validator_name,arg1,arg2" or "custom:logic"
# - Supported validators: gt, ge, lt, le, positive, negative, not_empty, email, etc.
# - FFI diff = 0: pure Mojo.

from router import Router
from handler import Handler, KIND_ECHO

# ---------- Validation Error ----------

class FieldValidationError:
    field_name: String
    message: String
    validator_type: String

    init(field: String, msg: String, vtype: String):
        self.field_name = field
        self.message = msg
        self.validator_type = vtype

# ---------- Numeric Helpers ----------

def _try_f64(s: String) -> Float64 raises:
    """Parse string to Float64."""
    var n = s.byte_length()
    if n == 0:
        raise Error("empty value")
    var result = Float64(0)
    var sign = Float64(1)
    var i = 0
    var seen_dot = False
    
    if s[byte=0] == '-':
        sign = Float64(-1)
        i += 1
    elif s[byte=0] == '+':
        i += 1
    
    while i < n:
        var c = s[byte=i]
        if c >= '0' and c <= '9':
            var digit = Float64(ord(c) - ord('0'))
            if seen_dot:
                var place = Float64(1)
                for j in range(i - s.byte_length() + 1):
                    place *= Float64(10)
                result += sign * digit / place
            else:
                result = result * Float64(10) + digit
            i += 1
        elif c == '.' and not seen_dot:
            seen_dot = True
            i += 1
        else:
            raise Error("invalid character in float")
    
    return result^ + Float64(0)

# ---------- Validator implementations ----------

def _validate_gt(field: String, v: String, arg: String) raises -> String:
    var val = _try_f64(v)
    var min_val = _try_f64(arg)
    if val <= min_val:
        raise FieldValidationError(field, 
            "Input should be greater than " + arg,
            "greater_than")
    return v

def _validate_ge(field: String, v: String, arg: String) raises -> String:
    var val = _try_f64(v)
    var min_val = _try_f64(arg)
    if val < min_val:
        raise FieldValidationError(field,
            "Input should be greater than or equal to " + arg,
            "greater_than_or_equal")
    return v

def _validate_lt(field: String, v: String, arg: String) raises -> String:
    var val = _try_f64(v)
    var max_val = _try_f64(arg)
    if val >= max_val:
        raise FieldValidationError(field,
            "Input should be less than " + arg,
            "less_than")
    return v

def _validate_le(field: String, v: String, arg: String) raises -> String:
    var val = _try_f64(v)
    var max_val = _try_f64(arg)
    if val > max_val:
        raise FieldValidationError(field,
            "Input should be less than or equal to " + arg,
            "less_than_or_equal")
    return v

def _validate_positive(field: String, v: String) raises -> String:
    var val = _try_f64(v)
    if val <= Float64(0):
        raise FieldValidationError(field,
            "Input should be greater than 0",
            "gt_0")
    return v

def _validate_negative(field: String, v: String) raises -> String:
    var val = _try_f64(v)
    if val >= Float64(0):
        raise FieldValidationError(field,
            "Input should be less than 0",
            "lt_0")
    return v

def _validate_not_empty(field: String, v: String) raises -> String:
    if v.byte_length() == 0:
        raise FieldValidationError(field,
            "String should not be empty",
            "min_length")
    return v

def _validate_email(field: String, v: String) raises -> String:
    if v.find("@") < 0 or v.byte_length() < 5:
        raise FieldValidationError(field,
            "Value should be a valid email address",
            "email")
    return v

# ---------- Main validation function ----------

def run_field_validator(field_name: String, value: String, validator_spec: String) raises -> String:
    """Run a field validator and return the validated value.
    
    Raises FieldValidationError if validation fails.
    validator_spec format: "validator_type,arg1,arg2"
    e.g., "gt,10" means value must be > 10
    """
    var parts = validator_spec.split(",")
    var vtype = String(parts[0].strip())
    
    if vtype == "gt":
        if len(parts) > 1:
            return _validate_gt(field_name, value, parts[1])^
    elif vtype == "ge":
        if len(parts) > 1:
            return _validate_ge(field_name, value, parts[1])^
    elif vtype == "lt":
        if len(parts) > 1:
            return _validate_lt(field_name, value, parts[1])^
    elif vtype == "le":
        if len(parts) > 1:
            return _validate_le(field_name, value, parts[1])^
    elif vtype == "positive":
        return _validate_positive(field_name, value)^
    elif vtype == "negative":
        return _validate_negative(field_name, value)^
    elif vtype == "not_empty":
        return _validate_not_empty(field_name, value)^
    elif vtype == "email":
        return _validate_email(field_name, value)^
    
    return value  # Default: pass through

def validate_field(field_name: String, value: String, validator_spec: String) raises -> Bool:
    """Validate a field and return True if valid.
    
    Deprecated: Use run_field_validator instead.
    """
    var _ = run_field_validator(field_name, value, validator_spec)
    return True

def error_to_422(e: FieldValidationError) -> Dict[String, String]:
    """Convert error to FastAPI 422 format."""
    var error_dict = Dict[String, String]()
    var loc_list = List[String]()
    loc_list.append("body")
    loc_list.append(e.field_name)
    error_dict["loc"] = loc_list.join(",")
    error_dict["msg"] = e.message
    error_dict["type"] = e.validator_type
    return error_dict^

# ---------- Demo route registration ----------

def register_field_validator_routes(mut router: Router) raises:
    """Register demo routes for field validators (ADR-0073)."""
    
    # /field_validator/positive: demonstrate positive validation
    var fv_pos = Handler(KIND_ECHO(), "field_validator_positive")
    fv_pos.set_data("message", "field validator demo")
    fv_pos.set_data("_field_validator_amount", "positive")
    router.add_route("/field_validator/positive", "POST", fv_pos)
    
    # /field_validator/email: demonstrate email validation
    var fv_email = Handler(KIND_ECHO(), "field_validator_email")
    fv_email.set_data("message", "email field validator")
    fv_email.set_data("_field_validator_email", "email")
    router.add_route("/field_validator/email", "POST", fv_email)
    
    # /field_validator/range: demonstrate range validation
    var fv_range = Handler(KIND_ECHO(), "field_validator_range")
    fv_range.set_data("message", "range field validator")
    fv_range.set_data("_field_validator_score", "gt,0;le,100")
    router.add_route("/field_validator/range", "POST", fv_range)
