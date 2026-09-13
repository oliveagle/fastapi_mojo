# src/fastapi_mojo/dataclass_support.mojo
#
# ADR-0069: Dataclass support (FastAPI/Pydantic dataclass equivalence)
#
# Upstream: https://fastapi.tiangolo.com/tutorial/dataclasses/
# Documentation: https://docs.pydantic.dev/latest/concepts/dataclasses/
#
# In FastAPI, you can use Python's dataclasses:
#   from dataclasses import dataclass
#   @dataclass
#   class Item:
#       name: str
#       price: float
#
# Mojo implementation notes:
# - Mojo has no dataclass decorator at this level.
# - We use declarative _dataclass_<name> keys in handler.data.
# - Format: "field1:type1;field2:type2;..." or reuse _body_schema
# - FFI diff = 0: pure Mojo, no Rust/C bridge changes.

from body_schema import parse_body_schema, field_count, get_field, FieldSpec
from router import Router
from handler import Handler, KIND_ECHO

# ---------- Dataclass Validation Error ----------

struct DataclassValidationError:
    var field_name: String
    var message: String

    def __init__(out self, field: String, msg: String):
        self.field_name = field
        self.message = msg

# ---------- Dataclass helpers ----------

def join_list(lst: List[String], sep: String) -> String:
    var s = ""
    for i in range(len(lst)):
        if i > 0:
            s = s + sep
        s = s + lst[i]
    return s



def dataclass_validation_error_to_string(e: DataclassValidationError) -> String:
    return e.field_name + ": " + e.message

def create_dataclass_from_schema(schema_str: String) raises -> Dict[String, String]:
    """Create a dataclass-like structure from schema string.
    
    Schema format: "field1:type1;field2:type2;..."
    Returns a dict mapping field names to types.
    """
    var result = Dict[String, String]()
    if schema_str.byte_length() == 0:
        return result^
    
    var parts = schema_str.split(";")
    for part in parts:
        var p = String(part.strip())
        if p.byte_length() == 0:
            continue
        
        # Find last colon to split name from type
        var colon_pos = -1
        for i in range(p.byte_length()):
            if ord(p[byte=i]) == 58:  # ':'
                colon_pos = i
        
        if colon_pos >= 0:
            var name = String(p[byte=0:colon_pos])
            var type_name = String(p[byte=colon_pos + 1:p.byte_length()])
            result[name] = type_name
    
    return result^

def validate_dataclass_fields(
    handler: Handler,
    data: Dict[String, String],
    schema_str: String
) raises -> Dict[String, String]:
    """Validate fields against dataclass schema.
    
    Checks that all required fields are present.
    Raises DataclassValidationError if validation fails.
    """
    var spec = create_dataclass_from_schema(schema_str)
    var result = Dict[String, String]()
    
    for fname in spec.keys():
        if fname not in data:
            var _err = DataclassValidationError(            fname, "Field is required")
            raise Error(dataclass_validation_error_to_string(_err))
        result[fname] = data[fname]
    
    return result^

def error_to_422(e: DataclassValidationError) -> Dict[String, String]:
    """Convert error to FastAPI 422 format."""
    var error_dict = Dict[String, String]()
    var loc_list = List[String]()
    loc_list.append("body")
    loc_list.append(e.field_name)
    error_dict["loc"] = join_list(loc_list, ",")
    error_dict["msg"] = e.message
    error_dict["type"] = "missing" if e.message == "Field is required" else "value_error"
    return error_dict^

def register_dataclass_routes(mut router: Router) raises:
    """Register demo routes for dataclass support (ADR-0069)."""
    
    # /dataclass/item: demonstrate dataclass validation
    var dc_item = Handler(KIND_ECHO(), "dataclass_item")
    dc_item.set_data("message", "dataclass demo: item")
    dc_item.set_data("_body_schema", "name:str;price:float;tax:float=0.0")
    dc_item.set_data("_dataclass", "true")
    router.add_route("/dataclass/item", "POST", dc_item)
    
    # /dataclass/user: demonstrate dataclass with required fields
    var dc_user = Handler(KIND_ECHO(), "dataclass_user")
    dc_user.set_data("message", "dataclass demo: user")
    dc_user.set_data("_body_schema", "username:str;email:str;age:int")
    dc_user.set_data("_dataclass", "true")
    router.add_route("/dataclass/user", "POST", dc_user)
