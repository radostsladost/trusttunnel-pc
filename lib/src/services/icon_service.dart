import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Extracts bundled icon assets to temp files and caches the paths.
///
/// On Windows, [tray_manager] and [window_manager] both require `.ico` files.
/// We create them at runtime by wrapping the app's PNG assets in the standard
/// PNG-in-ICO container format (supported by Windows Vista+).  This avoids
/// needing a separate `.ico` asset and ensures the tray / window icon always
/// matches the user's custom PNG.
class IconService {
  static String? _trayIconPath;
  static String? _appIconPath;

  /// Icon for the system tray.
  /// Windows → wraps tray_icon.png as a .ico file at runtime.
  /// Linux / macOS → returns the raw 32×32 PNG path.
  static Future<String> trayIconPath() async {
    if (_trayIconPath != null) return _trayIconPath!;
    if (Platform.isWindows) {
      _trayIconPath = await _extractAsIco(
        'assets/icons/tray_icon.png',
        'tt_tray.ico',
      );
    } else {
      _trayIconPath =
          await _extract('assets/icons/tray_icon.png', 'tt_tray.png');
    }
    return _trayIconPath!;
  }

  /// Icon for the window title bar / taskbar.
  /// Windows → wraps app_icon.png as a .ico file at runtime.
  /// Linux / macOS → returns the raw 512×512 PNG path.
  static Future<String> appIconPath() async {
    if (_appIconPath != null) return _appIconPath!;
    if (Platform.isWindows) {
      _appIconPath = await _extractAsIco(
        'assets/icons/app_icon.png',
        'tt_app_icon.ico',
      );
    } else {
      _appIconPath =
          await _extract('assets/icons/app_icon.png', 'tt_app_icon.png');
    }
    return _appIconPath!;
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Loads [asset] as PNG, wraps it in an ICO container, and writes to temp.
  static Future<String> _extractAsIco(String asset, String fileName) async {
    final data = await rootBundle.load(asset);
    final pngBytes = data.buffer.asUint8List();
    final icoBytes = _wrapPngAsIco(pngBytes);
    final tmpDir = await getTemporaryDirectory();
    final file = File('${tmpDir.path}/$fileName');
    await file.writeAsBytes(icoBytes, flush: true);
    return file.path;
  }

  /// Writes [asset] directly to a temp file and returns the path.
  static Future<String> _extract(String asset, String fileName) async {
    final data = await rootBundle.load(asset);
    final tmpDir = await getTemporaryDirectory();
    final file = File('${tmpDir.path}/$fileName');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }

  /// Wraps raw [pngBytes] in the Windows ICO container format.
  ///
  /// The PNG-in-ICO encoding is the standard way to ship high-quality icons
  /// on Windows Vista+.  The resulting bytes are a valid `.ico` file that
  /// Windows, [tray_manager], and [window_manager] all accept.
  ///
  /// ICO layout (all values little-endian):
  ///   ICONDIR      :  6 bytes  (reserved=0, type=1, count=1)
  ///   ICONDIRENTRY : 16 bytes  (one entry)
  ///   PNG data     : N bytes
  static List<int> _wrapPngAsIco(Uint8List pngBytes) {
    const dataOffset = 22; // 6 (ICONDIR) + 16 (ICONDIRENTRY)
    final n = pngBytes.length;

    return <int>[
      // ── ICONDIR ──────────────────────────────────────────────────────────
      0, 0, // reserved (must be 0)
      1, 0, // image type: 1 = ICO
      1, 0, // image count: 1
      // ── ICONDIRENTRY ─────────────────────────────────────────────────────
      0, // bWidth  : 0 means 256
      0, // bHeight : 0 means 256
      0, // bColorCount : 0 = true-color
      0, // bReserved
      1, 0, // wPlanes
      32, 0, // wBitCount : 32 bpp
      // dwBytesInRes (4 bytes LE)
      n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF,
      // dwImageOffset (4 bytes LE)
      dataOffset, 0, 0, 0,
      // ── PNG payload ───────────────────────────────────────────────────────
      ...pngBytes,
    ];
  }
}
