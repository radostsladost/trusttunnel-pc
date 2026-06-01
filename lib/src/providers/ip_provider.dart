import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/profile.dart';
import '../providers/profiles_provider.dart';
import '../services/ip_service.dart';
import 'connection_provider.dart';

final publicIpProvider =
    StateNotifierProvider<IpNotifier, String>((ref) => IpNotifier(ref));

class IpNotifier extends StateNotifier<String> {
  IpNotifier(this._ref) : super('—') {
    // Refresh whenever VPN connects or disconnects.
    _ref.listen<ConnectionStatus>(connectionStatusProvider, (prev, next) {
      if (prev != next &&
          (next == ConnectionStatus.connected ||
              next == ConnectionStatus.disconnected)) {
        refresh();
      }
    });
    refresh();
  }

  final Ref _ref;

  Future<void> refresh() async {
    state = '…';

    // When connected in SOCKS5 mode, route the IP check through the proxy so
    // the displayed address reflects the VPN exit node, not the local machine.
    // In TUN mode the OS already routes all traffic through the tunnel, so a
    // direct request exits via the VPN without any extra configuration.
    String? proxy;
    String? user;
    String? pass;

    final status = _ref.read(connectionStatusProvider);
    final profile = _ref.read(selectedProfileProvider);

    if (status == ConnectionStatus.connected &&
        profile?.listenerType == ListenerType.socks5) {
      proxy = profile!.socks5Address;
      user = profile.socks5Username.isEmpty ? null : profile.socks5Username;
      pass = profile.socks5Password.isEmpty ? null : profile.socks5Password;
    }

    state = await IpService.fetchPublicIp(
      socks5Proxy: proxy,
      socks5Username: user,
      socks5Password: pass,
    );
  }
}
