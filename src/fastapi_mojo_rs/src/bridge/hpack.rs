//! bridge/hpack.rs — HPACK (RFC 7541) decoder/encoder for HTTP/2.

//!
//! Decision-63 deliberately keeps this module dependency-free and bounded:
//! decoder dynamic table is capped at the protocol default 4096 bytes, string
//! lengths use a 24-bit integer ceiling, and the Huffman table is the canonical
//! RFC table. The encoder only emits literal fields (no Huffman), which is
//! valid HPACK and keeps response-side code small.

use std::collections::VecDeque;

use super::hpack_huffman;

pub const HPACK_STATIC_TABLE: [(&[u8], &[u8]); 61] = [
    (b":authority", b""),
    (b":method", b"GET"),
    (b":method", b"POST"),
    (b":path", b"/"),
    (b":path", b"/index.html"),
    (b":scheme", b"http"),
    (b":scheme", b"https"),
    (b":status", b"200"),
    (b":status", b"204"),
    (b":status", b"206"),
    (b":status", b"304"),
    (b":status", b"400"),
    (b":status", b"404"),
    (b":status", b"500"),
    (b"accept-charset", b""),
    (b"accept-encoding", b"gzip, deflate"),
    (b"accept-language", b""),
    (b"accept-ranges", b""),
    (b"accept", b""),
    (b"access-control-allow-origin", b""),
    (b"age", b""),
    (b"allow", b""),
    (b"authorization", b""),
    (b"cache-control", b""),
    (b"content-disposition", b""),
    (b"content-encoding", b""),
    (b"content-language", b""),
    (b"content-length", b""),
    (b"content-location", b""),
    (b"content-range", b""),
    (b"content-type", b""),
    (b"cookie", b""),
    (b"date", b""),
    (b"etag", b""),
    (b"expect", b""),
    (b"expires", b""),
    (b"from", b""),
    (b"host", b""),
    (b"if-match", b""),
    (b"if-modified-since", b""),
    (b"if-none-match", b""),
    (b"if-range", b""),
    (b"if-unmodified-since", b""),
    (b"last-modified", b""),
    (b"link", b""),
    (b"location", b""),
    (b"max-forwards", b""),
    (b"proxy-authenticate", b""),
    (b"proxy-authorization", b""),
    (b"range", b""),
    (b"referer", b""),
    (b"refresh", b""),
    (b"retry-after", b""),
    (b"server", b""),
    (b"set-cookie", b""),
    (b"strict-transport-security", b""),
    (b"transfer-encoding", b""),
    (b"user-agent", b""),
    (b"vary", b""),
    (b"via", b""),
    (b"www-authenticate", b""),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HpackError {
    Truncated,
    IntegerOverflow,
    InvalidIndex(usize),
    InvalidTableSize(usize),
    InvalidHuffman,
    InvalidDynamicUpdate,
}

type Field = (Vec<u8>, Vec<u8>);

#[derive(Debug, Default)]
pub struct HpackDecoder {
    entries: VecDeque<Field>,
    size: usize,
    max_size: usize,
}

impl HpackDecoder {
    pub fn new() -> Self {
        Self {
            entries: VecDeque::new(),
            size: 0,
            max_size: 4096,
        }
    }

    pub fn size(&self) -> usize {
        self.size
    }

    fn lookup(&self, index: usize) -> Result<Field, HpackError> {
        if index == 0 {
            return Err(HpackError::InvalidIndex(0));
        }
        if index <= HPACK_STATIC_TABLE.len() {
            let (name, value) = HPACK_STATIC_TABLE[index - 1];
            return Ok((name.to_vec(), value.to_vec()));
        }
        let dynamic_index = index - HPACK_STATIC_TABLE.len() - 1;
        self.entries
            .get(dynamic_index)
            .cloned()
            .ok_or(HpackError::InvalidIndex(index))
    }

    fn evict_to(&mut self, limit: usize) {
        while self.size > limit {
            if let Some((name, value)) = self.entries.pop_back() {
                self.size = self.size.saturating_sub(name.len() + value.len() + 32);
            } else {
                break;
            }
        }
    }

    fn set_max_size(&mut self, value: usize) -> Result<(), HpackError> {
        if value > 4096 {
            return Err(HpackError::InvalidTableSize(value));
        }
        self.max_size = value;
        self.evict_to(value);
        Ok(())
    }

    fn insert(&mut self, name: Vec<u8>, value: Vec<u8>) {
        let entry_size = name.len() + value.len() + 32;
        if entry_size > self.max_size {
            self.entries.clear();
            self.size = 0;
            return;
        }
        self.evict_to(self.max_size - entry_size);
        self.size += entry_size;
        self.entries.push_front((name, value));
    }

    pub fn decode(&mut self, input: &[u8]) -> Result<Vec<Field>, HpackError> {
        let mut out = Vec::new();
        let mut pos = 0usize;
        let mut can_size_update = true;
        while pos < input.len() {
            let first = input[pos];
            if first & 0x80 != 0 {
                let (index, next) = decode_integer(input, pos, first & 0x7f, 7)?;
                pos = next;
                let field = self.lookup(index)?;
                out.push(field);
            } else if first & 0xe0 == 0x20 {
                if !can_size_update {
                    return Err(HpackError::InvalidDynamicUpdate);
                }
                let (value, next) = decode_integer(input, pos, first & 0x1f, 5)?;
                self.set_max_size(value)?;
                pos = next;
                continue;
            } else {
                let incremental = first & 0xc0 == 0x40;
                let prefix_bits = if incremental { 6 } else { 4 };
                let prefix_mask = if incremental {
                    first & 0x3f
                } else {
                    first & 0x0f
                };
                let (index, mut next) = decode_integer(input, pos, prefix_mask, prefix_bits)?;
                let name = if index == 0 {
                    let (n, p) = read_string(input, next)?;
                    next = p;
                    n
                } else {
                    let field = self.lookup(index)?;
                    next = next.max(pos + 1);
                    field.0
                };
                if next > input.len() {
                    return Err(HpackError::Truncated);
                }
                let (value, end) = read_string(input, next)?;
                if incremental {
                    self.insert(name.clone(), value.clone());
                }
                out.push((name, value));
                pos = end;
                can_size_update = false;
                continue;
            }
            can_size_update = false;
        }
        Ok(out)
    }
}

fn decode_integer(
    input: &[u8],
    pos: usize,
    prefix_value: u8,
    prefix_bits: u32,
) -> Result<(usize, usize), HpackError> {
    let mask = (1u32 << prefix_bits) - 1;
    let mut value = (prefix_value & mask as u8) as usize;
    let mut next = pos + 1;
    if (value as u32) < mask {
        return Ok((value, next));
    }
    let mut shift = 0u32;
    loop {
        if next >= input.len() {
            return Err(HpackError::Truncated);
        }
        let b = input[next];
        next += 1;
        let add = usize::from(b & 0x7f)
            .checked_shl(shift)
            .ok_or(HpackError::IntegerOverflow)?;
        value = value.checked_add(add).ok_or(HpackError::IntegerOverflow)?;
        if value >= 1 << 24 {
            return Err(HpackError::IntegerOverflow);
        }
        if b & 0x80 == 0 {
            return Ok((value, next));
        }
        shift += 7;
        if shift > 28 {
            return Err(HpackError::IntegerOverflow);
        }
    }
}

fn read_string(input: &[u8], pos: usize) -> Result<(Vec<u8>, usize), HpackError> {
    if pos >= input.len() {
        return Err(HpackError::Truncated);
    }
    let huffman = input[pos] & 0x80 != 0;
    let (len, mut next) = decode_integer(input, pos, input[pos] & 0x7f, 7)?;
    if len >= 1 << 20 || next.saturating_add(len) > input.len() {
        return Err(HpackError::Truncated);
    }
    let raw = &input[next..next + len];
    next += len;
    let bytes = if huffman {
        hpack_huffman::decode(raw).map_err(|_| HpackError::InvalidHuffman)?
    } else {
        raw.to_vec()
    };
    Ok((bytes, next))
}

fn encode_integer(value: usize, prefix_bits: u32, first: u8) -> Vec<u8> {
    let mask = (1u32 << prefix_bits) - 1;
    let mut out = Vec::new();
    if value < mask as usize {
        out.push(first | value as u8);
        return out;
    }
    out.push(first | mask as u8);
    let mut rem = value - mask as usize;
    while rem >= 128 {
        out.push((rem & 0x7f) as u8 | 0x80);
        rem >>= 7;
    }
    out.push(rem as u8);
    out
}

fn encode_string(value: &[u8]) -> Vec<u8> {
    let mut out = encode_integer(value.len(), 7, 0);
    out.extend_from_slice(value);
    out
}

/// Encode a literal header field with an indexed name, without indexing.
pub fn encode_indexed_name(index: usize, value: &[u8]) -> Vec<u8> {
    let mut out = encode_integer(index, 4, 0);
    out.extend(encode_string(value));
    out
}

/// Encode a literal header field with a literal name, without indexing.
pub fn encode_literal_name(name: &[u8], value: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8];
    out.extend(encode_string(name));
    out.extend(encode_string(value));
    out
}

pub fn decode_integer_public(
    input: &[u8],
    pos: usize,
    prefix_bits: u32,
) -> Result<(usize, usize), HpackError> {
    decode_integer(input, pos, input[pos], prefix_bits)
}
