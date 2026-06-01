import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Extracts bundled icon assets to temp files and caches the paths.
/// Both tray_manager and window_manager need filesystem paths on Linux.
class IconService {
  static String? _trayIconPath;
  static String? _appIconPath;

  /// 32×32 PNG for the system tray.
  static Future<String> trayIconPath() async {
    _trayIconPath ??=
        await _extract('assets/icons/tray_icon.png', 'tt_tray.png');
    return _trayIconPath!;
  }

  /// 512×512 PNG for the window/taskbar icon and in-app use.
  static Future<String> appIconPath() async {
    _appIconPath ??=
        await _extract('assets/icons/app_icon.png', 'tt_app_icon.png');
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
