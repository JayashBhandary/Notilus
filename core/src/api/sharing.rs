//! File sharing, in the shape the bridge can carry.
//!
//! Two halves, both stateful in a way Dart can't hold directly:
//!
//! - The **server** is one process-wide instance. Dart starts it with a
//!   configuration and receives events on a stream; there is nothing to hold on
//!   to but the fact that it is running.
//! - The **client** keeps live TCP sessions. Dart addresses them by an opaque
//!   id, and open files by a second id inside that session, which is what lets
//!   a download stream rather than arrive as one enormous byte array.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use crate::smb::client::{Client, ClientConfig, ClientError, FileHandle};
use crate::smb::server::{self, ServerConfig, ServerEvent, User};
use crate::smb::share::Share;

// ── shared types ───────────────────────────────────────────────────────────

/// One folder to publish.
#[derive(Clone, Debug)]
pub struct SmbShareConfig {
    pub name: String,
    pub path: String,
    pub read_only: bool,
    pub comment: String,
    /// Accounts allowed to attach. Empty means every account that can sign in,
    /// which is what a one-person setup wants.
    pub allowed_users: Vec<String>,
    /// Whether someone with no account may attach. A guest is never granted
    /// write access, whatever `read_only` says.
    pub guest_ok: bool,
}

/// One account allowed to connect.
///
/// The password crosses the bridge once, at start, and is immediately reduced
/// to the hash the protocol needs; the running server never holds it.
#[derive(Clone, Debug)]
pub struct SmbUserConfig {
    pub username: String,
    pub password: String,
}

#[derive(Clone, Debug)]
pub struct SmbServerSettings {
    /// Address to listen on. `0.0.0.0` for the whole network, `127.0.0.1` to
    /// keep the share on this machine.
    pub bind: String,
    /// 0 asks the OS for a free port. 445 — the port other operating systems
    /// look for — needs administrator rights on every platform.
    pub port: u16,
    pub server_name: String,
    pub workgroup: String,
    pub shares: Vec<SmbShareConfig>,
    pub users: Vec<SmbUserConfig>,
    pub require_signing: bool,
    pub max_connections: u32,
}

#[derive(Clone, Debug)]
pub struct SmbServerStatus {
    pub running: bool,
    pub port: u16,
    pub connections: u32,
}

#[derive(Clone, Debug)]
pub struct SmbConnectionEvent {
    pub connection: u64,
    pub peer: String,
    pub user: String,
    /// The dialect for an authentication, the reason for a rejection, empty
    /// otherwise.
    pub detail: String,
}

#[derive(Clone, Debug)]
pub struct SmbTransferEvent {
    pub connection: u64,
    pub share: String,
    pub path: String,
    /// True when the client was downloading from the share.
    pub outbound: bool,
    pub bytes: u64,
}

#[derive(Clone, Debug)]
pub enum SmbServerEvent {
    Started(u16),
    Stopped,
    Connected(SmbConnectionEvent),
    Authenticated(SmbConnectionEvent),
    Rejected(SmbConnectionEvent),
    Disconnected(SmbConnectionEvent),
    Transfer(SmbTransferEvent),
}

/// One entry in a remote listing.
#[derive(Clone, Debug)]
pub struct SmbEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// Milliseconds since the epoch; 0 when the server reported none.
    pub modified_ms: i64,
    pub created_ms: i64,
    pub is_hidden: bool,
    pub is_read_only: bool,
}

#[derive(Clone, Debug)]
pub struct SmbSession {
    pub id: String,
    /// e.g. `SMB 3.1.1` — shown so a user can see what was negotiated.
    pub dialect: String,
}

#[derive(Clone, Debug)]
pub struct SmbOpenFile {
    pub handle: u64,
    pub size: u64,
}

#[derive(Clone, Debug)]
pub struct SmbClientSettings {
    pub host: String,
    pub port: u16,
    pub share: String,
    pub username: String,
    pub domain: String,
    pub password: String,
}

// ── error mapping ──────────────────────────────────────────────────────────

/// Encodes a client failure as `smb:<code> <message>`.
///
/// The bridge can only carry a `String` back, and the UI needs to tell "wrong
/// password" from "no such file" to decide whether to mark the connection
/// broken. A short machine-readable prefix costs less than a second channel.
fn encode(error: ClientError) -> String {
    let code = if error.is_auth_failure() {
        401
    } else if error.is_not_found() {
        404
    } else {
        0
    };
    format!("smb:{code} {}", error.message)
}

// ── server ─────────────────────────────────────────────────────────────────

fn server_slot() -> &'static Mutex<Option<server::Handle>> {
    static SERVER: OnceLock<Mutex<Option<server::Handle>>> = OnceLock::new();
    SERVER.get_or_init(|| Mutex::new(None))
}

/// Starts the file server, replacing any instance already running.
///
/// `on_event` is kept alive for as long as the server is, which is what keeps
/// the Dart stream open.
pub fn start_server(
    settings: SmbServerSettings,
    on_event: Arc<dyn Fn(SmbServerEvent) + Send + Sync>,
) -> Result<u16, String> {
    stop_server();

    let shares: Vec<Share> = settings
        .shares
        .iter()
        .map(|s| Share {
            name: s.name.trim().to_string(),
            root: std::path::PathBuf::from(&s.path),
            read_only: s.read_only,
            comment: s.comment.clone(),
            allowed_users: s
                .allowed_users
                .iter()
                .map(|u| u.trim().to_string())
                .filter(|u| !u.is_empty())
                .collect(),
            guest_ok: s.guest_ok,
        })
        .collect();

    for share in &shares {
        if share.name.is_empty() {
            return Err("Every shared folder needs a name.".into());
        }
        if share.name.contains(['\\', '/', ':']) {
            return Err(format!(
                "\"{}\" isn't a usable share name — leave out slashes and colons.",
                share.name
            ));
        }
    }
    let mut seen = std::collections::HashSet::new();
    for share in &shares {
        if !seen.insert(share.name.to_lowercase()) {
            return Err(format!("Two shares are both called \"{}\".", share.name));
        }
    }

    let users: Vec<User> = settings
        .users
        .iter()
        .filter(|u| !u.username.trim().is_empty())
        .map(|u| User::new(u.username.trim(), &u.password))
        .collect();
    if users.iter().any(|u| u.name.is_empty()) {
        return Err("Every user needs a name.".into());
    }

    let config = ServerConfig {
        bind: if settings.bind.trim().is_empty() {
            "0.0.0.0".into()
        } else {
            settings.bind.trim().to_string()
        },
        port: settings.port,
        server_name: if settings.server_name.trim().is_empty() {
            "NOTILUS".into()
        } else {
            settings.server_name.trim().to_uppercase()
        },
        domain: if settings.workgroup.trim().is_empty() {
            "WORKGROUP".into()
        } else {
            settings.workgroup.trim().to_uppercase()
        },
        shares,
        users,
        require_signing: settings.require_signing,
        max_connections: settings.max_connections.clamp(1, 256) as usize,
    };

    let sink = on_event.clone();
    let handle = server::start(
        config,
        Arc::new(move |event| sink(convert_event(event))),
    )?;
    let port = handle.port;
    if let Ok(mut slot) = server_slot().lock() {
        *slot = Some(handle);
    }
    Ok(port)
}

fn convert_event(event: ServerEvent) -> SmbServerEvent {
    match event {
        ServerEvent::Started { port } => SmbServerEvent::Started(port),
        ServerEvent::Stopped => SmbServerEvent::Stopped,
        ServerEvent::ClientConnected { connection, peer } => {
            SmbServerEvent::Connected(SmbConnectionEvent {
                connection,
                peer,
                user: String::new(),
                detail: String::new(),
            })
        }
        ServerEvent::ClientAuthenticated {
            connection,
            peer,
            user,
            dialect,
        } => SmbServerEvent::Authenticated(SmbConnectionEvent {
            connection,
            peer,
            user,
            detail: dialect,
        }),
        ServerEvent::ClientRejected {
            connection,
            peer,
            reason,
        } => SmbServerEvent::Rejected(SmbConnectionEvent {
            connection,
            peer,
            user: String::new(),
            detail: reason,
        }),
        ServerEvent::ClientDisconnected { connection, peer } => {
            SmbServerEvent::Disconnected(SmbConnectionEvent {
                connection,
                peer,
                user: String::new(),
                detail: String::new(),
            })
        }
        ServerEvent::Transfer {
            connection,
            share,
            path,
            outbound,
            bytes,
        } => SmbServerEvent::Transfer(SmbTransferEvent {
            connection,
            share,
            path,
            outbound,
            bytes,
        }),
    }
}

/// Stops the server. Returns false when nothing was running.
pub fn stop_server() -> bool {
    let Ok(mut slot) = server_slot().lock() else {
        return false;
    };
    match slot.take() {
        Some(handle) => {
            handle.stop();
            true
        }
        None => false,
    }
}

pub fn server_status() -> SmbServerStatus {
    let Ok(slot) = server_slot().lock() else {
        return SmbServerStatus {
            running: false,
            port: 0,
            connections: 0,
        };
    };
    match slot.as_ref() {
        Some(handle) if handle.is_running() => SmbServerStatus {
            running: true,
            port: handle.port,
            connections: handle.active_connections() as u32,
        },
        _ => SmbServerStatus {
            running: false,
            port: 0,
            connections: 0,
        },
    }
}

// ── client sessions ────────────────────────────────────────────────────────

struct LiveSession {
    client: Client,
    opens: HashMap<u64, FileHandle>,
    next_handle: u64,
}

fn sessions() -> &'static Mutex<HashMap<String, Arc<Mutex<LiveSession>>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Mutex<LiveSession>>>>> =
        OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_session_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    format!("smb-{}", COUNTER.fetch_add(1, Ordering::SeqCst))
}

fn to_client_config(settings: &SmbClientSettings) -> ClientConfig {
    ClientConfig {
        host: settings.host.trim().to_string(),
        port: settings.port,
        share: settings.share.trim().trim_matches(['\\', '/']).to_string(),
        username: settings.username.trim().to_string(),
        domain: settings.domain.trim().to_string(),
        password: settings.password.clone(),
    }
}

/// Connects, authenticates and attaches to the share, keeping the session for
/// later calls.
pub fn client_connect(settings: SmbClientSettings) -> Result<SmbSession, String> {
    let client = Client::connect(&to_client_config(&settings)).map_err(encode)?;
    let dialect = client.dialect_label().to_string();
    let id = next_session_id();

    let session = Arc::new(Mutex::new(LiveSession {
        client,
        opens: HashMap::new(),
        next_handle: 1,
    }));
    sessions()
        .lock()
        .map_err(|_| "smb:0 The connection table is unavailable.".to_string())?
        .insert(id.clone(), session);
    Ok(SmbSession { id, dialect })
}

/// Verifies credentials without keeping the session — the "Test" button.
pub fn client_probe(settings: SmbClientSettings) -> Result<String, String> {
    let mut client = Client::connect(&to_client_config(&settings)).map_err(encode)?;
    let dialect = client.dialect_label().to_string();
    // Listing the root proves the share is usable, not merely reachable.
    let result = client.list("").map(|_| ()).map_err(encode);
    client.disconnect();
    result?;
    Ok(dialect)
}

pub fn client_disconnect(session_id: String) -> bool {
    let Ok(mut table) = sessions().lock() else {
        return false;
    };
    let Some(session) = table.remove(&session_id) else {
        return false;
    };
    drop(table);
    if let Ok(mut live) = session.lock() {
        live.client.disconnect();
    }
    true
}

/// Runs `action` against a live session.
///
/// The session table is unlocked before the session itself is, so one slow
/// request — a large read — doesn't block every other connection.
fn with_session<T>(
    session_id: &str,
    action: impl FnOnce(&mut LiveSession) -> Result<T, ClientError>,
) -> Result<T, String> {
    let session = {
        let table = sessions()
            .lock()
            .map_err(|_| "smb:0 The connection table is unavailable.".to_string())?;
        table.get(session_id).cloned()
    };
    let session = session.ok_or_else(|| {
        "smb:0 That connection has been closed. Reopen the source to reconnect."
            .to_string()
    })?;
    let mut live = session
        .lock()
        .map_err(|_| "smb:0 The connection is in an unusable state.".to_string())?;
    action(&mut live).map_err(encode)
}

fn to_entry(info: crate::smb::client::FileInfo) -> SmbEntry {
    use crate::smb::proto::attr;
    SmbEntry {
        name: info.name,
        is_dir: info.is_dir,
        size: info.size,
        modified_ms: info.modified_ms,
        created_ms: info.created_ms,
        is_hidden: info.attributes & attr::HIDDEN != 0,
        is_read_only: info.attributes & attr::READONLY != 0,
    }
}

pub fn client_list(session_id: String, path: String) -> Result<Vec<SmbEntry>, String> {
    with_session(&session_id, |live| {
        live.client
            .list(&path)
            .map(|entries| entries.into_iter().map(to_entry).collect())
    })
}

pub fn client_stat(session_id: String, path: String) -> Result<Option<SmbEntry>, String> {
    with_session(&session_id, |live| {
        live.client.stat(&path).map(|info| info.map(to_entry))
    })
}

/// Opens a file and returns a handle to read or write through.
pub fn client_open(
    session_id: String,
    path: String,
    write: bool,
    truncate: bool,
) -> Result<SmbOpenFile, String> {
    with_session(&session_id, |live| {
        let (handle, size) = if write {
            (live.client.open_write(&path, truncate)?, 0)
        } else {
            let (handle, info) = live.client.open_read(&path)?;
            (handle, info.size)
        };
        let id = live.next_handle;
        live.next_handle += 1;
        live.opens.insert(id, handle);
        Ok(SmbOpenFile { handle: id, size })
    })
}

pub fn client_read(
    session_id: String,
    handle: u64,
    offset: u64,
    length: u32,
) -> Result<Vec<u8>, String> {
    with_session(&session_id, |live| {
        let file = *live
            .opens
            .get(&handle)
            .ok_or_else(|| ClientError::local("That file is no longer open."))?;
        live.client.read_at(file, offset, length)
    })
}

pub fn client_write(
    session_id: String,
    handle: u64,
    offset: u64,
    data: Vec<u8>,
) -> Result<u32, String> {
    with_session(&session_id, |live| {
        let file = *live
            .opens
            .get(&handle)
            .ok_or_else(|| ClientError::local("That file is no longer open."))?;
        live.client.write_at(file, offset, &data)
    })
}

pub fn client_close(session_id: String, handle: u64) -> Result<(), String> {
    with_session(&session_id, |live| {
        match live.opens.remove(&handle) {
            Some(file) => live.client.close(file),
            // Closing twice is not an error worth surfacing.
            None => Ok(()),
        }
    })
}

pub fn client_create_directory(session_id: String, path: String) -> Result<(), String> {
    with_session(&session_id, |live| live.client.create_directory(&path))
}

pub fn client_delete(
    session_id: String,
    path: String,
    is_dir: bool,
) -> Result<(), String> {
    with_session(&session_id, |live| live.client.delete(&path, is_dir))
}

pub fn client_rename(
    session_id: String,
    from: String,
    to: String,
    replace: bool,
) -> Result<(), String> {
    with_session(&session_id, |live| live.client.rename(&from, &to, replace))
}

pub fn client_copy(
    session_id: String,
    from: String,
    to: String,
) -> Result<u64, String> {
    with_session(&session_id, |live| live.client.copy_within(&from, &to))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_share_name_with_a_separator_is_refused() {
        let settings = SmbServerSettings {
            bind: "127.0.0.1".into(),
            port: 0,
            server_name: "TEST".into(),
            workgroup: "WORKGROUP".into(),
            shares: vec![SmbShareConfig {
                name: "bad/name".into(),
                path: "/tmp".into(),
                read_only: true,
                comment: String::new(),
                allowed_users: Vec::new(),
                guest_ok: false,
            }],
            users: vec![SmbUserConfig {
                username: "a".into(),
                password: "b".into(),
            }],
            require_signing: true,
            max_connections: 8,
        };
        let error = start_server(settings, Arc::new(|_| {})).unwrap_err();
        assert!(error.contains("isn't a usable share name"), "got {error}");
    }

    #[test]
    fn operations_on_an_unknown_session_are_a_readable_error() {
        let error = client_list("nope".into(), String::new()).unwrap_err();
        assert!(error.starts_with("smb:0"), "got {error}");
        assert!(error.contains("closed"), "got {error}");
    }

    #[test]
    fn status_is_not_running_before_anything_starts() {
        // `stop_server` on a fresh slot must not panic, and status must agree.
        stop_server();
        let status = server_status();
        assert!(!status.running);
        assert_eq!(status.port, 0);
    }
}
