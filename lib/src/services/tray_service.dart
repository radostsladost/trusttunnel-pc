import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/profile.dart';
import '../providers/connection_provider.dart';
import '../providers/ip_provider.dart';
import '../providers/profiles_provider.dart';
import 'icon_service.dart';
import 'process_service.dart';

/// Manages the system-tray icon and context menu.
///
/// Call [initialize] once after the provider scope is ready, then call
/// [update] whenever connection state or IP changes to rebuild the menu.
class TrayService with TrayListener {
  // ── Singleton ──────────────────────────────────────────────────────────────
  TrayService._();
  static TrayService? _instance;
  static TrayService get instance => _instance ??= TrayService._();

  // ── State ──────────────────────────────────────────────────────────────────
  WidgetRef? _ref;
  bool _exitRequested = false;
  bool get exitRequested => _exitRequested;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> initialize(WidgetRef ref) async {
    _ref = ref;
    trayManager.addListener(this);
    // Set the window/taskbar icon once at startup.
    try {
      await windowManager.setIcon(await IconService.appIconPath());
    } catch (_) {}
    await _rebuild();
  }

  /// Call this whenever connection status or IP changes.
  Future<void> update(WidgetRef ref) async {
    _ref = ref;
    await _rebuild();
  }

  void dispose() {
    trayManager.removeListener(this);
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _rebuild() async {
    final ref = _ref;
    if (ref == null) return;

    final status = ref.read(connectionStatusProvider);
    final ip = ref.read(publicIpProvider);

    // Use the real bundled icon (extracted to a temp file).
    try {
      await trayManager.setIcon(await IconService.trayIconPath());
    } catch (_) {}

    // Set the context menu BEFORE the tooltip so that a missing tooltip
    // implementation (e.g. some Linux AppIndicator setups) cannot prevent
    // the menu from being registered.
    await trayManager.setContextMenu(Menu(items: [
      // On Linux/AppIndicator, left-click opens this menu directly.
      MenuItem(key: 'show', label: 'Show Window'),
      MenuItem.separator(),
      MenuItem(key: 'ip', label: 'IP: $ip', disabled: true),
      MenuItem.separator(),
      MenuItem(
        key: 'connect',
        label: 'Connect',
        disabled: status.isActive,
      ),
      MenuItem(
        key: 'disconnect',
        label: 'Disconnect',
        disabled: status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error,
      ),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: 'Exit'),
    ]));

    // setToolTip is not implemented on all Linux AppIndicator setups.
    try {
      await trayManager.setToolTip('TrustTunnel – ${_statusLabel(status)}');
    } catch (_) {}
  }

  String _statusLabel(ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected => 'Connected',
        ConnectionStatus.connecting => 'Connecting…',
        ConnectionStatus.disconnected => 'Disconnected',
        ConnectionStatus.disconnecting => 'Disconnecting…',
        ConnectionStatus.error => 'Error',
      };

  // ── TrayListener callbacks ─────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    // On Windows/macOS a left-click fires this event.
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    // On some Linux setups, right-click arrives here instead of opening
    // the menu automatically.
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
      case 'connect':
        _connectFromTray();
      case 'disconnect':
        _ref?.read(connectionStatusProvider.notifier).disconnect();
      case 'exit':
        _performExit();
    }
  }

  void _connectFromTray() {
    final ref = _ref;
    if (ref == null) {
      windowManager.show();
      windowManager.focus();
      return;
    }
    final profile = ref.read(selectedProfileProvider);
    final binaryPath = ref.read(clientBinaryPathProvider);
    if (profile == null || binaryPath.isEmpty) {
      windowManager.show();
      windowManager.focus();
      return;
    }
    ref
        .read(connectionStatusProvider.notifier)
        .connect(profile, binaryPath, ref);
  }

  Future<void> _performExit() async {
    _exitRequested = true;
    final ref = _ref;
    if (ref != null) {
      await ref.read(connectionStatusProvider.notifier).disconnect();
    } else {
      await ProcessService.instance.stop();
    }
    dispose();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}
