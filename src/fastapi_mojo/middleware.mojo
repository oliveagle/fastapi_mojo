# src/fastapi_mojo/middleware.mojo
#
# Middleware system for HTTP server


struct Middleware:
    """Middleware definition."""
    var name: String
    var enabled: Bool

    def __init__(out self, name: String):
        self.name = name
        self.enabled = True

    def __init__(out self, name: String, enabled: Bool):
        self.name = name
        self.enabled = enabled
