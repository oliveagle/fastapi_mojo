// main.rs — fmtool CLI 入口 (Track B T1+T2 工具链).
//
// 用法: fmtool <subcommand> [args...]
//
// 子命令:
//   raw      <port> <hex>            send raw bytes, print status line
//   jsoncheck [FILE|-]             validate JSON (exit 0/1)
//   cont100  <port>                  100-continue probe (print OK/FAIL dt=...)
//   keepalive <port>                 keep-alive + Connection:close + idle
//   headbody  <port>                 HEAD / body byte count
//   ws1      <port>                  WS markers M1..M6
//   ws2      <port>                  WS markers M7..M13
//   ws3      <port>                  WS markers M14..M16 (concurrent)
//   ws4      <port>                  WS markers M17..M21
//   ws5      <port>                  WS 精化 markers W1..W8 (ADR-0026, 需 CLOSE_WAIT=2000 env)
//   slowloris <port> <tmp>           half-send + probe (background)
//   wsbench  <port> <path> <n> <c>   WS load, output hey-csv to stdout
//   testclient http|ws|run   declarative TestClient equivalent (ADR-0031)
//   bench    [options]               unified benchmark runner
//   bench    --history [--limit N]   show history

mod bench;
mod csv;
mod deflate;
mod e2e;
mod http2;
mod json;
mod net;
mod ws;
mod testclient;

#[cfg(test)]
mod deflate_tests;

use std::process::ExitCode;

fn usage() -> &'static str {
    "fmtool — Rust toolchain for fastapi_mojo (Track B T1+T2, Mojo + Rust only)

USAGE:
  fmtool raw      <port> <hex>
  fmtool jsoncheck [FILE|-]  validate a JSON document (file or stdin)
  fmtool f64repr  <sec> <nsec>     bridge-identical mtime f64 Display (etag check)
  fmtool f64repr  <decimal>        f64 shortest round-trip Display
  fmtool cont100  <port>
  fmtool keepalive <port>
  fmtool headbody  <port>
  fmtool http2   <port>          prior-knowledge h2c checks H2-1..H2-7
  fmtool ws1      <port>
  fmtool ws2      <port>
  fmtool ws3      <port>
  fmtool ws4      <port>
  fmtool ws5      <port>
  fmtool wsdeflate <port>          RFC 7692 markers WSD1..WSD4
  fmtool wsmatrix <port>           WS app subprotocol markers WSP1..WSP8
  fmtool wsdeflate-off <port>       decline offered extension (WSD5)
  fmtool wsdeflate-required <port>  reject missing required offer (WSD6)
  fmtool slowloris <port> <tmp>
  fmtool wsbench  <port> <path> <n> <c>
  fmtool testclient http <METHOD> <URL> [--json J] [--data D] [--header N:V]* [--param k=v]*
                          [--cookie k=v]* [--cookie-jar F] [--no-follow] [--max-hops N]
                          [--timeout-ms N] [--json-out]
  fmtool testclient ws <URL> [--subprotocol a,b] [--action SPEC]* [--timeout-ms N]
  fmtool testclient run [--port N] [--timeout-ms N] [--readiness PATH] [--max-wait N]
                        <server-cmd...> -- <actions.jsonl>
  fmtool bench    [--scenarios F] [--json F] [--report F] [--port N]
                  [--hey BIN] [--server-dir D] [--server-cmd C]
                  [--no-server] [--no-warmup] [--db F]
                  [--history] [--limit N]
"
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprint!("{}", usage());
        return ExitCode::from(2);
    }
    let sub = &args[1];
    let rest: Vec<&str> = args[2..].iter().map(String::as_str).collect();

    let rc = match sub.as_str() {
        "raw" => run_raw(&rest),
        "jsoncheck" => run_jsoncheck(&rest),
        "f64repr" => run_f64repr(&rest),
        "cont100" => run_e2e_port("cont100", &rest, e2e::cont100),
        "keepalive" => run_e2e_port("keepalive", &rest, e2e::keepalive),
        "headbody" => run_e2e_port("headbody", &rest, e2e::headbody),
        "http2" => run_e2e_port("http2", &rest, http2::e2e),
        "ws1" => run_e2e_port("ws1", &rest, e2e::ws1),
        "ws2" => run_e2e_port("ws2", &rest, e2e::ws2),
        "ws3" => run_e2e_port("ws3", &rest, e2e::ws3),
        "ws4" => run_e2e_port("ws4", &rest, e2e::ws4),
        "ws5" => run_e2e_port("ws5", &rest, e2e::ws5),
        "wsdeflate" => run_e2e_port("wsdeflate", &rest, e2e::wsdeflate),
        "wsmatrix" => run_e2e_port("wsmatrix", &rest, e2e::wsmatrix),
        "wsdeflate-off" => run_e2e_port("wsdeflate-off", &rest, e2e::wsdeflate_off),
        "wsdeflate-required" => run_e2e_port("wsdeflate-required", &rest, e2e::wsdeflate_required),
        "slowloris" => run_slowloris(&rest),
        "wsbench" => run_wsbench(&rest),
        "testclient" => testclient::dispatch(&rest),
        "bench" => run_bench_dispatch(&rest),
        "-h" | "--help" | "help" => {
            print!("{}", usage());
            0
        }
        _ => {
            eprint!("{}", usage());
            eprintln!("\nERROR: unknown subcommand: {sub}");
            2
        }
    };
    ExitCode::from(rc as u8)
}

fn run_raw(args: &[&str]) -> i32 {
    if args.len() != 2 {
        eprintln!("usage: fmtool raw <port> <hex>");
        return 2;
    }
    let port = match args[0].parse::<u16>() {
        Ok(n) => n,
        Err(_) => { eprintln!("bad port"); return 2; }
    };
    e2e::raw(port, args[1])
}

fn run_jsoncheck(args: &[&str]) -> i32 {
    let path = args.first().copied().unwrap_or("-");
    let data = if path == "-" {
        let mut s = String::new();
        if std::io::Read::read_to_string(&mut std::io::stdin(), &mut s).is_err() {
            eprintln!("read stdin failed");
            return 2;
        }
        s
    } else {
        match std::fs::read_to_string(path) {
            Ok(x) => x,
            Err(e) => { eprintln!("read {path}: {e}"); return 2; }
        }
    };
    match json::parse(&data) {
        Ok(_) => { println!("OK"); 0 }
        Err(e) => { eprintln!("INVALID: {e}"); 1 }
    }
}

fn run_e2e_port<F: FnOnce(u16) -> i32>(name: &str, args: &[&str], f: F) -> i32 {
    if args.len() != 1 {
        eprintln!("usage: fmtool {name} <port>");
        return 2;
    }
    let port = match args[0].parse::<u16>() {
        Ok(n) => n,
        Err(_) => { eprintln!("bad port"); return 2; }
    };
    f(port)
}

fn run_slowloris(args: &[&str]) -> i32 {
    if args.len() != 2 {
        eprintln!("usage: fmtool slowloris <port> <tmp>");
        return 2;
    }
    let port = match args[0].parse::<u16>() {
        Ok(n) => n,
        Err(_) => { eprintln!("bad port"); return 2; }
    };
    e2e::slowloris(port, args[1])
}

fn run_wsbench(args: &[&str]) -> i32 {
    if args.len() != 4 {
        eprintln!("usage: fmtool wsbench <port> <path> <n> <c>");
        return 2;
    }
    let port = match args[0].parse::<u16>() {
        Ok(n) => n,
        Err(_) => { eprintln!("bad port"); return 2; }
    };
    let path = args[1];
    let n = match args[2].parse::<usize>() {
        Ok(n) => n,
        Err(_) => { eprintln!("bad n"); return 2; }
    };
    let c = match args[3].parse::<usize>() {
        Ok(n) => n,
        Err(_) => { eprintln!("bad c"); return 2; }
    };
    println!("response-time,offset,status-code");
    let rows = bench::ws_load(port, path, n, c);
    for (rt, off, st) in &rows {
        println!("{rt},{off},{st}");
    }
    0
}

fn run_bench_dispatch(args: &[&str]) -> i32 {
    let mut opts = bench::BenchOpts {
        scenarios: None,
        json: None,
        report: None,
        port: 8000,
        hey: "hey".into(),
        server_dir: "src/fastapi_mojo".into(),
        server_cmd: "../../build/fastapi_mojo".into(),
        no_server: false,
        no_warmup: false,
        db: None,
        history: false,
        limit: 10,
    };
    let mut i = 0;
    while i < args.len() {
        let a = args[i];
        match a {
            "--scenarios" => { opts.scenarios = args.get(i+1).map(|s| s.to_string()); i += 2; }
            "--json" => { opts.json = args.get(i+1).map(|s| s.to_string()); i += 2; }
            "--report" => { opts.report = args.get(i+1).map(|s| s.to_string()); i += 2; }
            "--port" => {
                if let Some(v) = args.get(i+1) {
                    if let Ok(n) = v.parse() { opts.port = n; }
                }
                i += 2;
            }
            "--hey" => { opts.hey = args.get(i+1).map(|s| s.to_string()).unwrap_or_default(); i += 2; }
            "--server-dir" => { opts.server_dir = args.get(i+1).map(|s| s.to_string()).unwrap_or_default(); i += 2; }
            "--server-cmd" => { opts.server_cmd = args.get(i+1).map(|s| s.to_string()).unwrap_or_default(); i += 2; }
            "--db" => { opts.db = args.get(i+1).map(|s| s.to_string()); i += 2; }
            "--limit" => {
                if let Some(v) = args.get(i+1) {
                    if let Ok(n) = v.parse() { opts.limit = n; }
                }
                i += 2;
            }
            "--no-server" => { opts.no_server = true; i += 1; }
            "--no-warmup" => { opts.no_warmup = true; i += 1; }
            "--history" => { opts.history = true; i += 1; }
            _ => {
                eprintln!("unknown bench option: {a}");
                return 2;
            }
        }
    }
    bench::run_bench(&opts)
}

/// f64repr — 打印 f64 的最短 round-trip Display（etag 交叉验证用）。
///   f64repr <sec> <nsec>  — 与 bridge stat_file 完全相同的算术
///                            （sec as f64 + nsec as f64 * 1e-9 → Display），
///                            e2e 用 `stat -c '%Y %n'` 供参，保证 md5 输入
///                            与 bridge 逐位一致；
///   f64repr <decimal>     — 十进制字符串 parse → f64 → Display。
fn run_f64repr(args: &[&str]) -> i32 {
    if args.len() == 2 {
        match (args[0].parse::<f64>(), args[1].parse::<f64>()) {
            (Ok(sec), Ok(nsec)) => {
                // 与 bridge stat_file 同一表达式: sec + (nsec * 1e-9)
                let f = sec + nsec * 1e-9;
                println!("{f}");
                0
            }
            _ => {
                eprintln!("usage: fmtool f64repr <sec> <nsec>");
                2
            }
        }
    } else if args.len() == 1 {
        match args[0].parse::<f64>() {
            Ok(f) => {
                println!("{f}");
                0
            }
            Err(_) => {
                eprintln!("not a number: {}", args[0]);
                2
            }
        }
    } else {
        eprintln!("usage: fmtool f64repr <sec> <nsec> | <decimal>");
        2
    }
}
