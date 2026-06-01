import 'dart:convert';

/// Proxy type for outbound HTTP traffic from the app itself (e.g. installer).
enum ProxyType { http, socks5 }

/// Configuration for the app's outbound proxy.
class ProxyConfig {
  final bool enabled;
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  const ProxyConfig({
    this.enabled = false,
    this.type = ProxyType.socks5,
    this.host = '127.0.0.1',
    this.port = 1080,
    this.username = '',
    this.password = '',
  });

  static const ProxyConfig disabled = ProxyConfig(enabled: false);

  ProxyConfig copyWith({
    bool? enabled,
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
  }) =>
      ProxyConfig(
        enabled: enabled ?? this.enabled,
        type: type ?? this.type,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) => ProxyConfig(
        enabled: json['enabled'] as bool? ?? false,
        type: ProxyType.values.firstWhere(
          (e) => e.name == (json['type'] as String? ?? 'socks5'),
          orElse: () => ProxyType.socks5,
        ),
        host: json['host'] as String? ?? '127.0.0.1',
        port: json['port'] as int? ?? 1080,
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
      );

  String toJsonString() => jsonEncode(toJson());

  factory ProxyConfig.fromJsonString(String s) =>
      ProxyConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);

  @override
  String toString() =>
      enabled ? '${type.name.toUpperCase()} $host:$port' : 'No proxy';
}
