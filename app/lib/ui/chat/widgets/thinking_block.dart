import 'dart:async';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// Model reasoning ("thinking") as a collapsible block, COLLAPSED BY DEFAULT —
// it is context for the answer, not the answer, so it must never push the
// actual reply off the screen. The header is the only thing visible until the
// user taps it; expansion is local state, so a rebuild (a new streamed delta,
// or a re-sync re-writing the row) keeps whatever the user chose.
//
// The header also carries the elapsed time: it ticks while the model is still
// reasoning ("Thinking… 12s") and freezes into the row ("Thought for 12s") once
// the block closes.

/// Human-readable duration for a reasoning block. Sub-second blocks read as
/// "<1s" rather than a meaningless millisecond count.
String formatThinkingDuration(Duration d) {
  if (d.inSeconds < 1) return '<1s';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return seconds == 0 ? '${minutes}m' : '${minutes}m ${seconds}s';
}

class ThinkingBlock extends StatefulWidget {
  /// Live reasoning still arriving from the Pi (`live: true`) or a finalized
  /// row from the box/history. Both render identically apart from the
  /// streaming label, cursor and ticking timer.
  const ThinkingBlock({
    super.key,
    required this.text,
    this.live = false,
    this.cursor,
    this.duration,
    this.startedAt,
    this.now = DateTime.now,
  });

  final String text;
  final bool live;

  /// Blinking cursor, supplied by the streaming bubble while [live]. Rendered
  /// beside the label when collapsed and under the text when expanded.
  final Widget? cursor;

  /// How long the block took, for a finalized row. Null → no timer (history
  /// replayed by a Pi that could not time it).
  final Duration? duration;

  /// When the live block started, so the header can tick while it streams.
  final DateTime? startedAt;

  /// Clock seam: production reads the wall clock, tests advance theirs so the
  /// tick can be asserted without sleeping.
  final DateTime Function() now;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _expanded = false;
  Timer? _ticker;
  Duration? _elapsed;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    if (old.live != widget.live || old.startedAt != widget.startedAt) {
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Runs a 1s ticker exactly while there is a live segment with a known start.
  void _syncTicker() {
    final start = widget.startedAt;
    if (!widget.live || start == null) {
      _ticker?.cancel();
      _ticker = null;
      _elapsed = null;
      return;
    }
    _elapsed = widget.now().difference(start);
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = widget.now().difference(start));
    });
  }

  String _label() {
    if (widget.live) {
      final elapsed = _elapsed;
      return elapsed == null
          ? 'Thinking…'
          : 'Thinking… ${formatThinkingDuration(elapsed)}';
    }
    final duration = widget.duration;
    return duration == null
        ? 'Thinking'
        : 'Thought for ${formatThinkingDuration(duration)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = context.typo.sansBody.copyWith(fontSize: 13, height: 1.45);
    final hasText = widget.text.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            key: const Key('thinking-header'),
            behavior: HitTestBehavior.opaque,
            onTap: hasText
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(LucideIcons.brain, size: 13, color: colors.muted),
                  const SizedBox(width: 6),
                  Text(
                    _label(),
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 11.5,
                      color: colors.muted,
                      letterSpacing: 0.3,
                    ),
                  ),
                  if (widget.live && !_expanded && widget.cursor != null) ...[
                    const SizedBox(width: 6),
                    widget.cursor!,
                  ],
                  const Spacer(),
                  if (hasText)
                    Icon(
                      _expanded
                          ? LucideIcons.chevronDown
                          : LucideIcons.chevronRight,
                      size: 14,
                      color: colors.muted,
                    ),
                ],
              ),
            ),
          ),
          if (_expanded && hasText)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    widget.text,
                    style: body.copyWith(color: colors.muted2),
                  ),
                  if (widget.live && widget.cursor != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: widget.cursor!,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Persisted reasoning row (live text, re-synced history, app restart).
class ThinkingBubble extends StatelessWidget {
  final ThinkingMsg message;

  const ThinkingBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) =>
      ThinkingBlock(text: message.text, duration: message.duration);
}
