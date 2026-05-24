# Notilus

A Finder-style desktop file manager built in Flutter, with a built-in Ollama
chat panel and a workflow editor for running custom prompt chains against your
local files.

## Features

- **File browser** — sidebar with favorites, breadcrumb path bar, list view,
  and an info panel for the selected item. Cupertino UI with light/dark themes.
- **Ollama chat panel** — talk to any model you have pulled locally. Streams
  responses token-by-token via `/api/generate`.
- **Workflow editor** — build multi-step prompt chains (each step has its own
  template and optional model override) and run them as repeatable workflows.
- **Local settings** — preferences and saved workflows persist via
  `shared_preferences`; no cloud, no account.

## Project layout

```
lib/
├── app.dart                 # MultiProvider + CupertinoApp wiring
├── main.dart
├── theme.dart
├── models/                  # FileEntry, ChatMessage, Workflow, WorkflowStep
├── providers/               # Browser, Chat, Settings, Workflow state
├── screens/                 # Home, Settings, SystemOverview, WorkflowEditor
├── services/                # FileService, OllamaService, SettingsStore, ...
└── widgets/                 # Sidebar, FileListView, ChatPanel, ...
```

## Getting started

### Prerequisites

- Flutter `>=3.10.0` with Dart `>=3.0.0`
- A running [Ollama](https://ollama.com) instance (default host
  `http://localhost:11434`) with at least one model pulled, e.g.:

  ```sh
  ollama pull llama3.2
  ```

### Run

```sh
flutter pub get
flutter run -d macos      # or: linux, windows
```

Point the app at your Ollama host from **Settings** if it isn't on the default
port, then pick a model and start chatting or create a workflow.

## Workflows

A workflow is an ordered list of `WorkflowStep`s. Each step has:

- `name` — display label
- `prompt` — prompt template for that step
- `model` *(optional)* — overrides the default chat model for this step only

Workflows are saved as JSON via `SettingsStore` and can be re-run from the
workflow tab on the home screen.

## Status

Version `0.1.0+1` — early, single-developer project. Desktop targets
(macOS / Linux / Windows) are the focus; mobile targets are scaffolded but
not the primary use case.
