//! HTTP/2 request model shared by framing, I/O adapters, and header lookup.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct H2Request {
    pub stream_id: u32,
    pub method: Vec<u8>,
    pub path: Vec<u8>,
    pub query: Vec<u8>,
    pub authority: Vec<u8>,
    pub headers: Vec<(Vec<u8>, Vec<u8>)>,
    pub body: Vec<u8>,
}

impl H2Request {
    /// Case-insensitive lookup used by the bridge request-global adapters.
    /// `host` is backed by the `:authority` pseudo-header on HTTP/2.
    pub fn header_value(&self, name: &[u8]) -> Option<&[u8]> {
        if name.eq_ignore_ascii_case(b"host") {
            return Some(self.authority.as_slice());
        }
        self.headers
            .iter()
            .find(|(field, _)| field.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_slice())
    }

    pub fn is_multipart_form_data(&self) -> bool {
        self.header_value(b"content-type").is_some_and(|value| {
            let lower = value.to_ascii_lowercase();
            lower.starts_with(b"multipart/form-data")
        })
    }
}

impl H2Request {
    pub(crate) fn content_length(&self) -> Result<Option<usize>, &'static str> {
        let Some(value) = self.header_value(b"content-length") else {
            return Ok(None);
        };
        if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
            return Err("invalid content length");
        }
        let text = std::str::from_utf8(value).map_err(|_| "invalid content length")?;
        text.parse::<usize>()
            .map(Some)
            .map_err(|_| "invalid content length")
    }
}
