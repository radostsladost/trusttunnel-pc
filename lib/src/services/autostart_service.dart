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

  static Future<bool> isEnabled() async {
    await _ensure();
    return launchAtStartup.isEnabled();
  }

  static Future<void> setEnabled(bool value) async {
    await _ensure();
    if (value) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}
