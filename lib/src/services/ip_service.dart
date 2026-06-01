import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks.dart';

/// Detects the machine's current public IP by trying three providers in order:
/// ipinfo.io → 2ip.me → Cloudflare cdn-cgi/trace.
///
/// When [socks5Proxy] is provided (e.g. `"127.0.0.1:1080"`), all requests are
/// tunnelled through that SOCKS5 proxy so the reported IP reflects the VPN
/// exit node rather than the local machine's address.
///
/// In TUN mode the OS routes all traffic through the tunnel automatically, so
/// no proxy needs to be specified — a plain request already exits via the VPN.
class IpService {
  static const _timeout = Duration(seconds: 8);

  static Future<String> fetchPublicIp({
    String? socks5Proxy,
    String? socks5Username,
    String? socks5Password,
  }) async {
    final client = _buildClient(
      socks5Proxy,
      username: socks5Username,
      password: socks5Password,
    );
    try {
      for (final fetcher in [
        () => _fromIpInfo(client),
        () => _from2Ip(client),
        () => _fromCloudflare(client),
      ]) {
        try {
          final ip = await fetcher();
          if (ip != null && ip.isNotEmpty) return ip;
        } catch (_) {}
      }
      return 'Unknown';
    } finally {
      client.close();
    }
  }

  // ── HTTP client factory ────────────────────────────────────────────────────

  static http.Client _buildClient(
    String? socks5Proxy, {
    String? username,
    String? password,
  }) {
    if (socks5Proxy == null || socks5Proxy.isEmpty) return http.Client();

    final colonIdx = socks5Proxy.lastIndexOf(':');
    if (colonIdx < 0) return http.Client();

    final host = socks5Proxy.substring(0, colonIdx);
    final port = int.tryParse(socks5Proxy.substring(colonIdx + 1)) ?? 1080;

    final httpClient = HttpClient();
    SocksTCPClient.assignToHttpClient(httpClient, [
      ProxySettings(
        InternetAddress(host),
        port,
        username: username,
        password: password,
      ),
    ]);
    return IOClient(httpClient);
  }

  // ── Providers ──────────────────────────────────────────────────────────────

  static Future<String?> _fromIpInfo(http.Client client) async {
    final r =
        await client.get(Uri.parse('https://ipinfo.io/ip')).timeout(_timeout);
    if (r.statusCode == 200) return r.body.trim();
    return null;
  }

  static Future<String?> _from2Ip(http.Client client) async {
    final r = await client.get(
      Uri.parse('https://2ip.me/ip'),
      headers: {'User-Agent': 'curl/8.4.0'},
    ).timeout(_timeout);
    if (r.statusCode != 200) return null;
    // Response with curl UA is structured:
    //   ip\t\t: XX.XX.XX.XX
    //   provider\t: ...
    //   location\t: ...
    final match =
        RegExp(r'^ip\s*:\s*(\S+)', multiLine: true).firstMatch(r.body);
    return match?.group(1)?.trim();
  }

  static Future<String?> _fromCloudflare(http.Client client) async {
    final r = await client
        .get(Uri.parse('https://1.1.1.1/cdn-cgi/trace'))
        .timeout(_timeout);
    if (r.statusCode == 200) {
      final match = RegExp(r'ip=(.+)').firstMatch(r.body);
      return match?.group(1)?.trim();
    }
    return null;
  }
}
