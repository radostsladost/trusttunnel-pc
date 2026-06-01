import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme/app_theme.dart';
import '../models/profile.dart';
import '../providers/profiles_provider.dart';
import '../providers/connection_provider.dart';
import '../services/deeplink_service.dart';
import '../services/yaml_service.dart';
import '../widgets/profile_card.dart';
import '../widgets/gradient_button.dart';

import 'add_profile_screen.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Profiles',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                GradientButton(
                  label: 'Add Profile',
                  icon: Icons.add_rounded,
                  onPressed: () => _navigateToAdd(context, ref),
                  height: 40,
                  width: 160,
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Profile list ─────────────────────────────────────────────────
            Expanded(
              child: profiles.isEmpty
                  ? _EmptyState(onAdd: () => _navigateToAdd(context, ref))
                  : ListView.separated(
                      itemCount: profiles.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final profile = profiles[index];
                        return ProfileCard(
                          profile: profile,
                          isSelected: ref.watch(selectedProfileIdProvider) ==
                              profile.id,
                          isConnected: ref.watch(connectedProfileIdProvider) ==
                              profile.id,
                          onTap: () => ref
                              .read(selectedProfileIdProvider.notifier)
                              .select(profile.id),
                          onEdit: () => _navigateToAdd(context, ref, profile),
                          onDelete: () => _confirmDelete(context, ref, profile),
                          onExport: () => _showExportDialog(context, profile),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _navigateToAdd(
    BuildContext context,
    WidgetRef ref, [
    TrustTunnelProfile? editProfile,
  ]) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddProfileScreen(existingProfile: editProfile),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    TrustTunnelProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(
          'Delete Profile',
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Delete "${profile.name}"? This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(profilesProvider.notifier).deleteProfile(profile.id);
    }
  }

  void _showExportDialog(BuildContext context, TrustTunnelProfile profile) {
    showDialog(
      context: context,
      builder: (ctx) => _ExportDialog(profile: profile),
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.shield_outlined,
            size: 80,
            color: AppTheme.border,
          ),
          const SizedBox(height: 16),
          const Text(
            'No profiles yet',
            style: TextStyle(fontSize: 18, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          const Text(
            'Add a server profile to get started',
            style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          GradientButton(
            label: 'Add Profile',
            icon: Icons.add_rounded,
            onPressed: onAdd,
            width: 160,
          ),
        ],
      ),
    );
  }
}

// ── Export dialog ─────────────────────────────────────────────────────────────

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.profile});

  final TrustTunnelProfile profile;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _showQr = false;

  void _copyDeepLink() {
    final link = DeepLinkService.generateDeepLink(widget.profile);
    Clipboard.setData(ClipboardData(text: link));
    _showSnackbar('Copied to clipboard!');
  }

  void _copyYaml() {
    final yaml = YamlService.profileToYaml(widget.profile);
    Clipboard.setData(ClipboardData(text: yaml));
    _showSnackbar('Copied to clipboard!');
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: AppTheme.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: const Text(
        'Export Profile',
        style: TextStyle(color: AppTheme.textPrimary),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Deep link row ──────────────────────────────────────────────
            _ExportRow(
              icon: Icons.link_rounded,
              label: 'tt:// Deep Link',
              onCopy: _copyDeepLink,
            ),

            const SizedBox(height: 12),

            // ── QR code row ────────────────────────────────────────────────
            Row(
              children: [
                const Icon(Icons.qr_code_rounded,
                    color: AppTheme.textSecondary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Show QR Code',
                    style: const TextStyle(color: AppTheme.textPrimary),
                  ),
                ),
                IconButton(
                  tooltip: _showQr ? 'Hide QR' : 'Show QR',
                  icon: Icon(
                    _showQr
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.qr_code_2_rounded,
                    color: AppTheme.primary,
                  ),
                  onPressed: () => setState(() => _showQr = !_showQr),
                ),
              ],
            ),

            if (_showQr) ...[
              const SizedBox(height: 12),
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(
                    data: DeepLinkService.generateDeepLink(widget.profile),
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 12),

            // ── YAML row ───────────────────────────────────────────────────
            _ExportRow(
              icon: Icons.description_outlined,
              label: 'YAML Format',
              onCopy: _copyYaml,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ExportRow extends StatelessWidget {
  const _ExportRow({
    required this.icon,
    required this.label,
    required this.onCopy,
  });

  final IconData icon;
  final String label;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.textSecondary, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child:
              Text(label, style: const TextStyle(color: AppTheme.textPrimary)),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy_rounded, color: AppTheme.primary),
          onPressed: onCopy,
        ),
      ],
    );
  }
}
