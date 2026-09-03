// cmd_tests.rs — run_command_json 回归 (ADR-0010 DC2)
// 与生产代码同目录约定 (AGENTS.md §3.2)。
// 依赖系统 /bin/sh + 常用命令; 本 crate 面向 Unix (静态链接进单 binary)。
use super::cmd::run_command_json;

fn s(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

// ---------- 错误路径 ----------

#[test]
fn empty_cmd_error_json() {
    let out = run_command_json("", 1000);
    assert_eq!(s(&out), r#"{"rc":-1,"ok":false,"err":"empty cmd"}"#);
}

// ---------- 正常路径 ----------

#[test]
fn echo_stdout() {
    let out = run_command_json("echo hello", 5000);
    let text = s(&out);
    assert!(text.contains("\"rc\":0"), "got: {text}");
    assert!(text.contains("\"ok\":true"), "got: {text}");
    assert!(text.contains("\"timeout\":false"), "got: {text}");
    assert!(text.contains("\"out\":\"hello\\n\""), "got: {text}");
    assert!(text.contains("\"err\":\"\""), "got: {text}");
}

#[test]
fn exit_code_nonzero() {
    let out = run_command_json("false", 5000);
    let text = s(&out);
    assert!(text.contains("\"rc\":1"), "got: {text}");
    assert!(text.contains("\"ok\":false"), "got: {text}");
}

#[test]
fn stderr_captured() {
    let out = run_command_json("echo err 1>&2", 5000);
    let text = s(&out);
    assert!(text.contains("\"rc\":0"), "got: {text}");
    assert!(text.contains("\"err\":\"err\\n\""), "got: {text}");
    assert!(text.contains("\"out\":\"\""), "got: {text}");
}

#[test]
fn both_streams() {
    let out = run_command_json("echo o; echo e 1>&2", 5000);
    let text = s(&out);
    assert!(text.contains("\"out\":\"o\\n\""), "got: {text}");
    assert!(text.contains("\"err\":\"e\\n\""), "got: {text}");
}

#[test]
fn exit_code_and_output() {
    let out = run_command_json("echo data; exit 7", 5000);
    let text = s(&out);
    assert!(text.contains("\"rc\":7"), "got: {text}");
    assert!(text.contains("\"ok\":false"), "got: {text}");
    assert!(text.contains("\"out\":\"data\\n\""), "got: {text}");
}

#[test]
fn signal_death_rc_128_plus_sig() {
    // sh 自杀: kill -TERM $$ -> SIGTERM(15) -> rc = 143
    let out = run_command_json("kill -TERM $$", 5000);
    let text = s(&out);
    assert!(text.contains("\"rc\":143"), "got: {text}");
    assert!(text.contains("\"ok\":false"), "got: {text}");
}

#[test]
fn shell_syntax_and_env() {
    // 验证经 sh -c 执行 (非直接 exec), 变量展开/管道生效
    let out = run_command_json("X=abc; echo $X | tr a-z A-Z", 5000);
    let text = s(&out);
    assert!(text.contains("\"rc\":0"), "got: {text}");
    assert!(text.contains("\"out\":\"ABC\\n\""), "got: {text}");
}

// ---------- 超时路径 ----------

#[test]
fn timeout_kills_child_rc_137() {
    // sleep 10 被 SIGKILL (9) -> rc = 137; timeout=true
    let start = std::time::Instant::now();
    let out = run_command_json("sleep 10", 200);
    let elapsed_ms = start.elapsed().as_millis();
    let text = s(&out);
    assert!(text.contains("\"rc\":137"), "got: {text}");
    assert!(text.contains("\"timeout\":true"), "got: {text}");
    assert!(text.contains("\"ok\":false"), "got: {text}");
    // 必须显著小于 sleep 10 的全长 (允许 +2s 容差)
    assert!(elapsed_ms < 5_000, "timeout took too long: {elapsed_ms}ms");
}

#[test]
fn timeout_zero_uses_default() {
    // timeout_ms=0 -> 默认 15s; 这里验证不会立即超时 (echo 很快退出)
    let out = run_command_json("echo quick", 0);
    let text = s(&out);
    assert!(text.contains("\"rc\":0"), "got: {text}");
    assert!(text.contains("\"timeout\":false"), "got: {text}");
}

// ---------- 输出封顶 (256 KiB / 流) ----------

#[test]
fn stdout_cap_truncated_to_256k() {
    // 输出 1 MiB 的 'a' 行; JSON out 字段必须封顶在 256 KiB 附近
    let out = run_command_json("head -c 1048576 /dev/zero | tr '\\0' a", 5000);
    let text = s(&out);
    // out 字段含转义后的 'a' * 262144, 前后有 JSON 引号
    let out_field: String = text
        .split("\"out\":\"")
        .nth(1)
        .and_then(|t| t.split("\",\"err\"")
        .next())
        .map(|v| v.to_string())
        .unwrap_or_default();
    assert_eq!(out_field.len(), 256 * 1024, "out field not capped to 256KiB");
    assert!(text.contains("\"rc\":0"), "got rc not 0");
    // 子进程在管道被读尽后正常退出, 不挂死
    assert!(text.contains("\"timeout\":false"), "got: {text}");
}

// ---------- JSON 字段顺序 (与 C 字节等价) ----------

#[test]
fn json_field_order() {
    let out = run_command_json("echo hi", 5000);
    let text = s(&out);
    // 字段顺序: rc, ok, timeout, out, err
    let order = ["\"rc\":", "\"ok\":", "\"timeout\":", "\"out\":", "\"err\":"];
    let mut last = 0usize;
    for key in order {
        let idx = text.find(key).expect(&format!("missing {key} in {text}"));
        assert!(idx > last, "field {key} out of order in {text}");
        last = idx;
    }
}


#[test]
fn escaping_in_output() {
    // dash printf 的确定性行为: 格式串 x\\"y\\n (单引号内字面) ->
    // dash 不识别 \" 转义 (输出 反斜杠+引号), 识别 \n -> LF.
    // 子进程输出 5 字节: x, \, ", y, LF. json_escape -> x,\,\, \",y,\n.
    // 期望 out 字段字节 = x 5c 5c 5c 22 y 5c 6e (hex 字面, 免疫转义歧义).
    let out = run_command_json("printf 'x\\\"y\\n'", 5000);
    let expected: &[u8] = b"{\"rc\":0,\"ok\":true,\"timeout\":false,\"out\":\"x\x5c\x5c\x5c\x22y\x5c\x6e\",\"err\":\"\"}";
    assert_eq!(out, expected, "got: {}", s(&out));
}
