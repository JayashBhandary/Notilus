//! `notilus-share` — run the SMB server from a terminal.
//!
//! Exists so the server can be pointed at by a real client — `smbclient`,
//! Windows Explorer, macOS Finder, `mount.cifs` — without launching the app.
//! Interoperability is the one thing the in-crate round-trip tests can't prove:
//! they exercise this implementation against itself, and an agreed-upon
//! misreading of the spec would pass both sides.
//!
//! ```text
//! cargo run --bin notilus-share -- ~/Public --user alice:secret --port 4455
//! ```
//!
//! Ctrl-C stops it.

use notilus_core::api::sharing::{
    self, SmbServerEvent, SmbServerSettings, SmbShareConfig, SmbUserConfig,
};
use std::sync::Arc;

const USAGE: &str = "\
notilus-share — serve folders over SMB2/3

USAGE:
    notilus-share <folder>... [options]

OPTIONS:
    --user <name>:<password>   Add an account. Repeatable. At least one is required.
    --name <share>=<folder>    Publish <folder> as <share> instead of its own name.
    --allow <a,b>              Restrict the folder before it to these accounts.
    --guest                    Let anyone reach the folder before it, read-only.
    --port <n>                 Listen on <n>. Default 4455; 445 needs root.
    --local                    Bind 127.0.0.1 only.
    --read-only                Refuse writes on every share.
    --no-signing               Accept unsigned requests. For old clients only.
    --workgroup <name>         Default WORKGROUP.
    --server-name <name>       Default NOTILUS.
    -h, --help                 This.

EXAMPLE:
    notilus-share ~/Public --guest ~/Work --allow alice \\
        --user alice:secret --user bob:hunter2
    smbclient //127.0.0.1/Public -U alice%secret -p 4455 -c ls
    smbclient -L //127.0.0.1 -U alice%secret -p 4455
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        eprintln!("{USAGE}");
        std::process::exit(if args.is_empty() { 2 } else { 0 });
    }

    // (share name, folder, accounts allowed, guest-visible)
    let mut folders: Vec<(Option<String>, String, Vec<String>, bool)> = Vec::new();
    let mut users: Vec<SmbUserConfig> = Vec::new();
    let mut port = 4455u16;
    let mut local = false;
    let mut read_only = false;
    let mut signing = true;
    let mut workgroup = "WORKGROUP".to_string();
    let mut server_name = "NOTILUS".to_string();

    let mut i = 0;
    while i < args.len() {
        let arg = args[i].clone();
        let mut next = |flag: &str| -> String {
            i += 1;
            args.get(i)
                .unwrap_or_else(|| fail(&format!("{flag} needs a value")))
                .clone()
        };
        match arg.as_str() {
            "--user" => {
                let value = next("--user");
                let (name, password) = value
                    .split_once(':')
                    .unwrap_or_else(|| fail("--user takes <name>:<password>"));
                users.push(SmbUserConfig {
                    username: name.to_string(),
                    password: password.to_string(),
                });
            }
            "--name" => {
                let value = next("--name");
                let (share, path) = value
                    .split_once('=')
                    .unwrap_or_else(|| fail("--name takes <share>=<folder>"));
                folders.push((Some(share.to_string()), path.to_string(), Vec::new(), false));
            }
            "--port" => {
                port = next("--port")
                    .parse()
                    .unwrap_or_else(|_| fail("--port must be a number"));
            }
            "--allow" => {
                let value = next("--allow");
                let names: Vec<String> =
                    value.split(',').map(|n| n.trim().to_string()).collect();
                match folders.last_mut() {
                    Some(last) => last.2 = names,
                    None => fail("--allow comes after the folder it applies to"),
                }
            }
            "--guest" => match folders.last_mut() {
                Some(last) => last.3 = true,
                None => fail("--guest comes after the folder it applies to"),
            },
            "--local" => local = true,
            "--read-only" => read_only = true,
            "--no-signing" => signing = false,
            "--workgroup" => workgroup = next("--workgroup"),
            "--server-name" => server_name = next("--server-name"),
            other if other.starts_with('-') => fail(&format!("unknown option {other}")),
            path => folders.push((None, path.to_string(), Vec::new(), false)),
        }
        i += 1;
    }

    if folders.is_empty() {
        fail("name at least one folder to share");
    }
    if users.is_empty() {
        fail("add at least one --user; anonymous access is never allowed");
    }

    let shares: Vec<SmbShareConfig> = folders
        .into_iter()
        .map(|(name, path, allowed_users, guest_ok)| {
            let expanded = expand_home(&path);
            SmbShareConfig {
                name: name.unwrap_or_else(|| basename(&expanded)),
                path: expanded,
                read_only,
                comment: String::new(),
                allowed_users,
                guest_ok,
            }
        })
        .collect();

    for share in &shares {
        println!(
            "  {} → {}{}{}",
            share.name,
            share.path,
            if share.read_only { "  (read-only)" } else { "" },
            if share.guest_ok {
                "  (guest)".to_string()
            } else if share.allowed_users.is_empty() {
                String::new()
            } else {
                format!("  ({})", share.allowed_users.join(", "))
            }
        );
    }

    let settings = SmbServerSettings {
        bind: if local { "127.0.0.1".into() } else { "0.0.0.0".into() },
        port,
        server_name,
        workgroup,
        shares,
        users,
        require_signing: signing,
        max_connections: 32,
    };

    let started = match sharing::start_server(settings, Arc::new(report)) {
        Ok(port) => port,
        Err(e) => fail(&e),
    };

    println!("\nListening on {}:{started}", if local { "127.0.0.1" } else { "0.0.0.0" });
    println!("  smbclient //127.0.0.1/<share> -U <user>%<password> -p {started} -c ls");
    println!("\nCtrl-C to stop.\n");

    // The server runs on its own threads; this one only has to stay alive.
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}

fn report(event: SmbServerEvent) {
    match event {
        SmbServerEvent::Started(port) => println!("[up]    port {port}"),
        SmbServerEvent::Stopped => println!("[down]"),
        SmbServerEvent::Connected(e) => println!("[conn]  {}", e.peer),
        SmbServerEvent::Authenticated(e) => {
            println!("[auth]  {} as {} ({})", e.peer, e.user, e.detail)
        }
        SmbServerEvent::Rejected(e) => println!("[deny]  {} — {}", e.peer, e.detail),
        SmbServerEvent::Disconnected(e) => println!("[bye]   {}", e.peer),
        SmbServerEvent::Transfer(e) => println!(
            "[{}]  {}/{} — {} bytes",
            if e.outbound { "out" } else { "in " },
            e.share,
            e.path,
            e.bytes
        ),
    }
}

/// `~` and `~/…`, which a shell would have expanded for an interactive user
/// but not for a path arriving quoted.
fn expand_home(path: &str) -> String {
    let Some(rest) = path.strip_prefix('~') else {
        return path.to_string();
    };
    let Ok(home) = std::env::var("HOME") else {
        return path.to_string();
    };
    if rest.is_empty() {
        home
    } else if let Some(tail) = rest.strip_prefix('/') {
        format!("{home}/{tail}")
    } else {
        path.to_string()
    }
}

fn basename(path: &str) -> String {
    std::path::Path::new(path.trim_end_matches('/'))
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Shared".into())
}

fn fail(message: &str) -> ! {
    eprintln!("notilus-share: {message}");
    std::process::exit(2);
}
