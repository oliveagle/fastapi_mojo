# src/fastapi_mojo/custom_serializers.mojo
#
# ADR-0072: Custom serializers (FastAPI/pydantic custom encoders)
#
# Upstream: Pydantic supports custom serializers via:
#   @serializer('field_name')
#   def serialize_field(self, value):
#       return str(value).upper()
#
# Mojo implementation notes:
# - We use declarative _serializer_<field> keys.
# - Format: "serializer_name" or "custom:value_transform"
# - FFI diff = 0: pure Mojo.

from router import Router
from handler import Handler, KIND_ECHO

def apply_serializer(value: String, serializer_type: String) raises -> String:
    """Apply a custom serializer to a value."""
    if serializer_type == "upper":
        return value.upper()
    elif serializer_type == "lower":
        return value.lower()
    elif serializer_type == "reverse":
        var result = ""
        for i in range(value.byte_length() - 1, -1, -1):
            result += value[i]
        return result
    return value

def register_serializer_routes(mut router: Router) raises:
    """Register demo routes for custom serializers (ADR-0072)."""
    
    # /serializer/upper: demonstrate upper case serializer
    var ser_upper = Handler(KIND_ECHO(), "serializer_upper")
    ser_upper.set_data("message", "hello world")
    ser_upper.set_data("_serializer_message", "upper")
    router.add_route("/serializer/upper", "GET", ser_upper)
    
    # /serializer/reverse: demonstrate reverse serializer
    var ser_rev = Handler(KIND_ECHO(), "serializer_reverse")
    ser_rev.set_data("message", "hello")
    ser_rev.set_data("_serializer_message", "reverse")
    router.add_route("/serializer/reverse", "GET", ser_rev)
