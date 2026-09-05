# src/fastapi_mojo/lifespan.mojo
#
# Lifespan (决策-36, Goal-0003 P1): 声明式 startup/shutdown shell 命令.
#
# FastAPI 语义: `lifespan` 上下文管理器 — yield 前 = startup, yield 后 = shutdown;
# 每进程一次; startup 失败 -> 服务不启动 (进程退出).
#
# Mojo 1.0.0 无闭包 / async / lifespan 对象 -> 声明式 env 命令 (换行分隔),
# 经 run_command_json FFI 执行 (/bin/sh -c + fork/poll + 进程组 timeout kill,
# 与 F11 BackgroundTasks 同一机制):
#   - FASTAPI_MOJO_LIFESPAN_STARTUP    startup 命令 (换行分隔)
#   - FASTAPI_MOJO_LIFESPAN_SHUTDOWN   shutdown 命令 (换行分隔)
#   - FASTAPI_MOJO_LIFESPAN_TIMEOUT_MS 单条命令 timeout (默认 30000 ms)
#
# 多 worker (ADR-0005, re-exec 模型): 仅主进程 (worker_id=0) 执行, 对齐
# nginx master init; re-exec 出的 worker (worker_id>0) 跳过.
#
# 核心 (http_server_final) 只调用两个入口:
#   - run_lifespan_startup(worker_id)   bind 之后, serve 之前
#   - run_lifespan_shutdown(worker_id)  serve_forever 返回之后
# 新增 lifespan 行为 = 本文件内扩展; 核心零改动 (ADR-0004 扩展点模式).

from std.ffi import external_call, CStringSlice
from string_builder import span_to_str


def _parse_cmd_rc(json: String) -> Int:
    """从 run_command_json 输出 `{"rc":N,"ok":..,"out":"..","err":".."}` 解析 rc.

    第一个出现的 `"rc":` 即真实 rc (cmd.rs 固定 key 序); 未找到 -> -1 (视为失败).
    逐字节匹配 (输出为 ASCII JSON, 无 codepoint 边界问题).
    """
    var n = json.byte_length()
    var i = 0
    while i + 5 <= n:
        if (ord(json[byte=i]) == 34 and ord(json[byte=i + 1]) == 114 and
            ord(json[byte=i + 2]) == 99 and ord(json[byte=i + 3]) == 34 and
            ord(json[byte=i + 4]) == 58):
            var j = i + 5
            var neg = False
            if j < n and ord(json[byte=j]) == 45:
                neg = True
                j += 1
            var val = 0
            while j < n:
                var c = ord(json[byte=j])
                if c < 48 or c > 57:
                    break
                val = val * 10 + (c - 48)
                j += 1
            if neg:
                val = -val
            return val
        i += 1
    return -1


def _run_commands(raw: String, timeout_ms: Int, tag: String) raises -> Bool:
    """执行换行分隔的命令列表 (每行 trim 空白, 空行跳过).

    返回 True 当且仅当全部命令 rc=0. 每条命令输出一行 [lifespan] 日志
    (tag + rc + cmd + 截断 out).
    """
    var n = raw.byte_length()
    var start = 0
    var i = 0
    var all_ok = True
    while i <= n:
        var is_sep = (i == n) or (ord(raw[byte=i]) == 10)  # '\n'
        if is_sep:
            if i > start:
                var cmd = String(raw[byte=start:i])
                # trim leading/trailing whitespace (与 _run_background 同模式)
                var b = 0
                var e = cmd.byte_length()
                while b < e and (ord(cmd[byte=b]) == 32 or ord(cmd[byte=b]) == 9):
                    b += 1
                while e > b and (ord(cmd[byte=e - 1]) == 32 or ord(cmd[byte=e - 1]) == 9):
                    e -= 1
                if e > b:
                    var final_cmd = String(cmd[byte=b:e])
                    var slice = external_call["run_command_json", CStringSlice[origin_of(String(""))]](
                        final_cmd.as_c_string_slice(), Int64(timeout_ms))
                    var out = span_to_str(slice.as_bytes())
                    _ = external_call["run_command_free", NoneType](slice)
                    var rc = _parse_cmd_rc(out)
                    print("[lifespan] " + tag + " rc=" + String(rc) + " cmd=" + final_cmd
                          + " out=" + out[byte=0:min(out.byte_length(), 160)])
                    if rc != 0:
                        all_ok = False
            start = i + 1
        i += 1
    return all_ok


def run_lifespan_startup(worker_id: Int) raises:
    """Lifespan startup (serve 之前). 仅主进程 (worker_id=0) 执行.

    任一命令 rc!=0 -> 打印 ERROR 并 bridge_fail (进程退出, 服务不启动,
    对齐 FastAPI lifespan 异常 -> uvicorn 启动失败语义).
    """
    if worker_id > 0:
        return
    var raw = span_to_str(
        external_call["get_lifespan_startup_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
    if raw == "":
        return
    var timeout_ms = external_call["get_lifespan_timeout_ms", Int64]()
    var ok = _run_commands(raw, Int(timeout_ms), "startup")
    if not ok:
        print("ERROR: lifespan startup failed — refusing to serve (FastAPI lifespan semantics).")
        external_call["bridge_fail", NoneType]()


def run_lifespan_shutdown(worker_id: Int) raises:
    """Lifespan shutdown (serve_forever 返回之后). 仅主进程执行.

    失败只记日志 (命令 rc!=0 已输出), 不阻塞进程退出.
    """
    if worker_id > 0:
        return
    var raw = span_to_str(
        external_call["get_lifespan_shutdown_slice", CStringSlice[origin_of(String(""))]]().as_bytes())
    if raw == "":
        return
    var timeout_ms = external_call["get_lifespan_timeout_ms", Int64]()
    _ = _run_commands(raw, Int(timeout_ms), "shutdown")


def main() raises:
    """自测: _parse_cmd_rc 向量 (含负数 / 缺失 / out 内假 rc 干扰)."""
    assert _parse_cmd_rc('{"rc":0,"ok":true,"timeout":false,"out":"","err":""}') == 0, "rc=0"
    assert _parse_cmd_rc('{"rc":3,"ok":false,"err":"x"}') == 3, "rc=3"
    assert _parse_cmd_rc('{"rc":-1,"ok":false,"err":"spawn failed"}') == -1, "rc=-1"
    assert _parse_cmd_rc('{"rc":137,"ok":false,"out":"a"}') == 137, "rc=137"
    assert _parse_cmd_rc('{"rc":128,"ok":false,"out":"killed"}') == 128, "rc=128"
    assert _parse_cmd_rc('no rc field here') == -1, "missing -> -1"
    # 第一个 "rc": 优先 (out 里的干扰文本不影响)
    assert _parse_cmd_rc('{"rc":0,"out":"fake \"rc\":9"}') == 0, "first rc wins"
    print("lifespan self-test passed")
