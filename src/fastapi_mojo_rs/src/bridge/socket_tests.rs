// socket_tests.rs — listen socket / per-conn socket 选项回归 (ADR-0010 DC2)
use super::socket::*;

// 这些测试会真创建 listen socket, bind port 0 (内核选临时端口); CI 上并行
// cargo test 互不干扰 (每个 fd 独立). 关闭由 close_fd 兜底 (test 失败时
// 也确保不留泄漏 fd).

#[test]
fn create_bound_socket_ephemeral_port() {
    let fd = create_bound_socket(0);
    assert!(fd >= 0, "create_bound_socket(0) failed: fd={fd}");
    let port = bound_port(fd);
    assert!(port > 0, "ephemeral port should be > 0, got {port}");
    close_fd(fd);
}

#[test]
fn create_bound_socket_two_sockets() {
    // 两次 create_bound_socket(0) 拿到不同的临时端口 (SO_REUSEPORT 不冲突
    // 因为 port=0 是内核选的不同端口).
    let fd1 = create_bound_socket(0);
    let fd2 = create_bound_socket(0);
    assert!(fd1 >= 0);
    assert!(fd2 >= 0);
    assert_ne!(fd1, fd2, "fd1={fd1} fd2={fd2}");
    let p1 = bound_port(fd1);
    let p2 = bound_port(fd2);
    assert!(p1 > 0 && p2 > 0);
    assert_ne!(p1, p2);
    close_fd(fd1);
    close_fd(fd2);
}

#[test]
fn setup_conn_fd_accepts_valid_fd() {
    // create 一个 listen socket, 然后对它的 fd 调 setup_conn_fd; 应成功
    // (即不返回 errno; 我们无法直接读 errno, 但 setsockopt 失败会 close + 返回 -1.
    // setup_conn_fd 无返回值, 所以只能间接验证: 后续仍能 bound_port 取端口).
    let listen_fd = create_bound_socket(0);
    assert!(listen_fd >= 0);
    // listen socket 也是合法 fd; setup_conn_fd 对它应无影响 (TCP_NODELAY 是
    // TCP-specific, 对 listen socket 可能 ENOPROTOOPT 但不致命).
    setup_conn_fd(listen_fd);
    let p = bound_port(listen_fd);
    assert!(p > 0);
    close_fd(listen_fd);
}

#[test]
fn setup_conn_fd_on_closed_fd_silent() {
    // 关闭后的 fd 设选项: 内核返回 EBADF; setup_conn_fd 不返回错误 (与 C 一致).
    // 只确保不 panic.
    let fd = create_bound_socket(0);
    assert!(fd >= 0);
    close_fd(fd);
    setup_conn_fd(fd); // 不 panic 即可
}

#[test]
fn bound_port_invalid_fd_returns_zero() {
    assert_eq!(bound_port(-1), 0);
    assert_eq!(bound_port(99999), 0);
}
