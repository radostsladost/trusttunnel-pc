import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

  /// Retry loop: runs while state == reconnecting.
  // ignore: unused_field
  Future<void>? _reconnectFuture;

  /// Saved so we can reconnect without user input.
  TrustTunnelProfile? _lastProfile;
  String? _lastBinaryPath;

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

      // Remember for auto-reconnect.
      _lastProfile = profile;
      _lastBinaryPath = binaryPath;

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

    // Setting state to disconnected causes the reconnect loop (if any) to
    // stop iterating on its next check.
    state = ConnectionStatus.disconnected;
    _ref.read(connectedProfileIdProvider.notifier).state = null;
    _lastProfile = null;
    _lastBinaryPath = null;

    // stop() is non-blocking; actual process cleanup runs in the background.
    await ProcessService.instance.stop();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Polls every 3 seconds to detect if the process died unexpectedly.
  /// On unexpected death it checks whether the internet is reachable:
  ///   • Reachable  → server-side error; transitions to [ConnectionStatus.error].
  ///   • Unreachable → network loss; transitions to [ConnectionStatus.reconnecting]
  ///                   and starts the auto-reconnect loop.
  void _startHealthCheck() {
    _healthCheck?.cancel();
    _healthCheck = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!ProcessService.instance.isRunning &&
          state == ConnectionStatus.connected) {
        _healthCheck?.cancel();
        _healthCheck = null;

        final profile = _lastProfile;
        final binaryPath = _lastBinaryPath;

        if (profile == null || binaryPath == null) {
          state = ConnectionStatus.error;
          _ref.read(connectedProfileIdProvider.notifier).state = null;
          return;
        }

        // Give the OS a moment to settle after the process exits before
        // probing the network (route teardown may be in progress).
        await Future.delayed(const Duration(seconds: 1));

        final networkUp = await _isNetworkReachable();
        if (networkUp) {
          // Server-side issue or profile misconfiguration — don't reconnect
          // automatically (might loop forever on a broken config).
          state = ConnectionStatus.error;
          _ref.read(connectedProfileIdProvider.notifier).state = null;
        } else {
          // Network went away — wait for it to come back, then reconnect.
          state = ConnectionStatus.reconnecting;
          _reconnectFuture = _runReconnectLoop(profile, binaryPath);
        }
      }
    });
  }

  /// Waits for the network to return, then tries to reconnect with exponential
  /// backoff.  Stops if [state] leaves [ConnectionStatus.reconnecting]
  /// (e.g. the user clicked Disconnect).
  Future<void> _runReconnectLoop(
    TrustTunnelProfile profile,
    String binaryPath,
  ) async {
    const maxAttempts = 10;
    int attempts = 0;

    while (state == ConnectionStatus.reconnecting) {
      // ── Wait for network ──────────────────────────────────────────────────
      bool networkUp = false;
      for (int poll = 0;
          poll < 60 && state == ConnectionStatus.reconnecting;
          poll++) {
        if (await _isNetworkReachable()) {
          networkUp = true;
          break;
        }
        await _interruptibleDelay(const Duration(seconds: 3));
      }

      if (!networkUp || state != ConnectionStatus.reconnecting) {
        // Still no network after 3 min, or the user cancelled.
        if (state == ConnectionStatus.reconnecting) {
          state = ConnectionStatus.error;
          _ref.read(connectedProfileIdProvider.notifier).state = null;
        }
        return;
      }

      // ── Attempt reconnect ─────────────────────────────────────────────────
      attempts++;
      ProcessService.instance.logStream; // keep the log stream alive
      try {
        final tempDir = await getTemporaryDirectory();
        await ProcessService.instance.start(
          profile: profile,
          binaryPath: binaryPath,
          configDir: tempDir.path,
        );

        if (state == ConnectionStatus.reconnecting) {
          state = ConnectionStatus.connected;
          _ref.read(connectedProfileIdProvider.notifier).state = profile.id;
          _startHealthCheck();
        }
        return;
      } catch (_) {
        // start() failed — back off and retry.
        if (attempts >= maxAttempts) {
          if (state == ConnectionStatus.reconnecting) {
            state = ConnectionStatus.error;
            _ref.read(connectedProfileIdProvider.notifier).state = null;
          }
          return;
        }
        final backoff = Duration(seconds: math.min(30, 5 * attempts));
        await _interruptibleDelay(backoff);
      }
    }
  }

  /// Checks internet reachability by attempting a short TCP connect to
  /// Google's public DNS (8.8.8.8:53).  Returns true if the connection
  /// succeeds within 2 seconds.
  static Future<bool> _isNetworkReachable() async {
    try {
      final s = await Socket.connect(
        '8.8.8.8',
        53,
        timeout: const Duration(seconds: 2),
      );
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sleeps for [duration] but wakes up early if [state] changes away from
  /// [ConnectionStatus.reconnecting].
  Future<void> _interruptibleDelay(Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end) &&
        state == ConnectionStatus.reconnecting) {
      await Future.delayed(const Duration(seconds: 1));
    }
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
