import 'dart:convert';

/// Represents a TrustTunnel connection profile.
class TrustTunnelProfile {
  final String id;
  final String name;

  // Endpoint settings
  final String hostname;
  final List<String> addresses;
  final String username;
  final String password;
  final bool hasIpv6;
  final bool skipVerification;
  final String certificate; // PEM string, empty = system CA
  final String upstreamProtocol; // http2 or http3
  final bool antiDpi;
  final String clientRandom; // hex prefix[/mask]
  final List<String> dnsUpstreams;

  // Top-level client settings
  final String vpnMode; // general | selective
  final bool killswitchEnabled;
  final List<int> killswitchAllowPorts;
  final bool postQuantumEnabled;
  final List<String> exclusions;
  final List<String> dnsRouteRules;

  // Listener
  final ListenerType listenerType;
  final String socks5Address;
  final String socks5Username;
  final String socks5Password;

  const TrustTunnelProfile({
    required this.id,
    required this.name,
    required this.hostname,
    required this.addresses,
    required this.username,
    required this.password,
    this.hasIpv6 = true,
    this.skipVerification = false,
    this.certificate = '',
    this.upstreamProtocol = 'http2',
    this.antiDpi = false,
    this.clientRandom = '',
    this.dnsUpstreams = const [],
    this.vpnMode = 'general',
    this.killswitchEnabled = true,
    this.killswitchAllowPorts = const [],
    this.postQuantumEnabled = true,
    this.exclusions = const [],
    this.dnsRouteRules = const [],
    this.listenerType = ListenerType.tun,
    this.socks5Address = '127.0.0.1:1080',
    this.socks5Username = '',
    this.socks5Password = '',
  });

  TrustTunnelProfile copyWith({
    String? id,
    String? name,
    String? hostname,
    List<String>? addresses,
    String? username,
    String? password,
    bool? hasIpv6,
    bool? skipVerification,
    String? certificate,
    String? upstreamProtocol,
    bool? antiDpi,
    String? clientRandom,
    List<String>? dnsUpstreams,
    String? vpnMode,
    bool? killswitchEnabled,
    List<int>? killswitchAllowPorts,
    bool? postQuantumEnabled,
    List<String>? exclusions,
    List<String>? dnsRouteRules,
    ListenerType? listenerType,
    String? socks5Address,
    String? socks5Username,
    String? socks5Password,
  }) {
    return TrustTunnelProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      addresses: addresses ?? this.addresses,
      username: username ?? this.username,
      password: password ?? this.password,
      hasIpv6: hasIpv6 ?? this.hasIpv6,
      skipVerification: skipVerification ?? this.skipVerification,
      certificate: certificate ?? this.certificate,
      upstreamProtocol: upstreamProtocol ?? this.upstreamProtocol,
      antiDpi: antiDpi ?? this.antiDpi,
      clientRandom: clientRandom ?? this.clientRandom,
      dnsUpstreams: dnsUpstreams ?? this.dnsUpstreams,
      vpnMode: vpnMode ?? this.vpnMode,
      killswitchEnabled: killswitchEnabled ?? this.killswitchEnabled,
      killswitchAllowPorts: killswitchAllowPorts ?? this.killswitchAllowPorts,
      postQuantumEnabled: postQuantumEnabled ?? this.postQuantumEnabled,
      exclusions: exclusions ?? this.exclusions,
      dnsRouteRules: dnsRouteRules ?? this.dnsRouteRules,
      listenerType: listenerType ?? this.listenerType,
      socks5Address: socks5Address ?? this.socks5Address,
      socks5Username: socks5Username ?? this.socks5Username,
      socks5Password: socks5Password ?? this.socks5Password,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostname': hostname,
        'addresses': addresses,
        'username': username,
        'password': password,
        'hasIpv6': hasIpv6,
        'skipVerification': skipVerification,
        'certificate': certificate,
        'upstreamProtocol': upstreamProtocol,
        'antiDpi': antiDpi,
        'clientRandom': clientRandom,
        'dnsUpstreams': dnsUpstreams,
        'vpnMode': vpnMode,
        'killswitchEnabled': killswitchEnabled,
        'killswitchAllowPorts': killswitchAllowPorts,
        'postQuantumEnabled': postQuantumEnabled,
        'exclusions': exclusions,
        'dnsRouteRules': dnsRouteRules,
        'listenerType': listenerType.name,
        'socks5Address': socks5Address,
        'socks5Username': socks5Username,
        'socks5Password': socks5Password,
      };

  factory TrustTunnelProfile.fromJson(Map<String, dynamic> json) {
    return TrustTunnelProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      hostname: json['hostname'] as String,
      addresses: List<String>.from(json['addresses'] as List),
      username: json['username'] as String,
      password: json['password'] as String,
      hasIpv6: json['hasIpv6'] as bool? ?? true,
      skipVerification: json['skipVerification'] as bool? ?? false,
      certificate: json['certificate'] as String? ?? '',
      upstreamProtocol: json['upstreamProtocol'] as String? ?? 'http2',
      antiDpi: json['antiDpi'] as bool? ?? false,
      clientRandom: json['clientRandom'] as String? ?? '',
      dnsUpstreams: List<String>.from(json['dnsUpstreams'] as List? ?? []),
      vpnMode: json['vpnMode'] as String? ?? 'general',
      killswitchEnabled: json['killswitchEnabled'] as bool? ?? true,
      killswitchAllowPorts: List<int>.from(
        json['killswitchAllowPorts'] as List? ?? [],
      ),
      postQuantumEnabled: json['postQuantumEnabled'] as bool? ?? true,
      exclusions: List<String>.from(json['exclusions'] as List? ?? []),
      dnsRouteRules: List<String>.from(json['dnsRouteRules'] as List? ?? []),
      listenerType: ListenerType.values.firstWhere(
        (e) => e.name == (json['listenerType'] as String? ?? 'tun'),
        orElse: () => ListenerType.tun,
      ),
      socks5Address: json['socks5Address'] as String? ?? '127.0.0.1:1080',
      socks5Username: json['socks5Username'] as String? ?? '',
      socks5Password: json['socks5Password'] as String? ?? '',
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory TrustTunnelProfile.fromJsonString(String s) =>
      TrustTunnelProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);

  @override
  bool operator ==(Object other) =>
      other is TrustTunnelProfile && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TrustTunnelProfile($name @ $hostname)';
}

enum ListenerType {
  tun,
  socks5;

  String get label {
    switch (this) {
      case ListenerType.tun:
        return 'TUN (System VPN)';
      case ListenerType.socks5:
        return 'SOCKS5 / HTTP Proxy';
    }
  }

  String get icon {
    switch (this) {
      case ListenerType.tun:
        return '🔒';
      case ListenerType.socks5:
        return '🔀';
    }
  }
}

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error;

  bool get isActive => this == connecting || this == connected;
}
