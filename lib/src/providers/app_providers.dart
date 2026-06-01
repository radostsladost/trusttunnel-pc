import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_provider.dart';
import 'installer_provider.dart';
import 'ip_provider.dart';
import 'profiles_provider.dart';
import 'proxy_provider.dart';

// ---------------------------------------------------------------------------
// Provider observer
// ---------------------------------------------------------------------------

/// Lightweight observer that logs provider state changes in debug builds.
class AppProviderObserver extends ProviderObserver {
  const AppProviderObserver();

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (kDebugMode) {
      debugPrint(
        '[Provider] ${provider.name ?? provider.runtimeType}: '
        '$previousValue → $newValue',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Startup initialisation
// ---------------------------------------------------------------------------

/// Call once during app initialisation (e.g. inside the root widget's
/// [ConsumerStatefulWidget.initState] or a startup screen) to restore
/// all persisted state and perform the install check.
///
/// Example:
/// ```dart
/// @override
/// void initState() {
///   super.initState();
///   WidgetsBinding.instance.addPostFrameCallback((_) {
///     initializeProviders(ref);
///   });
/// }
/// ```
Future<void> initializeProviders(WidgetRef ref) async {
  await ref.read(proxyConfigProvider.notifier).loadFromStorage();
  await ref.read(profilesProvider.notifier).loadFromStorage();
  await ref.read(selectedProfileIdProvider.notifier).loadFromStorage();
  await ref.read(clientBinaryPathProvider.notifier).loadFromStorage();
  await ref.read(installerProvider.notifier).checkInstalled();
  // Trigger public-IP notifier construction so it starts its initial fetch.
  ref.read(publicIpProvider);
}
