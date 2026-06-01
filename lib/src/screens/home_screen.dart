import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../models/profile.dart';
import '../providers/profiles_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/installer_provider.dart';
import '../services/process_service.dart';
import '../widgets/connection_button.dart';
import '../widgets/status_badge.dart';
import '../widgets/neon_card.dart';
import '../widgets/log_viewer.dart';
import '../providers/ip_provider.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionStatusProvider);
    final selectedProfile = ref.watch(selectedProfileProvider);
    final isSocks = selectedProfile?.listenerType == ListenerType.socks5 &&
        status == ConnectionStatus.connected;
    final currentIp = ref.watch(publicIpProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ────────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'VPN Dashboard',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                StatusBadge(status: status),
              ],
            ),

            const SizedBox(height: 28),

            // ── Connection button ──────────────────────────────────────────
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConnectionButton(
                    status: status,
                    onConnect: () => _handleConnect(context, ref),
                    onDisconnect: () => ref
                        .read(connectionStatusProvider.notifier)
                        .disconnect(),
                  ),
                  const SizedBox(height: 16),
                  if (status == ConnectionStatus.connected &&
                      selectedProfile != null)
                    Text(
                      selectedProfile.name,
                      style: const TextStyle(
                        color: AppTheme.secondary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── Public IP card ─────────────────────────────────────────────
            NeonCard(
              glowColor: AppTheme.secondary,
              child: Row(
                children: [
                  const Icon(Icons.language_rounded,
                      color: AppTheme.secondary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PUBLIC IP',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          currentIp,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        ref.read(publicIpProvider.notifier).refresh(),
                    icon: const Icon(Icons.refresh_rounded,
                        color: AppTheme.textSecondary, size: 20),
                    tooltip: 'Refresh IP',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── Active Profile card ────────────────────────────────────────
            NeonCard(
              glowColor: AppTheme.primary,
              glowing: status == ConnectionStatus.connected,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text(
                        'ACTIVE PROFILE',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary,
                          letterSpacing: 1.2,
                        ),
                      ),
                      Icon(Icons.person_rounded,
                          color: AppTheme.textSecondary, size: 18),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (selectedProfile != null) ...[
                    Text(
                      selectedProfile.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      selectedProfile.hostname,
                      style: const TextStyle(
                          fontSize: 14, color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _Chip(
                          label: selectedProfile.listenerType.label,
                          color: AppTheme.secondary,
                        ),
                        _Chip(
                          label: selectedProfile.vpnMode == 'general'
                              ? 'General VPN'
                              : 'Selective VPN',
                          color: AppTheme.primary,
                        ),
                        _Chip(
                          label: selectedProfile.killswitchEnabled
                              ? 'Kill Switch ON'
                              : 'Kill Switch OFF',
                          color: selectedProfile.killswitchEnabled
                              ? AppTheme.success
                              : AppTheme.textSecondary,
                        ),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    const Center(
                      child: Column(
                        children: [
                          Text('No profile selected',
                              style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500)),
                          SizedBox(height: 4),
                          Text('Go to Profiles to add one',
                              style: TextStyle(
                                  color: AppTheme.textSecondary, fontSize: 13)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── SOCKS5 usage card (shown while connected in SOCKS5 mode) ──
            if (isSocks) ...[
              _Socks5UsageCard(
                address: selectedProfile!.socks5Address,
              ),
              const SizedBox(height: 24),
            ],

            // ── Log section ────────────────────────────────────────────────
            NeonCard(
              padding: EdgeInsets.zero,
              child: Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  title: const Text(
                    'Connection Logs',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                  ),
                  iconColor: AppTheme.textSecondary,
                  collapsedIconColor: AppTheme.textSecondary,
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    SizedBox(
                      height: 200,
                      child: LogViewer(
                          logStream: ProcessService.instance.logStream),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _handleConnect(BuildContext context, WidgetRef ref) async {
    final profile = ref.read(selectedProfileProvider);
    if (profile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select a profile first')));
      return;
    }
    final installState = ref.read(installerProvider);
    final binaryPath = ref.read(clientBinaryPathProvider);
    if (!installState.isInstalled) {
      _showInstallDialog(context, ref);
      return;
    }
    try {
      await ref
          .read(connectionStatusProvider.notifier)
          .connect(profile, binaryPath, ref);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Connection failed: $e'),
          backgroundColor: AppTheme.error));
    }
  }

  void _showInstallDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.border)),
        title: const Text('Client Not Found',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
            'TrustTunnel client binary not found. Install it now?',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: AppTheme.textSecondary))),
          TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                ref.read(installerProvider.notifier).install();
              },
              child: const Text('Install',
                  style: TextStyle(color: AppTheme.primary))),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SOCKS5 usage card
// ─────────────────────────────────────────────────────────────────────────────

class _Socks5UsageCard extends StatelessWidget {
  const _Socks5UsageCard({required this.address});

  final String address; // e.g. "127.0.0.1:1080"

  String get _socks5hUrl => 'socks5h://$address';
  String get _chromiumFlag => '--proxy-server="socks5h://$address"';
  String get _curlFlag => '--socks5-hostname $address';

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      glowColor: AppTheme.secondary,
      glowing: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: const [
              Icon(Icons.swap_horiz_rounded,
                  color: AppTheme.secondary, size: 18),
              SizedBox(width: 8),
              Text(
                'SOCKS5 PROXY ACTIVE',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondary,
                    letterSpacing: 1.2),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Key warning ──────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppTheme.warning.withValues(alpha: 0.35), width: 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Icon(Icons.info_outline_rounded,
                    color: AppTheme.warning, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Use socks5h:// — NOT socks5://\n'
                    'The "h" suffix tells the browser to send hostnames to the proxy for DNS resolution. '
                    'Without it, your browser resolves DNS locally (which may be censored) before connecting through the proxy.',
                    style: TextStyle(
                        color: AppTheme.warning, fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Proxy URL ────────────────────────────────────────────────────
          _CopyRow(
            icon: Icons.link_rounded,
            label: 'Proxy URL',
            value: _socks5hUrl,
            context: context,
          ),

          const SizedBox(height: 8),

          // ── Browser instructions ─────────────────────────────────────────
          const Text(
            'BROWSER SETUP',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
                letterSpacing: 1.1),
          ),
          const SizedBox(height: 8),

          _BrowserRow(
            browser: 'Chrome / Chromium / Edge / Brave',
            icon: Icons.language_rounded,
            instruction: _chromiumFlag,
            detail: 'Add this flag when launching the browser:',
            context: context,
          ),

          const SizedBox(height: 8),

          _BrowserRow(
            browser: 'Firefox',
            icon: Icons.public_rounded,
            instruction: 'Settings → Network → Manual proxy → SOCKS Host: '
                '${address.split(':').first}  Port: ${address.split(':').length > 1 ? address.split(':')[1] : "1080"}'
                '\nAlso enable: ☑ Proxy DNS when using SOCKS v5',
            detail: null,
            context: context,
          ),

          const SizedBox(height: 8),

          _CopyRow(
            icon: Icons.terminal_rounded,
            label: 'curl flag',
            value: _curlFlag,
            context: context,
          ),
        ],
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.context,
  });

  final IconData icon;
  final String label;
  final String value;
  final BuildContext context;

  @override
  Widget build(BuildContext ctx) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 10)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        color: AppTheme.secondary,
                        fontSize: 12,
                        fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _CopyButton(value: value, context: context),
        ],
      ),
    );
  }
}

class _BrowserRow extends StatelessWidget {
  const _BrowserRow({
    required this.browser,
    required this.icon,
    required this.instruction,
    required this.detail,
    required this.context,
  });

  final String browser;
  final IconData icon;
  final String instruction;
  final String? detail;
  final BuildContext context;

  @override
  Widget build(BuildContext ctx) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(browser,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(detail!,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  instruction,
                  style: const TextStyle(
                      color: AppTheme.secondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.5),
                ),
              ),
              _CopyButton(value: instruction, context: context),
            ],
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.value, required this.context});
  final String value;
  final BuildContext context;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  void _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _copied
          ? const Icon(Icons.check_rounded, size: 16, color: AppTheme.success)
          : IconButton(
              key: const ValueKey('copy'),
              onPressed: _copy,
              icon: const Icon(Icons.copy_rounded,
                  size: 14, color: AppTheme.textSecondary),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Copy',
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small chip badge
// ─────────────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.40)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w500)),
    );
  }
}
