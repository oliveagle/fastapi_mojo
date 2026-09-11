//! bridge/http2.rs — bounded HTTP/2 prior-knowledge server transport (RFC 7540).
//!
//! Decision-63 deliberately implements a dependency-free h2c subset: HPACK
//! request decoding, frame validation, SETTINGS/PING/GOAWAY handling, bounded
//! stream queues, and sequential request dispatch. TLS/ALPN, HTTP/1.1 Upgrade,
//! trailers, extended CONNECT, and full flow-control waiting remain explicit
//! non-goals in ADR-0038.

use std::collections::VecDeque;

use super::hpack::HpackDecoder;
use super::http2_frames::{
    frame, remove_padding, settings_frame, window_update, ACK, CONTINUATION, DATA, END_HEADERS,
    END_STREAM, FRAME_HEADER, GOAWAY, HEADERS, PING, PRIORITY, PRIORITY_FLAG, PUSH_PROMISE,
    RST_STREAM, SETTINGS, WINDOW_UPDATE,
};
pub use super::http2_request::H2Request;

pub const H2_PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const H2_PHASE: i32 = 6;

const DEFAULT_MAX_FRAME: usize = 16 * 1024;
const MAX_FRAME_SIZE: usize = 1024 * 1024;
const RX_MAX: usize = 2 * 1024 * 1024;
const HEADER_BLOCK_MAX: usize = 16 * 1024;
const MAX_HEADER_LIST: usize = 256;
const MAX_PENDING_STREAMS: usize = 100;
const MAX_FIELD: usize = 4096;

#[derive(Debug)]
pub struct H2Connection {
    pub rx: Vec<u8>,
    decoder: HpackDecoder,
    partial_headers: Option<(u32, Vec<u8>, bool)>,
    partial_request: Option<H2Request>,
    ready: Option<H2Request>,
    pending: VecDeque<H2Request>,
    current: Option<H2Request>,
    current_stream: Option<u32>,
    frames: VecDeque<Vec<u8>>,
    send_window: i64,
    peer_initial_window: i64,
    last_stream_id: u32,
    max_frame_size: usize,
}

impl Default for H2Connection {
    fn default() -> Self {
        Self::new(Vec::new())
    }
}

impl H2Connection {
    pub fn new(rx: Vec<u8>) -> Self {
        let mut connection = Self {
            rx,
            decoder: HpackDecoder::new(),
            partial_headers: None,
            partial_request: None,
            ready: None,
            pending: VecDeque::new(),
            current: None,
            current_stream: None,
            frames: VecDeque::new(),
            send_window: 65_535,
            peer_initial_window: 65_535,
            last_stream_id: 0,
            max_frame_size: DEFAULT_MAX_FRAME,
        };
        connection.frames.push_back(settings_frame(&[
            (0x0003, MAX_PENDING_STREAMS as u32),
            (0x0004, 1_048_576),
            (0x0005, MAX_FRAME_SIZE as u32),
        ]));
        connection
    }

    pub fn has_ready(&self) -> bool {
        self.ready.is_some() || self.pending.front().is_some()
    }

    pub fn current_stream(&self) -> Option<u32> {
        self.current_stream
    }

    /// Clone the request being dispatched for request-global header adapters.
    pub fn current_request(&self) -> Option<H2Request> {
        self.current.clone()
    }

    pub fn finish_current(&mut self) {
        self.current = None;
        self.current_stream = None;
        self.ready = self.pending.pop_front();
    }

    pub fn take_ready(&mut self) -> Option<H2Request> {
        if self.ready.is_none() {
            self.ready = self.pending.pop_front();
        }
        let ready = self.ready.take()?;
        self.current_stream = Some(ready.stream_id);
        self.current = Some(ready.clone());
        Some(ready)
    }

    pub fn take_frames(&mut self) -> Vec<Vec<u8>> {
        self.frames.drain(..).collect()
    }

    /// Reserve outbound DATA bytes from the connection flow-control window.
    /// This transport processes streams sequentially; ADR-0038 documents that
    /// responses larger than the currently available window fail rather than block.
    pub fn take_send_window(&mut self, len: usize) -> bool {
        if len as i64 > self.send_window {
            return false;
        }
        self.send_window -= len as i64;
        true
    }

    pub fn enqueue_goaway(&mut self, error_code: u32) {
        let mut payload = Vec::with_capacity(8);
        payload.extend_from_slice(&self.last_stream_id.to_be_bytes());
        payload.extend_from_slice(&error_code.to_be_bytes());
        self.frames.push_back(frame(GOAWAY, 0, 0, &payload));
    }

    pub fn enqueue_rst_stream(&mut self, stream: u32, error_code: u32) {
        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&error_code.to_be_bytes());
        self.frames
            .push_back(frame(RST_STREAM, 0, stream, &payload));
    }

    pub fn feed(&mut self, bytes: &[u8], max_body: usize) -> Result<(), &'static str> {
        if self.rx.len().saturating_add(bytes.len()) > RX_MAX {
            return Err("http2 receive buffer exceeded");
        }
        self.rx.extend_from_slice(bytes);
        while self.rx.len() >= FRAME_HEADER {
            let length = usize::from(self.rx[0]) << 16
                | usize::from(self.rx[1]) << 8
                | usize::from(self.rx[2]);
            if length > self.max_frame_size {
                return Err("http2 frame too large");
            }
            let end = FRAME_HEADER.saturating_add(length);
            if self.rx.len() < end {
                break;
            }
            let frame = self.rx[..end].to_vec();
            self.rx.drain(..end);
            let ty = frame[3];
            let flags = frame[4];
            let stream = u32::from_be_bytes([frame[5], frame[6], frame[7], frame[8]]) & 0x7fff_ffff;
            self.handle_frame(ty, flags, stream, &frame[FRAME_HEADER..], max_body)?;
            if self.ready.is_none() && !self.pending.is_empty() {
                self.ready = self.pending.pop_front();
            }
        }
        Ok(())
    }

    fn handle_frame(
        &mut self,
        ty: u8,
        flags: u8,
        stream: u32,
        payload: &[u8],
        max_body: usize,
    ) -> Result<(), &'static str> {
        // Once HEADERS is split, only CONTINUATION may precede END_HEADERS.
        if self.partial_headers.is_some() && ty != CONTINUATION {
            return Err("expected http2 continuation");
        }
        match ty {
            DATA if stream != 0 && stream & 1 == 1 => {
                self.handle_data(stream, flags, payload, max_body)
            }
            HEADERS if stream != 0 && stream & 1 == 1 && stream > self.last_stream_id => {
                self.last_stream_id = stream;
                self.handle_headers(stream, flags, payload, max_body)
            }
            CONTINUATION if stream != 0 => {
                self.handle_continuation(stream, flags, payload, max_body)
            }
            SETTINGS if stream == 0 => {
                if flags & ACK == 0 {
                    self.handle_settings(payload)?;
                    self.frames.push_back(frame(SETTINGS, ACK, 0, &[]));
                } else if !payload.is_empty() {
                    return Err("malformed settings ack");
                }
                Ok(())
            }
            PING if stream == 0 => {
                if payload.len() != 8 {
                    return Err("malformed ping");
                }
                if flags & ACK == 0 {
                    self.frames.push_back(frame(PING, ACK, 0, payload));
                }
                Ok(())
            }
            WINDOW_UPDATE if stream == 0 => self.handle_window_update(stream, payload),
            WINDOW_UPDATE if stream == self.current_stream.unwrap_or(0) => {
                self.handle_window_update(stream, payload)
            }
            PRIORITY if payload.len() == 5 => Ok(()),
            RST_STREAM if payload.len() == 4 => {
                if self.partial_request.as_ref().map(|r| r.stream_id) == Some(stream) {
                    self.partial_request = None;
                }
                Ok(())
            }
            GOAWAY if stream == 0 => Err("client goaway"),
            PUSH_PROMISE => Err("client push promise rejected"),
            SETTINGS | PING | WINDOW_UPDATE | PRIORITY | RST_STREAM | GOAWAY => {
                Err("http2 frame on invalid stream")
            }
            _ => Ok(()),
        }
    }

    fn handle_settings(&mut self, payload: &[u8]) -> Result<(), &'static str> {
        if !payload.len().is_multiple_of(6) {
            return Err("malformed settings");
        }
        for setting in payload.chunks_exact(6) {
            let id = u16::from_be_bytes([setting[0], setting[1]]);
            let value = u32::from_be_bytes([setting[2], setting[3], setting[4], setting[5]]);
            match id {
                0x0004 => {
                    if value > 0x7fff_ffff {
                        return Err("invalid initial window");
                    }
                    let new = i64::from(value);
                    let delta = new - self.peer_initial_window;
                    self.peer_initial_window = new;
                    self.send_window = (self.send_window + delta).clamp(0, 0x7fff_ffff);
                }
                0x0005 => {
                    if !((16 * 1024..=MAX_FRAME_SIZE)
                        .contains(&usize::try_from(value).map_err(|_| "invalid max frame size")?))
                    {
                        return Err("invalid max frame size");
                    }
                    self.max_frame_size = value as usize;
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn handle_window_update(&mut self, stream: u32, payload: &[u8]) -> Result<(), &'static str> {
        if payload.len() != 4 {
            return Err("malformed window update");
        }
        let increment =
            u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]) & 0x7fff_ffff;
        if increment == 0 {
            return Err("zero window increment");
        }
        if stream == 0 || stream == self.current_stream.unwrap_or(0) {
            self.send_window = (self.send_window + i64::from(increment)).clamp(0, 0x7fff_ffff);
        }
        Ok(())
    }

    fn handle_data(
        &mut self,
        stream: u32,
        flags: u8,
        payload: &[u8],
        max_body: usize,
    ) -> Result<(), &'static str> {
        if !payload.is_empty() {
            self.frames
                .push_back(window_update(0, payload.len() as u32));
            self.frames
                .push_back(window_update(stream, payload.len() as u32));
        }
        let data = remove_padding(flags, payload)?;
        let end_stream = flags & END_STREAM != 0;
        let partial = match self.partial_request.as_mut() {
            Some(request) if request.stream_id == stream => request,
            _ => return Err("data for unknown stream"),
        };
        if partial.body.len().saturating_add(data.len()) > max_body {
            return Err("http2 body too large");
        }
        partial.body.extend_from_slice(data);
        if end_stream {
            let request = self
                .partial_request
                .take()
                .ok_or("data for unknown stream")?;
            if let Some(expected) = request.content_length()? {
                if request.body.len() != expected {
                    return Err("content length mismatch");
                }
            }
            self.queue_request(request)?;
        }
        Ok(())
    }

    fn handle_headers(
        &mut self,
        stream: u32,
        flags: u8,
        payload: &[u8],
        max_body: usize,
    ) -> Result<(), &'static str> {
        if self.partial_headers.is_some() || self.partial_request.is_some() {
            return Err("http2 stream overlap");
        }
        let mut data = remove_padding(flags, payload)?;
        if flags & PRIORITY_FLAG != 0 {
            if data.len() < 5 {
                return Err("malformed headers priority");
            }
            data = &data[5..];
        }
        let end_stream = flags & END_STREAM != 0;
        if flags & END_HEADERS != 0 {
            self.decode_headers(stream, data, end_stream, max_body)
        } else {
            if data.len() > HEADER_BLOCK_MAX {
                return Err("http2 header block too large");
            }
            self.partial_headers = Some((stream, data.to_vec(), end_stream));
            Ok(())
        }
    }

    fn handle_continuation(
        &mut self,
        stream: u32,
        flags: u8,
        payload: &[u8],
        max_body: usize,
    ) -> Result<(), &'static str> {
        let end_headers = flags & END_HEADERS != 0;
        if !self
            .partial_headers
            .as_ref()
            .is_some_and(|(expected, _, _)| *expected == stream)
        {
            return Err("unexpected continuation");
        }
        let block_len = self
            .partial_headers
            .as_ref()
            .map(|(_, block, _)| block.len())
            .unwrap_or(0);
        if block_len.saturating_add(payload.len()) > HEADER_BLOCK_MAX {
            return Err("http2 header block too large");
        }
        if let Some((_, block, _)) = self.partial_headers.as_mut() {
            block.extend_from_slice(payload);
        }
        if end_headers {
            let (_, block, end_stream) = self
                .partial_headers
                .take()
                .ok_or("unexpected continuation")?;
            self.decode_headers(stream, &block, end_stream, max_body)
        } else {
            Ok(())
        }
    }

    fn decode_headers(
        &mut self,
        stream: u32,
        block: &[u8],
        end_stream: bool,
        max_body: usize,
    ) -> Result<(), &'static str> {
        let fields = self
            .decoder
            .decode(block)
            .map_err(|_| "hpack decode failed")?;
        if fields.len() > MAX_HEADER_LIST {
            return Err("http2 header list too large");
        }
        let mut method = Vec::new();
        let mut path = Vec::new();
        let mut authority = Vec::new();
        let mut scheme = Vec::new();
        let mut headers = Vec::new();
        let mut saw_regular = false;
        for (name, value) in fields {
            if value.len() > MAX_FIELD
                || name.iter().any(|b| matches!(b, 0 | b'\r' | b'\n'))
                || value.iter().any(|b| matches!(b, 0 | b'\r' | b'\n'))
            {
                return Err("invalid http2 header");
            }
            if name.starts_with(b":") {
                if saw_regular {
                    return Err("malformed pseudo header");
                }
                match name.as_slice() {
                    b":method" if method.is_empty() => method = value,
                    b":path" if path.is_empty() => path = value,
                    b":authority" if authority.is_empty() => authority = value,
                    b":scheme" if scheme.is_empty() => scheme = value,
                    _ => return Err("duplicate or unsupported pseudo header"),
                }
            } else {
                saw_regular = true;
                if name.is_empty()
                    || name.iter().any(|b| b.is_ascii_uppercase())
                    || matches!(
                        name.as_slice(),
                        b"connection"
                            | b"keep-alive"
                            | b"proxy-connection"
                            | b"te"
                            | b"transfer-encoding"
                            | b"upgrade"
                    )
                {
                    return Err("invalid http2 header");
                }
                headers.push((name, value));
            }
        }
        if method.len() > 15
            || scheme.is_empty()
            || path.is_empty()
            || !path.starts_with(b"/")
            || path.len() > 1023
            || authority.len() > MAX_FIELD
        {
            return Err("malformed http2 request");
        }
        let (path, query) = match path.iter().position(|&b| b == b'?') {
            Some(q) => (path[..q].to_vec(), path[q + 1..].to_vec()),
            None => (path, Vec::new()),
        };
        if query.len() > 1023 {
            return Err("http2 query too large");
        }
        let mut request = H2Request {
            stream_id: stream,
            method,
            path,
            query,
            authority,
            headers,
            body: Vec::new(),
        };
        if let Some(length) = request.content_length()? {
            if length > max_body {
                return Err("http2 body too large");
            }
            request.body.reserve(length);
        }
        if end_stream {
            if let Some(length) = request.content_length()? {
                if length != 0 {
                    return Err("content length mismatch");
                }
            }
            self.queue_request(request)?;
        } else {
            self.partial_request = Some(request);
        }
        Ok(())
    }

    fn queue_request(&mut self, request: H2Request) -> Result<(), &'static str> {
        if self.ready.is_none() {
            self.ready = Some(request);
        } else if self.pending.len() < MAX_PENDING_STREAMS {
            self.pending.push_back(request);
        } else {
            return Err("http2 too many concurrent streams");
        }
        Ok(())
    }
}
