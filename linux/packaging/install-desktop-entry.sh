#!/usr/bin/env sh
# Register a locally built Notilus with the desktop environment.
#
# A GTK app gets its launcher name and icon from a .desktop file, not from the
# binary, so a local `flutter build linux` / `flutter run` window shows up as
# "com.jayash.notilus" with a generic icon until an entry exists. This installs
# one into ~/.local/share for the current user — no sudo, nothing in /usr.
#
# Usage:
#   linux/packaging/install-desktop-entry.sh [path/to/bundle]
#   linux/packaging/install-desktop-entry.sh --uninstall
#
# Defaults to build/linux/x64/{release,debug}/bundle, whichever exists.

set -eu

# Must equal APPLICATION_ID in linux/CMakeLists.txt — the shell matches a window
# to its .desktop file by GTK application id, then by WM_CLASS, and both come
# from that value.
APP_ID="com.jayash.notilus"

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
DESKTOP_FILE="$DATA_DIR/applications/$APP_ID.desktop"
HICOLOR_DIR="$DATA_DIR/icons/hicolor"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$DESKTOP_FILE"
  find "$HICOLOR_DIR" -name "$APP_ID.png" -delete 2>/dev/null || true
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$DATA_DIR/applications" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -f -t "$HICOLOR_DIR" >/dev/null 2>&1 || true
  echo "Removed $DESKTOP_FILE and its icons."
  exit 0
fi

# ---------- locate the built executable ----------
if [ $# -gt 0 ]; then
  BUNDLE="$1"
else
  BUNDLE=""
  for candidate in \
    "$REPO_ROOT/build/linux/x64/release/bundle" \
    "$REPO_ROOT/build/linux/x64/debug/bundle" \
    "$REPO_ROOT/build/linux/arm64/release/bundle" \
    "$REPO_ROOT/build/linux/arm64/debug/bundle"
  do
    if [ -x "$candidate/notilus" ]; then
      BUNDLE="$candidate"
      break
    fi
  done
fi

if [ -z "$BUNDLE" ] || [ ! -x "$BUNDLE/notilus" ]; then
  echo "No built bundle found. Run 'flutter build linux' first," >&2
  echo "or pass the bundle directory as an argument." >&2
  exit 1
fi

EXEC_PATH=$(CDPATH='' cd -- "$BUNDLE" && pwd)/notilus

# ---------- desktop entry ----------
mkdir -p "$(dirname "$DESKTOP_FILE")"
sed "s|@EXEC@|$EXEC_PATH|g" "$REPO_ROOT/linux/packaging/$APP_ID.desktop" > "$DESKTOP_FILE"
chmod 644 "$DESKTOP_FILE"
echo "==> Installed $DESKTOP_FILE"
echo "    Exec=$EXEC_PATH"

# ---------- icons ----------
SRC_ICON="$REPO_ROOT/assets/icon/icon.png"
if command -v convert >/dev/null 2>&1; then
  for size in 16 24 32 48 64 128 256 512; do
    dir="$HICOLOR_DIR/${size}x${size}/apps"
    mkdir -p "$dir"
    convert "$SRC_ICON" -resize "${size}x${size}" "$dir/$APP_ID.png"
  done
  echo "==> Installed icons under $HICOLOR_DIR"
else
  # No ImageMagick: a scalable entry still renders, just without per-size
  # hand-off, so the launcher downscales the 1024px source itself.
  mkdir -p "$HICOLOR_DIR/scalable/apps"
  cp "$SRC_ICON" "$HICOLOR_DIR/scalable/apps/$APP_ID.png"
  echo "==> Installed $HICOLOR_DIR/scalable/apps/$APP_ID.png"
  echo "    (install ImageMagick for correctly sized icons)"
fi

# ---------- refresh caches ----------
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DATA_DIR/applications" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$HICOLOR_DIR" >/dev/null 2>&1 || true
fi

echo "Done. Notilus should now show its name and icon in the launcher and dock."
