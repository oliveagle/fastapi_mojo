//! deflate.rs — RFC 7692 permessage-deflate negotiation and streams.
//!
//! The extension is strictly opt-in per connection. Existing RFC 6455 clients
//! never offer it and therefore take the uncompressed parser/writer path.
//! Context takeover follows RFC direction semantics: `server_no_context_takeover`
//! controls this server's compressor, while `client_no_context_takeover`
//! controls the client-to-server compressor (and hence our decompressor).

use std::sync::atomic::{AtomicI32, Ordering};

use miniz_oxide::deflate::core::{create_comp_flags_from_zip_params, CompressorOxide};
use miniz_oxide::deflate::stream::deflate;
use miniz_oxide::inflate::stream::{inflate, InflateState};
use miniz_oxide::{DataFormat, MZFlush, MZStatus};

use super::WS_MAX_MSG;

const EMPTY_STORED_TAIL: [u8; 4] = [0x00, 0x00, 0xff, 0xff];
const DEFLATE_LEVEL: i32 = 6;

pub type WsCompressor = CompressorOxide;
pub type WsInflater = InflateState;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeflateMode {
    Off,
    On,
    Required,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NegotiatedDeflate {
    /// True means this server starts each outgoing message with an empty LZ77 window.
    pub server_no_context_takeover: bool,
    /// True means the client agreed to start each incoming message with an empty window.
    pub client_no_context_takeover: bool,
    /// The offer constrained our fixed 32 KiB window to exactly 15 bits.
    pub respond_server_window_bits: bool,
}

impl NegotiatedDeflate {
    pub fn response_header(&self) -> Vec<u8> {
        let mut s = String::from("permessage-deflate");
        if self.server_no_context_takeover {
            s.push_str("; server_no_context_takeover");
        }
        if self.client_no_context_takeover {
            s.push_str("; client_no_context_takeover");
        }
        if self.respond_server_window_bits {
            s.push_str("; server_max_window_bits=15");
        }
        s.into_bytes()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecompressError {
    Data,
    TooLarge,
}

pub fn get_ws_deflate_mode() -> DeflateMode {
    let cached = WS_DEFLATE_MODE.load(Ordering::Acquire);
    if let Some(mode) = mode_from_i32(cached) {
        return mode;
    }
    let raw = std::env::var("FASTAPI_MOJO_WS_DEFLATE").ok();
    let mode = match raw.as_deref().unwrap_or_default() {
        "" | "1" | "true" | "on" | "yes" => DeflateMode::On,
        "0" | "false" | "off" | "no" => DeflateMode::Off,
        "required" => DeflateMode::Required,
        _ => DeflateMode::On,
    };
    let _ = WS_DEFLATE_MODE.compare_exchange(
        -1,
        mode as i32,
        Ordering::AcqRel,
        Ordering::Acquire,
    );
    mode
}

static WS_DEFLATE_MODE: AtomicI32 = AtomicI32::new(-1);

const fn mode_from_i32(v: i32) -> Option<DeflateMode> {
    match v {
        0 => Some(DeflateMode::Off),
        1 => Some(DeflateMode::On),
        2 => Some(DeflateMode::Required),
        _ => None,
    }
}

#[cfg(test)]
pub fn reset_ws_deflate_mode_cache_for_test() {
    WS_DEFLATE_MODE.store(-1, Ordering::Release);
}

/// Parse the full extension header and return the first supported offer.
///
/// Unsupported offers do not fail the connection; RFC 7692 lets the server select
/// another offer in the same comma-separated list.
pub fn negotiate_extensions(header: &[u8]) -> Option<NegotiatedDeflate> {
    let header = String::from_utf8_lossy(header);
    for offer in header.split(',') {
        if let Some(agreed) = negotiate_offer(offer) {
            return Some(agreed);
        }
    }
    None
}

fn negotiate_offer(offer: &str) -> Option<NegotiatedDeflate> {
    let mut parts = offer.split(';');
    let name = parts.next()?.trim();
    if !name.eq_ignore_ascii_case("permessage-deflate") {
        return None;
    }

    let mut agreed = NegotiatedDeflate {
        server_no_context_takeover: false,
        client_no_context_takeover: false,
        respond_server_window_bits: false,
    };
    let mut seen_server_noct = false;
    let mut seen_client_noct = false;
    let mut seen_server_bits = false;
    let mut seen_client_bits = false;

    for raw in parts {
        let param = raw.trim();
        if param.is_empty() {
            continue;
        }
        let (key, value) = match param.split_once('=') {
            Some((k, v)) => (k.trim(), Some(v.trim())),
            None => (param, None),
        };
        match key.to_ascii_lowercase().as_str() {
            "server_no_context_takeover" => {
                if value.is_some() || seen_server_noct {
                    return None;
                }
                seen_server_noct = true;
                agreed.server_no_context_takeover = true;
            }
            "client_no_context_takeover" => {
                if value.is_some() || seen_client_noct {
                    return None;
                }
                seen_client_noct = true;
                agreed.client_no_context_takeover = true;
            }
            "server_max_window_bits" => {
                if seen_server_bits {
                    return None;
                }
                seen_server_bits = true;
                let bits = parse_window_bits(value?)?;
                // miniz_oxide has a fixed 15-bit LZ77 dictionary. It can honor
                // an explicit 15-bit request, but cannot shrink its dictionary.
                if bits != 15 {
                    return None;
                }
                agreed.respond_server_window_bits = true;
            }
            "client_max_window_bits" => {
                if seen_client_bits {
                    return None;
                }
                seen_client_bits = true;
                // A bare value advertises support for response negotiation. Any
                // 8..15 client window fits inside our 32 KiB inflate dictionary.
                if let Some(v) = value {
                    let _ = parse_window_bits(v)?;
                }
            }
            _ => return None,
        }
    }
    Some(agreed)
}

fn parse_window_bits(value: &str) -> Option<u8> {
    if value.is_empty() || value.len() > 2 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if value.len() > 1 && value.starts_with('0') {
        return None;
    }
    let bits = value.parse::<u8>().ok()?;
    (8..=15).contains(&bits).then_some(bits)
}

pub fn new_compressor() -> Box<CompressorOxide> {
    // window_bits < 0 selects raw DEFLATE (RFC 1951), without a zlib wrapper.
    let flags = create_comp_flags_from_zip_params(DEFLATE_LEVEL, -15, 0);
    Box::new(CompressorOxide::new(flags))
}

pub fn new_inflater() -> Box<InflateState> {
    Box::new(InflateState::new(DataFormat::Raw))
}

/// Compress one complete message and remove the RFC 7692 sync-flush tail.
pub fn compress_message(
    compressor: &mut CompressorOxide,
    input: &[u8],
    no_context_takeover: bool,
) -> Option<Vec<u8>> {
    if no_context_takeover {
        // reset() preserves the allocation and clears the previous raw-DEFLATE
        // completion state as well as the LZ77 dictionary.
        compressor.reset();
    }
    let mut out = Vec::new();
    let cap = input.len().saturating_add(4096).max(64);
    let mut buf = vec![0u8; cap];
    let mut in_off = 0usize;
    loop {
        let res = deflate(compressor, &input[in_off..], &mut buf, MZFlush::Sync);
        if res.status.is_err() {
            return None;
        }
        in_off += res.bytes_consumed;
        out.extend_from_slice(&buf[..res.bytes_written]);
        if out.len() > WS_MAX_MSG {
            return None;
        }
        if in_off < input.len() {
            if res.bytes_written == 0 {
                return None;
            }
            continue;
        }

        // A Z_SYNC_FLUSH stream must terminate in an empty stored block. Some
        // tiny inputs may place that block in a second call; finish it before
        // removing the four marker octets.
        if out.ends_with(&EMPTY_STORED_TAIL) {
            out.truncate(out.len() - EMPTY_STORED_TAIL.len());
            return Some(out);
        }
        let res = deflate(compressor, &[], &mut buf, MZFlush::Sync);
        if res.status.is_err() || res.bytes_consumed != 0 || res.bytes_written == 0 {
            return None;
        }
        out.extend_from_slice(&buf[..res.bytes_written]);
    }
}

/// Append the receiver-side empty stored block, inflate, and enforce the 1 MiB cap.
pub fn decompress_message(
    inflater: &mut InflateState,
    compressed: &[u8],
    no_context_takeover: bool,
) -> Result<Vec<u8>, DecompressError> {
    if compressed.len() > WS_MAX_MSG {
        return Err(DecompressError::TooLarge);
    }
    if no_context_takeover {
        inflater.reset(DataFormat::Raw);
    }

    let mut input = Vec::with_capacity(compressed.len() + EMPTY_STORED_TAIL.len());
    input.extend_from_slice(compressed);
    input.extend_from_slice(&EMPTY_STORED_TAIL);

    let mut out = Vec::new();
    let mut cap = (compressed.len() * 2).clamp(64, 64 * 1024);
    let mut buf = vec![0u8; cap];
    let mut in_off = 0usize;
    loop {
        if out.len() > WS_MAX_MSG {
            return Err(DecompressError::TooLarge);
        }
        if buf.is_empty() {
            if cap > WS_MAX_MSG {
                return Err(DecompressError::TooLarge);
            }
            cap = (cap * 2).min(WS_MAX_MSG + 1);
            buf = vec![0u8; cap];
        }
        let res = inflate(inflater, &input[in_off..], &mut buf, MZFlush::None);
        if res.status.is_err() {
            return Err(DecompressError::Data);
        }
        in_off += res.bytes_consumed;
        out.extend_from_slice(&buf[..res.bytes_written]);
        if out.len() > WS_MAX_MSG {
            return Err(DecompressError::TooLarge);
        }
        match res.status.ok() {
            Some(MZStatus::StreamEnd) => {
                // A BFINAL stream cannot be continued with its old dictionary.
                inflater.reset(DataFormat::Raw);
                return Ok(out);
            }
            Some(_) => {
                if in_off == input.len() {
                    // Sync-flush messages intentionally end in a non-final empty
                    // stored block, so Ok (rather than StreamEnd) is normal. A
                    // full miniz output ring can still hold decoded bytes even
                    // when all current input was consumed; add one more stored
                    // block and grow the output buffer to drain it.
                    if res.bytes_written == buf.len() && out.len() < WS_MAX_MSG {
                        input.extend_from_slice(&EMPTY_STORED_TAIL);
                        if cap > WS_MAX_MSG {
                            return Err(DecompressError::TooLarge);
                        }
                        cap = (cap * 2).min(WS_MAX_MSG + 1);
                        buf = vec![0u8; cap];
                        continue;
                    }
                    return Ok(out);
                }
                if res.bytes_written == 0 && res.bytes_consumed == 0 {
                    // Grow once before rejecting no-progress input.
                    if out.len() + buf.len() < WS_MAX_MSG {
                        buf.clear();
                        continue;
                    }
                    return Err(DecompressError::TooLarge);
                }
            }
            None => unreachable!("status.is_err was checked"),
        }
    }
}
