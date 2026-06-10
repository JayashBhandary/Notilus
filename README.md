# Notilus

> A Finder-style file manager built in Flutter, with a built-in Ollama chat
> panel, a Quick-Look-style preview viewer, and a workflow editor for running
> custom prompt chains against your local files.

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
- **Multi-step workflows** — chain prompts (each with its own template
  and optional model override) and run them against the selected file.
- **System Overview** screen — disk usage per drive, shallow folder
  breakdown for Desktop / Documents / Downloads, plus an "AI Insights"
  panel that asks your local model for cleanup suggestions.
- **Native context menu** on right-click / long-press with Open,
  Open With (default app + system chooser), Rename, Duplicate,
  Copy Path, Reveal in Finder / Files, and Move to Trash.
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
  `On My iPhone` on iOS).
- **Tags** — placeholder section for future tag support.

In compact mode (phones / narrow windows) the sidebar collapses to a
slide-in drawer toggled by the menu button.

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
