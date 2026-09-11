//! Unit tests for Decision-64 TLS configuration parsing.

use super::tls::alpn_protocols;

#[test]
fn alpn_defaults_to_h2_and_http1() {
    assert_eq!(
        alpn_protocols("").unwrap(),
        vec![b"h2".to_vec(), b"http/1.1".to_vec()]
    );
}

#[test]
fn alpn_parses_trims_and_preserves_order() {
    assert_eq!(
        alpn_protocols(" http/1.1 , h2 ").unwrap(),
        vec![b"http/1.1".to_vec(), b"h2".to_vec()]
    );
}

#[test]
fn alpn_rejects_duplicates_and_control_characters() {
    assert!(alpn_protocols("h2,h2").is_err());
    assert!(alpn_protocols("http/1.1,bad\ralpn").is_err());
}
