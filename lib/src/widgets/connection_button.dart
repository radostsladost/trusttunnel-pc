import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../theme/app_theme.dart';

/// The large circular connect / disconnect button shown on the home screen.
///
/// Behaviour by state:
/// - **disconnected / error** → tapping calls [onConnect].
/// - **connected** → tapping calls [onDisconnect].
/// - **connecting / disconnecting** → button is inert; a rotating arc ring is
///   drawn around it.
///
/// Animations:
/// - Rotating arc via [_rotCtrl] while connecting or disconnecting.
/// - Pulsing outer ring via [_pulseCtrl] while connected.
/// - Press-scale via [_pressCtrl] for all tappable states.
class ConnectionButton extends StatefulWidget {
  const ConnectionButton({
    super.key,
    required this.status,
    this.onConnect,
    this.onDisconnect,
  });

  final ConnectionStatus status;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  @override
  State<ConnectionButton> createState() => _ConnectionButtonState();
}

class _ConnectionButtonState extends State<ConnectionButton>
    with TickerProviderStateMixin {
  // Rotation: drives the spinning arc during connecting / disconnecting.
  late final AnimationController _rotCtrl;

  // Pulse: drives the outer glow ring breathing when connected.
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  // Press: drives a brief scale-down on pointer-down.
  late final AnimationController _pressCtrl;
  late final Animation<double> _pressAnim;

  @override
  void initState() {
    super.initState();

    _rotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _pulseAnim = Tween<double>(
      begin: 1.0,
      end: 1.14,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 180),
      lowerBound: 0,
      upperBound: 1,
    );
    _pressAnim = Tween<double>(
      begin: 1.0,
      end: 0.93,
    ).animate(CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut));

    _syncAnimations();
  }

  @override
  void didUpdateWidget(ConnectionButton old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _syncAnimations();
  }

  void _syncAnimations() {
    final s = widget.status;
    if (s == ConnectionStatus.connecting ||
        s == ConnectionStatus.disconnecting) {
      _rotCtrl.repeat();
      _pulseCtrl.stop();
      _pulseCtrl.reset();
    } else if (s == ConnectionStatus.connected) {
      _rotCtrl.stop();
      _rotCtrl.reset();
      _pulseCtrl.repeat(reverse: true);
    } else {
      _rotCtrl.stop();
      _rotCtrl.reset();
      _pulseCtrl.stop();
      _pulseCtrl.reset();
    }
  }

  @override
  void dispose() {
    _rotCtrl.dispose();
    _pulseCtrl.dispose();
    _pressCtrl.dispose();
    super.dispose();
  }

  // ── State-dependent visuals ────────────────────────────────────────────────

  ({Color inner, Color outer}) _gradientColors() => switch (widget.status) {
        ConnectionStatus.disconnected => (
            inner: AppTheme.primary,
            outer: AppTheme.primaryVariant,
          ),
        ConnectionStatus.connecting => (
            inner: AppTheme.warning,
            outer: const Color(0xFFB45309),
          ),
        ConnectionStatus.connected => (
            inner: AppTheme.success,
            outer: const Color(0xFF065F46),
          ),
        ConnectionStatus.disconnecting => (
            inner: AppTheme.warning,
            outer: const Color(0xFFB45309),
          ),
        ConnectionStatus.error => (
            inner: AppTheme.error,
            outer: const Color(0xFF9F1239),
          ),
      };

  String _upperLabel() => switch (widget.status) {
        ConnectionStatus.disconnected => 'CONNECT',
        ConnectionStatus.connecting => 'CONNECTING',
        ConnectionStatus.connected => 'CONNECTED',
        ConnectionStatus.disconnecting => 'DISCONNECTING',
        ConnectionStatus.error => 'ERROR',
      };

  String _lowerLabel() => switch (widget.status) {
        ConnectionStatus.connected => 'TAP TO DISCONNECT',
        ConnectionStatus.error => 'TAP TO RETRY',
        _ => '',
      };

  bool get _interactive =>
      widget.status == ConnectionStatus.disconnected ||
      widget.status == ConnectionStatus.connected ||
      widget.status == ConnectionStatus.error;

  void _handleTap() {
    if (widget.status == ConnectionStatus.disconnected ||
        widget.status == ConnectionStatus.error) {
      widget.onConnect?.call();
    } else if (widget.status == ConnectionStatus.connected) {
      widget.onDisconnect?.call();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = _gradientColors();
    final upperLabel = _upperLabel();
    final lowerLabel = _lowerLabel();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTapDown: _interactive ? (_) => _pressCtrl.forward() : null,
          onTapUp: _interactive ? (_) => _pressCtrl.reverse() : null,
          onTapCancel: _interactive ? () => _pressCtrl.reverse() : null,
          onTap: _interactive ? _handleTap : null,
          child: AnimatedBuilder(
            animation: Listenable.merge([_rotCtrl, _pulseCtrl, _pressCtrl]),
            builder: (context, _) {
              return Transform.scale(
                scale: _pressAnim.value,
                child: SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // ── Pulsing outer ring (connected) ───────────────────
                      if (widget.status == ConnectionStatus.connected)
                        Transform.scale(
                          scale: _pulseAnim.value,
                          child: Container(
                            width: 148,
                            height: 148,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppTheme.success.withValues(alpha: 0.35),
                                width: 2,
                              ),
                            ),
                          ),
                        ),

                      // ── Outer ambient glow (connected) ───────────────────
                      if (widget.status == ConnectionStatus.connected)
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.success.withValues(
                                  alpha: 0.15 +
                                      (_pulseAnim.value - 1.0) / 0.14 * 0.12,
                                ),
                                blurRadius: 28,
                                spreadRadius: 6,
                              ),
                            ],
                          ),
                        ),

                      // ── Rotating arc (connecting / disconnecting) ────────
                      if (widget.status == ConnectionStatus.connecting ||
                          widget.status == ConnectionStatus.disconnecting)
                        Transform.rotate(
                          angle: _rotCtrl.value * 2 * math.pi,
                          child: CustomPaint(
                            size: const Size(148, 148),
                            painter: _SpinnerArcPainter(
                              color: AppTheme.warning,
                              strokeWidth: 3.0,
                            ),
                          ),
                        ),

                      // ── Main circle ──────────────────────────────────────
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            center: const Alignment(-0.3, -0.35),
                            radius: 1.1,
                            colors: [colors.inner, colors.outer],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: colors.inner.withValues(
                                alpha: widget.status ==
                                        ConnectionStatus.connected
                                    ? 0.45 +
                                        (_pulseAnim.value - 1.0) / 0.14 * 0.25
                                    : 0.40,
                              ),
                              blurRadius:
                                  widget.status == ConnectionStatus.connected
                                      ? 24
                                      : 18,
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: Icon(
                              widget.status == ConnectionStatus.error
                                  ? Icons.error_outline_rounded
                                  : Icons.power_settings_new_rounded,
                              key: ValueKey(
                                widget.status == ConnectionStatus.error,
                              ),
                              color: Colors.white,
                              size: 46,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // ── Labels ──────────────────────────────────────────────────────────
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: Text(
            upperLabel,
            key: ValueKey(upperLabel),
            style: TextStyle(
              color: _gradientColors().inner,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.8,
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: lowerLabel.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    lowerLabel,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.2,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// ── Custom painter – spinning arc ────────────────────────────────────────────

class _SpinnerArcPainter extends CustomPainter {
  const _SpinnerArcPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // Fade the arc from opaque at the tip to transparent at the tail.
    final gradient = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      colors: [
        color.withValues(alpha: 0.0),
        color.withValues(alpha: 0.85),
        color
      ],
      stops: const [0.0, 0.75, 1.0],
    );

    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );

    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Draw ~330° of arc; the gap creates the impression of motion.
    canvas.drawArc(rect, -math.pi / 2, 11 * math.pi / 6, false, paint);
  }

  @override
  bool shouldRepaint(_SpinnerArcPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}
