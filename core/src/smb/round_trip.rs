//! End-to-end tests that run the client in this crate against the server in
//! this crate over a real TCP socket.
//!
//! This is the only way to prove the wire format is right without a Windows
//! box in the loop: every structure is written by one half and parsed by the
//! other, so a wrong offset fails here rather than in front of a user.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use super::client::{Client, ClientConfig};
use super::server::{self, ServerConfig, ServerEvent, User};
use super::share::Share;

static COUNTER: AtomicU32 = AtomicU32::new(0);

struct Fixture {
    root: PathBuf,
    handle: server::Handle,
    events: Arc<Mutex<Vec<ServerEvent>>>,
    port: u16,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.handle.stop();
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// How a share in the fixture is exposed.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Access {
    /// Every signed-in account, writable.
    Everyone,
    /// Every signed-in account, read-only.
    ReadOnly,
    /// Only `alice`.
    AliceOnly,
    /// Anyone at all, including a client with no credentials.
    Guest,
}

fn start(label: &str, read_only: bool) -> Fixture {
    start_with(label, if read_only { Access::ReadOnly } else { Access::Everyone })
}

fn start_with(label: &str, access: Access) -> Fixture {
    let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
    let root = std::env::temp_dir().join(format!(
        "notilus-smb-{label}-{}-{unique}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("Docs")).unwrap();
    fs::write(root.join("Docs/notes.txt"), b"hello from the share").unwrap();
    fs::write(root.join("top.bin"), vec![7u8; 200_000]).unwrap();

    let events: Arc<Mutex<Vec<ServerEvent>>> = Arc::new(Mutex::new(Vec::new()));
    let sink = events.clone();

    let config = ServerConfig {
        bind: "127.0.0.1".into(),
        port: 0,
        server_name: "NOTILUS".into(),
        domain: "WORKGROUP".into(),
        shares: vec![Share {
            name: "Files".into(),
            root: root.clone(),
            read_only: access == Access::ReadOnly,
            comment: "test share".into(),
            allowed_users: match access {
                Access::AliceOnly => vec!["alice".into()],
                _ => Vec::new(),
            },
            guest_ok: access == Access::Guest,
        }],
        users: vec![
            User::new("alice", "correct horse"),
            User::new("bob", "hunter2"),
        ],
        require_signing: true,
        max_connections: 8,
    };

    let handle = server::start(
        config,
        Arc::new(move |event| {
            if let Ok(mut log) = sink.lock() {
                log.push(event);
            }
        }),
    )
    .expect("the server should bind an ephemeral port");
    let port = handle.port;

    Fixture {
        root,
        handle,
        events,
        port,
    }
}

fn connect(fixture: &Fixture, password: &str) -> Result<Client, super::client::ClientError> {
    connect_as(fixture, "alice", password)
}

fn connect_as(
    fixture: &Fixture,
    user: &str,
    password: &str,
) -> Result<Client, super::client::ClientError> {
    Client::connect(&ClientConfig {
        host: "127.0.0.1".into(),
        port: fixture.port,
        share: "Files".into(),
        username: user.into(),
        domain: "WORKGROUP".into(),
        password: password.into(),
    })
}

#[test]
fn signs_in_and_lists_a_share() {
    let fixture = start("list", false);
    let mut client = connect(&fixture, "correct horse").expect("sign-in should succeed");

    let root = client.list("").unwrap();
    let names: Vec<&str> = root.iter().map(|e| e.name.as_str()).collect();
    assert!(names.contains(&"Docs"), "got {names:?}");
    assert!(names.contains(&"top.bin"), "got {names:?}");
    assert!(
        !names.contains(&".") && !names.contains(&".."),
        "the client should hide the dot entries: {names:?}"
    );

    let docs = root.iter().find(|e| e.name == "Docs").unwrap();
    assert!(docs.is_dir);

    let inner = client.list("Docs").unwrap();
    assert_eq!(inner.len(), 1);
    assert_eq!(inner[0].name, "notes.txt");
    assert_eq!(inner[0].size, 20);
    assert!(!inner[0].is_dir);
    assert!(inner[0].modified_ms > 1_600_000_000_000);

    client.disconnect();
}

#[test]
fn the_wrong_password_is_refused() {
    let fixture = start("auth", false);
    let Err(error) = connect(&fixture, "guess") else {
        panic!("a bad password must not connect");
    };
    assert!(error.is_auth_failure(), "got {error}");
}

#[test]
fn reads_a_file_larger_than_one_packet() {
    let fixture = start("read", false);
    let mut client = connect(&fixture, "correct horse").unwrap();

    let (handle, info) = client.open_read("top.bin").unwrap();
    assert_eq!(info.size, 200_000);

    let mut all = Vec::new();
    let mut offset = 0u64;
    loop {
        let chunk = client.read_at(handle, offset, 64 * 1024).unwrap();
        if chunk.is_empty() {
            break;
        }
        offset += chunk.len() as u64;
        all.extend_from_slice(&chunk);
    }
    client.close(handle).unwrap();
    assert_eq!(all.len(), 200_000);
    assert!(all.iter().all(|b| *b == 7));

    client.disconnect();
}

#[test]
fn writes_creates_renames_and_deletes() {
    let fixture = start("write", false);
    let mut client = connect(&fixture, "correct horse").unwrap();

    let handle = client.open_write("Docs\\report.txt", true).unwrap();
    let payload = b"quarterly numbers";
    assert_eq!(client.write_at(handle, 0, payload).unwrap(), payload.len() as u32);
    client.close(handle).unwrap();
    assert_eq!(
        fs::read(fixture.root.join("Docs/report.txt")).unwrap(),
        payload
    );

    client.create_directory("Archive").unwrap();
    assert!(fixture.root.join("Archive").is_dir());

    client
        .rename("Docs\\report.txt", "Archive\\report.txt", false)
        .unwrap();
    assert!(!fixture.root.join("Docs/report.txt").exists());
    assert!(fixture.root.join("Archive/report.txt").exists());

    client.delete("Archive\\report.txt", false).unwrap();
    assert!(!fixture.root.join("Archive/report.txt").exists());

    client.delete("Archive", true).unwrap();
    assert!(!fixture.root.join("Archive").exists());

    client.disconnect();
}

#[test]
fn stat_distinguishes_missing_from_present() {
    let fixture = start("stat", false);
    let mut client = connect(&fixture, "correct horse").unwrap();

    let file = client.stat("Docs\\notes.txt").unwrap().unwrap();
    assert_eq!(file.size, 20);
    assert!(!file.is_dir);

    let folder = client.stat("Docs").unwrap().unwrap();
    assert!(folder.is_dir);

    assert!(client.stat("Docs\\nothing.txt").unwrap().is_none());

    client.disconnect();
}

#[test]
fn copies_inside_the_share_without_moving_the_bytes_over_the_network() {
    let fixture = start("copy", false);
    let mut client = connect(&fixture, "correct horse").unwrap();

    let copied = client.copy_within("top.bin", "copy.bin").unwrap();
    assert_eq!(copied, 200_000);
    assert_eq!(
        fs::read(fixture.root.join("copy.bin")).unwrap(),
        fs::read(fixture.root.join("top.bin")).unwrap()
    );

    client.disconnect();
}

#[test]
fn a_read_only_share_refuses_writes() {
    let fixture = start("readonly", true);
    let mut client = connect(&fixture, "correct horse").unwrap();

    // Reading still works.
    let entries = client.list("Docs").unwrap();
    assert_eq!(entries.len(), 1);

    let error = client
        .open_write("Docs\\nope.txt", true)
        .expect_err("a read-only share must refuse a create");
    assert_eq!(
        error.status,
        super::proto::status::MEDIA_WRITE_PROTECTED,
        "got {error}"
    );
    assert!(!fixture.root.join("Docs/nope.txt").exists());

    client.disconnect();
}

#[test]
fn a_client_cannot_escape_the_share() {
    let fixture = start("escape", false);
    let mut client = connect(&fixture, "correct horse").unwrap();

    for attempt in ["..\\..\\etc\\passwd", "Docs\\..\\..\\secret", "..\\"] {
        let result = client.stat(attempt);
        // Either "no such thing" or an outright refusal is fine; what must
        // never happen is a successful open outside the share.
        if let Ok(Some(info)) = result {
            panic!("{attempt} resolved to {info:?}");
        }
    }

    client.disconnect();
}

#[test]
fn the_event_log_reports_who_connected() {
    let fixture = start("events", false);
    let mut client = connect(&fixture, "correct horse").unwrap();
    let _ = client.list("");
    client.disconnect();

    // The serving thread writes the event before the client's socket closes,
    // so by the time `list` has returned it is already there.
    let log = fixture.events.lock().unwrap();
    let authenticated = log.iter().any(|event| {
        matches!(event, ServerEvent::ClientAuthenticated { user, .. } if user == "alice")
    });
    assert!(authenticated, "no authentication event in {log:?}");
}

// ── access control ─────────────────────────────────────────────────────────

#[test]
fn a_share_restricted_to_one_account_refuses_the_others() {
    let fixture = start_with("restricted", Access::AliceOnly);

    let mut alice = connect_as(&fixture, "alice", "correct horse")
        .expect("the named account should get in");
    assert!(!alice.list("").unwrap().is_empty());
    alice.disconnect();

    // bob's password is right, so this is the share saying no, not the sign-in.
    let Err(error) = connect_as(&fixture, "bob", "hunter2") else {
        panic!("an account not on the list must not reach the share");
    };
    assert_eq!(
        error.status,
        super::proto::status::ACCESS_DENIED,
        "expected a refusal naming access, got {error}"
    );
}

#[test]
fn an_unrestricted_share_admits_every_account() {
    let fixture = start_with("open", Access::Everyone);
    for (user, password) in [("alice", "correct horse"), ("bob", "hunter2")] {
        let mut client = connect_as(&fixture, user, password)
            .unwrap_or_else(|e| panic!("{user} should get in: {e}"));
        assert!(!client.list("").unwrap().is_empty());
        client.disconnect();
    }
}

#[test]
fn a_guest_share_is_readable_without_an_account_and_never_writable() {
    let fixture = start_with("guest", Access::Guest);

    // No user name and no password: an anonymous session.
    let mut guest = Client::connect(&ClientConfig {
        host: "127.0.0.1".into(),
        port: fixture.port,
        share: "Files".into(),
        username: String::new(),
        domain: String::new(),
        password: String::new(),
    })
    .expect("a guest share should admit an anonymous client");

    let entries = guest.list("").expect("a guest should be able to read");
    assert!(entries.iter().any(|e| e.name == "Docs"));

    let Err(error) = guest.open_write("Docs\\guest.txt", true) else {
        panic!("a guest must never be able to write");
    };
    assert_eq!(
        error.status,
        super::proto::status::MEDIA_WRITE_PROTECTED,
        "got {error}"
    );
    assert!(!fixture.root.join("Docs/guest.txt").exists());

    guest.disconnect();
}

#[test]
fn a_share_without_guest_access_refuses_an_anonymous_client() {
    let fixture = start_with("noguest", Access::Everyone);
    let result = Client::connect(&ClientConfig {
        host: "127.0.0.1".into(),
        port: fixture.port,
        share: "Files".into(),
        username: String::new(),
        domain: String::new(),
        password: String::new(),
    });
    let Err(error) = result else {
        panic!("anonymous access must be refused when no share offers it");
    };
    assert!(error.is_auth_failure(), "got {error}");
}

// ── share enumeration ──────────────────────────────────────────────────────

#[test]
fn a_client_can_ask_the_server_what_shares_it_has() {
    let fixture = start_with("enum", Access::Everyone);
    let mut client = connect(&fixture, "correct horse").unwrap();

    let shares = client.list_shares().expect("enumeration should work");
    let names: Vec<&str> = shares.iter().map(|s| s.name.as_str()).collect();
    assert!(names.contains(&"Files"), "got {names:?}");

    let files = shares.iter().find(|s| s.name == "Files").unwrap();
    assert_eq!(files.comment, "test share");
    assert!(!files.hidden);

    // Enumerating must leave the session usable: the tree it borrowed has to
    // be handed back.
    assert!(!client.list("").unwrap().is_empty());
    client.disconnect();
}

#[test]
fn enumeration_shows_only_the_shares_the_account_may_reach() {
    let fixture = start_with("enum-acl", Access::AliceOnly);
    let mut alice = connect_as(&fixture, "alice", "correct horse").unwrap();
    let names: Vec<String> = alice
        .list_shares()
        .unwrap()
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert!(names.contains(&"Files".to_string()), "got {names:?}");
    alice.disconnect();

    // bob can't attach to Files, so he must not be told it is there. He can
    // still reach IPC$, which is how any client asks the question at all.
    let mut bob = Client::connect(&ClientConfig {
        host: "127.0.0.1".into(),
        port: fixture.port,
        share: "IPC$".into(),
        username: "bob".into(),
        domain: "WORKGROUP".into(),
        password: "hunter2".into(),
    })
    .expect("IPC$ is reachable by any account");
    let names: Vec<String> = bob
        .list_shares()
        .unwrap()
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert!(
        !names.contains(&"Files".to_string()),
        "a share bob cannot open must not be listed to him: {names:?}"
    );
    bob.disconnect();
}
