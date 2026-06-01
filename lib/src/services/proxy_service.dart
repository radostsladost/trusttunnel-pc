import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart';

import '../models/proxy_config.dart';

/// Creates an [http.Client] configured to use the given [ProxyConfig].
///
/// - SOCKS5 proxy: routed through [socks5_proxy] package.
/// - HTTP CONNECT proxy: routed via Dart's built-in [HttpClient.findProxy].
/// - Disabled or null config: returns a plain [http.Client].
class ProxyService {
  ProxyService._();

  /// Returns a ready-to-use [http.Client].
  ///
  /// The caller is responsible for closing the returned client.
  static Future<http.Client> createClient(ProxyConfig? config) async {
    if (config == null || !config.enabled) return http.Client();

    final httpClient = HttpClient();

    if (config.type == ProxyType.socks5) {
      // Resolve proxy host (handles both IP strings and hostnames).
      InternetAddress proxyAddr;
      try {
        // InternetAddress constructor resolves numeric IPs directly.
        proxyAddr = InternetAddress(config.host);
      } catch (_) {
        // Non-IP hostname → DNS lookup.
        try {
          proxyAddr = (await InternetAddress.lookup(config.host)).first;
        } catch (_) {
          // Fall back to treating it as a unix-type address so socks5_proxy
          // can pass the hostname string to the SOCKS5 server for remote DNS.
          proxyAddr =
              InternetAddress(config.host, type: InternetAddressType.unix);
        }
      }

      SocksTCPClient.assignToHttpClient(httpClient, [
        ProxySettings(
          proxyAddr,
          config.port,
          username: config.username.isNotEmpty ? config.username : null,
          password: config.password.isNotEmpty ? config.password : null,
        ),
      ]);
    } else {
      // HTTP CONNECT proxy
      final userInfo = config.username.isNotEmpty
          ? '${Uri.encodeComponent(config.username)}:${Uri.encodeComponent(config.password)}@'
          : '';
      httpClient.findProxy =
          (uri) => 'PROXY $userInfo${config.host}:${config.port}';
      // Accept proxy-injected certificates (common with MITM proxies).
      httpClient.badCertificateCallback = (_, __, ___) => true;
    }

    return IOClient(httpClient);
  }
}
