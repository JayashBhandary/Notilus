//! SMB2 wire constants and the 64-byte packet header.
//!
//! Field names follow [MS-SMB2] so the code can be read next to the spec.

use super::wire::{Reader, WireResult, Writer};

/// `\xFESMB` — the marker that starts every SMB2 packet.
pub const PROTOCOL_ID: [u8; 4] = [0xFE, b'S', b'M', b'B'];
pub const HEADER_SIZE: usize = 64;

/// The 4-byte NetBIOS session-service header that precedes every packet on the
/// wire, even on port 445 where NetBIOS itself is long gone.
pub const NBSS_HEADER: usize = 4;

/// Largest payload the server will accept in one packet.
///
/// Read and write sizes are advertised as 8 MB (below), and the header,
/// padding and any compound follow-on have to fit alongside; 9 MB leaves room
/// without letting a malformed length field make us allocate wildly.
pub const MAX_PACKET: usize = 9 * 1024 * 1024;

// ── commands ───────────────────────────────────────────────────────────────

pub mod command {
    pub const NEGOTIATE: u16 = 0x0000;
    pub const SESSION_SETUP: u16 = 0x0001;
    pub const LOGOFF: u16 = 0x0002;
    pub const TREE_CONNECT: u16 = 0x0003;
    pub const TREE_DISCONNECT: u16 = 0x0004;
    pub const CREATE: u16 = 0x0005;
    pub const CLOSE: u16 = 0x0006;
    pub const FLUSH: u16 = 0x0007;
    pub const READ: u16 = 0x0008;
    pub const WRITE: u16 = 0x0009;
    pub const LOCK: u16 = 0x000A;
    pub const IOCTL: u16 = 0x000B;
    pub const CANCEL: u16 = 0x000C;
    pub const ECHO: u16 = 0x000D;
    pub const QUERY_DIRECTORY: u16 = 0x000E;
    pub const CHANGE_NOTIFY: u16 = 0x000F;
    pub const QUERY_INFO: u16 = 0x0010;
    pub const SET_INFO: u16 = 0x0011;
    pub const OPLOCK_BREAK: u16 = 0x0012;
}

// ── NT status codes ────────────────────────────────────────────────────────

pub mod status {
    pub const SUCCESS: u32 = 0x0000_0000;
    pub const PENDING: u32 = 0x0000_0103;
    pub const BUFFER_OVERFLOW: u32 = 0x8000_0005;
    pub const NO_MORE_FILES: u32 = 0x8000_0006;
    pub const NOT_IMPLEMENTED: u32 = 0xC000_0002;
    pub const INFO_LENGTH_MISMATCH: u32 = 0xC000_0004;
    pub const INVALID_HANDLE: u32 = 0xC000_0008;
    pub const INVALID_DEVICE_REQUEST: u32 = 0xC000_0010;
    pub const END_OF_FILE: u32 = 0xC000_0011;
    pub const NO_SUCH_FILE: u32 = 0xC000_000F;
    pub const INVALID_PARAMETER: u32 = 0xC000_000D;
    pub const ACCESS_DENIED: u32 = 0xC000_0022;
    pub const OBJECT_NAME_NOT_FOUND: u32 = 0xC000_0034;
    pub const OBJECT_NAME_COLLISION: u32 = 0xC000_0035;
    pub const OBJECT_PATH_NOT_FOUND: u32 = 0xC000_003A;
    pub const OBJECT_PATH_SYNTAX_BAD: u32 = 0xC000_003B;
    pub const SHARING_VIOLATION: u32 = 0xC000_0043;
    pub const DISK_FULL: u32 = 0xC000_007F;
    pub const FILE_IS_A_DIRECTORY: u32 = 0xC000_00BA;
    pub const NOT_SUPPORTED: u32 = 0xC000_00BB;
    pub const NETWORK_NAME_DELETED: u32 = 0xC000_00C9;
    pub const BAD_NETWORK_NAME: u32 = 0xC000_00CC;
    pub const DIRECTORY_NOT_EMPTY: u32 = 0xC000_0101;
    pub const NOT_A_DIRECTORY: u32 = 0xC000_0103;
    pub const CANCELLED: u32 = 0xC000_0120;
    pub const FILE_CLOSED: u32 = 0xC000_0128;
    pub const LOGON_FAILURE: u32 = 0xC000_006D;
    pub const MORE_PROCESSING_REQUIRED: u32 = 0xC000_0016;
    pub const USER_SESSION_DELETED: u32 = 0xC000_0203;
    pub const MEDIA_WRITE_PROTECTED: u32 = 0xC000_00A2;
    pub const REQUEST_NOT_ACCEPTED: u32 = 0xC000_00D0;

    /// A one-line description, used to turn a server reply into a message a
    /// person can act on.
    pub fn describe(code: u32) -> &'static str {
        match code {
            SUCCESS => "OK",
            ACCESS_DENIED => "Access denied.",
            LOGON_FAILURE => "The server refused these credentials.",
            OBJECT_NAME_NOT_FOUND | NO_SUCH_FILE => "No such file or folder.",
            OBJECT_PATH_NOT_FOUND => "That folder doesn't exist.",
            OBJECT_NAME_COLLISION => "Something with that name already exists.",
            BAD_NETWORK_NAME => "The server has no share with that name.",
            NOT_A_DIRECTORY => "That path isn't a folder.",
            FILE_IS_A_DIRECTORY => "That path is a folder.",
            DIRECTORY_NOT_EMPTY => "That folder isn't empty.",
            SHARING_VIOLATION => "The file is open in another program.",
            DISK_FULL => "The server has run out of space.",
            MEDIA_WRITE_PROTECTED => "That share is read-only.",
            END_OF_FILE => "End of file.",
            NOT_SUPPORTED | NOT_IMPLEMENTED | INVALID_DEVICE_REQUEST => {
                "The server doesn't support that operation."
            }
            USER_SESSION_DELETED | NETWORK_NAME_DELETED | FILE_CLOSED => {
                "The connection was closed by the server."
            }
            INVALID_PARAMETER => "The server rejected the request.",
            _ => "The server reported an error.",
        }
    }
}

// ── dialects ───────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Dialect {
    Smb202,
    Smb210,
    Smb300,
    Smb302,
    Smb311,
}

impl Dialect {
    pub fn code(self) -> u16 {
        match self {
            Dialect::Smb202 => 0x0202,
            Dialect::Smb210 => 0x0210,
            Dialect::Smb300 => 0x0300,
            Dialect::Smb302 => 0x0302,
            Dialect::Smb311 => 0x0311,
        }
    }

    pub fn from_code(code: u16) -> Option<Dialect> {
        Some(match code {
            0x0202 => Dialect::Smb202,
            0x0210 => Dialect::Smb210,
            0x0300 => Dialect::Smb300,
            0x0302 => Dialect::Smb302,
            0x0311 => Dialect::Smb311,
            _ => return None,
        })
    }

    /// Newest first, so a client offer can be matched greedily.
    pub const ALL: [Dialect; 5] = [
        Dialect::Smb311,
        Dialect::Smb302,
        Dialect::Smb300,
        Dialect::Smb202,
        Dialect::Smb210,
    ];

    /// 3.x changed signing from HMAC-SHA256 to AES-CMAC and derives the
    /// signing key rather than using the session key directly.
    pub fn is_smb3(self) -> bool {
        self >= Dialect::Smb300
    }

    pub fn label(self) -> &'static str {
        match self {
            Dialect::Smb202 => "SMB 2.0.2",
            Dialect::Smb210 => "SMB 2.1",
            Dialect::Smb300 => "SMB 3.0",
            Dialect::Smb302 => "SMB 3.0.2",
            Dialect::Smb311 => "SMB 3.1.1",
        }
    }
}

// ── header flags and capabilities ──────────────────────────────────────────

pub mod flags {
    pub const SERVER_TO_REDIR: u32 = 0x0000_0001;
    pub const ASYNC_COMMAND: u32 = 0x0000_0002;
    pub const RELATED_OPERATIONS: u32 = 0x0000_0004;
    pub const SIGNED: u32 = 0x0000_0008;
    pub const PRIORITY_MASK: u32 = 0x0000_0070;
    pub const DFS_OPERATIONS: u32 = 0x1000_0000;
}

pub mod security_mode {
    pub const SIGNING_ENABLED: u16 = 0x0001;
    pub const SIGNING_REQUIRED: u16 = 0x0002;
}

pub mod capabilities {
    pub const DFS: u32 = 0x0000_0001;
    pub const LEASING: u32 = 0x0000_0002;
    pub const LARGE_MTU: u32 = 0x0000_0004;
    pub const MULTI_CHANNEL: u32 = 0x0000_0008;
    pub const PERSISTENT_HANDLES: u32 = 0x0000_0010;
    pub const DIRECTORY_LEASING: u32 = 0x0000_0020;
    pub const ENCRYPTION: u32 = 0x0000_0040;
}

// ── access masks, attributes, dispositions ─────────────────────────────────

pub mod access {
    pub const FILE_READ_DATA: u32 = 0x0000_0001;
    pub const FILE_WRITE_DATA: u32 = 0x0000_0002;
    pub const FILE_APPEND_DATA: u32 = 0x0000_0004;
    pub const FILE_READ_EA: u32 = 0x0000_0008;
    pub const FILE_WRITE_EA: u32 = 0x0000_0010;
    pub const FILE_EXECUTE: u32 = 0x0000_0020;
    pub const FILE_DELETE_CHILD: u32 = 0x0000_0040;
    pub const FILE_READ_ATTRIBUTES: u32 = 0x0000_0080;
    pub const FILE_WRITE_ATTRIBUTES: u32 = 0x0000_0100;
    pub const DELETE: u32 = 0x0001_0000;
    pub const READ_CONTROL: u32 = 0x0002_0000;
    pub const WRITE_DAC: u32 = 0x0004_0000;
    pub const WRITE_OWNER: u32 = 0x0008_0000;
    pub const SYNCHRONIZE: u32 = 0x0010_0000;
    pub const GENERIC_ALL: u32 = 0x1000_0000;
    pub const GENERIC_EXECUTE: u32 = 0x2000_0000;
    pub const GENERIC_WRITE: u32 = 0x4000_0000;
    pub const GENERIC_READ: u32 = 0x8000_0000;

    /// Everything a read-only opener needs.
    pub const READ_SET: u32 =
        FILE_READ_DATA | FILE_READ_EA | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
    /// Everything a writer needs, read included.
    pub const WRITE_SET: u32 = READ_SET
        | FILE_WRITE_DATA
        | FILE_APPEND_DATA
        | FILE_WRITE_EA
        | FILE_WRITE_ATTRIBUTES
        | DELETE;

    /// True when the mask asks for anything that would modify the file.
    pub fn is_write(mask: u32) -> bool {
        mask & (FILE_WRITE_DATA
            | FILE_APPEND_DATA
            | FILE_WRITE_EA
            | FILE_WRITE_ATTRIBUTES
            | DELETE
            | WRITE_DAC
            | WRITE_OWNER
            | GENERIC_WRITE
            | GENERIC_ALL)
            != 0
    }
}

pub mod attr {
    pub const READONLY: u32 = 0x0000_0001;
    pub const HIDDEN: u32 = 0x0000_0002;
    pub const SYSTEM: u32 = 0x0000_0004;
    pub const DIRECTORY: u32 = 0x0000_0010;
    pub const ARCHIVE: u32 = 0x0000_0020;
    pub const NORMAL: u32 = 0x0000_0080;
}

pub mod disposition {
    pub const SUPERSEDE: u32 = 0;
    pub const OPEN: u32 = 1;
    pub const CREATE: u32 = 2;
    pub const OPEN_IF: u32 = 3;
    pub const OVERWRITE: u32 = 4;
    pub const OVERWRITE_IF: u32 = 5;
}

pub mod create_action {
    pub const SUPERSEDED: u32 = 0;
    pub const OPENED: u32 = 1;
    pub const CREATED: u32 = 2;
    pub const OVERWRITTEN: u32 = 3;
}

pub mod options {
    pub const DIRECTORY_FILE: u32 = 0x0000_0001;
    pub const WRITE_THROUGH: u32 = 0x0000_0002;
    pub const NON_DIRECTORY_FILE: u32 = 0x0000_0040;
    pub const DELETE_ON_CLOSE: u32 = 0x0000_1000;
}

pub mod share_type {
    pub const DISK: u8 = 0x01;
    pub const PIPE: u8 = 0x02;
}

pub mod share_flags {
    pub const MANUAL_CACHING: u32 = 0x0000_0000;
}

pub mod fsctl {
    pub const DFS_GET_REFERRALS: u32 = 0x0006_0194;
    pub const VALIDATE_NEGOTIATE_INFO: u32 = 0x0014_0204;
    pub const SRV_COPYCHUNK: u32 = 0x0014_40F2;
    pub const SRV_COPYCHUNK_WRITE: u32 = 0x0014_80F2;
    pub const SRV_REQUEST_RESUME_KEY: u32 = 0x0014_0078;
    pub const QUERY_NETWORK_INTERFACE_INFO: u32 = 0x0014_FC00;
    /// Write a request and read its reply in one round trip — how Windows and
    /// macOS drive a named pipe.
    pub const PIPE_TRANSCEIVE: u32 = 0x0011_C017;
    pub const PIPE_WAIT: u32 = 0x0011_0018;
}

/// Information classes for `QUERY_DIRECTORY`.
pub mod dir_info {
    pub const DIRECTORY: u8 = 0x01;
    pub const FULL_DIRECTORY: u8 = 0x02;
    pub const BOTH_DIRECTORY: u8 = 0x03;
    pub const NAMES: u8 = 0x0C;
    pub const ID_BOTH_DIRECTORY: u8 = 0x25;
    pub const ID_FULL_DIRECTORY: u8 = 0x26;
}

/// Information classes for `QUERY_INFO`/`SET_INFO` with `InfoType == FILE`.
pub mod file_info {
    pub const BASIC: u8 = 4;
    pub const STANDARD: u8 = 5;
    pub const INTERNAL: u8 = 6;
    pub const EA: u8 = 7;
    pub const ACCESS: u8 = 8;
    pub const NAME: u8 = 9;
    pub const RENAME: u8 = 10;
    pub const DISPOSITION: u8 = 13;
    pub const POSITION: u8 = 14;
    pub const MODE: u8 = 16;
    pub const ALIGNMENT: u8 = 17;
    pub const ALL: u8 = 18;
    pub const ALLOCATION: u8 = 19;
    pub const END_OF_FILE: u8 = 20;
    pub const STREAM: u8 = 22;
    pub const COMPRESSION: u8 = 28;
    pub const NETWORK_OPEN: u8 = 34;
    pub const ATTRIBUTE_TAG: u8 = 35;
}

/// Information classes for `QUERY_INFO` with `InfoType == FILESYSTEM`.
pub mod fs_info {
    pub const VOLUME: u8 = 1;
    pub const SIZE: u8 = 3;
    pub const DEVICE: u8 = 4;
    pub const ATTRIBUTE: u8 = 5;
    pub const FULL_SIZE: u8 = 7;
    pub const OBJECT_ID: u8 = 8;
    pub const SECTOR_SIZE: u8 = 11;
}

pub mod info_type {
    pub const FILE: u8 = 0x01;
    pub const FILESYSTEM: u8 = 0x02;
    pub const SECURITY: u8 = 0x03;
    pub const QUOTA: u8 = 0x04;
}

// ── header ─────────────────────────────────────────────────────────────────

/// The SMB2 packet header, in its synchronous form.
///
/// The async form replaces `tree_id`/`reserved` with a 64-bit `AsyncId`. This
/// server never returns `STATUS_PENDING`, so it never needs to write one.
#[derive(Clone, Copy, Debug, Default)]
pub struct Header {
    pub credit_charge: u16,
    pub status: u32,
    pub command: u16,
    pub credits: u16,
    pub flags: u32,
    pub next_command: u32,
    pub message_id: u64,
    pub tree_id: u32,
    pub session_id: u64,
    pub signature: [u8; 16],
}

impl Header {
    pub fn parse(reader: &mut Reader<'_>) -> WireResult<Header> {
        let start = reader.position();
        let magic: [u8; 4] = reader.array()?;
        if magic != PROTOCOL_ID {
            return Err(super::wire::WireError::OutOfRange);
        }
        let _structure_size = reader.u16()?;
        let credit_charge = reader.u16()?;
        let status = reader.u32()?;
        let command = reader.u16()?;
        let credits = reader.u16()?;
        let flags = reader.u32()?;
        let next_command = reader.u32()?;
        let message_id = reader.u64()?;
        let _reserved = reader.u32()?;
        let tree_id = reader.u32()?;
        let session_id = reader.u64()?;
        let signature: [u8; 16] = reader.array()?;
        debug_assert_eq!(reader.position() - start, HEADER_SIZE);
        Ok(Header {
            credit_charge,
            status,
            command,
            credits,
            flags,
            next_command,
            message_id,
            tree_id,
            session_id,
            signature,
        })
    }

    pub fn write(&self, w: &mut Writer) {
        w.bytes(&PROTOCOL_ID)
            .u16(HEADER_SIZE as u16)
            .u16(self.credit_charge)
            .u32(self.status)
            .u16(self.command)
            .u16(self.credits)
            .u32(self.flags)
            .u32(self.next_command)
            .u64(self.message_id)
            .u32(0)
            .u32(self.tree_id)
            .u64(self.session_id)
            .bytes(&self.signature);
    }

    pub fn is_signed(&self) -> bool {
        self.flags & flags::SIGNED != 0
    }

    pub fn is_related(&self) -> bool {
        self.flags & flags::RELATED_OPERATIONS != 0
    }
}

/// Windows FILETIME (100 ns ticks since 1601) for a Unix timestamp in seconds
/// and nanoseconds. Every timestamp SMB2 carries uses this.
pub fn to_filetime(unix_secs: i64, nanos: u32) -> u64 {
    const EPOCH_DIFF: i64 = 11_644_473_600;
    let ticks = (unix_secs + EPOCH_DIFF)
        .saturating_mul(10_000_000)
        .saturating_add((nanos / 100) as i64);
    ticks.max(0) as u64
}

/// The inverse of [`to_filetime`], in milliseconds since the Unix epoch.
pub fn filetime_to_unix_ms(ticks: u64) -> i64 {
    if ticks == 0 {
        return 0;
    }
    (ticks / 10_000) as i64 - 11_644_473_600_000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_header_round_trips() {
        let header = Header {
            credit_charge: 1,
            status: status::SUCCESS,
            command: command::CREATE,
            credits: 8,
            flags: flags::SERVER_TO_REDIR | flags::SIGNED,
            next_command: 0,
            message_id: 42,
            tree_id: 7,
            session_id: 0xDEAD_BEEF,
            signature: [9u8; 16],
        };
        let mut w = Writer::new();
        header.write(&mut w);
        assert_eq!(w.len(), HEADER_SIZE);

        let buf = w.into_vec();
        let parsed = Header::parse(&mut Reader::new(&buf)).unwrap();
        assert_eq!(parsed.command, command::CREATE);
        assert_eq!(parsed.message_id, 42);
        assert_eq!(parsed.session_id, 0xDEAD_BEEF);
        assert_eq!(parsed.signature, [9u8; 16]);
        assert!(parsed.is_signed());
    }

    #[test]
    fn a_packet_that_is_not_smb2_is_rejected() {
        let buf = [0xFFu8; HEADER_SIZE];
        assert!(Header::parse(&mut Reader::new(&buf)).is_err());
    }

    #[test]
    fn filetime_round_trips_through_the_unix_epoch() {
        let ticks = to_filetime(1_709_627_400, 0);
        assert_eq!(filetime_to_unix_ms(ticks), 1_709_627_400_000);
        assert_eq!(filetime_to_unix_ms(0), 0);
    }

    #[test]
    fn dialects_order_newest_last_so_max_picks_the_best() {
        assert!(Dialect::Smb311 > Dialect::Smb202);
        assert!(Dialect::Smb300.is_smb3());
        assert!(!Dialect::Smb210.is_smb3());
        assert_eq!(Dialect::from_code(0x0311), Some(Dialect::Smb311));
        assert_eq!(Dialect::from_code(0x0111), None);
    }
}
