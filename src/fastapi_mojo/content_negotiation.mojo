# src/fastapi_mojo/content_negotiation.mojo
#
# ADR-0070: Content-Type negotiation (FastAPI response format selection)
#
# Upstream: FastAPI supports returning different formats based on Accept header
#           or using different response classes.
#
# Implementation notes:
# - Mojo has no built-in content negotiation.
# - We implement declarative _content_types_<path> mapping.
# - Format: "accept1:type1;accept2:type2;..."
# - FFI diff = 0: pure Mojo.

from router import Router
from handler import Handler, KIND_ECHO

def get_best_content_type(accept_header: String, supported_types: String) raises -> String:
    """Determine best content type from Accept header.
    
    supported_types format: "application/json;text/plain;application/xml"
    """
    if accept_header.byte_length() == 0:
        return "application/json"  # Default
    
    # Simple implementation: check if supported types are in accept header
    var parts = supported_types.split(";")
    for part in parts:
        var ct = String(part.strip())
        if accept_header.find(ct) >= 0:
            return ct
    return supported_types.split(";")[0]  # Return first supported

def register_negotiation_routes(mut router: Router) raises:
    """Register demo routes for content negotiation (ADR-0070)."""
    
    # /negotiation/data: demonstrate content-type based response
    var neg_data = Handler(KIND_ECHO(), "negotiation_data")
    neg_data.set_data("message", "content negotiation demo")
    neg_data.set_data("_content_types", "application/json:text/plain")
    router.add_route("/negotiation/data", "GET", neg_data)
