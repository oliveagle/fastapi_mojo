// deflate.rs — zero-dependency RFC 7692 client codec.
//
// fmtool intentionally implements only what the e2e client needs:
//   * outgoing messages use independent raw DEFLATE stored blocks;
//   * incoming messages use a complete RFC 1951 inflater (stored, fixed,
//     and dynamic Huffman) with a persistent 32 KiB LZ77 window.
// The implementation is std-only, keeping Track B free of third-party crates.

const WINDOW_SIZE: usize = 32 * 1024;
pub(crate) const MAX_MESSAGE: usize = 1024 * 1024;
const MAX_BITS: usize = 15;
const EMPTY_TAIL: [u8; 4] = [0x00, 0x00, 0xff, 0xff];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InflateError {
    Data,
    TooLarge,
}

pub struct Inflater {
    window: Vec<u8>,
    final_ended: bool,
}

impl Default for Inflater {
    fn default() -> Self {
        Self::new()
    }
}

impl Inflater {
    pub fn new() -> Self {
        Self {
            window: Vec::with_capacity(WINDOW_SIZE),
            final_ended: false,
        }
    }

    /// Decode one RFC 7692 message. The appended empty stored block replaces
    /// the four octets removed by the sender; the persistent window models
    /// server context takeover across messages.
    pub fn decompress_message(&mut self, compressed: &[u8]) -> Result<Vec<u8>, InflateError> {
        if compressed.len() > MAX_MESSAGE {
            return Err(InflateError::TooLarge);
        }
        if self.final_ended {
            self.window.clear();
            self.final_ended = false;
        }
        let mut input = Vec::with_capacity(compressed.len() + EMPTY_TAIL.len());
        input.extend_from_slice(compressed);
        input.extend_from_slice(&EMPTY_TAIL);

        let mut br = BitReader::new(&input);
        let mut out = Vec::new();
        while !br.is_empty() {
            let final_block = br.bit().ok_or(InflateError::Data)?;
            let kind = br.bits(2).ok_or(InflateError::Data)?;
            match kind {
                0 => {
                    br.align();
                    let len = br.usize_le16().ok_or(InflateError::Data)?;
                    let nlen = br.usize_le16().ok_or(InflateError::Data)?;
                    if len != (!nlen & 0xffff) {
                        return Err(InflateError::Data);
                    }
                    for _ in 0..len {
                        let b = br.byte().ok_or(InflateError::Data)?;
                        self.push_byte(&mut out, b)?;
                    }
                }
                1 => {
                    let lit = fixed_literal_table();
                    let dist = fixed_distance_table();
                    self.inflate_block(&mut br, &lit, &dist, &mut out)?;
                }
                2 => {
                    let (lit, dist) = read_dynamic_tables(&mut br)?;
                    self.inflate_block(&mut br, &lit, &dist, &mut out)?;
                }
                _ => return Err(InflateError::Data),
            }
            if final_block != 0 {
                self.final_ended = true;
                break;
            }
        }
        Ok(out)
    }

    fn inflate_block(
        &mut self,
        br: &mut BitReader<'_>,
        lit: &Huffman,
        dist: &Option<Huffman>,
        out: &mut Vec<u8>,
    ) -> Result<(), InflateError> {
        loop {
            let symbol = br.decode(lit).ok_or(InflateError::Data)?;
            match symbol {
                0..=255 => self.push_byte(out, symbol as u8)?,
                256 => return Ok(()),
                257..=285 => {
                    let len = decode_length(br, symbol).ok_or(InflateError::Data)?;
                    let table = dist.as_ref().ok_or(InflateError::Data)?;
                    let dsym = br.decode(table).ok_or(InflateError::Data)?;
                    if dsym > 29 {
                        return Err(InflateError::Data);
                    }
                    let distance = decode_distance(br, dsym).ok_or(InflateError::Data)?;
                    if distance == 0 || distance > self.window.len() {
                        return Err(InflateError::Data);
                    }
                    if out.len() + len as usize > MAX_MESSAGE {
                        return Err(InflateError::TooLarge);
                    }
                    for _ in 0..len {
                        let b = self.window[self.window.len() - distance];
                        self.push_byte(out, b)?;
                    }
                }
                _ => return Err(InflateError::Data),
            }
            if out.len() > MAX_MESSAGE {
                return Err(InflateError::TooLarge);
            }
        }
    }

    fn push_byte(&mut self, out: &mut Vec<u8>, b: u8) -> Result<(), InflateError> {
        if out.len() >= MAX_MESSAGE {
            return Err(InflateError::TooLarge);
        }
        out.push(b);
        self.window.push(b);
        if self.window.len() > WINDOW_SIZE {
            self.window.drain(..self.window.len() - WINDOW_SIZE);
        }
        Ok(())
    }
}

/// Encode an outgoing RFC 7692 message as independent non-final stored blocks,
/// append the sync-flush tail, then remove it exactly as RFC 7692 specifies.
pub fn compress_stored_message(data: &[u8]) -> Vec<u8> {
    if data.len() > MAX_MESSAGE {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(data.len() + data.len().div_ceil(u16::MAX as usize) * 5);
    for chunk in data.chunks(u16::MAX as usize) {
        let len = chunk.len() as u16;
        let nlen = !len;
        out.push(0);
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&nlen.to_le_bytes());
        out.extend_from_slice(chunk);
    }
    // Keep the next empty stored block header; decompression supplies its
    // LEN/NLEN octets by appending the RFC 7692 four-byte tail.
    out.extend_from_slice(&[0x00, 0x00, 0x00, 0xff, 0xff]);
    out.truncate(out.len() - EMPTY_TAIL.len());
    out
}

struct BitReader<'a> {
    data: &'a [u8],
    byte: usize,
    bit: u32,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, byte: 0, bit: 0 }
    }

    fn is_empty(&self) -> bool {
        self.byte >= self.data.len()
    }

    fn bit(&mut self) -> Option<u16> {
        let b = *self.data.get(self.byte)?;
        let v = (b >> self.bit) & 1;
        self.bit += 1;
        if self.bit == 8 {
            self.bit = 0;
            self.byte += 1;
        }
        Some(v as u16)
    }

    fn bits(&mut self, n: u32) -> Option<u16> {
        let mut v = 0u16;
        for i in 0..n {
            v |= self.bit()? << i;
        }
        Some(v)
    }

    fn byte(&mut self) -> Option<u8> {
        if self.bit != 0 {
            self.bit = 0;
            self.byte += 1;
        }
        let v = *self.data.get(self.byte)?;
        self.byte += 1;
        Some(v)
    }

    fn align(&mut self) {
        if self.bit != 0 {
            self.bit = 0;
            self.byte += 1;
        }
    }

    fn usize_le16(&mut self) -> Option<usize> {
        let lo = self.byte()?;
        let hi = self.byte()?;
        Some(lo as usize | ((hi as usize) << 8))
    }

    fn decode(&mut self, table: &Huffman) -> Option<u16> {
        let mut code = 0usize;
        let mut first = 0usize;
        let mut index = 0usize;
        for len in 1..=MAX_BITS {
            code = (code << 1) | self.bit()? as usize;
            let count = table.counts[len] as usize;
            if code - first < count {
                return table.symbols.get(index + code - first).copied();
            }
            index += count;
            first = (first + count) << 1;
        }
        None
    }
}

struct Huffman {
    counts: [u16; MAX_BITS + 1],
    symbols: Vec<u16>,
}

fn new_huffman(lengths: &[u8]) -> Option<Huffman> {
    let mut counts = [0u16; MAX_BITS + 1];
    for &len in lengths {
        if len as usize > MAX_BITS {
            return None;
        }
        counts[len as usize] += 1;
    }
    counts[0] = 0;
    let mut offsets = [0usize; MAX_BITS + 1];
    for len in 1..MAX_BITS {
        offsets[len + 1] = offsets[len] + counts[len] as usize;
    }
    let mut symbols = vec![0u16; lengths.iter().filter(|&&x| x != 0).count()];
    for (symbol, &len) in lengths.iter().enumerate() {
        if len != 0 {
            symbols[offsets[len as usize]] = symbol as u16;
            offsets[len as usize] += 1;
        }
    }
    Some(Huffman { counts, symbols })
}

fn fixed_literal_table() -> Huffman {
    let mut lengths = [0u8; 288];
    for (symbol, len) in lengths.iter_mut().enumerate() {
        *len = if symbol < 144 {
            8
        } else if symbol < 256 {
            9
        } else if symbol < 280 {
            7
        } else {
            8
        };
    }
    new_huffman(&lengths).expect("fixed literal lengths are valid")
}

fn fixed_distance_table() -> Option<Huffman> {
    let lengths = [5u8; 30];
    new_huffman(&lengths)
}

fn read_dynamic_tables(br: &mut BitReader<'_>) -> Result<(Huffman, Option<Huffman>), InflateError> {
    let hlit = br.bits(5).ok_or(InflateError::Data)? as usize + 257;
    let hdist = br.bits(5).ok_or(InflateError::Data)? as usize + 1;
    let hclen = br.bits(4).ok_or(InflateError::Data)? as usize + 4;
    if hlit > 286 || hdist > 30 {
        return Err(InflateError::Data);
    }

    const ORDER: [usize; 19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    let mut code_lengths = [0u8; 19];
    for &sym in ORDER.iter().take(hclen) {
        code_lengths[sym] = br.bits(3).ok_or(InflateError::Data)? as u8;
    }
    let header = new_huffman(&code_lengths).ok_or(InflateError::Data)?;

    let count = hlit + hdist;
    let mut lengths = Vec::with_capacity(count);
    while lengths.len() < count {
        let sym = br.decode(&header).ok_or(InflateError::Data)?;
        match sym {
            0..=15 => lengths.push(sym as u8),
            16 => {
                let repeat = 3 + br.bits(2).ok_or(InflateError::Data)? as usize;
                let last = lengths.last().copied().ok_or(InflateError::Data)?;
                lengths.extend(std::iter::repeat_n(last, repeat));
            }
            17 => {
                let repeat = 3 + br.bits(3).ok_or(InflateError::Data)? as usize;
                lengths.extend(std::iter::repeat_n(0, repeat));
            }
            18 => {
                let repeat = 11 + br.bits(7).ok_or(InflateError::Data)? as usize;
                lengths.extend(std::iter::repeat_n(0, repeat));
            }
            _ => return Err(InflateError::Data),
        }
    }
    if lengths.len() != count {
        return Err(InflateError::Data);
    }
    let lit = new_huffman(&lengths[..hlit]).ok_or(InflateError::Data)?;
    let dist = if lengths[hlit..].iter().any(|&x| x != 0) {
        new_huffman(&lengths[hlit..])
    } else {
        None
    };
    Ok((lit, dist))
}

const LENGTH_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258,
];
const LENGTH_EXTRA: [u32; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [u32; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];

fn decode_length(br: &mut BitReader<'_>, symbol: u16) -> Option<u16> {
    let idx = (symbol - 257) as usize;
    let extra = br.bits(LENGTH_EXTRA[idx])? as usize;
    Some(LENGTH_BASE[idx] + extra as u16)
}

fn decode_distance(br: &mut BitReader<'_>, symbol: u16) -> Option<usize> {
    let extra = br.bits(DIST_EXTRA[symbol as usize])? as usize;
    Some(DIST_BASE[symbol as usize] as usize + extra)
}
