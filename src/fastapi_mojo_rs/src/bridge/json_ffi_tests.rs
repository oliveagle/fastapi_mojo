use super::json_ffi::{
    fm_json_object_add, fm_json_object_begin, fm_json_object_finish, fm_json_object_free,
};
use std::ptr;

fn finish_object() -> Vec<u8> {
    let slice = fm_json_object_finish();
    assert!(!slice.ptr.is_null());
    assert!(slice.len > 0);
    unsafe {
        let mut bytes = std::slice::from_raw_parts(slice.ptr as *const u8, slice.len as usize).to_vec();
        assert_eq!(*slice.ptr.add(slice.len as usize), 0);
        bytes.push(0);
        fm_json_object_free(slice.ptr);
        bytes
    }
}

#[test]
fn ffi_object_round_trip_is_nul_terminated() {
    assert_eq!(fm_json_object_begin(), 0);
    assert_eq!(
        fm_json_object_add(c"message".as_ptr(), 7,
                           c"hello \"world\"".as_ptr(), 13, 0),
        0
    );
    assert_eq!(
        finish_object(),
        b"{\"message\": \"hello \\\"world\\\"\"}\0".to_vec()
    );
}

#[test]
fn ffi_rejects_negative_length_without_mutating_writer() {
    assert_eq!(fm_json_object_begin(), 0);
    assert_eq!(fm_json_object_add(ptr::null(), -1, ptr::null(), 0, 0), -1);
    assert_eq!(finish_object(), b"{}\0".to_vec());
}

#[test]
fn ffi_zero_lengths_are_empty_strings() {
    assert_eq!(fm_json_object_begin(), 0);
    assert_eq!(fm_json_object_add(ptr::null(), 0, ptr::null(), 0, 0), 0);
    assert_eq!(finish_object(), b"{\"\": \"\"}\0".to_vec());
}
