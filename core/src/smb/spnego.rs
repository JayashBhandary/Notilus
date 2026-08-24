//! Just enough GSS-API/SPNEGO to carry NTLM inside an SMB2 session setup.
//!
//! SMB2 doesn't carry NTLM directly: it carries a GSS-API token that names a
//! mechanism and wraps that mechanism's message. Only one mechanism is ever
//! offered here, so instead of a general ASN.1 stack this is a small DER reader
//! that finds the wrapped token, and a builder for the three token shapes the
//! exchange needs.

/// `1.3.6.1.4.1.311.2.2.10` — NTLMSSP.
const OID_NTLMSSP: &[u8] = &[0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a];
/// `1.3.6.1.5.5.2` — SPNEGO itself.
const OID_SPNEGO: &[u8] = &[0x2b, 0x06, 0x01, 0x05, 0x05, 0x02];

const TAG_OID: u8 = 0x06;
const TAG_OCTET_STRING: u8 = 0x04;
const TAG_ENUMERATED: u8 = 0x0A;
const TAG_SEQUENCE: u8 = 0x30;
const TAG_APP_0: u8 = 0x60;
const TAG_CTX_0: u8 = 0xA0;
const TAG_CTX_1: u8 = 0xA1;
const TAG_CTX_2: u8 = 0xA2;

/// The outcome the server reports in a `NegTokenResp`.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum NegState {
    AcceptCompleted = 0,
    AcceptIncomplete = 1,
    Reject = 2,
}

// ── DER reading ────────────────────────────────────────────────────────────

struct Der<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Der<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Der { buf, pos: 0 }
    }

    fn done(&self) -> bool {
        self.pos >= self.buf.len()
    }

    /// The next tag and its contents, or None if the encoding is malformed.
    ///
    /// Only definite-length form is accepted, which is all DER permits and all
    /// any SPNEGO implementation emits.
    fn next(&mut self) -> Option<(u8, &'a [u8])> {
        let tag = *self.buf.get(self.pos)?;
        let first = *self.buf.get(self.pos + 1)?;
        let (length, header) = if first & 0x80 == 0 {
            (first as usize, 2)
        } else {
            let count = (first & 0x7F) as usize;
            // A length longer than a usize is a malformed token, not a big one.
            if count == 0 || count > 4 {
                return None;
            }
            let mut value = 0usize;
            for i in 0..count {
                value = (value << 8) | *self.buf.get(self.pos + 2 + i)? as usize;
            }
            (value, 2 + count)
        };
        let start = self.pos.checked_add(header)?;
        let end = start.checked_add(length)?;
        if end > self.buf.len() {
            return None;
        }
        self.pos = end;
        Some((tag, &self.buf[start..end]))
    }

    /// The contents of the first element with `tag`, at this level only.
    fn find(&mut self, tag: u8) -> Option<&'a [u8]> {
        while !self.done() {
            let (found, body) = self.next()?;
            if found == tag {
                return Some(body);
            }
        }
        None
    }
}

/// Pulls the NTLM message out of whatever wrapper it arrived in.
///
/// Clients differ: some send a full `NegTokenInit`, some a `NegTokenResp`, and
/// some — including Windows once a mechanism is settled — send the raw NTLM
/// message with no wrapper at all. All three are accepted.
pub fn extract_ntlm_token(blob: &[u8]) -> Option<&[u8]> {
    if blob.starts_with(super::ntlm::SIGNATURE) {
        return Some(blob);
    }
    let mut outer = Der::new(blob);
    let (tag, body) = outer.next()?;

    let inner = match tag {
        // NegTokenInit, wrapped in the GSS-API application tag.
        TAG_APP_0 => {
            let mut app = Der::new(body);
            let (oid_tag, oid) = app.next()?;
            if oid_tag != TAG_OID || oid != OID_SPNEGO {
                return None;
            }
            let negotiation = app.find(TAG_CTX_0)?;
            Der::new(negotiation).find(TAG_SEQUENCE)?
        }
        // NegTokenResp — the continuation messages.
        TAG_CTX_1 => Der::new(body).find(TAG_SEQUENCE)?,
        // A bare NegTokenInit sequence; rare but seen.
        TAG_SEQUENCE => body,
        _ => return None,
    };

    // `[2]` is `mechToken` in an init and `responseToken` in a resp; in both it
    // holds an OCTET STRING with the mechanism's own message.
    let token_field = Der::new(inner).find(TAG_CTX_2)?;
    let token = Der::new(token_field).find(TAG_OCTET_STRING)?;
    if token.starts_with(super::ntlm::SIGNATURE) {
        Some(token)
    } else {
        None
    }
}

// ── DER writing ────────────────────────────────────────────────────────────

fn tlv(tag: u8, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() + 6);
    out.push(tag);
    let length = body.len();
    if length < 0x80 {
        out.push(length as u8);
    } else {
        let bytes = length.to_be_bytes();
        let first = bytes.iter().position(|b| *b != 0).unwrap_or(bytes.len() - 1);
        let significant = &bytes[first..];
        out.push(0x80 | significant.len() as u8);
        out.extend_from_slice(significant);
    }
    out.extend_from_slice(body);
    out
}

/// The `NegTokenInit2` a server puts in its NEGOTIATE response, advertising
/// that it speaks NTLM.
pub fn server_mech_list() -> Vec<u8> {
    let mech_types = tlv(TAG_SEQUENCE, &tlv(TAG_OID, OID_NTLMSSP));
    let negotiation = tlv(TAG_SEQUENCE, &tlv(TAG_CTX_0, &mech_types));
    let mut inner = tlv(TAG_OID, OID_SPNEGO);
    inner.extend_from_slice(&tlv(TAG_CTX_0, &negotiation));
    tlv(TAG_APP_0, &inner)
}

/// A `NegTokenInit` carrying the client's first NTLM message.
pub fn client_init(ntlm_negotiate: &[u8]) -> Vec<u8> {
    let mech_types = tlv(TAG_SEQUENCE, &tlv(TAG_OID, OID_NTLMSSP));
    let mut negotiation = tlv(TAG_CTX_0, &mech_types);
    negotiation.extend_from_slice(&tlv(
        TAG_CTX_2,
        &tlv(TAG_OCTET_STRING, ntlm_negotiate),
    ));

    let mut inner = tlv(TAG_OID, OID_SPNEGO);
    inner.extend_from_slice(&tlv(TAG_CTX_0, &tlv(TAG_SEQUENCE, &negotiation)));
    tlv(TAG_APP_0, &inner)
}

/// A `NegTokenResp`, used by the server for its challenge and its final
/// accept, and by the client for its authenticate.
pub fn neg_token_resp(state: NegState, token: Option<&[u8]>, with_mech: bool) -> Vec<u8> {
    let mut body = tlv(TAG_CTX_0, &tlv(TAG_ENUMERATED, &[state as u8]));
    if with_mech {
        body.extend_from_slice(&tlv(TAG_CTX_1, &tlv(TAG_OID, OID_NTLMSSP)));
    }
    if let Some(token) = token {
        body.extend_from_slice(&tlv(TAG_CTX_2, &tlv(TAG_OCTET_STRING, token)));
    }
    tlv(TAG_CTX_1, &tlv(TAG_SEQUENCE, &body))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_client_init_round_trips() {
        let ntlm = super::super::ntlm::build_negotiate("", "BOX");
        let token = client_init(&ntlm);
        assert_eq!(extract_ntlm_token(&token), Some(ntlm.as_slice()));
    }

    #[test]
    fn a_neg_token_resp_round_trips() {
        let ntlm = super::super::ntlm::build_negotiate("", "BOX");
        let token = neg_token_resp(NegState::AcceptIncomplete, Some(&ntlm), true);
        assert_eq!(extract_ntlm_token(&token), Some(ntlm.as_slice()));
    }

    #[test]
    fn a_raw_ntlm_message_needs_no_wrapper() {
        let ntlm = super::super::ntlm::build_negotiate("", "BOX");
        assert_eq!(extract_ntlm_token(&ntlm), Some(ntlm.as_slice()));
    }

    #[test]
    fn long_tokens_use_multi_byte_lengths() {
        // Over 127 bytes forces the long-form length encoding on the way out
        // and exercises it on the way back in.
        let ntlm = super::super::ntlm::build_negotiate(&"d".repeat(200), "BOX");
        assert!(ntlm.len() > 200);
        let token = client_init(&ntlm);
        assert_eq!(extract_ntlm_token(&token), Some(ntlm.as_slice()));
    }

    #[test]
    fn garbage_returns_none_rather_than_panicking() {
        assert!(extract_ntlm_token(&[]).is_none());
        assert!(extract_ntlm_token(&[0x60, 0x82]).is_none());
        assert!(extract_ntlm_token(&[0x60, 0x7F, 0x00]).is_none());
        assert!(extract_ntlm_token(&[0xA1, 0x03, 0x30, 0x01, 0x00]).is_none());
    }

    #[test]
    fn the_server_mech_list_names_ntlm() {
        let list = server_mech_list();
        assert!(list
            .windows(OID_NTLMSSP.len())
            .any(|w| w == OID_NTLMSSP));
    }
}
