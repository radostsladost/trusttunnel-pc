import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A card widget with an optional neon glow border effect.
///
/// Uses a diagonal gradient background and a coloured border whose opacity
/// intensifies when [glowing] is true.  When [onTap] is provided the card
/// responds to presses with an ink ripple clipped to its rounded shape.
class NeonCard extends StatelessWidget {
  const NeonCard({
    super.key,
    required this.child,
    this.glowColor,
    this.glowing = false,
    this.padding,
    this.onTap,
    this.borderRadius = 16,
  });

  final Widget child;

  /// Border/glow colour.  Defaults to [AppTheme.primary].
  final Color? glowColor;

  /// Whether to render the glow shadow and raise border opacity.
  final bool glowing;

  final EdgeInsets? padding;

  /// Callback fired when the card is tapped.  If null the card is inert
  /// (no ripple).
  final VoidCallback? onTap;

  /// Corner radius in logical pixels.  Default 16.
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final Color effectiveGlow = glowColor ?? AppTheme.primary;
    final double borderOpacity = glowing ? 0.60 : 0.28;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.card.withValues(alpha: 0.92),
            AppTheme.surface.withValues(alpha: 0.92),
          ],
        ),
        border: Border.all(
          color: effectiveGlow.withValues(alpha: borderOpacity),
          width: 1.0,
        ),
        boxShadow: glowing
            ? [
                BoxShadow(
                  color: effectiveGlow.withValues(alpha: 0.25),
                  blurRadius: 12,
                  spreadRadius: 0,
                  offset: Offset.zero,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(borderRadius),
            splashColor: effectiveGlow.withValues(alpha: 0.08),
            highlightColor: effectiveGlow.withValues(alpha: 0.04),
            hoverColor: effectiveGlow.withValues(alpha: 0.03),
            child: Padding(
              padding: padding ?? const EdgeInsets.all(16),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
