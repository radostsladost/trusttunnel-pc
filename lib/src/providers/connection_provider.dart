import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/profile.dart';
import '../services/installer_service.dart';
import '../services/process_service.dart';
import '../services/storage_service.dart';

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final connectionStatusProvider =
    StateNotifierProvider<ConnectionNotifier, ConnectionStatus>(
  (ref) => ConnectionNotifier(ref),
);

/// The id of the profile that is currently (or was last) connected.
/// Null when no connection is active.
final connectedProfileIdProvider = StateProvider<String?>((ref) => null);

final clientBinaryPathProvider =
    StateNotifierProvider<ClientBinaryPathNotifier, String>(
  (ref) => ClientBinaryPathNotifier(),
);

// ---------------------------------------------------------------------------
// ConnectionNotifier
// ---------------------------------------------------------------------------

class ConnectionNotifier extends StateNotifier<ConnectionStatus> {
  ConnectionNotifier(this._ref) : super(ConnectionStatus.disconnected);

  final Ref _ref;

  /// Periodic health-check: detects unexpected process death while connected.
  Timer? _healthCheck;

  @override
  void dispose() {
    _healthCheck?.cancel();
    super.dispose();
  }

  // ── Connect ───────────────────────────────────────────────────────────────

  Future<void> connect(
    TrustTunnelProfile profile,
    String binaryPath,
    // ignore: avoid_unused_parameters
    WidgetRef ref,
  ) async {
    try {
      state = ConnectionStatus.connecting;
      _ref.read(connectedProfileIdProvider.notifier).state = profile.id;

      final tempDir = await getTemporaryDirectory();

      // start() now blocks until the tunnel is confirmed up (or throws).
      await ProcessService.instance.start(
        profile: profile,
        binaryPath: binaryPath,
        configDir: tempDir.path,
      );

      state = ConnectionStatus.connected;
      _startHealthCheck();
    } catch (e) {
      state = ConnectionStatus.error;
      _ref.read(connectedProfileIdProvider.notifier).state = null;
      rethrow;
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────

  /// Stops the VPN. Returns immediately – the process dies in the background.
  Future<void> disconnect() async {
    _healthCheck?.cancel();
    _healthCheck = null;

    // Mark disconnected right away so the UI is responsive.
    state = ConnectionStatus.disconnected;
    _ref.read(connectedProfileIdProvider.notifier).state = null;

    // stop() is non-blocking; actual process cleanup runs in the background.
    await ProcessService.instance.stop();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Polls every 3 seconds to detect if the process died unexpectedly
  /// (e.g. server closed the connection, TUN interface error).
  void _startHealthCheck() {
    _healthCheck?.cancel();
    _healthCheck = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!ProcessService.instance.isRunning &&
          state == ConnectionStatus.connected) {
        _healthCheck?.cancel();
        state = ConnectionStatus.error;
        _ref.read(connectedProfileIdProvider.notifier).state = null;
      }
    });
  }
}

// ---------------------------------------------------------------------------
// ClientBinaryPathNotifier
// ---------------------------------------------------------------------------

class ClientBinaryPathNotifier extends StateNotifier<String> {
  ClientBinaryPathNotifier() : super('');

  Future<void> loadFromStorage() async {
    final stored = await StorageService.loadBinaryPath();
    if (stored != null && stored.isNotEmpty) {
      state = stored;
    } else {
      state = InstallerService.getDefaultBinaryPath();
    }
  }

  Future<void> updatePath(String path) async {
    await StorageService.saveBinaryPath(path);
    state = path;
  }
}
