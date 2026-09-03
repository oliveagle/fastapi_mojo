// signals_tests.rs — 信号处理回归 (ADR-0010 DC2)
//
// 分两组:
//   A) 默认单元测试 (不触发真信号, 与其它并发测试无干扰):
//      - shutdown_handler 直接调用 (它就是普通 extern "C" fn, 可被 Rust 直接调)
//      - server_shutdown / is_running / 幂等 setup / SIG_IGN 指针形态
//   B) #[ignore] 集成测试 (用 raise() 触发真信号, 修改进程级信号状态):
//      需 `cargo test --release -- --ignored --test-threads=1` 单独跑.
use super::signals::*;

const SIGTERM: i32 = 15;
const SIGINT: i32 = 2;
const SIGPIPE: i32 = 13;

// ---------- A) 默认单元测试 (无真信号) ----------

#[test]
fn is_running_initial_true() {
    assert!(is_running());
    assert_eq!(raw_running(), 1);
}

#[test]
fn shutdown_handler_direct_call_sets_zero() {
    // shutdown_handler 是普通 extern "C" fn, 直接调用等价于收到关停信号.
    let before = raw_running();
    invoke_shutdown_handler(SIGTERM);
    assert_eq!(raw_running(), 0);
    assert!(!is_running());
    reset_running_for_test();
    assert!(is_running());
    assert_eq!(before, 1); // 原值恒 1 (其它测试不共享 G_RUNNING 写入)
}

#[test]
fn server_shutdown_sets_zero() {
    server_shutdown();
    assert_eq!(raw_running(), 0);
    assert!(!is_running());
    reset_running_for_test();
    assert!(is_running());
}

#[test]
fn setup_is_idempotent_and_callable() {
    // 幂等: 首次返回 true (或已被其它测试安装则 false), 再次调用不 panic,
    // 信号状态仍有效. 不 over-assert 首次返回值 (并行进程内共享 OnceBool).
    let _first = setup_signal_handlers();
    let _second = setup_signal_handlers();
    let _third = setup_signal_handlers();
    // 安装后 shutdown 语义不变
    server_shutdown();
    assert!(!is_running());
    reset_running_for_test();
}

#[test]
fn sig_ign_pointer_form() {
    // SIG_IGN 指针形态: glibc 约定 (sighandler_t)1; 用于 SIGPIPE 忽略.
    let ign = sig_ign_for_test();
    assert!(ign.is_some());
}

// ---------- B) 真信号集成测试 (#[ignore]) ----------

/// 进程内并发跑信号测试会互相干扰 (进程级 handler 共享); 必须单线程.
fn sleep_ms(ms: u64) {
    std::thread::sleep(std::time::Duration::from_millis(ms));
}

#[test]
#[ignore]
fn sigterm_raise_sets_running_false() {
    setup_signal_handlers();
    reset_running_for_test();
    assert!(is_running());
    let rc = raise_signal(SIGTERM);
    assert_eq!(rc, 0);
    sleep_ms(100); // 等信号投递
    assert!(!is_running(), "SIGTERM 后 is_running() 应为 false");
    reset_running_for_test();
}

#[test]
#[ignore]
fn sigint_raise_sets_running_false() {
    setup_signal_handlers();
    reset_running_for_test();
    let rc = raise_signal(SIGINT);
    assert_eq!(rc, 0);
    sleep_ms(100);
    assert!(!is_running(), "SIGINT 后 is_running() 应为 false");
    reset_running_for_test();
}

#[test]
#[ignore]
fn sigpipe_ignored_process_survives() {
    // 无 handler 时 raise(SIGPIPE) 默认动作是终止进程; SIG_IGN 后进程存活.
    setup_signal_handlers();
    reset_running_for_test();
    let rc = raise_signal(SIGPIPE);
    assert_eq!(rc, 0);
    sleep_ms(100);
    // 进程还活着 (走到这里即通过), 运行标志未被破坏
    assert!(is_running());
}
