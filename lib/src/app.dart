import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'theme/app_theme.dart';
import 'providers/app_providers.dart';
import 'providers/connection_provider.dart';
import 'providers/ip_provider.dart';
import 'services/tray_service.dart';
import 'screens/home_screen.dart';
import 'screens/profiles_screen.dart';
import 'screens/settings_screen.dart';

import 'widgets/status_badge.dart';

// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

class TrustTunnelApp extends ConsumerStatefulWidget {
  const TrustTunnelApp({super.key});

  @override
  ConsumerState<TrustTunnelApp> createState() => _TrustTunnelAppState();
}

class _TrustTunnelAppState extends ConsumerState<TrustTunnelApp> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeProviders(ref);
      setState(() => _initialized = true);
      // Initialize system tray after all providers are ready.
      await TrayService.instance.initialize(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TrustTunnel',
      theme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      home: _initialized ? const MainShell() : const SplashScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Splash screen
// ---------------------------------------------------------------------------

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/icons/app_icon.png',
              width: 88,
              height: 88,
            ),
            const SizedBox(height: 20),
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [AppTheme.primary, AppTheme.secondary],
              ).createShader(bounds),
              child: const Text(
                'TrustTunnel',
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Desktop Client',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Initializing...',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Main shell — sidebar + content area
// ---------------------------------------------------------------------------

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> with WindowListener {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Intercept close so we can stop the VPN before the app exits.
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// Called when the user (or OS) requests the window to close.
  @override
  Future<void> onWindowClose() async {
    // If exit was requested from the tray menu, the tray service handles
    // cleanup — just return here to avoid a recursive close.
    if (TrayService.instance.exitRequested) return;
    // Otherwise hide the window to the system tray instead of exiting.
    await windowManager.hide();
  }

  static const _navItems = [
    (icon: Icons.dashboard_rounded, label: 'Dashboard'),
    (icon: Icons.shield_rounded, label: 'Profiles'),
    (icon: Icons.settings_rounded, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final connectionStatus = ref.watch(connectionStatusProvider);

    // Keep tray icon/menu in sync with app state.
    ref.listen(connectionStatusProvider, (_, __) {
      TrayService.instance.update(ref);
    });
    ref.listen(publicIpProvider, (_, __) {
      TrayService.instance.update(ref);
    });

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Row(
        children: [
          // ── Sidebar ──────────────────────────────────────────────────────
          SizedBox(
            width: 220,
            child: ColoredBox(
              color: AppTheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Logo
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Image.asset(
                              'assets/icons/app_icon.png',
                              width: 28,
                              height: 28,
                            ),
                            const SizedBox(width: 10),
                            ShaderMask(
                              shaderCallback: (bounds) => const LinearGradient(
                                colors: [AppTheme.primary, AppTheme.secondary],
                              ).createShader(bounds),
                              child: const Text(
                                'TrustTunnel',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Desktop Client',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                  const Divider(color: AppTheme.border, height: 1),
                  const SizedBox(height: 8),

                  // Nav items
                  for (var i = 0; i < _navItems.length; i++)
                    _NavItem(
                      icon: _navItems[i].icon,
                      label: _navItems[i].label,
                      selected: _selectedIndex == i,
                      onTap: () => setState(() => _selectedIndex = i),
                    ),

                  const Spacer(),

                  // Status badge
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: StatusBadge(status: connectionStatus),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ── Content ───────────────────────────────────────────────────────
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: const [
                HomeScreen(),
                ProfilesScreen(),
                SettingsScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sidebar nav item
// ---------------------------------------------------------------------------

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.primary : AppTheme.textSecondary;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppTheme.primary.withValues(alpha: 0.06),
        splashColor: AppTheme.primary.withValues(alpha: 0.10),
        highlightColor: AppTheme.primary.withValues(alpha: 0.05),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            border: selected
                ? const Border(
                    left: BorderSide(color: AppTheme.primary, width: 3),
                  )
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
