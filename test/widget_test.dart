import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trustunnel_pc/src/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: TrustTunnelApp(),
      ),
    );
    // Splash screen should appear during initialization
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
