//! 决策-54 (ADR-0029): regex 引擎测试 — 向量由 Python `re.search`
//! (fastapi 0.141.1 / pydantic 2.13.5 活体对拍, /tmp/exch_probe/p26h_pat.py
//! 生成) + 编译失败用例 + 预算用例.

use super::regex::{rgx, rgx_compile_ok};

#[cfg(test)]
fn check(cond: bool, msg: &str) {
    if !cond {
        panic!("regex FAIL: {msg}");
    }
}

#[test]
fn rgx_python_re_vectors() {
    // ---- search 语义 (P26-h: 任意起点; ^ 仅串首; $ 串尾/尾\n前) ----
    check(rgx("(ab|cd)e", "abcde") == 1, "match (ab|cd)e abcde");
    check(rgx("(ab|cd)e", "abc") == 0, "nomatch (ab|cd)e abc");
    check(rgx(".*x", "axc") == 1, "match .*x axc");
    check(rgx(".*x", "abc") == 0, "nomatch .*x abc");
    check(rgx("[^a-z]", "abcX") == 1, "match [^a-z] abcX");
    check(rgx("[^a-z]", "abc") == 0, "nomatch [^a-z] abc");
    check(rgx("[a-d[f-z]]", "abc") == 0, "nomatch [a-d[f-z]] abc");
    check(rgx("[a-z]+", "abc") == 1, "match [a-z]+ abc");
    check(rgx("[a-z]+", "XXXX") == 0, "nomatch [a-z]+ XXXX");
    check(rgx("[ab]+", "abc") == 1, "match [ab]+ abc");
    check(rgx("[ab]+", "XXXX") == 0, "nomatch [ab]+ XXXX");
    check(rgx("\\bfoo\\b", "foo") == 1, "match \\bfoo\\b foo");
    check(rgx("\\bfoo\\b", "abc") == 0, "nomatch \\bfoo\\b abc");
    check(rgx("\\bfoo\\b", "barfoo") == 0, "nomatch \\bfoo\\b barfoo");
    check(rgx("\\bfoo\\b", "foo bar") == 1, "match \\bfoo\\b 'foo bar'");
    // ---- class escapes (\\d \\w \\s) ----
    check(rgx("\\d+", "12:34") == 1, "match \\d+ 12:34");
    check(rgx("\\d+", "abc") == 0, "nomatch \\d+ abc");
    check(rgx("\\d{2,3}", "12:34") == 1, "match \\d{2,3} 12:34");
    check(rgx("\\d{2,3}", "abc") == 0, "nomatch \\d{2,3} abc");
    check(rgx("\\s+", "hello world") == 1, "match \\s+ 'hello world'");
    check(rgx("\\s+", "abc") == 0, "nomatch \\s+ abc");
    check(rgx("\\w+", "abc") == 1, "match \\w+ abc");
    check(rgx("\\w+", "") == 0, "nomatch \\w+ empty");
    check(rgx("[\\d]+", "x12y") == 1, "match [\\d]+ x12y");
    // ---- 锚 ----
    check(rgx("^$", "") == 1, "match ^$ empty");
    check(rgx("^$", "abc") == 0, "nomatch ^$ abc");
    check(rgx("^[0-9]{2}:[0-9]{2}$", "12:34") == 1, "match ^[0-9]{2}:[0-9]{2}$ 12:34");
    check(rgx("^[0-9]{2}:[0-9]{2}$", "abc") == 0, "nomatch ^[0-9]{2}:[0-9]{2}$ abc");
    check(rgx("^[0-9a-f]+$", "abc") == 1, "match ^[0-9a-f]+$ abc");
    check(rgx("^[0-9a-f]+$", "abcX") == 0, "nomatch ^[0-9a-f]+$ abcX");
    check(rgx("^[\\w ]+$", "abc") == 1, "match ^[\\w ]+$ abc");
    check(rgx("^[\\w ]+$", "12:34") == 0, "nomatch ^[\\w ]+$ 12:34");
    check(rgx("^[a-z]+", "abc") == 1, "match ^[a-z]+ abc");
    check(rgx("^[a-z]+", "XabcX") == 0, "nomatch ^[a-z]+ XabcX");
    check(rgx("^[a-z]+", "abcX") == 1, "match ^[a-z]+ abcX (search: 尾自由)");
    check(rgx("^[a-z]+$", "abc") == 1, "match ^[a-z]+$ abc");
    check(rgx("^[a-z]+$", "abcX") == 0, "nomatch ^[a-z]+$ abcX");
    check(rgx("^no\\.", "no.") == 1, "match ^no\\. no.");
    check(rgx("^no\\.", "abc") == 0, "nomatch ^no\\. abc");
    check(rgx("^x.*", "xxy") == 1, "match ^x.* xxy");
    check(rgx("^x.*", "abc") == 0, "nomatch ^x.* abc");
    check(rgx("abc$", "xabc") == 1, "match abc$ xabc");
    check(rgx("abc$", "abcx") == 0, "nomatch abc$ abcx");
    // $ 在尾 \n 前匹配 (Python 同款)
    check(rgx("abc$", "abc\n") == 1, "match abc$ 'abc\\n'");
    // ---- 量词 ----
    check(rgx("a(b|c)d", "abc") == 0, "nomatch a(b|c)d abc");
    check(rgx("a(b|c)d", "abd") == 1, "match a(b|c)d abd");
    check(rgx("a*", "abc") == 1, "match a* abc");
    check(rgx("a.c", "abc") == 1, "match a.c abc");
    check(rgx("a.c", "XXXX") == 0, "nomatch a.c XXXX");
    check(rgx("a?", "abc") == 1, "match a? abc");
    check(rgx("abc|xyz", "abc") == 1, "match abc|xyz abc");
    check(rgx("abc|xyz", "XXXX") == 0, "nomatch abc|xyz XXXX");
    check(rgx("abc|xyz", "qxyz") == 1, "match abc|xyz qxyz (search)");
    check(rgx("a{1}", "abc") == 1, "match a{1} abc");
    check(rgx("a{1}", "XXXX") == 0, "nomatch a{1} XXXX");
    check(rgx("a{2,4}", "aabb") == 1, "match a{2,4} aabb");
    check(rgx("a{2,4}", "abc") == 0, "nomatch a{2,4} abc");
    check(rgx("a{2,}", "aabb") == 1, "match a{2,} aabb");
    check(rgx("a{2,}", "abc") == 0, "nomatch a{2,} abc");
    check(rgx("x+y", "xxy") == 1, "match x+y xxy");
    check(rgx("x+y", "abc") == 0, "nomatch x+y abc");
    check(rgx("x\\d{3}y", "x123y") == 1, "match x\\d{3}y x123y");
    check(rgx("x\\d{3}y", "x12y") == 0, "nomatch x\\d{3}y x12y");
    // ---- 空 pattern = 匹配任意串 ----
    check(rgx("", "anything") == 1, "match empty pattern");
    check(rgx("", "") == 1, "match empty pattern empty");
    // ---- 点号 (不匹配 \n) ----
    check(rgx("a.b", "a\nb") == 0, "nomatch a.b a\\nb");
    check(rgx("a.b", "axb") == 1, "match a.b axb");
}

#[test]
fn rgx_compile_fail() {
    check(!rgx_compile_ok("[a-"), "unterminated class");
    check(!rgx_compile_ok("(ab"), "unbalanced (");
    check(!rgx_compile_ok(")"), "unbalanced )");
    check(!rgx_compile_ok("a{2,1}"), "brace min > max");
    check(!rgx_compile_ok("a{,2}"), "bad brace");
    check(!rgx_compile_ok("[^"), "unterminated negated class");
    // 类外 ] = 字面 (Python 同款): "z]" 合法
    check(rgx_compile_ok("z]"), "literal ] ok");
    check(rgx("]", "]") == 1, "match ] ]");
    check(rgx("[a-d[f-z]]", "a]") == 1, "class + literal ] match");
    check(rgx("[a-", "x") == -1, "ffi -1 on bad pattern");
    check(rgx("(ab", "x") == -1, "ffi -1 on unbalanced");
    // 合法 pattern 编译 OK
    check(rgx_compile_ok("^[a-z]{2,4}$"), "good pattern ok");
    check(rgx_compile_ok("a*|b+?"), "quantified alt ok");
    check(rgx_compile_ok("x{2,}"), "open brace range ok");
}

#[test]
fn rgx_step_budget() {
    // pathological: (a|a)*b 对全 a 长串 — 预算内判未中 (不挂死)
    let big: String = "a".repeat(200);
    check(rgx("(a|a)*b", &big) == 0, "budget: (a|a)*b no b -> 0");
    let big_b = big + "b";
    check(rgx("(a|a)*b", &big_b) == 1, "budget: (a|a)*b with b -> 1");
}
