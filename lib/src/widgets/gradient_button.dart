import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A full-width (or fixed-width) button with a left-to-right linear gradient,
/// an optional leading icon, a loading spinner, and a subtle press-scale
/// animation.
class GradientButton extends StatefulWidget {
  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.gradient,
    this.loading = false,
    this.width,
    this.height = 52,
  });

  final String label;
  final IconData? icon;

  /// Called when the button is tapped and [loading] is false.
  final VoidCallback? onPressed;

  /// Gradient stop colours.  Defaults to `[AppTheme.primary, AppTheme.secondary]`.
  final List<Color>? gradient;

  /// Shows a [CircularProgressIndicator] in place of the label when true.
  final bool loading;

  final double? width;

  /// Button height.  Default 52.
  final double height;

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleCtrl;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 180),
      lowerBound: 0,
      upperBound: 1,
    );
    _scaleAnim = Tween<double>(
      begin: 1.0,
      end: 0.97,
    ).animate(CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  bool get _isEnabled => widget.onPressed != null && !widget.loading;

  List<Color> get _colors =>
      widget.gradient ?? [AppTheme.primary, AppTheme.secondary];

  void _onTapDown(TapDownDetails _) {
    if (_isEnabled) _scaleCtrl.forward();
  }

  void _onTapUp(TapUpDetails _) {
    if (_isEnabled) _scaleCtrl.reverse();
  }

  void _onTapCancel() {
    if (_isEnabled) _scaleCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors;
    final disabled = !_isEnabled;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: _isEnabled ? widget.onPressed : null,
      child: AnimatedBuilder(
        animation: _scaleAnim,
        builder: (context, child) =>
            Transform.scale(scale: _scaleAnim.value, child: child),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: disabled
                  ? colors.map((c) => c.withValues(alpha: 0.35)).toList()
                  : colors,
            ),
            boxShadow: disabled
                ? null
                : [
                    BoxShadow(
                      color: colors.first.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Center(
            child: widget.loading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(
                          widget.icon,
                          color: Colors.white
                              .withValues(alpha: disabled ? 0.4 : 1.0),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: Colors.white
                              .withValues(alpha: disabled ? 0.4 : 1.0),
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
