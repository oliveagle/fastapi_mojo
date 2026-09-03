// deadlines_tests.rs — check_deadlines 决策回归 (ADR-0010 DC2)
use super::deadlines::*;
use super::super::conn::*;  // for phase constants if needed

const RECV_TIMEOUT: i64 = 5000;
const IDLE_MAX: i64 = 60_000;
const MAX_REQUEST: i64 = 30_000;

#[test]
fn phase_2_dispatch_skip_regardless_of_times() {
    let mut s = 0;
    // 已远超阈值, 但 phase=2 (Mojo 分派中) → None
    let a = decide(2, 0, 0, 0, &mut s, 2, 1_000_000, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
}

#[test]
fn phase_4_dispatch_skip_regardless_of_times() {
    let mut s = 0;
    let a = decide(4, 0, 0, 0, &mut s, 2, 1_000_000, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
}

#[test]
fn phase_0_no_first_data_below_idle_threshold_returns_none() {
    let mut s = 0;
    let a = decide(0, 0, 0, 1000, &mut s, 2, 1000 + 30_000, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
}

#[test]
fn phase_0_no_first_data_at_idle_threshold_closes_idle() {
    let mut s = 0;
    let a = decide(0, 0, 0, 1000, &mut s, 2, 1000 + IDLE_MAX, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::CloseIdle);
}

#[test]
fn phase_0_no_first_data_above_idle_threshold_closes_idle() {
    let mut s = 0;
    let a = decide(0, 0, 0, 1000, &mut s, 2, 1000 + IDLE_MAX + 1, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::CloseIdle);
}

#[test]
fn phase_0_first_data_below_recv_timeout_returns_none() {
    let mut s = 0;
    // first_data=1000, last_data=1500 (5s ago at now=6500)
    let a = decide(0, 1000, 1500, 2000, &mut s, 2, 6499, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
}

#[test]
fn phase_0_first_data_at_recv_timeout_returns_timeout_408() {
    let mut s = 0;
    // idle = RECV_TIMEOUT exactly → boundary included (C uses `>=`)
    let a = decide(0, 1000, 1500, 2000, &mut s, 2, 1500 + RECV_TIMEOUT, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::Timeout408);
}

#[test]
fn phase_0_first_data_total_over_max_request_returns_timeout_408() {
    let mut s = 0;
    // total = now - first_data = 31000-1000 = 30000 = MAX_REQUEST exactly (boundary, >=)
    // idle  = now - last_data = 31000-27000 = 4000 < RECV_TIMEOUT → 由 total 路径触发 408
    let a = decide(0, 1000, 27000, 2000, &mut s, 2, 31_000, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::Timeout408);
}

#[test]
fn phase_1_body_partial_idle_too_long_returns_timeout_408() {
    let mut s = 0;
    let a = decide(1, 1000, 1500, 2000, &mut s, 2, 1500 + RECV_TIMEOUT + 1, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::Timeout408);
}

#[test]
fn phase_3_no_last_data_returns_none() {
    let mut s = 0;
    // WS phase, never received data → no ping
    let a = decide(3, 0, 0, 1000, &mut s, 2, 1000 + RECV_TIMEOUT + 1, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
    assert_eq!(s, 0, "strikes must not increment when no data");
}

#[test]
fn phase_3_below_recv_timeout_returns_none() {
    let mut s = 0;
    let a = decide(3, 0, 1500, 2000, &mut s, 2, 1500 + 3000, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
    assert_eq!(s, 0, "strikes must not increment below threshold");
}

#[test]
fn phase_3_ping_max_zero_first_idle_closes_immediately() {
    let mut s = 0;
    // ping_max=0 → 首次 idle 即 close (禁用保活)
    let a = decide(3, 0, 1500, 2000, &mut s, 0, 1500 + RECV_TIMEOUT, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::WsClose1000);
    assert_eq!(s, 1, "strike must increment to 1 (then > 0 triggers close)");
}

#[test]
fn phase_3_ping_max_two_progression() {
    // 第一次 idle → ping (strike=1)
    let mut s = 0;
    let a = decide(3, 0, 1500, 2000, &mut s, 2, 1500 + RECV_TIMEOUT, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::WsPing);
    assert_eq!(s, 1);
    // 第二次 idle → ping (strike=2)
    let mut s = 1;
    let a = decide(3, 0, 1500, 2000, &mut s, 2, 1500 + RECV_TIMEOUT, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::WsPing);
    assert_eq!(s, 2);
    // 第三次 idle → close (strike=3 > 2)
    let mut s = 2;
    let a = decide(3, 0, 1500, 2000, &mut s, 2, 1500 + RECV_TIMEOUT, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::WsClose1000);
    assert_eq!(s, 3);
}

#[test]
fn phase_3_clock_rollback_saturates_to_none() {
    let mut s = 0;
    // now < last_data_ms (e.g. monotonic clock glitch) → saturating to 0 → None
    let a = decide(3, 0, 2000, 2000, &mut s, 2, 1000, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
    assert_eq!(s, 0);
}

#[test]
fn phase_0_first_data_clock_rollback_saturates_to_none() {
    let mut s = 0;
    let a = decide(0, 5000, 5000, 5000, &mut s, 2, 1000, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::None);
}

#[test]
fn phase_0_recv_timeout_priority_over_max_request() {
    // idle 超 recv_timeout → 408 (即使 total 未到 max_request)
    let mut s = 0;
    let now = 1500 + RECV_TIMEOUT + 100;
    let a = decide(0, 1000, 1500, 2000, &mut s, 2, now, RECV_TIMEOUT, IDLE_MAX, MAX_REQUEST);
    assert_eq!(a, DeadlineAction::Timeout408);
}
