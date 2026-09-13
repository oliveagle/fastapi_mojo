# src/fastapi_mojo/enum_support.mojo
#
# ADR-0068: Enum support (FastAPI/Pydantic Enum equivalence)
#
# Upstream: https://fastapi.tiangolo.com/tutorial/pydantic/#enums
# Documentation: https://docs.pydantic.dev/latest/concepts/models_as_fields/
#
# In FastAPI, you can use Python's Enum class:
#   from enum import Enum
#   class Direction(Enum):
#       UP = "UP"
#       DOWN = "DOWN"
#   class Item(BaseModel):
#       direction: Direction
#
# Mojo implementation notes:
# - Mojo has no Enum type at this level.
# - We use declarative _enum_<name> keys in handler.data.
# - Format: "value1,value2,value3"
# - FFI diff = 0: pure Mojo, no Rust/C bridge changes.

from body_schema import parse_body_schema, field_count, get_field, FieldSpec
from router import Router
from handler import Handler, KIND_ECHO

# ---------- Enum Validation Error ----------

struct EnumValidationError:
    var field_name: String
    var invalid_value: String
    var allowed_values: String

    def __init__(out self, field: String, invalid: String, allowed: String):
        self.field_name = field
        self.invalid_value = invalid
        self.allowed_values = allowed

# ---------- Enum validation ----------

def join_list(lst: List[String], sep: String) -> String:
    var s = ""
    for i in range(len(lst)):
        if i > 0:
            s = s + sep
        s = s + lst[i]
    return s



def enum_validation_error_to_string(e: EnumValidationError) -> String:
    return e.field_name + ": invalid value " + e.invalid_value + ", allowed: " + e.allowed_values

def validate_enum_value(field_name: String, value: String, enum_values_csv: String) raises -> Bool:
    """Validate that value is in the enum list.
    
    Returns True if valid, raises EnumValidationError if not.
    """
    if enum_values_csv.byte_length() == 0:
        return True  # No enum constraint
    
    var parts = enum_values_csv.split(",")
    for part in parts:
        var p = String(part.strip())
        if p == value:
            return True
    var _err = EnumValidationError(    field_name, value, enum_values_csv)
    raise Error(enum_validation_error_to_string(_err))

def get_allowed_values(enum_values_csv: String) -> List[String]:
    """Return list of allowed enum values."""
    var out = List[String]()
    if enum_values_csv.byte_length() == 0:
        return out^
    var parts = enum_values_csv.split(",")
    for part in parts:
        var p = String(part.strip())
        if p.byte_length() > 0:
            out.append(p)
    return out^

def enum_error_to_422(e: EnumValidationError) -> Dict[String, String]:
    """Convert EnumValidationError to FastAPI 422 error format."""
    var error_dict = Dict[String, String]()
    var loc_list = List[String]()
    loc_list.append("body")
    loc_list.append(e.field_name)
    error_dict["loc"] = join_list(loc_list, ",")
    error_dict["msg"] = "Input should be " + e.allowed_values + ", invalid input was '" + e.invalid_value + "'"
    error_dict["type"] = "enum_invalid_value"
    return error_dict^

# ---------- Enum route registration ----------

def register_enum_routes(mut router: Router) raises:
    """Register demo routes for enum support (ADR-0068)."""
    
    # /enum/direction: demonstrate enum validation in query params
    var enum_dir = Handler(KIND_ECHO(), "enum_direction")
    enum_dir.set_data("message", "enum demo: direction")
    enum_dir.set_data("_param_types", "direction:str[UP,DOWN,LEFT,RIGHT]=UP")
    router.add_route("/enum/direction", "GET", enum_dir)
    
    # /enum/status: demonstrate enum in body
    var enum_status = Handler(KIND_ECHO(), "enum_status")
    enum_status.set_data("message", "enum demo: status")
    enum_status.set_data("_body_schema", "status:str[active,inactive,pending]=pending")
    router.add_route("/enum/status", "POST", enum_status)
    
    # /enum/priority: demonstrate enum with validation error
    var enum_prio = Handler(KIND_ECHO(), "enum_priority")
    enum_prio.set_data("message", "enum demo: priority")
    enum_prio.set_data("_body_schema", "priority:int[1,2,3,4,5]=3")
    router.add_route("/enum/priority", "POST", enum_prio)
