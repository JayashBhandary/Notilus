//! Just enough DCE/RPC and `srvsvc` to answer "what shares are here?".
//!
//! A client that wants to *browse* a server — the iOS and Android Files apps,
//! macOS Finder, Windows Explorer, `smbclient -L` — does not ask over SMB. It
//! connects to the hidden `IPC$` share, opens the `srvsvc` named pipe, and
//! makes a `NetrShareEnum` call over MSRPC ([MS-SRVS]). Without that the server
//! is reachable but invisible: every one of those clients stops at the point
//! where it would show a list of shares.
//!
//! This is the smallest implementation that satisfies them — a bind handshake
//! and three calls. Nothing here is a general RPC stack, and it deliberately
//! isn't: the surface a real one exposes is enormous and none of the rest is
//! reachable from a file browser.

use super::share::Share;
use super::wire::{Reader, Writer};

/// `8a885d04-1ceb-11c9-9fe8-08002b104860` v2.0 — the NDR transfer syntax every
/// client offers, in the mixed-endian field order a DCE/RPC UUID is written in.
const NDR32_UUID: [u8; 16] = [
    0x04, 0x5d, 0x88, 0x8a, 0xeb, 0x1c, 0xc9, 0x11, 0x9f, 0xe8, 0x08, 0x00, 0x2b, 0x10,
    0x48, 0x60,
];

mod pdu {
    pub const REQUEST: u8 = 0;
    pub const RESPONSE: u8 = 2;
    pub const FAULT: u8 = 3;
    pub const BIND: u8 = 11;
    pub const BIND_ACK: u8 = 12;
}

mod opnum {
    /// `NetrShareEnum`
    pub const SHARE_ENUM: u16 = 15;
    /// `NetrShareGetInfo`
    pub const SHARE_GET_INFO: u16 = 16;
    /// `NetrServerGetInfo`
    pub const SERVER_GET_INFO: u16 = 21;
}

mod win {
    pub const OK: u32 = 0;
    pub const ACCESS_DENIED: u32 = 5;
    pub const NOT_FOUND: u32 = 2310;
}

/// `STYPE_DISKTREE` — an ordinary folder share.
const STYPE_DISKTREE: u32 = 0;
/// `STYPE_IPC | STYPE_SPECIAL` — the hidden pipe share.
const STYPE_IPC_HIDDEN: u32 = 0x0000_0003 | 0x8000_0000;

/// The name of the hidden share every browsing client connects to first.
pub const IPC_SHARE: &str = "IPC$";

/// One `srvsvc` pipe, holding whatever it answered until the client reads it.
///
/// Clients drive a pipe in two ways — write then read, or a single
/// `FSCTL_PIPE_TRANSCEIVE` — so the reply is buffered here rather than produced
/// inline, and a client that reads in small pieces gets them in order.
#[derive(Default)]
pub struct Pipe {
    pending: Vec<u8>,
}

impl Pipe {
    pub fn new() -> Pipe {
        Pipe::default()
    }

    /// Handles one PDU and buffers the reply, returning it as well for the
    /// transceive path that wants it immediately.
    pub fn call(&mut self, request: &[u8], shares: &[&Share], server: &str) -> Vec<u8> {
        let reply = handle(request, shares, server);
        self.pending = reply.clone();
        reply
    }

    /// Takes up to `limit` bytes of the buffered reply.
    pub fn read(&mut self, limit: usize) -> Vec<u8> {
        let take = limit.min(self.pending.len());
        self.pending.drain(..take).collect()
    }

    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }
}

/// The common 16-byte PDU header.
struct Head {
    kind: u8,
    call_id: u32,
}

fn parse_head(request: &[u8]) -> Option<(Head, usize)> {
    let mut r = Reader::new(request);
    let _major = r.u8().ok()?;
    let _minor = r.u8().ok()?;
    let kind = r.u8().ok()?;
    let _flags = r.u8().ok()?;
    let _data_representation = r.u32().ok()?;
    let _frag_length = r.u16().ok()?;
    let _auth_length = r.u16().ok()?;
    let call_id = r.u32().ok()?;
    Some((Head { kind, call_id }, r.position()))
}

fn handle(request: &[u8], shares: &[&Share], server: &str) -> Vec<u8> {
    let Some((head, after)) = parse_head(request) else {
        return fault(0, win::ACCESS_DENIED);
    };
    match head.kind {
        pdu::BIND => bind_ack(head.call_id, request, after),
        pdu::REQUEST => {
            let mut r = Reader::new(request);
            if r.seek(after).is_err() {
                return fault(head.call_id, win::ACCESS_DENIED);
            }
            let _alloc_hint = r.u32().unwrap_or(0);
            let _context_id = r.u16().unwrap_or(0);
            let operation = r.u16().unwrap_or(u16::MAX);
            let body = &request[r.position().min(request.len())..];

            let payload = match operation {
                opnum::SHARE_ENUM => share_enum(shares),
                opnum::SHARE_GET_INFO => share_get_info(shares, body),
                opnum::SERVER_GET_INFO => server_get_info(server),
                // Anything else is part of a surface a file browser never
                // touches; a fault is honest and keeps the client moving.
                _ => return fault(head.call_id, win::ACCESS_DENIED),
            };
            response(head.call_id, &payload)
        }
        _ => fault(head.call_id, win::ACCESS_DENIED),
    }
}

/// Accepts the bind, echoing back the transfer syntax the client offered.
fn bind_ack(call_id: u32, request: &[u8], after_head: usize) -> Vec<u8> {
    let mut r = Reader::new(request);
    let _ = r.seek(after_head);
    let max_xmit = r.u16().unwrap_or(4280);
    let max_recv = r.u16().unwrap_or(4280);
    let assoc_group = r.u32().unwrap_or(0);

    // The secondary address is the pipe's own name, NUL-terminated, and the
    // result list that follows it is 4-byte aligned.
    let address = b"\\PIPE\\srvsvc\0";

    let mut body = Writer::new();
    body.u16(max_xmit)
        .u16(max_recv)
        .u32(if assoc_group == 0 { 0x0000_1234 } else { assoc_group })
        .u16(address.len() as u16)
        .bytes(address);
    body.align_to(4);
    body.u8(1) // one result
        .u8(0)
        .u16(0)
        .u16(0) // acceptance
        .u16(0) // no reason
        .bytes(&NDR32_UUID)
        .u32(2); // NDR32 version

    frame(pdu::BIND_ACK, call_id, &body.into_vec())
}

fn response(call_id: u32, payload: &[u8]) -> Vec<u8> {
    let mut body = Writer::new();
    body.u32(payload.len() as u32) // alloc hint
        .u16(0) // context id
        .u8(0) // cancel count
        .u8(0)
        .bytes(payload);
    frame(pdu::RESPONSE, call_id, &body.into_vec())
}

fn fault(call_id: u32, code: u32) -> Vec<u8> {
    let mut body = Writer::new();
    body.u32(0).u16(0).u8(0).u8(0).u32(code).u32(0);
    frame(pdu::FAULT, call_id, &body.into_vec())
}

fn frame(kind: u8, call_id: u32, body: &[u8]) -> Vec<u8> {
    let length = 16 + body.len();
    let mut w = Writer::with_capacity(length);
    w.u8(5) // major
        .u8(0) // minor
        .u8(kind)
        .u8(0x03) // first and last fragment
        .u32(0x0000_0010) // little-endian, ASCII, IEEE
        .u16(length as u16)
        .u16(0) // no auth
        .u32(call_id)
        .bytes(body);
    w.into_vec()
}

// ── srvsvc calls ───────────────────────────────────────────────────────────

/// `NetrShareEnum` at info level 1, which is what every browsing client asks
/// for: name, type and comment per share.
///
/// The reply is NDR: a conformant array of three-field structs whose strings
/// are *deferred* to the end, in the order their referent pointers appeared.
/// Getting that order wrong is the classic way this call half-works — the
/// client shows the right number of shares with the wrong names.
fn share_enum(shares: &[&Share]) -> Vec<u8> {
    let mut w = Writer::new();
    w.u32(1) // Level
        .u32(1) // switch value: the union arm
        .u32(0x0002_0000) // pointer to the level-1 container
        .u32(shares.len() as u32) // EntriesRead
        .u32(0x0002_0004) // pointer to the array
        .u32(shares.len() as u32); // conformant max count

    // One struct per share, each naming two strings that follow.
    let mut referent = 0x0002_0008u32;
    for share in shares {
        w.u32(referent); // netname
        referent += 4;
        w.u32(share_type(share));
        w.u32(referent); // remark
        referent += 4;
    }
    for share in shares {
        ndr_string(&mut w, &share.name);
        ndr_string(&mut w, &share.comment);
    }

    w.u32(shares.len() as u32) // TotalEntries
        .u32(0) // ResumeHandle: null, the enumeration is complete
        .u32(win::OK);
    w.into_vec()
}

/// `NetrShareGetInfo` at level 1 — asked about the share a client is about to
/// open.
fn share_get_info(shares: &[&Share], body: &[u8]) -> Vec<u8> {
    // The first string in the request is the server name; the share follows.
    let wanted = second_string(body).or_else(|| first_string(body));
    let found = wanted.and_then(|name| {
        shares
            .iter()
            .find(|s| s.name.eq_ignore_ascii_case(&name))
            .copied()
    });
    level_1_info(found)
}

fn level_1_info(share: Option<&Share>) -> Vec<u8> {
    let mut w = Writer::new();
    let Some(share) = share else {
        w.u32(1).u32(0).u32(win::NOT_FOUND);
        return w.into_vec();
    };
    w.u32(1) // Level
        .u32(0x0002_0000) // pointer to the union
        .u32(0x0002_0004) // netname
        .u32(share_type(share))
        .u32(0x0002_0008); // remark
    ndr_string(&mut w, &share.name);
    ndr_string(&mut w, &share.comment);
    w.u32(win::OK);
    w.into_vec()
}

/// `NetrServerGetInfo` at level 101 — some clients ask before enumerating.
fn server_get_info(server: &str) -> Vec<u8> {
    const SV_TYPE_SERVER: u32 = 0x0000_0002;
    let mut w = Writer::new();
    w.u32(101)
        .u32(0x0002_0000) // pointer to the union
        .u32(500) // platform id: NT
        .u32(0x0002_0004) // name
        .u32(6) // version major
        .u32(1) // version minor
        .u32(SV_TYPE_SERVER)
        .u32(0); // no comment
    ndr_string(&mut w, server);
    w.u32(win::OK);
    w.into_vec()
}

fn share_type(share: &Share) -> u32 {
    if share.name.eq_ignore_ascii_case(IPC_SHARE) {
        STYPE_IPC_HIDDEN
    } else {
        STYPE_DISKTREE
    }
}

/// A conformant, varying NDR string: max count, offset, actual count, then the
/// UTF-16LE characters including the terminator, padded to four bytes.
fn ndr_string(w: &mut Writer, value: &str) {
    let units: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
    w.u32(units.len() as u32).u32(0).u32(units.len() as u32);
    for unit in units {
        w.u16(unit);
    }
    w.align_to(4);
}

/// Reads the first NDR string in a request, skipping its referent pointer.
fn first_string(body: &[u8]) -> Option<String> {
    let mut r = Reader::new(body);
    let pointer = r.u32().ok()?;
    if pointer == 0 {
        return None;
    }
    read_ndr_string(&mut r)
}

fn second_string(body: &[u8]) -> Option<String> {
    let mut r = Reader::new(body);
    let pointer = r.u32().ok()?;
    if pointer != 0 {
        read_ndr_string(&mut r)?;
    }
    let next = r.u32().ok()?;
    if next == 0 {
        return None;
    }
    read_ndr_string(&mut r)
}

fn read_ndr_string(r: &mut Reader<'_>) -> Option<String> {
    let max = r.u32().ok()? as usize;
    let _offset = r.u32().ok()?;
    let actual = r.u32().ok()? as usize;
    // Both bounds matter: `actual > max` is malformed, and the cap keeps a
    // hostile length from turning into a huge read.
    if actual > max || actual > 4096 {
        return None;
    }
    let bytes = r.take(actual * 2).ok()?;
    let over = (actual * 2) % 4;
    if over != 0 {
        r.skip(4 - over).ok()?;
    }
    let text = super::wire::utf16le_to_string(bytes).ok()?;
    Some(text.trim_end_matches('\0').to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn share(name: &str, comment: &str) -> Share {
        Share {
            name: name.into(),
            root: PathBuf::from("/tmp"),
            read_only: false,
            comment: comment.into(),
            allowed_users: Vec::new(),
            guest_ok: false,
        }
    }

    /// `4b324fc8-1670-01d3-1278-5a47bf6ee188` v3.0 — the srvsvc interface a
    /// client names in its bind.
    const SRVSVC_UUID: [u8; 16] = [
        0xc8, 0x4f, 0x32, 0x4b, 0x70, 0x16, 0xd3, 0x01, 0x12, 0x78, 0x5a, 0x47, 0xbf,
        0x6e, 0xe1, 0x88,
    ];

    fn bind_request() -> Vec<u8> {
        let mut body = Writer::new();
        body.u16(4280)
            .u16(4280)
            .u32(0)
            .u32(1) // one context
            .u16(0)
            .u8(1)
            .u8(0)
            .bytes(&SRVSVC_UUID)
            .u32(3)
            .bytes(&NDR32_UUID)
            .u32(2);
        frame(pdu::BIND, 1, &body.into_vec())
    }

    fn enum_request() -> Vec<u8> {
        let mut body = Writer::new();
        body.u32(0) // null server name
            .u32(1) // level
            .u32(1) // switch
            .u32(0x0002_0000)
            .u32(0)
            .u32(0)
            .u32(u32::MAX) // preferred maximum length
            .u32(0); // null resume handle
        let mut w = Writer::new();
        w.u32(body.len() as u32)
            .u16(0)
            .u16(opnum::SHARE_ENUM)
            .bytes(body.as_slice());
        frame(pdu::REQUEST, 2, &w.into_vec())
    }

    fn trailing_status(reply: &[u8]) -> u32 {
        u32::from_le_bytes(reply[reply.len() - 4..].try_into().expect("four bytes"))
    }

    fn as_utf16_text(reply: &[u8]) -> String {
        let units: Vec<u16> = reply
            .chunks_exact(2)
            .map(|p| u16::from_le_bytes([p[0], p[1]]))
            .collect();
        String::from_utf16_lossy(&units)
    }

    #[test]
    fn a_bind_is_accepted_and_names_the_pipe() {
        let mut pipe = Pipe::new();
        let reply = pipe.call(&bind_request(), &[], "NOTILUS");
        assert_eq!(reply[2], pdu::BIND_ACK);
        // The fragment length must match what was written, or the client waits
        // forever for the rest of a PDU that never comes.
        let length = u16::from_le_bytes([reply[8], reply[9]]) as usize;
        assert_eq!(length, reply.len());
        assert!(
            reply.windows(12).any(|w| w == b"\\PIPE\\srvsvc"),
            "the ack must name the pipe"
        );
    }

    #[test]
    fn enumeration_lists_every_share_by_name() {
        let public = share("Public", "Everyone");
        let work = share("Work", "");
        let shares = [&public, &work];

        let mut pipe = Pipe::new();
        let reply = pipe.call(&enum_request(), &shares, "NOTILUS");
        assert_eq!(reply[2], pdu::RESPONSE);

        let decoded = as_utf16_text(&reply);
        assert!(decoded.contains("Public"), "got {decoded:?}");
        assert!(decoded.contains("Work"), "got {decoded:?}");
        assert_eq!(trailing_status(&reply), win::OK);
    }

    #[test]
    fn an_empty_server_enumerates_to_nothing_rather_than_failing() {
        let mut pipe = Pipe::new();
        let reply = pipe.call(&enum_request(), &[], "NOTILUS");
        assert_eq!(reply[2], pdu::RESPONSE);
        assert_eq!(trailing_status(&reply), win::OK);
    }

    #[test]
    fn an_unknown_operation_faults_instead_of_hanging_the_client() {
        let mut w = Writer::new();
        w.u32(0).u16(0).u16(999);
        let request = frame(pdu::REQUEST, 3, &w.into_vec());

        let mut pipe = Pipe::new();
        assert_eq!(pipe.call(&request, &[], "NOTILUS")[2], pdu::FAULT);
    }

    #[test]
    fn garbage_is_answered_with_a_fault_not_a_panic() {
        let mut pipe = Pipe::new();
        for bad in [vec![], vec![0u8; 3], vec![0xFFu8; 64]] {
            assert_eq!(pipe.call(&bad, &[], "NOTILUS")[2], pdu::FAULT);
        }
    }

    #[test]
    fn a_reply_is_read_back_in_pieces_until_it_is_drained() {
        let mut pipe = Pipe::new();
        let total = pipe.call(&bind_request(), &[], "NOTILUS").len();

        let first = pipe.read(8);
        assert_eq!(first.len(), 8);
        assert!(pipe.has_pending());
        let rest = pipe.read(4096);
        assert_eq!(first.len() + rest.len(), total);
        assert!(!pipe.has_pending());
        assert!(pipe.read(16).is_empty());
    }

    #[test]
    fn ndr_strings_round_trip_through_the_request_reader() {
        let mut w = Writer::new();
        w.u32(0x0002_0000);
        ndr_string(&mut w, "\\\\NOTILUS");
        w.u32(0x0002_0004);
        ndr_string(&mut w, "Public");
        let body = w.into_vec();

        assert_eq!(first_string(&body).as_deref(), Some("\\\\NOTILUS"));
        assert_eq!(second_string(&body).as_deref(), Some("Public"));
    }

    #[test]
    fn share_get_info_finds_the_named_share_and_misses_cleanly() {
        let public = share("Public", "Everyone");
        let shares = [&public];

        let mut hit = Writer::new();
        hit.u32(0x0002_0000);
        ndr_string(&mut hit, "\\\\NOTILUS");
        hit.u32(0x0002_0004);
        ndr_string(&mut hit, "Public");
        let found = share_get_info(&shares, &hit.into_vec());
        assert_eq!(trailing_status(&found), win::OK);
        assert!(as_utf16_text(&found).contains("Public"));

        let mut miss = Writer::new();
        miss.u32(0x0002_0000);
        ndr_string(&mut miss, "\\\\NOTILUS");
        miss.u32(0x0002_0004);
        ndr_string(&mut miss, "Nope");
        let absent = share_get_info(&shares, &miss.into_vec());
        assert_eq!(trailing_status(&absent), win::NOT_FOUND);
    }

    #[test]
    fn the_ipc_share_is_typed_as_a_hidden_pipe() {
        assert_eq!(share_type(&share(IPC_SHARE, "")), STYPE_IPC_HIDDEN);
        assert_eq!(share_type(&share("Public", "")), STYPE_DISKTREE);
    }
}
