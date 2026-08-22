#!/usr/bin/env python3
"""
bench.py — 统一的 FastAPI-Mojo benchmark runner。

职责：
  1. 启动被测服务器（mojo run hello.mojo，可指定端口）
  2. 预热
  3. 按场景配置跑 hey 压测（csv 逐请求输出）
  4. 解析 csv，计算统一统计量（吞吐、延迟分位、错误数等）
  5. 输出统一格式 JSON（--json 指定路径，默认 stdout）
  6. 可选：由 JSON 生成统一格式 Markdown 报告（--report）

用法：
  python3 bench.py --server-dir ../src/fastapi_mojo --server-cmd "mojo run hello.mojo"
  python3 bench.py --json out.json --report out.md

依赖：hey 二进制（--hey 指定，默认从 PATH 找 hey）
"""

import argparse
import csv
import io
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# 默认场景：与 Baseline 报告一致的测试矩阵
# ---------------------------------------------------------------------------
DEFAULT_SCENARIOS = [
    {"name": "get_root_10k_100c", "url": "http://127.0.0.1:8000/", "n": 10000, "c": 100},
    {"name": "get_root_50k_500c", "url": "http://127.0.0.1:8000/", "n": 50000, "c": 500},
    {"name": "get_root_100k_200c", "url": "http://127.0.0.1:8000/", "n": 100000, "c": 200},
    {"name": "get_hello_10k_100c", "url": "http://127.0.0.1:8000/hello?name=Mojo", "n": 10000, "c": 100},
]

WARMUP_N = 2000
WARMUP_C = 50
STARTUP_WAIT = 20  # 秒，等待 mojo 编译 + 服务器启动
STARTUP_CHECK_INTERVAL = 2


def parse_args():
    p = argparse.ArgumentParser(description="Unified benchmark runner for fastapi_mojo")
    p.add_argument("--server-dir", default="src/fastapi_mojo",
                   help="目录，在其中启动服务器（默认 src/fastapi_mojo）")
    p.add_argument("--server-cmd", default="mojo run hello.mojo",
                   help="服务器启动命令（默认 'mojo run hello.mojo'）")
    p.add_argument("--port", type=int, default=8000, help="服务器端口（默认 8000）")
    p.add_argument("--hey", default="hey", help="hey 二进制路径（默认 PATH 中的 hey）")
    p.add_argument("--scenarios", default=None,
                   help="场景 JSON 文件路径；缺省用内置默认场景")
    p.add_argument("--json", default=None, help="输出 JSON 文件路径（默认 stdout）")
    p.add_argument("--report", default=None, help="由 JSON 生成 Markdown 报告文件路径")
    p.add_argument("--no-server", action="store_true",
                   help="不启动/停止服务器（假设服务器已在运行）")
    p.add_argument("--no-warmup", action="store_true", help="跳过预热")
    return p.parse_args()


# ---------------------------------------------------------------------------
# 服务器生命周期
# ---------------------------------------------------------------------------
class Server:
    def __init__(self, args):
        self.args = args
        self.proc = None

    def start(self):
        if self.args.no_server:
            return
        self.proc = subprocess.Popen(
            self.args.server_cmd.split(),
            cwd=self.args.server_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + STARTUP_WAIT
        url = f"http://127.0.0.1:{self.args.port}/"
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(url, timeout=1) as r:
                    if r.status == 200:
                        return
            except Exception:
                pass
            time.sleep(STARTUP_CHECK_INTERVAL)
        raise RuntimeError("服务器未在预期时间内启动")

    def stop(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None


# ---------------------------------------------------------------------------
# hey 执行与 csv 解析
# ---------------------------------------------------------------------------
def run_hey(hey_bin, url, n, c, timeout_ms=600000):
    """运行 hey，返回逐请求 csv 行（dict 列表）。"""
    cmd = [hey_bin, "-n", str(n), "-c", str(c), "-o", "csv", url]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_ms)
    if proc.returncode != 0:
        raise RuntimeError(f"hey 失败: {proc.stderr[:500]}")
    reader = csv.DictReader(io.StringIO(proc.stdout))
    return list(reader)


def percentile(sorted_vals, p):
    """线性插值分位数（与 hey 的 summary 一致）。"""
    if not sorted_vals:
        return 0.0
    k = (len(sorted_vals) - 1) * p
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def summarize(rows, n, c, url):
    """从逐请求数据计算统一统计量。"""
    times = [float(r["response-time"]) for r in rows]
    # 总耗时 = 最后一个请求开始的时间偏移 + 其响应时间
    total = max(float(r["offset"]) + float(r["response-time"]) for r in rows)
    statuses = {}
    for r in rows:
        statuses[r["status-code"]] = statuses.get(r["status-code"], 0) + 1
    sorted_times = sorted(times)
    return {
        "url": url,
        "requests": n,
        "concurrency": c,
        "total_seconds": round(total, 4),
        "requests_per_sec": round(n / total, 2) if total > 0 else 0.0,
        "latency_ms": {
            "avg": round(statistics.fmean(times) * 1000, 2),
            "min": round(min(times) * 1000, 2),
            "max": round(max(times) * 1000, 2),
            "p10": round(percentile(sorted_times, 0.10) * 1000, 2),
            "p25": round(percentile(sorted_times, 0.25) * 1000, 2),
            "p50": round(percentile(sorted_times, 0.50) * 1000, 2),
            "p75": round(percentile(sorted_times, 0.75) * 1000, 2),
            "p90": round(percentile(sorted_times, 0.90) * 1000, 2),
            "p95": round(percentile(sorted_times, 0.95) * 1000, 2),
            "p99": round(percentile(sorted_times, 0.99) * 1000, 2),
        },
        "status_codes": statuses,
        "errors": n - statuses.get("200", 0),
    }


# ---------------------------------------------------------------------------
# 环境信息
# ---------------------------------------------------------------------------
def env_info():
    def sh(cmd):
        try:
            return subprocess.run(cmd, shell=True, capture_output=True,
                                  text=True, timeout=10).stdout.strip()
        except Exception:
            return ""

    return {
        "cpu": sh("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs"),
        "cores": sh("grep -c '^processor' /proc/cpuinfo"),
        "mem_gib": sh("awk '/MemTotal/{printf \"%.0f\", $2/1024/1024}' /proc/meminfo"),
        "kernel": sh("uname -r"),
        "mojo": sh("mojo --version 2>/dev/null | grep -v Crashpad | head -1"),
        "python": sh("python3 --version"),
        "fastapi": sh("python3 -c 'import fastapi; print(fastapi.__version__)' 2>/dev/null"),
        "uvicorn": sh("python3 -c 'import uvicorn; print(uvicorn.__version__)' 2>/dev/null"),
        "hey": sh("go version -m $(command -v hey) 2>/dev/null | grep '^\\s*mod' | awk '{print $2, $3}' || hey 2>&1 | head -1"),
    }


# ---------------------------------------------------------------------------
# Markdown 报告生成（统一格式）
# ---------------------------------------------------------------------------
def render_markdown(data):
    env = data["environment"]
    lines = []
    lines.append("# Benchmark 报告")
    lines.append("")
    lines.append(f"- **日期**：{data['date']}")
    lines.append(f"- **Commit**：{data['commit']}")
    lines.append(f"- **压测工具**：{env['hey']}")
    lines.append(f"- **测试目标**：{data['server_cmd']}（{data['server_dir']}）")
    lines.append("")
    lines.append("## 1. 测试环境")
    lines.append("")
    lines.append("| 项目 | 值 |")
    lines.append("|---|---|")
    for k, v in env.items():
        lines.append(f"| {k} | {v} |")
    lines.append("")
    lines.append("## 2. 测试方法")
    lines.append("")
    lines.append(f"- 启动：`{data['server_cmd']}`（{data['server_dir']}）")
    lines.append(f"- 预热：{data['warmup']}")
    lines.append("- 压测命令：`hey -n <总数> -c <并发> <url>`（csv 逐请求采集，脚本统一计算统计量）")
    lines.append("")
    lines.append("## 3. 测试结果")
    lines.append("")
    for s in data["scenarios"]:
        lines.append(f"### 3.x {s['name']}（{s['url']}）")
        lines.append("")
        lines.append("| 指标 | 值 |")
        lines.append("|---|---|")
        lines.append(f"| 请求数 | {s['requests']} |")
        lines.append(f"| 并发 | {s['concurrency']} |")
        lines.append(f"| 总耗时 | {s['total_seconds']} s |")
        lines.append(f"| **吞吐量 (req/s)** | **{s['requests_per_sec']}** |")
        lat = s["latency_ms"]
        lines.append(f"| 平均延迟 | {lat['avg']} ms |")
        lines.append(f"| 最快延迟 | {lat['min']} ms |")
        lines.append(f"| 最慢延迟 | {lat['max']} ms |")
        lines.append(f"| P50 | {lat['p50']} ms |")
        lines.append(f"| P90 | {lat['p90']} ms |")
        lines.append(f"| P99 | {lat['p99']} ms |")
        lines.append(f"| 错误 | {s['errors']} |")
        lines.append("")
    lines.append("## 4. 结论")
    lines.append("")
    lines.append("（由 `bench.py` 自动生成，结论需人工补充）")
    lines.append("")
    lines.append("## 5. 复现方法")
    lines.append("")
    lines.append("```bash")
    lines.append("python3 bench.py --json out.json --report out.md")
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    args = parse_args()

    if args.scenarios:
        with open(args.scenarios) as f:
            scenarios = json.load(f)
    else:
        scenarios = DEFAULT_SCENARIOS

    server = Server(args)
    try:
        server.start()
        if not args.no_warmup:
            print(f"[bench] 预热 {WARMUP_N} 请求 / 并发 {WARMUP_C} ...", file=sys.stderr)
            run_hey(args.hey, f"http://127.0.0.1:{args.port}/", WARMUP_N, WARMUP_C)

        results = []
        for sc in scenarios:
            print(f"[bench] 场景 {sc['name']}: {sc['n']} 请求 / 并发 {sc['c']} ...",
                  file=sys.stderr)
            rows = run_hey(args.hey, sc["url"], sc["n"], sc["c"])
            summary = summarize(rows, sc["n"], sc["c"], sc["url"])
            summary["name"] = sc["name"]
            results.append(summary)
            print(f"[bench]   -> {summary['requests_per_sec']} req/s, "
                  f"avg {summary['latency_ms']['avg']} ms, "
                  f"errors {summary['errors']}", file=sys.stderr)

        commit = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"], capture_output=True,
            text=True, cwd=os.getcwd()
        ).stdout.strip()

        data = {
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            "commit": commit,
            "server_dir": args.server_dir,
            "server_cmd": args.server_cmd,
            "warmup": f"{WARMUP_N} 请求 / 并发 {WARMUP_C}" if not args.no_warmup else "无",
            "environment": env_info(),
            "scenarios": results,
        }

        if args.json:
            with open(args.json, "w") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            print(f"[bench] JSON 已写入 {args.json}", file=sys.stderr)
        else:
            print(json.dumps(data, indent=2, ensure_ascii=False))

        if args.report:
            with open(args.report, "w") as f:
                f.write(render_markdown(data))
            print(f"[bench] 报告已写入 {args.report}", file=sys.stderr)
    finally:
        server.stop()


if __name__ == "__main__":
    main()
