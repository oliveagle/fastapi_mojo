# src/fastapi_mojo/request_state_selftest.mojo
#
# 决策-50 (ADR-0025): request_state 纯逻辑自检 (mojo run — JIT 可达:
# main 只调纯函数 — apply/inject/validate (+ handler.mojo 的纯
# substitute_params), 不触 run_handler FFI 闭包, file_params_selftest 模式).

import std.os

from request_state import (validate_state_set, apply_state_set,
                           inject_request_state)


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    print("Testing request.state (决策-50, ADR-0025)...")

    # ---------- validate_state_set ----------
    check(validate_state_set(""), "empty spec ok")
    check(validate_state_set("user:alice"), "single entry")
    check(validate_state_set("user:alice;dept:eng"), "multi entry")
    check(validate_state_set("u:a:b"), "value keeps colons")
    check(not validate_state_set(":nokey"), "empty key rejected")
    check(not validate_state_set("noval"), "missing colon rejected")
    check(validate_state_set("a:b;;c:d"), "empty entry skipped (CSV convention)")
    check(validate_state_set("u:"), "empty value ok (key present)")

    # ---------- apply_state_set ----------
    var s1: Dict[String, String] = Dict[String, String]()
    apply_state_set(s1, "user:alice;dept:eng", Dict[String, String]())
    check(s1["user"] == "alice" and s1["dept"] == "eng" and len(s1) == 2,
          "apply static values")
    var s2: Dict[String, String] = Dict[String, String]()
    apply_state_set(s2, "u:a:b", Dict[String, String]())
    check(s2["u"] == "a:b", "apply value keeps colons")
    # {param} 插值
    var ctx: Dict[String, String] = Dict[String, String]()
    ctx["who"] = "bob"
    ctx["path"] = "/x"
    var s3: Dict[String, String] = Dict[String, String]()
    apply_state_set(s3, "user:{who};req:path:{path}", ctx)
    check(s3["user"] == "bob" and s3["req"] == "path:/x", "apply interpolation")
    # 缺失键保留字面量 (防静默填空)
    var s4: Dict[String, String] = Dict[String, String]()
    apply_state_set(s4, "user:{ghost}", ctx)
    check(s4["user"] == "{ghost}", "apply missing key keeps literal")
    # 空 spec no-op
    var s5: Dict[String, String] = Dict[String, String]()
    apply_state_set(s5, "", ctx)
    check(len(s5) == 0, "apply empty spec no-op")

    # ---------- inject_request_state ----------
    var st: Dict[String, String] = Dict[String, String]()
    st["user"] = "alice"
    st["dept"] = "eng"
    var p1: Dict[String, String] = Dict[String, String]()
    inject_request_state(p1, st, "user,dept")
    check(p1["state_user"] == "alice" and p1["state_dept"] == "eng",
          "inject present keys")
    var p2: Dict[String, String] = Dict[String, String]()
    inject_request_state(p2, st, "ghost")
    check(p2["state_ghost"] == "", "inject missing -> empty (F10 convention)")
    var p3: Dict[String, String] = Dict[String, String]()
    inject_request_state(p3, st, "user, ghost ,")
    check(p3["state_user"] == "alice" and p3["state_ghost"] == "",
          "inject trims + skips empty names")
    var p4: Dict[String, String] = Dict[String, String]()
    inject_request_state(p4, Dict[String, String](), "user")
    check(p4["state_user"] == "", "inject empty state -> empty")

    print("request_state self-test: all checks passed")
