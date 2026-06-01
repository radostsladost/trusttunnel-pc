import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../services/installer_service.dart';
import '../services/proxy_service.dart';
import 'proxy_provider.dart';

// ---------------------------------------------------------------------------
// InstallState
// ---------------------------------------------------------------------------

// Sentinel used to distinguish "not provided" from an explicit null in copyWith.
const Object _absent = Object();

class InstallState {
  const InstallState({
    required this.checking,
    required this.isInstalled,
    required this.installing,
    required this.progress,
    this.error,
    this.installedVersion,
  });

  final bool checking;
  final bool isInstalled;
  final bool installing;

  /// Download / install progress in the range 0.0–1.0.
  final double progress;

  /// Non-null when the last operation ended with an error.
  final String? error;

  /// Version string reported after a successful install check, if available.
  final String? installedVersion;

  static const InstallState initial = InstallState(
    checking: false,
    isInstalled: false,
    installing: false,
    progress: 0.0,
  );

  /// Returns a copy with the supplied fields overridden.
  ///
  /// Pass the [_absent] sentinel (default) for [error] / [installedVersion]
  /// to keep the current value; pass an explicit `null` to clear it.
  InstallState copyWith({
    bool? checking,
    bool? isInstalled,
    bool? installing,
    double? progress,
    Object? error = _absent,
    Object? installedVersion = _absent,
  }) {
    return InstallState(
      checking: checking ?? this.checking,
      isInstalled: isInstalled ?? this.isInstalled,
      installing: installing ?? this.installing,
      progress: progress ?? this.progress,
      error: identical(error, _absent) ? this.error : error as String?,
      installedVersion: identical(installedVersion, _absent)
          ? this.installedVersion
          : installedVersion as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final installerProvider =
    StateNotifierProvider<InstallerNotifier, InstallState>(
  (ref) => InstallerNotifier(ref),
);

// ---------------------------------------------------------------------------
// InstallerNotifier
// ---------------------------------------------------------------------------

class InstallerNotifier extends StateNotifier<InstallState> {
  InstallerNotifier(this._ref) : super(InstallState.initial);

  final Ref _ref;

  /// Check whether the client binary is already installed.
  ///
  /// [customPath] may point to a non-default binary location.
  Future<void> checkInstalled({String? customPath}) async {
    state = state.copyWith(checking: true, error: null);
    try {
      final installed = await InstallerService.isInstalled(
        customPath: customPath,
      );
      state = state.copyWith(
        checking: false,
        isInstalled: installed,
      );
    } catch (e) {
      state = state.copyWith(
        checking: false,
        error: e.toString(),
      );
    }
  }

  /// Download and install the client binary.
  ///
  /// [customInstallDir] overrides the platform default install directory.
  /// Progress is reported in [InstallState.progress] (0.0–1.0).
  Future<void> install({String? customInstallDir}) async {
    state = state.copyWith(
      installing: true,
      progress: 0.0,
      error: null,
    );
    http.Client? client;
    try {
      final installDir =
          customInstallDir ?? InstallerService.getDefaultInstallDir();

      // Build a proxy-aware HTTP client from the current proxy config.
      final proxyConfig = _ref.read(proxyConfigProvider);
      client = await ProxyService.createClient(proxyConfig);

      await InstallerService.install(
        installDir: installDir,
        httpClient: client,
        onProgress: (int received, int total) {
          final progress = total > 0 ? received / total : 0.0;
          state = state.copyWith(progress: progress.clamp(0.0, 1.0));
        },
      );

      state = state.copyWith(
        installing: false,
        isInstalled: true,
        progress: 1.0,
      );
    } catch (e) {
      state = state.copyWith(
        installing: false,
        error: e.toString(),
      );
    } finally {
      client?.close();
    }
  }
}
