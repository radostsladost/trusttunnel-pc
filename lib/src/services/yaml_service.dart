import 'package:yaml/yaml.dart';

import '../models/profile.dart';

/// Serializes and deserializes [TrustTunnelProfile] to/from a human-readable
/// YAML format.
///
/// YAML layout:
/// ```yaml
/// # TrustTunnel Profile
/// name: "My Server"
/// endpoint:
///   hostname: "vpn.example.com"
///   addresses:
///     - "1.2.3.4:443"
///   username: "user"
///   password: "pass"
///   has_ipv6: true
///   skip_verification: false
///   certificate: ""
///   upstream_protocol: "http2"
///   anti_dpi: false
///   client_random: ""
///   dns_upstreams:
///     - "tls://1.1.1.1"
/// client:
///   vpn_mode: "general"
///   killswitch_enabled: true
///   killswitch_allow_ports: []
///   post_quantum_enabled: true
///   exclusions: []
/// listener:
///   type: "tun"
///   socks5_address: "127.0.0.1:1080"
///   socks5_username: ""
///   socks5_password: ""
/// ```
class YamlService {
  // ---------------------------------------------------------------------------
  // Serialization (profile → YAML string)
  // ---------------------------------------------------------------------------

  static String profileToYaml(TrustTunnelProfile profile) {
    final buf = StringBuffer();

    buf.writeln('# TrustTunnel Profile');
    buf.writeln('name: ${_q(profile.name)}');
    buf.writeln();

    buf.writeln('endpoint:');
    buf.writeln('  hostname: ${_q(profile.hostname)}');
    buf.writeln('  addresses:');
    if (profile.addresses.isEmpty) {
      buf.writeln('    []');
    } else {
      for (final a in profile.addresses) {
        buf.writeln('    - ${_q(a)}');
      }
    }
    buf.writeln('  username: ${_q(profile.username)}');
    buf.writeln('  password: ${_q(profile.password)}');
    buf.writeln('  has_ipv6: ${profile.hasIpv6}');
    buf.writeln('  skip_verification: ${profile.skipVerification}');
    buf.writeln('  certificate: ${_q(profile.certificate)}');
    buf.writeln('  upstream_protocol: ${_q(profile.upstreamProtocol)}');
    buf.writeln('  anti_dpi: ${profile.antiDpi}');
    buf.writeln('  client_random: ${_q(profile.clientRandom)}');
    buf.writeln('  dns_upstreams:');
    if (profile.dnsUpstreams.isEmpty) {
      buf.writeln('    []');
    } else {
      for (final d in profile.dnsUpstreams) {
        buf.writeln('    - ${_q(d)}');
      }
    }
    buf.writeln();

    buf.writeln('client:');
    buf.writeln('  vpn_mode: ${_q(profile.vpnMode)}');
    buf.writeln('  killswitch_enabled: ${profile.killswitchEnabled}');
    buf.writeln('  killswitch_allow_ports:');
    if (profile.killswitchAllowPorts.isEmpty) {
      buf.writeln('    []');
    } else {
      for (final p in profile.killswitchAllowPorts) {
        buf.writeln('    - $p');
      }
    }
    buf.writeln('  post_quantum_enabled: ${profile.postQuantumEnabled}');
    buf.writeln('  exclusions:');
    if (profile.exclusions.isEmpty) {
      buf.writeln('    []');
    } else {
      for (final e in profile.exclusions) {
        buf.writeln('    - ${_q(e)}');
      }
    }
    buf.writeln('  dns_route_rules:');
    if (profile.dnsRouteRules.isEmpty) {
      buf.writeln('    []');
    } else {
      for (final r in profile.dnsRouteRules) {
        buf.writeln('    - ${_q(r)}');
      }
    }
    buf.writeln();

    buf.writeln('listener:');
    buf.writeln(
      '  type: ${_q(profile.listenerType == ListenerType.socks5 ? "socks5" : "tun")}',
    );
    buf.writeln('  socks5_address: ${_q(profile.socks5Address)}');
    buf.writeln('  socks5_username: ${_q(profile.socks5Username)}');
    buf.writeln('  socks5_password: ${_q(profile.socks5Password)}');

    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Deserialization (YAML string → profile)
  // ---------------------------------------------------------------------------

  static TrustTunnelProfile profileFromYaml(String yamlStr, String newId) {
    final doc = loadYaml(yamlStr) as YamlMap;

    final endpoint = doc['endpoint'] as YamlMap?;
    final client = doc['client'] as YamlMap?;
    final listener = doc['listener'] as YamlMap?;

    final listenerTypeStr = _str(listener?['type'], 'tun');
    final listenerType =
        listenerTypeStr == 'socks5' ? ListenerType.socks5 : ListenerType.tun;

    return TrustTunnelProfile(
      id: newId,
      name: _str(doc['name'], ''),
      hostname: _str(endpoint?['hostname'], ''),
      addresses: _strList(endpoint?['addresses']),
      username: _str(endpoint?['username'], ''),
      password: _str(endpoint?['password'], ''),
      hasIpv6: _bool(endpoint?['has_ipv6'], true),
      skipVerification: _bool(endpoint?['skip_verification'], false),
      certificate: _str(endpoint?['certificate'], ''),
      upstreamProtocol: _str(endpoint?['upstream_protocol'], 'http2'),
      antiDpi: _bool(endpoint?['anti_dpi'], false),
      clientRandom: _str(endpoint?['client_random'], ''),
      dnsUpstreams: _strList(endpoint?['dns_upstreams']),
      vpnMode: _str(client?['vpn_mode'], 'general'),
      killswitchEnabled: _bool(client?['killswitch_enabled'], true),
      killswitchAllowPorts: _intList(client?['killswitch_allow_ports']),
      postQuantumEnabled: _bool(client?['post_quantum_enabled'], true),
      exclusions: _strList(client?['exclusions']),
      dnsRouteRules: _strList(client?['dns_route_rules']),
      listenerType: listenerType,
      socks5Address: _str(listener?['socks5_address'], '127.0.0.1:1080'),
      socks5Username: _str(listener?['socks5_username'], ''),
      socks5Password: _str(listener?['socks5_password'], ''),
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Wraps [value] in double quotes, escaping backslashes and quotes.
  static String _q(String value) {
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static String _str(dynamic value, String fallback) =>
      value == null ? fallback : value.toString();

  static bool _bool(dynamic value, bool fallback) {
    if (value == null) return fallback;
    if (value is bool) return value;
    return value.toString().toLowerCase() == 'true';
  }

  static List<String> _strList(dynamic value) {
    if (value == null) return [];
    if (value is YamlList) return value.map((e) => e.toString()).toList();
    if (value is List) return value.map((e) => e.toString()).toList();
    return [];
  }

  static List<int> _intList(dynamic value) {
    if (value == null) return [];
    Iterable<dynamic> items;
    if (value is YamlList) {
      items = value;
    } else if (value is List) {
      items = value;
    } else {
      return [];
    }
    return items
        .map((e) => int.tryParse(e.toString()))
        .whereType<int>()
        .toList();
  }
}
