//! ws_session_deflate.rs — per-connection RFC 7692 setup and outbound writer.
//!
//! This split keeps ws_session_ffi.rs below the repository's 500-line module
//! threshold while preserving the three-argument Mojo/C ABI unchanged.

use std::os::raw::c_int;

use super::conn::{Conn, WS_REASM_INIT};
use super::parse::get_header_value_ci;
use crate::ws::deflate::{
    compress_message, negotiate_extensions, new_compressor, new_inflater, DeflateMode,
};

/// Read the client offer, select a supported offer, and initialize conn streams.
/// Ok(None) means “accept the WebSocket uncompressed” (the extension is declined).
/// Err(RequiredNotOffered) means `required` mode had no acceptable offer and the caller must 400.
pub enum ConfigureError {
    RequiredNotOffered,
}

pub fn configure(c: &mut Conn, mode: DeflateMode) -> Result<Option<Vec<u8>>, ConfigureError> {
    let negotiated = if mode == DeflateMode::Off {
        None
    } else {
        let hdr_end = c.hdr_total.min(c.hdr.len());
        get_header_value_ci(&c.hdr[..hdr_end], b"Sec-WebSocket-Extensions")
            .as_deref()
            .and_then(negotiate_extensions)
    };
    if mode == DeflateMode::Required && negotiated.is_none() {
        return Err(ConfigureError::RequiredNotOffered);
    }
    match negotiated {
        Some(n) => {
            c.ws_deflate = true;
            c.ws_server_no_context_takeover = n.server_no_context_takeover;
            c.ws_client_no_context_takeover = n.client_no_context_takeover;
            if c.ws_comp.is_none() {
                c.ws_comp = Some(new_compressor());
            }
            if c.ws_decomp.is_none() {
                c.ws_decomp = Some(new_inflater());
            }
            if c.ws_decomp_buf.is_empty() {
                c.ws_decomp_buf = vec![0u8; WS_REASM_INIT];
            }
            Ok(Some(n.response_header()))
        }
        None => {
            c.ws_deflate = false;
            c.ws_server_no_context_takeover = false;
            c.ws_client_no_context_takeover = false;
            c.ws_comp = None;
            c.ws_decomp = None;
            c.ws_decomp_buf = Vec::new();
            Ok(None)
        }
    }
}

/// 压缩一个出站数据消息; 压缩失败时按 RFC 7692 允许的未压缩形态回退。
pub fn ws_write_conn_payload(c: &mut Conn, fd: c_int, opcode: c_int, payload: &[u8]) -> c_int {
    if c.ws_deflate && (opcode == 1 || opcode == 2) && !payload.is_empty() {
        if let Some(comp) = c.ws_comp.as_mut() {
            if let Some(wire) =
                compress_message(comp, payload, c.ws_server_no_context_takeover)
            {
                return crate::ws::ws_write_message_rsv1(
                    fd,
                    opcode,
                    wire.as_ptr(),
                    wire.len(),
                );
            }
            // A partially advanced takeover stream cannot be reused safely.
            comp.reset();
        }
    }
    crate::ws::ws_write_message(fd, opcode, payload.as_ptr(), payload.len())
}
