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

# ---------- Dataclass helpers ----------

def create_dataclass_from_schema(schema_str: String) raises -> Dict[String, String]:
    """Create a dataclass-like structure from schema string.
    
    Schema format: "field1:type1;field2:type2;..."
    Returns a dict mapping field names to types.
    """
    var result = Dict[String, String]()
    if schema_str.byte_length() == 0:
        return result
    
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

def register_dataclass_routes(mut router: Router) raises:
    """Register demo routes for dataclass support (ADR-0069)."""
    
    # /dataclass/item: demonstrate dataclass validation
    var dc_item = Handler(KIND_ECHO(), "dataclass_item")
    dc_item.set_data("message", "dataclass demo: item")
    dc_item.set_data("_body_schema", "name:str;price:float;tax:float=0.0")
    dc_item.set_data("_dataclass", "true")
    router.add_route("/dataclass/item", "POST", dc_item)
