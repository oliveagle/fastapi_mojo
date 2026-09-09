//! crypto_tests.rs — SHA-256 / HMAC-SHA256 / base64url known vectors (决策-44).
//!
//! 向量来源: FIPS 180-4 (SHA-256) / RFC 4231 (HMAC) / RFC 7515 \u00a72.1
//! (base64url) / pyjwt 2.13 (JWT 签名交叉验证, 独立实现 oracle).

use super::crypto::{b64url_decode, b64url_encode, hmac_sha256, sha256};

fn hx(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

// ========== SHA-256 (FIPS 180-4) ==========

#[test]
fn sha256_empty() {
    assert_eq!(
        hx(&sha256(b"")),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
}

#[test]
fn sha256_abc() {
    assert_eq!(
        hx(&sha256(b"abc")),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

#[test]
fn sha256_448bit() {
    let data = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    assert_eq!(
        hx(&sha256(data)),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    );
}

#[test]
fn sha256_million_a() {
    let data = vec![b'a'; 1_000_000];
    assert_eq!(
        hx(&sha256(&data)),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    );
}

// ========== HMAC-SHA256 (RFC 4231) ==========

#[test]
fn hmac_tc1_key20x0b() {
    // TC1: key = 20 x 0x0b, data = "Hi There"
    assert_eq!(
        hx(&hmac_sha256(&[0x0b; 20], b"Hi There")),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    );
}

#[test]
fn hmac_tc2_jefe() {
    // TC2: key = "Jefe", data = "what do ya want for nothing?"
    assert_eq!(
        hx(&hmac_sha256(b"Jefe", b"what do ya want for nothing?")),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    );
}

#[test]
fn hmac_tc6_long_key() {
    // TC6: key = 131 x 0xaa (> block size -> 先 sha256), data = 50 x 0xdd
    assert_eq!(
        hx(&hmac_sha256(&[0xaa; 131], &[0xdd; 50])),
        "124c7d2385aa1743aaad12204e3464f06305fd1a6d291250fa564dceffab0c8a"
    );
}

#[test]
fn hmac_empty_key_empty_msg() {
    assert_eq!(
        hx(&hmac_sha256(b"", b"")),
        "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"
    );
}

// ========== base64url (RFC 7515 \u00a72.1) ==========

#[test]
fn b64url_rfc7515_vectors() {
    // RFC 7515 \u00a72.1 官方向量表
    assert_eq!(b64url_encode(b""), "");
    assert_eq!(b64url_encode(b"f"), "Zg");
    assert_eq!(b64url_encode(b"fo"), "Zm8");
    assert_eq!(b64url_encode(b"foo"), "Zm9v");
    assert_eq!(b64url_encode(b"foob"), "Zm9vYg");
    assert_eq!(b64url_encode(b"fooba"), "Zm9vYmE");
    assert_eq!(b64url_encode(b"foobar"), "Zm9vYmFy");
}

#[test]
fn b64url_decode_roundtrip() {
    let raw: Vec<u8> = (0..255u8).collect(); // 全字节域 (含 0x00)
    let enc = b64url_encode(&raw);
    assert_eq!(b64url_decode(&enc).unwrap(), raw);
    assert_eq!(b64url_encode(&b""[..]), "");
    assert_eq!(b64url_decode("").unwrap(), Vec::<u8>::new());
}

#[test]
fn b64url_decode_tolerant_and_reject() {
    // 宽松: 容忍标准字母表 +/ 与 padding
    assert_eq!(b64url_decode("Zm9vYg==").unwrap(), b"foob".to_vec());
    // 62/63 -> 12 bits: (62<<6)|63=4031, 出 1 字节 4031>>4=251, 余 4 bits(=15) 丢弃 (宽松尾语义)
    assert_eq!(b64url_decode("+/").unwrap(), vec![251]);
    // 非法字符 -> None
    assert!(b64url_decode("abc$").is_none());
    assert!(b64url_decode("a!b").is_none());
}

// ========== JWT HS256 交叉验证 (pyjwt 2.13 oracle) ==========

// pyjwt 2.13.0 独立实现签发 (2026-09-10 生成, 固定向量 — 防本实现系统性
// 错误: 若 sha256/hmac/b64url 任一系统性错, 与独立 oracle 必不匹配).
#[test]
fn jwt_hs256_pyjwt_oracle() {
    let key = b"probe-secret-key-42";
    let signing_input = b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\
eyJzdWIiOiJhZG1pbiIsInVzZXJuYW1lIjoiYWRtaW4iLCJpYXQiOjE3ODg5NzkyMDAsImV4cCI6OTk5OTk5OTk5OX0";
    let sig = b64url_encode(&hmac_sha256(key, signing_input));
    assert_eq!(sig, "k9rThWezzPx3d1B6pLUl_6yLHTsmfjxXKnDCo1fDPqw");
}
// ========== FFI 包装层 (ffi.rs fm_hmac_sha256_b64url) ==========

/// FFI 入口与纯 crypto 函数交叉验证: 同一 signing_input, FFI 结果必须
/// 等于 `b64url_encode(hmac_sha256(...))` (pyjwt oracle 向量), 且 NUL 终止
/// (决策-36 契约: Mojo CStringSlice.as_bytes() 按 C 串读至 NUL).
#[test]
fn ffi_hmac_sha256_b64url_matches_crypto() {
    use super::ffi;
    use std::ffi::CString;
    let key = CString::new("probe-secret-key-42").unwrap();
    let msg = CString::new(
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZG1pbiIsInVzZXJuYW1lIjoiYWRtaW4iLCJpYXQiOjE3ODg5NzkyMDAsImV4cCI6OTk5OTk5OTk5OX0",
    )
    .unwrap();
    let slice = ffi::fm_hmac_sha256_b64url(
        key.as_ptr(),
        key.to_bytes().len() as i64,
        msg.as_ptr(),
        msg.to_bytes().len() as i64,
    );
    let raw = unsafe { std::slice::from_raw_parts(slice.ptr as *const u8, slice.len as usize) };
    let got = std::str::from_utf8(raw).unwrap();
    assert_eq!(got, "k9rThWezzPx3d1B6pLUl_6yLHTsmfjxXKnDCo1fDPqw");
    // NUL 终止: len 位置字节 = 0
    assert_eq!(unsafe { *slice.ptr.add(slice.len as usize) }, 0);
    ffi::fm_hmac_sha256_b64url_free(slice.ptr);
}

/// FFI 空输入路径 (len=0 + null ptr 回退) 与直接 crypto 调用一致, free 幂等安全.
#[test]
fn ffi_hmac_sha256_b64url_empty_inputs() {
    use super::ffi;
    let slice = ffi::fm_hmac_sha256_b64url(std::ptr::null(), 0, std::ptr::null(), 0);
    let raw = unsafe { std::slice::from_raw_parts(slice.ptr as *const u8, slice.len as usize) };
    let got = std::str::from_utf8(raw).unwrap().to_owned();
    let expect = b64url_encode(&hmac_sha256(b"", b""));
    assert_eq!(got, expect);
    ffi::fm_hmac_sha256_b64url_free(slice.ptr);
    ffi::fm_hmac_sha256_b64url_free(std::ptr::null()); // null 容忍
}
