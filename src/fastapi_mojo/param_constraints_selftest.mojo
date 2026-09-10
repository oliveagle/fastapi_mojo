# src/fastapi_mojo/param_constraints_selftest.mojo
#
# 决策-54 (ADR-0029): 参数约束面自测 — 纯逻辑 (无 FFI / 无 HTTP):
# parse_constraint_entry / _parse_len / get_param_constraints /
# check_num_constraints (优先级 mo→ge→gt→le→lt; mo=0 no-op; fmt_num) /
# check_str_constraints (minl→maxl; 无 pat — regex_match FFI 在 JIT 二进制
# 未定义, pattern 路径只编译不调用) / validate_headers_collect (缺失 /
# 默认违反(input=类型化字面量 P26-b-8) / 在场 parse / 在场约束 / list 取首) /
# validate_implicit_constraints (missing / str 约束) /
# validate_params_collect (两段群序 path→query + 约束 + 默认违反 input 裸数字) /
# constraint_schema_fragments / parse_reads_headers.
#
# Mojo 1.0.0: assert no-op -> 真 check()+abort; 无全局变量 ->
# 错误路径 = 函数体内 try/except (except 不可绑变量, Bool 捕获);
# 不调 _rgx_match / check_param_constraints (注册期 pattern 编译 = bridge
# FFI, 由 e2e 启动期守护).
# 运行: export JIT_STUB="$(bash ../../scripts/jit_stub.sh)" &&
#   mojo run -Xlinker "$JIT_STUB" param_constraints_selftest.mojo
#   (JIT 环境不链接 bridge: -Xlinker 注入符号桩 .so 满足 materialize;
#   桩被调用即 abort, 自测约束永不含 pat — ADR-0029 §7 环境注记).
import std.os
from handler import Handler, KIND_ECHO
from param_constraints import (ConstraintSpec, _parse_len, parse_constraint_entry,
                               get_param_constraints, check_num_constraints,
                               check_str_len_constraints, check_str_constraints,
                               constraint_schema_fragments,
                               parse_reads_headers)
from param_constraints_run import (validate_headers_collect,
                                   validate_implicit_constraints)
from params_typed import validate_params_collect
from params_query_extra import parse_table

def check(cond: Bool, msg: String) raises:
    """真检查 (Mojo 1.0.0 assert 是 no-op, 决策-38 教训)."""
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def _ts(csv: String) raises -> Dict[String, String]:
    """类型表: "name:type=default;..." (sep ;, keysep :)."""
    return parse_table(csv, 59, 58, True)

def _tc(csv: String) raises -> Dict[String, String]:
    """逗号分隔 "k=v,..." 表 (sep ,, keysep =)."""
    return parse_table(csv, 44, 61, True)
def _t(csv: String) raises -> Dict[String, String]:
    """自测输入: 紧凑 "k=v;..." 表 -> Dict."""
    return parse_table(csv, 59, 61, True)

# ---------- parse_constraint_entry ----------

def _pce(entry: String) -> Tuple[Bool, String, String, String, String, String, Int, Int, String]:
    """try/except 捕获: (raised, gt, ge, lt, le, mo, minl, maxl, pat)."""
    var raised: Bool = True
    var gt: String = ""
    var ge: String = ""
    var lt: String = ""
    var le: String = ""
    var mo: String = ""
    var minl: Int = -1
    var maxl: Int = -1
    var pat: String = ""
    try:
        var spec = parse_constraint_entry(entry, "")
        raised = False
        gt = spec.gt
        ge = spec.ge
        lt = spec.lt
        le = spec.le
        mo = spec.mo
        minl = spec.minl
        maxl = spec.maxl
        pat = spec.pat
    except Error:
        pass
    return (raised, gt, ge, lt, le, mo, minl, maxl, pat)

def t_parse() raises:
    print("-- parse_constraint_entry --")
    var r = _pce("gt=3,le=10")
    check(not r[0], "pce no raise")
    check(r[1] == "3" and r[4] == "10", "pce gt/le")
    check(r[2] == "" and r[3] == "" and r[5] == "" and r[6] == -1 and r[7] == -1 and r[8] == "", "pce unset")
    r = _pce("len=2-4,pat=^[a-z]+$")
    check(not r[0] and r[6] == 2 and r[7] == 4 and r[8] == "^[a-z]+$", "pce len/pat")
    r = _pce("mo=2,ge=1")
    check(not r[0] and r[5] == "2" and r[2] == "1", "pce mo/ge")
    r = _pce("gt=2.5")
    check(not r[0] and r[1] == "2.5", "pce float literal")
    r = _pce("len=0")
    check(not r[0] and r[6] == 0 and r[7] == 0, "pce len=0")
    for bad in ["zz=1", "gt=x", "len=-1", "len=1.5", "len=1-2-3", "=3", "gt"]:
        r = _pce(bad)
        check(r[0], "pce raise: " + bad)
    r = _pce("")
    check(not r[0] and r[1] == "" and r[6] == -1, "pce empty entry ok")

# ---------- _parse_len ----------

def t_len() raises:
    print("-- _parse_len --")
    var r = _parse_len("2")
    check(r[0] and r[1] == 2 and r[2] == 2, "len N")
    r = _parse_len("2-4")
    check(r[0] and r[1] == 2 and r[2] == 4, "len N-M")
    r = _parse_len("0")
    check(r[0] and r[1] == 0 and r[2] == 0, "len 0")
    for bad in ["-1", "1.5", "1-2-3", "", "2-"]:
        r = _parse_len(bad)
        check(not r[0], "len bad: " + bad)

# ---------- check_num_constraints ----------

def _numspec(gt: String, ge: String, lt: String, le: String, mo: String) -> ConstraintSpec:
    """构造 ConstraintSpec (函数返回 = 新值, 可绑局部)."""
    var s = ConstraintSpec()
    s.gt = gt
    s.ge = ge
    s.lt = lt
    s.le = le
    s.mo = mo
    return s^

def t_num() raises:
    print("-- check_num_constraints --")
    var r = check_num_constraints(5.0, _numspec("", "", "", "", ""))
    check(r[0], "num empty ok")
    r = check_num_constraints(4.0, _numspec("", "5", "", "", ""))
    check(not r[0] and r[1] == "Input should be greater than or equal to 5", "ge msg")
    check(r[2] == "greater_than_equal" and r[3] == "{\"ge\":5}", "ge type/ctx")
    r = check_num_constraints(5.0, _numspec("", "5", "", "", ""))
    check(r[0], "ge boundary pass")
    r = check_num_constraints(3.0, _numspec("3", "", "", "", ""))
    check(not r[0] and r[1] == "Input should be greater than 3", "gt msg")
    check(r[2] == "greater_than" and r[3] == "{\"gt\":3}", "gt type/ctx")
    r = check_num_constraints(4.0, _numspec("3", "", "", "", ""))
    check(r[0], "gt pass")
    r = check_num_constraints(11.0, _numspec("", "", "", "10", ""))
    check(not r[0] and r[1] == "Input should be less than or equal to 10", "le msg")
    check(r[2] == "less_than_equal" and r[3] == "{\"le\":10}", "le type/ctx")
    r = check_num_constraints(10.0, _numspec("", "", "", "10", ""))
    check(r[0], "le boundary pass")
    r = check_num_constraints(5.0, _numspec("", "", "5", "", ""))
    check(not r[0] and r[1] == "Input should be less than 5", "lt msg")
    check(r[2] == "less_than" and r[3] == "{\"lt\":5}", "lt type/ctx")
    r = check_num_constraints(4.0, _numspec("", "", "5", "", ""))
    check(r[0], "lt pass")
    r = check_num_constraints(10.0, _numspec("", "", "", "", "3"))
    check(not r[0] and r[1] == "Input should be a multiple of 3", "mo msg")
    check(r[2] == "multiple_of" and r[3] == "{\"multiple_of\":3}", "mo type/ctx")
    r = check_num_constraints(9.0, _numspec("", "", "", "", "3"))
    check(r[0], "mo pass")
    r = check_num_constraints(1.0, _numspec("", "", "", "", "0"))
    check(r[0], "mo=0 no-op (upstream parity)")
    # 优先级: mo→ge→gt→le→lt (P26-c/d/e 实测)
    r = check_num_constraints(4.0, _numspec("", "5", "", "", "3"))
    check(not r[0] and r[2] == "multiple_of", "mo before ge")
    r = check_num_constraints(2.0, _numspec("1", "3", "", "", ""))
    check(not r[0] and r[2] == "greater_than_equal", "ge before gt")
    r = check_num_constraints(10.0, _numspec("3", "", "", "5", ""))
    check(not r[0] and r[2] == "less_than_equal", "gt then le")
    r = check_num_constraints(2.0, _numspec("", "2.5", "", "", ""))
    check(not r[0] and r[1] == "Input should be greater than or equal to 2.5", "float ge msg")
    r = check_num_constraints(4.0, _numspec("", "", "", "", "1.5"))
    check(not r[0] and r[2] == "multiple_of" and r[3] == "{\"multiple_of\":1.5}", "float mo ctx raw")

# ---------- check_str_constraints ----------

def _strspec(minl: Int, maxl: Int, pat: String) -> ConstraintSpec:
    """构造 str 约束 spec (pat 保持空 — JIT 下 regex FFI 未定义)."""
    var s = ConstraintSpec()
    s.minl = minl
    s.maxl = maxl
    s.pat = pat
    return s^

def t_str() raises:
    print("-- check_str_constraints --")
    var r = check_str_len_constraints("a", _strspec(2, -1, ""))
    check(not r[0] and r[1] == "String should have at least 2 characters", "minl msg")
    check(r[2] == "string_too_short" and r[3] == "{\"min_length\":2}", "minl type/ctx")
    r = check_str_len_constraints("abcde", _strspec(-1, 4, ""))
    check(not r[0] and r[1] == "String should have at most 4 characters", "maxl msg")
    check(r[2] == "string_too_long" and r[3] == "{\"max_length\":4}", "maxl type/ctx")
    r = check_str_len_constraints("ab", _strspec(2, 4, ""))
    check(r[0], "min boundary pass")
    r = check_str_len_constraints("abcd", _strspec(2, 4, ""))
    check(r[0], "max boundary pass")
    r = check_str_len_constraints("a", _strspec(2, 4, ""))
    check(not r[0] and r[2] == "string_too_short", "minl before maxl")
    r = check_str_len_constraints("a", _strspec(0, 0, ""))
    check(not r[0] and r[2] == "string_too_long" and r[3] == "{\"max_length\":0}", "len=0 vacuous")
    r = check_str_len_constraints("anything", _strspec(-1, -1, ""))
    check(r[0], "empty spec ok")

# ---------- constraint_schema_fragments ----------

def _fullspec() -> ConstraintSpec:
    """minl/maxl/pat/mo/gt/le 全开 (pat 只测 fragment 字符串, 不调 regex)."""
    var s = ConstraintSpec()
    s.minl = 2
    s.maxl = 4
    s.pat = "^[a-z]+$"
    s.mo = "2"
    s.gt = "3"
    s.le = "10"
    return s^

def t_fragments() raises:
    print("-- constraint_schema_fragments --")
    var fs = constraint_schema_fragments(_fullspec())
    check(len(fs) == 7, "full fragment count")
    check(fs[0] == "\"minLength\":2", "f0 minLength")
    check(fs[1] == "\"maxLength\":4", "f1 maxLength")
    check(fs[2] == "\"pattern\":\"^[a-z]+$\"", "f2 pattern")
    check(fs[3] == "\"multipleOf\":2", "f3 multipleOf")
    check(fs[4] == "\"minimum\":3", "f4 minimum")
    check(fs[5] == "\"exclusiveMinimum\":true", "f5 exclusiveMinimum (3.0 bool)")
    check(fs[6] == "\"maximum\":10", "f6 maximum")
    fs = constraint_schema_fragments(_numspec("3", "", "", "", ""))
    check(len(fs) == 2 and fs[0] == "\"minimum\":3" and fs[1] == "\"exclusiveMinimum\":true", "gt only")
    fs = constraint_schema_fragments(_numspec("", "", "10", "", ""))
    check(len(fs) == 2 and fs[0] == "\"maximum\":10" and fs[1] == "\"exclusiveMaximum\":true", "lt only")
    fs = constraint_schema_fragments(_numspec("", "1", "", "", ""))
    check(len(fs) == 1 and fs[0] == "\"minimum\":1", "ge only no exclusive")
    fs = constraint_schema_fragments(_numspec("", "", "", "", ""))
    check(len(fs) == 0, "empty")

# ---------- get_param_constraints ----------

def t_get() raises:
    print("-- get_param_constraints --")
    var h = Handler(KIND_ECHO(), "t1")
    h.set_data("_param_constraints", "n=gt=3,le=10;;s=len=2-4")
    var d = get_param_constraints(h)
    check(len(d) == 2, "entries (empty skipped)")
    check(d["n"] == "gt=3,le=10", "raw csv n")
    check(d["s"] == "len=2-4", "raw csv s")
    var h2 = Handler(KIND_ECHO(), "t2")
    h2.set_data("_param_constraints", "")
    check(len(get_param_constraints(h2)) == 0, "empty decl")
    var h3 = Handler(KIND_ECHO(), "t3")
    check(len(get_param_constraints(h3)) == 0, "no decl")
    var h4 = Handler(KIND_ECHO(), "t4")
    h4.set_data("_param_constraints", "n=gt=3,le=10;")
    d = get_param_constraints(h4)
    check(len(d) == 1 and d["n"] == "gt=3,le=10", "trailing sep")

# ---------- parse_reads_headers ----------

def t_reads() raises:
    print("-- parse_reads_headers --")
    var d = parse_reads_headers("x_token,x-app")
    check(d["x_token"] == "x-token" and d["x-app"] == "x-app", "default _->-")
    d = parse_reads_headers("x-ver=X-Ver,tag")
    check(d["x-ver"] == "X-Ver" and d["tag"] == "tag", "alias as-is")

# ---------- validate_headers_collect ----------

def t_headers() raises:
    print("-- validate_headers_collect --")
    var reads = _tc("x_token=x-token,x-app=x-app,x-h=x-h,x-v=x-v,a=a,b=b,h=h,s=s")
    # 1. required 缺失 -> missing (input null, loc = wire)
    var r = validate_headers_collect(_ts("x_token:int"), reads, _t(""), _t(""))
    check(not r[0] and len(r[1]) == 1, "hdr missing 1 err")
    check(r[1][0] == "{\"loc\":[\"header\",\"x-token\"],\"msg\":\"Field required\",\"type\":\"missing\",\"input\":null}",
          "hdr missing exact")
    check(len(r[2]) == 0, "hdr missing no inject")
    # 2. 在场 int parse 失败 -> 完整上游消息
    r = validate_headers_collect(_ts("x_token:int"), reads, _t("x_token=abc"), _t(""))
    check(not r[0] and r[1][0] == "{\"loc\":[\"header\",\"x-token\"],\"msg\":\"Input should be a valid integer, unable to parse string as an integer\",\"type\":\"int_parsing\",\"input\":\"abc\"}",
          "hdr int parse exact")
    # 3. bool 默认 (缺失 -> true 注入)
    r = validate_headers_collect(_ts("x-app:bool=true"), reads, _t(""), _t(""))
    check(r[0] and r[2]["x-app"] == "true", "hdr bool default inject")
    # 4. 在场 bool parse 失败 -> 完整上游消息 (矩阵 #3 三面对齐)
    r = validate_headers_collect(_ts("x-app:bool=true"), reads, _t("x-app=xyz"), _t(""))
    check(not r[0] and r[1][0] == "{\"loc\":[\"header\",\"x-app\"],\"msg\":\"Input should be a valid boolean, unable to interpret input\",\"type\":\"bool_parsing\",\"input\":\"xyz\"}",
          "hdr bool parse exact")
    # 5. 缺失 + 默认违反约束 -> 422, input = 类型化默认 (裸数字, P26-b-8)
    r = validate_headers_collect(_ts("x-h:int=2"), reads, _t(""), _t("x-h=ge=5"))
    check(not r[0] and r[1][0] == "{\"loc\":[\"header\",\"x-h\"],\"msg\":\"Input should be greater than or equal to 5\",\"type\":\"greater_than_equal\",\"input\":2,\"ctx\":{\"ge\":5}}",
          "hdr default violation input unquoted 2")
    # 6. 在场违反约束 -> input = raw 串 (带引号)
    r = validate_headers_collect(_ts("x-h:int=2"), reads, _t("x-h=3"), _t("x-h=ge=5"))
    check(not r[0] and r[1][0] == "{\"loc\":[\"header\",\"x-h\"],\"msg\":\"Input should be greater than or equal to 5\",\"type\":\"greater_than_equal\",\"input\":\"3\",\"ctx\":{\"ge\":5}}",
          "hdr present violation input quoted")
    # 7. 在场通过 -> 注入原始字符串
    r = validate_headers_collect(_ts("x-h:int=2"), reads, _t("x-h=7"), _t("x-h=ge=5"))
    check(r[0] and r[2]["x-h"] == "7", "hdr present inject raw")
    # 8. 缺失 + 默认通过 -> 注入默认字面量
    r = validate_headers_collect(_ts("x-v:int=3"), reads, _t(""), _t("x-v=ge=1"))
    check(r[0] and r[2]["x-v"] == "3", "hdr default pass inject")
    # 9. collect-all (缺失 + parse 双错; 组内 dict 序不断言, 按内容断言)
    r = validate_headers_collect(_ts("a:int;b:int=1"), reads, _t("b=x"), _t(""))
    check(not r[0] and len(r[1]) == 2, "hdr collect-all 2 errs")
    var saw_missing = False
    var saw_parse = False
    for e in r[1]:
        if e == "{\"loc\":[\"header\",\"a\"],\"msg\":\"Field required\",\"type\":\"missing\",\"input\":null}":
            saw_missing = True
        if e == "{\"loc\":[\"header\",\"b\"],\"msg\":\"Input should be a valid integer, unable to parse string as an integer\",\"type\":\"int_parsing\",\"input\":\"x\"}":
            saw_parse = True
    check(saw_missing and saw_parse, "hdr collect-all content")
    # 10. list header = 取首值标量语义 (ADR-0029 §3.1)
    r = validate_headers_collect(_ts("h:int[]"), reads, _t("h=3"), _t(""))
    check(r[0] and r[2]["h"] == "3", "hdr list first-value ok")
    r = validate_headers_collect(_ts("h:int[]"), reads, _t("h=3,zz"), _t(""))
    check(not r[0] and len(r[1]) == 1 and "int_parsing" in r[1][0], "hdr list non-scalar 422")
    # 11. str 约束 (在场)
    r = validate_headers_collect(_ts("s:str=ab"), reads, _t("s=xyz"), _t("s=len=1-2"))
    check(not r[0] and r[1][0] == "{\"loc\":[\"header\",\"s\"],\"msg\":\"String should have at most 2 characters\",\"type\":\"string_too_long\",\"input\":\"xyz\",\"ctx\":{\"max_length\":2}}",
          "hdr str constraint exact")

# ---------- validate_implicit_constraints ----------

def t_implicit() raises:
    print("-- validate_implicit_constraints --")
    var htypes = _t("")
    # 1. query 在场违反 (len)
    var errs = validate_implicit_constraints(_t("r=len=1-3"), _ts("q:int=5"), htypes, _t(""), _t("r=abcd"))
    check(len(errs) == 1, "imp 1 err")
    check(errs[0] == "{\"loc\":[\"query\",\"r\"],\"msg\":\"String should have at most 3 characters\",\"type\":\"string_too_long\",\"input\":\"abcd\",\"ctx\":{\"max_length\":3}}",
          "imp query too-long exact")
    # 2. query 缺失 (声明即必填)
    errs = validate_implicit_constraints(_t("r=len=1-3"), _ts("q:int=5"), htypes, _t(""), _t(""))
    check(len(errs) == 1 and errs[0] == "{\"loc\":[\"query\",\"r\"],\"msg\":\"Field required\",\"type\":\"missing\",\"input\":null}",
          "imp query missing exact")
    # 3. path 段在场通过
    errs = validate_implicit_constraints(_t("s=len=2-4"), _ts(""), htypes, _t("s=abc"), _t(""))
    check(len(errs) == 0, "imp path ok")
    # 4. path 段违反
    errs = validate_implicit_constraints(_t("s=len=2-4"), _ts(""), htypes, _t("s=a"), _t(""))
    check(len(errs) == 1 and errs[0] == "{\"loc\":[\"path\",\"s\"],\"msg\":\"String should have at least 2 characters\",\"type\":\"string_too_short\",\"input\":\"a\",\"ctx\":{\"min_length\":2}}",
          "imp path too-short exact")
    # 5. 类型化 name 跳过 (归 params_typed 面)
    errs = validate_implicit_constraints(_t("q=ge=0"), _ts("q:int=5"), htypes, _t(""), _t("q=200"))
    check(len(errs) == 0, "imp typed name skipped")
    # 6. header name 跳过 (归 typed header 面)
    errs = validate_implicit_constraints(_t("x=len=1-2"), _ts(""), _ts("x:str=ab"), _t(""), _t(""))
    check(len(errs) == 0, "imp header name skipped")
    # 7. 空约束
    check(len(validate_implicit_constraints(_t(""), _ts("q:int=5"), htypes, _t(""), _t("q=1"))) == 0, "imp empty")
    # 8. 双参数 (path + query) collect-all (组内 dict 序不断言)
    errs = validate_implicit_constraints(_t("s=len=2-4;r=len=1-3"), _ts(""), htypes, _t("s=a"), _t("r=abcd"))
    check(len(errs) == 2, "imp both 2 errs")

# ---------- validate_params_collect (约束接线) ----------

def t_params() raises:
    print("-- validate_params_collect + constraints --")
    var multi = Dict[String, List[String]]()
    # 1. path 在场违反
    var r = validate_params_collect(_ts("n:int"), _t("n=2"), _t(""), multi, _t(""), _t("n=gt=3"))
    check(not r[0] and len(r[1]) == 1, "tp path 1 err")
    check(r[1][0] == "{\"loc\":[\"path\",\"n\"],\"msg\":\"Input should be greater than 3\",\"type\":\"greater_than\",\"input\":\"2\",\"ctx\":{\"gt\":3}}",
          "tp path exact")
    # 2. query 在场违反
    r = validate_params_collect(_ts("q:int=5"), _t(""), _t("q=200"), multi, _t(""), _t("q=lt=100"))
    check(not r[0] and r[1][0] == "{\"loc\":[\"query\",\"q\"],\"msg\":\"Input should be less than 100\",\"type\":\"less_than\",\"input\":\"200\",\"ctx\":{\"lt\":100}}",
          "tp query exact")
    # 3. collect-all 群序 path→query (两段遍历, 顺序确定)
    r = validate_params_collect(_ts("n:int;q:int=1"), _t("n=1"), _t("q=200"), multi, _t(""), _t("n=gt=3;q=lt=100"))
    check(not r[0] and len(r[1]) == 2, "tp both 2 errs")
    check(r[1][0] == "{\"loc\":[\"path\",\"n\"],\"msg\":\"Input should be greater than 3\",\"type\":\"greater_than\",\"input\":\"1\",\"ctx\":{\"gt\":3}}",
          "tp order path first")
    check(r[1][1] == "{\"loc\":[\"query\",\"q\"],\"msg\":\"Input should be less than 100\",\"type\":\"less_than\",\"input\":\"200\",\"ctx\":{\"lt\":100}}",
          "tp order query second")
    # 4. 全通过
    r = validate_params_collect(_ts("n:int;q:int=1"), _t("n=5"), _t("q=50"), multi, _t(""), _t("n=gt=3;q=lt=100"))
    check(r[0] and len(r[1]) == 0, "tp all pass")
    # 5. int parse 回归 (CP-24 同款)
    r = validate_params_collect(_ts("count:int"), _t(""), _t("count=abc"), multi, _t(""), _t(""))
    check(not r[0] and r[1][0] == "{\"loc\":[\"query\",\"count\"],\"msg\":\"Input should be a valid integer, unable to parse string as an integer\",\"type\":\"int_parsing\",\"input\":\"abc\"}",
          "tp int parse exact")
    # 6. bool 完整消息 (矩阵 #3 偏差销账)
    r = validate_params_collect(_ts("b:bool"), _t(""), _t("b=xyz"), multi, _t(""), _t(""))
    check(not r[0] and r[1][0] == "{\"loc\":[\"query\",\"b\"],\"msg\":\"Input should be a valid boolean, unable to interpret input\",\"type\":\"bool_parsing\",\"input\":\"xyz\"}",
          "tp bool full msg")
    # 7. float parse
    r = validate_params_collect(_ts("f:float=1.5"), _t(""), _t("f=abc"), multi, _t(""), _t(""))
    check(not r[0] and r[1][0] == "{\"loc\":[\"query\",\"f\"],\"msg\":\"Input should be a valid number, unable to parse string as a number\",\"type\":\"float_parsing\",\"input\":\"abc\"}",
          "tp float parse exact")
    # 8. 缺失 + 默认违反约束 -> input = 裸数字 (P26-b-8 同源, 决策-54 修复点)
    r = validate_params_collect(_ts("q:int=250"), _t(""), _t(""), multi, _t(""), _t("q=lt=100"))
    check(not r[0] and len(r[1]) == 1, "tp default violation 1 err")
    check(r[1][0] == "{\"loc\":[\"query\",\"q\"],\"msg\":\"Input should be less than 100\",\"type\":\"less_than\",\"input\":250,\"ctx\":{\"lt\":100}}",
          "tp default violation input unquoted")
    # 9. enum 值通过后再查 str 约束
    r = validate_params_collect(_ts("lvl:str[low,high]"), _t(""), _t("lvl=high"), multi, _t(""), _t("lvl=len=1-2"))
    check(not r[0] and r[1][0] == "{\"loc\":[\"query\",\"lvl\"],\"msg\":\"String should have at most 2 characters\",\"type\":\"string_too_long\",\"input\":\"high\",\"ctx\":{\"max_length\":2}}",
          "tp enum then str constraint")
    # 10. enum 值不在表 -> enum 错 (不查约束)
    r = validate_params_collect(_ts("lvl:str[low,high]"), _t(""), _t("lvl=mid"), multi, _t(""), _t("lvl=len=1-2"))
    check(not r[0] and r[1][0] == "{\"loc\":[\"query\",\"lvl\"],\"msg\":\"Input should be 'low' or 'high'\",\"type\":\"enum\",\"input\":\"mid\"}",
          "tp enum reject")

# ---------- main ----------

def main() raises:
    print("Testing param constraints (决策-54, ADR-0029)...")
    t_parse()
    t_len()
    t_num()
    t_str()
    t_fragments()
    t_get()
    t_reads()
    t_headers()
    t_implicit()
    t_params()
    print("param constraints test completed!")
