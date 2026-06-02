import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Extracts bundled icon assets to temp files and caches the paths.
/// tray_manager on Windows requires .ico files; PNG works on Linux/macOS.
class IconService {
  static String? _trayIconPath;
  static String? _appIconPath;

  /// Icon for the system tray.
  /// Windows: returns a .ico path (required by tray_manager on Win32).
  /// Linux/macOS: returns the 32×32 PNG.
  static Future<String> trayIconPath() async {
    if (_trayIconPath != null) return _trayIconPath!;
    if (Platform.isWindows) {
      _trayIconPath =
          await _extract('assets/icons/app_icon.ico', 'tt_tray.ico');
    } else {
      _trayIconPath =
          await _extract('assets/icons/tray_icon.png', 'tt_tray.png');
    }
    return _trayIconPath!;
  }

  /// Icon for the window title bar / taskbar.
  /// Windows: returns a .ico path (required by window_manager on Win32).
  /// Linux/macOS: returns the 512×512 PNG.
  static Future<String> appIconPath() async {
    if (_appIconPath != null) return _appIconPath!;
    if (Platform.isWindows) {
      _appIconPath =
          await _extract('assets/icons/app_icon.ico', 'tt_app_icon.ico');
    } else {
      _appIconPath =
          await _extract('assets/icons/app_icon.png', 'tt_app_icon.png');
    }
    return _appIconPath!;
  }

  static Future<String> _extract(String asset, String fileName) async {
    final data = await rootBundle.load(asset);
    final tmpDir = await getTemporaryDirectory();
    final file = File('${tmpDir.path}/$fileName');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }
}
