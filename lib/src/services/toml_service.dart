import '../models/profile.dart';

/// Generates and parses `trusttunnel_client.toml` configuration files.
///
/// Generation produces a complete config suitable for running the client binary.
/// Parsing uses simple regex-based TOML reading (no external toml package).
class TomlService {
  // ---------------------------------------------------------------------------
  // Generation (profile → TOML string)
  // ---------------------------------------------------------------------------

  /// Generates a full TOML configuration file from [profile].
  static String generateToml(
    TrustTunnelProfile profile, {
    List<String> extraRoutes = const [],
  }) {
    final buf = StringBuffer();

    // Top-level settings
    buf.writeln('loglevel = "info"');
    buf.writeln('vpn_mode = "${profile.vpnMode}"');
    buf.writeln('killswitch_enabled = ${profile.killswitchEnabled}');
    buf.writeln(
      'killswitch_allow_ports = [${profile.killswitchAllowPorts.join(', ')}]',
    );
    buf.writeln('post_quantum_group_enabled = ${profile.postQuantumEnabled}');
    buf.writeln(
      'exclusions = [${profile.exclusions.map(_tomlStr).join(', ')}]',
    );
    // DNS route rules (domain:, cidr:, geoip: prefixes supported)
    final allRoutes = [...profile.dnsRouteRules, ...extraRoutes];
    buf.writeln(
      'dns_route_rules = [${allRoutes.map(_tomlStr).join(', ')}]',
    );
    buf.writeln();

    // [endpoint]
    buf.writeln('[endpoint]');
    buf.writeln('hostname = "${_escape(profile.hostname)}"');
    buf.writeln('addresses = [${profile.addresses.map(_tomlStr).join(', ')}]');
    buf.writeln('has_ipv6 = ${profile.hasIpv6}');
    buf.writeln('username = "${_escape(profile.username)}"');
    buf.writeln('password = "${_escape(profile.password)}"');
    buf.writeln('client_random = "${_escape(profile.clientRandom)}"');
    buf.writeln('skip_verification = ${profile.skipVerification}');

    // Certificate: DATA:<base64-DER> is stored without prefix; PEM is omitted.
    if (profile.certificate.startsWith('DATA:')) {
      buf.writeln('certificate = "${profile.certificate.substring(5)}"');
    } else {
      buf.writeln('certificate = "${_escape(profile.certificate)}"');
    }

    buf.writeln(
      'dns_upstreams = [${profile.dnsUpstreams.map(_tomlStr).join(', ')}]',
    );
    buf.writeln('upstream_protocol = "${profile.upstreamProtocol}"');
    buf.writeln('anti_dpi = ${profile.antiDpi}');
    buf.writeln();

    // [listener.*]
    if (profile.listenerType == ListenerType.tun) {
      buf.writeln('[listener.tun]');
    } else {
      buf.writeln('[listener.socks]');
      buf.writeln('address = "${_escape(profile.socks5Address)}"');
      if (profile.socks5Username.isNotEmpty) {
        buf.writeln('username = "${_escape(profile.socks5Username)}"');
        buf.writeln('password = "${_escape(profile.socks5Password)}"');
      }
    }

    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Parsing (TOML string → profile)
  // ---------------------------------------------------------------------------

  /// Parses a TOML configuration file into a [TrustTunnelProfile].
  /// Returns `null` if parsing fails or required fields are absent.
  static TrustTunnelProfile? parseToml(String tomlStr, String newId) {
    try {
      final topLevel = <String, String>{};
      final endpoint = <String, String>{};
      final listenerSocks = <String, String>{};

      String section = '';

      for (var line in tomlStr.split('\n')) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;

        // Section header: [section] or [section.sub]
        final sectionMatch = RegExp(r'^\[([^\]]+)\]$').firstMatch(line);
        if (sectionMatch != null) {
          section = sectionMatch.group(1)!.trim();
          continue;
        }

        // Key = value
        final kvMatch = RegExp(r'^(\w+)\s*=\s*(.+)$').firstMatch(line);
        if (kvMatch == null) continue;

        final key = kvMatch.group(1)!;
        final raw = kvMatch.group(2)!.trim();

        final target = switch (section) {
          '' => topLevel,
          'endpoint' => endpoint,
          'listener.socks' => listenerSocks,
          _ => null,
        };
        target?[key] = raw;
      }

      // -----------------------------------------------------------------------
      // Helpers
      // -----------------------------------------------------------------------

      String parseStr(String? raw, String fallback) {
        if (raw == null) return fallback;
        final m = RegExp(r'^"(.*)"$', dotAll: true).firstMatch(raw);
        if (m != null) {
          // Unescape basic TOML escape sequences.
          return m
              .group(1)!
              .replaceAll(r'\"', '"')
              .replaceAll(r'\\', r'\')
              .replaceAll(r'\n', '\n')
              .replaceAll(r'\t', '\t');
        }
        return raw;
      }

      bool parseBool(String? raw, bool fallback) {
        if (raw == null) return fallback;
        return raw.trim() == 'true';
      }

      List<String> parseStrArray(String? raw) {
        if (raw == null) return [];
        final trimmed = raw.trim();
        if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) return [];
        final inner = trimmed.substring(1, trimmed.length - 1).trim();
        if (inner.isEmpty) return [];
        return RegExp(
          r'"([^"]*)"',
        ).allMatches(inner).map((m) => m.group(1)!).toList();
      }

      List<int> parseIntArray(String? raw) {
        if (raw == null) return [];
        final trimmed = raw.trim();
        if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) return [];
        final inner = trimmed.substring(1, trimmed.length - 1).trim();
        if (inner.isEmpty) return [];
        return inner
            .split(',')
            .map((s) => int.tryParse(s.trim()))
            .whereType<int>()
            .toList();
      }

      // -----------------------------------------------------------------------
      // Build profile
      // -----------------------------------------------------------------------

      final hostname = parseStr(endpoint['hostname'], '');
      if (hostname.isEmpty) return null;

      // Listener type: presence of [listener.socks] section determines it.
      final hasSocks = tomlStr.contains('[listener.socks]');
      final listenerType = hasSocks ? ListenerType.socks5 : ListenerType.tun;

      return TrustTunnelProfile(
        id: newId,
        name: hostname,
        hostname: hostname,
        addresses: parseStrArray(endpoint['addresses']),
        username: parseStr(endpoint['username'], ''),
        password: parseStr(endpoint['password'], ''),
        hasIpv6: parseBool(endpoint['has_ipv6'], true),
        skipVerification: parseBool(endpoint['skip_verification'], false),
        certificate: parseStr(endpoint['certificate'], ''),
        upstreamProtocol: parseStr(endpoint['upstream_protocol'], 'http2'),
        antiDpi: parseBool(endpoint['anti_dpi'], false),
        clientRandom: parseStr(endpoint['client_random'], ''),
        dnsUpstreams: parseStrArray(endpoint['dns_upstreams']),
        vpnMode: parseStr(topLevel['vpn_mode'], 'general'),
        killswitchEnabled: parseBool(topLevel['killswitch_enabled'], false),
        killswitchAllowPorts: parseIntArray(topLevel['killswitch_allow_ports']),
        postQuantumEnabled: parseBool(
          topLevel['post_quantum_group_enabled'],
          true,
        ),
        exclusions: parseStrArray(topLevel['exclusions']),
        dnsRouteRules: parseStrArray(topLevel['dns_route_rules']),
        listenerType: listenerType,
        socks5Address: parseStr(listenerSocks['address'], '127.0.0.1:1080'),
        socks5Username: parseStr(listenerSocks['username'], ''),
        socks5Password: parseStr(listenerSocks['password'], ''),
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Wraps [value] in TOML double quotes.
  static String _tomlStr(String value) => '"${_escape(value)}"';

  /// Escapes backslashes and double quotes for TOML strings.
  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}
