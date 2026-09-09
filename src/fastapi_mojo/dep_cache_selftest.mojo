# src/fastapi_mojo/dep_cache_selftest.mojo
#
# 决策-47 (ADR-0022): dep_cache 纯数据层自检 (mojo run — JIT 可达, 零 FFI).
# memo 语义映射上游 0.141.1 probe P9-1..P9-5 (菱形/nocache/嵌套 nocache 覆写入库).

import std.os

from dep_cache import DepCache, inject_dep_calls


def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def main() raises:
    # P9-1: 菱形 cached — 首次派发入库, 二次引用命中 (1 条 memo, calls=1)
    var c1 = DepCache()
    c1.append("tick", ["tick"], ["TICK"])
    var i1 = c1.find("tick")
    check(i1 == 0, "P9-1 find")
    var t1 = Dict[String, String]()
    c1.inject("tick", i1, t1)
    check(t1["tick_tick"] == "TICK", "P9-1 inject value")
    check(c1.calls_of("tick") == 1, "P9-1 calls=1")
    check(c1.find("nope") == -1, "P9-1 find miss")

    # P9-3: nocache 派发覆写式入库 (追加新条) — 后续 cached 引用取最新条
    var c2 = DepCache()
    c2.append("s3", ["v"], ["s3-1"])
    c2.append("s3", ["v"], ["s3-2"])  # nocache re-dispatch -> 新条
    var i2 = c2.find("s3")
    check(i2 == 1, "P9-3 find = latest entry")
    var t2 = Dict[String, String]()
    c2.inject("s3", i2, t2)
    check(t2["s3_v"] == "s3-2", "P9-3 cached ref consumes latest value")
    check(c2.calls_of("s3") == 2, "P9-3 calls=2")

    # P9-2: 多 dep 独立 memo (auth + tick 各 1 条, 注入前缀独立)
    var c3 = DepCache()
    c3.append("auth", ["user", "tick_tick"], ["u1", "TICK"])
    c3.append("tick", ["tick"], ["TICK"])
    var t3 = Dict[String, String]()
    var ia = c3.find("auth")
    var it = c3.find("tick")
    c3.inject("auth", ia, t3)
    c3.inject("tick", it, t3)
    check(t3["auth_user"] == "u1", "P9-2 auth inject")
    check(t3["auth_tick_tick"] == "TICK", "P9-2 nested double-prefix")
    check(t3["tick_tick"] == "TICK", "P9-2 direct inject")
    check(c3.entry_count() == 2, "P9-2 entry count")

    # inject_dep_calls: 声明门控 + 次数注入
    var d_on = Dict[String, String]()
    d_on["_dep_calls"] = "true"
    var p1 = Dict[String, String]()
    inject_dep_calls(d_on, p1, c3)
    check("tick_calls" in p1 and p1["tick_calls"] == "1", "calls inject tick=1")
    check("auth_calls" in p1 and p1["auth_calls"] == "1", "calls inject auth=1")
    var p2 = Dict[String, String]()
    var d_off = Dict[String, String]()
    inject_dep_calls(d_off, p2, c3)
    check("tick_calls" not in p2, "calls off = no inject")

    # 混合计数: 同 name 3 条 (nocache ×2 + cached ×1) -> calls=3
    var c4 = DepCache()
    c4.append("t", ["v"], ["a"])
    c4.append("t", ["v"], ["b"])
    c4.append("t", ["v"], ["c"])
    check(c4.calls_of("t") == 3, "mixed calls=3")
    var un = c4.unique_names()
    check(len(un) == 1 and un[0] == "t", "unique_names dedup")

    print("dep_cache selftest: all ok (16 checks)")
