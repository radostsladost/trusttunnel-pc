# TrustTunnel Desktop

A cross-platform desktop GUI client for the **TrustTunnel VPN protocol** — built with Flutter.  
Wraps the official [`trusttunnel_client`](https://github.com/TrustTunnel/TrustTunnelClient) CLI binary with a polished dark UI, system-tray integration, and per-profile route rules.

> **Supported platforms:** Linux · macOS · Windows


![screenshot](https://github.com/radostsladost/trusttunnel-pc/raw/refs/heads/main/screenshot.webp)


---

## Download

- [Windows](https://github.com/radostsladost/trusttunnel-pc/releases/download/v1.0.1/TrustTunnel-win-x64.zip)
- [Debian/Ubuntu .deb package](https://github.com/radostsladost/trusttunnel-pc/releases/download/v1.0.1/trusttunnel-desktop-1.0.0-amd64.deb)
- [Sources](https://github.com/radostsladost/trusttunnel-pc/releases)

## Features

### Connection
- **TUN mode** — system-wide VPN tunnel (requires elevation via `pkexec` on Linux / UAC on Windows)
- **SOCKS5 / HTTP proxy mode** — per-application proxying, sets system proxy automatically on connect
- One-click connect / disconnect with animated status indicator
- **Kill switch** — blocks all traffic if the VPN drops unexpectedly
- **Post-quantum** key exchange support
- **Anti-DPI** obfuscation to bypass deep-packet inspection
- Per-profile **exclusions** (IPs / CIDRs that bypass the tunnel)

### Profiles
- Add profiles manually, by pasting a `tt://` deep-link, or by importing a YAML / TOML config file
- Full editing of all endpoint parameters: hostname, addresses, credentials, DNS upstreams, TLS certificate, upstream protocol (HTTP/2 or HTTP/3 / QUIC)
- Per-profile **DNS route rules** (one rule per line, supports `domain:`, `cidr:`, `geoip:` prefixes — e.g. `domain:example.com`, `cidr:10.0.0.0/8`, `geoip:RU`)
- Drag-to-reorder profile list

### Public IP display
- Dashboard shows your current public IP, updated automatically on every connect / disconnect
- IP is fetched through the active SOCKS5 proxy when in SOCKS5 mode so it always reflects the VPN exit node
- Falls back across three providers: **ipinfo.io → 2ip.me → Cloudflare** (`1.1.1.1/cdn-cgi/trace`)
- Manual refresh button

### System tray
- Persistent tray icon (the real TrustTunnel icon, not a placeholder)
- Context menu: **Show Window · IP: x.x.x.x · Connect · Disconnect · Exit**
- Closing the window **hides to tray** instead of quitting; use *Exit* in the tray menu to fully close
- Tray menu reflects live connection state and current IP

### Settings
- **Autostart** — launch TrustTunnel at login (`.desktop` on Linux, registry key on Windows, launchd plist on macOS)
- **Global DNS route rules file** — a plain-text file with one rule per line, merged with per-profile rules at connection time; supports `#` comments
- Custom CLI binary path with auto-install / update from GitHub releases
- Upstream (chain) SOCKS5 / HTTP proxy support
- Connection log viewer (expandable, live tail)

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Flutter SDK | ≥ 3.3.0 | [Install Flutter](https://docs.flutter.dev/get-started/install) |
| Dart SDK | ≥ 3.3.0 | Bundled with Flutter |
| **Linux** — GTK 3 dev headers | — | `libgtk-3-dev` |
| **Linux** — AppIndicator | — | `libayatana-appindicator3-dev` or `libappindicator3-dev` |
| **Linux** — TUN mode | — | `pkexec` (PolicyKit) for elevation |
| **macOS** | 10.14+ | Xcode command-line tools |
| **Windows** | 10 1903+ | Visual Studio 2022 with C++ workload |

Install Flutter desktop dependencies in one step:

```bash
# Linux (Debian / Ubuntu)
sudo apt-get install \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev \
  libayatana-appindicator3-dev
```

---

## Building

### 1. Clone and get dependencies

```bash
git clone https://github.com/TrustTunnel/TrustTunnelFlutterClient
cd TrustTunnelFlutterClient
flutter pub get
```

### 2. Build

```bash
# Linux
flutter build linux --release

# macOS
flutter build macos --release

# Windows
flutter build windows --release
```

The compiled bundle is placed at:

| Platform | Output path |
|---|---|
| Linux | `build/linux/x64/release/bundle/` |
| macOS | `build/macos/Build/Products/Release/TrustTunnel.app` |
| Windows | `build/windows/x64/runner/Release/` |

### 3. Run without building (development)

```bash
flutter run -d linux    # or macos / windows
```

### 4. Distribute and install on Linux

The `bundle/` directory is **self-contained** — the executable resolves `lib/` and `data/` relative to itself, so all files must stay together.

#### Option A — Run directly (no install)
```bash
cd build/linux/x64/release/bundle
./trustunnel_pc
```

#### Option B — System-wide install (recommended)

Copy `install.sh` from the repo root into the bundle directory, then run:

```bash
cd build/linux/x64/release/bundle
cp /path/to/repo/install.sh .
sudo bash install.sh
```

The script:
1. Copies the entire bundle to `/opt/trusttunnel/`
2. Creates a symlink `/usr/local/bin/trusttunnel`
3. Installs the icon to `/usr/share/icons/hicolor/512x512/apps/`
4. Registers a `.desktop` entry so the app appears in your launcher

To uninstall:
```bash
sudo bash install.sh --uninstall
```

#### Option C — Portable tar.gz for sharing
```bash
cd build/linux/x64/release
tar -czf trusttunnel-desktop-linux-x64.tar.gz bundle/
```
Recipients extract it and can either run directly or use `install.sh`.

#### Option D — .deb package (optional, requires `dpkg-deb`)
```bash
BUNDLE=build/linux/x64/release/bundle
mkdir -p deb/opt/trusttunnel deb/usr/share/applications
cp -r "$BUNDLE"/* deb/opt/trusttunnel/
cat > deb/usr/share/applications/trusttunnel.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=TrustTunnel
Exec=/opt/trusttunnel/trustunnel_pc
Icon=trusttunnel
Categories=Network;VPN;
StartupWMClass=trusttunnel_pc
EOF
mkdir -p deb/DEBIAN
cat > deb/DEBIAN/control <<'EOF'
Package: trusttunnel-desktop
Version: 1.0.0
Architecture: amd64
Maintainer: you@example.com
Depends: libgtk-3-0, libayatana-appindicator3-1
Description: TrustTunnel VPN desktop client
EOF
dpkg-deb --build deb trusttunnel-desktop-1.0.0-amd64.deb
```

---

## First-time setup

1. **Launch** the app.
2. Go to **Settings → AUTO INSTALL TRUSTTUNNEL CLIENT** and click *Install / Update*.  
   This downloads the latest `trusttunnel_client` CLI binary for your platform from GitHub releases.
3. Go to **Profiles → +** and add a profile:
   - Paste a `tt://` deep-link from your server's export, **or**
   - Import a YAML / TOML config file, **or**
   - Fill in the fields manually (hostname, addresses, credentials).
4. Select the profile on the **Dashboard** and click **Connect**.

---

## DNS Route Rules file format

The global routes file (Settings → **GLOBAL DNS ROUTE RULES FILE**) is a plain-text file.  
Per-profile rules are entered in the profile editor under **Advanced → DNS Route Rules**.

```
# Lines starting with # are ignored
# Bypass by domain
domain:internal.corp
domain:192.168.local

# Bypass by CIDR
cidr:192.168.0.0/16
cidr:10.0.0.0/8

# Bypass by country (GeoIP)
geoip:RU
geoip:CN
```

Rules are merged (global file + active profile) and written to the TOML config as `dns_route_rules` before each connection.

---

## Project structure

```
lib/
├── main.dart                     # Entry point, window setup
└── src/
    ├── models/
    │   ├── profile.dart          # TrustTunnelProfile data model
    │   └── proxy_config.dart     # Upstream proxy model
    ├── providers/
    │   ├── app_providers.dart    # Startup initialisation
    │   ├── connection_provider.dart
    │   ├── installer_provider.dart
    │   ├── ip_provider.dart      # Public IP state (auto-refresh)
    │   ├── profiles_provider.dart
    │   └── proxy_provider.dart
    ├── screens/
    │   ├── home_screen.dart      # Dashboard (connect, IP, logs)
    │   ├── profiles_screen.dart
    │   ├── add_profile_screen.dart
    │   └── settings_screen.dart
    ├── services/
    │   ├── autostart_service.dart   # Launch-at-login
    │   ├── deeplink_service.dart    # tt:// URI parser
    │   ├── icon_service.dart        # Asset → temp-file extractor
    │   ├── installer_service.dart   # CLI binary download/install
    │   ├── ip_service.dart          # Public IP detection
    │   ├── process_service.dart     # CLI subprocess lifecycle
    │   ├── proxy_service.dart       # System proxy set/clear
    │   ├── storage_service.dart     # SharedPreferences persistence
    │   ├── toml_service.dart        # TOML config generation/parsing
    │   ├── tray_service.dart        # System tray icon & menu
    │   ├── yaml_service.dart        # YAML profile import/export
    │   └── ...
    ├── theme/
    │   └── app_theme.dart
    └── widgets/
        ├── connection_button.dart
        ├── gradient_button.dart
        ├── log_viewer.dart
        ├── neon_card.dart
        ├── profile_card.dart
        └── status_badge.dart
```

---

## Protocol

TrustTunnel is an open-source VPN protocol originally developed by [AdGuard VPN](https://adguard-vpn.com).  
Traffic is indistinguishable from regular HTTPS, making it resistant to throttling and deep-packet inspection.

- Supports HTTP/2 and HTTP/3 (QUIC) upstream transport
- Tunnels TCP, UDP, and ICMP
- Optional post-quantum key exchange
- Split tunnelling via exclusion lists and route rules

See the [CLI documentation](README_CLI.MD) for server setup, deep-link format, and TOML config reference.

---

## License

This project follows the same license as the upstream TrustTunnel project.  
See [LICENSE](LICENSE) for details.
