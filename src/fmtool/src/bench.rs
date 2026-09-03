// bench.rs — 统一 Benchmark runner (Track B T1: 替代 bench.py, 零 Python).
//
// 行为对齐 bench.py:
//   1. 启动被测服务器 (默认 build/fastapi_mojo, --server-cmd 覆盖)
//   2. 预热 (默认 2000 req / 50 并发)
//   3. 按场景压测: HTTP 走 hey (csv 逐请求输出); WS (url 以 ws:// 开头)
//      用内置 Rust WS 负载客户端 (echo 往返逐条计时)
//   4. 解析 csv, 计算统一统计量 (吞吐 / 延迟分位 / 错误数)
//   5. 每次运行追加写入 JSONL 历史 (docs/reports/auto/benchmark.jsonl),
//      替代原 SQLite (benchmark.db) — 零第三方依赖
//   6. 输出统一格式 JSON (--json 或 stdout)
//   7. --report 由 JSON 生成 Markdown
//   8. --history 查看历史
//
// 用法:
//   fmtool bench --scenarios F --json out.json --report out.md
//   fmtool bench --history [--limit N]
//   fmtool wsbench <port> <path> <n> <c>    (独立 WS 负载, hey-csv 输出)

use crate::csv::Csv;
use crate::json::{self, Value};
use crate::net::{send_exact, tcp_connect, DEFAULT_TIMEOUT};
use crate::ws;
use std::io::{Read, Write};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const WARMUP_N: usize = 2000;
const WARMUP_C: usize = 50;
const STARTUP_WAIT: u64 = 20;

// ---------- Server 生命周期 ----------

pub struct Server {
    proc: Option<std::process::Child>,
}

impl Server {
    pub fn start(server_cmd: &str, server_dir: &str, port: u16, no_server: bool) -> Server {
        let mut s = Server { proc: None };
        if no_server {
            return s;
        }
        let mut parts = server_cmd.split_whitespace();
        let bin = parts.next().unwrap_or("").to_string();
        let mut args: Vec<String> = parts.map(|s| s.to_string()).collect();
        // 服务器监听端口必须跟随 --port (bench.py 同样如此: server_cmd 不带端口).
        args.push("--port".into());
        args.push(port.to_string());
        // server_cmd 是相对 --server-dir 的 (文档语义), 解析成绝对路径再 spawn,
        // 避免 execvp 相对父进程 cwd 解析导致 "No such file or directory".
        let full = std::path::Path::new(server_dir).join(&bin);
        let abs = std::fs::canonicalize(&full).unwrap_or(full);
        // 服务器 stdout/stderr 丢弃 (bench.py 同样用 DEVNULL): 避免 10k 条
        // access log 灌满 bench 输出, 也避免上游管道 (head/awk) 提前关闭时
        // SIGPIPE 杀掉 server 导致端口残留孤儿进程 (实测 hang 根因)。
        match Command::new(&abs)
            .args(&args)
            .current_dir(server_dir)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn() {
            Ok(child) => s.proc = Some(child),
            Err(e) => {
                eprintln!("[bench] 无法启动服务器 {bin}: {e}");
                std::process::exit(1);
            }
        }
        // 等待 /health 200
        let deadline = Instant::now() + Duration::from_secs(STARTUP_WAIT);
        loop {
            if http_get_200(port) {
                return s;
            }
            if Instant::now() > deadline {
                eprintln!("[bench] 服务器未在 {STARTUP_WAIT}s 内就绪 (port {port})");
                std::process::exit(1);
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.proc.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn http_get_200(port: u16) -> bool {
    let mut s = match tcp_connect(&format!("127.0.0.1:{port}"), Duration::from_secs(1)) {
        Ok(s) => s,
        Err(_) => return false,
    };
    if send_exact(&mut s, b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").is_err() {
        return false;
    }
    let mut buf = Vec::new();
    let mut tmp = [0u8; 1024];
    s.set_read_timeout(Some(Duration::from_secs(1))).ok();
    while let Ok(n) = s.read(&mut tmp) {
        if n == 0 { break; }
        buf.extend_from_slice(&tmp[..n]);
    }
    buf.starts_with(b"HTTP/1.1 200")
}

// ---------- WS 负载 (hey-csv 同构) ----------

/// 返回 (response-time, offset, status-code) 行列表
pub fn ws_load(port: u16, path: &str, n: usize, c: usize) -> Vec<(String, String, String)> {
    let rows: Arc<Mutex<Vec<(String, String, String)>>> = Arc::new(Mutex::new(Vec::new()));
    let mut handles = Vec::new();
    let port2 = port;
    let path2 = path.to_string();
    for wid in 0..c {
        let rows = Arc::clone(&rows);
        let path2 = path2.clone();
        handles.push(std::thread::spawn(move || {
            let share = n / c + if wid < n % c { 1 } else { 0 };
            let t_start = Instant::now();
            let mut done = 0usize;
            let ok = (|| -> Result<(), String> {
                let mut s = tcp_connect(&format!("127.0.0.1:{port2}"), DEFAULT_TIMEOUT)
                    .map_err(|e| e.to_string())?;
                let (statuses, _, _) = ws::connect_and_handshake(&mut s, port2, &path2, "")
                    .map_err(|e| e.to_string())?;
                if !statuses[0].starts_with("HTTP/1.1 101") {
                    return Err(format!("upgrade {}", statuses[0]));
                }
                for i in 0..share {
                    let payload = format!("benchmark-{i}");
                    let m = rand4();
                    let frame = ws::make_frame(0x1, payload.as_bytes(), true, &m);
                    let t0 = Instant::now();
                    s.write_all(&frame).map_err(|e| e.to_string())?;
                    let f = ws::recv_frame(&mut s).map_err(|e| e.to_string())?;
                    let dt = t0.elapsed().as_secs_f64();
                    let ok = f.op == 0x1 && f.payload == payload.as_bytes();
                    let offset = t_start.elapsed().as_secs_f64();
                    rows.lock().unwrap().push((
                        format!("{:.6}", dt),
                        format!("{:.6}", offset),
                        if ok { "200" } else { "500" }.to_string(),
                    ));
                    done += 1;
                    if !ok {
                        break;
                    }
                }
                let m = rand4();
                let close = ws::make_frame(0x8, &1000u16.to_be_bytes(), true, &m);
                let _ = s.write_all(&close);
                Ok(())
            })();
            if ok.is_err() {
                let t_fail = t_start.elapsed().as_secs_f64();
                let mut rows = rows.lock().unwrap();
                for _ in done..share {
                    rows.push(("0.000000".into(), format!("{:.6}", t_fail), "000".into()));
                }
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let mut out = Vec::new();
    for r in rows.lock().unwrap().iter() {
        out.push(r.clone());
    }
    out
}

fn rand4() -> [u8; 4] {
    let r = ws::random_bytes(4);
    [r[0], r[1], r[2], r[3]]
}

// ---------- hey 执行与解析 ----------

struct HeyRow {
    rt: f64,
    offset: f64,
    status: String,
}

fn run_hey(hey_bin: &str, url: &str, n: usize, c: usize, method: &str, data: Option<&str>) -> Result<Vec<HeyRow>, String> {
    let mut cmd = Command::new(hey_bin);
    cmd.arg("-n").arg(n.to_string())
        .arg("-c").arg(c.to_string())
        .arg("-o").arg("csv");
    if method == "POST" {
        if let Some(d) = data {
            cmd.arg("-m").arg("POST").arg("-d").arg(d);
        }
    }
    cmd.arg(url);
    let out = cmd.output().map_err(|e| format!("hey 失败: {e}"))?;
    if !out.status.success() {
        return Err(format!("hey 失败(exit {}): {}", out.status, &String::from_utf8_lossy(&out.stderr)[..500.min(String::from_utf8_lossy(&out.stderr).len())]));
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let csv = Csv::parse(&stdout).map_err(|e| format!("csv 解析失败: {e}"))?;
    let mut rows = Vec::with_capacity(csv.rows.len());
    for r in &csv.rows {
        let rt: f64 = csv.field(r, "response-time").trim().parse().unwrap_or(0.0);
        let offset: f64 = csv.field(r, "offset").trim().parse().unwrap_or(0.0);
        let status = csv.field(r, "status-code");
        rows.push(HeyRow { rt, offset, status });
    }
    Ok(rows)
}

// ---------- 统计 ----------

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let k = (sorted.len() as f64 - 1.0) * p;
    let f = k.floor() as usize;
    let c = (f + 1).min(sorted.len() - 1);
    sorted[f] + (sorted[c] - sorted[f]) * (k - f as f64)
}

struct Summary {
    url: String,
    requests: usize,
    concurrency: usize,
    total_seconds: f64,
    rps: f64,
    latency: [f64; 10], // avg,min,max,p10,p25,p50,p75,p90,p95,p99
    status_codes: Vec<(String, usize)>,
    errors: usize,
}

fn summarize(rt_rows: &[f64], off_rows: &[f64], statuses: &[String], n: usize, c: usize, url: &str) -> Summary {
    let total = off_rows
        .iter()
        .zip(rt_rows.iter())
        .map(|(o, r)| o + r)
        .fold(0.0f64, f64::max);
    let mut times: Vec<f64> = rt_rows.to_vec();
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mut sc: Vec<(String, usize)> = Vec::new();
    for st in statuses {
        match sc.iter_mut().find(|(k, _)| k == st) {
            Some((_, v)) => *v += 1,
            None => sc.push((st.clone(), 1)),
        }
    }
    let errors = n - statuses.iter().filter(|s| s.as_str() == "200").count();
    let avg = if times.is_empty() { 0.0 } else { times.iter().sum::<f64>() / times.len() as f64 };
    Summary {
        url: url.to_string(),
        requests: n,
        concurrency: c,
        total_seconds: if total > 0.0 { (total * 10000.0).round() / 10000.0 } else { 0.0 },
        rps: if total > 0.0 { (n as f64 / total * 100.0).round() / 100.0 } else { 0.0 },
        latency: [
            (avg * 1000.0 * 100.0).round() / 100.0,
            (times.first().copied().unwrap_or(0.0) * 1000.0 * 100.0).round() / 100.0,
            (times.last().copied().unwrap_or(0.0) * 1000.0 * 100.0).round() / 100.0,
            (percentile(&times, 0.10) * 1000.0 * 100.0).round() / 100.0,
            (percentile(&times, 0.25) * 1000.0 * 100.0).round() / 100.0,
            (percentile(&times, 0.50) * 1000.0 * 100.0).round() / 100.0,
            (percentile(&times, 0.75) * 1000.0 * 100.0).round() / 100.0,
            (percentile(&times, 0.90) * 1000.0 * 100.0).round() / 100.0,
            (percentile(&times, 0.95) * 1000.0 * 100.0).round() / 100.0,
            (percentile(&times, 0.99) * 1000.0 * 100.0).round() / 100.0,
        ],
        status_codes: sc,
        errors,
    }
}

// ---------- 环境信息 ----------

fn sh(cmd: &str) -> String {
    if let Ok(out) = Command::new("sh").arg("-c").arg(cmd).output() {
        if out.status.success() {
            return String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
    String::new()
}

fn env_info() -> Vec<(String, String)> {
    vec![
        ("cpu".into(), sh("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs")),
        ("cores".into(), sh("grep -c '^processor' /proc/cpuinfo")),
        ("mem_gib".into(), sh("awk '/MemTotal/{printf \"%.0f\", $2/1024/1024}' /proc/meminfo")),
        ("kernel".into(), sh("uname -r")),
        ("mojo".into(), sh("mojo --version 2>/dev/null | grep -v Crashpad | head -1")),
        ("rust".into(), sh("rustc --version 2>/dev/null | head -1")),
        ("hey".into(), sh("go version -m $(command -v hey) 2>/dev/null | grep -E '^\\s*mod' | awk '{print $2, $3}' || hey 2>&1 | head -1")),
    ]
}

// ---------- JSON 构造 ----------

fn jnum(f: f64) -> Value {
    Value::Num(f)
}
fn jstr(s: &str) -> Value {
    Value::Str(s.to_string())
}
fn jint(i: usize) -> Value {
    Value::Num(i as f64)
}

fn summary_to_value(s: &Summary) -> Value {
    let mut obj = vec![
        ("url".into(), jstr(&s.url)),
        ("requests".into(), jint(s.requests)),
        ("concurrency".into(), jint(s.concurrency)),
        ("total_seconds".into(), jnum(s.total_seconds)),
        ("requests_per_sec".into(), jnum(s.rps)),
    ];
    let lat = [
        ("avg", s.latency[0]),
        ("min", s.latency[1]),
        ("max", s.latency[2]),
        ("p10", s.latency[3]),
        ("p25", s.latency[4]),
        ("p50", s.latency[5]),
        ("p75", s.latency[6]),
        ("p90", s.latency[7]),
        ("p95", s.latency[8]),
        ("p99", s.latency[9]),
    ];
    obj.push(("latency_ms".into(), Value::Object(lat.iter().map(|(k, v)| (k.to_string(), jnum(*v))).collect())));
    let sc_obj: Vec<(String, Value)> = s
        .status_codes
        .iter()
        .map(|(k, v)| (k.clone(), jint(*v)))
        .collect();
    obj.push(("status_codes".into(), Value::Object(sc_obj)));
    obj.push(("errors".into(), jint(s.errors)));
    Value::Object(obj)
}

// ---------- 场景解析 ----------

pub struct Scenario {
    pub name: String,
    pub url: String,
    pub n: usize,
    pub c: usize,
    pub method: String,
    pub data: Option<String>,
}

fn load_scenarios(path: Option<&str>) -> Result<Vec<Scenario>, String> {
    let text = match path {
        Some(p) => std::fs::read_to_string(p).map_err(|e| format!("读场景文件失败: {e}"))?,
        None => {
            // 内置默认场景 (与 bench.py DEFAULT_SCENARIOS 一致)
            return Ok(vec![
                Scenario { name: "get_root_10k_100c".into(), url: "http://127.0.0.1:8000/".into(), n: 10000, c: 100, method: "GET".into(), data: None },
                Scenario { name: "get_root_50k_500c".into(), url: "http://127.0.0.1:8000/".into(), n: 50000, c: 500, method: "GET".into(), data: None },
                Scenario { name: "get_root_100k_200c".into(), url: "http://127.0.0.1:8000/".into(), n: 100000, c: 200, method: "GET".into(), data: None },
                Scenario { name: "get_hello_10k_100c".into(), url: "http://127.0.0.1:8000/hello?name=Mojo".into(), n: 10000, c: 100, method: "GET".into(), data: None },
            ]);
        }
    };
    let v = json::parse(&text).map_err(|e| e.to_string())?;
    let list = if let Some(arr) = v.as_arr() {
        arr.clone()
    } else if let Some(obj) = v.as_obj() {
        obj.iter()
            .find(|(k, _)| k == "scenarios")
            .and_then(|(_, v)| v.as_arr())
            .cloned()
            .ok_or("场景 JSON 缺 scenarios 数组")?
    } else {
        return Err("场景 JSON 必须是数组或 {scenarios: [...]}".into());
    };
    let mut out = Vec::new();
    for item in list {
        let name = item.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let url = item.get("url").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let n = item.get("n").and_then(|v| v.as_num()).unwrap_or(0.0) as usize;
        let c = item.get("c").and_then(|v| v.as_num()).unwrap_or(0.0) as usize;
        let method = item.get("method").and_then(|v| v.as_str()).unwrap_or("GET").to_string();
        let data = item.get("data").and_then(|v| v.as_str()).map(|s| s.to_string());
        out.push(Scenario { name, url, n, c, method, data });
    }
    Ok(out)
}

// ---------- Markdown ----------

fn render_markdown(data: &Value) -> String {
    let mut s = String::new();
    s.push_str("# Benchmark 报告\n\n");
    if let Some(d) = data.get("date").and_then(|v| v.as_str()) {
        s.push_str(&format!("- **日期**：{d}\n"));
    }
    if let Some(c) = data.get("commit").and_then(|v| v.as_str()) {
        s.push_str(&format!("- **Commit**：{c}\n"));
    }
    if let Some(e) = data.get("environment") {
        if let Some(hey) = e.get("hey").and_then(|v| v.as_str()) {
            s.push_str(&format!("- **压测工具**：{hey}\n"));
        }
    }
    if let Some(c) = data.get("server_cmd").and_then(|v| v.as_str()) {
        let d = data.get("server_dir").and_then(|v| v.as_str()).unwrap_or("");
        s.push_str(&format!("- **测试目标**：{c}（{d}）\n"));
    }
    s.push_str("\n## 1. 测试环境\n\n| 项目 | 值 |\n|---|---|\n");
    if let Some(e) = data.get("environment").and_then(|v| v.as_obj()) {
        for (k, v) in e {
            let val = match v { Value::Str(x) => x.clone(), _ => json::to_string(v) };
            s.push_str(&format!("| {k} | {val} |\n"));
        }
    }
    s.push_str("\n## 2. 测试方法\n\n");
    if let Some(c) = data.get("server_cmd").and_then(|v| v.as_str()) {
        let d = data.get("server_dir").and_then(|v| v.as_str()).unwrap_or("");
        s.push_str(&format!("- 启动：`{c}`（{d}）\n"));
    }
    let warm = data.get("warmup").and_then(|v| v.as_str()).unwrap_or("");
    s.push_str(&format!("- 预热：{warm}\n"));
    s.push_str("- 压测命令：`hey -n <总数> -c <并发> <url>`（csv 逐请求采集，脚本统一计算统计量）\n");
    s.push_str("\n## 3. 测试结果\n\n");
    if let Some(arr) = data.get("scenarios").and_then(|v| v.as_arr()) {
        for (i, sc) in (1..).zip(arr.iter()) {
            let name = sc.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let url = sc.get("url").and_then(|v| v.as_str()).unwrap_or("");
            s.push_str(&format!("### 3.{i} {name}（{url}）\n\n| 指标 | 值 |\n|---|---|\n"));
            let reqs = sc.get("requests").and_then(|v| v.as_num()).unwrap_or(0.0) as i64;
            let conc = sc.get("concurrency").and_then(|v| v.as_num()).unwrap_or(0.0) as i64;
            let total = sc.get("total_seconds").and_then(|v| v.as_num()).unwrap_or(0.0);
            let rps = sc.get("requests_per_sec").and_then(|v| v.as_num()).unwrap_or(0.0);
            s.push_str(&format!("| 请求数 | {reqs} |\n"));
            s.push_str(&format!("| 并发 | {conc} |\n"));
            s.push_str(&format!("| 总耗时 | {total} s |\n"));
            s.push_str(&format!("| **吞吐量 (req/s)** | **{rps}** |\n"));
            if let Some(lat) = sc.get("latency_ms").and_then(|v| v.as_obj()) {
                let get = |k: &str| lat.iter().find(|(x, _)| x == k).and_then(|(_, v)| v.as_num()).unwrap_or(0.0);
                s.push_str(&format!("| 平均延迟 | {} ms |\n", get("avg")));
                s.push_str(&format!("| 最快延迟 | {} ms |\n", get("min")));
                s.push_str(&format!("| 最慢延迟 | {} ms |\n", get("max")));
                s.push_str(&format!("| P50 | {} ms |\n", get("p50")));
                s.push_str(&format!("| P90 | {} ms |\n", get("p90")));
                s.push_str(&format!("| P99 | {} ms |\n", get("p99")));
            }
            let errs = sc.get("errors").and_then(|v| v.as_num()).unwrap_or(0.0) as i64;
            s.push_str(&format!("| 错误 | {errs} |\n\n"));
        }
    }
    s.push_str("## 4. 结论\n\n（由 `fmtool bench` 自动生成，结论需人工补充）\n\n## 5. 复现方法\n\n```bash\n./benchmark.sh\n```\n");
    s
}

// ---------- 历史 (JSONL) ----------

fn default_db() -> String {
    // cwd 相对路径, 适合从仓库根目录运行 (./benchmark.sh / fmtool bench).
    // 不依赖编译期路径, 避免 build 目录位置变化导致写入错位.
    "docs/reports/auto/benchmark.jsonl".into()
}

fn append_history(db: &str, data: &Value) {
    if let Some(parent) = std::path::Path::new(db).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(db) {
        let line = json::to_string(data);
        let _ = writeln!(f, "{line}");
    }
}

fn show_history(db: &str, limit: usize) {
    let text = match std::fs::read_to_string(db) {
        Ok(t) => t,
        Err(_) => {
            println!("（暂无历史记录）");
            return;
        }
    };
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    let start = lines.len().saturating_sub(limit);
    for (id, line) in (start + 1..).zip(lines[start..].iter()) {
        if let Ok(v) = json::parse(line) {
            let date = v.get("date").and_then(|x| x.as_str()).unwrap_or("");
            let commit = v.get("commit").and_then(|x| x.as_str()).unwrap_or("");
            let scmd = v.get("server_cmd").and_then(|x| x.as_str()).unwrap_or("");
            println!("run #{id}  {date}  commit={commit}  {scmd}");
            if let Some(arr) = v.get("scenarios").and_then(|x| x.as_arr()) {
                for sc in arr {
                    let name = sc.get("name").and_then(|x| x.as_str()).unwrap_or("");
                    let rps = sc.get("requests_per_sec").and_then(|x| x.as_num()).unwrap_or(0.0);
                    let avg = sc.get("latency_ms").and_then(|x| x.get("avg")).and_then(|x| x.as_num()).unwrap_or(0.0);
                    let errs = sc.get("errors").and_then(|x| x.as_num()).unwrap_or(0.0) as i64;
                    println!("    {name:<22} {rps:>9.1} req/s  avg {avg:>6.2} ms  errors {errs}");
                }
            }
        }
    }
}

// ---------- 主流程 ----------

pub struct BenchOpts {
    pub scenarios: Option<String>,
    pub json: Option<String>,
    pub report: Option<String>,
    pub port: u16,
    pub hey: String,
    pub server_dir: String,
    pub server_cmd: String,
    pub no_server: bool,
    pub no_warmup: bool,
    pub db: Option<String>,
    pub history: bool,
    pub limit: usize,
}

pub fn run_bench(opts: &BenchOpts) -> i32 {
    if opts.history {
        let db = opts.db.clone().unwrap_or_else(default_db);
        show_history(&db, opts.limit);
        return 0;
    }

    let scenarios = match load_scenarios(opts.scenarios.as_deref()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[bench] {e}");
            return 1;
        }
    };

    let mut server = Server::start(&opts.server_cmd, &opts.server_dir, opts.port, opts.no_server);

    let mut scenarios_out: Vec<Value> = Vec::new();

    let do_warmup = |hey: &str, port: u16| {
        if !opts.no_warmup {
            eprintln!("[bench] 预热 {WARMUP_N} 请求 / 并发 {WARMUP_C} ...");
            let _ = run_hey(hey, &format!("http://127.0.0.1:{port}/"), WARMUP_N, WARMUP_C, "GET", None);
        }
    };
    do_warmup(&opts.hey, opts.port);

    for sc in &scenarios {
        let name = &sc.name;
        let url = &sc.url;
        let n = sc.n;
        let c = sc.c;
        let summary = if url.starts_with("ws://") {
            eprintln!("[bench] 场景 {name}: {n} echo 往返 / 并发 {c} (WS {url}) ...");
            let rest = url.strip_prefix("ws://").unwrap();
            let (hostport, ppath) = match rest.split_once('/') {
                Some((h, p)) => (h, format!("/{p}")),
                None => (rest, "/".to_string()),
            };
            let wport = if let Some(idx) = hostport.rfind(':') {
                hostport[idx + 1..].parse().unwrap_or(opts.port)
            } else {
                opts.port
            };
            let rows = ws_load(wport, &ppath, n, c);
            let rts: Vec<f64> = rows.iter().map(|r| r.0.parse().unwrap_or(0.0)).collect();
            let offs: Vec<f64> = rows.iter().map(|r| r.1.parse().unwrap_or(0.0)).collect();
            let sts: Vec<String> = rows.iter().map(|r| r.2.clone()).collect();
            summarize(&rts, &offs, &sts, n, c, url)
        } else {
            eprintln!("[bench] 场景 {name}: {n} 请求 / 并发 {c} ...");
            let rows = match run_hey(&opts.hey, url, n, c, &sc.method, sc.data.as_deref()) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[bench] {e}");
                    server.stop();
                    return 1;
                }
            };
            let rts: Vec<f64> = rows.iter().map(|r| r.rt).collect();
            let offs: Vec<f64> = rows.iter().map(|r| r.offset).collect();
            let sts: Vec<String> = rows.iter().map(|r| r.status.clone()).collect();
            summarize(&rts, &offs, &sts, n, c, url)
        };
        eprintln!("[bench]   -> {} req/s, avg {} ms, errors {}", summary.rps, summary.latency[0], summary.errors);
        let mut sv = summary_to_value(&summary);
        if let Value::Object(obj) = &mut sv {
            obj.insert(0, ("name".into(), jstr(name)));
        }
        scenarios_out.push(sv);
    }

    let commit = sh("git rev-parse --short HEAD 2>/dev/null");
    let date = {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        let secs = now.as_secs();
        // UTC 时间 (与 python datetime.now(timezone.utc) 对齐)
        let days = secs / 86400;
        let (y, m, d) = civil_from_days(days as i64);
        let (h, mi, s) = ((secs % 86400) / 3600, (secs % 3600) / 60, secs % 60);
        format!("{y:04}-{m:02}-{d:02} {h:02}:{mi:02}:{s:02} UTC")
    };
    let warmup_desc = if opts.no_warmup { "无".to_string() } else { format!("{WARMUP_N} 请求 / 并发 {WARMUP_C}") };

    let env_pairs = env_info().into_iter().map(|(k, v)| (k, Value::Str(v))).collect();
    let root = vec![
        ("date".into(), jstr(&date)),
        ("commit".into(), jstr(&commit)),
        ("server_dir".into(), jstr(&opts.server_dir)),
        ("server_cmd".into(), jstr(&opts.server_cmd)),
        ("warmup".into(), jstr(&warmup_desc)),
        ("environment".into(), Value::Object(env_pairs)),
        ("scenarios".into(), Value::Array(scenarios_out)),
    ];
    let data = Value::Object(root);

    let db = opts.db.clone().unwrap_or_else(default_db);
    append_history(&db, &data);
    eprintln!("[bench] 已记录到 JSONL: {db}");

    if let Some(jp) = &opts.json {
        if let Err(e) = std::fs::write(jp, format!("{}\n", json::to_string(&data))) {
            eprintln!("[bench] 写 JSON 失败: {e}");
        } else {
            eprintln!("[bench] JSON 已写入 {jp}");
        }
    } else {
        println!("{}", json::to_string(&data));
    }

    if let Some(rp) = &opts.report {
        if let Err(e) = std::fs::write(rp, render_markdown(&data)) {
            eprintln!("[bench] 写报告失败: {e}");
        } else {
            eprintln!("[bench] 报告已写入 {rp}");
        }
    }

    server.stop();
    0
}

// 天数 → 公历 (Howard Hinnant 算法)
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}
