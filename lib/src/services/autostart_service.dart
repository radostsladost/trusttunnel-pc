import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

/// Thin wrapper around `launch_at_startup` that configures itself lazily.
class AutostartService {
  static bool _initialized = false;

  static Future<void> _ensure() async {
    if (_initialized) return;
    launchAtStartup.setup(
      appName: 'TrustTunnel',
      appPath: Platform.resolvedExecutable,
    );
    _initialized = true;
  }

  /// Returns whether autostart is enabled, or `false` if the check fails
  /// (e.g. the LaunchAgents directory is not accessible yet).
  static Future<bool> isEnabled() async {
    try {
      await _ensure();
      return await launchAtStartup.isEnabled();
    } catch (_) {
      return false;
    }
  }

  /// Enables or disables autostart.  Throws if the operation fails so the
  /// caller can surface the error in the UI.
  static Future<void> setEnabled(bool value) async {
    await _ensure();
    if (value) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}
