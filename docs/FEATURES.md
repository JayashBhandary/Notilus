# Notilus — Feature Overview

> Source material for the landing page. Written as benefit-oriented copy:
> each feature has a headline + short pitch you can lift directly, with
> technical specifics as supporting bullets. Verified against the code at
> version **0.2.1** (`pubspec.yaml`).

---

## One-liner

**Notilus is a Finder-style file manager with a local AI built in.**
Browse, preview, and organize your files; chat with a local Ollama model
or Claude / Gemini / OpenAI via your own API keys
about them; run custom prompt-chain workflows; find duplicates; and send
files machine-to-machine — all local-first, with no cloud, no account, and
no telemetry.

**Tagline candidates:**
- "Your files. Your AI. Your machine."
- "A file manager that thinks locally."
- "Finder-style file management, AirDrop-style sharing, ChatGPT-style AI — all offline."

---

## Platforms

- **One codebase, five platforms:** macOS, Windows, Linux, iPadOS, iPhone.
  Desktop (macOS / Windows / Linux) is the primary, fully-supported target.
- **Prebuilt binaries:** macOS DMGs (Apple Silicon, Intel, universal),
  Windows 10/11 x64 zip, Linux x86_64 tarball.
- **One-line install:** `install.sh` (macOS/Linux) and `install.ps1`
  (Windows) detect your platform and install to the right place
  (`/Applications`, `/opt/notilus`, `%LOCALAPPDATA%\Programs\Notilus`).
- iOS/iPadOS build from source; the app's Documents folder integrates with
  the iOS Files app.

---

## 🗂 File management — a real Finder alternative

**Everything you expect from a native file manager, on every desktop OS.**

- **Three-pane layout** — sidebar, file area, and an Info / Chat / Workflows
  panel, with back/forward history. Below 750 px the UI reflows into a
  compact bottom-tab layout for phones, narrow windows, and iPad split-view.
- **Grid and list views** — icon grid with real thumbnails, or a sortable
  detail list (Name / Kind / Date Modified / Size, click headers to reverse).
- **Live folder updates** — the current folder is watched by the OS; files
  created, renamed, or deleted by any other app appear automatically
  (~180 ms debounce). No refresh button.
- **Real multi-select** — click, Cmd/Ctrl-click, Shift-click ranges,
  Cmd/Ctrl+A select-all, and marquee (rubber-band) drag selection.
- **Full context menu** — Open, Open With (native macOS app chooser),
  Send to…, Get Info, Rename, Duplicate, Copy Path, Reveal in Finder,
  Move to Trash, New Folder, Use Groups, Sort By, View Options.
- **Trash done right** — on macOS files go to the real Trash via Finder
  (batched, so bulk cleanups play the Trash sound once).
- **Sidebar** — Favorites (Home / Desktop / Documents / Downloads),
  mounted drives and volumes per-OS, plus System Overview, Duplicate
  Finder, and File Transfer entry points.
- **View Options** — group files by kind, pick sort order, and adjust row
  density (Compact / Default / Spacious).
- **Thumbnails, cached** — PDF first pages, SVGs, and text snippets are
  rendered once and disk-cached; cache keys include mtime + size, so
  external edits refresh automatically.

## 👁 Quick Look previews — press Space, see anything

**A full-screen previewer for nearly every file type — no external apps needed.**

- Trigger with **Space** (desktop) or a tap (touch); arrow keys or swipes
  flip through sibling files; **Esc** closes; **I** shows file info.
- **Images** (`png jpg jpeg gif bmp webp heic tif tiff ico`) — pinch/drag
  zoom up to 6×, plus 90° rotation.
- **SVG** (`svg svgz`) — vector rendering with zoom to 8×.
- **Markdown** — fully rendered, with a raw-source toggle.
- **Text & source code** — dozens of extensions (`json yaml py rs ts dart
  go swift sql sh toml …`), monospaced and selectable.
- **PDF** — native rendering (PDFKit on Apple, PDFium on Windows, poppler
  on Linux) with page navigation, go-to-page, and a thumbnail rail.
- **Office documents** (`docx xlsx pptx odt rtf …`) — converted via
  LibreOffice and previewed as PDF, with a graceful fallback if
  LibreOffice isn't installed.
- **Archives** (`zip jar tar tar.gz tgz bz2 …`) — inspect contents, entry
  sizes, and total uncompressed size without extracting.
- **Video** (`mp4 mov m4v mkv webm avi`) — play/pause/seek overlay.
- **Audio** (`mp3 wav m4a aac flac ogg opus wma`) — player with scrubber.

## 🤖 AI assistant — your files, discussed with any model

**A ChatGPT-style panel that runs on local Ollama models or your own
Claude, Gemini, or OpenAI API keys — plus any OpenAI-compatible server
(LM Studio, OpenRouter, Groq…).**

- **Five providers, one chat** — Ollama (fully local, nothing leaves
  your machine), Anthropic Claude, Google Gemini, OpenAI, or a custom
  OpenAI-compatible endpoint. API keys are stored in the OS keychain,
  never in plain text.
- **Per-chat model picker** — the chat header shows the active
  provider · model; tap it to switch this conversation to any configured
  provider and model without touching the app default.
- **Streaming chat** — token-by-token responses with stop/cancel
  mid-reply and clearable history.
- **Attach any file as context** — pick one with the paperclip, or
  toggle "Include selection" to send the file selected in the browser:
  - Text and code sent as-is (up to 200 KB).
  - PDFs extracted via poppler `pdftotext` (LibreOffice fallback).
  - Word / Excel / PowerPoint extracted via LibreOffice.
  - Images passed to vision-capable models (up to 6 MB).
- **Connection pill** in the top bar — green means your provider is
  reachable; shows the active model, click to open Settings.
- **Fully configurable** — per-provider settings (Ollama host URL, API
  keys, custom base URL), model picker populated live from each
  provider, temperature slider (0.0–1.5), and a Save & Test button.

## ⛓ Workflows — reusable AI pipelines for your files

**Chain prompts into multi-step workflows and run them on any file with one click.**

- Each step has a name, a prompt template, and an optional per-step model
  override — e.g. summarize with a small fast model, then critique with a
  larger one.
- **Template placeholders:** `{file_content}`, `{file_name}`,
  `{file_path}`, `{prev}` (previous step's output), and `{step_1}`,
  `{step_2}`, … to reference any earlier step.
- **Visual editor** — create, edit, and delete workflows with a built-in
  placeholder cheat sheet.
- **Live run view** — each step's output streams in as it's generated;
  workflows are saved locally and re-runnable from the Workflows tab.

## 🔍 Duplicate Finder — reclaim your disk

**Find true duplicates by content — not by name — and clean them up in bulk.**

- **Content-based matching** — size bucketing + SHA-256 hashing catches
  identical files no matter what they're called; hashing is streamed, so
  huge files never load into memory, and scans run on a background isolate
  so the UI never stutters.
- **Choose your scope** — any combination of drives and common folders
  (Home / Desktop / Documents / Downloads).
- **Smart filters** — skips dev/build folders (`node_modules`, `.git`,
  `venv`, `build`, …), treats app bundles as single items, optional
  hidden-file inclusion, file-type filters (Images / Videos / Audio /
  Documents), and custom skip lists. Trash is always excluded.
- **Live progress** with cancel, plus reclaimable-space totals per group
  and overall.
- **Bulk cleanup** — pick a keep strategy (Newest / Oldest / Shortest
  path) and trash the rest with one confirmation; or handle groups and
  files individually (preview, reveal, trash).
- **Side-by-side comparison** — open a duplicate group straight into the
  Quick Look viewer and flip between copies.
- **Scans persist** — results and preferences are saved and restored
  across launches.

## 📊 System Overview — know your disks

**A dashboard for your storage, with AI-generated cleanup advice.**

- **Per-drive usage** — used / free / total with color-coded warnings at
  75% and 90%, plus hostname, OS, and drive-count summary.
- **Quick Folder Scan** — one-level breakdown of Desktop / Documents /
  Downloads into Images / Videos / Audio / Docs / Code / Other, shown as a
  stacked bar with counts and sizes.
- **AI Insights** — your disk stats go to your local model, which streams
  back concise bullet points on storage health, biggest consumers, and
  what to clean up.

## ⌨️ Integrated terminal — a shell where your files are

**A real PTY terminal docked at the bottom of the window, one keystroke away.**

- Toggle with **⌘J** (macOS) / **Ctrl+J** (Windows/Linux).
- **VSCode-style tabs** — multiple sessions, per-tab close, clear button,
  drag-to-resize panel.
- **Folder-aware** — new sessions open in the folder you're browsing, and
  switching folders sends `cd` to the active tab.
- Uses your login shell (`$SHELL` / zsh / bash) on macOS and Linux,
  PowerShell on Windows.

## 📡 P2P File Transfer — AirDrop for every desktop *(beta)*

> **Beta:** code-complete and security-hardened, currently in live
> verification. Label as "beta" or "early access" on the landing page.

**Send files machine-to-machine, directly, encrypted — across the room or across the internet. No accounts, no upload servers, no size-limit paywalls.**

- **Truly peer-to-peer** — file bytes travel over an encrypted WebRTC
  DataChannel straight between machines; they never touch a server. A free
  Firebase Realtime Database relays only kilobyte-sized signaling messages.
- **Pair once, send forever** — every install has a stable identity with
  an Ed25519 keypair and a shareable machine code. Add a contact once via
  QR code or copy-paste; no per-transfer codes ever again.
- **LAN fast path** — contacts on the same network transfer directly over
  UDP-discovered TCP sockets (faster, fully offline), with automatic
  fallback to WebRTC. Toggleable in Settings.
- **Consent built in** — every incoming transfer shows an Accept/Decline
  dialog; the app raises itself from the tray to ask.
- **Security by default:**
  - All signaling messages Ed25519-signed and verified against the saved
    contact's key — unknown senders are rejected.
  - Replay protection (±5-minute freshness window).
  - SHA-256 integrity check per file, with cleanup of partial files on
    mismatch.
  - DoS bounds (max 1000 files / 50 GB per request) and stall watchdogs.
- **Live progress** — per-file and overall bars, cancel mid-transfer, and
  a persisted transfer history.
- Received files land in `~/Downloads/Notilus` by default (configurable).

## 🖥 Desktop citizen — tray, notifications, native feel

**Behaves like a real native app on every platform.**

- **Minimize to system tray** — close the window and Notilus keeps
  listening for incoming transfers; restore from the tray icon or menu.
  Toggleable ("Receive in the background").
- **Native notifications** — desktop banners announce incoming transfer
  requests even when the window is hidden.
- **Native windowing** — enforced 900×600 minimum size, edge-to-edge
  macOS titlebar under the traffic lights.
- **Responsive** — one codebase adapts from a full three-pane desktop
  layout to a compact tabbed layout on narrow windows and phones.

## 🎨 Appearance & settings

- **System / Light / Dark** — follows your OS appearance by default, or
  override in Settings.
- **Pure-neutral dark theme** — true-gray (R=G=B) surfaces with a single
  blue accent; easy on OLED and on the eyes.
- **Persistent layout** — collapsible sidebar and right panel, view
  options, and duplicate-finder preferences are all remembered.

---

## Keyboard & gesture cheat sheet

| Action | Desktop | Touch |
|---|---|---|
| Select file | Click | Tap |
| Multi-select | Cmd/Ctrl-click, Shift-click, marquee drag | — |
| Select all | Cmd/Ctrl+A | — |
| Open folder / file | Double-click | Tap |
| Quick Look preview | **Space** | Tap |
| Cycle preview siblings | ← / → / Space | Swipe |
| Preview info sheet | **I** | — |
| Close preview | **Esc** | Back / swipe down |
| Context menu | Right-click | Long-press |
| Toggle terminal | **⌘J** / **Ctrl+J** | — |

---

## Privacy & trust points (for the landing page)

- **Local-first by design** — no cloud storage, no account, no telemetry.
- The AI can run entirely on **your** hardware via Ollama — file contents
  you attach go to `localhost` (or a machine you choose), nowhere else.
  Cloud providers (Claude, Gemini, OpenAI) are strictly opt-in, use your
  own API keys, and those keys live in the OS keychain.
- P2P transfers are end-to-end: DTLS-encrypted in transit, signed
  signaling, hash-verified on arrival — and the file bytes never touch a
  server.
- All app data (settings, workflows, contacts, scan results) lives on
  your device.

## Honest caveats (don't overclaim on the page)

- P2P transfer is **beta**; it needs both machines running Notilus, and
  double-symmetric-NAT networks fail with a clear message (no TURN relay).
  Interrupted transfers restart from scratch (no resume yet).
- Office previews and PDF/Office text extraction rely on **LibreOffice /
  poppler** being installed (graceful fallbacks included).
- macOS builds are ad-hoc signed, **not notarized** (installer handles
  the quarantine flag).
- iOS/iPadOS are build-from-source and sandbox-limited to the app's
  Documents folder.
- Sidebar **Tags** section is a visual placeholder (no persistence yet).
- No in-folder file search yet (on the roadmap).
