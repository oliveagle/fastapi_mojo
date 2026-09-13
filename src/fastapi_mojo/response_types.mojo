# src/fastapi_mojo/response_types.mojo
#
# ADR-0071: Response class variants (PlainTextResponse, XMLResponse, etc.)
#
# Upstream: FastAPI supports different response types:
#   - JSONResponse (default)
#   - HTMLResponse
#   - PlainTextResponse
#   - XMLResponse
#   - RedirectResponse
#   - FileResponse
#   - StreamingResponse
#
# Mojo implementation notes:
# - We use declarative _response_type keys to select response format.
# - FFI diff = 0: pure Mojo.

from router import Router
from handler import Handler, KIND_ECHO

def get_response_type_from_handler(handler: Handler) raises -> String:
    """Get response type from handler data."""
    if "_response_type" in handler.data:
        return handler.data["_response_type"]
    return "json"  # Default

def register_response_type_routes(mut router: Router) raises:
    """Register demo routes for different response types (ADR-0071)."""
    
    # /response/text: PlainTextResponse
    var resp_text = Handler(KIND_ECHO(), "response_text")
    resp_text.set_data("message", "This is plain text")
    resp_text.set_data("_response_type", "text")
    router.add_route("/response/text", "GET", resp_text)
    
    # /response/xml: XMLResponse
    var resp_xml = Handler(KIND_ECHO(), "response_xml")
    resp_xml.set_data("message", "<root><msg>Hello</msg></root>")
    resp_xml.set_data("_response_type", "xml")
    router.add_route("/response/xml", "GET", resp_xml)
