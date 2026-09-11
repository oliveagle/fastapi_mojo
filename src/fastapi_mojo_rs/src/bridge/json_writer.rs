//! Decision-66: opt-in JSON object serialization acceleration.
//!
//! Hand-written, dependency-free “serde-like” writer. Mojo owns the flat
//! `Dict[String, String]` response model and iteration order; Rust performs the
//! byte-heavy JSON escaping and buffer assembly. Output is byte-for-byte
//! compatible with `json.mojo` for ordinary and `__nested__:` raw members.

pub const NESTED_PREFIX: &[u8] = b"__nested__:";

pub struct JsonObjectWriter {
    out: Vec<u8>,
    first: bool,
}

impl Default for JsonObjectWriter {
    fn default() -> Self {
        Self {
            out: Vec::new(),
            first: true,
        }
    }
}

impl JsonObjectWriter {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Append one object member. `raw` means `value` starts with the Mojo
    /// `__nested__:` marker and the suffix is already valid JSON.
    pub fn add_field(&mut self, key: &[u8], value: &[u8], raw: bool) {
        if self.first {
            self.out.push(b'{');
        } else {
            self.out.extend_from_slice(b", ");
        }
        self.first = false;
        escape_string_into(&mut self.out, key);
        self.out.extend_from_slice(b": ");

        if raw && value.starts_with(NESTED_PREFIX) {
            self.out
                .extend_from_slice(&value[NESTED_PREFIX.len()..]);
        } else {
            escape_string_into(&mut self.out, value);
        }
    }

    /// Consume buffered members and return `{...}`.
    pub fn finish(&mut self) -> Vec<u8> {
        if self.first {
            self.out.push(b'{');
        }
        self.out.push(b'}');
        let out = std::mem::take(&mut self.out);
        self.first = true;
        out
    }
}

/// Escape a UTF-8 string exactly like `json.mojo`: quote/backslash and the
/// three named controls (`\n`, `\r`, `\t`), other `<0x20` controls as lowercase `\u00xx`;
/// non-ASCII UTF-8 bytes pass through unchanged.
fn escape_string_into(out: &mut Vec<u8>, value: &[u8]) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    out.push(b'"');
    for &b in value {
        match b {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            0x00..=0x1f => {
                out.extend_from_slice(b"\\u00");
                out.push(HEX[(b >> 4) as usize]);
                out.push(HEX[(b & 0x0f) as usize]);
            }
            _ => out.push(b),
        }
    }
    out.push(b'"');
}
