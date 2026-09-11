use super::hpack::{HpackDecoder, HPACK_STATIC_TABLE};

fn unhex(value: &str) -> Vec<u8> {
    value
        .split_whitespace()
        .map(|byte| u8::from_str_radix(byte, 16).unwrap())
        .collect()
}

#[test]
fn static_table_matches_rfc_7541_indexes() {
    assert_eq!(HPACK_STATIC_TABLE[1].0, b":method");
    assert_eq!(HPACK_STATIC_TABLE[1].1, b"GET");
    assert_eq!(HPACK_STATIC_TABLE[2].1, b"POST");
    assert_eq!(HPACK_STATIC_TABLE[7].0, b":status");
    assert_eq!(HPACK_STATIC_TABLE[7].1, b"200");
    assert_eq!(HPACK_STATIC_TABLE[60].0, b"www-authenticate");
}

#[test]
fn decodes_rfc_request_huffman_and_dynamic_table() {
    let mut decoder = HpackDecoder::new();
    let first = decoder
        .decode(&unhex("82 86 84 41 8c f1 e3 c2 e5 f2 3a 6b a0 ab 90 f4 ff"))
        .unwrap();
    assert_eq!(first[0], (b":method".to_vec(), b"GET".to_vec()));
    assert_eq!(
        first[3],
        (b":authority".to_vec(), b"www.example.com".to_vec())
    );
    assert_eq!(decoder.size(), 57);

    let second = decoder
        .decode(&unhex("82 86 84 be 58 86 a8 eb 10 64 9c bf"))
        .unwrap();
    assert_eq!(
        second[3],
        (b":authority".to_vec(), b"www.example.com".to_vec())
    );
    assert_eq!(second[4], (b"cache-control".to_vec(), b"no-cache".to_vec()));
    assert_eq!(decoder.size(), 110);

    let third = decoder
        .decode(&unhex(
            "82 87 85 bf 40 88 25 a8 49 e9 5b a9 7d 7f 89 25 a8 49 e9 5b b8 e8 b4 bf",
        ))
        .unwrap();
    assert_eq!(third[2], (b":path".to_vec(), b"/index.html".to_vec()));
    assert_eq!(
        third[3],
        (b":authority".to_vec(), b"www.example.com".to_vec())
    );
    assert_eq!(third[4], (b"custom-key".to_vec(), b"custom-value".to_vec()));
    assert_eq!(decoder.size(), 164);
}

#[test]
fn huffman_rejects_non_ones_padding() {
    let mut decoder = HpackDecoder::new();
    // Literal indexed name (:authority), Huffman value bit pattern with invalid padding.
    let result = decoder.decode(&[0x40, 0x81, 0x00]);
    assert!(result.is_err());
}
