//! bridge/conn/deadlines.rs — 每 conn 超时/保活决策 (ADR-0010 DC2).
//!
//! 行为等价 `http_bridge_final.c` 的 `check_deadlines` (§1028-1067) 的**纯逻辑版**.
//! 给定 conn 阶段 + 时间戳, 决定 deadline action. 调用方 (未来 pump_conn / poll 循环)
//! 据此触发 ping / 408 / close 等**副作用** (I/O). 本模块**不**做 I/O, **不**触 conn_table.
//!
//! 阶段语义 (端口 `bridge::conn::Conn::phase`):
//!   0 = HTTP header 累积中
//!   1 = HTTP body 累积中
//!   2 = HTTP 分派中 (Mojo 持有, 跳过)
//!   3 = WS 会话 (poll 可驱动; ADR-0008 保活)
//!   4 = WS 单消息分派中 (Mojo 持有, 跳过)

/// 每个 conn 在一次 deadline tick 上的决策.
///
/// 调用方按以下顺序处理 (与 C 一致):
///   None        → 不动作
///   WsPing      → `ws_write_message(fd, 9, b"", 0)` 发空 ping
///   WsClose1000 → `ws_send_close(fd, 1000)` + `ws_event_push(fd, 2)` + close_conn
///   Timeout408  → `send_error_json(fd, "408 Request Timeout", "Request timeout")` + close_conn
///   CloseIdle   → close_conn (静默; 不发响应 — keep-alive 连接池噪音最小化)
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum DeadlineAction {
    None,
    WsPing,
    WsClose1000,
    Timeout408,
    CloseIdle,
}

/// 行为等价 `check_deadlines` (C §1028-1067). 纯函数, 无 I/O, 无全局副作用
/// (除 `ws_strikes` 的 `&mut` 自增, 与 C `c->ws_strikes++` 对齐).
///
/// 阈值用 `i64` 与 Conn 字段类型一致; `now_ms` 也用 `i64` 与 C `long now_ms()` 对齐.
/// 时间差用 `saturating_sub` 防 underflow (时钟回拨 / 边界).
#[allow(clippy::too_many_arguments)]
pub fn decide(
    phase: i32,
    first_data_ms: i64,
    last_data_ms: i64,
    last_active_ms: i64,
    ws_strikes: &mut i32,
    ping_max: i32,
    now_ms: i64,
    recv_timeout_ms: i64,
    idle_max_ms: i64,
    max_request_ms: i64,
) -> DeadlineAction {
    // Mojo 分派中: 跳过 (与 C `phase == 2 || phase == 4` 一致)
    if phase == 2 || phase == 4 {
        return DeadlineAction::None;
    }

    // WS 保活 (ADR-0008)
    if phase == 3 {
        // 首次数据未到 → 不保活 (与 C `last_data_ms != 0` 一致)
        if last_data_ms != 0 {
            let idle = now_ms.saturating_sub(last_data_ms);
            if idle >= recv_timeout_ms {
                *ws_strikes += 1;
                return if *ws_strikes > ping_max {
                    DeadlineAction::WsClose1000
                } else {
                    DeadlineAction::WsPing
                };
            }
        }
        return DeadlineAction::None;
    }

    // 0/1: HTTP header/body 累积中
    if first_data_ms != 0 {
        // 请求已开始: recv_timeout (slowloris) 或 max_request (总时长) 任一超 → 408
        let idle = now_ms.saturating_sub(last_data_ms);
        let total = now_ms.saturating_sub(first_data_ms);
        if idle >= recv_timeout_ms || total >= max_request_ms {
            return DeadlineAction::Timeout408;
        }
        return DeadlineAction::None;
    }

    // 0/1, 还没首字节: idle keep-alive 静默 close
    let idle = now_ms.saturating_sub(last_active_ms);
    if idle >= idle_max_ms {
        return DeadlineAction::CloseIdle;
    }
    DeadlineAction::None
}
