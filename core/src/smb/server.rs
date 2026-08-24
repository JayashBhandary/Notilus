//! An SMB2 file server.
//!
//! One thread accepts connections, one thread serves each. There is no async
//! runtime: a file server's work is blocking I/O on a handful of connections,
//! and a thread apiece keeps the request handlers straightforwardly sequential,
//! which matters when the state machine already has sessions, trees and opens
//! to keep straight.
//!
//! Dialects 2.0.2 through 3.1.1 are spoken, with NTLMv2 authentication and
//! packet signing (HMAC-SHA256 below 3.0, AES-CMAC at and above it, with 3.1.1
//! binding its keys to the preauth-integrity hash). Encryption is not offered:
//! a client that requires it will decline, which is the honest outcome.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Seek, SeekFrom, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::crypto;
use super::ntlm;
use super::proto::*;
use super::rpc::{Pipe, IPC_SHARE};
use super::share::{matches_pattern, Share};
use super::spnego::{self, NegState};
use super::wire::{utf16le_to_string, Reader, Writer};

/// Read and write sizes advertised to clients. Large transfers are what make a
/// file server feel fast on a LAN, and every dialect here supports LARGE_MTU.
const MAX_TRANSACT: u32 = 8 * 1024 * 1024;
const MAX_READ: u32 = 8 * 1024 * 1024;
const MAX_WRITE: u32 = 8 * 1024 * 1024;

/// Credits granted per request. SMB2 uses credits for flow control; a fixed
/// generous grant is right for a server that isn't trying to police clients.
const CREDITS_GRANTED: u16 = 64;

/// How long a connection may sit idle before the server drops it. Also the
/// granularity at which a serving thread notices a stop request.
const IDLE_TIMEOUT: Duration = Duration::from_secs(300);
const POLL_INTERVAL: Duration = Duration::from_millis(250);

/// `\xffSMB` — the header every SMB1 packet starts with.
const SMB1_PROTOCOL_ID: [u8; 4] = [0xFF, b'S', b'M', b'B'];
const SMB1_HEADER: usize = 32;
const SMB1_NEGOTIATE: u8 = 0x72;
/// The revision a server answers a multi-protocol negotiate with: "I speak
/// SMB2 — ask me again there."
const SMB2_WILDCARD_DIALECT: u16 = 0x02FF;

// ── configuration ──────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct User {
    pub name: String,
    /// MD4 of the UTF-16LE password. Stored rather than the password itself so
    /// the running server never holds the plaintext.
    pub nt_hash: [u8; 16],
}

impl User {
    pub fn new(name: &str, password: &str) -> User {
        User {
            name: name.to_string(),
            nt_hash: ntlm::nt_hash(password),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ServerConfig {
    pub bind: String,
    /// 0 asks the OS for a free port, which is what an app that can't bind 445
    /// wants.
    pub port: u16,
    pub server_name: String,
    pub domain: String,
    pub shares: Vec<Share>,
    pub users: Vec<User>,
    /// Refuse unsigned requests once a session is established.
    pub require_signing: bool,
    pub max_connections: usize,
}

impl Default for ServerConfig {
    fn default() -> Self {
        ServerConfig {
            bind: "0.0.0.0".into(),
            port: 0,
            server_name: "NOTILUS".into(),
            domain: "WORKGROUP".into(),
            shares: Vec::new(),
            users: Vec::new(),
            require_signing: true,
            max_connections: 32,
        }
    }
}

/// Something worth telling the user about, as it happens.
#[derive(Clone, Debug)]
pub enum ServerEvent {
    Started {
        port: u16,
    },
    Stopped,
    ClientConnected {
        connection: u64,
        peer: String,
    },
    ClientAuthenticated {
        connection: u64,
        peer: String,
        user: String,
        dialect: String,
    },
    ClientRejected {
        connection: u64,
        peer: String,
        reason: String,
    },
    ClientDisconnected {
        connection: u64,
        peer: String,
    },
    /// Bytes moved. Emitted when a handle closes rather than per packet, so a
    /// large copy produces one line rather than thousands.
    Transfer {
        connection: u64,
        share: String,
        path: String,
        /// True when the client was reading from the share.
        outbound: bool,
        bytes: u64,
    },
}

pub type EventSink = Arc<dyn Fn(ServerEvent) + Send + Sync>;

/// A running server. Dropping this does not stop it; call [`Handle::stop`].
pub struct Handle {
    pub port: u16,
    stop: Arc<AtomicBool>,
    connections: Arc<AtomicU64>,
}

impl Handle {
    /// Signals every thread to wind up. Returns once the listener is closed;
    /// in-flight requests finish on their own within [`POLL_INTERVAL`].
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }

    pub fn is_running(&self) -> bool {
        !self.stop.load(Ordering::SeqCst)
    }

    pub fn active_connections(&self) -> u64 {
        self.connections.load(Ordering::SeqCst)
    }
}

/// Binds and starts serving. Returns as soon as the listener is up.
pub fn start(config: ServerConfig, events: EventSink) -> Result<Handle, String> {
    if config.shares.is_empty() {
        return Err("Add at least one folder to share first.".into());
    }
    if config.users.is_empty() {
        return Err("Add at least one user before starting the server.".into());
    }
    for share in &config.shares {
        if !share.root.is_dir() {
            return Err(format!(
                "\"{}\" points at {}, which isn't a folder.",
                share.name,
                share.root.display()
            ));
        }
    }

    let address = format!("{}:{}", config.bind, config.port);
    let listener = TcpListener::bind(&address).map_err(|e| match e.kind() {
        ErrorKind::PermissionDenied => format!(
            "Port {} needs administrator rights. Pick a port above 1024.",
            config.port
        ),
        ErrorKind::AddrInUse => {
            format!("Port {} is already in use by another program.", config.port)
        }
        _ => format!("Couldn't listen on {address}: {e}"),
    })?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("Couldn't read the bound port: {e}"))?
        .port();
    listener
        .set_nonblocking(true)
        .map_err(|e| format!("Couldn't configure the listener: {e}"))?;

    let stop = Arc::new(AtomicBool::new(false));
    let connections = Arc::new(AtomicU64::new(0));
    let config = Arc::new(config);

    let handle = Handle {
        port,
        stop: stop.clone(),
        connections: connections.clone(),
    };

    thread::Builder::new()
        .name("smb-accept".into())
        .spawn(move || {
            events(ServerEvent::Started { port });
            let next_id = AtomicU64::new(1);

            while !stop.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, peer)) => {
                        if connections.load(Ordering::SeqCst)
                            >= config.max_connections as u64
                        {
                            // Refusing is better than queueing: a client that
                            // can't be served should find out now.
                            let _ = stream.shutdown(Shutdown::Both);
                            continue;
                        }
                        let id = next_id.fetch_add(1, Ordering::SeqCst);
                        connections.fetch_add(1, Ordering::SeqCst);
                        let config = config.clone();
                        let events = events.clone();
                        let stop = stop.clone();
                        let counter = connections.clone();
                        let spawned = thread::Builder::new()
                            .name(format!("smb-conn-{id}"))
                            .spawn(move || {
                                serve(id, stream, peer, config, events.clone(), stop);
                                counter.fetch_sub(1, Ordering::SeqCst);
                                events(ServerEvent::ClientDisconnected {
                                    connection: id,
                                    peer: peer.to_string(),
                                });
                            });
                        if spawned.is_err() {
                            connections.fetch_sub(1, Ordering::SeqCst);
                        }
                    }
                    Err(ref e) if e.kind() == ErrorKind::WouldBlock => {
                        thread::sleep(POLL_INTERVAL);
                    }
                    Err(_) => thread::sleep(POLL_INTERVAL),
                }
            }
            events(ServerEvent::Stopped);
        })
        .map_err(|e| format!("Couldn't start the server thread: {e}"))?;

    Ok(handle)
}

// ── per-connection state ───────────────────────────────────────────────────

/// What a tree id refers to.
///
/// `IPC$` is not a folder: it exists so a client can open the `srvsvc` pipe and
/// ask what shares there are. Modelling it as a second kind of tree — rather
/// than as a `Share` pointing at a directory — is what keeps every file
/// operation from having to ask whether its "folder" is real.
#[derive(Clone)]
enum Tree {
    Disk(Arc<Share>),
    Ipc,
}

impl Open {
    /// The share this handle belongs to. A pipe has none, and every caller
    /// that reaches for one is doing something only a file can do.
    fn share(&self) -> Result<&Arc<Share>, u32> {
        self.share.as_ref().ok_or(status::INVALID_DEVICE_REQUEST)
    }

    fn is_pipe(&self) -> bool {
        self.pipe.is_some()
    }
}

impl Tree {
    fn disk(&self) -> Result<&Arc<Share>, u32> {
        match self {
            Tree::Disk(share) => Ok(share),
            // A file request against IPC$ is a client bug, and this is the code
            // Windows answers it with.
            Tree::Ipc => Err(status::INVALID_DEVICE_REQUEST),
        }
    }
}

struct Open {
    path: PathBuf,
    /// The share this handle belongs to, or None for a pipe on `IPC$`.
    share: Option<Arc<Share>>,
    /// Set for the `srvsvc` pipe, which answers RPC rather than holding bytes.
    pipe: Option<Pipe>,
    is_dir: bool,
    file: Option<File>,
    granted: u32,
    delete_on_close: bool,
    /// Snapshot of the directory, taken on the first `QUERY_DIRECTORY` so that
    /// paging through a listing is consistent even if the folder changes.
    listing: Option<Vec<Entry>>,
    listing_index: usize,
    bytes_read: u64,
    bytes_written: u64,
}

struct Entry {
    name: String,
    is_dir: bool,
    size: u64,
    allocated: u64,
    created: u64,
    accessed: u64,
    modified: u64,
    attributes: u32,
    inode: u64,
}

struct PendingAuth {
    challenge: [u8; 8],
    negotiate: Vec<u8>,
    challenge_message: Vec<u8>,
}

struct Session {
    user: String,
    authenticated: bool,
    /// True when the client signed in without credentials.
    ///
    /// A guest reaches only the shares that opted into it, and never writes —
    /// so this has to be carried alongside the user name rather than inferred
    /// from it being empty.
    is_guest: bool,
    signing_key: [u8; 16],
    pending: Option<PendingAuth>,
    /// Preauth-integrity hash for this session (3.1.1 only).
    preauth: [u8; 64],
    trees: HashMap<u32, Tree>,
    opens: HashMap<u64, Open>,
}

impl Session {
    /// The shares this session is allowed to see, in configuration order.
    fn visible<'a>(&self, config: &'a ServerConfig) -> Vec<&'a Share> {
        config
            .shares
            .iter()
            .filter(|share| share.permits(&self.user, self.is_guest))
            .collect()
    }
}

struct Conn {
    id: u64,
    peer: SocketAddr,
    config: Arc<ServerConfig>,
    events: EventSink,
    dialect: Dialect,
    negotiated: bool,
    server_guid: [u8; 16],
    /// Preauth hash after NEGOTIATE, from which each session's starts.
    preauth: [u8; 64],
    sessions: HashMap<u64, Session>,
    next_session: u64,
    next_tree: u32,
    next_file: u64,
    boot_time: u64,
}

/// The result of handling one request: a body, plus whatever the header needs
/// to say that the handler decided.
struct Reply {
    status: u32,
    body: Vec<u8>,
    session_id: u64,
    tree_id: u32,
}

impl Reply {
    fn ok(body: Vec<u8>) -> Reply {
        Reply {
            status: status::SUCCESS,
            body,
            session_id: 0,
            tree_id: 0,
        }
    }

    fn with_status(status: u32, body: Vec<u8>) -> Reply {
        Reply {
            status,
            body,
            session_id: 0,
            tree_id: 0,
        }
    }
}

/// An SMB2 error response body: nine bytes, one of which is a placeholder.
fn error_body() -> Vec<u8> {
    let mut w = Writer::with_capacity(9);
    w.u16(9).u8(0).u8(0).u32(0).u8(0);
    w.into_vec()
}

type Handled = Result<Reply, u32>;

fn serve(
    id: u64,
    stream: TcpStream,
    peer: SocketAddr,
    config: Arc<ServerConfig>,
    events: EventSink,
    stop: Arc<AtomicBool>,
) {
    events(ServerEvent::ClientConnected {
        connection: id,
        peer: peer.to_string(),
    });
    // The listener is non-blocking so the accept loop can notice a stop, and on
    // BSD — macOS included — an accepted socket inherits that flag. Left set, a
    // read returns `WouldBlock` at once: the timeouts below would do nothing,
    // the serve loop would spin through its idle budget in milliseconds and
    // hang up on a working client, and a packet that arrived in pieces would
    // fail mid-body. Clear it explicitly rather than rely on the platform.
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(POLL_INTERVAL));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(60)));

    let Ok(server_guid) = crypto::random_array::<16>() else {
        events(ServerEvent::ClientRejected {
            connection: id,
            peer: peer.to_string(),
            reason: "no system randomness available".into(),
        });
        return;
    };

    let mut conn = Conn {
        id,
        peer,
        config,
        events: events.clone(),
        dialect: Dialect::Smb210,
        negotiated: false,
        server_guid,
        preauth: [0u8; 64],
        sessions: HashMap::new(),
        next_session: 1,
        next_tree: 1,
        next_file: 1,
        boot_time: now_filetime(),
    };

    let mut reader = stream.try_clone().ok();
    let mut writer = stream;
    let mut idle = Duration::ZERO;

    while !stop.load(Ordering::SeqCst) {
        let Some(source) = reader.as_mut() else { break };
        match read_packet(source) {
            Ok(Some(packet)) => {
                idle = Duration::ZERO;
                let response = conn.handle_packet(&packet);
                if response.is_empty() {
                    continue;
                }
                if write_packet(&mut writer, &response).is_err() {
                    break;
                }
            }
            // Idle: the read timed out with nothing pending.
            Ok(None) => {
                idle += POLL_INTERVAL;
                if idle >= IDLE_TIMEOUT {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let _ = writer.shutdown(Shutdown::Both);
}

/// Reads one NetBIOS-framed SMB2 packet.
///
/// `Ok(None)` means the socket timed out with nothing to read, which is how the
/// serving loop gets a chance to notice a stop request.
fn read_packet(stream: &mut TcpStream) -> std::io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; NBSS_HEADER];
    match stream.read_exact(&mut header) {
        Ok(()) => {}
        Err(e)
            if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut =>
        {
            return Ok(None)
        }
        Err(e) => return Err(e),
    }
    let length =
        u32::from_be_bytes([0, header[1], header[2], header[3]]) as usize;
    if length == 0 || length > MAX_PACKET {
        return Err(std::io::Error::new(
            ErrorKind::InvalidData,
            "packet length out of range",
        ));
    }
    let mut body = vec![0u8; length];
    // Past the framing header the rest of the packet must arrive; a timeout
    // here is a client that died mid-message.
    stream.set_read_timeout(Some(Duration::from_secs(60)))?;
    let result = stream.read_exact(&mut body);
    stream.set_read_timeout(Some(POLL_INTERVAL))?;
    result?;
    Ok(Some(body))
}

/// The dialect strings offered by an SMB1 negotiate.
///
/// After the fixed header comes `WordCount` (always zero here), a byte count,
/// then a run of `0x02`-tagged NUL-terminated ASCII names.
fn smb1_dialects(packet: &[u8]) -> Vec<String> {
    let mut names = Vec::new();
    // WordCount, then the two-byte ByteCount.
    let Some(&word_count) = packet.get(SMB1_HEADER) else {
        return names;
    };
    let mut at = SMB1_HEADER + 1 + word_count as usize * 2;
    let Some(count) = packet
        .get(at..at + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]) as usize)
    else {
        return names;
    };
    at += 2;
    let end = (at + count).min(packet.len());
    while at < end {
        if packet[at] != 0x02 {
            break;
        }
        at += 1;
        let Some(len) = packet[at..end].iter().position(|b| *b == 0) else {
            break;
        };
        if let Ok(name) = std::str::from_utf8(&packet[at..at + len]) {
            names.push(name.to_string());
        }
        at += len + 1;
    }
    names
}

/// An SMB1 negotiate response saying none of the offered dialects will do.
fn smb1_no_dialect(request: &[u8]) -> Vec<u8> {
    let mut reply = vec![0u8; SMB1_HEADER + 1 + 2 + 2];
    reply[..SMB1_HEADER].copy_from_slice(&request[..SMB1_HEADER]);
    reply[9] |= 0x80; // SMB_FLAGS_REPLY
    reply[5..9].copy_from_slice(&0u32.to_le_bytes()); // STATUS_SUCCESS
    reply[14..22].fill(0); // no signature
    reply[SMB1_HEADER] = 1; // WordCount
    reply[SMB1_HEADER + 1..SMB1_HEADER + 3].copy_from_slice(&0xFFFFu16.to_le_bytes());
    reply[SMB1_HEADER + 3..].copy_from_slice(&0u16.to_le_bytes()); // ByteCount
    reply
}

fn write_packet(stream: &mut TcpStream, body: &[u8]) -> std::io::Result<()> {
    let length = body.len() as u32;
    let header = [0u8, (length >> 16) as u8, (length >> 8) as u8, length as u8];
    stream.write_all(&header)?;
    stream.write_all(body)?;
    stream.flush()
}

fn now_filetime() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| to_filetime(d.as_secs() as i64, d.subsec_nanos()))
        .unwrap_or(0)
}

fn system_time_to_filetime(time: Option<SystemTime>) -> u64 {
    time.and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| to_filetime(d.as_secs() as i64, d.subsec_nanos()))
        .unwrap_or(0)
}

// ── request dispatch ───────────────────────────────────────────────────────

/// A `FileId` of all 0xFF means "the handle the previous request in this
/// compound chain produced" — Windows uses it to chain create+query+close.
const FILE_ID_INHERIT: u64 = u64::MAX;

impl Conn {
    /// Handles one packet, which may hold a compound chain of requests, and
    /// returns the packet to send back.
    fn handle_packet(&mut self, packet: &[u8]) -> Vec<u8> {
        // Finder, Explorer and mount.cifs all open with an SMB1 negotiate
        // listing "SMB 2.???" among its dialects. Ignoring it leaves the client
        // waiting for a reply that never comes, which is how a share that works
        // between two Notilus instances still looks dead to the rest of the
        // network.
        if packet.starts_with(&SMB1_PROTOCOL_ID) {
            return self.smb1(packet);
        }
        let mut out: Vec<u8> = Vec::with_capacity(packet.len().min(64 * 1024));
        let mut offset = 0usize;
        // Related requests inherit these from the request before them.
        let mut chain_session = 0u64;
        let mut chain_tree = 0u32;
        let mut chain_file = 0u64;

        while offset + HEADER_SIZE <= packet.len() {
            let mut reader = Reader::new(&packet[offset..]);
            let Ok(mut header) = Header::parse(&mut reader) else {
                break;
            };
            let available = packet.len() - offset;
            let chunk = if header.next_command == 0 {
                available
            } else {
                (header.next_command as usize).min(available)
            };
            if chunk < HEADER_SIZE {
                break;
            }
            let message = &packet[offset..offset + chunk];

            if header.is_related() {
                if header.session_id == 0 || header.session_id == u64::MAX {
                    header.session_id = chain_session;
                }
                if header.tree_id == 0 || header.tree_id == u32::MAX {
                    header.tree_id = chain_tree;
                }
            }

            // CANCEL is the one request with no response.
            if header.command == command::CANCEL {
                offset += chunk;
                if header.next_command == 0 {
                    break;
                }
                continue;
            }

            let result = self.dispatch(&header, message, &mut chain_file);
            let (status, body, session_id, tree_id) = match result {
                Ok(reply) => {
                    let session = if reply.session_id != 0 {
                        reply.session_id
                    } else {
                        header.session_id
                    };
                    let tree = if reply.tree_id != 0 {
                        reply.tree_id
                    } else {
                        header.tree_id
                    };
                    (reply.status, reply.body, session, tree)
                }
                Err(code) => (code, error_body(), header.session_id, header.tree_id),
            };
            chain_session = session_id;
            chain_tree = tree_id;

            let start = out.len();
            let response_header = Header {
                credit_charge: header.credit_charge,
                status,
                command: header.command,
                credits: header.credits.max(1).min(CREDITS_GRANTED),
                flags: flags::SERVER_TO_REDIR,
                next_command: 0,
                message_id: header.message_id,
                tree_id,
                session_id,
                signature: [0u8; 16],
            };
            let mut w = Writer::with_capacity(HEADER_SIZE + body.len());
            response_header.write(&mut w);
            w.bytes(&body);
            out.extend_from_slice(w.as_slice());

            // The preauth-integrity hash covers the negotiate exchange and
            // every session-setup message up to — but not including — the
            // response that completes authentication.
            if header.command == command::NEGOTIATE
                && status == status::SUCCESS
                && self.dialect == Dialect::Smb311
            {
                let response = out[start..].to_vec();
                self.preauth = crypto::extend_preauth(&self.preauth, &response);
            }
            if header.command == command::SESSION_SETUP
                && status == status::MORE_PROCESSING_REQUIRED
                && self.dialect == Dialect::Smb311
            {
                let response = out[start..].to_vec();
                if let Some(session) = self.sessions.get_mut(&session_id) {
                    session.preauth = crypto::extend_preauth(&session.preauth, &response);
                }
            }

            offset += chunk;
            let last = header.next_command == 0;
            if !last {
                // Every response but the last announces where the next begins,
                // eight-byte aligned.
                let padding = (8 - (out.len() % 8)) % 8;
                out.resize(out.len() + padding, 0);
                let size = (out.len() - start) as u32;
                out[start + 20..start + 24].copy_from_slice(&size.to_le_bytes());
            }
            // Signing comes last, once this response is exactly the bytes that
            // go on the wire. Signing before `NextCommand` and the padding were
            // written left every chained response with a signature over the
            // wrong bytes — invisible to a client that doesn't check, fatal to
            // one that does, and a compound request is how macOS opens a file.
            self.sign_response(session_id, &mut out[start..]);
            if last {
                break;
            }
        }
        out
    }

    /// Signs a response when the session it belongs to has a key.
    fn sign_response(&self, session_id: u64, packet: &mut [u8]) {
        let Some(session) = self.sessions.get(&session_id) else {
            return;
        };
        if !session.authenticated || session.is_guest {
            return;
        }
        crypto::apply_signature(self.dialect, &session.signing_key, packet);
    }

    fn dispatch(
        &mut self,
        header: &Header,
        message: &[u8],
        chain_file: &mut u64,
    ) -> Handled {
        // NEGOTIATE is the only thing accepted before a dialect is agreed.
        if !self.negotiated && header.command != command::NEGOTIATE {
            return Err(status::INVALID_PARAMETER);
        }
        if header.command != command::NEGOTIATE
            && header.command != command::SESSION_SETUP
        {
            self.check_signature(header, message)?;
        } else if header.command == command::SESSION_SETUP && header.is_signed() {
            // A signed session setup is the client re-authenticating on an
            // existing session; it must still verify.
            self.check_signature(header, message)?;
        }

        let body = message.get(HEADER_SIZE..).unwrap_or_default();
        match header.command {
            command::NEGOTIATE => self.negotiate(message, body),
            command::SESSION_SETUP => self.session_setup(header, message, body),
            command::LOGOFF => self.logoff(header),
            command::TREE_CONNECT => self.tree_connect(header, body),
            command::TREE_DISCONNECT => self.tree_disconnect(header),
            command::CREATE => self.create(header, body, chain_file),
            command::CLOSE => self.close(header, body, chain_file),
            command::FLUSH => self.flush(header, body, chain_file),
            command::READ => self.read(header, body, chain_file),
            command::WRITE => self.write(header, body, chain_file),
            command::QUERY_DIRECTORY => self.query_directory(header, body, chain_file),
            command::QUERY_INFO => self.query_info(header, body, chain_file),
            command::SET_INFO => self.set_info(header, body, chain_file),
            command::IOCTL => self.ioctl(header, body, chain_file),
            command::ECHO => {
                let mut w = Writer::with_capacity(4);
                w.u16(4).u16(0);
                Ok(Reply::ok(w.into_vec()))
            }
            // Locking is advisory here: a file manager doesn't rely on it, and
            // refusing would break clients that lock as a matter of course.
            command::LOCK => {
                let mut w = Writer::with_capacity(4);
                w.u16(4).u16(0);
                Ok(Reply::ok(w.into_vec()))
            }
            command::CHANGE_NOTIFY => Err(status::NOT_SUPPORTED),
            command::OPLOCK_BREAK => Err(status::NOT_SUPPORTED),
            _ => Err(status::NOT_IMPLEMENTED),
        }
    }

    /// Enforces the signing policy for a request that arrives on a session.
    fn check_signature(&self, header: &Header, message: &[u8]) -> Result<(), u32> {
        if header.session_id == 0 {
            return Ok(());
        }
        let Some(session) = self.sessions.get(&header.session_id) else {
            return Err(status::USER_SESSION_DELETED);
        };
        if !session.authenticated {
            return Err(status::ACCESS_DENIED);
        }
        if !header.is_signed() {
            // A guest has no session key, so it has nothing to sign with and
            // the server must not demand a signature it made impossible.
            return if self.config.require_signing && !session.is_guest {
                Err(status::ACCESS_DENIED)
            } else {
                Ok(())
            };
        }
        if crypto::verify_packet(self.dialect, &session.signing_key, message) {
            Ok(())
        } else {
            Err(status::ACCESS_DENIED)
        }
    }

    // ── NEGOTIATE ──────────────────────────────────────────────────────────

    /// Answers the SMB1 packet a client opens with before it will speak SMB2.
    ///
    /// Only the multi-protocol negotiate is answered, and only ever with SMB2:
    /// a client offering `SMB 2.???` is told to ask again in SMB2 (the `0x02FF`
    /// wildcard), one offering `SMB 2.002` gets that dialect outright, and one
    /// offering neither is told no dialect matched — which fails it fast
    /// instead of leaving it to time out. This server speaks no SMB1 beyond
    /// this one exchange, and there is no plan to: SMB1 is off by default on
    /// every current client for good reason.
    fn smb1(&mut self, packet: &[u8]) -> Vec<u8> {
        if packet.len() < SMB1_HEADER || packet[4] != SMB1_NEGOTIATE {
            return Vec::new();
        }
        let dialects = smb1_dialects(packet);
        let wildcard = dialects.iter().any(|d| d == "SMB 2.???");
        let smb2002 = dialects.iter().any(|d| d == "SMB 2.002");

        if !wildcard && !smb2002 {
            return smb1_no_dialect(packet);
        }
        // The wildcard means "answer in SMB2 and I'll negotiate properly"; the
        // dialect is settled by the SMB2 negotiate that follows, and the
        // preauth hash starts there too, so nothing is recorded here.
        let code = if wildcard {
            SMB2_WILDCARD_DIALECT
        } else {
            self.dialect = Dialect::Smb202;
            self.negotiated = true;
            Dialect::Smb202.code()
        };
        let Ok(body) = self.negotiate_body(code) else {
            return Vec::new();
        };

        let header = Header {
            credit_charge: 0,
            status: status::SUCCESS,
            command: command::NEGOTIATE,
            credits: 1,
            flags: flags::SERVER_TO_REDIR,
            next_command: 0,
            message_id: 0,
            tree_id: 0,
            session_id: 0,
            signature: [0u8; 16],
        };
        let mut w = Writer::with_capacity(HEADER_SIZE + body.len());
        header.write(&mut w);
        w.bytes(&body);
        w.into_vec()
    }

    fn negotiate(&mut self, message: &[u8], body: &[u8]) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let dialect_count = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let _security_mode = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _capabilities = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let _client_guid: [u8; 16] = r.array().map_err(|_| status::INVALID_PARAMETER)?;
        let context_offset = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let context_count = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved2 = r.u16().map_err(|_| status::INVALID_PARAMETER)?;

        if dialect_count == 0 || dialect_count > 64 {
            return Err(status::INVALID_PARAMETER);
        }
        let mut offered = Vec::with_capacity(dialect_count);
        for _ in 0..dialect_count {
            let code = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
            if let Some(dialect) = Dialect::from_code(code) {
                offered.push(dialect);
            }
        }
        let Some(chosen) = offered.iter().copied().max() else {
            return Err(status::NOT_SUPPORTED);
        };
        self.dialect = chosen;
        self.negotiated = true;

        // 3.1.1 requires the client's preauth-integrity context to be echoed
        // with the server's own salt.
        if chosen == Dialect::Smb311
            && !has_preauth_context(message, context_offset as usize, context_count)
        {
            // Without it there is no way to bind the session keys to this
            // negotiation, which is the point of 3.1.1.
            return Err(status::INVALID_PARAMETER);
        }

        let body = self.negotiate_body(chosen.code())?;

        if chosen == Dialect::Smb311 {
            // First half of the preauth hash; `handle_packet` folds in the
            // response once it has been framed.
            self.preauth = crypto::extend_preauth(&[0u8; 64], message);
        }
        Ok(Reply::ok(body))
    }

    /// The body of a NEGOTIATE response announcing `dialect_code`.
    ///
    /// Taken by code rather than [`Dialect`] because the answer to an SMB1
    /// multi-protocol negotiate carries `0x02FF`, the wildcard revision, which
    /// names no dialect at all — it tells the client to ask again in SMB2.
    fn negotiate_body(&self, dialect_code: u16) -> Result<Vec<u8>, u32> {
        let security_buffer = spnego::server_mech_list();
        let salt: [u8; 32] = crypto::random_array().map_err(|_| status::NOT_SUPPORTED)?;
        let is_311 = dialect_code == Dialect::Smb311.code();

        let mut w = Writer::with_capacity(128 + security_buffer.len());
        w.u16(65)
            .u16(security_mode::SIGNING_ENABLED
                | if self.config.require_signing {
                    security_mode::SIGNING_REQUIRED
                } else {
                    0
                })
            .u16(dialect_code)
            .u16(if is_311 { 1 } else { 0 })
            .bytes(&self.server_guid)
            // Large MTU only. Leasing, multi-channel, persistent handles and
            // encryption are all things a client would then be entitled to
            // ask for, and none of them are implemented.
            .u32(capabilities::LARGE_MTU)
            .u32(MAX_TRANSACT)
            .u32(MAX_READ)
            .u32(MAX_WRITE)
            .u64(now_filetime())
            .u64(self.boot_time);
        let buffer_offset_at = w.len();
        w.u16(0).u16(security_buffer.len() as u16);
        let context_offset_at = w.len();
        w.u32(0);

        let buffer_offset = HEADER_SIZE + w.len();
        w.bytes(&security_buffer);
        w.patch_u16(buffer_offset_at, buffer_offset as u16);

        if is_311 {
            w.align_to(8);
            let contexts_at = HEADER_SIZE + w.len();
            w.patch_u32(context_offset_at, contexts_at as u32);
            // SMB2_PREAUTH_INTEGRITY_CAPABILITIES: SHA-512, one salt.
            w.u16(1)
                .u16(4 + 2 + salt.len() as u16)
                .u32(0)
                .u16(1) // HashAlgorithmCount
                .u16(salt.len() as u16)
                .u16(1) // SHA-512
                .bytes(&salt);
        }
        Ok(w.into_vec())
    }

    // ── SESSION_SETUP ──────────────────────────────────────────────────────

    fn session_setup(&mut self, header: &Header, message: &[u8], body: &[u8]) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _flags = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let _security_mode = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let _capabilities = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let _channel = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let buffer_offset = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let buffer_length = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let _previous = r.u64().map_err(|_| status::INVALID_PARAMETER)?;

        let blob = Reader::new(message)
            .slice_at(buffer_offset, buffer_length)
            .map_err(|_| status::INVALID_PARAMETER)?;
        let token = spnego::extract_ntlm_token(blob).ok_or(status::LOGON_FAILURE)?;

        let session_id = if header.session_id == 0 {
            let id = self.next_session;
            self.next_session += 1;
            let preauth = self.preauth;
            self.sessions.insert(
                id,
                Session {
                    user: String::new(),
                    authenticated: false,
                    is_guest: false,
                    signing_key: [0u8; 16],
                    pending: None,
                    preauth,
                    trees: HashMap::new(),
                    opens: HashMap::new(),
                },
            );
            id
        } else {
            if !self.sessions.contains_key(&header.session_id) {
                return Err(status::USER_SESSION_DELETED);
            }
            header.session_id
        };

        if self.dialect == Dialect::Smb311 {
            if let Some(session) = self.sessions.get_mut(&session_id) {
                session.preauth = crypto::extend_preauth(&session.preauth, message);
            }
        }
        match ntlm::message_type(token) {
            Some(1) => self.send_challenge(session_id, token),
            Some(3) => self.accept_authenticate(session_id, token),
            _ => Err(status::LOGON_FAILURE),
        }
    }

    fn send_challenge(&mut self, session_id: u64, negotiate: &[u8]) -> Handled {
        let challenge = ntlm::build_challenge(
            &self.config.server_name,
            &self.config.server_name.to_lowercase(),
            &self.config.domain,
            now_filetime(),
        )
        .map_err(|_| status::LOGON_FAILURE)?;

        let Some(session) = self.sessions.get_mut(&session_id) else {
            return Err(status::USER_SESSION_DELETED);
        };
        session.pending = Some(PendingAuth {
            challenge: challenge.server_challenge,
            negotiate: negotiate.to_vec(),
            challenge_message: challenge.message.clone(),
        });

        let token = spnego::neg_token_resp(
            NegState::AcceptIncomplete,
            Some(&challenge.message),
            true,
        );
        let mut reply = Reply::with_status(
            status::MORE_PROCESSING_REQUIRED,
            session_setup_body(&token),
        );
        reply.session_id = session_id;
        Ok(reply)
    }

    fn accept_authenticate(&mut self, session_id: u64, token: &[u8]) -> Handled {
        let auth = ntlm::parse_authenticate(token).map_err(|_| status::LOGON_FAILURE)?;
        let Some(session) = self.sessions.get(&session_id) else {
            return Err(status::USER_SESSION_DELETED);
        };
        let Some(pending) = session.pending.as_ref() else {
            return Err(status::INVALID_PARAMETER);
        };

        if auth.is_anonymous() {
            // A guest session is worth granting only when some share asked for
            // one; otherwise this is an unauthenticated stranger.
            if !self.config.shares.iter().any(|share| share.guest_ok) {
                self.reject(session_id, "anonymous access is not allowed");
                return Err(status::LOGON_FAILURE);
            }
            return self.accept_guest(session_id);
        }
        let Some(user) = self
            .config
            .users
            .iter()
            .find(|u| u.name.eq_ignore_ascii_case(&auth.user))
        else {
            self.reject(session_id, &format!("no user named \"{}\"", auth.user));
            return Err(status::LOGON_FAILURE);
        };

        let established = ntlm::verify_authenticate(
            &auth,
            token,
            &user.nt_hash,
            &pending.challenge,
            &pending.negotiate,
            &pending.challenge_message,
        );
        let established = match established {
            Ok(established) => established,
            Err(e) => {
                self.reject(session_id, &e.to_string());
                return Err(status::LOGON_FAILURE);
            }
        };

        let dialect = self.dialect;
        let peer = self.peer.to_string();
        let connection = self.id;
        let Some(session) = self.sessions.get_mut(&session_id) else {
            return Err(status::USER_SESSION_DELETED);
        };
        session.signing_key =
            crypto::signing_key(dialect, &established.session_key, &session.preauth);
        session.user = user.name.clone();
        session.authenticated = true;
        session.is_guest = false;
        session.pending = None;


        (self.events)(ServerEvent::ClientAuthenticated {
            connection,
            peer,
            user: user.name.clone(),
            dialect: dialect.label().to_string(),
        });

        let token = spnego::neg_token_resp(NegState::AcceptCompleted, None, false);
        let mut reply = Reply::ok(session_setup_body(&token));
        reply.session_id = session_id;
        Ok(reply)
    }

    /// Completes a session for a client that offered no credentials.
    ///
    /// The reply sets `SMB2_SESSION_FLAG_IS_GUEST`, which tells the client not
    /// to expect signing — a guest has no session key to sign with, so the
    /// server must not demand one from it either.
    fn accept_guest(&mut self, session_id: u64) -> Handled {
        let peer = self.peer.to_string();
        let connection = self.id;
        let dialect = self.dialect;
        let Some(session) = self.sessions.get_mut(&session_id) else {
            return Err(status::USER_SESSION_DELETED);
        };
        session.user = "guest".into();
        session.authenticated = true;
        session.is_guest = true;
        session.signing_key = [0u8; 16];
        session.pending = None;

        (self.events)(ServerEvent::ClientAuthenticated {
            connection,
            peer,
            user: "guest".into(),
            dialect: dialect.label().to_string(),
        });

        let token = spnego::neg_token_resp(NegState::AcceptCompleted, None, false);
        let mut reply = Reply::ok(session_setup_body_with_flags(&token, SESSION_FLAG_GUEST));
        reply.session_id = session_id;
        Ok(reply)
    }

    fn reject(&self, connection_session: u64, reason: &str) {
        let _ = connection_session;
        (self.events)(ServerEvent::ClientRejected {
            connection: self.id,
            peer: self.peer.to_string(),
            reason: reason.to_string(),
        });
    }

    fn logoff(&mut self, header: &Header) -> Handled {
        self.sessions.remove(&header.session_id);
        let mut w = Writer::with_capacity(4);
        w.u16(4).u16(0);
        Ok(Reply::ok(w.into_vec()))
    }

    // ── TREE_CONNECT ───────────────────────────────────────────────────────

    fn tree_connect(&mut self, header: &Header, body: &[u8]) -> Handled {
        let session = self
            .sessions
            .get(&header.session_id)
            .filter(|s| s.authenticated)
            .ok_or(status::USER_SESSION_DELETED)?;
        let user = session.user.clone();
        let is_guest = session.is_guest;

        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _flags = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let path_offset = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let path_length = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;

        // The offset is from the start of the packet, and `body` starts one
        // header in.
        let start = path_offset
            .checked_sub(HEADER_SIZE)
            .ok_or(status::INVALID_PARAMETER)?;
        let raw = Reader::new(body)
            .slice_at(start, path_length)
            .map_err(|_| status::INVALID_PARAMETER)?;
        let path = utf16le_to_string(raw).map_err(|_| status::INVALID_PARAMETER)?;
        let name = path.rsplit('\\').next().unwrap_or("").to_string();

        // `IPC$` is where a client goes to ask what shares exist. Every account
        // reaches it, including a guest — what it can *see* through it is
        // filtered per share when the enumeration is answered.
        let (tree, share_type, maximal) = if name.eq_ignore_ascii_case(IPC_SHARE) {
            (
                Tree::Ipc,
                share_type::PIPE,
                access::FILE_READ_DATA | access::FILE_WRITE_DATA | access::SYNCHRONIZE,
            )
        } else {
            let share = self
                .config
                .shares
                .iter()
                .find(|s| s.name.eq_ignore_ascii_case(&name))
                .cloned()
                .ok_or(status::BAD_NETWORK_NAME)?;

            if !share.permits(&user, is_guest) {
                // Deliberately not BAD_NETWORK_NAME: the share exists, and
                // saying otherwise would send the user hunting for a typo.
                (self.events)(ServerEvent::ClientRejected {
                    connection: self.id,
                    peer: self.peer.to_string(),
                    reason: format!(
                        "{} isn't allowed on \"{}\"",
                        if is_guest { "a guest" } else { user.as_str() },
                        share.name
                    ),
                });
                return Err(status::ACCESS_DENIED);
            }

            let maximal = if share.writable_by(is_guest) {
                access::WRITE_SET | access::FILE_DELETE_CHILD
            } else {
                access::READ_SET
            };
            (Tree::Disk(Arc::new(share)), share_type::DISK, maximal)
        };

        let tree_id = self.next_tree;
        self.next_tree += 1;
        if let Some(session) = self.sessions.get_mut(&header.session_id) {
            session.trees.insert(tree_id, tree);
        }

        let mut w = Writer::with_capacity(16);
        w.u16(16)
            .u8(share_type)
            .u8(0)
            .u32(share_flags::MANUAL_CACHING)
            .u32(0)
            .u32(maximal);
        let mut reply = Reply::ok(w.into_vec());
        reply.tree_id = tree_id;
        Ok(reply)
    }

    fn tree_disconnect(&mut self, header: &Header) -> Handled {
        if let Some(session) = self.sessions.get_mut(&header.session_id) {
            session.trees.remove(&header.tree_id);
        }
        let mut w = Writer::with_capacity(4);
        w.u16(4).u16(0);
        Ok(Reply::ok(w.into_vec()))
    }
}

/// `SMB2_SESSION_FLAG_IS_GUEST`.
const SESSION_FLAG_GUEST: u16 = 0x0001;

fn session_setup_body(token: &[u8]) -> Vec<u8> {
    session_setup_body_with_flags(token, 0)
}

fn session_setup_body_with_flags(token: &[u8], flags: u16) -> Vec<u8> {
    let mut w = Writer::with_capacity(8 + token.len());
    w.u16(9).u16(flags);
    let offset_at = w.len();
    w.u16(0).u16(token.len() as u16);
    let offset = HEADER_SIZE + w.len();
    w.bytes(token);
    w.patch_u16(offset_at, offset as u16);
    w.into_vec()
}

/// True when the client's negotiate contexts include a preauth-integrity
/// context naming SHA-512, which 3.1.1 requires.
fn has_preauth_context(message: &[u8], offset: usize, count: u16) -> bool {
    let reader = Reader::new(message);
    let mut at = offset;
    for _ in 0..count {
        let Ok(head) = reader.slice_at(at, 8) else {
            return false;
        };
        let context_type = u16::from_le_bytes([head[0], head[1]]);
        let length = u16::from_le_bytes([head[2], head[3]]) as usize;
        if context_type == 1 {
            return true;
        }
        at = match at.checked_add(8 + length) {
            Some(next) => (next + 7) / 8 * 8,
            None => return false,
        };
    }
    false
}

// ── file handles ───────────────────────────────────────────────────────────

impl Conn {
    fn tree_of(&self, header: &Header) -> Result<Tree, u32> {
        self.sessions
            .get(&header.session_id)
            .filter(|s| s.authenticated)
            .ok_or(status::USER_SESSION_DELETED)?
            .trees
            .get(&header.tree_id)
            .cloned()
            .ok_or(status::NETWORK_NAME_DELETED)
    }

    /// The folder share a request is against, refusing anything aimed at
    /// `IPC$`.
    fn share_of(&self, header: &Header) -> Result<Arc<Share>, u32> {
        self.tree_of(header)?.disk().cloned()
    }

    fn is_guest(&self, header: &Header) -> bool {
        self.sessions
            .get(&header.session_id)
            .map(|s| s.is_guest)
            .unwrap_or(false)
    }

    fn session_mut(&mut self, header: &Header) -> Result<&mut Session, u32> {
        self.sessions
            .get_mut(&header.session_id)
            .filter(|s| s.authenticated)
            .ok_or(status::USER_SESSION_DELETED)
    }

    /// Reads a `FileId` from a request, resolving the "same handle as the last
    /// request in this chain" form.
    fn file_id(reader: &mut Reader<'_>, chain_file: &mut u64) -> Result<u64, u32> {
        let persistent = reader.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let volatile = reader.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let id = if persistent == FILE_ID_INHERIT && volatile == FILE_ID_INHERIT {
            *chain_file
        } else {
            volatile
        };
        if id == 0 {
            return Err(status::INVALID_HANDLE);
        }
        *chain_file = id;
        Ok(id)
    }

    // ── CREATE ─────────────────────────────────────────────────────────────

    fn create(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        let tree = self.tree_of(header)?;

        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _security_flags = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let _oplock = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let _impersonation = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let _create_flags = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let desired_access = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let _file_attributes = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let _share_access = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let create_disposition = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let create_options = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let name_offset = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let name_length = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;

        let name = if name_length == 0 {
            String::new()
        } else {
            let start = name_offset
                .checked_sub(HEADER_SIZE)
                .ok_or(status::INVALID_PARAMETER)?;
            let raw = Reader::new(body)
                .slice_at(start, name_length)
                .map_err(|_| status::INVALID_PARAMETER)?;
            utf16le_to_string(raw).map_err(|_| status::OBJECT_PATH_SYNTAX_BAD)?
        };

        let share = match tree {
            Tree::Ipc => return self.open_pipe(header, &name, chain_file),
            Tree::Disk(share) => share,
        };
        let path = share.resolve(&name).ok_or(status::OBJECT_PATH_SYNTAX_BAD)?;
        let wants_write = access::is_write(desired_access)
            || matches!(
                create_disposition,
                disposition::CREATE
                    | disposition::OPEN_IF
                    | disposition::OVERWRITE
                    | disposition::OVERWRITE_IF
                    | disposition::SUPERSEDE
            );
        if wants_write && !share.writable_by(self.is_guest(header)) {
            return Err(status::MEDIA_WRITE_PROTECTED);
        }

        let want_directory = create_options & options::DIRECTORY_FILE != 0;
        let want_file = create_options & options::NON_DIRECTORY_FILE != 0;
        let existing = fs::metadata(&path).ok();

        // Disposition first, so a CREATE on something that exists fails before
        // anything is touched.
        match create_disposition {
            disposition::OPEN | disposition::OVERWRITE if existing.is_none() => {
                return Err(status::OBJECT_NAME_NOT_FOUND)
            }
            disposition::CREATE if existing.is_some() => {
                return Err(status::OBJECT_NAME_COLLISION)
            }
            _ => {}
        }
        if let Some(meta) = &existing {
            if meta.is_dir() && want_file {
                return Err(status::FILE_IS_A_DIRECTORY);
            }
            if !meta.is_dir() && want_directory {
                return Err(status::NOT_A_DIRECTORY);
            }
        }

        let mut action = create_action::OPENED;
        let is_dir = existing.as_ref().map(|m| m.is_dir()).unwrap_or(want_directory);
        let mut file = None;

        if is_dir {
            if existing.is_none() {
                fs::create_dir(&path).map_err(io_to_status)?;
                action = create_action::CREATED;
            }
        } else {
            let mut open = OpenOptions::new();
            open.read(true);
            if wants_write {
                open.write(true);
            }
            match create_disposition {
                disposition::OPEN => {}
                disposition::CREATE => {
                    open.create_new(true).write(true);
                    action = create_action::CREATED;
                }
                disposition::OPEN_IF => {
                    open.create(true).write(true);
                    if existing.is_none() {
                        action = create_action::CREATED;
                    }
                }
                disposition::OVERWRITE => {
                    open.write(true).truncate(true);
                    action = create_action::OVERWRITTEN;
                }
                disposition::OVERWRITE_IF | disposition::SUPERSEDE => {
                    open.create(true).write(true).truncate(true);
                    action = if existing.is_some() {
                        if create_disposition == disposition::SUPERSEDE {
                            create_action::SUPERSEDED
                        } else {
                            create_action::OVERWRITTEN
                        }
                    } else {
                        create_action::CREATED
                    };
                }
                _ => return Err(status::INVALID_PARAMETER),
            }
            file = Some(open.open(&path).map_err(io_to_status)?);
        }

        let entry = entry_for(&path, file_name_of(&path)).ok_or(status::OBJECT_NAME_NOT_FOUND)?;
        let id = self.next_file;
        self.next_file += 1;
        let delete_on_close = create_options & options::DELETE_ON_CLOSE != 0;

        let session = self.session_mut(header)?;
        session.opens.insert(
            id,
            Open {
                path,
                share: Some(share),
                pipe: None,
                is_dir,
                file,
                granted: desired_access,
                delete_on_close,
                listing: None,
                listing_index: 0,
                bytes_read: 0,
                bytes_written: 0,
            },
        );
        *chain_file = id;

        let mut w = Writer::with_capacity(96);
        w.u16(89)
            .u8(0)
            .u8(0)
            .u32(action)
            .u64(entry.created)
            .u64(entry.accessed)
            .u64(entry.modified)
            .u64(entry.modified)
            .u64(entry.allocated)
            .u64(entry.size)
            .u32(entry.attributes)
            .u32(0)
            .u64(id)
            .u64(id)
            .u32(0)
            .u32(0)
            .u8(0);
        Ok(Reply::ok(w.into_vec()))
    }

    /// Opens a named pipe on `IPC$`.
    ///
    /// Only `srvsvc` is served. The other pipes a Windows client might name —
    /// `wkssvc`, `lsarpc`, `samr` — belong to interfaces this server doesn't
    /// implement, and answering them with an empty pipe would strand the
    /// client waiting for a reply that never parses.
    fn open_pipe(
        &mut self,
        header: &Header,
        name: &str,
        chain_file: &mut u64,
    ) -> Handled {
        let pipe_name = name.trim_start_matches(['\\', '/']);
        if !pipe_name.eq_ignore_ascii_case("srvsvc") {
            return Err(status::OBJECT_NAME_NOT_FOUND);
        }

        let id = self.next_file;
        self.next_file += 1;
        let now = now_filetime();

        let session = self.session_mut(header)?;
        session.opens.insert(
            id,
            Open {
                path: PathBuf::from(pipe_name),
                share: None,
                pipe: Some(Pipe::new()),
                is_dir: false,
                file: None,
                granted: access::FILE_READ_DATA
                    | access::FILE_WRITE_DATA
                    | access::SYNCHRONIZE,
                delete_on_close: false,
                listing: None,
                listing_index: 0,
                bytes_read: 0,
                bytes_written: 0,
            },
        );
        *chain_file = id;

        let mut w = Writer::with_capacity(96);
        w.u16(89)
            .u8(0)
            .u8(0)
            .u32(create_action::OPENED)
            .u64(now)
            .u64(now)
            .u64(now)
            .u64(now)
            .u64(0)
            .u64(0)
            .u32(attr::NORMAL)
            .u32(0)
            .u64(id)
            .u64(id)
            .u32(0)
            .u32(0)
            .u8(0);
        Ok(Reply::ok(w.into_vec()))
    }

    /// Runs one RPC call and returns its reply, for both the write-then-read
    /// and the transceive paths.
    fn pipe_call(&mut self, header: &Header, id: u64, request: &[u8]) -> Result<Vec<u8>, u32> {
        let server_name = self.config.server_name.clone();
        let session = self
            .sessions
            .get(&header.session_id)
            .filter(|s| s.authenticated)
            .ok_or(status::USER_SESSION_DELETED)?;
        // What the client is told exists is exactly what it is allowed to
        // attach to — a share it can't reach must not appear in the list.
        let visible = session.visible(&self.config);
        let owned: Vec<Share> = visible.into_iter().cloned().collect();
        let borrowed: Vec<&Share> = owned.iter().collect();

        let session = self
            .sessions
            .get_mut(&header.session_id)
            .ok_or(status::USER_SESSION_DELETED)?;
        let open = session.opens.get_mut(&id).ok_or(status::FILE_CLOSED)?;
        let pipe = open.pipe.as_mut().ok_or(status::INVALID_DEVICE_REQUEST)?;
        Ok(pipe.call(request, &borrowed, &server_name))
    }

    // ── CLOSE / FLUSH ──────────────────────────────────────────────────────

    fn close(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let flags = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let id = Self::file_id(&mut r, chain_file)?;

        let connection = self.id;
        let events = self.events.clone();
        let session = self.session_mut(header)?;
        let open = session.opens.remove(&id).ok_or(status::FILE_CLOSED)?;
        // Drop the handle before any unlink: on Windows a file with an open
        // handle can't be removed.
        drop(open.file);

        if open.delete_on_close {
            let result = if open.is_dir {
                fs::remove_dir(&open.path)
            } else {
                fs::remove_file(&open.path)
            };
            if let Err(e) = result {
                if e.kind() != ErrorKind::NotFound {
                    return Err(io_to_status(e));
                }
            }
        }

        if let (Some(share), true) =
            (open.share.as_ref(), open.bytes_read > 0 || open.bytes_written > 0)
        {
            events(ServerEvent::Transfer {
                connection,
                share: share.name.clone(),
                path: share.relative_name(&open.path),
                outbound: open.bytes_read >= open.bytes_written,
                bytes: open.bytes_read.max(open.bytes_written),
            });
        }

        let entry = entry_for(&open.path, file_name_of(&open.path));
        let mut w = Writer::with_capacity(60);
        w.u16(60).u16(flags & 1).u32(0);
        match (flags & 1 != 0, entry) {
            (true, Some(entry)) => {
                w.u64(entry.created)
                    .u64(entry.accessed)
                    .u64(entry.modified)
                    .u64(entry.modified)
                    .u64(entry.allocated)
                    .u64(entry.size)
                    .u32(entry.attributes);
            }
            _ => {
                w.zeros(48).u32(0);
            }
        }
        Ok(Reply::ok(w.into_vec()))
    }

    fn flush(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved2 = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let id = Self::file_id(&mut r, chain_file)?;

        let session = self.session_mut(header)?;
        let open = session.opens.get_mut(&id).ok_or(status::FILE_CLOSED)?;
        if let Some(file) = open.file.as_mut() {
            file.flush().map_err(io_to_status)?;
            file.sync_data().map_err(io_to_status)?;
        }
        let mut w = Writer::with_capacity(4);
        w.u16(4).u16(0);
        Ok(Reply::ok(w.into_vec()))
    }

    // ── READ / WRITE ───────────────────────────────────────────────────────

    fn read(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _padding = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let _flags = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let length = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let offset = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let id = Self::file_id(&mut r, chain_file)?;
        let minimum = r.u32().map_err(|_| status::INVALID_PARAMETER)?;

        if length > MAX_READ {
            return Err(status::INVALID_PARAMETER);
        }
        let session = self.session_mut(header)?;
        let open = session.opens.get_mut(&id).ok_or(status::FILE_CLOSED)?;
        if open.is_dir {
            return Err(status::INVALID_DEVICE_REQUEST);
        }
        // A pipe read returns whatever the last call left waiting, not bytes at
        // an offset — the offset field is meaningless on a pipe.
        if let Some(pipe) = open.pipe.as_mut() {
            let buffered = pipe.read(length as usize);
            return Ok(Reply::ok(read_body(&buffered)));
        }
        let file = open.file.as_mut().ok_or(status::FILE_CLOSED)?;

        file.seek(SeekFrom::Start(offset)).map_err(io_to_status)?;
        let mut buffer = vec![0u8; length as usize];
        let mut filled = 0usize;
        while filled < buffer.len() {
            match file.read(&mut buffer[filled..]) {
                Ok(0) => break,
                Ok(n) => filled += n,
                Err(ref e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(io_to_status(e)),
            }
        }
        buffer.truncate(filled);
        if filled == 0 && length > 0 {
            return Err(status::END_OF_FILE);
        }
        if (filled as u32) < minimum {
            return Err(status::END_OF_FILE);
        }
        open.bytes_read += filled as u64;
        Ok(Reply::ok(read_body(&buffer)))
    }

    fn write(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        // A write to IPC$ is an RPC request, not a file change, so the
        // share's read-only flag has nothing to say about it.
        if let Tree::Disk(share) = self.tree_of(header)? {
            if !share.writable_by(self.is_guest(header)) {
                return Err(status::MEDIA_WRITE_PROTECTED);
            }
        }

        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let data_offset = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let length = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let offset = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let id = Self::file_id(&mut r, chain_file)?;

        if length > MAX_WRITE as usize {
            return Err(status::INVALID_PARAMETER);
        }
        let start = data_offset
            .checked_sub(HEADER_SIZE)
            .ok_or(status::INVALID_PARAMETER)?;
        let data = Reader::new(body)
            .slice_at(start, length)
            .map_err(|_| status::INVALID_PARAMETER)?
            .to_vec();

        // A write to a pipe is an RPC request; the reply waits for the read
        // that follows it.
        let is_pipe = self
            .sessions
            .get(&header.session_id)
            .and_then(|s| s.opens.get(&id))
            .map(|open| open.is_pipe())
            .unwrap_or(false);
        if is_pipe {
            self.pipe_call(header, id, &data)?;
            return Ok(Reply::ok(write_body(data.len() as u32)));
        }

        let session = self.session_mut(header)?;
        let open = session.opens.get_mut(&id).ok_or(status::FILE_CLOSED)?;
        if open.is_dir {
            return Err(status::INVALID_DEVICE_REQUEST);
        }
        if !access::is_write(open.granted) {
            return Err(status::ACCESS_DENIED);
        }
        let file = open.file.as_mut().ok_or(status::FILE_CLOSED)?;
        file.seek(SeekFrom::Start(offset)).map_err(io_to_status)?;
        file.write_all(&data).map_err(io_to_status)?;
        open.bytes_written += data.len() as u64;
        Ok(Reply::ok(write_body(data.len() as u32)))
    }
}

/// A READ response carrying `data`.
fn read_body(data: &[u8]) -> Vec<u8> {
    let data_offset = HEADER_SIZE + 16;
    let mut w = Writer::with_capacity(16 + data.len());
    w.u16(17)
        .u8(data_offset as u8)
        .u8(0)
        .u32(data.len() as u32)
        .u32(0)
        .u32(0)
        .bytes(data);
    w.into_vec()
}

/// A WRITE response acknowledging `written` bytes.
fn write_body(written: u32) -> Vec<u8> {
    let mut w = Writer::with_capacity(16);
    w.u16(17).u16(0).u32(written).u32(0).u16(0).u16(0);
    w.into_vec()
}

// ── directory listing ──────────────────────────────────────────────────────

impl Conn {
    fn query_directory(
        &mut self,
        header: &Header,
        body: &[u8],
        chain_file: &mut u64,
    ) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let info_class = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let flags = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let _file_index = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let id = Self::file_id(&mut r, chain_file)?;
        let name_offset = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let name_length = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let output_limit = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;

        let pattern = if name_length == 0 {
            "*".to_string()
        } else {
            let start = name_offset
                .checked_sub(HEADER_SIZE)
                .ok_or(status::INVALID_PARAMETER)?;
            let raw = Reader::new(body)
                .slice_at(start, name_length)
                .map_err(|_| status::INVALID_PARAMETER)?;
            utf16le_to_string(raw).map_err(|_| status::INVALID_PARAMETER)?
        };

        const RESTART_SCANS: u8 = 0x01;
        const RETURN_SINGLE_ENTRY: u8 = 0x02;
        const REOPEN: u8 = 0x10;

        let session = self.session_mut(header)?;
        let open = session.opens.get_mut(&id).ok_or(status::FILE_CLOSED)?;
        if !open.is_dir {
            return Err(status::INVALID_PARAMETER);
        }

        if open.listing.is_none() || flags & (RESTART_SCANS | REOPEN) != 0 {
            open.listing = Some(read_directory(&open.path, &pattern)?);
            open.listing_index = 0;
        }
        // Taken out of the handle for the duration so the index can advance
        // alongside it; put back before returning.
        let entries = open.listing.take().ok_or(status::INVALID_PARAMETER)?;
        let mut index = open.listing_index;

        let restore = |open: &mut Open, entries, index| {
            open.listing = Some(entries);
            open.listing_index = index;
        };
        if entries.is_empty() {
            restore(open, entries, index);
            return Err(status::NO_SUCH_FILE);
        }
        if index >= entries.len() {
            restore(open, entries, index);
            return Err(status::NO_MORE_FILES);
        }

        // A client that asks for gigabytes shouldn't make us allocate them.
        let limit = output_limit.min(MAX_TRANSACT as usize);
        let mut payload: Vec<u8> = Vec::with_capacity(limit.min(64 * 1024));
        let mut last_start: Option<usize> = None;
        let mut last_unpadded = 0usize;
        let mut failure: Option<u32> = None;

        while index < entries.len() {
            let mut item = Writer::new();
            if !encode_dir_entry(&mut item, info_class, &entries[index]) {
                failure = Some(status::INVALID_PARAMETER);
                break;
            }
            let mut bytes = item.into_vec();
            let unpadded = bytes.len();
            let padding = (8 - unpadded % 8) % 8;
            bytes.resize(unpadded + padding, 0);

            if payload.len() + bytes.len() > limit {
                if last_start.is_none() {
                    // Not even one entry fits: the client must ask again with
                    // a bigger buffer.
                    failure = Some(status::INFO_LENGTH_MISMATCH);
                }
                break;
            }
            let start = payload.len();
            payload.extend_from_slice(&bytes);
            if let Some(previous) = last_start {
                let delta = ((start - previous) as u32).to_le_bytes();
                payload[previous..previous + 4].copy_from_slice(&delta);
            }
            last_start = Some(start);
            last_unpadded = unpadded;
            index += 1;
            if flags & RETURN_SINGLE_ENTRY != 0 {
                break;
            }
        }

        if let Some(previous) = last_start {
            // The final entry ends the chain and needs no trailing padding.
            payload[previous..previous + 4].copy_from_slice(&0u32.to_le_bytes());
            payload.truncate(previous + last_unpadded);
        }
        restore(open, entries, index);
        if let Some(code) = failure {
            return Err(code);
        }

        let mut w = Writer::with_capacity(8 + payload.len());
        w.u16(9);
        let offset_at = w.len();
        w.u16(0).u32(payload.len() as u32);
        let offset = HEADER_SIZE + w.len();
        w.bytes(&payload);
        w.patch_u16(offset_at, offset as u16);
        Ok(Reply::ok(w.into_vec()))
    }

    // ── QUERY_INFO / SET_INFO ──────────────────────────────────────────────

    fn query_info(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let kind = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let info_class = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let output_limit = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let _input_offset = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _input_length = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let _additional = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let _flags = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let id = Self::file_id(&mut r, chain_file)?;

        let session = self
            .sessions
            .get(&header.session_id)
            .filter(|s| s.authenticated)
            .ok_or(status::USER_SESSION_DELETED)?;
        let open = session.opens.get(&id).ok_or(status::FILE_CLOSED)?;
        let entry =
            entry_for(&open.path, file_name_of(&open.path)).ok_or(status::OBJECT_NAME_NOT_FOUND)?;

        let payload = match kind {
            info_type::FILE => encode_file_info(info_class, &entry, open)?,
            info_type::FILESYSTEM => encode_fs_info(info_class, open.share()?)?,
            // A real ACL would be a fiction: the share's own read-only flag is
            // the whole of this server's access control.
            info_type::SECURITY => return Err(status::NOT_SUPPORTED),
            _ => return Err(status::NOT_SUPPORTED),
        };
        if payload.len() > output_limit {
            return Err(status::INFO_LENGTH_MISMATCH);
        }

        let mut w = Writer::with_capacity(8 + payload.len());
        w.u16(9);
        let offset_at = w.len();
        w.u16(0).u32(payload.len() as u32);
        let offset = HEADER_SIZE + w.len();
        w.bytes(&payload);
        w.patch_u16(offset_at, offset as u16);
        Ok(Reply::ok(w.into_vec()))
    }

    fn set_info(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        let share = self.share_of(header)?;
        if !share.writable_by(self.is_guest(header)) {
            return Err(status::MEDIA_WRITE_PROTECTED);
        }

        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let kind = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let info_class = r.u8().map_err(|_| status::INVALID_PARAMETER)?;
        let buffer_length = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let buffer_offset = r.u16().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let _reserved = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _additional = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let id = Self::file_id(&mut r, chain_file)?;

        if kind != info_type::FILE {
            return Err(status::NOT_SUPPORTED);
        }
        let start = buffer_offset
            .checked_sub(HEADER_SIZE)
            .ok_or(status::INVALID_PARAMETER)?;
        let input = Reader::new(body)
            .slice_at(start, buffer_length)
            .map_err(|_| status::INVALID_PARAMETER)?
            .to_vec();

        let session = self.session_mut(header)?;
        let open = session.opens.get_mut(&id).ok_or(status::FILE_CLOSED)?;

        match info_class {
            file_info::DISPOSITION => {
                let delete = input.first().copied().unwrap_or(0) != 0;
                if delete && open.is_dir {
                    // Fail now rather than at close, where the client can no
                    // longer be told which operation went wrong.
                    let empty = fs::read_dir(&open.path)
                        .map_err(io_to_status)?
                        .next()
                        .is_none();
                    if !empty {
                        return Err(status::DIRECTORY_NOT_EMPTY);
                    }
                }
                open.delete_on_close = delete;
            }
            file_info::END_OF_FILE | file_info::ALLOCATION => {
                let size = Reader::new(&input)
                    .u64()
                    .map_err(|_| status::INVALID_PARAMETER)?;
                let file = open.file.as_mut().ok_or(status::INVALID_DEVICE_REQUEST)?;
                file.set_len(size).map_err(io_to_status)?;
            }
            file_info::RENAME => {
                let target = parse_rename(&input)?;
                let destination = open
                    .share()?
                    .resolve(&target.name)
                    .ok_or(status::OBJECT_PATH_SYNTAX_BAD)?;
                if destination.exists() {
                    if !target.replace {
                        return Err(status::OBJECT_NAME_COLLISION);
                    }
                    // `rename` replaces a file silently but refuses a
                    // non-empty directory; make that explicit.
                    if destination.is_dir() {
                        return Err(status::OBJECT_NAME_COLLISION);
                    }
                }
                fs::rename(&open.path, &destination).map_err(io_to_status)?;
                open.path = destination;
            }
            file_info::BASIC => {
                // Only the read-only bit maps onto something this server can
                // honour; timestamps are accepted and ignored, which is what
                // keeps a Windows copy from failing at the last step.
                if input.len() >= 36 {
                    let attributes =
                        u32::from_le_bytes([input[32], input[33], input[34], input[35]]);
                    if attributes != 0 {
                        if let Ok(meta) = fs::metadata(&open.path) {
                            let mut permissions = meta.permissions();
                            permissions.set_readonly(attributes & attr::READONLY != 0);
                            let _ = fs::set_permissions(&open.path, permissions);
                        }
                    }
                }
            }
            file_info::POSITION | file_info::MODE => {}
            _ => return Err(status::NOT_SUPPORTED),
        }

        let mut w = Writer::with_capacity(2);
        w.u16(2);
        Ok(Reply::ok(w.into_vec()))
    }

    // ── IOCTL ──────────────────────────────────────────────────────────────

    fn ioctl(&mut self, header: &Header, body: &[u8], chain_file: &mut u64) -> Handled {
        let mut r = Reader::new(body);
        let _structure_size = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let _reserved = r.u16().map_err(|_| status::INVALID_PARAMETER)?;
        let control_code = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
        let persistent = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let volatile = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let input_offset = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;
        let input_count = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;

        let file_id = if persistent == FILE_ID_INHERIT && volatile == FILE_ID_INHERIT {
            *chain_file
        } else {
            volatile
        };
        let input = if input_count == 0 {
            Vec::new()
        } else {
            let start = input_offset
                .checked_sub(HEADER_SIZE)
                .ok_or(status::INVALID_PARAMETER)?;
            Reader::new(body)
                .slice_at(start, input_count)
                .map_err(|_| status::INVALID_PARAMETER)?
                .to_vec()
        };

        let output = match control_code {
            fsctl::PIPE_TRANSCEIVE => self.pipe_call(header, file_id, &input)?,
            // A client waiting for a pipe that already exists has nothing to
            // wait for.
            fsctl::PIPE_WAIT => Vec::new(),
            fsctl::VALIDATE_NEGOTIATE_INFO => {
                // The client is checking that the negotiate it saw wasn't
                // tampered with. Echoing what we actually chose is the whole
                // point; a mismatch makes the client disconnect, correctly.
                let mut w = Writer::with_capacity(24);
                w.u32(capabilities::LARGE_MTU)
                    .bytes(&self.server_guid)
                    .u16(
                        security_mode::SIGNING_ENABLED
                            | if self.config.require_signing {
                                security_mode::SIGNING_REQUIRED
                            } else {
                                0
                            },
                    )
                    .u16(self.dialect.code());
                w.into_vec()
            }
            fsctl::SRV_REQUEST_RESUME_KEY => {
                let session = self.session_mut(header)?;
                if !session.opens.contains_key(&file_id) {
                    return Err(status::FILE_CLOSED);
                }
                let mut w = Writer::with_capacity(32);
                w.u64(file_id).u64(RESUME_MAGIC).zeros(8).u32(0).u32(0);
                w.into_vec()
            }
            fsctl::SRV_COPYCHUNK | fsctl::SRV_COPYCHUNK_WRITE => {
                self.copy_chunks(header, file_id, &input)?
            }
            // DFS and multi-channel are things this server deliberately isn't.
            fsctl::DFS_GET_REFERRALS | fsctl::QUERY_NETWORK_INTERFACE_INFO => {
                return Err(status::NOT_SUPPORTED)
            }
            _ => return Err(status::NOT_SUPPORTED),
        };

        let mut w = Writer::with_capacity(48 + output.len());
        w.u16(49)
            .u16(0)
            .u32(control_code)
            .u64(persistent)
            .u64(volatile)
            .u32(0)
            .u32(0);
        let output_offset_at = w.len();
        w.u32(0).u32(output.len() as u32).u32(0).u32(0);
        let offset = HEADER_SIZE + w.len();
        w.bytes(&output);
        w.patch_u32(output_offset_at, offset as u32);
        Ok(Reply::ok(w.into_vec()))
    }

    /// Server-side copy: the client names a source handle and a list of byte
    /// ranges, and the bytes never leave the machine. This is what makes
    /// duplicating a large file on a share nearly instant.
    fn copy_chunks(
        &mut self,
        header: &Header,
        target_id: u64,
        input: &[u8],
    ) -> Result<Vec<u8>, u32> {
        let is_guest = self.is_guest(header);
        let mut r = Reader::new(input);
        let source_id = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        let magic = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
        r.skip(8).map_err(|_| status::INVALID_PARAMETER)?;
        let chunk_count = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;
        r.skip(4).map_err(|_| status::INVALID_PARAMETER)?;

        if magic != RESUME_MAGIC {
            return Err(status::INVALID_PARAMETER);
        }
        const MAX_CHUNKS: usize = 256;
        const MAX_CHUNK_BYTES: u32 = 1024 * 1024;
        if chunk_count == 0 || chunk_count > MAX_CHUNKS {
            return Err(status::INVALID_PARAMETER);
        }

        let mut requests = Vec::with_capacity(chunk_count);
        for _ in 0..chunk_count {
            let source_offset = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
            let target_offset = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
            let length = r.u32().map_err(|_| status::INVALID_PARAMETER)?;
            r.skip(4).map_err(|_| status::INVALID_PARAMETER)?;
            if length > MAX_CHUNK_BYTES {
                return Err(status::INVALID_PARAMETER);
            }
            requests.push((source_offset, target_offset, length));
        }

        let session = self
            .sessions
            .get_mut(&header.session_id)
            .filter(|s| s.authenticated)
            .ok_or(status::USER_SESSION_DELETED)?;
        if session.opens.get(&source_id).is_none_or(|o| o.is_dir) {
            return Err(status::INVALID_PARAMETER);
        }
        if session.opens.get(&target_id).is_none_or(|o| o.is_dir) {
            return Err(status::INVALID_PARAMETER);
        }
        if session
            .opens
            .get(&target_id)
            .and_then(|o| o.share.as_ref())
            .is_none_or(|share| !share.writable_by(is_guest))
        {
            return Err(status::MEDIA_WRITE_PROTECTED);
        }

        let mut total = 0u32;
        let mut done = 0u32;
        for (source_offset, target_offset, length) in requests {
            let mut buffer = vec![0u8; length as usize];
            {
                let source = session
                    .opens
                    .get_mut(&source_id)
                    .ok_or(status::FILE_CLOSED)?;
                let file = source.file.as_mut().ok_or(status::FILE_CLOSED)?;
                file.seek(SeekFrom::Start(source_offset))
                    .map_err(io_to_status)?;
                file.read_exact(&mut buffer).map_err(io_to_status)?;
                source.bytes_read += length as u64;
            }
            {
                let target = session
                    .opens
                    .get_mut(&target_id)
                    .ok_or(status::FILE_CLOSED)?;
                let file = target.file.as_mut().ok_or(status::FILE_CLOSED)?;
                file.seek(SeekFrom::Start(target_offset))
                    .map_err(io_to_status)?;
                file.write_all(&buffer).map_err(io_to_status)?;
                target.bytes_written += length as u64;
            }
            total += length;
            done += 1;
        }

        let mut w = Writer::with_capacity(12);
        w.u32(done).u32(total).u32(total);
        Ok(w.into_vec())
    }
}

/// Marker in a resume key, so a forged one is rejected before it is used to
/// address a handle.
const RESUME_MAGIC: u64 = 0x4E4F_5449_4C55_5301;

struct RenameTarget {
    replace: bool,
    name: String,
}

fn parse_rename(input: &[u8]) -> Result<RenameTarget, u32> {
    let mut r = Reader::new(input);
    let replace = r.u8().map_err(|_| status::INVALID_PARAMETER)? != 0;
    r.skip(7).map_err(|_| status::INVALID_PARAMETER)?;
    let root = r.u64().map_err(|_| status::INVALID_PARAMETER)?;
    if root != 0 {
        // A rename relative to another open handle. No client this server
        // meets uses it, and guessing would move the wrong file.
        return Err(status::NOT_SUPPORTED);
    }
    let length = r.u32().map_err(|_| status::INVALID_PARAMETER)? as usize;
    let raw = r.take(length).map_err(|_| status::INVALID_PARAMETER)?;
    let name = utf16le_to_string(raw).map_err(|_| status::OBJECT_PATH_SYNTAX_BAD)?;
    Ok(RenameTarget { replace, name })
}

// ── filesystem helpers ─────────────────────────────────────────────────────

fn file_name_of(path: &std::path::Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "\\".into())
}

/// Turns one path into the fields every SMB2 information class is built from.
fn entry_for(path: &std::path::Path, name: String) -> Option<Entry> {
    let meta = fs::metadata(path).ok()?;
    let is_dir = meta.is_dir();
    let size = if is_dir { 0 } else { meta.len() };

    let mut attributes = if is_dir { attr::DIRECTORY } else { attr::ARCHIVE };
    if meta.permissions().readonly() {
        attributes |= attr::READONLY;
    }
    // A leading dot is the Unix convention for hidden, and clients render the
    // HIDDEN attribute the way users expect.
    if name.starts_with('.') && name != "." && name != ".." {
        attributes |= attr::HIDDEN;
    }

    let modified = system_time_to_filetime(meta.modified().ok());
    let accessed = system_time_to_filetime(meta.accessed().ok());
    // Not every filesystem records a creation time; the modification time is a
    // better answer than 1601.
    let created = match meta.created().ok() {
        Some(time) => system_time_to_filetime(Some(time)),
        None => modified,
    };

    Some(Entry {
        name,
        is_dir,
        size,
        // Rounded up to a 4 KB cluster, which is what a client expects
        // "size on disk" to look like.
        allocated: size.div_ceil(4096) * 4096,
        created,
        accessed: if accessed == 0 { modified } else { accessed },
        modified,
        attributes,
        inode: inode_of(&meta, path),
    })
}

#[cfg(unix)]
fn inode_of(meta: &fs::Metadata, _path: &std::path::Path) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.ino()
}

#[cfg(not(unix))]
fn inode_of(_meta: &fs::Metadata, path: &std::path::Path) -> u64 {
    // No inode to report. A stable hash of the path is what clients actually
    // use this for — telling two entries apart within one listing.
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hasher);
    hasher.finish()
}

/// The entries of `path` matching `pattern`, sorted the way a client expects.
fn read_directory(path: &std::path::Path, pattern: &str) -> Result<Vec<Entry>, u32> {
    let mut out = Vec::new();

    // "." and ".." are part of a directory listing on the wire, and some
    // clients treat their absence as a broken server.
    for (name, target) in [(".", path.to_path_buf()), ("..", parent_or_self(path))] {
        if matches_pattern(pattern, name) {
            if let Some(mut entry) = entry_for(&target, name.to_string()) {
                entry.is_dir = true;
                entry.attributes |= attr::DIRECTORY;
                out.push(entry);
            }
        }
    }

    let listing = fs::read_dir(path).map_err(io_to_status)?;
    let mut items = Vec::new();
    for entry in listing.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !matches_pattern(pattern, &name) {
            continue;
        }
        if let Some(item) = entry_for(&entry.path(), name) {
            items.push(item);
        }
    }
    items.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out.append(&mut items);
    Ok(out)
}

fn parent_or_self(path: &std::path::Path) -> PathBuf {
    path.parent().unwrap_or(path).to_path_buf()
}

/// Maps a local I/O failure onto the status code that says the same thing.
fn io_to_status(error: std::io::Error) -> u32 {
    match error.kind() {
        ErrorKind::NotFound => status::OBJECT_NAME_NOT_FOUND,
        ErrorKind::PermissionDenied => status::ACCESS_DENIED,
        ErrorKind::AlreadyExists => status::OBJECT_NAME_COLLISION,
        ErrorKind::InvalidInput => status::INVALID_PARAMETER,
        ErrorKind::UnexpectedEof => status::END_OF_FILE,
        ErrorKind::WriteZero => status::DISK_FULL,
        _ => match error.raw_os_error() {
            // ENOTEMPTY differs by platform and has no ErrorKind of its own.
            Some(39) | Some(66) => status::DIRECTORY_NOT_EMPTY,
            Some(28) => status::DISK_FULL,
            Some(21) => status::FILE_IS_A_DIRECTORY,
            Some(20) => status::NOT_A_DIRECTORY,
            _ => status::ACCESS_DENIED,
        },
    }
}

// ── information-class encoders ─────────────────────────────────────────────

/// Writes one directory entry in `class`'s layout. Returns false for a class
/// this server doesn't produce, which the caller turns into a status code.
fn encode_dir_entry(w: &mut Writer, class: u8, entry: &Entry) -> bool {
    let name = super::wire::string_to_utf16le(&entry.name);

    // Every class but FileNamesInformation opens with the same 56 bytes.
    let common = |w: &mut Writer| {
        w.u32(0) // NextEntryOffset, patched by the caller
            .u32(0) // FileIndex; zero means "no resume index"
            .u64(entry.created)
            .u64(entry.accessed)
            .u64(entry.modified)
            .u64(entry.modified)
            .u64(entry.size)
            .u64(entry.allocated)
            .u32(entry.attributes)
            .u32(name.len() as u32);
    };

    match class {
        dir_info::DIRECTORY => {
            common(w);
            w.bytes(&name);
        }
        dir_info::FULL_DIRECTORY => {
            common(w);
            w.u32(0) // EaSize
                .bytes(&name);
        }
        dir_info::ID_FULL_DIRECTORY => {
            common(w);
            w.u32(0) // EaSize
                .u32(0) // Reserved
                .u64(entry.inode)
                .bytes(&name);
        }
        dir_info::BOTH_DIRECTORY => {
            common(w);
            w.u32(0) // EaSize
                .u8(0) // ShortNameLength — 8.3 names aren't synthesised
                .u8(0)
                .zeros(24)
                .bytes(&name);
        }
        dir_info::ID_BOTH_DIRECTORY => {
            common(w);
            w.u32(0)
                .u8(0)
                .u8(0)
                .zeros(24)
                .u16(0) // Reserved2
                .u64(entry.inode)
                .bytes(&name);
        }
        dir_info::NAMES => {
            w.u32(0)
                .u32(0)
                .u32(name.len() as u32)
                .bytes(&name);
        }
        _ => return false,
    }
    true
}

fn encode_file_info(class: u8, entry: &Entry, open: &Open) -> Result<Vec<u8>, u32> {
    let mut w = Writer::with_capacity(128);
    match class {
        file_info::BASIC => {
            w.u64(entry.created)
                .u64(entry.accessed)
                .u64(entry.modified)
                .u64(entry.modified)
                .u32(entry.attributes)
                .u32(0);
        }
        file_info::STANDARD => {
            w.u64(entry.allocated)
                .u64(entry.size)
                .u32(1) // NumberOfLinks
                .u8(open.delete_on_close as u8)
                .u8(entry.is_dir as u8)
                .u16(0);
        }
        file_info::INTERNAL => {
            w.u64(entry.inode);
        }
        file_info::EA => {
            w.u32(0);
        }
        file_info::ACCESS => {
            w.u32(open.granted);
        }
        file_info::POSITION => {
            w.u64(0);
        }
        file_info::MODE => {
            w.u32(0);
        }
        file_info::ALIGNMENT => {
            w.u32(0); // FILE_BYTE_ALIGNMENT
        }
        file_info::NAME => {
            let name = super::wire::string_to_utf16le(&format!(
                "\\{}",
                open.share()?.relative_name(&open.path)
            ));
            w.u32(name.len() as u32).bytes(&name);
        }
        file_info::NETWORK_OPEN => {
            w.u64(entry.created)
                .u64(entry.accessed)
                .u64(entry.modified)
                .u64(entry.modified)
                .u64(entry.allocated)
                .u64(entry.size)
                .u32(entry.attributes)
                .u32(0);
        }
        file_info::ATTRIBUTE_TAG => {
            w.u32(entry.attributes).u32(0);
        }
        file_info::COMPRESSION => {
            w.u64(entry.size).u16(0).u8(0).u8(0).u8(0).zeros(3);
        }
        file_info::STREAM => {
            if entry.is_dir {
                // A directory has no data stream; an empty answer is correct.
                return Ok(Vec::new());
            }
            let name = super::wire::string_to_utf16le("::$DATA");
            w.u32(0)
                .u32(name.len() as u32)
                .u64(entry.size)
                .u64(entry.allocated)
                .bytes(&name);
        }
        file_info::ALL => {
            // The concatenation of Basic, Standard, Internal, Ea, Access,
            // Position, Mode, Alignment and Name, in that order.
            w.u64(entry.created)
                .u64(entry.accessed)
                .u64(entry.modified)
                .u64(entry.modified)
                .u32(entry.attributes)
                .u32(0)
                .u64(entry.allocated)
                .u64(entry.size)
                .u32(1)
                .u8(open.delete_on_close as u8)
                .u8(entry.is_dir as u8)
                .u16(0)
                .u64(entry.inode)
                .u32(0) // EaSize
                .u32(open.granted)
                .u64(0) // CurrentByteOffset
                .u32(0) // Mode
                .u32(0); // AlignmentRequirement
            let name = super::wire::string_to_utf16le(&format!(
                "\\{}",
                open.share()?.relative_name(&open.path)
            ));
            w.u32(name.len() as u32).bytes(&name);
        }
        _ => return Err(status::NOT_SUPPORTED),
    }
    Ok(w.into_vec())
}

fn encode_fs_info(class: u8, share: &Share) -> Result<Vec<u8>, u32> {
    let space = disk_space(&share.root);
    const SECTOR: u32 = 512;
    const SECTORS_PER_UNIT: u32 = 8; // 4 KB clusters
    let unit = (SECTOR * SECTORS_PER_UNIT) as u64;

    let mut w = Writer::with_capacity(64);
    match class {
        fs_info::VOLUME => {
            let label = super::wire::string_to_utf16le(&share.name);
            w.u64(0)
                .u32(0x4E54_4C53) // Serial number; stable but arbitrary.
                .u32(label.len() as u32)
                .u8(0)
                .u8(0)
                .bytes(&label);
        }
        fs_info::SIZE => {
            w.u64(space.total / unit)
                .u64(space.free / unit)
                .u32(SECTORS_PER_UNIT)
                .u32(SECTOR);
        }
        fs_info::FULL_SIZE => {
            w.u64(space.total / unit)
                .u64(space.free / unit)
                .u64(space.free / unit)
                .u32(SECTORS_PER_UNIT)
                .u32(SECTOR);
        }
        fs_info::DEVICE => {
            w.u32(0x0000_0007) // FILE_DEVICE_DISK
                .u32(0x0000_0010); // FILE_DEVICE_IS_MOUNTED
        }
        fs_info::ATTRIBUTE => {
            let name = super::wire::string_to_utf16le("NTFS");
            // Case-sensitive search, case-preserving names, Unicode names.
            // Deliberately not claiming compression, quotas or ACLs.
            w.u32(0x0000_0003 | 0x0000_0004)
                .u32(255)
                .u32(name.len() as u32)
                .bytes(&name);
        }
        fs_info::SECTOR_SIZE => {
            w.u32(SECTOR)
                .u32(SECTOR)
                .u32(SECTOR)
                .u32(SECTOR)
                .u32(0)
                .u32(0)
                .u32(0);
        }
        fs_info::OBJECT_ID => return Err(status::NOT_SUPPORTED),
        _ => return Err(status::NOT_SUPPORTED),
    }
    Ok(w.into_vec())
}

pub(crate) struct DiskSpace {
    pub total: u64,
    pub free: u64,
}

/// Free and total bytes on the filesystem holding `path`.
///
/// Clients check this before starting a copy, so a made-up number would let a
/// transfer begin that can't finish.
#[cfg(unix)]
pub(crate) fn disk_space(path: &std::path::Path) -> DiskSpace {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let fallback = DiskSpace {
        total: 1 << 40,
        free: 1 << 39,
    };
    let Ok(c_path) = CString::new(path.as_os_str().as_bytes()) else {
        return fallback;
    };
    // SAFETY: `stat` is written by `statvfs` before it is read, and `c_path`
    // is a valid NUL-terminated string that outlives the call.
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c_path.as_ptr(), &mut stat) != 0 {
            return fallback;
        }
        let block = if stat.f_frsize > 0 {
            stat.f_frsize as u64
        } else {
            stat.f_bsize as u64
        };
        DiskSpace {
            total: stat.f_blocks as u64 * block,
            free: stat.f_bavail as u64 * block,
        }
    }
}

#[cfg(not(unix))]
pub(crate) fn disk_space(_path: &std::path::Path) -> DiskSpace {
    // Windows would need GetDiskFreeSpaceEx, which isn't worth a new
    // dependency here: the desktop build that hosts a share is the Unix one.
    DiskSpace {
        total: 1 << 40,
        free: 1 << 39,
    }
}
