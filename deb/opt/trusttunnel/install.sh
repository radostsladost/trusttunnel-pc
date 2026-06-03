#!/usr/bin/env bash
# install.sh — installs TrustTunnel Desktop on Linux system-wide
# Run as root:  sudo bash install.sh
# Uninstall:    sudo bash install.sh --uninstall

set -euo pipefail

APP_NAME="trusttunnel"
DISPLAY_NAME="TrustTunnel"
BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/${APP_NAME}"
BIN_LINK="/usr/local/bin/${APP_NAME}"
ICON_DIR="/usr/share/icons/hicolor/512x512/apps"
DESKTOP_FILE="/usr/share/applications/${APP_NAME}.desktop"

# ── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1-}" == "--uninstall" ]]; then
  echo "Removing TrustTunnel Desktop..."
  rm -rf "$INSTALL_DIR"
  rm -f  "$BIN_LINK"
  rm -f  "$ICON_DIR/${APP_NAME}.png"
  rm -f  "$DESKTOP_FILE"
  update-desktop-database /usr/share/applications 2>/dev/null || true
  echo "Done."
  exit 0
fi

# ── Check bundle ──────────────────────────────────────────────────────────────
EXECUTABLE="${BUNDLE_DIR}/trustunnel_pc"
if [[ ! -f "$EXECUTABLE" ]]; then
  echo "ERROR: trustunnel_pc not found in ${BUNDLE_DIR}"
  echo "Run this script from inside the release bundle directory:"
  echo "  cd build/linux/x64/release/bundle && sudo bash /path/to/install.sh"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:  sudo bash install.sh"
  exit 1
fi

# ── Install ───────────────────────────────────────────────────────────────────
echo "Installing ${DISPLAY_NAME} to ${INSTALL_DIR}..."

# 1. Copy the entire bundle (preserving relative structure)
rm -rf "$INSTALL_DIR"
cp -r "$BUNDLE_DIR" "$INSTALL_DIR"
chmod +x "${INSTALL_DIR}/trustunnel_pc"

# 2. Symlink the executable so it's on PATH
ln -sf "${INSTALL_DIR}/trustunnel_pc" "$BIN_LINK"

# 3. Install icon
mkdir -p "$ICON_DIR"
ICON_SRC="${INSTALL_DIR}/data/flutter_assets/assets/icons/app_icon.png"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "${ICON_DIR}/${APP_NAME}.png"
  gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true
fi

# 4. Create .desktop entry
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${DISPLAY_NAME}
GenericName=VPN Client
Comment=TrustTunnel VPN desktop client
Exec=${INSTALL_DIR}/trustunnel_pc
Icon=${APP_NAME}
Terminal=false
Categories=Network;VPN;
Keywords=vpn;tunnel;proxy;privacy;
StartupWMClass=trusttunnel_pc
EOF

update-desktop-database /usr/share/applications 2>/dev/null || true

echo ""
echo "✓ ${DISPLAY_NAME} installed."
echo "  Run:        ${APP_NAME}"
echo "  App menu:   search for '${DISPLAY_NAME}'"
echo "  Uninstall:  sudo bash ${BUNDLE_DIR}/install.sh --uninstall"
