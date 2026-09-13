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

struct ResponseType:
    var name: String
    var content_type: String
    var is_json: Bool
    var needs_json_escape: Bool

    def __init__(out self, name: String, ct: String, json: Bool, escape: Bool):
        self.name = name
        self.content_type = ct
        self.is_json = json
        self.needs_json_escape = escape

def get_response_type_from_handler(handler: Handler) raises -> ResponseType:
    """Get response type from handler data."""
    if "_response_type" not in handler.data:
        return ResponseType("json", "application/json", True, True)^
    
    var rt = handler.data["_response_type"]
    
    if rt == "text":
        return ResponseType("text", "text/plain", False, False)^
    elif rt == "html":
        return ResponseType("html", "text/html", False, False)^
    elif rt == "xml":
        return ResponseType("xml", "application/xml", False, False)^
    elif rt == "csv":
        return ResponseType("csv", "text/csv", False, False)^
    elif rt == "redirect":
        return ResponseType("redirect", "text/html", False, False)^
    elif rt == "file":
        return ResponseType("file", "application/octet-stream", False, False)^
    else:
        return ResponseType("json", "application/json", True, True)^

def get_content_type(response_type: String) raises -> String:
    """Get Content-Type header value for a response type."""
    if response_type == "text":
        return "text/plain"
    elif response_type == "html":
        return "text/html"
    elif response_type == "xml":
        return "application/xml"
    elif response_type == "csv":
        return "text/csv"
    else:
        return "application/json"

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
    
    # /response/html: HTMLResponse
    var resp_html = Handler(KIND_ECHO(), "response_html")
    resp_html.set_data("message", "<html><body><h1>Hello</h1></body></html>")
    resp_html.set_data("_response_type", "html")
    router.add_route("/response/html", "GET", resp_html)
    
    # /response/csv: CSVResponse
    var resp_csv = Handler(KIND_ECHO(), "response_csv")
    resp_csv.set_data("message", "name,age\nnickname,30\njohn,25")
    resp_csv.set_data("_response_type", "csv")
    router.add_route("/response/csv", "GET", resp_csv)
