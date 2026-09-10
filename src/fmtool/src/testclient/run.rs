// testclient/run.rs — the `testclient run` subcommand:
// spawn the server, poll readiness, execute a JSONL action script,
// send SIGTERM, verify the server exits cleanly (code 0).
//
// Usage:
//   fmtool testclient run [--port N] [--timeout-ms N] [--readiness PATH]
//                         [--max-wait N] <server-cmd...> -- <actions.jsonl>
//
// Actions file: one JSON object per line:
//   {"op":"http","method":"GET","url":"...","expect_status":200,"expect_body":"..."}
//   {"op":"ws","url":"ws://...","actions":["send-text:hi","receive-text:hi"]}
//
// Exit codes: 0 all actions passed and server_exit=0 / 1 otherwise / 2 bad args.

use std::fs::File;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use super::http::{HttpOpts, http_request};
use super::ws::ws_core;
use super::{Action, CookieJar, parse_action};
use crate::json::{self, Value};

pub struct RunOpts {
    pub port: Option<u16>,
    pub timeout_ms: u64,
    pub readiness: String,
    pub max_wait: u64,
    pub server_cmd: Vec<String>,
    pub actions_file: String,
}

pub fn run_cli(args: &[&str]) -> i32 {
    if args.is_empty() {
        eprintln!("usage: fmtool testclient run [--port N] [--timeout-ms N] [--readiness PATH] [--max-wait N] <server-cmd...> -- <actions.jsonl>");
        return 2;
    }
    let mut opts = RunOpts {
        port: None,
        timeout_ms: 5000,
        readiness: "/health".to_string(),
        max_wait: 10,
        server_cmd: Vec::new(),
        actions_file: String::new(),
    };
    // The last "--" separates the actions file; everything before it is
    // options + server-cmd (a leading cosmetic "--" after options is allowed).
    let sep = match args.iter().rposition(|a| *a == "--") {
        Some(i) => i,
        None => {
            eprintln!("ERROR: missing the trailing ' -- <actions.jsonl>'");
            return 2;
        }
    };
    opts.actions_file = args[sep + 1..].join(" ");
    let left = &args[..sep];
    let mut i = 0;
    while i < left.len() {
        let a = left[i];
        if a == "--" {
            i += 1;
            continue;
        }
        match a {
            "--port" => {
                if let Ok(n) = left.get(i + 1).copied().unwrap_or("").parse() {
                    opts.port = Some(n);
                }
                i += 2;
            }
            "--timeout-ms" => {
                if let Ok(n) = left.get(i + 1).copied().unwrap_or("").parse() {
                    opts.timeout_ms = n;
                }
                i += 2;
            }
            "--readiness" => {
                opts.readiness = left.get(i + 1).copied().unwrap_or("").to_string();
                i += 2;
            }
            "--max-wait" => {
                if let Ok(n) = left.get(i + 1).copied().unwrap_or("").parse() {
                    opts.max_wait = n;
                }
                i += 2;
            }
            _ => {
                opts.server_cmd.push(a.to_string());
                i += 1;
            }
        }
    }
    if opts.server_cmd.is_empty() {
        eprintln!("ERROR: server-cmd is empty");
        return 2;
    }
    if opts.actions_file.is_empty() {
        eprintln!("ERROR: actions file missing (expected: ... -- <actions.jsonl>)");
        return 2;
    }
    run_core(&opts)
}

fn run_core(opts: &RunOpts) -> i32 {
    let mut cmd = Command::new(&opts.server_cmd[0]);
    for a in &opts.server_cmd[1..] {
        cmd.arg(a);
    }
    if let Some(p) = opts.port {
        cmd.arg("--port");
        cmd.arg(p.to_string());
    }
    let log_path = format!("/tmp/fm_tcl_run_{}.log", std::process::id());
    match File::create(&log_path) {
        Ok(log) => {
            cmd.stdout(Stdio::from(log)).stderr(Stdio::null());
        }
        Err(e) => {
            eprintln!("ERROR: cannot create {log_path}: {e}");
            return 1;
        }
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ERROR: spawn failed: {e}");
            return 1;
        }
    };
    // fresh-bind stability (~Caddy transparent-proxy pollution, e2e convention)
    thread::sleep(Duration::from_secs(3));
    // readiness poll
    let mut ready = false;
    let deadline = Instant::now() + Duration::from_secs(opts.max_wait);
    let mut jar = CookieJar { entries: Vec::new() };
    let hopts = HttpOpts::default();
    let port = opts.port.unwrap_or(8000);
    let url = format!("http://127.0.0.1:{port}{}", opts.readiness);
    while Instant::now() < deadline && !ready {
        if let Ok(r) = http_request(&url, "GET", &hopts, &mut jar) {
            let body = String::from_utf8_lossy(&r.body).into_owned();
            if r.status == 200 && body.contains("healthy") {
                ready = true;
            }
        }
        thread::sleep(Duration::from_millis(300));
    }
    if !ready {
        kill_term(child.id());
        let _ = child.wait();
        eprintln!("ERROR: server did not become ready; log: {log_path}");
        return 1;
    }
    // execute the actions file
    let actions_txt = std::fs::read_to_string(&opts.actions_file).unwrap_or_default();
    let mut passed = 0;
    let mut failed = 0;
    for (i, line) in actions_txt.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if eval_line(line, opts.timeout_ms) {
            println!("PASS {i} {line}");
            passed += 1;
        } else {
            println!("FAIL {i} {line}");
            failed += 1;
        }
    }
    // shutdown: SIGTERM, wait up to 5 s, else SIGKILL
    kill_term(child.id());
    let mut server_exit: i32 = -1;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(st)) => {
                server_exit = status_code(&st);
                break;
            }
            Ok(None) => thread::sleep(Duration::from_millis(250)),
            Err(e) => {
                eprintln!("ERROR: try_wait: {e}");
                break;
            }
        }
    }
    if server_exit == -1 {
        let _ = child.kill();
        let _ = child.wait();
        eprintln!("ERROR: server did not exit on SIGTERM (SIGKILLed)");
    }
    println!("run: {passed} passed, {failed} failed; server_exit={server_exit}; log: {log_path}");
    if failed == 0 && server_exit == 0 {
        0
    } else {
        1
    }
}

/// SIGTERM via the coreutils `kill` binary (fmtool has zero crate deps — no libc).
fn kill_term(pid: u32) {
    let _ = Command::new("kill").arg("-TERM").arg(pid.to_string()).status();
}

fn status_code(st: &ExitStatus) -> i32 {
    // None = terminated by signal (e.g. SIGKILL after the SIGTERM timeout)
    st.code().unwrap_or(128)
}

fn eval_line(line: &str, timeout_ms: u64) -> bool {
    let v = match json::parse(line) {
        Ok(v) => v,
        Err(_) => {
            eprintln!("  [bad action line: not JSON]");
            return false;
        }
    };
    let op = v.get("op").and_then(|x| x.as_str()).unwrap_or("");
    match op {
        "http" => {
            let method = v.get("method").and_then(|x| x.as_str()).unwrap_or("GET");
            let url = v.get("url").and_then(|x| x.as_str()).unwrap_or("");
            let expect_status = v
                .get("expect_status")
                .and_then(|x| x.as_num())
                .map(|n| n as u16)
                .unwrap_or(0);
            let expect_body = v.get("expect_body").and_then(|x| x.as_str()).unwrap_or("");
            let mut jar = CookieJar { entries: Vec::new() };
            let hopts = HttpOpts::default();
            match http_request(url, method, &hopts, &mut jar) {
                Ok(r) => {
                    if expect_status != 0 && r.status != expect_status {
                        return false;
                    }
                    if !expect_body.is_empty() {
                        let body = String::from_utf8_lossy(&r.body).into_owned();
                        if !body.contains(expect_body) {
                            return false;
                        }
                    }
                    true
                }
                Err(_) => false,
            }
        }
        "ws" => {
            let url = v.get("url").and_then(|x| x.as_str()).unwrap_or("");
            let raw: Vec<Value> = v
                .get("actions")
                .and_then(|x| x.as_arr())
                .cloned()
                .unwrap_or_default();
            let mut actions: Vec<Action> = Vec::new();
            for a in &raw {
                match a.as_str() {
                    Some(spec) => match parse_action(spec) {
                        Ok(act) => actions.push(act),
                        Err(m) => {
                            eprintln!("  [bad ws action: {m}]");
                            return false;
                        }
                    },
                    None => return false,
                }
            }
            ws_core(url, &actions, timeout_ms, "") == 0
        }
        _ => {
            eprintln!("  [unknown op: {op}]");
            false
        }
    }
}
