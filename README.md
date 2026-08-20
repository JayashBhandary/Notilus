<p align="center">
  <img src="assets/icon/icon.png" alt="Notilus icon" width="128" height="128">
</p>

<h1 align="center">Notilus</h1>

<p align="center">
  A Finder-style file manager built in Flutter, with a built-in Ollama chat
  panel, a Quick-Look-style preview viewer, and a workflow editor for running
  custom prompt chains against your local files.
</p>

Notilus is a single-developer, local-first project. It runs on macOS, Windows,
Linux, iPad, and iPhone from one Flutter codebase, and talks to a local
[Ollama](https://ollama.com) instance — no cloud, no account, no telemetry.

**Current version:** `0.1.5` (see `pubspec.yaml`).

---

## Highlights

- **Finder-style three-pane layout** on desktop — sidebar, file area,
  Info / Chat / Workflows panel — with a fluid wide layout and a
  bottom-tab compact layout below 750-px width (iPhone, iPad portrait
  split-view, narrow desktop windows).
- **Quick-Look-style preview** for images, text/source code, rendered
  Markdown, PDF, video, and audio. Sibling files in the same folder are
  navigable via swipe (touch) or arrow keys + space (desktop).
- **Integrated terminal** (desktop) — bottom-docked PTY-backed panel
  with VSCode-style tabs, toggled by **⌘J** (macOS) / **Ctrl+J**
  (Windows / Linux). New sessions inherit the current folder as their
  working directory; switching folders sends `cd` to the active tab.
- **Disk-cached thumbnails** for PDFs (first page), SVGs, and text
  files (first-lines snippet). Cache keys include path + mtime + size,
  so an external edit invalidates the entry automatically.
- **Live filesystem updates** — the current folder is watched with
  `Directory.watch()` and re-listed automatically on create / rename /
  delete (debounced ~180 ms). No manual refresh button needed.
- **Ollama chat panel** with token-by-token streaming over
  `/api/generate`. Attach the selected file to send its extracted text
  (PDF via `pdftotext`, Office docs via LibreOffice) or pass images
  straight through as base64 to a vision-capable model.
- **Remote sources** — mount a **VPS over SSH/SFTP**, Amazon S3 (and
  anything S3-compatible: MinIO, R2, Wasabi, Spaces), Google Drive, or a
  WebDAV server from the sidebar's **Locations +** button, then browse them
  exactly like a local folder. Copy and paste, drag and drop, rename, new folder and delete all
  work across the boundary, with a progress card in the bottom-right corner
  for anything that takes a while.
- **Built-in text editor** — ⌘E / Ctrl+E, right-click → **Edit**, or the
  pencil in the preview toolbar. Edits source, config and plain-text files
  in place, on local disk *and* on any mounted remote source, with ⌘S to
  save, an unsaved-changes guard, and a warning if the file changed
  underneath you.
- **Multi-step workflows** — chain prompts (each with its own template
  and optional model override) and run them against the selected file.
- **System Overview** screen — disk usage per drive, shallow folder
  breakdown for Desktop / Documents / Downloads, plus an "AI Insights"
  panel that asks your local model for cleanup suggestions.
- **Native context menu** on right-click / long-press with Open,
  Open With (default app + system chooser), Rename, Duplicate,
  Copy Path, Reveal in Finder / Files, and Move to Trash. Display
  toggles (view mode, Sort By, Use Groups, Show Hidden Files, View
  Options) live in a **View** submenu.
- **Quick Actions** submenu, built from whatever is under the cursor and
  run in Rust: Compress (any selection), Extract Here / Extract to a
  named folder (archives), Rotate / Flip and Convert To PNG, JPEG, WebP
  or a web-sized copy (images), Calculate Folder Size (folders), and
  Copy SHA-256 (files).
- **Pure-neutral dark theme** (R = G = B grays) plus a light theme;
  follows the system appearance by default and can be overridden in
  Settings.

---

## Install

Prebuilt binaries are published on the
[Releases page](https://github.com/JayashBhandary/Notilus/releases).

### One-liner

**macOS / Linux:**

```sh
curl -fsSL https://raw.githubusercontent.com/JayashBhandary/Notilus/main/install.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/JayashBhandary/Notilus/main/install.ps1 | iex
```

The installer detects your platform, downloads the latest release asset,
and installs to:

| Platform | Install location |
|---|---|
| macOS   | `/Applications/Notilus.app` |
| Linux   | `/opt/notilus` (symlinked at `/usr/local/bin/notilus`) |
| Windows | `%LOCALAPPDATA%\Programs\Notilus` (Start Menu shortcut added) |

### Manual download

Grab the asset for your platform from the
[Releases page](https://github.com/JayashBhandary/Notilus/releases/latest):

| Asset | Target |
|---|---|
| `Notilus-<v>-macos-arm64.dmg`     | Apple Silicon Macs (M1/M2/M3+) |
| `Notilus-<v>-macos-x64.dmg`       | Intel Macs |
| `Notilus-<v>-macos-universal.dmg` | Either architecture (larger file) |
| `Notilus-<v>-windows-x64.zip`     | Windows 10/11 x64 |
| `Notilus-<v>-linux-x64.tar.gz`    | Linux x86_64 |

> macOS builds are ad-hoc signed but **not notarized**. The install
> script strips the Gatekeeper quarantine attribute for you. If you
> download a DMG directly through a browser and macOS refuses to open
> it, run: `xattr -dr com.apple.quarantine /Applications/Notilus.app`

iOS / iPadOS are not currently distributed as prebuilt binaries — see
[Build from source](#build-from-source).

---

## First launch

1. **Start Ollama** locally:
   ```sh
   ollama serve
   ollama pull llama3.2     # or any model you prefer
   ```
2. **Open Notilus.** It points at `http://localhost:11434` by default;
   the green dot in the top bar confirms it can reach the host.
3. **Open Settings → Default Model** and pick a model from the list.
4. Optionally switch the appearance (`System` / `Light` / `Dark`) and
   tweak temperature.

> **Running Ollama on a different machine?** Open Settings and set the
> Host URL to e.g. `http://192.168.1.42:11434`. Make sure Ollama is
> bound to that interface (`OLLAMA_HOST=0.0.0.0:11434 ollama serve`).
> The iOS app already includes the ATS exception and Local Network
> usage description required to reach it.

---

## UI tour

### Top bar (desktop)

```
◀  ▶   Documents                          [▥|≣]  ● llama3.2   ⚙
```

- **Back / Forward** — navigates the in-app history stack.
- **Current folder name** — just the basename (no breadcrumb clutter).
- **Grid / List toggle** — view-mode for the file area.
- **Connection pill** — green = Ollama reachable, red = unreachable.
  Click to open Settings.
- **Settings gear** — global preferences.

The pill collapses to just a dot when the main column is narrow;
chrome reflows so the toggle and settings stay pinned at the right end.

### Sidebar

Finder-style sidebar that extends edge-to-edge under the macOS traffic
lights:

- **System Overview** — disk + folder analysis screen.
- **Favorites** — Home / Desktop / Documents / Downloads (only those
  that exist on the current platform).
- **Locations** — mounted volumes / drives (`/Volumes/*` on macOS, drive
  letters on Windows, `/media/<user>/*` and `/mnt/*` on Linux,
  `On My iPhone` on iOS), followed by any remote sources you have added.
  The **+** in the section header adds one; the **⟳** re-scans drives.
  Each remote row carries a status dot (connecting / connected / needs
  attention) and a right-click menu: Open, Reconnect, Edit…, Eject,
  Remove source.
- **Tags** — placeholder section for future tag support.

In compact mode (phones / narrow windows) the sidebar collapses to a
slide-in drawer toggled by the menu button.

### Remote sources

Cloud storage is mounted as a location, not bolted on as a separate screen.
A mounted source gets a virtual path — `notilus://<source-id>/<path>` — and
everything above the filesystem layer treats it like any other folder:
history, breadcrumbs, selection, the clipboard, drag and drop, rename,
New Folder, and delete.

| Provider | What it needs | Notes |
| --- | --- | --- |
| **SSH / SFTP** | Host, username, and either a private key file (+ passphrase) or a password | Any server you can `ssh` into — VPS, NAS, build box. The host key is pinned on first connection; a later mismatch refuses to connect. *Start folder* defaults to your login home, exactly like `sftp user@host`. |
| **Amazon S3 & compatible** | Access key ID + secret, region; optional bucket and endpoint | Signature V4 is computed in-app (no AWS SDK). Leave *Bucket* empty to browse every bucket in the account. Set *Endpoint* for MinIO, Cloudflare R2, Wasabi, Backblaze B2 or DigitalOcean Spaces — path-style addressing is picked automatically for non-AWS hosts. |
| **Google Drive** | OAuth client ID + secret from a *Desktop app* client, then **Sign in with Google** | Standard loopback + PKCE flow in your real browser; only the refresh token is stored. Google-native docs download as `.docx` / `.xlsx` / `.pptx` / `.png`. |
| **WebDAV** | Server URL, username, password or app token | Nextcloud, ownCloud, Box, Synology, Apache `mod_dav`. |

Credentials go to the OS keychain (macOS Keychain, Windows Credential
Manager, libsecret) via `flutter_secure_storage` — never to
`shared_preferences`. **Add** verifies the connection before saving, so a
source that can't connect never reaches the sidebar.

**Copying.** Copy/Cut/Paste (⌘C / ⌘X / ⌘V), drag and drop, and
Duplicate all work in every direction — local → remote, remote → local,
and remote → remote. A copy inside one source is done server-side where
the provider supports it (S3 `CopyObject`, Drive `files.copy`, WebDAV
`COPY`, `cp -p` over SSH), so the bytes never travel through your machine. Folders are
recursed, names never overwrite (`report (2).pdf`), and a move only
deletes the source after the copy succeeds.

**Progress.** Network transfers report into a card in the bottom-right
corner — one row per transfer, with percentage, throughput, ETA, and a
cancel button. It collapses to a single line, clears finished rows on its
own after a few seconds, and keeps failures until you dismiss them. Local
copies keep using the full-width bar above the status bar, which is
single-operation by design.

**Working on a server.** Right-click anything on an SSH source →
**Cloud Actions → Open SSH Session Here** drops the integrated terminal
(⌘J / Ctrl+J) into that exact directory on the server, using your own
`ssh` client, agent and `~/.ssh/config`; **Copy SSH Command** puts the same
line on the clipboard. Searching an SSH source runs `find` on the server in
one round trip and falls back to walking the tree if the account has no
shell. Deleting a folder is recursed through SFTP itself, never `rm -rf`,
so it works on accounts locked to `internal-sftp`.

**What differs from a local folder.** Remote files are downloaded to a
cache on demand — the preview, Open With, chat attachments and workflows
all get a real file that way — so listings show file-type icons rather
than thumbnails (rendering one would mean downloading the folder). Search
matches names only. Deleting uses the provider's own recycle bin where it
has one (Drive trashes; S3 deletes). The Rust Quick Actions (compress,
convert, checksum) are local-only; remote items get a **Cloud Actions**
submenu instead — Download a Copy, Copy Link, Refresh Source. "Copy Link"
never changes who can see a file: S3 returns a presigned URL that expires
in an hour, Drive returns the sharing link the file already has.

### Text editor

Anything that looks like text — by extension, or by convention (`Makefile`,
`Dockerfile`, `.env`, `authorized_keys`, `README`) — can be edited without
leaving the app, whether it sits on this machine, a VPS, S3, Drive or a
WebDAV server.

- Open it with **⌘E / Ctrl+E**, right-click → **Edit**, or the pencil in the
  preview toolbar. Creating a **New File** with a text-ish name opens the
  editor on it straight away.
- **⌘S / Ctrl+S** saves, **⌘W / Ctrl+W** closes, Tab indents and Shift+Tab
  outdents. Closing with unsaved work asks Save / Discard / Cancel.
- A status bar shows line and column, line count, the file's line ending and
  whether it carries a byte-order mark.
- **The file is written back the way it came.** CRLF files stay CRLF, a BOM
  survives, and the save is done in place rather than through a temp file and
  a rename — so permissions, ownership, hard links and symlinks are all
  preserved. Point it at `~/.ssh/config` and the file stays the file.
- **Concurrent edits are noticed.** The size and mtime are recorded at open;
  if they changed by the time you save, the editor asks before overwriting
  someone else's work. Sources that can't report a dependable stamp (S3)
  skip the check rather than pretend.
- **Remote files are edited at the source** — the bytes are read from the
  provider and written straight back to it, not through the preview cache.
  Saving a remote file drops any cached copy so the preview can't go stale.
- It declines what it shouldn't touch: anything with a NUL byte, anything
  that isn't valid UTF-8, and anything over 5 MB. No syntax highlighting —
  that needs a grammar per language and a dependency to match.

### Right panel — Info / Chat / Workflows

A `CupertinoSlidingSegmentedControl` switches between:

- **Info** — preview, name, kind, size, modified, location of the
  current selection (Finder's "Get Info"-style panel).
- **Chat** — Ollama chat with an attach toggle on the selected file:
  text is extracted (text capped at 200 KB; PDFs and Office docs use
  external tools if available) and images are passed as base64 to a
  vision-capable model.
- **Workflows** — list, edit, and run saved prompt chains.

On compact widths these become tabs in the bottom tab bar
(Files / Info / Chat / Flows) alongside the file area.

### Preview viewer

Quick-Look-style full-screen modal. Trigger:

- **macOS / desktop:** select a file, press **Space**.
- **iOS / touch:** single-tap a file (folders still navigate).

Per-type viewers:

| Type | Extensions | Viewer |
|---|---|---|
| Image | `png` `jpg` `jpeg` `gif` `bmp` `webp` `heic` `tif` | `InteractiveViewer` + `Image.file` (pinch / drag zoom) |
| Markdown | `md` `markdown` `mdown` | `flutter_markdown` rendered, with a toggle to view raw source |
| Text / code | `txt` `json` `yaml` `xml` `csv` `html` `css` `js` `ts` `dart` `py` `go` `rs` `c` `cpp` `java` `kt` `swift` `sh` `toml` `ini` `conf` `log` `+more` | Monospaced, selectable, capped at 1 MB |
| PDF | `pdf` | `pdfx` (PDFKit on Apple, PDFium elsewhere) |
| Video | `mp4` `mov` `m4v` `mkv` `webm` | `video_player` with play / pause / seek overlay |
| Audio | `mp3` `wav` `m4a` `aac` `flac` `ogg` | `just_audio` with scrubber |
| Anything else | — | Info fallback with name / kind / size |

Top nav shows `filename — n of total`, plus prev / next buttons.

### Right-click / long-press menu

```
Open
Open With ▶  (macOS)  →  Default Application
                          Choose Application…   (native AppleScript picker)
Share…       (iOS)
─────────
Get Info
Rename…
Duplicate
Copy Path
Reveal in Finder  /  Open Parent Folder (iOS)
─────────
Move to Trash  /  Delete  (iOS — hard delete; no sandbox Trash)
─────────
New Folder
Use Groups
Sort By ▶
Show View Options
```

---

## Keyboard / gesture cheat sheet

| Action | Desktop | iOS / touch |
|---|---|---|
| Select file | Click | Tap |
| Open folder | Double-click | Tap |
| Preview file (Quick Look) | **Space** (after selecting) | Tap |
| Context menu | Right-click | Long-press |
| Cycle preview siblings | **←** / **→** / Space | Swipe |
| Close preview | **Esc** | Back / swipe down |
| Toggle integrated terminal | **⌘J** (macOS) / **Ctrl+J** | — |
| Edit a text file | **⌘E** / **Ctrl+E** | Right-click → Edit |
| Save in the editor | **⌘S** / **Ctrl+S** | Save button |
| Close the editor | **⌘W** / **Ctrl+W** | Back |
| Indent / outdent in the editor | **Tab** / **Shift+Tab** | — |

Filesystem changes (files created, renamed, or deleted by another app)
appear automatically — no refresh shortcut needed.

---

## Ollama setup

Notilus speaks the `/api/generate` streaming protocol. Defaults:

- Host: `http://localhost:11434`
- Temperature: configurable in Settings (0.0 – 1.5)
- Model: chosen from the list returned by `/api/tags`

```sh
# Install + start Ollama
brew install ollama       # macOS; see ollama.com for other platforms
ollama serve
ollama pull llama3.2
```

In Settings, hit **Save & Test** after editing the Host URL. The
"Default Model" picker is populated from `/api/tags`.

### Reaching Ollama from an iPhone

`localhost` on iOS means the phone itself, not your Mac. Set Host URL
to your Mac's LAN IP (e.g. `http://192.168.1.42:11434`) and run
Ollama bound to all interfaces:

```sh
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

The bundled `ios/Runner/Info.plist` already includes:

- `NSAppTransportSecurity → NSAllowsLocalNetworking` (HTTP on LAN)
- `NSLocalNetworkUsageDescription` (iOS 14+ prompt)
- `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
  (so the app's Documents folder shows up in the iOS Files app)

---

## Workflows

A workflow is an ordered list of `WorkflowStep`s. Each step has:

- **name** — display label
- **prompt template** — supports placeholders:
  - `{file_content}` — text contents of the selected file
  - `{file_name}`, `{file_path}`
  - `{prev}` — previous step's output
  - `{step_1}`, `{step_2}`, … — output of any earlier numbered step
- **model** *(optional)* — overrides the default chat model for this
  step only

Workflows are saved as JSON via `SettingsStore` (`shared_preferences`)
and re-run from the Workflows tab on the home screen. Step-by-step
output streams into a results panel while the run is in flight.

---

## Project layout

```
lib/
├── app.dart                          # MultiProvider + CupertinoApp wiring
├── main.dart
├── theme.dart                        # AppPalette light/dark (pure neutral)
├── utils/
│   └── responsive.dart               # 750-px compact breakpoint helper
├── models/
│   ├── file_entry.dart               # FileSystemEntity + cached stat
│   ├── chat_message.dart             # user / assistant + streaming flag
│   ├── workflow.dart
│   └── workflow_step.dart
├── providers/
│   ├── browser_provider.dart         # history, watcher, sort, view mode
│   ├── chat_provider.dart            # streaming chat state
│   ├── settings_provider.dart        # theme, host, model, temperature
│   └── workflow_provider.dart        # CRUD + run lifecycle
├── services/
│   ├── file_service.dart             # list, drives, shortcuts (per-OS)
│   ├── file_actions_service.dart     # open, open-with, rename, trash, …
│   ├── ollama_service.dart           # /api/tags + /api/generate stream
│   ├── attachment_service.dart       # text/PDF/Office → text; images → base64
│   ├── thumbnail_service.dart        # disk-cached PDF/SVG/text thumbnails
│   ├── settings_store.dart           # shared_preferences wrapper
│   ├── system_info_service.dart      # disk usage + folder breakdown
│   └── workflow_runner.dart
├── screens/
│   ├── home_screen.dart              # wide + compact layouts, top bar
│   ├── settings_screen.dart
│   ├── system_overview_screen.dart
│   ├── workflow_editor_screen.dart
│   └── file_preview_screen.dart      # Quick-Look-style viewer (incl. Markdown)
└── widgets/
    ├── sidebar.dart                  # full-height; drawer in compact
    ├── breadcrumb_bar.dart           # (legacy — currently unused)
    ├── path_status_bar.dart          # Finder-style bottom status bar
    ├── file_list_view.dart           # list view + context menu wiring
    ├── file_icon_grid.dart           # icon view with cached thumbnails
    ├── desk_context_menu.dart        # overlay menu with submenus
    ├── terminal_panel.dart           # PTY-backed terminal with VSCode tabs
    ├── chat_panel.dart
    ├── workflow_tab.dart
    ├── workflow_run_view.dart
    └── info_panel.dart
```

### Per-platform native shims

| File | Purpose |
|---|---|
| `macos/Runner/MainFlutterWindow.swift` | Transparent titlebar + `contentMinSize` 900 × 600 |
| `windows/runner/win32_window.cpp`      | `WM_GETMINMAXINFO` enforces 900 × 600 (DPI-scaled) |
| `linux/runner/my_application.cc`       | `gtk_window_set_geometry_hints` with `GDK_HINT_MIN_SIZE` |
| `ios/Runner/Info.plist`                | ATS exception, file sharing, local network usage |

---

## Architecture overview

- **State** is plain `ChangeNotifier` + `provider` — one provider per
  domain (browser / chat / settings / workflows). No Riverpod, no
  BLoC, no codegen.
- **Persistence** is `shared_preferences` only. No SQLite, no JSON
  files on disk for app data.
- **Networking** is a single `http.Client` + `dart:async` stream for
  Ollama. Token chunks are forwarded straight to the chat / workflow
  UI as they arrive.
- **Filesystem** is `dart:io`. Listing is shallow per directory; the
  current folder is watched with `Directory.watch(recursive: false)`
  and changes are debounced before re-listing. Falls back silently on
  platforms / filesystems where watching isn't supported.
- **Theming** is a small `AppPalette` record with light / dark
  variants resolved via `CupertinoTheme.brightnessOf`. Dark surfaces
  are pure-neutral (R = G = B); the only chromatic tokens are the
  accent (system blue), folder icon (lighter blue), success (green),
  and danger (red).
- **Responsiveness** is a single 750-px breakpoint:
  - ≥ 750 px → 3-pane wide layout (sidebar full-height, fluid
    panel widths)
  - < 750 px → bottom-tab compact layout (Files / Info / Chat /
    Flows), sidebar becomes a slide-in drawer

---

## Build from source

### Prerequisites

- Flutter `>=3.10.0` (Dart `>=3.0.0`)
- A running Ollama instance (see above)
- macOS: Xcode + CocoaPods (for the macOS / iOS targets)
- Windows: Visual Studio with the *Desktop development with C++*
  workload
- Linux: `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`

### Run

```sh
flutter pub get
flutter run -d macos      # or:  linux, windows, ios, ipad, chrome
```

### Build release binaries

```sh
flutter build macos       # universal .app  (arm64 + x64)
flutter build windows     # build/windows/x64/runner/Release/
flutter build linux       # build/linux/x64/release/bundle/
flutter build ios         # archive in Xcode for distribution
```

On Linux, a locally built bundle shows up in the launcher and dock as
`com.jayash.notilus` with a generic icon until a desktop entry is registered —
the name and icon come from a `.desktop` file, not from the binary. To register
one for the current user (no sudo, writes only to `~/.local/share`):

```sh
linux/packaging/install-desktop-entry.sh              # after flutter build linux
linux/packaging/install-desktop-entry.sh --uninstall
```

The released installer (`install.sh`) does this system-wide already. The entry,
its `Icon=`, its `StartupWMClass=` and the installed icon filenames must all
equal `APPLICATION_ID` from `linux/CMakeLists.txt` (`com.jayash.notilus`) —
that's the id GTK reports for the window, and the shell matches a window to its
desktop entry by that id.

### Dependency notes

`pubspec.yaml` includes a `dependency_overrides` pin:

```yaml
dependency_overrides:
  video_player_avfoundation: 2.6.5
```

`video_player_avfoundation` 2.8.x split its Apple plugin into a
modular Obj-C subtarget that unconditionally imports
`<Flutter/Flutter.h>`, which doesn't exist on macOS (macOS exposes
`FlutterMacOS`). Pinning to the last pre-split version restores the
macOS build; iOS is unaffected. Drop the override when the upstream
plugin fixes the issue.

---

## Releasing

Releases are produced by
[`.github/workflows/release.yml`](.github/workflows/release.yml):

- **Trigger:** push a tag matching `v*` *or* run the workflow
  manually with the `tag` input.
- **Builds:** macOS (universal + arm64 + x64 DMGs), Windows x64 zip,
  Linux x64 tarball — all in parallel.
- **Publishes:** a single GitHub Release named `Notilus <tag>` with
  all five archives attached and auto-generated release notes.

Typical flow:

```sh
# 1. Bump version in pubspec.yaml (e.g. 0.1.5 → 0.1.6)
# 2. Commit + push
git commit -am "Bump version to 0.1.6"
git push

# 3. Tag and push the tag
git tag v0.1.6
git push origin v0.1.6
```

> The workflow resolves the tag from `workflow_dispatch` input
> *or* `GITHUB_REF_NAME` (in that order), so manual dispatches
> won't accidentally name the release after the branch.

---

## Dependencies

| Package | Why |
|---|---|
| `provider`             | App-wide state via `ChangeNotifier` |
| `http`                 | Ollama REST calls |
| `shared_preferences`   | Local settings + saved workflows |
| `path`, `path_provider`| OS-specific path helpers |
| `pdfx`                 | PDF preview + first-page thumbnails |
| `video_player`         | Video preview |
| `just_audio`           | Audio preview |
| `flutter_markdown`     | Rendered Markdown preview |
| `flutter_svg`          | SVG thumbnails + icons |
| `xterm`, `flutter_pty` | Integrated PTY-backed terminal |
| `archive`              | Reading zip/tar contents (e.g. legacy `.docx` text extraction fallback) |
| `share_plus`           | iOS share-sheet for "Open With" |
| `dartssh2`             | SSH + SFTP client for the remote-source browser |
| `crypto`               | AWS Signature V4 for the S3 remote source (no AWS SDK) |
| `flutter_secure_storage` | API keys and remote credentials in the OS keychain |
| `cupertino_icons`      | Icon font |

Dev-only: `flutter_lints`, `flutter_launcher_icons`.

---

## Status & roadmap

Notilus is an early, single-developer project. Desktop targets
(macOS / Linux / Windows) are the primary focus; iOS / iPadOS work but
are limited by the iOS app sandbox (you can only browse the app's
Documents folder and whatever you share into it from the Files app).

Things on the short list:

- Notarized macOS builds (currently ad-hoc signed)
- Tag support in the sidebar (UI is there; persistence isn't)
- File search inside the current folder
- Disk-cached raster thumbnails for raw images (PDFs / SVGs / text are
  already cached)
- Optional: bundle pinning for `share_plus` 11.x once it stabilises

PRs and issues welcome at
<https://github.com/JayashBhandary/Notilus>.

---

## License

No license has been added yet — see the repository for updates.
Until a license is published, default copyright applies: the source
is readable but not freely redistributable.
