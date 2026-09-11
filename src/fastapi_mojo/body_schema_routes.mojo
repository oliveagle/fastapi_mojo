# src/fastapi_mojo/body_schema_routes.mojo
#
# Decision-38/57/58/61 body-schema demo route registration.
# Keeping these declarations cohesive avoids further growing the server module.

from handler import Handler, KIND_ECHO
from router import Router


def register_body_schema_routes(mut router: Router) raises:
    """Register declarative JSON body validation demos."""
    var val_h = Handler(KIND_ECHO(), "validate_item")
    val_h.set_data("message", "validated item")
    val_h.set_data("_body_schema",
        "name:str;price:float|gt=0;quantity:int=10;mode:str[fast,slow]=fast;tags:str[]|items=0-5;meta:obj{city:str|len=2-6;zip:int=0}")
    router.add_route("/validate", "POST", val_h)

    var pat_h = Handler(KIND_ECHO(), "body_pat")
    pat_h.set_data("message", "body pattern demo")
    pat_h.set_data("_body_schema", "code:str|pat=^[a-z0-9]+$")
    router.add_route("/bs/pat", "POST", pat_h)

    var patch_h = Handler(KIND_ECHO(), "body_patch")
    patch_h.set_data("message", "patch body demo")
    patch_h.set_data("_body_schema", "note:str")
    router.add_route("/bs/patch", "PATCH", patch_h)

    var elem_h = Handler(KIND_ECHO(), "validate_elems")
    elem_h.set_data("message", "elem constraints demo")
    elem_h.set_data("_body_schema", "items:str[]|items=0-5,len=1-3,pat=^[a-z0-9]+$;nums:int[]|items=0-3,ge=0")
    router.add_route("/validate/elems", "POST", elem_h)

    # Decision-61: recursive object schema and object-array element schema.
    var nested_h = Handler(KIND_ECHO(), "validate_nested_schema")
    nested_h.set_data("message", "nested schema demo")
    nested_h.set_data("_body_schema",
        "root:str|len=3-12;models:obj[]{id:int|ge=1;tag:str|len=2-3}|items=1-2;profile:obj{email:str|pat=^[^@]+@[^@]+$;address:obj{city:str|len=2-40}}")
    router.add_route("/validate/nested", "POST", nested_h)
