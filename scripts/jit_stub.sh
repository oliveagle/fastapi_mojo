#!/usr/bin/env bash
# dev-only: 构建 JIT 自测用 bridge 符号桩 (.so), 打印产物路径 (最后一行).
#
# 用途: `mojo run param_constraints_selftest.mojo` (决策-54 自测) 的调用图
# 可达 regex_match FFI (validate_* -> check_str_pattern -> _rgx_match),
# 而 JIT 环境不链接 bridge staticlib -> materialize 失败 ("Symbols not
# found"). LD_PRELOAD 无效 (JIT materialize 早于进程加载) — 用 -Xlinker
# 注入桩 .so 作为链接输入. 本脚本构建 dev/jit_regex_stub.rs (符号桩;
# 被调用则 abort — 自测约束永不含 pat):
#   export JIT_STUB="$(bash scripts/jit_stub.sh)"
#   cd src/fastapi_mojo && mojo run -Xlinker "$JIT_STUB" param_constraints_selftest.mojo
# CI「Run unit tests」step 亦调用本脚本: params_typed (import param_constraints)
# 的 JIT 闭包需 regex_match 符号 (main 不实际触发, 桩安全); 仍不进 build_single /
# binary (ADR-0029 §7.5).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${JIT_STUB_OUT:-/tmp/jit_regex_stub.so}"
rustc --edition 2021 -O --crate-type cdylib -o "$OUT" dev/jit_regex_stub.rs
echo "$OUT"
