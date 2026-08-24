//! NTLMv2, the authentication SMB2 uses when there is no Kerberos realm.
//!
//! Three messages: the client's NEGOTIATE, the server's CHALLENGE carrying
//! eight random bytes, and the client's AUTHENTICATE proving it knows the
//! password without sending it. Only NTLMv2 is implemented — LM and NTLMv1
//! responses are rejected rather than accepted for compatibility, because
//! accepting them would let an attacker choose the weaker of the two.

use super::crypto::{hmac_md5, md4, random_array, rc4};
use super::wire::{string_to_utf16le, utf16le_to_string, Reader, Writer};

pub const SIGNATURE: &[u8; 8] = b"NTLMSSP\0";

pub mod flag {
    pub const UNICODE: u32 = 0x0000_0001;
    pub const OEM: u32 = 0x0000_0002;
    pub const REQUEST_TARGET: u32 = 0x0000_0004;
    pub const SIGN: u32 = 0x0000_0010;
    pub const SEAL: u32 = 0x0000_0020;
    pub const NTLM: u32 = 0x0000_0200;
    pub const ANONYMOUS: u32 = 0x0000_0800;
    pub const DOMAIN_SUPPLIED: u32 = 0x0000_1000;
    pub const WORKSTATION_SUPPLIED: u32 = 0x0000_2000;
    pub const ALWAYS_SIGN: u32 = 0x0000_8000;
    pub const TARGET_TYPE_DOMAIN: u32 = 0x0001_0000;
    pub const TARGET_TYPE_SERVER: u32 = 0x0002_0000;
    pub const EXTENDED_SESSION_SECURITY: u32 = 0x0008_0000;
    pub const TARGET_INFO: u32 = 0x0080_0000;
    pub const VERSION: u32 = 0x0200_0000;
    pub const KEY_128: u32 = 0x2000_0000;
    pub const KEY_EXCH: u32 = 0x4000_0000;
    pub const KEY_56: u32 = 0x8000_0000;
}

/// AV-pair ids inside the CHALLENGE's target info.
mod av {
    pub const EOL: u16 = 0x0000;
    pub const NB_COMPUTER_NAME: u16 = 0x0001;
    pub const NB_DOMAIN_NAME: u16 = 0x0002;
    pub const DNS_COMPUTER_NAME: u16 = 0x0003;
    pub const DNS_DOMAIN_NAME: u16 = 0x0004;
    pub const TIMESTAMP: u16 = 0x0007;
}

/// The flags the server offers. Signing is always on: an SMB2 session that
/// can't sign can be hijacked mid-transfer.
const SERVER_FLAGS: u32 = flag::UNICODE
    | flag::REQUEST_TARGET
    | flag::SIGN
    | flag::NTLM
    | flag::ALWAYS_SIGN
    | flag::TARGET_TYPE_SERVER
    | flag::EXTENDED_SESSION_SECURITY
    | flag::TARGET_INFO
    | flag::VERSION
    | flag::KEY_128
    | flag::KEY_EXCH
    | flag::KEY_56;

#[derive(Debug)]
pub enum NtlmError {
    /// Not an NTLMSSP message, or one whose fields point outside it.
    Malformed(&'static str),
    /// The credentials didn't verify.
    BadCredentials,
    /// A form of NTLM this server won't accept.
    Unsupported(&'static str),
}

impl std::fmt::Display for NtlmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NtlmError::Malformed(what) => write!(f, "malformed NTLM message: {what}"),
            NtlmError::BadCredentials => write!(f, "wrong user name or password"),
            NtlmError::Unsupported(what) => write!(f, "unsupported NTLM: {what}"),
        }
    }
}

pub fn message_type(message: &[u8]) -> Option<u32> {
    if message.len() < 12 || &message[..8] != SIGNATURE {
        return None;
    }
    Some(u32::from_le_bytes([
        message[8],
        message[9],
        message[10],
        message[11],
    ]))
}

// ── NTLM key material ──────────────────────────────────────────────────────

/// The NT hash: MD4 of the UTF-16LE password. Weak by modern standards, but it
/// is what the protocol specifies, and it is never sent over the wire.
pub fn nt_hash(password: &str) -> [u8; 16] {
    md4(&string_to_utf16le(password))
}

/// `NTOWFv2` — the per-identity key everything else derives from.
///
/// The user name is upper-cased and the domain is not, exactly as the spec
/// says; getting that wrong produces an authentication failure that looks like
/// a wrong password.
pub fn ntowf_v2(nt_hash: &[u8; 16], user: &str, domain: &str) -> [u8; 16] {
    let identity = format!("{}{}", user.to_uppercase(), domain);
    hmac_md5(nt_hash, &string_to_utf16le(&identity))
}

// ── CHALLENGE (server → client) ────────────────────────────────────────────

pub struct Challenge {
    pub server_challenge: [u8; 8],
    pub message: Vec<u8>,
}

/// Builds the CHALLENGE message naming this server.
pub fn build_challenge(
    netbios_name: &str,
    dns_name: &str,
    domain: &str,
    timestamp: u64,
) -> Result<Challenge, String> {
    let server_challenge: [u8; 8] = random_array()?;

    let mut target_info = Writer::new();
    let av_pair = |id: u16, value: &[u8], w: &mut Writer| {
        w.u16(id).u16(value.len() as u16).bytes(value);
    };
    av_pair(
        av::NB_DOMAIN_NAME,
        &string_to_utf16le(domain),
        &mut target_info,
    );
    av_pair(
        av::NB_COMPUTER_NAME,
        &string_to_utf16le(netbios_name),
        &mut target_info,
    );
    av_pair(
        av::DNS_DOMAIN_NAME,
        &string_to_utf16le(domain),
        &mut target_info,
    );
    av_pair(
        av::DNS_COMPUTER_NAME,
        &string_to_utf16le(dns_name),
        &mut target_info,
    );
    av_pair(av::TIMESTAMP, &timestamp.to_le_bytes(), &mut target_info);
    target_info.u16(av::EOL).u16(0);
    let target_info = target_info.into_vec();

    // TARGET_TYPE_SERVER says this name is the server's, not a domain's.
    let target_name = string_to_utf16le(netbios_name);
    // Payload follows the fixed 56-byte part.
    let target_name_offset = 56u32;
    let target_info_offset = target_name_offset + target_name.len() as u32;

    let mut w = Writer::with_capacity(56 + target_name.len() + target_info.len());
    w.bytes(SIGNATURE)
        .u32(2)
        .u16(target_name.len() as u16)
        .u16(target_name.len() as u16)
        .u32(target_name_offset)
        .u32(SERVER_FLAGS)
        .bytes(&server_challenge)
        .zeros(8) // Reserved
        .u16(target_info.len() as u16)
        .u16(target_info.len() as u16)
        .u32(target_info_offset)
        // Version: Windows 6.1 build 7601, NTLM revision 15. Some clients
        // refuse a zeroed version block.
        .u8(6)
        .u8(1)
        .u16(7601)
        .zeros(3)
        .u8(15)
        .bytes(&target_name)
        .bytes(&target_info);

    Ok(Challenge {
        server_challenge,
        message: w.into_vec(),
    })
}

// ── AUTHENTICATE (client → server) ─────────────────────────────────────────

/// The parts of an AUTHENTICATE message the server acts on.
pub struct Authenticate {
    pub domain: String,
    pub user: String,
    pub workstation: String,
    pub lm_response: Vec<u8>,
    pub nt_response: Vec<u8>,
    pub encrypted_session_key: Vec<u8>,
    pub flags: u32,
    pub mic: Option<[u8; 16]>,
    /// Offset of the MIC field, so it can be zeroed when the MIC is checked.
    mic_offset: Option<usize>,
}

impl Authenticate {
    /// True when the client asked for an anonymous session — no user, no proof.
    pub fn is_anonymous(&self) -> bool {
        self.flags & flag::ANONYMOUS != 0
            || (self.user.is_empty() && self.nt_response.len() < 24)
    }
}

pub fn parse_authenticate(message: &[u8]) -> Result<Authenticate, NtlmError> {
    if message_type(message) != Some(3) {
        return Err(NtlmError::Malformed("not an AUTHENTICATE message"));
    }
    /// One `(Len, MaxLen, BufferOffset)` triple, the shape every
    /// variable-length NTLM field uses.
    fn field(cursor: &mut Reader<'_>) -> Result<(usize, usize), NtlmError> {
        let len = cursor
            .u16()
            .map_err(|_| NtlmError::Malformed("truncated field"))? as usize;
        let _max = cursor
            .u16()
            .map_err(|_| NtlmError::Malformed("truncated field"))?;
        let offset = cursor
            .u32()
            .map_err(|_| NtlmError::Malformed("truncated field"))? as usize;
        Ok((offset, len))
    }

    let reader = Reader::new(message);
    let mut cursor = Reader::new(message);
    cursor
        .skip(12)
        .map_err(|_| NtlmError::Malformed("truncated header"))?;

    let lm = field(&mut cursor)?;
    let nt = field(&mut cursor)?;
    let domain = field(&mut cursor)?;
    let user = field(&mut cursor)?;
    let workstation = field(&mut cursor)?;
    let session_key = field(&mut cursor)?;
    let flags = cursor
        .u32()
        .map_err(|_| NtlmError::Malformed("truncated flags"))?;

    let payload_start = [lm, nt, domain, user, workstation, session_key]
        .iter()
        .filter(|(_, len)| *len > 0)
        .map(|(offset, _)| *offset)
        .min()
        .unwrap_or(message.len());

    // The MIC sits after the 8-byte version block, at offset 72. It is present
    // only when the payload starts at 88 or later, which is how the spec says
    // to detect it without a flag.
    let (mic, mic_offset) = if payload_start >= 88 && message.len() >= 88 {
        let mut value = [0u8; 16];
        value.copy_from_slice(&message[72..88]);
        (Some(value), Some(72))
    } else {
        (None, None)
    };

    let slice = |(offset, len): (usize, usize)| -> Result<Vec<u8>, NtlmError> {
        if len == 0 {
            return Ok(Vec::new());
        }
        reader
            .slice_at(offset, len)
            .map(|s| s.to_vec())
            .map_err(|_| NtlmError::Malformed("a field pointed outside the message"))
    };
    let text = |bytes: Vec<u8>| -> String {
        if flags & flag::UNICODE != 0 {
            utf16le_to_string(&bytes).unwrap_or_default()
        } else {
            String::from_utf8_lossy(&bytes).into_owned()
        }
    };

    Ok(Authenticate {
        lm_response: slice(lm)?,
        nt_response: slice(nt)?,
        domain: text(slice(domain)?),
        user: text(slice(user)?),
        workstation: text(slice(workstation)?),
        encrypted_session_key: slice(session_key)?,
        flags,
        mic,
        mic_offset,
    })
}

/// What a successful authentication yields.
pub struct Established {
    pub user: String,
    pub domain: String,
    /// The key SMB2 signing is derived from.
    pub session_key: [u8; 16],
    pub anonymous: bool,
}

/// Verifies an AUTHENTICATE against a known NT hash and returns the session key.
///
/// `negotiate` and `challenge` are the raw earlier messages, needed only to
/// check the MIC when the client sent one. A MIC that is present and wrong is
/// fatal: it means the negotiation was tampered with even though the password
/// proof is correct.
pub fn verify_authenticate(
    auth: &Authenticate,
    raw_authenticate: &[u8],
    nt_hash: &[u8; 16],
    server_challenge: &[u8; 8],
    negotiate: &[u8],
    challenge: &[u8],
) -> Result<Established, NtlmError> {
    // An NTLMv2 response is a 16-byte proof plus a blob, so it is always
    // longer than 24. Exactly 24 is an NTLMv1 response, which this server
    // refuses rather than accepts as a weaker fallback.
    if auth.nt_response.len() == 24 {
        return Err(NtlmError::Unsupported("NTLMv1 is not accepted"));
    }
    if auth.nt_response.len() < 24 {
        return Err(NtlmError::BadCredentials);
    }
    let (proof, blob) = auth.nt_response.split_at(16);

    let key = ntowf_v2(nt_hash, &auth.user, &auth.domain);
    let mut signed = Vec::with_capacity(8 + blob.len());
    signed.extend_from_slice(server_challenge);
    signed.extend_from_slice(blob);
    let expected = hmac_md5(&key, &signed);

    let mut difference = 0u8;
    for (a, b) in expected.iter().zip(proof) {
        difference |= a ^ b;
    }
    if difference != 0 {
        return Err(NtlmError::BadCredentials);
    }

    let session_base_key = hmac_md5(&key, proof);
    let session_key = if auth.flags & flag::KEY_EXCH != 0
        && auth.encrypted_session_key.len() == 16
    {
        let decrypted = rc4(&session_base_key, &auth.encrypted_session_key);
        let mut out = [0u8; 16];
        out.copy_from_slice(&decrypted);
        out
    } else {
        session_base_key
    };

    if let (Some(mic), Some(offset)) = (auth.mic, auth.mic_offset) {
        if mic != [0u8; 16] {
            let mut zeroed = raw_authenticate.to_vec();
            if offset + 16 <= zeroed.len() {
                zeroed[offset..offset + 16].fill(0);
            }
            let mut all = Vec::with_capacity(
                negotiate.len() + challenge.len() + zeroed.len(),
            );
            all.extend_from_slice(negotiate);
            all.extend_from_slice(challenge);
            all.extend_from_slice(&zeroed);
            if hmac_md5(&session_key, &all) != mic {
                return Err(NtlmError::Unsupported(
                    "the handshake was altered in transit",
                ));
            }
        }
    }

    Ok(Established {
        user: auth.user.clone(),
        domain: auth.domain.clone(),
        session_key,
        anonymous: false,
    })
}

// ── client side ────────────────────────────────────────────────────────────

/// The NEGOTIATE message a client opens with.
pub fn build_negotiate(domain: &str, workstation: &str) -> Vec<u8> {
    let flags = flag::UNICODE
        | flag::REQUEST_TARGET
        | flag::SIGN
        | flag::NTLM
        | flag::ALWAYS_SIGN
        | flag::EXTENDED_SESSION_SECURITY
        | flag::KEY_128
        | flag::KEY_EXCH
        | flag::KEY_56
        | flag::VERSION;

    let domain_bytes = domain.as_bytes();
    let workstation_bytes = workstation.as_bytes();
    let domain_offset = 40u32;
    let workstation_offset = domain_offset + domain_bytes.len() as u32;

    let mut w = Writer::with_capacity(40 + domain_bytes.len() + workstation_bytes.len());
    w.bytes(SIGNATURE)
        .u32(1)
        .u32(flags)
        .u16(domain_bytes.len() as u16)
        .u16(domain_bytes.len() as u16)
        .u32(domain_offset)
        .u16(workstation_bytes.len() as u16)
        .u16(workstation_bytes.len() as u16)
        .u32(workstation_offset)
        .u8(6)
        .u8(1)
        .u16(7601)
        .zeros(3)
        .u8(15)
        .bytes(domain_bytes)
        .bytes(workstation_bytes);
    w.into_vec()
}

/// The fields a client needs out of the server's CHALLENGE.
pub struct ParsedChallenge {
    pub server_challenge: [u8; 8],
    pub flags: u32,
    pub target_info: Vec<u8>,
    pub target_name: String,
}

pub fn parse_challenge(message: &[u8]) -> Result<ParsedChallenge, NtlmError> {
    if message_type(message) != Some(2) {
        return Err(NtlmError::Malformed("not a CHALLENGE message"));
    }
    let reader = Reader::new(message);
    let mut cursor = Reader::new(message);
    cursor
        .skip(12)
        .map_err(|_| NtlmError::Malformed("truncated header"))?;

    let name_len = cursor
        .u16()
        .map_err(|_| NtlmError::Malformed("truncated"))? as usize;
    cursor.skip(2).map_err(|_| NtlmError::Malformed("truncated"))?;
    let name_offset = cursor
        .u32()
        .map_err(|_| NtlmError::Malformed("truncated"))? as usize;
    let flags = cursor.u32().map_err(|_| NtlmError::Malformed("truncated"))?;
    let server_challenge: [u8; 8] = cursor
        .array()
        .map_err(|_| NtlmError::Malformed("truncated challenge"))?;
    cursor.skip(8).map_err(|_| NtlmError::Malformed("truncated"))?;
    let info_len = cursor
        .u16()
        .map_err(|_| NtlmError::Malformed("truncated"))? as usize;
    cursor.skip(2).map_err(|_| NtlmError::Malformed("truncated"))?;
    let info_offset = cursor
        .u32()
        .map_err(|_| NtlmError::Malformed("truncated"))? as usize;

    let target_info = reader
        .slice_at(info_offset, info_len)
        .map(|s| s.to_vec())
        .unwrap_or_default();
    let target_name = reader
        .slice_at(name_offset, name_len)
        .ok()
        .and_then(|s| utf16le_to_string(s).ok())
        .unwrap_or_default();

    Ok(ParsedChallenge {
        server_challenge,
        flags,
        target_info,
        target_name,
    })
}

/// Builds the AUTHENTICATE message and returns it with the session key.
///
/// The `blob` construction is the whole of NTLMv2: a version stamp, the
/// server's timestamp echoed back, a client challenge, and the server's own
/// target info returned unmodified — which is what stops the response being
/// replayed against a different server.
pub fn build_authenticate(
    challenge: &ParsedChallenge,
    user: &str,
    domain: &str,
    password: &str,
    workstation: &str,
    timestamp: u64,
) -> Result<(Vec<u8>, [u8; 16]), String> {
    // No user name at all is a request for guest access, and it has its own
    // shape: the ANONYMOUS flag set and no proof of anything. Sending a
    // computed response for an empty user would instead look like a failed
    // sign-in as the account named "".
    if user.trim().is_empty() {
        return Ok((build_anonymous(workstation), [0u8; 16]));
    }
    let client_challenge: [u8; 8] = random_array()?;

    let mut blob = Writer::new();
    blob.u8(1)
        .u8(1)
        .u16(0)
        .u32(0)
        .u64(timestamp)
        .bytes(&client_challenge)
        .u32(0)
        .bytes(&challenge.target_info)
        .u32(0);
    let blob = blob.into_vec();

    let hash = nt_hash(password);
    let key = ntowf_v2(&hash, user, domain);
    let mut signed = Vec::with_capacity(8 + blob.len());
    signed.extend_from_slice(&challenge.server_challenge);
    signed.extend_from_slice(&blob);
    let proof = hmac_md5(&key, &signed);

    let mut nt_response = Vec::with_capacity(16 + blob.len());
    nt_response.extend_from_slice(&proof);
    nt_response.extend_from_slice(&blob);

    let session_base_key = hmac_md5(&key, &proof);

    let flags = flag::UNICODE
        | flag::REQUEST_TARGET
        | flag::SIGN
        | flag::NTLM
        | flag::ALWAYS_SIGN
        | flag::EXTENDED_SESSION_SECURITY
        | flag::TARGET_INFO
        | flag::KEY_128
        | flag::KEY_56
        | flag::KEY_EXCH
        | flag::VERSION;

    // When the server offers key exchange, generate a fresh session key and
    // send it wrapped, so the key protecting the session isn't a pure function
    // of the password.
    let (session_key, encrypted_session_key) = if challenge.flags & flag::KEY_EXCH != 0 {
        let exported: [u8; 16] = random_array()?;
        (exported, rc4(&session_base_key, &exported))
    } else {
        (session_base_key, Vec::new())
    };

    let domain_bytes = string_to_utf16le(domain);
    let user_bytes = string_to_utf16le(user);
    let workstation_bytes = string_to_utf16le(workstation);
    // Fixed part is 64 bytes, plus the 8-byte version and the 16-byte MIC.
    let payload_start = 88u32;
    let lm_offset = payload_start;
    let lm_len = 24u32; // A zeroed LMv2 response, which NTLMv2 requires be sent.
    let nt_offset = lm_offset + lm_len;
    let domain_offset = nt_offset + nt_response.len() as u32;
    let user_offset = domain_offset + domain_bytes.len() as u32;
    let workstation_offset = user_offset + user_bytes.len() as u32;
    let key_offset = workstation_offset + workstation_bytes.len() as u32;

    let mut w = Writer::new();
    w.bytes(SIGNATURE)
        .u32(3)
        .u16(lm_len as u16)
        .u16(lm_len as u16)
        .u32(lm_offset)
        .u16(nt_response.len() as u16)
        .u16(nt_response.len() as u16)
        .u32(nt_offset)
        .u16(domain_bytes.len() as u16)
        .u16(domain_bytes.len() as u16)
        .u32(domain_offset)
        .u16(user_bytes.len() as u16)
        .u16(user_bytes.len() as u16)
        .u32(user_offset)
        .u16(workstation_bytes.len() as u16)
        .u16(workstation_bytes.len() as u16)
        .u32(workstation_offset)
        .u16(encrypted_session_key.len() as u16)
        .u16(encrypted_session_key.len() as u16)
        .u32(key_offset)
        .u32(flags)
        .u8(6)
        .u8(1)
        .u16(7601)
        .zeros(3)
        .u8(15)
        .zeros(16) // MIC, filled in below
        .zeros(lm_len as usize)
        .bytes(&nt_response)
        .bytes(&domain_bytes)
        .bytes(&user_bytes)
        .bytes(&workstation_bytes)
        .bytes(&encrypted_session_key);

    Ok((w.into_vec(), session_key))
}

/// The AUTHENTICATE message for a client asking to be treated as a guest.
///
/// Every variable-length field is empty, which is what tells the server there
/// is nothing to verify. A one-byte LM response is what Windows sends here, and
/// some servers reject a zero-length one.
fn build_anonymous(workstation: &str) -> Vec<u8> {
    let flags = flag::UNICODE
        | flag::REQUEST_TARGET
        | flag::NTLM
        | flag::ALWAYS_SIGN
        | flag::ANONYMOUS
        | flag::EXTENDED_SESSION_SECURITY
        | flag::VERSION;

    let workstation_bytes = string_to_utf16le(workstation);
    // The fixed part is 64 bytes plus the 8-byte version block; no MIC is sent,
    // so the payload starts right after it.
    let payload_start = 72u32;
    let lm_offset = payload_start;
    let lm_len = 1u32;
    let nt_offset = lm_offset + lm_len;
    let domain_offset = nt_offset;
    let user_offset = domain_offset;
    let workstation_offset = user_offset;
    let key_offset = workstation_offset + workstation_bytes.len() as u32;

    let mut w = Writer::new();
    w.bytes(SIGNATURE)
        .u32(3)
        .u16(lm_len as u16)
        .u16(lm_len as u16)
        .u32(lm_offset)
        .u16(0)
        .u16(0)
        .u32(nt_offset)
        .u16(0)
        .u16(0)
        .u32(domain_offset)
        .u16(0)
        .u16(0)
        .u32(user_offset)
        .u16(workstation_bytes.len() as u16)
        .u16(workstation_bytes.len() as u16)
        .u32(workstation_offset)
        .u16(0)
        .u16(0)
        .u32(key_offset)
        .u32(flags)
        .u8(6)
        .u8(1)
        .u16(7601)
        .zeros(3)
        .u8(15)
        .u8(0) // the single-byte LM response
        .bytes(&workstation_bytes);
    w.into_vec()
}

/// Fills in the MIC over the three-message exchange.
///
/// Called after [`build_authenticate`] because the MIC covers the message it
/// sits inside, so it can only be computed once the rest is final.
pub fn seal_mic(
    authenticate: &mut [u8],
    session_key: &[u8; 16],
    negotiate: &[u8],
    challenge: &[u8],
) {
    if authenticate.len() < 88 {
        return;
    }
    authenticate[72..88].fill(0);
    let mut all =
        Vec::with_capacity(negotiate.len() + challenge.len() + authenticate.len());
    all.extend_from_slice(negotiate);
    all.extend_from_slice(challenge);
    all.extend_from_slice(authenticate);
    let mic = hmac_md5(session_key, &all);
    authenticate[72..88].copy_from_slice(&mic);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ntowf_v2_matches_the_ms_nlmp_vector() {
        // [MS-NLMP] §4.2.4.1.1: user "User", domain "Domain", password
        // "Password".
        let hash = nt_hash("Password");
        let key = ntowf_v2(&hash, "User", "Domain");
        assert_eq!(
            key,
            [
                0x0c, 0x86, 0x8a, 0x40, 0x3b, 0xfd, 0x7a, 0x93, 0xa3, 0x00, 0x1e, 0xf2,
                0x2e, 0xf0, 0x2e, 0x3f
            ]
        );
    }

    /// One full exchange, driven by this module's own client and server halves.
    fn round_trip(user: &str, domain: &str, password: &str, attempt: &str) -> bool {
        let negotiate = build_negotiate("", "TESTBOX");
        let challenge = build_challenge("SERVER", "server.local", "WORKGROUP", 0).unwrap();
        let parsed = parse_challenge(&challenge.message).unwrap();
        let (mut auth_message, session_key) =
            build_authenticate(&parsed, user, domain, attempt, "TESTBOX", 0).unwrap();
        seal_mic(
            &mut auth_message,
            &session_key,
            &negotiate,
            &challenge.message,
        );

        let auth = parse_authenticate(&auth_message).unwrap();
        verify_authenticate(
            &auth,
            &auth_message,
            &nt_hash(password),
            &challenge.server_challenge,
            &negotiate,
            &challenge.message,
        )
        .is_ok()
    }

    #[test]
    fn the_right_password_authenticates() {
        assert!(round_trip("alice", "WORKGROUP", "correct horse", "correct horse"));
    }

    #[test]
    fn the_wrong_password_does_not() {
        assert!(!round_trip("alice", "WORKGROUP", "correct horse", "guess"));
    }

    #[test]
    fn the_session_key_survives_the_exchange() {
        let negotiate = build_negotiate("", "BOX");
        let challenge = build_challenge("SERVER", "server.local", "WG", 0).unwrap();
        let parsed = parse_challenge(&challenge.message).unwrap();
        let (mut message, client_key) =
            build_authenticate(&parsed, "bob", "WG", "hunter2", "BOX", 0).unwrap();
        seal_mic(&mut message, &client_key, &negotiate, &challenge.message);

        let auth = parse_authenticate(&message).unwrap();
        let established = verify_authenticate(
            &auth,
            &message,
            &nt_hash("hunter2"),
            &challenge.server_challenge,
            &negotiate,
            &challenge.message,
        )
        .unwrap();
        assert_eq!(established.session_key, client_key);
        assert_eq!(established.user, "bob");
    }

    #[test]
    fn a_tampered_handshake_is_caught_by_the_mic() {
        let negotiate = build_negotiate("", "BOX");
        let challenge = build_challenge("SERVER", "server.local", "WG", 0).unwrap();
        let parsed = parse_challenge(&challenge.message).unwrap();
        let (mut message, client_key) =
            build_authenticate(&parsed, "bob", "WG", "hunter2", "BOX", 0).unwrap();
        seal_mic(&mut message, &client_key, &negotiate, &challenge.message);

        // A downgrade attacker rewrites the NEGOTIATE the server saw.
        let mut altered = negotiate.clone();
        altered[12] ^= 0xFF;

        let auth = parse_authenticate(&message).unwrap();
        let result = verify_authenticate(
            &auth,
            &message,
            &nt_hash("hunter2"),
            &challenge.server_challenge,
            &altered,
            &challenge.message,
        );
        assert!(matches!(result, Err(NtlmError::Unsupported(_))));
    }

    #[test]
    fn ntlmv1_length_responses_are_refused() {
        let auth = Authenticate {
            domain: "WG".into(),
            user: "bob".into(),
            workstation: "BOX".into(),
            lm_response: vec![0; 24],
            nt_response: vec![0; 24],
            encrypted_session_key: Vec::new(),
            flags: flag::UNICODE,
            mic: None,
            mic_offset: None,
        };
        let result = verify_authenticate(
            &auth,
            &[],
            &nt_hash("x"),
            &[0; 8],
            &[],
            &[],
        );
        assert!(matches!(result, Err(NtlmError::Unsupported(_))));
    }

    #[test]
    fn an_empty_user_produces_an_anonymous_message() {
        let challenge = build_challenge("SERVER", "server.local", "WG", 0).unwrap();
        let parsed = parse_challenge(&challenge.message).unwrap();
        let (message, key) =
            build_authenticate(&parsed, "", "", "", "BOX", 0).unwrap();

        let auth = parse_authenticate(&message).unwrap();
        assert!(auth.is_anonymous(), "the server must read this as a guest");
        assert!(auth.user.is_empty());
        assert_eq!(key, [0u8; 16], "a guest has no session key");
    }

    #[test]
    fn an_anonymous_message_is_not_mistaken_for_a_real_sign_in() {
        let challenge = build_challenge("SERVER", "server.local", "WG", 0).unwrap();
        let parsed = parse_challenge(&challenge.message).unwrap();
        let (message, _) = build_authenticate(&parsed, "", "", "", "BOX", 0).unwrap();
        let auth = parse_authenticate(&message).unwrap();

        // Verifying it as an account must fail rather than succeed by accident.
        let result = verify_authenticate(
            &auth,
            &message,
            &nt_hash(""),
            &challenge.server_challenge,
            &[],
            &challenge.message,
        );
        assert!(result.is_err());
    }

    #[test]
    fn garbage_is_rejected_without_panicking() {
        assert!(parse_authenticate(b"not ntlm").is_err());
        assert!(parse_challenge(&[0u8; 4]).is_err());
        assert!(message_type(b"NTLMSSP\0\x03").is_none());
    }
}
