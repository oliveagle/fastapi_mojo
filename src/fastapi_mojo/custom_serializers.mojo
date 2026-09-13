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

struct CustomSerializerError:
    var field_name: String
    var message: String

    def __init__(out self, field: String, msg: String):
        self.field_name = field
        self.message = msg


def custom_serializer_error_to_string(e: CustomSerializerError) -> String:
    return e.field_name + ": " + e.message

def apply_serializer(value: String, serializer_type: String, field_name: String) raises -> String:
    """Apply a custom serializer to a value.
    
    Supports:
    - upper: Convert to uppercase
    - lower: Convert to lowercase
    - reverse: Reverse string
    - trim: Remove whitespace from ends
    - capitalize: Capitalize first letter
    - base64: Encode to base64 (simplified)
    """
    if serializer_type == "upper":
        return value.upper()^
    elif serializer_type == "lower":
        return value.lower()^
    elif serializer_type == "reverse":
        var result = ""
        for i in range(value.byte_length() - 1, -1, -1):
            result += value[byte=i:i+1]
        return result^
    elif serializer_type == "trim":
        # Remove leading/trailing whitespace
        var start = 0
        var end = value.byte_length()
        while start < end and value[byte=start] == " ":  # ASCII space is 32
            start += 1
        while end > start and value[byte=end - 1] == " ":
            end -= 1
        return String(value[byte=start:end])^
    elif serializer_type == "capitalize":
        if value.byte_length() == 0:
            return value
        var first_upper = String(value[byte=0:1]).upper()
        var rest = String(value[byte=1:value.byte_length()])
        return first_upper + rest^
    elif serializer_type == "base64":
        # Simplified base64-like encoding (not standard base64)
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        var result = ""
        for i in range(value.byte_length()):
            var c = value[byte=i]
            # Get index by comparing single char string to table
            var idx = 0
            for j in range(chars.byte_length()):
                if c == chars[byte=j:j+1]:
                    idx = j
                    break
            result += String(chars[byte=idx:idx+1])
        return result^
    
    var _err = CustomSerializerError(field_name, "Unknown serializer: " + serializer_type)
    raise Error(custom_serializer_error_to_string(_err))

def apply_serializers_to_data(
    data: Dict[String, String],
    handlers_data: Dict[String, String]
) raises -> Dict[String, String]:
    """Apply custom serializers to data fields.
    
    Looks for _serializer_<field> keys in handlers_data.
    """
    var result = Dict[String, String]()
    
    for key in data.keys():
        result[key] = data[key]
    
    # Look for serializer declarations
    for key in handlers_data.keys():
        if key.startswith("_serializer_"):
            var field_name = String(key[byte=12:key.byte_length()])  # Skip '_serializer_'
            var serializer_type = handlers_data[key]
            
            if field_name in data:
                var original = data[field_name]
                var serialized = apply_serializer(original, serializer_type, field_name)
                result[field_name] = serialized
    
    return result^

def error_to_422(e: CustomSerializerError) -> Dict[String, String]:
    """Convert error to FastAPI 422 format."""
    var error_dict = Dict[String, String]()
    error_dict["loc"] = e.field_name
    error_dict["msg"] = e.message
    error_dict["type"] = "value_error"
    return error_dict^

def register_serializer_routes(mut router: Router) raises:
    """Register demo routes for custom serializers (ADR-0072)."""
    
    # /serializer/upper: demonstrate upper case serializer
    var ser_upper = Handler(KIND_ECHO(), "serializer_upper")
    ser_upper.set_data("message", "hello world")
    ser_upper.set_data("_serializer_message", "upper")
    router.add_route("/serializer/upper", "GET", ser_upper)
    
    # /serializer/lower: demonstrate lower case serializer
    var ser_lower = Handler(KIND_ECHO(), "serializer_lower")
    ser_lower.set_data("message", "HELLO WORLD")
    ser_lower.set_data("_serializer_message", "lower")
    router.add_route("/serializer/lower", "GET", ser_lower)
    
    # /serializer/capitalize: demonstrate capitalize serializer
    var ser_cap = Handler(KIND_ECHO(), "serializer_capitalize")
    ser_cap.set_data("message", "hello world")
    ser_cap.set_data("_serializer_message", "capitalize")
    router.add_route("/serializer/capitalize", "GET", ser_cap)
    
    # /serializer/reverse: demonstrate reverse serializer
    var ser_rev = Handler(KIND_ECHO(), "serializer_reverse")
    ser_rev.set_data("message", "hello")
    ser_rev.set_data("_serializer_message", "reverse")
    router.add_route("/serializer/reverse", "GET", ser_rev)
