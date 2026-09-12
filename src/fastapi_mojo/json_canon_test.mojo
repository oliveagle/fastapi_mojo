# src/fastapi_mojo/json_canon_test.mojo
#
# 决策-88 (ADR-0063) executable tests for json_canon (CPython/Starlette
# `json.dumps(ensure_ascii=False, separators=(",",":"))` 等价的 body `input`
# 反序列化-重序列化)。same-dir split 保持两模块 < 500 行。

from json_canon import canon_json


def _eq(got: String, want: String, label: String) raises:
    if got != want:
        raise Error("json_canon: " + label + ": got '" + got + "' want '" + want + "'")


def main() raises:
    print("Testing json_canon (CPython/Starlette input re-serialization)...")
    # 空白去除 (对象/数组)
    _eq(canon_json('[1, 2, 3]'), '[1,2,3]', "array ws")
    _eq(canon_json('[ "a" , "b" ]'), '["a","b"]', "array str ws")
    _eq(canon_json('[1,[2, 3]]'), '[1,[2,3]]', "nested array ws")
    _eq(canon_json('{ "a" : 1 , "b" : [1, 2] }'), '{"a":1,"b":[1,2]}', "object ws")
    _eq(canon_json('  true  '), 'true', "leading/trailing ws")
    # 数字规范化
    _eq(canon_json('1.50'), '1.5', "float trailing zero")
    _eq(canon_json('1e2'), '100.0', "float exp -> integral float")
    _eq(canon_json('1E+2'), '100.0', "float E+")
    _eq(canon_json('-0'), '0', "int -0 -> 0")
    _eq(canon_json('-0.0'), '-0.0', "float -0.0 kept")
    _eq(canon_json('0.0'), '0.0', "float 0.0 kept")
    _eq(canon_json('5'), '5', "int unchanged")
    _eq(canon_json('12345678901234567890'), '12345678901234567890', "big int unchanged")
    # 字符串解码重编码
    _eq(canon_json('"caf\\u00e9"'), '"café"', "unicode escape -> raw utf8")
    _eq(canon_json('"\\u0041"'), '"A"', "ascii escape")
    _eq(canon_json('"a\\/b"'), '"a/b"', "solidus unescaped")
    _eq(canon_json('"\\uD83D\\uDE00"'), '"😀"', "surrogate pair")
    _eq(canon_json('"\\b"'), '"\\b"', "backspace short escape")
    _eq(canon_json('"a\\nb"'), '"a\\nb"', "newline escape preserved")
    _eq(canon_json('"he said \\"hi\\""'), '"he said \\"hi\\""', "quote escape")
    # 标量 / 重复键
    _eq(canon_json('null'), 'null', "null")
    _eq(canon_json('{"a":1,"a":2}'), '{"a":2}', "dup key last wins")
    _eq(canon_json('[true, false, null]'), '[true,false,null]', "literals")
    _eq(canon_json('{}'), '{}', "empty object")
    _eq(canon_json('[]'), '[]', "empty array")
    # 安全回退 (非合法 JSON / 非有限 / 孤立代理): 原样返回
    _eq(canon_json('zz'), 'zz', "bare token fallback")
    _eq(canon_json('NaN'), 'NaN', "NaN fallback")
    _eq(canon_json('Infinity'), 'Infinity', "Infinity fallback")
    _eq(canon_json('1e999'), '1e999', "non-finite float fallback")
    _eq(canon_json('"\\ud83d"'), '"\\ud83d"', "lone surrogate fallback")
    _eq(canon_json('{"a":1}trailing'), '{"a":1}trailing', "trailing data fallback")
    _eq(canon_json(''), '', "empty fallback")
    print("json_canon selftest OK")
