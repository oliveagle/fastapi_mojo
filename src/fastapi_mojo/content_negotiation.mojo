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

def parse_accept_header(accept_header: String) raises -> List[Tuple[String, Float64]]:
    """Parse Accept header into list of (type, q_value) tuples.
    
    Format: type1;q=0.9,type2;q=0.8
    Returns sorted list with highest priority first.
    """
    var result = List[Tuple[String, Float64]]()
    
    if accept_header.byte_length() == 0:
        result.append(("*/*", Float64(1.0)))
        return result^
    
    var parts = accept_header.split(",")
    for part in parts:
        var p = String(part.strip())
        var q_value = Float64(1.0)
        var type_str = p
        
        # Check for q parameter
        var semicolon_pos = p.find(";")
        if semicolon_pos >= 0:
            type_str = String(p[byte=0:semicolon_pos]).strip()
            var params = String(p[byte:semicolon_pos + 1:p.byte_length()])
            var param_parts = params.split(";")
            for pp in param_parts:
                var param = String(pp.strip())
                if param.startswith("q="):
                    var q_str = String(param[byte=2:param.byte_length()])
                    q_value = Float64(q_str)
        
        if type_str.byte_length() > 0:
            result.append((type_str, q_value))
    
    # Sort by q value (descending)
    # Simple bubble sort for small lists
    var n = len(result)
    for i in range(n):
        for j in range(i + 1, n):
            if result[j][1] > result[i][1]:
                var tmp = result[i]^
                result[i] = result[j]^
                result[j] = tmp^
    
    return result^

def get_best_content_type(accept_header: String, supported_types: String) raises -> String:
    """Determine best content type from Accept header.
    
    supported_types format: "application/json;text/plain;application/xml"
    Returns the first supported type that matches the Accept header.
    """
    if accept_header.byte_length() == 0:
        return "application/json"  # Default
    
    var accepted = parse_accept_header(accept_header)
    var supported = supported_types.split(";")
    
    for acc_type, q in accepted:
        for sup_type in supported:
            var st = String(sup_type.strip())
            if acc_type == "*/*" or acc_type == st:
                return st
    
    return supported[0]  # Return first supported as fallback

def register_negotiation_routes(mut router: Router) raises:
    """Register demo routes for content negotiation (ADR-0070)."""
    
    # /negotiation/data: demonstrate content-type based response
    var neg_data = Handler(KIND_ECHO(), "negotiation_data")
    neg_data.set_data("message", "content negotiation demo")
    neg_data.set_data("_content_types", "application/json:text/plain:application/xml")
    router.add_route("/negotiation/data", "GET", neg_data)
    
    # /negotiation/api: demonstrate API content types
    var neg_api = Handler(KIND_ECHO(), "negotiation_api")
    neg_api.set_data("message", "API data")
    neg_api.set_data("_content_types", "application/json:application/x-ndjson")
    router.add_route("/negotiation/api", "GET", neg_api)
