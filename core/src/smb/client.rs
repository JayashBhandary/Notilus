//! An SMB2 client.
//!
//! Deliberately synchronous and single-connection: one TCP socket, one session,
//! one tree. That is what a mounted share in a file manager is, and it keeps
//! the request/response bookkeeping — message ids, signing, credits — in one
//! obvious place.
//!
//! Handles are returned to the caller rather than hidden behind a
//! read-the-whole-file call, so a download can be streamed and a large upload
//! can be sent in pieces.

use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::crypto;
use super::ntlm;
use super::proto::*;
use super::spnego;
use super::wire::{string_to_utf16le, utf16le_to_string, Reader, Writer};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const IO_TIMEOUT: Duration = Duration::from_secs(60);

/// Largest single read or write the client will issue. Servers advertise their
/// own limits in NEGOTIATE and the smaller of the two wins.
const CHUNK: u32 = 1024 * 1024;

#[derive(Debug)]
pub struct ClientError {
    pub message: String,
    /// The NT status the server returned, when the failure came from it.
    pub status: u32,
}

impl ClientError {
    pub fn local(message: impl Into<String>) -> ClientError {
        ClientError {
            message: message.into(),
            status: 0,
        }
    }

    fn from_status(code: u32, context: &str) -> ClientError {
        ClientError {
            message: format!("{context}: {}", status::describe(code)),
            status: code,
        }
    }

    /// True when the server rejected the credentials rather than the request.
    pub fn is_auth_failure(&self) -> bool {
        matches!(self.status, status::LOGON_FAILURE | status::ACCESS_DENIED)
    }

    pub fn is_not_found(&self) -> bool {
        matches!(
            self.status,
            status::OBJECT_NAME_NOT_FOUND
                | status::OBJECT_PATH_NOT_FOUND
                | status::NO_SUCH_FILE
        )
    }
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

type Result<T> = std::result::Result<T, ClientError>;

#[derive(Clone, Debug)]
pub struct ClientConfig {
    pub host: String,
    pub port: u16,
    pub share: String,
    pub username: String,
    pub domain: String,
    pub password: String,
}

/// One share a server publishes.
#[derive(Clone, Debug)]
pub struct ShareInfo {
    pub name: String,
    pub comment: String,
    /// True for `IPC$` and the administrative `C$`-style shares, which are not
    /// somewhere a person browses to.
    pub hidden: bool,
}

/// One entry from a directory listing, or one file's metadata.
#[derive(Clone, Debug)]
pub struct FileInfo {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified_ms: i64,
    pub created_ms: i64,
    pub attributes: u32,
}

/// An open file or directory on the server.
#[derive(Clone, Copy, Debug)]
pub struct FileHandle {
    persistent: u64,
    volatile: u64,
}

impl FileHandle {
    fn write(&self, w: &mut Writer) {
        w.u64(self.persistent).u64(self.volatile);
    }
}

pub struct Client {
    stream: TcpStream,
    dialect: Dialect,
    session_id: u64,
    tree_id: u32,
    signing_key: Option<[u8; 16]>,
    message_id: u64,
    max_read: u32,
    max_write: u32,
    server_name: String,
}

impl Client {
    /// Connects, authenticates and attaches to the configured share.
    pub fn connect(config: &ClientConfig) -> Result<Client> {
        if config.host.trim().is_empty() {
            return Err(ClientError::local("This connection has no server name."));
        }
        if config.share.trim().is_empty() {
            return Err(ClientError::local("This connection has no share name."));
        }

        let port = if config.port == 0 { 445 } else { config.port };
        let address = format!("{}:{}", config.host, port);
        let target = address
            .to_socket_addrs()
            .map_err(|e| ClientError::local(format!("Can't look up {}: {e}", config.host)))?
            .next()
            .ok_or_else(|| {
                ClientError::local(format!("{} didn't resolve to an address.", config.host))
            })?;

        let stream = TcpStream::connect_timeout(&target, CONNECT_TIMEOUT).map_err(|e| {
            ClientError::local(match e.kind() {
                ErrorKind::TimedOut => format!("{address} didn't answer."),
                ErrorKind::ConnectionRefused => {
                    format!("{address} refused the connection — is file sharing on?")
                }
                _ => format!("Can't reach {address}: {e}"),
            })
        })?;
        let _ = stream.set_nodelay(true);
        stream
            .set_read_timeout(Some(IO_TIMEOUT))
            .and_then(|_| stream.set_write_timeout(Some(IO_TIMEOUT)))
            .map_err(|e| ClientError::local(format!("Couldn't configure the socket: {e}")))?;

        let mut client = Client {
            stream,
            dialect: Dialect::Smb202,
            session_id: 0,
            tree_id: 0,
            signing_key: None,
            message_id: 0,
            max_read: CHUNK,
            max_write: CHUNK,
            server_name: config.host.clone(),
        };

        let preauth = client.negotiate()?;
        client.authenticate(config, preauth)?;
        client.tree_connect(&config.share)?;
        Ok(client)
    }

    pub fn dialect_label(&self) -> &'static str {
        self.dialect.label()
    }

    pub fn disconnect(&mut self) {
        // Best effort: the socket is about to close either way.
        if self.tree_id != 0 {
            let mut w = Writer::with_capacity(4);
            w.u16(4).u16(0);
            let _ = self.request(command::TREE_DISCONNECT, w.as_slice());
        }
        if self.session_id != 0 {
            let mut w = Writer::with_capacity(4);
            w.u16(4).u16(0);
            let _ = self.request(command::LOGOFF, w.as_slice());
        }
        let _ = self.stream.shutdown(Shutdown::Both);
    }

    // ── transport ──────────────────────────────────────────────────────────

    /// Sends one request and returns the response header and body.
    ///
    /// A non-success status is *not* an error here: several callers treat
    /// specific codes (`NO_MORE_FILES`, `OBJECT_NAME_NOT_FOUND`) as ordinary
    /// outcomes, so the decision belongs to them.
    fn request(&mut self, command: u16, body: &[u8]) -> Result<(Header, Vec<u8>)> {
        let packet = self.frame(command, body);
        self.send(&packet)?;
        let response = self.receive()?;

        let mut reader = Reader::new(&response);
        let header = Header::parse(&mut reader)
            .map_err(|_| ClientError::local("The server sent a malformed reply."))?;

        if let Some(key) = self.signing_key {
            if header.is_signed() && !crypto::verify_packet(self.dialect, &key, &response) {
                return Err(ClientError::local(
                    "The server's reply failed its signature check — the \
                     connection may be being intercepted.",
                ));
            }
        }
        let payload = response.get(HEADER_SIZE..).unwrap_or_default().to_vec();
        Ok((header, payload))
    }

    /// Like [`request`], but turns any non-success status into an error.
    fn require(&mut self, command: u16, body: &[u8], context: &str) -> Result<Vec<u8>> {
        let (header, payload) = self.request(command, body)?;
        if header.status != status::SUCCESS {
            return Err(ClientError::from_status(header.status, context));
        }
        Ok(payload)
    }

    fn frame(&mut self, command: u16, body: &[u8]) -> Vec<u8> {
        self.message_id += 1;
        let header = Header {
            credit_charge: 1,
            status: 0,
            command,
            credits: 64,
            flags: 0,
            next_command: 0,
            message_id: self.message_id,
            tree_id: self.tree_id,
            session_id: self.session_id,
            signature: [0u8; 16],
        };
        let mut w = Writer::with_capacity(HEADER_SIZE + body.len());
        header.write(&mut w);
        w.bytes(body);
        let mut packet = w.into_vec();
        if let Some(key) = self.signing_key {
            crypto::apply_signature(self.dialect, &key, &mut packet);
        }
        packet
    }

    fn send(&mut self, packet: &[u8]) -> Result<()> {
        let length = packet.len() as u32;
        let framing = [0u8, (length >> 16) as u8, (length >> 8) as u8, length as u8];
        self.stream
            .write_all(&framing)
            .and_then(|_| self.stream.write_all(packet))
            .and_then(|_| self.stream.flush())
            .map_err(|e| ClientError::local(format!("The connection dropped: {e}")))
    }

    fn receive(&mut self) -> Result<Vec<u8>> {
        let mut framing = [0u8; NBSS_HEADER];
        self.stream
            .read_exact(&mut framing)
            .map_err(|e| ClientError::local(format!("The connection dropped: {e}")))?;
        let length = u32::from_be_bytes([0, framing[1], framing[2], framing[3]]) as usize;
        if length < HEADER_SIZE || length > MAX_PACKET {
            return Err(ClientError::local("The server sent an oversized reply."));
        }
        let mut body = vec![0u8; length];
        self.stream
            .read_exact(&mut body)
            .map_err(|e| ClientError::local(format!("The connection dropped: {e}")))?;
        Ok(body)
    }

    // ── handshake ──────────────────────────────────────────────────────────

    /// Negotiates a dialect and returns the preauth-integrity hash, which is
    /// all zeroes below 3.1.1.
    fn negotiate(&mut self) -> Result<[u8; 64]> {
        let client_guid: [u8; 16] = crypto::random_array()
            .map_err(|e| ClientError::local(format!("Couldn't start a session: {e}")))?;
        let salt: [u8; 32] = crypto::random_array()
            .map_err(|e| ClientError::local(format!("Couldn't start a session: {e}")))?;

        let dialects = [
            Dialect::Smb202,
            Dialect::Smb210,
            Dialect::Smb300,
            Dialect::Smb302,
            Dialect::Smb311,
        ];

        let mut w = Writer::with_capacity(96);
        w.u16(36)
            .u16(dialects.len() as u16)
            .u16(security_mode::SIGNING_ENABLED)
            .u16(0)
            .u32(capabilities::LARGE_MTU)
            .bytes(&client_guid);
        let context_offset_at = w.len();
        w.u32(0).u16(1).u16(0);
        for dialect in dialects {
            w.u16(dialect.code());
        }
        w.align_to(8);
        let contexts_at = HEADER_SIZE + w.len();
        w.patch_u32(context_offset_at, contexts_at as u32);
        // SMB2_PREAUTH_INTEGRITY_CAPABILITIES — required to offer 3.1.1.
        w.u16(1)
            .u16(6 + salt.len() as u16)
            .u32(0)
            .u16(1)
            .u16(salt.len() as u16)
            .u16(1) // SHA-512
            .bytes(&salt);

        let body = w.into_vec();
        let packet = self.frame(command::NEGOTIATE, &body);
        self.send(&packet)?;
        let response = self.receive()?;

        let mut reader = Reader::new(&response);
        let header = Header::parse(&mut reader)
            .map_err(|_| ClientError::local("The server sent a malformed reply."))?;
        if header.status != status::SUCCESS {
            return Err(ClientError::from_status(
                header.status,
                "The server refused to negotiate",
            ));
        }

        let mut r = Reader::new(response.get(HEADER_SIZE..).unwrap_or_default());
        let _structure_size = r.u16().map_err(|_| malformed())?;
        let _security_mode = r.u16().map_err(|_| malformed())?;
        let dialect_code = r.u16().map_err(|_| malformed())?;
        let _context_count = r.u16().map_err(|_| malformed())?;
        let _server_guid: [u8; 16] = r.array().map_err(|_| malformed())?;
        let _capabilities = r.u32().map_err(|_| malformed())?;
        let _max_transact = r.u32().map_err(|_| malformed())?;
        let max_read = r.u32().map_err(|_| malformed())?;
        let max_write = r.u32().map_err(|_| malformed())?;

        self.dialect = Dialect::from_code(dialect_code).ok_or_else(|| {
            ClientError::local(
                "The server speaks a version of SMB this app doesn't — SMB1 \
                 servers aren't supported.",
            )
        })?;
        self.max_read = max_read.clamp(64 * 1024, CHUNK);
        self.max_write = max_write.clamp(64 * 1024, CHUNK);

        if self.dialect == Dialect::Smb311 {
            let after_request = crypto::extend_preauth(&[0u8; 64], &packet);
            Ok(crypto::extend_preauth(&after_request, &response))
        } else {
            Ok([0u8; 64])
        }
    }

    fn authenticate(&mut self, config: &ClientConfig, preauth: [u8; 64]) -> Result<()> {
        let workstation = "NOTILUS";
        let negotiate = ntlm::build_negotiate("", workstation);
        let init = spnego::client_init(&negotiate);

        let (header, payload, request_packet, response_packet) =
            self.session_setup_round(&init)?;
        if header.status != status::MORE_PROCESSING_REQUIRED {
            return Err(ClientError::from_status(
                header.status,
                "The server refused to start a session",
            ));
        }
        self.session_id = header.session_id;

        let mut preauth = if self.dialect == Dialect::Smb311 {
            let after_request = crypto::extend_preauth(&preauth, &request_packet);
            crypto::extend_preauth(&after_request, &response_packet)
        } else {
            preauth
        };

        let blob = session_setup_blob(&payload)?;
        let token = spnego::extract_ntlm_token(&blob)
            .ok_or_else(|| ClientError::local("The server didn't offer NTLM."))?;
        let challenge = ntlm::parse_challenge(token)
            .map_err(|e| ClientError::local(format!("The server's challenge was invalid: {e}")))?;

        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| to_filetime(d.as_secs() as i64, d.subsec_nanos()))
            .unwrap_or(0);
        let domain = if config.domain.trim().is_empty() {
            challenge.target_name.clone()
        } else {
            config.domain.clone()
        };
        let (mut authenticate, session_key) = ntlm::build_authenticate(
            &challenge,
            &config.username,
            &domain,
            &config.password,
            workstation,
            timestamp,
        )
        .map_err(|e| ClientError::local(format!("Couldn't sign in: {e}")))?;
        // An anonymous message carries no MIC — there is no key to compute one
        // with, and the field isn't present in it.
        if !config.username.trim().is_empty() {
            ntlm::seal_mic(&mut authenticate, &session_key, &negotiate, token);
        }

        let response_token =
            spnego::neg_token_resp(spnego::NegState::AcceptIncomplete, Some(&authenticate), false);
        let (header, _, request_packet, _) = self.session_setup_round(&response_token)?;

        if self.dialect == Dialect::Smb311 {
            preauth = crypto::extend_preauth(&preauth, &request_packet);
        }
        if header.status != status::SUCCESS {
            return Err(ClientError::from_status(
                header.status,
                format!("The server refused the sign-in for \"{}\"", config.username).as_str(),
            ));
        }
        self.session_id = header.session_id;
        // A guest session has no key, so nothing it sends can be signed — and
        // the server knows not to ask, having set SMB2_SESSION_FLAG_IS_GUEST.
        self.signing_key = if config.username.trim().is_empty() {
            None
        } else {
            Some(crypto::signing_key(self.dialect, &session_key, &preauth))
        };
        Ok(())
    }

    /// One SESSION_SETUP exchange, returning the raw packets as well so the
    /// preauth hash can be extended over exactly what went on the wire.
    fn session_setup_round(
        &mut self,
        token: &[u8],
    ) -> Result<(Header, Vec<u8>, Vec<u8>, Vec<u8>)> {
        let mut w = Writer::with_capacity(24 + token.len());
        w.u16(25)
            .u8(0)
            .u8(security_mode::SIGNING_ENABLED as u8)
            .u32(0)
            .u32(0);
        let offset_at = w.len();
        w.u16(0).u16(token.len() as u16).u64(0);
        let offset = HEADER_SIZE + w.len();
        w.bytes(token);
        w.patch_u16(offset_at, offset as u16);

        let packet = self.frame(command::SESSION_SETUP, w.as_slice());
        self.send(&packet)?;
        let response = self.receive()?;
        let mut reader = Reader::new(&response);
        let header = Header::parse(&mut reader)
            .map_err(|_| ClientError::local("The server sent a malformed reply."))?;
        let payload = response.get(HEADER_SIZE..).unwrap_or_default().to_vec();
        Ok((header, payload, packet, response))
    }

    fn tree_connect(&mut self, share: &str) -> Result<()> {
        let path = format!("\\\\{}\\{}", self.server_name, share);
        let encoded = string_to_utf16le(&path);

        let mut w = Writer::with_capacity(8 + encoded.len());
        w.u16(9).u16(0);
        let offset_at = w.len();
        w.u16(0).u16(encoded.len() as u16);
        let offset = HEADER_SIZE + w.len();
        w.bytes(&encoded);
        w.patch_u16(offset_at, offset as u16);

        let body = w.into_vec();
        let packet = self.frame(command::TREE_CONNECT, &body);
        self.send(&packet)?;
        let response = self.receive()?;
        let mut reader = Reader::new(&response);
        let header = Header::parse(&mut reader)
            .map_err(|_| ClientError::local("The server sent a malformed reply."))?;
        if header.status != status::SUCCESS {
            return Err(ClientError::from_status(
                header.status,
                &format!("Couldn't open the share \"{share}\""),
            ));
        }
        self.tree_id = header.tree_id;
        Ok(())
    }
}

fn malformed() -> ClientError {
    ClientError::local("The server sent a malformed reply.")
}

/// The security blob out of a SESSION_SETUP response body.
fn session_setup_blob(payload: &[u8]) -> Result<Vec<u8>> {
    let mut r = Reader::new(payload);
    let _structure_size = r.u16().map_err(|_| malformed())?;
    let _session_flags = r.u16().map_err(|_| malformed())?;
    let offset = r.u16().map_err(|_| malformed())? as usize;
    let length = r.u16().map_err(|_| malformed())? as usize;
    let start = offset.checked_sub(HEADER_SIZE).ok_or_else(malformed)?;
    Reader::new(payload)
        .slice_at(start, length)
        .map(|s| s.to_vec())
        .map_err(|_| malformed())
}

// ── file operations ────────────────────────────────────────────────────────

impl Client {
    /// Opens a path, returning the handle and the metadata the CREATE response
    /// already carries — which is why `stat` needs no second round trip.
    pub fn create(
        &mut self,
        path: &str,
        desired_access: u32,
        create_disposition: u32,
        create_options: u32,
    ) -> Result<(FileHandle, FileInfo)> {
        let name = path.trim_matches(['\\', '/']).replace('/', "\\");
        let encoded = string_to_utf16le(&name);

        let mut w = Writer::with_capacity(64 + encoded.len());
        w.u16(57)
            .u8(0)
            .u8(0) // no oplock
            .u32(2) // SMB2_IMPERSONATION_IMPERSONATION
            .u64(0)
            .u64(0)
            .u32(desired_access)
            .u32(attr::NORMAL)
            // Sharing everything: a file manager that locked other readers out
            // would be a worse neighbour than the OS itself.
            .u32(0x07)
            .u32(create_disposition)
            .u32(create_options);
        let name_offset_at = w.len();
        w.u16(0).u16(encoded.len() as u16).u32(0).u32(0);
        let name_offset = HEADER_SIZE + w.len();
        if encoded.is_empty() {
            // A zero-length name still needs a byte of buffer.
            w.u8(0);
        } else {
            w.bytes(&encoded);
        }
        w.patch_u16(name_offset_at, name_offset as u16);

        let body = w.into_vec();
        let payload = self.require(
            command::CREATE,
            &body,
            &format!("Couldn't open \"{}\"", display_name(&name)),
        )?;

        let mut r = Reader::new(&payload);
        let _structure_size = r.u16().map_err(|_| malformed())?;
        let _oplock = r.u8().map_err(|_| malformed())?;
        let _flags = r.u8().map_err(|_| malformed())?;
        let _action = r.u32().map_err(|_| malformed())?;
        let created = r.u64().map_err(|_| malformed())?;
        let _accessed = r.u64().map_err(|_| malformed())?;
        let modified = r.u64().map_err(|_| malformed())?;
        let _changed = r.u64().map_err(|_| malformed())?;
        let _allocated = r.u64().map_err(|_| malformed())?;
        let size = r.u64().map_err(|_| malformed())?;
        let attributes = r.u32().map_err(|_| malformed())?;
        let _reserved = r.u32().map_err(|_| malformed())?;
        let persistent = r.u64().map_err(|_| malformed())?;
        let volatile = r.u64().map_err(|_| malformed())?;

        let is_dir = attributes & attr::DIRECTORY != 0;
        Ok((
            FileHandle {
                persistent,
                volatile,
            },
            FileInfo {
                name: name
                    .rsplit('\\')
                    .next()
                    .unwrap_or_default()
                    .to_string(),
                is_dir,
                size: if is_dir { 0 } else { size },
                modified_ms: filetime_to_unix_ms(modified),
                created_ms: filetime_to_unix_ms(created),
                attributes,
            },
        ))
    }

    pub fn close(&mut self, handle: FileHandle) -> Result<()> {
        let mut w = Writer::with_capacity(24);
        w.u16(24).u16(0).u32(0);
        handle.write(&mut w);
        let body = w.into_vec();
        self.require(command::CLOSE, &body, "Couldn't close the file")?;
        Ok(())
    }

    /// Closes a handle without caring whether it worked — for cleanup paths
    /// where the original error is the one worth reporting.
    fn close_quietly(&mut self, handle: FileHandle) {
        let _ = self.close(handle);
    }

    /// Metadata for one path, or `None` when nothing is there.
    pub fn stat(&mut self, path: &str) -> Result<Option<FileInfo>> {
        match self.create(
            path,
            access::FILE_READ_ATTRIBUTES | access::SYNCHRONIZE,
            disposition::OPEN,
            0,
        ) {
            Ok((handle, mut info)) => {
                self.close_quietly(handle);
                if info.name.is_empty() {
                    info.name = path
                        .trim_matches(['\\', '/'])
                        .rsplit(['\\', '/'])
                        .next()
                        .unwrap_or_default()
                        .to_string();
                }
                Ok(Some(info))
            }
            Err(e) if e.is_not_found() => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Everything directly inside `path`.
    pub fn list(&mut self, path: &str) -> Result<Vec<FileInfo>> {
        let (handle, _) = self.create(
            path,
            access::FILE_READ_DATA | access::FILE_READ_ATTRIBUTES | access::SYNCHRONIZE,
            disposition::OPEN,
            options::DIRECTORY_FILE,
        )?;

        let mut out = Vec::new();
        let mut first = true;
        loop {
            let pattern = string_to_utf16le("*");
            let mut w = Writer::with_capacity(40);
            w.u16(33)
                .u8(dir_info::ID_BOTH_DIRECTORY)
                .u8(if first { 0x01 } else { 0x00 }) // RESTART_SCANS
                .u32(0);
            handle.write(&mut w);
            let offset_at = w.len();
            w.u16(0).u16(pattern.len() as u16).u32(64 * 1024);
            let offset = HEADER_SIZE + w.len();
            w.bytes(&pattern);
            w.patch_u16(offset_at, offset as u16);
            first = false;

            let body = w.into_vec();
            let (header, payload) = match self.request(command::QUERY_DIRECTORY, &body) {
                Ok(response) => response,
                Err(e) => {
                    self.close_quietly(handle);
                    return Err(e);
                }
            };
            // Both codes mean "that's all", and which one arrives depends on
            // whether the folder was empty to begin with.
            if header.status == status::NO_MORE_FILES
                || header.status == status::NO_SUCH_FILE
            {
                break;
            }
            if header.status != status::SUCCESS {
                self.close_quietly(handle);
                return Err(ClientError::from_status(
                    header.status,
                    &format!("Couldn't list \"{}\"", display_name(path)),
                ));
            }
            match parse_directory_page(&payload) {
                Ok(page) if page.is_empty() => break,
                Ok(mut page) => out.append(&mut page),
                Err(e) => {
                    self.close_quietly(handle);
                    return Err(e);
                }
            }
        }
        self.close_quietly(handle);

        out.retain(|entry| entry.name != "." && entry.name != "..");
        Ok(out)
    }

    pub fn open_read(&mut self, path: &str) -> Result<(FileHandle, FileInfo)> {
        self.create(
            path,
            access::READ_SET,
            disposition::OPEN,
            options::NON_DIRECTORY_FILE,
        )
    }

    /// Opens for writing, creating the file or truncating an existing one.
    pub fn open_write(&mut self, path: &str, truncate: bool) -> Result<FileHandle> {
        let disposition = if truncate {
            disposition::OVERWRITE_IF
        } else {
            disposition::OPEN_IF
        };
        let (handle, _) = self.create(
            path,
            access::WRITE_SET,
            disposition,
            options::NON_DIRECTORY_FILE,
        )?;
        Ok(handle)
    }

    /// Reads up to `length` bytes. A short result means end of file.
    pub fn read_at(&mut self, handle: FileHandle, offset: u64, length: u32) -> Result<Vec<u8>> {
        let want = length.min(self.max_read);
        let mut w = Writer::with_capacity(48);
        w.u16(49).u8(0).u8(0).u32(want).u64(offset);
        handle.write(&mut w);
        w.u32(0) // MinimumCount — a short read is fine
            .u32(0)
            .u32(0)
            .u16(0)
            .u16(0)
            .u8(0);

        let body = w.into_vec();
        let (header, payload) = self.request(command::READ, &body)?;
        if header.status == status::END_OF_FILE {
            return Ok(Vec::new());
        }
        if header.status != status::SUCCESS {
            return Err(ClientError::from_status(header.status, "Couldn't read"));
        }

        let mut r = Reader::new(&payload);
        let _structure_size = r.u16().map_err(|_| malformed())?;
        let data_offset = r.u8().map_err(|_| malformed())? as usize;
        let _reserved = r.u8().map_err(|_| malformed())?;
        let data_length = r.u32().map_err(|_| malformed())? as usize;

        let start = data_offset.checked_sub(HEADER_SIZE).ok_or_else(malformed)?;
        Reader::new(&payload)
            .slice_at(start, data_length)
            .map(|s| s.to_vec())
            .map_err(|_| malformed())
    }

    /// Writes at `offset`, returning how many bytes the server took.
    pub fn write_at(&mut self, handle: FileHandle, offset: u64, data: &[u8]) -> Result<u32> {
        let take = data.len().min(self.max_write as usize);
        let chunk = &data[..take];

        let mut w = Writer::with_capacity(48 + chunk.len());
        w.u16(49);
        let offset_at = w.len();
        w.u16(0).u32(chunk.len() as u32).u64(offset);
        handle.write(&mut w);
        w.u32(0).u32(0).u16(0).u16(0).u32(0);
        let data_offset = HEADER_SIZE + w.len();
        w.bytes(chunk);
        w.patch_u16(offset_at, data_offset as u16);

        let body = w.into_vec();
        let payload = self.require(command::WRITE, &body, "Couldn't write")?;
        let mut r = Reader::new(&payload);
        let _structure_size = r.u16().map_err(|_| malformed())?;
        let _reserved = r.u16().map_err(|_| malformed())?;
        r.u32().map_err(|_| malformed())
    }

    pub fn create_directory(&mut self, path: &str) -> Result<()> {
        let (handle, _) = self.create(
            path,
            access::WRITE_SET,
            disposition::CREATE,
            options::DIRECTORY_FILE,
        )?;
        self.close(handle)
    }

    pub fn delete(&mut self, path: &str, is_dir: bool) -> Result<()> {
        let options = options::DELETE_ON_CLOSE
            | if is_dir {
                options::DIRECTORY_FILE
            } else {
                options::NON_DIRECTORY_FILE
            };
        let (handle, _) = self.create(
            path,
            access::DELETE | access::SYNCHRONIZE,
            disposition::OPEN,
            options,
        )?;
        // The unlink happens at close, so its status is the one that matters.
        self.close(handle)
    }

    /// Renames or moves within the share. `to` is a share-relative path.
    pub fn rename(&mut self, from: &str, to: &str, replace: bool) -> Result<()> {
        let (handle, info) = self.create(
            from,
            access::DELETE | access::SYNCHRONIZE | access::FILE_READ_ATTRIBUTES,
            disposition::OPEN,
            0,
        )?;
        let _ = info;

        let target = string_to_utf16le(&to.trim_matches(['\\', '/']).replace('/', "\\"));
        let mut input = Writer::with_capacity(24 + target.len());
        input
            .u8(replace as u8)
            .zeros(7)
            .u64(0) // RootDirectory: the path is share-relative
            .u32(target.len() as u32)
            .bytes(&target);
        let input = input.into_vec();

        let mut w = Writer::with_capacity(40 + input.len());
        w.u16(33)
            .u8(info_type::FILE)
            .u8(file_info::RENAME)
            .u32(input.len() as u32);
        let offset_at = w.len();
        w.u16(0).u16(0).u32(0);
        handle.write(&mut w);
        let offset = HEADER_SIZE + w.len();
        w.bytes(&input);
        w.patch_u16(offset_at, offset as u16);

        let body = w.into_vec();
        let result = self.require(
            command::SET_INFO,
            &body,
            &format!("Couldn't rename \"{}\"", display_name(from)),
        );
        self.close_quietly(handle);
        result.map(|_| ())
    }

    /// Copies a file inside the share.
    ///
    /// Tries the server-side copy first — the bytes never cross the network —
    /// and falls back to reading and writing them through this machine when the
    /// server doesn't support it.
    pub fn copy_within(&mut self, from: &str, to: &str) -> Result<u64> {
        let (source, info) = self.open_read(from)?;
        let target = match self.open_write(to, true) {
            Ok(handle) => handle,
            Err(e) => {
                self.close_quietly(source);
                return Err(e);
            }
        };

        let result = self
            .server_side_copy(source, target, info.size)
            .or_else(|e| {
                if e.status == status::NOT_SUPPORTED || e.status == status::INVALID_DEVICE_REQUEST
                {
                    self.stream_copy(source, target)
                } else {
                    Err(e)
                }
            });

        self.close_quietly(source);
        self.close_quietly(target);
        result
    }

    fn server_side_copy(
        &mut self,
        source: FileHandle,
        target: FileHandle,
        size: u64,
    ) -> Result<u64> {
        let resume = self.ioctl(source, fsctl::SRV_REQUEST_RESUME_KEY, &[])?;
        if resume.len() < 24 {
            return Err(ClientError::from_status(
                status::NOT_SUPPORTED,
                "Server-side copy",
            ));
        }

        // One megabyte a chunk, and at most 16 chunks a request, which is what
        // the protocol allows every server to accept.
        const CHUNK_BYTES: u64 = 1024 * 1024;
        const CHUNKS_PER_CALL: usize = 16;

        let mut copied = 0u64;
        while copied < size {
            let mut input = Writer::with_capacity(32 + CHUNKS_PER_CALL * 24);
            input.bytes(&resume[..24]);
            let count_at = input.len();
            input.u32(0).u32(0);

            let mut chunks = 0u32;
            while (chunks as usize) < CHUNKS_PER_CALL && copied < size {
                let length = CHUNK_BYTES.min(size - copied) as u32;
                input.u64(copied).u64(copied).u32(length).u32(0);
                copied += length as u64;
                chunks += 1;
            }
            input.patch_u32(count_at, chunks);

            let body = input.into_vec();
            self.ioctl(target, fsctl::SRV_COPYCHUNK, &body)?;
        }
        Ok(copied)
    }

    fn stream_copy(&mut self, source: FileHandle, target: FileHandle) -> Result<u64> {
        let mut offset = 0u64;
        loop {
            let chunk = self.read_at(source, offset, self.max_read)?;
            if chunk.is_empty() {
                return Ok(offset);
            }
            let mut written = 0usize;
            while written < chunk.len() {
                let took = self.write_at(target, offset + written as u64, &chunk[written..])?;
                if took == 0 {
                    return Err(ClientError::local("The server stopped accepting data."));
                }
                written += took as usize;
            }
            offset += chunk.len() as u64;
        }
    }

    fn ioctl(&mut self, handle: FileHandle, control_code: u32, input: &[u8]) -> Result<Vec<u8>> {
        let mut w = Writer::with_capacity(64 + input.len());
        w.u16(57).u16(0).u32(control_code);
        handle.write(&mut w);
        let input_offset_at = w.len();
        w.u32(0)
            .u32(input.len() as u32)
            .u32(0)
            .u32(0)
            .u32(0)
            .u32(64 * 1024)
            .u32(0x0000_0001) // SMB2_0_IOCTL_IS_FSCTL
            .u32(0);
        let input_offset = HEADER_SIZE + w.len();
        if input.is_empty() {
            w.u8(0);
        } else {
            w.bytes(input);
        }
        w.patch_u32(input_offset_at, input_offset as u32);

        let body = w.into_vec();
        let (header, payload) = self.request(command::IOCTL, &body)?;
        if header.status != status::SUCCESS {
            return Err(ClientError::from_status(header.status, "The server refused"));
        }

        let mut r = Reader::new(&payload);
        let _structure_size = r.u16().map_err(|_| malformed())?;
        let _reserved = r.u16().map_err(|_| malformed())?;
        let _control_code = r.u32().map_err(|_| malformed())?;
        r.skip(16).map_err(|_| malformed())?;
        let _input_offset = r.u32().map_err(|_| malformed())?;
        let _input_count = r.u32().map_err(|_| malformed())?;
        let output_offset = r.u32().map_err(|_| malformed())? as usize;
        let output_count = r.u32().map_err(|_| malformed())? as usize;

        if output_count == 0 {
            return Ok(Vec::new());
        }
        let start = output_offset.checked_sub(HEADER_SIZE).ok_or_else(malformed)?;
        Reader::new(&payload)
            .slice_at(start, output_count)
            .map(|s| s.to_vec())
            .map_err(|_| malformed())
    }
}

/// Parses one page of `FileIdBothDirectoryInformation` entries.
fn parse_directory_page(payload: &[u8]) -> Result<Vec<FileInfo>> {
    let mut r = Reader::new(payload);
    let _structure_size = r.u16().map_err(|_| malformed())?;
    let offset = r.u16().map_err(|_| malformed())? as usize;
    let length = r.u32().map_err(|_| malformed())? as usize;

    let start = offset.checked_sub(HEADER_SIZE).ok_or_else(malformed)?;
    let buffer = Reader::new(payload)
        .slice_at(start, length)
        .map_err(|_| malformed())?;

    let mut out = Vec::new();
    let mut at = 0usize;
    loop {
        let reader = Reader::new(buffer);
        let Ok(fixed) = reader.slice_at(at, 104) else {
            break;
        };
        let next = u32::from_le_bytes([fixed[0], fixed[1], fixed[2], fixed[3]]) as usize;
        let created = u64::from_le_bytes(fixed[8..16].try_into().unwrap_or_default());
        let modified = u64::from_le_bytes(fixed[24..32].try_into().unwrap_or_default());
        let size = u64::from_le_bytes(fixed[40..48].try_into().unwrap_or_default());
        let attributes = u32::from_le_bytes([fixed[56], fixed[57], fixed[58], fixed[59]]);
        let name_length =
            u32::from_le_bytes([fixed[60], fixed[61], fixed[62], fixed[63]]) as usize;

        let Ok(raw) = reader.slice_at(at + 104, name_length) else {
            break;
        };
        let name = utf16le_to_string(raw).unwrap_or_default();
        let is_dir = attributes & attr::DIRECTORY != 0;
        if !name.is_empty() {
            out.push(FileInfo {
                name,
                is_dir,
                size: if is_dir { 0 } else { size },
                modified_ms: filetime_to_unix_ms(modified),
                created_ms: filetime_to_unix_ms(created),
                attributes,
            });
        }
        if next == 0 {
            break;
        }
        at = match at.checked_add(next) {
            Some(value) if value < buffer.len() => value,
            _ => break,
        };
    }
    Ok(out)
}

fn display_name(path: &str) -> String {
    let trimmed = path.trim_matches(['\\', '/']);
    if trimmed.is_empty() {
        "the share".to_string()
    } else {
        trimmed.replace('\\', "/")
    }
}

// ── share enumeration ──────────────────────────────────────────────────────

impl Client {
    /// Asks the server what shares it publishes.
    ///
    /// This is not an SMB request: it connects to the hidden `IPC$` share,
    /// opens the `srvsvc` pipe and makes a `NetrShareEnum` call over MSRPC.
    /// Doing it here means the app can offer a list to pick from instead of
    /// asking someone to remember a share name.
    ///
    /// The connection's own tree is restored afterwards, so this can be called
    /// on a live session without disturbing it.
    pub fn list_shares(&mut self) -> Result<Vec<ShareInfo>> {
        let original_tree = self.tree_id;
        self.tree_connect("IPC$")
            .map_err(|e| ClientError {
                message: format!(
                    "{} — the server doesn't support browsing for shares.",
                    e.message
                ),
                status: e.status,
            })?;

        let result = self.enumerate_shares();
        // Whatever happened, put the session back the way it was found.
        self.tree_id = original_tree;
        result
    }

    fn enumerate_shares(&mut self) -> Result<Vec<ShareInfo>> {
        let (handle, _) = self.create(
            "srvsvc",
            access::FILE_READ_DATA | access::FILE_WRITE_DATA | access::SYNCHRONIZE,
            disposition::OPEN,
            0,
        )?;

        let outcome = (|| -> Result<Vec<ShareInfo>> {
            let bind = self.ioctl(handle, fsctl::PIPE_TRANSCEIVE, &rpc_bind())?;
            if bind.len() < 3 || bind[2] != 12 {
                return Err(ClientError::local(
                    "The server refused the share-listing request.",
                ));
            }
            let reply = self.ioctl(handle, fsctl::PIPE_TRANSCEIVE, &rpc_share_enum())?;
            parse_share_enum(&reply)
        })();

        self.close_quietly(handle);
        outcome
    }
}

/// The MSRPC bind PDU for `srvsvc` v3.0 over NDR32.
fn rpc_bind() -> Vec<u8> {
    const SRVSVC_UUID: [u8; 16] = [
        0xc8, 0x4f, 0x32, 0x4b, 0x70, 0x16, 0xd3, 0x01, 0x12, 0x78, 0x5a, 0x47, 0xbf,
        0x6e, 0xe1, 0x88,
    ];
    const NDR32_UUID: [u8; 16] = [
        0x04, 0x5d, 0x88, 0x8a, 0xeb, 0x1c, 0xc9, 0x11, 0x9f, 0xe8, 0x08, 0x00, 0x2b,
        0x10, 0x48, 0x60,
    ];

    let mut body = Writer::new();
    body.u16(4280)
        .u16(4280)
        .u32(0) // assoc group: let the server choose
        .u32(1) // one presentation context
        .u16(0)
        .u8(1) // one transfer syntax
        .u8(0)
        .bytes(&SRVSVC_UUID)
        .u32(3) // interface version 3.0
        .bytes(&NDR32_UUID)
        .u32(2);
    rpc_frame(11, 1, &body.into_vec())
}

/// `NetrShareEnum` at level 1, with a null server name and no resume handle.
fn rpc_share_enum() -> Vec<u8> {
    let mut body = Writer::new();
    body.u32(0) // ServerName: null pointer
        .u32(1) // Level
        .u32(1) // switch value
        .u32(0x0002_0000) // pointer to the container
        .u32(0) // EntriesRead
        .u32(0) // null array pointer
        .u32(u32::MAX) // PreferedMaximumLength: no limit
        .u32(0); // null ResumeHandle

    let mut w = Writer::new();
    w.u32(body.len() as u32) // alloc hint
        .u16(0) // context id
        .u16(15) // opnum
        .bytes(body.as_slice());
    rpc_frame(0, 2, &w.into_vec())
}

fn rpc_frame(kind: u8, call_id: u32, body: &[u8]) -> Vec<u8> {
    let length = 16 + body.len();
    let mut w = Writer::with_capacity(length);
    w.u8(5)
        .u8(0)
        .u8(kind)
        .u8(0x03) // first and last fragment
        .u32(0x0000_0010) // little-endian, ASCII, IEEE
        .u16(length as u16)
        .u16(0)
        .u32(call_id)
        .bytes(body);
    w.into_vec()
}

/// Reads the level-1 share array out of a `NetrShareEnum` response.
///
/// NDR defers the strings to the end of the structure, in the order their
/// referent pointers appeared — so the fixed part is walked first to learn how
/// many shares there are and which of them named a string, then the strings are
/// read in that same order.
fn parse_share_enum(reply: &[u8]) -> Result<Vec<ShareInfo>> {
    // 16 bytes of PDU header, then 8 of response header.
    const BODY: usize = 24;
    if reply.len() < BODY + 4 || reply[2] != 2 {
        return Err(ClientError::local(
            "The server's share list couldn't be read.",
        ));
    }
    let mut r = Reader::new(&reply[BODY..]);
    let _level = r.u32().map_err(|_| malformed())?;
    let _switch = r.u32().map_err(|_| malformed())?;
    let container = r.u32().map_err(|_| malformed())?;
    if container == 0 {
        return Ok(Vec::new());
    }
    let count = r.u32().map_err(|_| malformed())? as usize;
    let array = r.u32().map_err(|_| malformed())?;
    if array == 0 || count == 0 {
        return Ok(Vec::new());
    }
    // A count from the network sizes the loop below, so it is bounded.
    if count > 4096 {
        return Err(malformed());
    }
    let _max_count = r.u32().map_err(|_| malformed())?;

    // Fixed part: (netname pointer, type, remark pointer) per share.
    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        let name_pointer = r.u32().map_err(|_| malformed())?;
        let share_type = r.u32().map_err(|_| malformed())?;
        let remark_pointer = r.u32().map_err(|_| malformed())?;
        entries.push((name_pointer, share_type, remark_pointer));
    }

    let mut out = Vec::with_capacity(count);
    for (name_pointer, share_type, remark_pointer) in entries {
        let name = if name_pointer == 0 {
            String::new()
        } else {
            read_ndr_string(&mut r).ok_or_else(malformed)?
        };
        let comment = if remark_pointer == 0 {
            String::new()
        } else {
            read_ndr_string(&mut r).ok_or_else(malformed)?
        };
        if name.is_empty() {
            continue;
        }
        // The top bit is STYPE_SPECIAL, and IPC$ carries it along with every
        // administrative share. Neither is a place to browse.
        let hidden = share_type & 0x8000_0000 != 0 || name.ends_with('$');
        out.push(ShareInfo {
            name,
            comment,
            hidden,
        });
    }
    Ok(out)
}

fn read_ndr_string(r: &mut Reader<'_>) -> Option<String> {
    let max = r.u32().ok()? as usize;
    let _offset = r.u32().ok()?;
    let actual = r.u32().ok()? as usize;
    if actual > max || actual > 4096 {
        return None;
    }
    let bytes = r.take(actual * 2).ok()?;
    // NDR pads each string out to a four-byte boundary.
    let over = (actual * 2) % 4;
    if over != 0 {
        r.skip(4 - over).ok()?;
    }
    let text = utf16le_to_string(bytes).ok()?;
    Some(text.trim_end_matches('\0').to_string())
}
