import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// Model reasoning ("thinking") as a collapsible block, COLLAPSED BY DEFAULT —
// it is context for the answer, not the answer, so it must never push the
// actual reply off the screen. The header is the only thing visible until the
// user taps it; expansion is local state, so a rebuild (a new streamed delta,
// or a re-sync re-writing the row) keeps whatever the user chose.

class ThinkingBlock extends StatefulWidget {
  /// Live reasoning still arriving from the Pi (`live: true`) or a finalized
  /// row from the box/history. Both render identically apart from the
  /// streaming label + cursor.
  const ThinkingBlock({
    super.key,
    required this.text,
    this.live = false,
    this.cursor,
  });

  final String text;
  final bool live;

  /// Blinking cursor, supplied by the streaming bubble while [live]. Rendered
  /// beside the label when collapsed and under the text when expanded.
  final Widget? cursor;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _expanded = false;

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
                    widget.live ? 'Thinking…' : 'Thinking',
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
                  SelectableText(widget.text, style: body.copyWith(color: colors.muted2)),
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
  Widget build(BuildContext context) => ThinkingBlock(text: message.text);
}
