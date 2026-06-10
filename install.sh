#!/usr/bin/env sh
# Notilus installer (macOS + Linux).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/JayashBhandary/Notilus/main/install.sh | sh
#
# Detects platform/arch, downloads the latest GitHub release asset, and installs:
#   macOS -> /Applications/Notilus.app    (requires sudo)
#   Linux -> /opt/notilus  + symlink at /usr/local/bin/notilus  (requires sudo)

set -eu

REPO="JayashBhandary/Notilus"
APP_NAME="Notilus"

# ---------- platform detection ----------
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    PLATFORM="macos"
    case "$ARCH" in
      arm64)  ASSET_SUFFIX="macos-arm64.dmg" ;;
      x86_64) ASSET_SUFFIX="macos-x64.dmg" ;;
      *)      ASSET_SUFFIX="macos-universal.dmg" ;;
    esac
    ;;
  Linux)
    PLATFORM="linux"
    case "$ARCH" in
      x86_64|amd64) ASSET_SUFFIX="linux-x64.tar.gz" ;;
      *)
        echo "Unsupported Linux architecture: $ARCH" >&2
        echo "Only x86_64 Linux builds are published." >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    echo "Windows users: use install.ps1 instead." >&2
    exit 1
    ;;
esac

echo "==> Detected $PLATFORM / $ARCH -> looking for *${ASSET_SUFFIX}"

# ---------- pick latest release asset ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need curl

API_URL="https://api.github.com/repos/$REPO/releases/latest"

# Auth header if GITHUB_TOKEN is set (avoids rate limits for power users)
AUTH_HEADER=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
fi

if [ -n "$AUTH_HEADER" ]; then
  RELEASE_JSON=$(curl -fsSL -H "$AUTH_HEADER" "$API_URL")
else
  RELEASE_JSON=$(curl -fsSL "$API_URL")
fi

ASSET_URL=$(printf '%s' "$RELEASE_JSON" \
  | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
  | sed -E 's/.*"([^"]+)"$/\1/' \
  | grep -- "$ASSET_SUFFIX" \
  | head -n 1)

if [ -z "$ASSET_URL" ]; then
  echo "Could not find a release asset matching *${ASSET_SUFFIX} in $REPO." >&2
  echo "Visit https://github.com/$REPO/releases to inspect available assets." >&2
  exit 1
fi

# ---------- download ----------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
FILENAME="$TMPDIR/$(basename "$ASSET_URL")"

echo "==> Downloading $ASSET_URL"
curl -fSL --progress-bar -o "$FILENAME" "$ASSET_URL"

# ---------- install ----------
case "$PLATFORM" in
  macos)
    echo "==> Mounting DMG"
    MOUNT_OUTPUT=$(hdiutil attach "$FILENAME" -nobrowse -readonly -plist)
    MOUNT_DIR=$(printf '%s' "$MOUNT_OUTPUT" \
      | grep -A1 '<key>mount-point</key>' \
      | grep '<string>' \
      | head -n 1 \
      | sed -E 's/.*<string>(.*)<\/string>.*/\1/')

    if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR/$APP_NAME.app" ]; then
      echo "Failed to locate $APP_NAME.app inside the mounted DMG." >&2
      exit 1
    fi

    echo "==> Installing to /Applications/$APP_NAME.app (sudo required)"
    sudo rm -rf "/Applications/$APP_NAME.app"
    sudo cp -R "$MOUNT_DIR/$APP_NAME.app" /Applications/
    sudo xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true

    hdiutil detach "$MOUNT_DIR" -quiet || true

    echo ""
    echo "Installed: /Applications/$APP_NAME.app"
    echo "Launch:    open -a $APP_NAME"
    ;;

  linux)
    INSTALL_DIR="/opt/notilus"
    BIN_LINK="/usr/local/bin/notilus"
    DESKTOP_FILE="/usr/share/applications/notilus.desktop"
    ICON_DIR="/usr/share/icons/hicolor/512x512/apps"
    ICON_FILE="$ICON_DIR/notilus.png"
    PIXMAP_FILE="/usr/share/pixmaps/notilus.png"

    echo "==> Installing to $INSTALL_DIR (sudo required)"
    sudo rm -rf "$INSTALL_DIR"
    sudo mkdir -p "$INSTALL_DIR"
    sudo tar -xzf "$FILENAME" -C "$INSTALL_DIR"

    # Find the executable inside the bundle and symlink it
    EXEC_PATH=""
    for candidate in "$INSTALL_DIR/notilus" "$INSTALL_DIR/Notilus"; do
      if [ -x "$candidate" ]; then
        EXEC_PATH="$candidate"
        break
      fi
    done

    if [ -n "$EXEC_PATH" ]; then
      sudo ln -sf "$EXEC_PATH" "$BIN_LINK"
    else
      echo "Could not auto-detect the executable; skipping CLI symlink." >&2
    fi

    # Install desktop entry so it shows up in app launchers
    if [ -f "$INSTALL_DIR/notilus.desktop" ] && [ -n "$EXEC_PATH" ]; then
      echo "==> Registering desktop entry at $DESKTOP_FILE"
      sudo mkdir -p "$(dirname "$DESKTOP_FILE")"
      sudo sh -c "sed 's|@EXEC@|$EXEC_PATH|g' '$INSTALL_DIR/notilus.desktop' > '$DESKTOP_FILE'"
      sudo chmod 644 "$DESKTOP_FILE"
    fi

    # Install icon into the hicolor theme + /usr/share/pixmaps fallback
    if [ -f "$INSTALL_DIR/notilus.png" ]; then
      echo "==> Installing app icon"
      sudo mkdir -p "$ICON_DIR"
      sudo cp "$INSTALL_DIR/notilus.png" "$ICON_FILE"
      sudo chmod 644 "$ICON_FILE"
      sudo mkdir -p "$(dirname "$PIXMAP_FILE")"
      sudo cp "$INSTALL_DIR/notilus.png" "$PIXMAP_FILE"
      sudo chmod 644 "$PIXMAP_FILE"
    fi

    # Refresh desktop + icon caches so the entry appears without re-login
    if command -v update-desktop-database >/dev/null 2>&1; then
      sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi

    echo ""
    echo "Installed: $INSTALL_DIR"
    if [ -n "$EXEC_PATH" ]; then
      echo "Launch:    notilus    (symlinked from $BIN_LINK), or from your app launcher"
    fi
    ;;
esac

echo "Done."
