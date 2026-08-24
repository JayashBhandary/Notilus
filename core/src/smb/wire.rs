//! Bounds-checked little-endian reading and writing.
//!
//! Every field in SMB2 is little-endian, and every length and offset in a
//! request comes from the network. The crate is built with `panic = "abort"`,
//! so an out-of-range slice would take the whole app down rather than one
//! connection — hence a reader that returns [`Err`] instead of indexing.

use std::fmt;

#[derive(Debug)]
pub enum WireError {
    /// The message ended in the middle of a field.
    Truncated { needed: usize, had: usize },
    /// An offset or length in the message pointed outside it.
    OutOfRange,
    /// A string field wasn't valid UTF-16.
    BadString,
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WireError::Truncated { needed, had } => {
                write!(f, "message ended early (wanted {needed} bytes, had {had})")
            }
            WireError::OutOfRange => write!(f, "a field pointed outside the message"),
            WireError::BadString => write!(f, "a name field wasn't valid UTF-16"),
        }
    }
}

pub type WireResult<T> = Result<T, WireError>;

/// Sequential reader over one message.
pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    pub fn position(&self) -> usize {
        self.pos
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }

    pub fn seek(&mut self, pos: usize) -> WireResult<()> {
        if pos > self.buf.len() {
            return Err(WireError::OutOfRange);
        }
        self.pos = pos;
        Ok(())
    }

    pub fn skip(&mut self, count: usize) -> WireResult<()> {
        self.seek(self.pos.saturating_add(count))
    }

    pub fn take(&mut self, count: usize) -> WireResult<&'a [u8]> {
        let end = self.pos.checked_add(count).ok_or(WireError::OutOfRange)?;
        if end > self.buf.len() {
            return Err(WireError::Truncated {
                needed: count,
                had: self.remaining(),
            });
        }
        let slice = &self.buf[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    /// A slice addressed by an absolute offset and length, as most SMB2
    /// variable-length fields are. Does not move the cursor.
    pub fn slice_at(&self, offset: usize, length: usize) -> WireResult<&'a [u8]> {
        let end = offset.checked_add(length).ok_or(WireError::OutOfRange)?;
        if end > self.buf.len() {
            return Err(WireError::OutOfRange);
        }
        Ok(&self.buf[offset..end])
    }

    pub fn u8(&mut self) -> WireResult<u8> {
        Ok(self.take(1)?[0])
    }

    pub fn u16(&mut self) -> WireResult<u16> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    pub fn u32(&mut self) -> WireResult<u32> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn u64(&mut self) -> WireResult<u64> {
        let b = self.take(8)?;
        Ok(u64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    pub fn array<const N: usize>(&mut self) -> WireResult<[u8; N]> {
        let mut out = [0u8; N];
        out.copy_from_slice(self.take(N)?);
        Ok(out)
    }
}

/// Growable little-endian writer with the patch-later helpers the protocol
/// needs, since SMB2 puts offsets before the data they point at.
#[derive(Default)]
pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Writer { buf: Vec::new() }
    }

    pub fn with_capacity(capacity: usize) -> Self {
        Writer {
            buf: Vec::with_capacity(capacity),
        }
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    pub fn into_vec(self) -> Vec<u8> {
        self.buf
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.buf
    }

    pub fn u8(&mut self, value: u8) -> &mut Self {
        self.buf.push(value);
        self
    }

    pub fn u16(&mut self, value: u16) -> &mut Self {
        self.buf.extend_from_slice(&value.to_le_bytes());
        self
    }

    pub fn u32(&mut self, value: u32) -> &mut Self {
        self.buf.extend_from_slice(&value.to_le_bytes());
        self
    }

    pub fn u64(&mut self, value: u64) -> &mut Self {
        self.buf.extend_from_slice(&value.to_le_bytes());
        self
    }

    pub fn bytes(&mut self, value: &[u8]) -> &mut Self {
        self.buf.extend_from_slice(value);
        self
    }

    pub fn zeros(&mut self, count: usize) -> &mut Self {
        self.buf.resize(self.buf.len() + count, 0);
        self
    }

    /// Pads to the next multiple of `align`, which several SMB2 structures
    /// require of their variable-length sections.
    pub fn align_to(&mut self, align: usize) -> &mut Self {
        if align > 1 {
            let over = self.buf.len() % align;
            if over != 0 {
                self.zeros(align - over);
            }
        }
        self
    }

    pub fn utf16(&mut self, value: &str) -> &mut Self {
        for unit in value.encode_utf16() {
            self.buf.extend_from_slice(&unit.to_le_bytes());
        }
        self
    }

    /// Overwrites two bytes already written — used to fill in a length once
    /// the data it describes has been appended.
    pub fn patch_u16(&mut self, at: usize, value: u16) {
        if at + 2 <= self.buf.len() {
            self.buf[at..at + 2].copy_from_slice(&value.to_le_bytes());
        }
    }

    pub fn patch_u32(&mut self, at: usize, value: u32) {
        if at + 4 <= self.buf.len() {
            self.buf[at..at + 4].copy_from_slice(&value.to_le_bytes());
        }
    }
}

/// UTF-16LE bytes as a string. Unpaired surrogates become U+FFFD rather than
/// failing the request — a file whose name is broken should still be listed.
pub fn utf16le_to_string(bytes: &[u8]) -> WireResult<String> {
    if bytes.len() % 2 != 0 {
        return Err(WireError::BadString);
    }
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    Ok(String::from_utf16_lossy(&units))
}

pub fn string_to_utf16le(value: &str) -> Vec<u8> {
    value
        .encode_utf16()
        .flat_map(|unit| unit.to_le_bytes())
        .collect()
}

/// Length in bytes of `value` once encoded as UTF-16LE.
pub fn utf16_len(value: &str) -> usize {
    value.encode_utf16().count() * 2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reading_past_the_end_errors_instead_of_panicking() {
        let mut r = Reader::new(&[1, 2, 3]);
        assert_eq!(r.u16().unwrap(), 0x0201);
        assert!(r.u32().is_err());
    }

    #[test]
    fn an_offset_field_cannot_escape_the_message() {
        let r = Reader::new(&[0u8; 8]);
        assert!(r.slice_at(4, 4).is_ok());
        assert!(r.slice_at(4, 8).is_err());
        assert!(r.slice_at(usize::MAX, 1).is_err());
    }

    #[test]
    fn patching_fills_in_a_length_written_before_its_data() {
        let mut w = Writer::new();
        w.u16(0);
        let at = 0;
        w.bytes(b"abcd");
        w.patch_u16(at, 4);
        assert_eq!(w.as_slice(), &[4, 0, b'a', b'b', b'c', b'd']);
    }

    #[test]
    fn utf16_round_trips_including_astral_characters() {
        let text = "über 🚀";
        let encoded = string_to_utf16le(text);
        assert_eq!(encoded.len(), utf16_len(text));
        assert_eq!(utf16le_to_string(&encoded).unwrap(), text);
    }

    #[test]
    fn alignment_pads_to_the_requested_boundary() {
        let mut w = Writer::new();
        w.bytes(b"abc").align_to(8);
        assert_eq!(w.len(), 8);
    }
}
