# src/fastapi_mojo/string_builder.mojo
#
# Linear-time String construction from raw bytes.
#
# Mojo String concatenation (`s += x`) copies the whole string each time, so
# building a string byte-by-byte with `+=` is O(n^2) — a 1MB body takes
# minutes. This module provides:
#
#   * StringBuilder — chunked builder (256-byte chunks + one final join),
#     amortized O(n).
#   * decode_utf8_bytes — robust UTF-8 decoder over raw bytes (invalid
#     sequences become U+FFFD; never calls chr() with a surrogate, which
#     would abort the process).

from std.ffi import CStringSlice


struct StringBuilder:
    """Efficient String builder: appends into small chunks, joins once."""
    var chunks: List[String]
    var chunk_size: Int
    var cur: String

    def __init__(out self, chunk_size: Int = 256):
        self.chunks = List[String]()
        self.chunk_size = chunk_size
        self.cur = String("")

    def _flush(mut self):
        if self.cur.byte_length() > 0:
            self.chunks.append(self.cur)
            self.cur = String("")

    def append(mut self, s: String):
        """Append a string (any size)."""
        if s.byte_length() >= self.chunk_size:
            self._flush()
            self.chunks.append(s)
            return
        if self.cur.byte_length() + s.byte_length() > self.chunk_size:
            self._flush()
        self.cur += s

    def append_codepoint(mut self, cp: Int):
        """Append one Unicode codepoint (surrogates/out-of-range -> U+FFFD)."""
        var v = cp
        if (v >= 0xD800 and v <= 0xDFFF) or v > 0x10FFFF or v < 0:
            v = 0xFFFD
        if self.cur.byte_length() >= self.chunk_size:
            self._flush()
        self.cur += chr(v)

    def append_byte(mut self, b: Int):
        """Append one ASCII byte (0-127); non-ASCII becomes U+FFFD."""
        var v = b
        if v < 0:
            v = 0
        if v >= 0x80:
            self.append_codepoint(0xFFFD)
            return
        if self.cur.byte_length() >= self.chunk_size:
            self._flush()
        self.cur += chr(v)

    def take(mut self) -> String:
        """Finalize and return the built string (single linear join)."""
        self._flush()
        return "".join(self.chunks)


def trim_spaces(s: String) -> String:
    """Trim ASCII space (0x20) from both ends.

    决策-83/ADR-0058: 全字节安全 — Mojo 1.0.0 `s[byte=i]` 在码点内部下标会
    assert; 原始 wire 数据 (如 WS 子协议 offer "café") 的尾字节是续字节.
    """
    var a = 0
    var b = s.byte_length()
    var ab = s.as_bytes()
    while a < b and Int(ab[a]) == 32:
        a += 1
    while b > a and Int(ab[b - 1]) == 32:
        b -= 1
    return String(s[byte=a:b])


def next_codepoint_len(s: String, i: Int) -> Int:
    """UTF-8 byte length of the codepoint starting at byte index i.

    Byte-safe (决策-83/ADR-0058): classification uses the raw lead byte from
    `as_bytes()`, never `s[byte=i]` (which asserts mid-codepoint). Off-boundary
    continuation bytes (0x80..0xBF) yield 1 so byte-wise callers advance past
    them instead of aborting."""
    var b = Int(s.as_bytes()[i])
    if b < 0x80:
        return 1
    if b < 0xC0:
        return 1
    if b < 0xE0:
        return 2
    if b < 0xF0:
        return 3
    return 4


def _is_cont(bs: List[Int], i: Int, n: Int) -> Bool:
    return i < n and ((bs[i] & 0xC0) == 0x80)


def decode_utf8_bytes(bs: List[Int]) -> String:
    """Decode raw bytes as UTF-8 into a String.

    Malformed sequences (bad lead, truncated run, overlong, surrogate,
    out of range) yield U+FFFD instead of crashing.
    """
    var sb = StringBuilder()
    var n = len(bs)
    var i = 0
    while i < n:
        var b = bs[i]
        if b < 0x80:
            sb.append_byte(b)
            i += 1
        elif (b & 0xE0) == 0xC0:
            if not _is_cont(bs, i + 1, n):
                sb.append_codepoint(0xFFFD)
                i += 1
                continue
            var cp2 = ((b & 0x1F) << 6) | (bs[i + 1] & 0x3F)
            if cp2 < 0x80:  # overlong
                sb.append_codepoint(0xFFFD)
            else:
                sb.append_codepoint(cp2)
            i += 2
        elif (b & 0xF0) == 0xE0:
            if not _is_cont(bs, i + 1, n) or not _is_cont(bs, i + 2, n):
                sb.append_codepoint(0xFFFD)
                i += 1
                continue
            var cp3 = ((b & 0x0F) << 12) | ((bs[i + 1] & 0x3F) << 6) | (bs[i + 2] & 0x3F)
            if cp3 < 0x800 or (cp3 >= 0xD800 and cp3 <= 0xDFFF):  # overlong / surrogate
                sb.append_codepoint(0xFFFD)
            else:
                sb.append_codepoint(cp3)
            i += 3
        elif (b & 0xF8) == 0xF0:
            if not _is_cont(bs, i + 1, n) or not _is_cont(bs, i + 2, n) or not _is_cont(bs, i + 3, n):
                sb.append_codepoint(0xFFFD)
                i += 1
                continue
            var cp4 = ((b & 0x07) << 18) | ((bs[i + 1] & 0x3F) << 12) | ((bs[i + 2] & 0x3F) << 6) | (bs[i + 3] & 0x3F)
            if cp4 < 0x10000 or b > 0xF4:  # overlong / > U+10FFFF
                sb.append_codepoint(0xFFFD)
            else:
                sb.append_codepoint(cp4)
            i += 4
        else:
            # stray continuation byte or invalid lead
            sb.append_codepoint(0xFFFD)
            i += 1
    return sb.take()




def main() raises:
    print("Testing Mojo string builder...")

    # Basic building
    var sb = StringBuilder()
    sb.append("Hello, ")
    sb.append("World!")
    if sb.take() == "Hello, World!":
        print("OK: append + take")

    # UTF-8 decode: "héllo" bytes = 68 C3 A9 6C 6C 6F
    var b1 = List[Int]()
    for b in [0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F]:
        b1.append(b)
    var s1 = decode_utf8_bytes(b1)
    if s1 == "héllo" and s1.byte_length() == 6:
        print("OK: utf8 decode 2-byte")

    # 4-byte: U+1F600 = F0 9F 98 80
    var b2 = List[Int]()
    for b in [0xF0, 0x9F, 0x98, 0x80]:
        b2.append(b)
    var s2 = decode_utf8_bytes(b2)
    if s2 == "😀" and s2.byte_length() == 4:
        print("OK: utf8 decode 4-byte")

    # invalid sequence -> U+FFFD
    var b3 = List[Int]()
    for b in [0x61, 0xFF, 0x62]:
        b3.append(b)
    var s3 = decode_utf8_bytes(b3)
    if s3 == "a\uFFFD" + "b" and s3.byte_length() == 5:
        print("OK: invalid byte -> U+FFFD")

    # "héllo 😀" as raw bytes: 68 C3 A9 6C 6C 6F 20 F0 9F 98 80
    var b4 = List[Int]()
    for b in [0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F, 0x20, 0xF0, 0x9F, 0x98, 0x80]:
        b4.append(b)
    if decode_utf8_bytes(b4) == "héllo 😀":
        print("OK: mixed 2/4-byte decode")

    # performance: 1MB of text must build in well under a second
    var big = StringBuilder()
    for _ in range(256 * 1024):
        big.append_byte(0x61)  # 'a'
    var s4 = big.take()
    if s4.byte_length() == 262144:
        print("OK: 256KB built linearly")

    # Decision-66 fast path: ASCII spans bulk-construct, UTF-8 spans decode.
    var span_ascii = "bridge payload"
    if span_to_str(span_ascii.as_c_string_slice().as_bytes()) == span_ascii:
        print("OK: span ASCII fast path")

    var span_utf8 = "héllo 😀"
    if span_to_str(span_utf8.as_c_string_slice().as_bytes()) == span_utf8:
        print("OK: span UTF-8 decoder")

    print("StringBuilder test completed!")

# Bulk decode of a raw byte span (e.g. a CStringSlice.as_bytes() from the
# C bridge) into a UTF-8 String, in amortized O(n). The C side has already
# validated the UTF-8; isolated/invalid sequences still degrade to U+FFFD.
def span_to_str(bs: Span[UInt8, _, address_space=AddressSpace.GENERIC]) -> String:
    # ASCII spans (the dominant bridge payload: HTTP fields and escaped JSON)
    # have a direct String construction path. It avoids a byte-by-byte
    # StringBuilder loop while preserving the robust decoder below for UTF-8.
    var n = len(bs)
    var all_ascii = True
    var probe = 0
    while probe < n:
        if Int(bs[probe]) >= 0x80:
            all_ascii = False
            break
        probe += 1
    if all_ascii:
        return String(unsafe_from_utf8=bs)

    # Robust UTF-8 decode (决策-84/ADR-0059): mirror decode_utf8_bytes with
    # full bounds + continuation checks. The C bridge NUL-terminates its slices
    # (决策-36), but a lone invalid lead byte (0xFF / truncated run) previously
    # read past the span end -> Assert Error -> server crash. Invalid sequences
    # degrade to U+FFFD instead.
    var sb = StringBuilder()
    var i = 0
    while i < n:
        var b = Int(bs[i])
        if b < 0x80:
            sb.append_byte(b)
            i += 1
        elif b < 0xC0:
            sb.append_codepoint(0xFFFD)   # stray continuation byte
            i += 1
        elif b < 0xE0:
            if i + 1 >= n or (Int(bs[i + 1]) & 0xC0) != 0x80:
                sb.append_codepoint(0xFFFD)
                i += 1
                continue
            var cp2 = ((b & 0x1F) << 6) | (Int(bs[i + 1]) & 0x3F)
            sb.append_codepoint(0xFFFD if cp2 < 0x80 else cp2)  # overlong
            i += 2
        elif b < 0xF0:
            if i + 2 >= n or (Int(bs[i + 1]) & 0xC0) != 0x80 or (Int(bs[i + 2]) & 0xC0) != 0x80:
                sb.append_codepoint(0xFFFD)
                i += 1
                continue
            var cp3 = ((b & 0x0F) << 12) | ((Int(bs[i + 1]) & 0x3F) << 6) | (Int(bs[i + 2]) & 0x3F)
            sb.append_codepoint(0xFFFD if (cp3 < 0x800 or (cp3 >= 0xD800 and cp3 <= 0xDFFF)) else cp3)
            i += 3
        elif b < 0xF5:
            if i + 3 >= n or (Int(bs[i + 1]) & 0xC0) != 0x80 or (Int(bs[i + 2]) & 0xC0) != 0x80 or (Int(bs[i + 3]) & 0xC0) != 0x80:
                sb.append_codepoint(0xFFFD)
                i += 1
                continue
            var cp4 = ((b & 0x07) << 18) | ((Int(bs[i + 1]) & 0x3F) << 12) | ((Int(bs[i + 2]) & 0x3F) << 6) | (Int(bs[i + 3]) & 0x3F)
            sb.append_codepoint(0xFFFD if cp4 < 0x10000 else cp4)  # overlong
            i += 4
        else:
            sb.append_codepoint(0xFFFD)   # invalid lead (0xF5..0xFF)
            i += 1
    return sb.take()
