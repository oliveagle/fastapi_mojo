# src/fastapi_mojo/root_validators.mojo
#
# ADR-0074: Root validators (Pydantic @root_validator equivalence)
#
# Upstream: Pydantic supports root validators via:
#   @root_validator(pre=True)
#   def validate_model(cls, values):
#       if values.get('a') == values.get('b'):
#           raise ValueError('a and b must be different')
#       return values
#
# Mojo implementation notes:
# - We use declarative _root_validator keys.
# - Format: "validator_name,field1,field2" or "custom:logic"
# - FFI diff = 0: pure Mojo.

from router import Router
from handler import Handler, KIND_ECHO

def run_root_validator(field_data: Dict[String, String], validator_spec: String) raises -> Bool:
    """Run a root validator on the model fields.
    
    validator_spec format: "validator_name,arg1,arg2"
    Returns True if valid, False otherwise.
    """
    var parts = validator_spec.split(",")
    var vtype = String(parts[0].strip())
    
    if vtype == "all_required":
        # All specified fields must be present
        for i in range(1, len(parts)):
            var fname = String(parts[i].strip())
            if fname not in field_data:
                return False
        return True
    
    if vtype == "at_least_one":
        # At least one field must be present
        var found = False
        for i in range(1, len(parts)):
            var fname = String(parts[i].strip())
            if fname in field_data:
                found = True
                break
        return found
    
    if vtype == "mutually_exclusive":
        # Only one field can be present
        var count = 0
        for i in range(1, len(parts)):
            var fname = String(parts[i].strip())
            if fname in field_data:
                count += 1
        return count <= 1
    
    return True  # Default: pass

def register_root_validator_routes(mut router: Router) raises:
    """Register demo routes for root validators (ADR-0074)."""
    
    # /root_validator/at_least_one: demonstrate at least one required
    var rv_one = Handler(KIND_ECHO(), "root_validator_at_least_one")
    rv_one.set_data("message", "root validator demo")
    rv_one.set_data("_root_validator", "at_least_one,username,email")
    router.add_route("/root_validator/at_least_one", "POST", rv_one)
    
    # /root_validator/mutually_exclusive: demonstrate mutual exclusion
    var rv_excl = Handler(KIND_ECHO(), "root_validator_mutually_exclusive")
    rv_excl.set_data("message", "mutual exclusion demo")
    rv_excl.set_data("_root_validator", "mutually_exclusive,api_key,oauth_token")
    router.add_route("/root_validator/mutually_exclusive", "POST", rv_excl)
"