import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../theme/app_theme.dart';
import 'neon_card.dart';

/// A list-item card for a single [TrustTunnelProfile].
///
/// Visual priority:
/// - Connected  → green glow + "ACTIVE" badge
/// - Selected   → purple glow
/// - Neither    → subtle grey border (no glow)
///
/// The three-dot overflow menu exposes Edit / Export / Delete actions.
class ProfileCard extends StatelessWidget {
  const ProfileCard({
    super.key,
    required this.profile,
    this.isSelected = false,
    this.isConnected = false,
    this.onTap,
    this.onEdit,
    this.onDelete,
    this.onExport,
  });

  final TrustTunnelProfile profile;
  final bool isSelected;
  final bool isConnected;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onExport;

  Color get _glowColor {
    if (isConnected) return AppTheme.success;
    if (isSelected) return AppTheme.primary;
    return AppTheme.border;
  }

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      glowColor: _glowColor,
      glowing: isConnected || isSelected,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          // ── Shield avatar ────────────────────────────────────────────────
          _ShieldAvatar(color: _glowColor, isConnected: isConnected),
          const SizedBox(width: 14),

          // ── Profile info ─────────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Name row
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        profile.name,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isConnected) ...[
                      const SizedBox(width: 8),
                      const _PillBadge(
                        label: 'ACTIVE',
                        color: AppTheme.success,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),

                // Hostname
                Text(
                  profile.hostname,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),

                // Badges row: listener type + first address
                Row(
                  children: [
                    _ListenerBadge(type: profile.listenerType),
                    if (profile.addresses.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          profile.addresses.first,
                          style: TextStyle(
                            color:
                                AppTheme.textSecondary.withValues(alpha: 0.7),
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // ── Overflow menu ────────────────────────────────────────────────
          _OverflowMenu(onEdit: onEdit, onDelete: onDelete, onExport: onExport),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _ShieldAvatar extends StatelessWidget {
  const _ShieldAvatar({required this.color, required this.isConnected});

  final Color color;
  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.40), width: 1.5),
      ),
      child: Icon(
        isConnected ? Icons.shield_rounded : Icons.shield_outlined,
        color: color,
        size: 21,
      ),
    );
  }
}

class _PillBadge extends StatelessWidget {
  const _PillBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.40), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _ListenerBadge extends StatelessWidget {
  const _ListenerBadge({required this.type});

  final ListenerType type;

  @override
  Widget build(BuildContext context) {
    final isTun = type == ListenerType.tun;
    final color = isTun ? AppTheme.secondary : AppTheme.primary;
    final label = isTun ? 'TUN' : 'SOCKS5';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.onEdit,
    required this.onDelete,
    required this.onExport,
  });

  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_MenuAction>(
      onSelected: (action) {
        switch (action) {
          case _MenuAction.edit:
            onEdit?.call();
          case _MenuAction.export:
            onExport?.call();
          case _MenuAction.delete:
            onDelete?.call();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _MenuAction.edit,
          height: 40,
          child: _MenuItem(
            icon: Icons.edit_outlined,
            label: 'Edit',
            iconColor: AppTheme.textSecondary,
          ),
        ),
        const PopupMenuItem(
          value: _MenuAction.export,
          height: 40,
          child: _MenuItem(
            icon: Icons.upload_file_outlined,
            label: 'Export',
            iconColor: AppTheme.textSecondary,
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: _MenuAction.delete,
          height: 40,
          child: _MenuItem(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            iconColor: AppTheme.error,
            labelColor: AppTheme.error,
          ),
        ),
      ],
      icon: const Icon(
        Icons.more_vert_rounded,
        color: AppTheme.textSecondary,
        size: 20,
      ),
      tooltip: 'Profile options',
      splashRadius: 18,
      padding: EdgeInsets.zero,
    );
  }
}

enum _MenuAction { edit, export, delete }

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.iconColor,
    this.labelColor = AppTheme.textPrimary,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            color: labelColor,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
