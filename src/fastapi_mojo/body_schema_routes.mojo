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

    # Decision-82 (ADR-0057): pydantic lax model cross-JSON-type coercion demo.
    var cross_h = Handler(KIND_ECHO(), "validate_cross")
    cross_h.set_data("message", "cross-type demo")
    cross_h.set_data("_body_schema", "i:int;f:float;b:bool")
    router.add_route("/validate/cross", "POST", cross_h)

    var cross_arr_h = Handler(KIND_ECHO(), "validate_cross_arr")
    cross_arr_h.set_data("message", "cross-type array demo")
    cross_arr_h.set_data("_body_schema", "is:int[];fs:float[];bs:bool[]")
    router.add_route("/validate/cross-arr", "POST", cross_arr_h)

    # Decision-83 (ADR-0058): 422 detail 对齐 demo (ctx / multiple_of / 字符计数 / plural).
    var detail_h = Handler(KIND_ECHO(), "validate_detail")
    detail_h.set_data("message", "detail parity demo")
    detail_h.set_data("_body_schema", "s:str|len=2-4;n:int|ge=10,mo=3;f:float|mo=0.5;xs:int[]|items=1-2,mo=2;mode:str[fast,slow]")
    router.add_route("/bs/detail", "POST", detail_h)

    # Decision-86 (ADR-0061): Body(embed=True) — 单 body 模型包裹在 <embed_key> 下.
    var embed_h = Handler(KIND_ECHO(), "validate_embed")
    embed_h.set_data("message", "embed body demo")
    embed_h.set_data("_body_schema", "name:str;price:float")
    embed_h.set_data("_body_embed", "item")
    router.add_route("/validate/embed", "POST", embed_h)
