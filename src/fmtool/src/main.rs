// main.rs — fmtool CLI 入口 (Track B T1+T2 工具链).
//
// 用法: fmtool <subcommand> [args...]
//
// 子命令:
//   raw      <port> <hex>            send raw bytes, print status line
//   cont100  <port>                  100-continue probe (print OK/FAIL dt=...)
//   keepalive <port>                 keep-alive + Connection:close + idle
//   headbody  <port>                 HEAD / body byte count
//   ws1      <port>                  WS markers M1..M6
//   ws2      <port>                  WS markers M7..M13
//   ws3      <port>                  WS markers M14..M16 (concurrent)
//   ws4      <port>                  WS markers M17..M21
//   slowloris <port> <tmp>           half-send + probe (background)
//   wsbench  <port> <path> <n> <c>   WS load, output hey-csv to stdout
//   bench    [options]               unified benchmark runner
//   bench    --history [--limit N]   show history

mod bench;
mod csv;
mod e2e;
mod json;
mod net;
mod ws;

use std::process::ExitCode;

fn usage() -> &'static str {
    "fmtool — Rust toolchain for fastapi_mojo (Track B T1+T2, Mojo + Rust only)

USAGE:
  fmtool raw      <port> <hex>
  fmtool cont100  <port>
  fmtool keepalive <port>
  fmtool headbody  <port>
  fmtool ws1      <port>
  fmtool ws2      <port>
  fmtool ws3      <port>
  fmtool ws4      <port>
  fmtool slowloris <port> <tmp>
  fmtool wsbench  <port> <path> <n> <c>
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
        "cont100" => run_e2e_port("cont100", &rest, e2e::cont100),
        "keepalive" => run_e2e_port("keepalive", &rest, e2e::keepalive),
        "headbody" => run_e2e_port("headbody", &rest, e2e::headbody),
        "ws1" => run_e2e_port("ws1", &rest, e2e::ws1),
        "ws2" => run_e2e_port("ws2", &rest, e2e::ws2),
        "ws3" => run_e2e_port("ws3", &rest, e2e::ws3),
        "ws4" => run_e2e_port("ws4", &rest, e2e::ws4),
        "slowloris" => run_slowloris(&rest),
        "wsbench" => run_wsbench(&rest),
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
