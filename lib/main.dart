import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/providers/app_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1100, 720),
    minimumSize: Size(860, 600),
    center: true,
    backgroundColor: Color(0xFF080810),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
    title: 'TrustTunnel',
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    ProviderScope(
      observers: const [AppProviderObserver()],
      child: const TrustTunnelApp(),
    ),
  );
}
