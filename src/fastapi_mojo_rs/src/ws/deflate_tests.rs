use super::deflate::{
    compress_message, decompress_message, get_ws_deflate_mode, negotiate_extensions,
    new_compressor, new_inflater, DeflateMode,
};

#[test]
fn negotiation_accepts_simple_offer() {
    let n = negotiate_extensions(b"permessage-deflate").unwrap();
    assert!(!n.server_no_context_takeover);
    assert!(!n.client_no_context_takeover);
    assert_eq!(n.response_header(), b"permessage-deflate");
}

#[test]
fn negotiation_supports_directional_no_context_takeover() {
    let n = negotiate_extensions(
        b"permessage-deflate; server_no_context_takeover; client_no_context_takeover",
    )
    .unwrap();
    assert!(n.server_no_context_takeover);
    assert!(n.client_no_context_takeover);
    assert_eq!(
        n.response_header(),
        b"permessage-deflate; server_no_context_takeover; client_no_context_takeover"
    );
}

#[test]
fn negotiation_supports_fallback_offers_and_valid_bits() {
    let h = b"permessage-deflate; server_max_window_bits=10, permessage-deflate; client_max_window_bits=12";
    let n = negotiate_extensions(h).unwrap();
    assert!(!n.respond_server_window_bits);
    let n = negotiate_extensions(b"permessage-deflate; server_max_window_bits=15").unwrap();
    assert!(n.respond_server_window_bits);
    assert!(n.response_header().ends_with(b"server_max_window_bits=15"));
}

#[test]
fn negotiation_rejects_bad_or_duplicate_parameters() {
    assert!(negotiate_extensions(b"permessage-deflate; unknown=1").is_none());
    assert!(negotiate_extensions(b"permessage-deflate; server_max_window_bits=9").is_none());
    assert!(negotiate_extensions(
        b"permessage-deflate; client_no_context_takeover; client_no_context_takeover"
    )
    .is_none());
}

#[test]
fn sync_flush_context_takeover_roundtrip() {
    let mut comp = new_compressor();
    let mut dec = new_inflater();
    let a = compress_message(&mut comp, b"first-message-with-plenty-of-context", false).unwrap();
    let b = compress_message(&mut comp, b"first-message-with-plenty-of-context", false).unwrap();
    assert!(a.len() >= 2);
    assert!(b.len() < a.len(), "takeover not reflected: {} {}", a.len(), b.len());
    assert_eq!(
        decompress_message(&mut dec, &a, false).unwrap(),
        b"first-message-with-plenty-of-context"
    );
    assert_eq!(
        decompress_message(&mut dec, &b, false).unwrap(),
        b"first-message-with-plenty-of-context"
    );
}

#[test]
fn no_context_roundtrip_resets_each_direction() {
    let mut comp = new_compressor();
    let a = compress_message(&mut comp, b"payload-alpha", true).unwrap();
    let b = compress_message(&mut comp, b"payload-alpha", true).unwrap();
    assert_eq!(a, b);
    let mut dec = new_inflater();
    assert_eq!(decompress_message(&mut dec, &a, true).unwrap(), b"payload-alpha");
    assert_eq!(decompress_message(&mut dec, &b, true).unwrap(), b"payload-alpha");
}

#[test]
fn empty_and_large_messages_roundtrip() {
    let mut comp = new_compressor();
    let mut dec = new_inflater();
    let large = vec![b'a'; 80 * 1024];
    for msg in [&b""[..], &b"x"[..], large.as_slice()] {
        let wire = compress_message(&mut comp, msg, false).unwrap();
        assert_eq!(decompress_message(&mut dec, &wire, false).unwrap(), msg);
    }
}

#[test]
fn invalid_compressed_data_rejected() {
    let mut dec = new_inflater();
    assert!(decompress_message(&mut dec, &[0xff, 0xff, 0xff, 0xff], false).is_err());
}

#[test]
fn deflate_env_mode_parses_and_caches() {
    super::deflate::reset_ws_deflate_mode_cache_for_test();
    std::env::set_var("FASTAPI_MOJO_WS_DEFLATE", "required");
    assert_eq!(get_ws_deflate_mode(), DeflateMode::Required);
    std::env::set_var("FASTAPI_MOJO_WS_DEFLATE", "off");
    assert_eq!(get_ws_deflate_mode(), DeflateMode::Required, "cache must be stable");
    std::env::remove_var("FASTAPI_MOJO_WS_DEFLATE");
    super::deflate::reset_ws_deflate_mode_cache_for_test();
    assert_eq!(get_ws_deflate_mode(), DeflateMode::On);
    std::env::set_var("FASTAPI_MOJO_WS_DEFLATE", "false");
    super::deflate::reset_ws_deflate_mode_cache_for_test();
    assert_eq!(get_ws_deflate_mode(), DeflateMode::Off);
    std::env::remove_var("FASTAPI_MOJO_WS_DEFLATE");
    super::deflate::reset_ws_deflate_mode_cache_for_test();
}
