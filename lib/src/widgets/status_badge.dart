import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/profile.dart';
import '../theme/app_theme.dart';

/// A coloured badge that communicates the current [ConnectionStatus].
///
/// In full mode (default) it renders as a pill with a background tint.
/// In [compact] mode it shows only the indicator dot and a short label, useful
/// for tight spaces such as the app-bar.
///
/// Connecting / disconnecting states use a repeating scale pulse driven by
/// `flutter_animate`.  The connected state adds a steady outer glow.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.compact = false});

  final ConnectionStatus status;

  /// When true, renders a minimal dot + short-text variant.
  final bool compact;

  // ── Helpers ────────────────────────────────────────────────────────────────

  Color _color() => switch (status) {
        ConnectionStatus.disconnected => AppTheme.textSecondary,
        ConnectionStatus.connecting => AppTheme.warning,
        ConnectionStatus.connected => AppTheme.success,
        ConnectionStatus.disconnecting => AppTheme.warning,
        ConnectionStatus.reconnecting => AppTheme.warning,
        ConnectionStatus.error => AppTheme.error,
      };

  String _label() => switch (status) {
        ConnectionStatus.disconnected => 'Disconnected',
        ConnectionStatus.connecting => 'Connecting...',
        ConnectionStatus.connected => 'Connected',
        ConnectionStatus.disconnecting => 'Disconnecting...',
        ConnectionStatus.reconnecting => 'Reconnecting...',
        ConnectionStatus.error => 'Error',
      };

  bool get _pulsing =>
      status == ConnectionStatus.connecting ||
      status == ConnectionStatus.disconnecting ||
      status == ConnectionStatus.reconnecting;

  bool get _connected => status == ConnectionStatus.connected;

  // ── Dot ───────────────────────────────────────────────────────────────────

  Widget _buildDot(double size) {
    final color = _color();

    Widget dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: _connected
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.65),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );

    if (_pulsing) {
      dot = dot.animate(onPlay: (c) => c.repeat(reverse: true)).scale(
            begin: const Offset(0.75, 0.75),
            end: const Offset(1.25, 1.25),
            duration: 800.ms,
            curve: Curves.easeInOut,
          );
    }

    return dot;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final color = _color();
    final label = _label();

    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDot(8),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ],
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.30), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDot(10),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
