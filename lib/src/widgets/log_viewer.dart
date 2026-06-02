import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A terminal-style scrollable log viewer that subscribes to a [Stream<String>].
///
/// - Lines containing "error" are coloured red; "warn" lines amber; all others
///   terminal green.
/// - Auto-scrolls to the bottom whenever a new line arrives.
/// - Caps history at [maxLines] entries (FIFO) to avoid unbounded growth.
class LogViewer extends StatefulWidget {
  const LogViewer({super.key, required this.logStream, this.maxLines = 500});

  final Stream<String> logStream;

  /// Maximum number of log lines retained in memory.  Default 500.
  final int maxLines;

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  // ── Colours ────────────────────────────────────────────────────────────────
  static const Color _bg = Color(0xFF06060E);
  static const Color _green = Color(0xFF7BF0A0);
  static const Color _red = Color(0xFFFF6B6B);
  static const Color _amber = Color(0xFFFFC107);
  static const Color _dim = Color(0xFF3A3A5A);

  // ── State ──────────────────────────────────────────────────────────────────
  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _sub;

  // Whether the user has manually scrolled away from the bottom.
  bool _userScrolled = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _subscribe();
  }

  @override
  void didUpdateWidget(LogViewer old) {
    super.didUpdateWidget(old);
    if (old.logStream != widget.logStream) {
      _sub?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  // ── Stream subscription ───────────────────────────────────────────────────

  void _subscribe() {
    _sub = widget.logStream.listen(_onLine, onError: (_) {});
  }

  void _onLine(String line) {
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > widget.maxLines) _lines.removeAt(0);
    });
    if (!_userScrolled) {
      // Schedule after the next frame so the new item is laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // Consider "at bottom" within 32 px of the maximum scroll extent.
    _userScrolled = pos.pixels < pos.maxScrollExtent - 32;
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  // ── Line colouring ────────────────────────────────────────────────────────

  Color _colorForLine(String line) {
    final l = line.toLowerCase();
    if (l.contains('error') || l.contains('err]') || l.contains('[err')) {
      return _red;
    }
    if (l.contains('warn') || l.contains('[warn')) return _amber;
    return _green;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // ── Terminal background ──────────────────────────────────────────────
        Container(color: _bg),

        // ── Content ──────────────────────────────────────────────────────────
        if (_lines.isEmpty)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.terminal_rounded, size: 36, color: _dim),
                const SizedBox(height: 12),
                Text(
                  'No logs yet',
                  style: GoogleFonts.sourceCodePro(
                    color: _dim,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          )
        else
          Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              // A single SelectableText.rich spans all lines, so the user
              // can drag a selection across multiple log lines at once.
              child: SelectableText.rich(
                TextSpan(
                  children: [
                    for (final line in _lines)
                      TextSpan(
                        text: '$line\n',
                        style: GoogleFonts.sourceCodePro(
                          color: _colorForLine(line),
                          fontSize: 11,
                          height: 1.55,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

        // ── "scroll to bottom" FAB ───────────────────────────────────────────
        if (_userScrolled)
          Positioned(
            right: 14,
            bottom: 14,
            child: _ScrollToBottomButton(
              onPressed: () {
                _userScrolled = false;
                _scrollToBottom();
              },
            ),
          ),
      ],
    );
  }
}

// ── Helper widget ──────────────────────────────────────────────────────────────

class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Jump to latest',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A30),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF2D3060), width: 1),
          ),
          child: const Icon(
            Icons.keyboard_double_arrow_down_rounded,
            color: Color(0xFF7BF0A0),
            size: 17,
          ),
        ),
      ),
    );
  }
}
