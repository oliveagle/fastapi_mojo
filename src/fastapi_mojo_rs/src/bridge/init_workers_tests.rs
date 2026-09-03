// init_workers_tests.rs — worker mode 解析 + init 集成 (ADR-0010 DC2)
use super::init_workers::*;

// ---------- WorkerMode 纯逻辑 ----------

#[test]
fn worker_mode_single_when_unset() {
    assert_eq!(worker_mode(None, None), WorkerMode::Single);
    assert_eq!(worker_mode(Some(""), None), WorkerMode::Single);
}

#[test]
fn worker_mode_single_when_n_le_1() {
    assert_eq!(worker_mode(Some("1"), None), WorkerMode::Single);
    assert_eq!(worker_mode(Some("0"), None), WorkerMode::Single);
    assert_eq!(worker_mode(Some("-3"), None), WorkerMode::Single);
}

#[test]
fn worker_mode_garbage_n_falls_back_to_single() {
    // atoi 在 C 中遇到 "abc" 返回 0 -> n<=1 -> Single. Rust parse 也失败, fallback 1 -> Single.
    assert_eq!(worker_mode(Some("abc"), None), WorkerMode::Single);
}

#[test]
fn worker_mode_spawner_when_n_gt_1() {
    assert_eq!(worker_mode(Some("4"), None), WorkerMode::Spawner(4));
    assert_eq!(worker_mode(Some("2"), None), WorkerMode::Spawner(2));
    assert_eq!(worker_mode(Some("100"), None), WorkerMode::Spawner(100));
}

#[test]
fn worker_mode_worker_when_worker_env_set() {
    // n > 1 且 worker env 合法 -> Worker(i)
    assert_eq!(worker_mode(Some("4"), Some("2")), WorkerMode::Worker(2));
    assert_eq!(worker_mode(Some("4"), Some("0")), WorkerMode::Worker(0));
}

#[test]
fn worker_mode_worker_env_garbage_falls_to_spawner() {
    // C 中 atoi("abc") = 0; 子进程代码: `if (g_worker_id = atoi(am_worker))` 路径
    // 是 `if (am_worker && am_worker[0])`, 无空检查然后无 atoi 失败检查. C 实际:
    // atoi 返回 0, 然后 `g_worker_id = 0; setenv(WORKER, "0", 1)` 走 spawner 路径.
    // Rust 严格化: parse 失败 -> WorkerMode::Spawner(n) (与 C 的"g_worker_id=0 后
    // 继续 spawn" 语义对齐).
    assert_eq!(worker_mode(Some("4"), Some("abc")), WorkerMode::Spawner(4));
}

#[test]
fn worker_mode_worker_env_empty_falls_to_spawner() {
    // 空 env: C 中 `am_worker[0]` 检查, 空字符串触发 spawner 路径.
    assert_eq!(worker_mode(Some("4"), Some("")), WorkerMode::Spawner(4));
}

#[test]
fn worker_mode_worker_takes_priority_over_workers_n() {
    // n=2 但 worker=5: 子进程路径, id=5 (即使超过 n, 也按 env 走)
    assert_eq!(worker_mode(Some("2"), Some("5")), WorkerMode::Worker(5));
}

// ---------- get_worker_id / set_worker_id_for_test ----------

#[test]
fn worker_id_default_zero() {
    set_worker_id_for_test(0);
    assert_eq!(get_worker_id(), 0);
}

#[test]
fn worker_id_settable() {
    set_worker_id_for_test(0);
    set_worker_id_for_test(7);
    assert_eq!(get_worker_id(), 7);
    set_worker_id_for_test(0);
}

// ---------- init_workers 集成 (env 路径) ----------

#[test]
fn init_workers_single_mode() {
    // 无 env -> Single 路径, G_WORKER_ID = 0, 不 fork
    // SAFETY: 单线程 env 操作 (cargo test --test-threads=1 不强制, 但这两个
    // 测试不会并发, 因为它们各自只读/写特定键)
    unsafe {
        std::env::remove_var("FASTAPI_MOJO_WORKERS");
        std::env::remove_var("FASTAPI_MOJO_WORKER");
    }
    set_worker_id_for_test(0);
    let pids = init_workers();
    assert!(pids.is_empty());
    assert_eq!(get_worker_id(), 0);
}

#[test]
fn init_workers_already_worker() {
    // FASTAPI_MOJO_WORKERS=4 + FASTAPI_MOJO_WORKER=2 -> Worker(2) 路径, 不 fork
    unsafe {
        std::env::set_var("FASTAPI_MOJO_WORKERS", "4");
        std::env::set_var("FASTAPI_MOJO_WORKER", "2");
    }
    set_worker_id_for_test(0);
    let pids = init_workers();
    assert!(pids.is_empty());
    assert_eq!(get_worker_id(), 2);
    unsafe {
        std::env::remove_var("FASTAPI_MOJO_WORKERS");
        std::env::remove_var("FASTAPI_MOJO_WORKER");
    }
    set_worker_id_for_test(0);
}

#[test]
fn init_workers_workers_one_no_fork() {
    // WORKERS=1 + 无 WORKER env -> Single (n <= 1), 不 fork
    unsafe {
        std::env::set_var("FASTAPI_MOJO_WORKERS", "1");
        std::env::remove_var("FASTAPI_MOJO_WORKER");
    }
    set_worker_id_for_test(0);
    let pids = init_workers();
    assert!(pids.is_empty());
    assert_eq!(get_worker_id(), 0);
    unsafe { std::env::remove_var("FASTAPI_MOJO_WORKERS"); }
}

#[test]
#[ignore = "会真 fork; 并行 cargo test 不安全. 单独跑: cargo test --release -- --ignored --test-threads=1"]
fn init_workers_spawner_forks_children() {
    // WORKERS=2, 我是 spawner. readlink + fork 一次.
    // 子进程会 execv 自己 (会以 --port <port> 重新启动 binary), 然后 exit(127).
    // 测试: spawner 端应得到 1 个子 pid, G_WORKER_ID=0.
    unsafe {
        std::env::set_var("FASTAPI_MOJO_WORKERS", "2");
        std::env::remove_var("FASTAPI_MOJO_WORKER");
    }
    set_worker_id_for_test(0);
    let pids = init_workers();
    assert_eq!(pids.len(), 1, "expected 1 child pid, got {pids:?}");
    assert_eq!(get_worker_id(), 0);
    unsafe { std::env::remove_var("FASTAPI_MOJO_WORKERS"); }
}
