import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/proxy_config.dart';
import '../services/proxy_service.dart';
import '../services/storage_service.dart';

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final proxyConfigProvider =
    StateNotifierProvider<ProxyConfigNotifier, ProxyConfig>(
  (ref) => ProxyConfigNotifier(),
);

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class ProxyConfigNotifier extends StateNotifier<ProxyConfig> {
  ProxyConfigNotifier() : super(ProxyConfig.disabled);

  Future<void> loadFromStorage() async {
    state = await StorageService.loadProxyConfig();
  }

  Future<void> update(ProxyConfig config) async {
    state = config;
    await StorageService.saveProxyConfig(config);
  }

  /// Convenience: creates a properly configured [http.Client] for the current
  /// proxy state. The caller must close the returned client.
  Future<dynamic> buildClient() => ProxyService.createClient(state);
}
