//! HTTP/2 frame constants and byte encoders shared by the transport/response layers.

pub const FRAME_HEADER: usize = 9;
pub const DATA: u8 = 0;
pub const HEADERS: u8 = 1;
pub const PRIORITY: u8 = 2;
pub const RST_STREAM: u8 = 3;
pub const SETTINGS: u8 = 4;
pub const PUSH_PROMISE: u8 = 5;
pub const PING: u8 = 6;
pub const GOAWAY: u8 = 7;
pub const WINDOW_UPDATE: u8 = 8;
pub const CONTINUATION: u8 = 9;

pub const END_STREAM: u8 = 0x1;
pub const END_HEADERS: u8 = 0x4;
pub const PADDED: u8 = 0x8;
pub const PRIORITY_FLAG: u8 = 0x20;
pub const ACK: u8 = 0x1;

pub fn frame(ty: u8, flags: u8, stream: u32, payload: &[u8]) -> Vec<u8> {
    let len = payload.len();
    let mut out = Vec::with_capacity(FRAME_HEADER + len);
    out.extend_from_slice(&[(len >> 16) as u8, (len >> 8) as u8, len as u8, ty, flags]);
    out.extend_from_slice(&stream.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

pub fn settings_frame(settings: &[(u16, u32)]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(settings.len() * 6);
    for (id, value) in settings {
        payload.extend_from_slice(&id.to_be_bytes());
        payload.extend_from_slice(&value.to_be_bytes());
    }
    frame(SETTINGS, 0, 0, &payload)
}

pub fn window_update(stream: u32, increment: u32) -> Vec<u8> {
    frame(WINDOW_UPDATE, 0, stream, &increment.to_be_bytes())
}

pub fn remove_padding(flags: u8, payload: &[u8]) -> Result<&[u8], &'static str> {
    if flags & PADDED == 0 {
        return Ok(payload);
    }
    let pad = usize::from(*payload.first().ok_or("malformed padding")?);
    if payload.len() < pad + 1 {
        return Err("malformed padding");
    }
    Ok(&payload[1..payload.len() - pad])
}
