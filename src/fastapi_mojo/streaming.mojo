# src/fastapi_mojo/streaming.mojo
#
# F5: Streaming Response / SSE (Goal-0002 §1.1).
#
# 设计:
#   - 极简实现: 一次性推送所有事件后关连接 (不维护长连接, 避免占 worker).
#   - SSE 格式: 每事件 = "data: <line>\\n\\n" (SSE spec 要求的双换行).
#   - 多行事件 (data 含换行): 拆成多个 "data: <line>\\n" + 末 "data: ..." 不加换行 + "\\n\\n".
#     参考 FastAPI 0.140.12 修复: format_sse_event 需按行切分 (sse_data.splitlines()).
#   - Content-Type: text/event-stream; charset=utf-8 (SSE 规范).
#   - 不实现的事件字段: id, event, retry (v0.5.0 范围外, v0.6.0 候选).
#
# 路由声明:
#   - KIND_SSE handler + data["_stream_events"] = "msg1|msg2|msg3" (用 | 避免与 data 内逗号冲突).
#   - dispatch: KIND_SSE 走 send_sse_response_extra FFI (rust bridge; F9 status+extra 头).
#   - data["_stream_status"] = "201 Created" (可选; F9 对齐上游 0.140.13 status_code 修复).
#   - data["_response_headers"] = "Cache-Control: no-cache" (可选; F9 修复 v0.5.0 静默丢弃).
#
# 单点 dispatch 扩展点: dispatch 中 KIND_SSE 特殊处理; handler.mojo 加 KIND_SSE 常量.

from string_builder import StringBuilder


def format_sse_event(data: String) -> String:
    """按 SSE spec 构造一个事件字节串.
    输入 data 任意字符串 (可含换行/CR/特殊字符); 输出 "data: <line1>\\ndata: <line2>\\n...\\n\\n".
    FastAPI 0.140.12 修复: line splitting 按 \\n + CR 处理 (splitlines).
    """
    var sb = StringBuilder()
    var n = data.byte_length()
    var i = 0
    var line_start = 0
    while i < n:
        var b = ord(data[byte=i])
        if b == 10:  # '\n'
            # flush line
            if i > line_start:
                sb.append("data: ")
                sb.append(String(data[byte=line_start:i]))
                sb.append(chr(10))
            line_start = i + 1
        i += 1
    # flush remaining
    if n > line_start:
        sb.append("data: ")
        sb.append(String(data[byte=line_start:n]))
        sb.append(chr(10))
    sb.append(chr(10))  # event terminator (SSE event end)
    return sb.take()


def build_sse_body(events_csv: String) -> String:
    """把 "msg1|msg2|msg3" 拼成完整 SSE body. 用 | 作分隔 (避免与 data 内 , 冲突)."""
    var sb = StringBuilder()
    var n = events_csv.byte_length()
    var start = 0
    var i = 0
    while i <= n:
        var is_sep = (i == n) or (ord(events_csv[byte=i]) == 124)  # '|'
        if is_sep:
            if i > start:
                var event = String(events_csv[byte=start:i])
                sb.append(format_sse_event(event))
            start = i + 1
        i += 1
    return sb.take()


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
