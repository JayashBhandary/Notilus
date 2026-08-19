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
    # APP_ID must stay in sync with APPLICATION_ID in linux/CMakeLists.txt: the
    # desktop entry and icon are only matched to the running window when their
    # names equal the GTK application id. Anything else and the shell shows the
    # bare app id with a generic icon.
    APP_ID="com.jayash.notilus"
    INSTALL_DIR="/opt/notilus"
    BIN_LINK="/usr/local/bin/notilus"
    DESKTOP_FILE="/usr/share/applications/$APP_ID.desktop"
    HICOLOR_DIR="/usr/share/icons/hicolor"
    PIXMAP_FILE="/usr/share/pixmaps/$APP_ID.png"

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

    # Drop the pre-0.4.1 entry and icons, which were named "notilus" and so
    # never matched a window. Left behind they show up as a second, iconless
    # launcher item.
    sudo rm -f /usr/share/applications/notilus.desktop \
               /usr/share/pixmaps/notilus.png \
               "$HICOLOR_DIR"/*/apps/notilus.png

    # Install desktop entry so it shows up in app launchers. Accept the old
    # bundle layout too, so this installer keeps working against older releases.
    SRC_DESKTOP=""
    for candidate in "$INSTALL_DIR/$APP_ID.desktop" "$INSTALL_DIR/notilus.desktop"; do
      if [ -f "$candidate" ]; then
        SRC_DESKTOP="$candidate"
        break
      fi
    done

    if [ -n "$SRC_DESKTOP" ] && [ -n "$EXEC_PATH" ]; then
      echo "==> Registering desktop entry at $DESKTOP_FILE"
      sudo mkdir -p "$(dirname "$DESKTOP_FILE")"
      sudo sh -c "sed 's|@EXEC@|$EXEC_PATH|g' '$SRC_DESKTOP' > '$DESKTOP_FILE'"
      # An older bundle's entry points Icon= and StartupWMClass= at "notilus";
      # rewrite them so window matching works regardless of bundle age.
      sudo sed -i "s|^Icon=.*|Icon=$APP_ID|; s|^StartupWMClass=.*|StartupWMClass=$APP_ID|" "$DESKTOP_FILE"
      sudo chmod 644 "$DESKTOP_FILE"
    fi

    # Install the hicolor icon tree the bundle ships, falling back to the
    # single full-size PNG for older bundles.
    if [ -d "$INSTALL_DIR/icons/hicolor" ]; then
      echo "==> Installing app icons"
      sudo cp -r "$INSTALL_DIR/icons/hicolor/." "$HICOLOR_DIR/"
      sudo find "$HICOLOR_DIR" -name "$APP_ID.png" -exec chmod 644 {} +
    fi

    SRC_ICON=""
    for candidate in "$INSTALL_DIR/$APP_ID.png" "$INSTALL_DIR/notilus.png"; do
      if [ -f "$candidate" ]; then
        SRC_ICON="$candidate"
        break
      fi
    done

    if [ -n "$SRC_ICON" ]; then
      # Scalable takes any pixel size, so the 1024px source needs no resize and
      # no guess about which fixed-size directory it belongs in.
      sudo mkdir -p "$HICOLOR_DIR/scalable/apps"
      sudo cp "$SRC_ICON" "$HICOLOR_DIR/scalable/apps/$APP_ID.png"
      sudo chmod 644 "$HICOLOR_DIR/scalable/apps/$APP_ID.png"
      sudo mkdir -p "$(dirname "$PIXMAP_FILE")"
      sudo cp "$SRC_ICON" "$PIXMAP_FILE"
      sudo chmod 644 "$PIXMAP_FILE"
    fi

    # Refresh desktop + icon caches so the entry appears without re-login
    if command -v update-desktop-database >/dev/null 2>&1; then
      sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      sudo gtk-update-icon-cache -f -t "$HICOLOR_DIR" >/dev/null 2>&1 || true
    fi

    echo ""
    echo "Installed: $INSTALL_DIR"
    if [ -n "$EXEC_PATH" ]; then
      echo "Launch:    notilus    (symlinked from $BIN_LINK), or from your app launcher"
    fi
    ;;
esac

echo "Done."
