//! dev-only: JIT 自测 (`mojo run *_selftest.mojo`) 的 bridge 符号桩.
//!
//! Mojo 1.0.0 JIT 可执行按调用图解析 external_call 符号: param_constraints
//! 自测的 validate_* 链路可达 check_str_pattern -> _rgx_match (regex_match
//! FFI), 而 JIT 环境无 bridge 库 -> materialize 失败 ("Symbols not found").
//! 本桩提供符号使自测可 materialize; 若真被调用 (自测约束永不含 pat) ->
//! 大声 abort 而非静默错误. 不进入任何构建产物 (dev-only, ADR-0029 §7).
//!
//! 构建: rustc --edition 2021 -O --crate-type cdylib \
//!           -o /tmp/jit_regex_stub.so dev/jit_regex_stub.rs
//! 使用: LD_PRELOAD=/tmp/jit_regex_stub.so mojo run param_constraints_selftest.mojo
//!       (scripts/jit_stub.sh 封装; 自测头注与 ADR-0029 §7 注记).

#[no_mangle]
pub extern "C" fn regex_match(_pattern: *const i8, _s: *const i8) -> i32 {
    eprintln!("jit_regex_stub: regex_match called — selftest must not invoke the regex FFI");
    std::process::abort();
}
