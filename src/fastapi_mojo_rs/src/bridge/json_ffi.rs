//! Decision-66 FFI: opt-in streaming JSON object serialization.
//!
//! Mojo supplies one field at a time from its flat response dict; Rust performs
//! escaping and output assembly. Explicit lengths make key/value input binary
//! safe. The finished JSON buffer is malloc'd, NUL-terminated, and released by
//! `fm_json_object_free` (decision-36 contract).

use std::os::raw::{c_char, c_int, c_long, c_void};
use std::ptr;
use std::sync::{Mutex, OnceLock};

use super::json_writer::JsonObjectWriter;
use super::request::CSlice;

extern "C" {
    fn malloc(size: usize) -> *mut c_void;
    fn free(ptr: *mut c_void);
}

static WRITER: OnceLock<Mutex<JsonObjectWriter>> = OnceLock::new();

fn writer() -> &'static Mutex<JsonObjectWriter> {
    WRITER.get_or_init(|| Mutex::new(JsonObjectWriter::new()))
}

fn input_bytes<'a>(p: *const c_char, len: c_long) -> Option<&'a [u8]> {
    if len < 0 || (p.is_null() && len > 0) {
        return None;
    }
    if len == 0 {
        return Some(&[]);
    }
    Some(unsafe { std::slice::from_raw_parts(p as *const u8, len as usize) })
}

fn malloc_nul(bytes: &[u8]) -> *mut c_char {
    let p = unsafe { malloc(bytes.len() + 1) } as *mut c_char;
    if p.is_null() {
        return p;
    }
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        *p.add(bytes.len()) = 0;
    }
    p
}

/// Start a new object. 0 = ok, -1 = lock poisoned.
#[no_mangle]
pub extern "C" fn fm_json_object_begin() -> c_int {
    match writer().lock() {
        Ok(mut w) => {
            *w = JsonObjectWriter::new();
            0
        }
        Err(_) => -1,
    }
}

/// Add one member. 0 = ok, -1 = invalid pointer/length or lock poisoned.
#[no_mangle]
pub extern "C" fn fm_json_object_add(
    key: *const c_char,
    key_len: c_long,
    value: *const c_char,
    value_len: c_long,
    raw: c_int,
) -> c_int {
    let Some(key) = input_bytes(key, key_len) else {
        return -1;
    };
    let Some(value) = input_bytes(value, value_len) else {
        return -1;
    };
    match writer().lock() {
        Ok(mut w) => {
            w.add_field(key, value, raw != 0);
            0
        }
        Err(_) => -1,
    }
}

/// Finish and return a malloc'd NUL-terminated JSON buffer.
#[no_mangle]
pub extern "C" fn fm_json_object_finish() -> CSlice {
    let bytes = match writer().lock() {
        Ok(mut w) => w.finish(),
        Err(_) => Vec::new(),
    };
    let p = malloc_nul(&bytes);
    if p.is_null() {
        return CSlice {
            ptr: ptr::null(),
            len: 0,
        };
    }
    CSlice {
        ptr: p,
        len: bytes.len() as c_long,
    }
}

/// Free a buffer returned by `fm_json_object_finish`.
#[no_mangle]
pub extern "C" fn fm_json_object_free(ptr: *const c_char) {
    if !ptr.is_null() {
        unsafe { free(ptr as *mut c_void) };
    }
}
