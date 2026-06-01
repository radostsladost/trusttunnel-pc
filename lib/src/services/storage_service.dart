import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';
import '../models/proxy_config.dart';

/// Persists and loads app data using shared_preferences.
/// All methods are static for convenience.
class StorageService {
  static const String _profilesKey = 'tt_profiles';
  static const String _selectedIdKey = 'tt_selected_id';
  static const String _clientPathKey = 'tt_client_path';

  // ---------------------------------------------------------------------------
  // Profiles
  // ---------------------------------------------------------------------------

  static Future<List<TrustTunnelProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list
          .map((e) => TrustTunnelProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveProfiles(List<TrustTunnelProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode(profiles.map((p) => p.toJson()).toList());
    await prefs.setString(_profilesKey, encoded);
  }

  // ---------------------------------------------------------------------------
  // Selected profile ID
  // ---------------------------------------------------------------------------

  static Future<String?> loadSelectedProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedIdKey);
  }

  static Future<void> saveSelectedProfileId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_selectedIdKey);
    } else {
      await prefs.setString(_selectedIdKey, id);
    }
  }

  // ---------------------------------------------------------------------------
  // Client binary path
  // ---------------------------------------------------------------------------

  static Future<String?> loadBinaryPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_clientPathKey);
  }

  static Future<void> saveBinaryPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clientPathKey, path);
  }

  // ---------------------------------------------------------------------------
  // Proxy config
  // ---------------------------------------------------------------------------

  static const String _proxyKey = 'tt_proxy_config';

  static Future<ProxyConfig> loadProxyConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_proxyKey);
    if (raw == null || raw.isEmpty) return ProxyConfig.disabled;
    try {
      return ProxyConfig.fromJsonString(raw);
    } catch (_) {
      return ProxyConfig.disabled;
    }
  }

  static Future<void> saveProxyConfig(ProxyConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_proxyKey, config.toJsonString());
  }

  // ---------------------------------------------------------------------------
  // Autostart
  // ---------------------------------------------------------------------------

  static const String _autostartKey = 'tt_autostart';

  static Future<bool> loadAutostart() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autostartKey) ?? false;
  }

  static Future<void> saveAutostart(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autostartKey, value);
  }

  // ---------------------------------------------------------------------------
  // Auto-connect on launch
  // ---------------------------------------------------------------------------

  static const String _autoConnectKey = 'tt_auto_connect';

  static Future<bool> loadAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoConnectKey) ?? false;
  }

  static Future<void> saveAutoConnect(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoConnectKey, value);
  }

  // ---------------------------------------------------------------------------
  // Global DNS routes file
  // ---------------------------------------------------------------------------

  static const String _globalRoutesFileKey = 'tt_global_routes_file';

  static Future<String?> loadGlobalRoutesFile() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_globalRoutesFileKey);
  }

  static Future<void> saveGlobalRoutesFile(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove(_globalRoutesFileKey);
    } else {
      await prefs.setString(_globalRoutesFileKey, path);
    }
  }
}
