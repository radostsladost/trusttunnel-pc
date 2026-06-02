import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

/// Downloads and installs the TrustTunnel client binary from GitHub Releases.
class InstallerService {
  static const String _githubApiUrl =
      'https://api.github.com/repos/TrustTunnel/TrustTunnelClient/releases/latest';

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns `true` if the binary exists at [customPath] or the default path.
  static Future<bool> isInstalled({String? customPath}) async {
    final path = customPath ?? getDefaultBinaryPath();
    return File(path).existsSync();
  }

  /// Returns the full path to the binary in the default install directory.
  static String getDefaultBinaryPath() {
    final sep = Platform.pathSeparator;
    return '${getDefaultInstallDir()}$sep${_binaryName()}';
  }

  /// Returns the default directory where the binary should be placed.
  static String getDefaultInstallDir() {
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/root';
      return '$home/.local/bin/trusttunnel';
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '/Users/user';
      return '$home/Library/Application Support/TrustTunnel';
    } else if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'] ??
          r'C:\Users\User\AppData\Local';
      return '$local\\TrustTunnel';
    }
    return '/tmp/trusttunnel';
  }

  /// Downloads and installs the binary into [installDir].
  ///
  /// [onProgress] is called with (bytesReceived, totalBytes) during download.
  /// `totalBytes` is `-1` when the server does not report Content-Length.
  static Future<void> install({
    required String installDir,
    void Function(int received, int total)? onProgress,
    http.Client? httpClient,
  }) async {
    final downloadUrl = await _resolveDownloadUrl(httpClient: httpClient);
    if (downloadUrl == null) {
      throw Exception(
        'No suitable binary found for the current platform in the latest release.',
      );
    }

    final bytes = await _download(
      downloadUrl,
      onProgress: onProgress,
      httpClient: httpClient,
    );

    // Ensure the install directory exists.
    final dir = Directory(installDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    // Extract based on archive type.
    final lower = downloadUrl.toLowerCase();
    if (lower.endsWith('.zip')) {
      _extractZip(bytes, installDir);
    } else {
      // Assume .tar.gz
      _extractTarGz(bytes, installDir);
    }

    // Make the binary executable on POSIX platforms.
    if (Platform.isLinux || Platform.isMacOS) {
      final binaryPath = '$installDir${Platform.pathSeparator}${_binaryName()}';
      await Process.run('chmod', ['755', binaryPath]);
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static String _binaryName() =>
      Platform.isWindows ? 'trusttunnel_client.exe' : 'trusttunnel_client';

  /// Returns `true` if the current Linux machine is ARM-based.
  static Future<bool> _isArm() async {
    if (!Platform.isLinux) return false;
    try {
      final cpuinfo = await File('/proc/cpuinfo').readAsString();
      final lower = cpuinfo.toLowerCase();
      return lower.contains('aarch64') || lower.contains('arm');
    } catch (_) {
      return false;
    }
  }

  /// Queries the GitHub API and returns the best matching download URL.
  static Future<String?> _resolveDownloadUrl({http.Client? httpClient}) async {
    final client = httpClient ?? http.Client();
    final ownClient = httpClient == null;
    try {
      final response = await client.get(
        Uri.parse(_githubApiUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'TrustTunnelPC',
        },
      );

      if (response.statusCode != 200) {
        final hint = response.statusCode == 403
            ? ' (rate limit – try again later or check your network)'
            : response.statusCode == 404
                ? ' (repository or release not found)'
                : '';
        throw Exception(
          'GitHub API returned HTTP ${response.statusCode}$hint.',
        );
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final assets = data['assets'] as List<dynamic>?;
      if (assets == null || assets.isEmpty) return null;

      final arm = await _isArm();

      for (final asset in assets) {
        final url = (asset['browser_download_url'] as String?) ?? '';
        final lower = url.toLowerCase();

        if (Platform.isLinux) {
          if (arm) {
            if (lower.contains('linux') &&
                (lower.contains('aarch64') || lower.contains('arm64'))) {
              return url;
            }
          } else {
            if (lower.contains('linux') && lower.contains('x86_64')) {
              return url;
            }
          }
        } else if (Platform.isMacOS) {
          if (lower.contains('macos') || lower.contains('darwin')) {
            return url;
          }
        } else if (Platform.isWindows) {
          if (lower.contains('windows') && lower.contains('x86_64')) {
            return url;
          }
        }
      }
    } finally {
      if (ownClient) client.close();
    }

    return null;
  }

  /// Streams the file at [url] and returns the raw bytes.
  static Future<List<int>> _download(
    String url, {
    void Function(int received, int total)? onProgress,
    http.Client? httpClient,
  }) async {
    final client = httpClient ?? http.Client();
    final ownClient = httpClient == null;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final streamed = await client.send(request);

      if (streamed.statusCode != 200) {
        throw Exception('Download failed: HTTP ${streamed.statusCode}');
      }

      final total = streamed.contentLength ?? -1;
      var received = 0;
      final bytes = <int>[];

      await for (final chunk in streamed.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      return bytes;
    } finally {
      if (ownClient) client.close();
    }
  }

  /// Extracts the client binary from a `.tar.gz` archive into [destDir].
  static void _extractTarGz(List<int> bytes, String destDir) {
    final tarBytes = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(tarBytes);
    _writeBinaryFromArchive(archive, destDir);
  }

  /// Extracts the client binary from a `.zip` archive into [destDir].
  static void _extractZip(List<int> bytes, String destDir) {
    final archive = ZipDecoder().decodeBytes(bytes);
    _writeBinaryFromArchive(archive, destDir);
  }

  /// Writes the first matching binary file from [archive] to [destDir].
  static void _writeBinaryFromArchive(Archive archive, String destDir) {
    final name = _binaryName();
    for (final file in archive) {
      if (!file.isFile) continue;

      // Strip any leading directory components and compare just the filename.
      final fileName = file.name.split('/').last.split(r'\').last;
      if (fileName == name || fileName == 'trusttunnel_client') {
        final outFile = File('$destDir${Platform.pathSeparator}$fileName');
        outFile.writeAsBytesSync(file.content as List<int>);
        return;
      }
    }
    throw Exception('Binary "$name" not found inside the downloaded archive.');
  }
}
