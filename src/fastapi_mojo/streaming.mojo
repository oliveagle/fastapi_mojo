# src/fastapi_mojo/streaming.mojo
#
# F5 + 决策-72: Streaming Response / SSE (Goal-0002 §1.1 / FastAPI 0.141 SSE).
#
# 设计:
#   - 极简实现: 一次性推送所有事件后关连接 (不维护长连接, 避免占 worker).
#   - SSE 事件 wire format = 上游 `fastapi.sse.format_sse_event` (逐字节对齐):
#       字段序 comment(可多行 `: `) -> event -> data(逐行 `data: `) -> id -> retry,
#       末尾事件终止符 `\n\n`.
#   - 行切分 = 上游 `_split_sse_lines`: `\r\n`/`\r` -> `\n`, split 保留**尾空串**.
#   - Content-Type: text/event-stream; charset=utf-8 (SSE 规范).
#   - `data` 语义 = 上游 `raw_data`(原样, 不 JSON 编码; 本仓库声明式既有语义).
#
# 路由声明:
#   - KIND_SSE handler + data["_stream_events"] = "msg1|msg2|msg3" (用 | 避免与 data 内逗号冲突).
#   - data["_sse_event"] / ["_sse_id"] / ["_sse_retry"] / ["_sse_comment"] = 可选事件字段
#     (决策-72, 路由级: 施加到每个事件; 上游 `ServerSentEvent` 允许逐事件 — 见 ADR-0047 边界).
#   - data["_stream_status"] = "201 Created" (可选; F9 对齐上游 0.140.13 status_code 修复).
#   - data["_response_headers"] = "Cache-Control: no-cache" (可选; F9 修复 v0.5.0 静默丢弃).
#
# 单点 dispatch 扩展点: dispatch 中 KIND_SSE 特殊处理; handler.mojo 加 KIND_SSE 常量.

from string_builder import StringBuilder


def _split_sse_lines(value: String) -> List[String]:
    """SSE 行切分 (上游 FastAPI `_split_sse_lines`): `\\r\\n`/`\\r` -> `\\n`,
    split 保留尾空串 (data 以 `\\n` 结尾 -> 多一个空 `data:` 行)."""
    var sb = StringBuilder()
    var n = value.byte_length()
    var i = 0
    while i < n:
        var b = ord(value[byte=i])
        if b == 13:  # '\r'
            sb.append(chr(10))
            if i + 1 < n and ord(value[byte=i + 1]) == 10:
                i += 1
        else:
            sb.append_byte(b)
        i += 1
    var s = sb.take()
    var out = List[String]()
    var m = s.byte_length()
    var start = 0
    var j = 0
    while j <= m:
        if (j == m) or (ord(s[byte=j]) == 10):
            out.append(String(s[byte=start:j]))
            start = j + 1
        j += 1
    return out^


def format_sse_event_full(data: String, event: String, eid: String, retry: String,
                          comment: String) -> String:
    """构造一个 SSE 事件字节串 (上游 `format_sse_event` 逐字节对齐).

    字段序: comment (`: <line>`) -> `event:` -> `data:` (逐行) -> `id:` -> `retry:`,
    末尾追加事件终止符 (空行). 空串字段 = 不输出该字段."""
    var sb = StringBuilder()
    if comment != "":
        for line in _split_sse_lines(comment):
            sb.append(": ")
            sb.append(line)
            sb.append(chr(10))
    if event != "":
        sb.append("event: ")
        sb.append(event)
        sb.append(chr(10))
    for line in _split_sse_lines(data):
        sb.append("data: ")
        sb.append(line)
        sb.append(chr(10))
    if eid != "":
        sb.append("id: ")
        sb.append(eid)
        sb.append(chr(10))
    if retry != "":
        sb.append("retry: ")
        sb.append(retry)
        sb.append(chr(10))
    sb.append(chr(10))  # event terminator (SSE event end)
    return sb.take()


def format_sse_event(data: String) -> String:
    """按 SSE spec 构造一个 data-only 事件 (兼容既有调用; 等价
    `format_sse_event_full(data, "", "", "", "")`)."""
    return format_sse_event_full(data, "", "", "", "")


def build_sse_body_fields(events_csv: String, event: String, eid: String, retry: String,
                          comment: String) -> String:
    """`|` 分隔的 data 事件 + 路由级字段 -> 完整 SSE body."""
    var sb = StringBuilder()
    var n = events_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(events_csv[byte=i]) == 124)  # '|'
        if is_sep:
            if i > start:
                sb.append(format_sse_event_full(String(events_csv[byte=start:i]),
                                                event, eid, retry, comment))
            start = i + 1
        i += 1
    return sb.take()


def build_sse_body(events_csv: String) -> String:
    """把 "msg1|msg2|msg3" 拼成完整 SSE body (data-only; 兼容既有调用)."""
    return build_sse_body_fields(events_csv, "", "", "", "")


def sse_event_count(events_csv: String) -> Int:
    """事件数 = | 分隔数 + 1 (非空)."""
    var n = events_csv.byte_length()
    if n == 0:
        return 0
    var count = 1
    for i in range(n):
        if ord(events_csv[byte=i]) == 124:
            count += 1
    return count


def _check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


def main() raises:
    # data-only (既有语义, 上游 format_sse_event(data_str=...))
    _check(format_sse_event("hello") == "data: hello\n\n", "single")
    _check(format_sse_event("line1\nline2") == "data: line1\ndata: line2\n\n", "multiline")
    _check(format_sse_event("tail\n") == "data: tail\ndata: \n\n", "trailing newline keeps empty")
    _check(format_sse_event("a\r\nb\rc") == "data: a\ndata: b\ndata: c\n\n", "crlf+cr")
    _check(format_sse_event("") == "data: \n\n", "empty data")
    # fields (上游全字段顺序)
    _check(format_sse_event_full("d", "e", "7", "5", "c1\nc2") ==
           ": c1\n: c2\nevent: e\ndata: d\nid: 7\nretry: 5\n\n", "all fields order")
    _check(format_sse_event_full("x", "", "", "3000", "") == "data: x\nretry: 3000\n\n", "retry only")
    _check(format_sse_event_full("hi", "msg", "", "", "") == "event: msg\ndata: hi\n\n", "event+data")
    _check(format_sse_event_full("", "", "", "", "ping") == ": ping\ndata: \n\n", "comment+empty data")
    # body
    _check(build_sse_body_fields("a|b", "e", "", "", "") ==
           "event: e\ndata: a\n\nevent: e\ndata: b\n\n", "body fields 2 events")
    _check(build_sse_body("a|b") == "data: a\n\ndata: b\n\n", "body data-only")
    _check(sse_event_count("a|b|c") == 3 and sse_event_count("") == 0, "count")
    print("streaming self-test: OK")
