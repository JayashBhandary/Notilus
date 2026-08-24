//! The cryptography SMB2 needs: packet signing, key derivation, and the two
//! legacy primitives NTLM is built out of.
//!
//! Everything here is a thin, allocation-light wrapper over RustCrypto crates
//! so the algorithms themselves aren't reimplemented — except RC4, which no
//! maintained crate exposes any more and which NTLM's key exchange still
//! requires.

use aes::Aes128;
use cmac::Cmac;
use hmac::{Hmac, Mac};
use md4::Md4;
use md5::Md5;
use sha2::{Digest, Sha256, Sha512};

use super::proto::{Dialect, HEADER_SIZE};

pub fn md4(data: &[u8]) -> [u8; 16] {
    let mut hasher = Md4::new();
    hasher.update(data);
    hasher.finalize().into()
}

pub fn hmac_md5(key: &[u8], data: &[u8]) -> [u8; 16] {
    let mut mac = <Hmac<Md5> as Mac>::new_from_slice(key)
        .expect("HMAC accepts a key of any length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key)
        .expect("HMAC accepts a key of any length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

pub fn sha512(chunks: &[&[u8]]) -> [u8; 64] {
    let mut hasher = Sha512::new();
    for chunk in chunks {
        hasher.update(chunk);
    }
    hasher.finalize().into()
}

fn aes_cmac(key: &[u8; 16], data: &[u8]) -> [u8; 16] {
    let mut mac = <Cmac<Aes128> as Mac>::new_from_slice(key)
        .expect("CMAC takes exactly a 16-byte AES-128 key");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

/// RC4, used only by NTLM's optional session-key exchange.
///
/// Kept here rather than pulled in as a dependency: the maintained crates have
/// all deprecated it, and the algorithm is short enough that vendoring it is
/// less risk than depending on an unmaintained one.
pub fn rc4(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut state: [u8; 256] = [0; 256];
    for (i, slot) in state.iter_mut().enumerate() {
        *slot = i as u8;
    }
    if !key.is_empty() {
        let mut j = 0u8;
        for i in 0..256 {
            j = j
                .wrapping_add(state[i])
                .wrapping_add(key[i % key.len()]);
            state.swap(i, j as usize);
        }
    }
    let mut out = Vec::with_capacity(data.len());
    let (mut i, mut j) = (0u8, 0u8);
    for byte in data {
        i = i.wrapping_add(1);
        j = j.wrapping_add(state[i as usize]);
        state.swap(i as usize, j as usize);
        let k = state[(state[i as usize].wrapping_add(state[j as usize])) as usize];
        out.push(byte ^ k);
    }
    out
}

/// SP800-108 counter-mode KDF with HMAC-SHA256, producing 128 bits.
///
/// This is how SMB 3.x turns one session key into the several keys it uses for
/// different purposes, so that compromising one doesn't yield the others.
///
/// The fixed input is `counter || label || 0x00 || context || L`, where the
/// `0x00` is SP800-108's own separator. MS-SMB2 specifies its labels as
/// *NUL-terminated* strings, so a caller passes `b"SMBSigningKey\0"` and the
/// separator lands after that terminator — two NULs in the input, not one.
/// Passing the label without its terminator produces a key that is wrong in a
/// way nothing local catches: both ends of one implementation agree, and every
/// other SMB stack rejects the signature.
pub fn kdf_sp800_108(key: &[u8], label: &[u8], context: &[u8]) -> [u8; 16] {
    let mut input = Vec::with_capacity(label.len() + context.len() + 12);
    input.extend_from_slice(&1u32.to_be_bytes());
    input.extend_from_slice(label);
    input.push(0);
    input.extend_from_slice(context);
    input.extend_from_slice(&128u32.to_be_bytes());

    let full = hmac_sha256(key, &input);
    let mut out = [0u8; 16];
    out.copy_from_slice(&full[..16]);
    out
}

/// The signing key for a session, which differs by dialect.
///
/// 2.x signs with the session key itself. 3.0 and 3.0.2 derive one from a fixed
/// label; 3.1.1 mixes in the preauth-integrity hash, which is what ties the
/// session's keys to the exact negotiate and session-setup messages that
/// established it and so defeats a downgrade attack.
pub fn signing_key(
    dialect: Dialect,
    session_key: &[u8],
    preauth_hash: &[u8; 64],
) -> [u8; 16] {
    let mut truncated = [0u8; 16];
    let take = session_key.len().min(16);
    truncated[..take].copy_from_slice(&session_key[..take]);

    match dialect {
        Dialect::Smb202 | Dialect::Smb210 => truncated,
        Dialect::Smb300 | Dialect::Smb302 => {
            kdf_sp800_108(&truncated, b"SMB2AESCMAC\0", b"SmbSign\0")
        }
        Dialect::Smb311 => kdf_sp800_108(&truncated, b"SMBSigningKey\0", preauth_hash),
    }
}

/// Computes the signature for one packet.
///
/// The signature field itself must read as zero while the MAC is taken, which
/// is why this copies rather than signing in place.
pub fn sign_packet(dialect: Dialect, key: &[u8; 16], packet: &[u8]) -> [u8; 16] {
    if packet.len() < HEADER_SIZE {
        return [0u8; 16];
    }
    let mut zeroed = packet.to_vec();
    zeroed[48..64].fill(0);

    if dialect.is_smb3() {
        aes_cmac(key, &zeroed)
    } else {
        let mac = hmac_sha256(key, &zeroed);
        let mut out = [0u8; 16];
        out.copy_from_slice(&mac[..16]);
        out
    }
}

/// Writes a signature into a packet in place and sets the SIGNED flag.
pub fn apply_signature(dialect: Dialect, key: &[u8; 16], packet: &mut [u8]) {
    if packet.len() < HEADER_SIZE {
        return;
    }
    // Flags live at offset 16; the SIGNED bit has to be set *before* the MAC
    // is taken, since it is part of what is signed.
    let mut flags = u32::from_le_bytes([packet[16], packet[17], packet[18], packet[19]]);
    flags |= super::proto::flags::SIGNED;
    packet[16..20].copy_from_slice(&flags.to_le_bytes());

    let signature = sign_packet(dialect, key, packet);
    packet[48..64].copy_from_slice(&signature);
}

/// Constant-time comparison of a received signature against the expected one.
pub fn verify_packet(dialect: Dialect, key: &[u8; 16], packet: &[u8]) -> bool {
    if packet.len() < HEADER_SIZE {
        return false;
    }
    let expected = sign_packet(dialect, key, packet);
    let mut difference = 0u8;
    for (a, b) in expected.iter().zip(&packet[48..64]) {
        difference |= a ^ b;
    }
    difference == 0
}

/// Rolls one message into the running preauth-integrity hash (SMB 3.1.1).
pub fn extend_preauth(current: &[u8; 64], message: &[u8]) -> [u8; 64] {
    sha512(&[current, message])
}

/// Cryptographically random bytes, for challenges, GUIDs and salts.
///
/// A failure here would mean the OS entropy source is unavailable; rather than
/// silently continuing with predictable values, the caller is told so it can
/// refuse the connection.
pub fn random_bytes(out: &mut [u8]) -> Result<(), String> {
    getrandom::getrandom(out).map_err(|e| format!("no system randomness available: {e}"))
}

pub fn random_array<const N: usize>() -> Result<[u8; N], String> {
    let mut out = [0u8; N];
    random_bytes(&mut out)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rc4_matches_the_published_test_vector() {
        // RFC 6229, key "Key", plaintext "Plaintext".
        let out = rc4(b"Key", b"Plaintext");
        assert_eq!(out, vec![0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3]);
    }

    #[test]
    fn rc4_is_its_own_inverse() {
        let key = b"a longer key value";
        let cipher = rc4(key, b"round trip me");
        assert_eq!(rc4(key, &cipher), b"round trip me".to_vec());
    }

    #[test]
    fn md4_matches_the_rfc_vector() {
        // RFC 1320 test suite: MD4("abc").
        let digest = md4(b"abc");
        assert_eq!(
            digest,
            [
                0xa4, 0x48, 0x01, 0x7a, 0xaf, 0x21, 0xd8, 0x52, 0x5f, 0xc1, 0x0a, 0xe8,
                0x7a, 0xa6, 0x72, 0x9d
            ]
        );
    }

    #[test]
    fn signing_detects_a_tampered_packet() {
        let key = [7u8; 16];
        let mut packet = vec![0u8; HEADER_SIZE + 16];
        packet[..4].copy_from_slice(&super::super::proto::PROTOCOL_ID);
        apply_signature(Dialect::Smb210, &key, &mut packet);
        assert!(verify_packet(Dialect::Smb210, &key, &packet));

        packet[HEADER_SIZE] ^= 0xFF;
        assert!(!verify_packet(Dialect::Smb210, &key, &packet));
    }

    #[test]
    fn smb3_and_smb2_signatures_differ_for_the_same_key() {
        let key = [3u8; 16];
        let mut packet = vec![0u8; HEADER_SIZE];
        packet[..4].copy_from_slice(&super::super::proto::PROTOCOL_ID);
        let two = sign_packet(Dialect::Smb210, &key, &packet);
        let three = sign_packet(Dialect::Smb300, &key, &packet);
        assert_ne!(two, three, "3.x must use AES-CMAC, not HMAC-SHA256");
    }

    #[test]
    fn the_signing_key_depends_on_the_preauth_hash_at_311() {
        let session = [1u8; 16];
        let a = signing_key(Dialect::Smb311, &session, &[0u8; 64]);
        let b = signing_key(Dialect::Smb311, &session, &[9u8; 64]);
        assert_ne!(a, b, "3.1.1 must bind its keys to the preauth hash");

        // 3.0 ignores it, so a different hash must produce the same key.
        let c = signing_key(Dialect::Smb300, &session, &[0u8; 64]);
        let d = signing_key(Dialect::Smb300, &session, &[9u8; 64]);
        assert_eq!(c, d);
    }

    /// Vectors produced by an independent SP800-108 implementation
    /// (`cryptography`'s `KBKDFHMAC`, which is what the `smbprotocol` client
    /// signs with). These pin the label encoding: an earlier version dropped
    /// the labels' NUL terminators, which every other SMB stack rejected while
    /// this crate's own client happily accepted.
    #[test]
    fn derived_keys_match_an_independent_implementation() {
        let key: [u8; 16] = std::array::from_fn(|i| i as u8 + 1);
        let preauth = [0xAAu8; 64];

        assert_eq!(
            signing_key(Dialect::Smb311, &key, &preauth),
            [
                0x26, 0xc1, 0x0e, 0x17, 0x85, 0x71, 0x92, 0xd8, 0x49, 0x60, 0x3c, 0x0b,
                0xe4, 0xcb, 0x8a, 0x32
            ],
            "SMB 3.1.1 signing key"
        );
        assert_eq!(
            signing_key(Dialect::Smb300, &key, &preauth),
            [
                0xdf, 0x3d, 0x10, 0xc8, 0x04, 0xf8, 0xbe, 0x22, 0xba, 0x94, 0xd4, 0xa0,
                0x57, 0x6e, 0xc1, 0xd4
            ],
            "SMB 3.0 signing key"
        );
    }

    #[test]
    fn the_preauth_hash_moves_with_every_message() {
        let start = [0u8; 64];
        let after = extend_preauth(&start, b"negotiate");
        assert_ne!(after, start);
        assert_ne!(extend_preauth(&after, b"session setup"), after);
    }
}
