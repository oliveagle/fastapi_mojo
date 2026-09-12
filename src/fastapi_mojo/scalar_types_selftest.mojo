# src/fastapi_mojo/scalar_types_selftest.mojo
#
# 决策-79 (ADR-0054): scalar_types 自测 (mojo run 独立执行, CI 列表)。
# 覆盖 uuid/date/datetime/time/timedelta/decimal 的合法/畸形输入 + 错误
# type/msg/ctx 对齐 (上游 pydantic_core 2.46.4 实测向量)。

import std.os
from scalar_types import parse_scalar, is_scalar_type, scalar_openapi_schema, ScalarParse


def check(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL: " + msg)
        std.os.abort()


def _has(s: String, sub: String) -> Bool:
    var sn = sub.byte_length()
    var sl = s.byte_length()
    if sn == 0 or sn > sl:
        return False
    for i in range(sl - sn + 1):
        var j = 0
        while j < sn:
            if s[byte=i + j] != sub[byte=j]:
                break
            j += 1
        if j == sn:
            return True
    return False


def okv(t: String, raw: String) -> Bool:
    var r = parse_scalar(t, raw)
    return r.ok


def errs(t: String, raw: String, etype: String, emsg: String) -> Bool:
    var r = parse_scalar(t, raw)
    if r.ok:
        return False
    return r.err_type == etype and r.err_msg == emsg


def main() raises:
    print("Testing scalar_types (决策-79)...")

    check(is_scalar_type("uuid") and is_scalar_type("UUID") and is_scalar_type("decimal"), "aliases")
    check(not is_scalar_type("int") and not is_scalar_type("str"), "non-scalars")
    check(_has(scalar_openapi_schema("datetime"), "\"format\":\"date-time\""), "dt openapi")
    check(_has(scalar_openapi_schema("decimal"), "anyOf"), "dec openapi")

    # ----- uuid -----
    check(okv("uuid", "A987FB5A-8CB6-4F3F-8F6B-000000000001"), "uuid hyphen upper")
    check(parse_scalar("uuid", "A987FB5A-8CB6-4F3F-8F6B-000000000001").value == "a987fb5a-8cb6-4f3f-8f6b-000000000001", "uuid lowercase canonical")
    check(okv("uuid", "a987fb5a8cb64f3f8f6b000000000001"), "uuid simple")
    check(okv("uuid", "{a987fb5a-8cb6-4f3f-8f6b-000000000001}"), "uuid braced")
    check(okv("uuid", "urn:uuid:a987fb5a-8cb6-4f3f-8f6b-000000000001"), "uuid urn")
    check(errs("uuid", "nope", "uuid_parsing", "Input should be a valid UUID, invalid character: found `n` at 1"), "uuid bad char")
    check(errs("uuid", "{", "uuid_parsing", "Input should be a valid UUID, invalid character: found `{` at 1"), "uuid brace char")
    check(errs("uuid", "{}", "uuid_parsing", "Input should be a valid UUID, invalid group count: expected 5, found 1"), "uuid group count")
    check(errs("uuid", "", "uuid_parsing", "Input should be a valid UUID, invalid length: expected length 32 for simple format, found 0"), "uuid empty")
    check(errs("uuid", "a987fb5a8cb64f3f8f6b00000000000", "uuid_parsing", "Input should be a valid UUID, invalid length: expected length 32 for simple format, found 31"), "uuid simple len")
    check(errs("uuid", "a987fb5a-8cb6-4f3f-8f6b-00000000001", "uuid_parsing", "Input should be a valid UUID, invalid group length in group 4: expected 12, found 11"), "uuid g4 len")
    check(errs("uuid", "1-1-1-1-1", "uuid_parsing", "Input should be a valid UUID, invalid group length in group 0: expected 8, found 1"), "uuid g0 len")
    check(errs("uuid", "urn:uuid:{}", "uuid_parsing", "Input should be a valid UUID, invalid character: found `{` at 10"), "uuid urn char")
    check(errs("uuid", "aébc", "uuid_parsing", "Input should be a valid UUID, invalid character: found `é` at 2"), "uuid multibyte")

    # ----- date -----
    check(okv("date", "2024-01-02"), "date ok")
    check(okv("date", "2024-02-29"), "date leap ok")
    check(okv("date", "2024-01-02T00:00:00"), "date dt zero")
    check(errs("date", "2024-01-0", "date_from_datetime_parsing", "Input should be a valid date or datetime, input is too short"), "date short")
    check(errs("date", "2024-01-32", "date_from_datetime_parsing", "Input should be a valid date or datetime, day value is outside expected range"), "date day range")
    check(errs("date", "2024-13-01", "date_from_datetime_parsing", "Input should be a valid date or datetime, month value is outside expected range of 1-12"), "date month range")
    check(errs("date", "2024-01-02T03:04:05", "date_from_datetime_inexact", "Datetimes provided to dates should have zero time - e.g. be exact dates"), "date inexact")
    check(errs("date", "0000-01-01", "date_parsing", "Input should be a valid date in the format YYYY-MM-DD, year 0 is out of range"), "date year0")

    # ----- datetime -----
    check(okv("datetime", "2024-01-02T03:04:05"), "dt ok")
    check(okv("datetime", "2024-01-02"), "dt date only")
    check(okv("datetime", "2024-01-02T03:04:05Z"), "dt z")
    check(okv("datetime", "2024-01-02T03:04:05+05:30"), "dt tz")
    check(okv("datetime", "1704164645"), "dt epoch")
    check(errs("datetime", "x", "datetime_from_date_parsing", "Input should be a valid datetime or date, input is too short"), "dt short")
    check(errs("datetime", "2024-01-02T03", "datetime_from_date_parsing", "Input should be a valid datetime or date, unexpected extra characters at the end of the input"), "dt hour only")
    check(errs("datetime", "2024-13-02T03:04:05", "datetime_from_date_parsing", "Input should be a valid datetime or date, month value is outside expected range of 1-12"), "dt month range")

    # ----- time -----
    check(okv("time", "03:04:05"), "time ok")
    check(okv("time", "03:04"), "time hm")
    check(okv("time", "03:04:05.123"), "time frac")
    check(okv("time", "03:04:05+00:00"), "time tz")
    check(errs("time", "3:04:05", "time_parsing", "Input should be in a valid time format, invalid character in hour"), "time hour char")
    check(errs("time", "25:00:00", "time_parsing", "Input should be in a valid time format, hour value is outside expected range of 0-23"), "time hour range")
    check(errs("time", "x", "time_parsing", "Input should be in a valid time format, input is too short"), "time short")
    check(errs("time", "03:04:05.", "time_parsing", "Input should be in a valid time format, second fraction digits missing after `.`"), "time frac missing")

    # ----- timedelta -----
    check(okv("timedelta", "P1DT2H"), "td iso")
    check(okv("timedelta", "PT1H"), "td iso t")
    check(okv("timedelta", "1 day, 2:00:00"), "td human day")
    check(okv("timedelta", "02:03:04"), "td hms")
    check(okv("timedelta", "-P1D"), "td neg")
    check(okv("timedelta", "0:00:00"), "td zero")
    check(errs("timedelta", "P", "time_delta_parsing", "Input should be a valid timedelta, input is too short"), "td P")
    check(errs("timedelta", "PT", "time_delta_parsing", "Input should be a valid timedelta, input is too short"), "td PT")
    check(errs("timedelta", "P1D2H", "time_delta_parsing", "Input should be a valid timedelta, quantity invalid in date part of duration"), "td qty")
    check(errs("timedelta", "1:2:3", "time_delta_parsing", "Input should be a valid timedelta, invalid character in minute"), "td minute char")
    check(errs("timedelta", "x", "time_delta_parsing", "Input should be a valid timedelta, invalid digit in duration"), "td digit")
    check(errs("timedelta", "3:04", "time_delta_parsing", "Input should be a valid timedelta, \"day\" identifier in duration not correctly formatted"), "td day id")
    check(errs("timedelta", "1 day, 25:00:00", "time_delta_parsing", "Input should be a valid timedelta, durations may not exceed 999,999,999 hours"), "td exceed")

    # ----- decimal -----
    check(okv("decimal", "3.14") and okv("decimal", "-0.5") and okv("decimal", "1e3"), "dec ok")
    check(okv("decimal", ".5") and okv("decimal", "+1") and okv("decimal", "1_000"), "dec lax")
    check(errs("decimal", "abc", "decimal_parsing", "Input should be a valid decimal"), "dec bad")
    check(errs("decimal", "", "decimal_parsing", "Input should be a valid decimal"), "dec empty")
    check(errs("decimal", "1.2.3", "decimal_parsing", "Input should be a valid decimal"), "dec double dot")
    check(errs("decimal", "nan", "finite_number", "Input should be a finite number"), "dec nan")
    check(errs("decimal", "inf", "finite_number", "Input should be a finite number"), "dec inf")

    print("scalar_types test completed!")
