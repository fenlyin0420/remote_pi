import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// Inline tool execution card that appears in the chat flow.
//
// Historically this widget rendered Allow/Deny buttons + a 60s countdown
// assuming the Pi paused execution until the user decided. With the current
// Claude SDK integration the pi-extension emits `tool_request` AFTER the
// SDK has already accepted the tool (`tool_execution_start` fires post
// auto-approval), so the buttons could only blink for a few hundred
// milliseconds before `tool_result` arrived — confusing UX with no real
// gating. The card is now purely informational.
//
// The details are FOLDED BY DEFAULT: the header always says which tool ran and
// how it ended (colour + RUNNING/DONE/FAILED/DENIED), and that is all the
// collapsed row shows. What folds away is everything long — the command / diff
// AND the tool's returned output (which for a failed call is the error text,
// and can be hundreds of KB): expanded, the output scrolls inside a bounded box
// instead of stretching the transcript.
//
// `onDecide` is kept on the API for forward compat — when the Pi adds a
// real approval pause we can re-enable the controls. Today it is unused.

class ToolRequestCard extends StatefulWidget {
  final ToolEvent tool;
  final void Function(String toolCallId, ApproveDecision decision)? onDecide;

  const ToolRequestCard({super.key, required this.tool, this.onDecide});

  @override
  State<ToolRequestCard> createState() => _ToolRequestCardState();
}

class _ToolRequestCardState extends State<ToolRequestCard> {
  bool _expanded = false;
  bool _restored = false;

  ToolEvent get tool => widget.tool;

  /// Expansion kept in the route's [PageStorage] under the tool call id (which
  /// the wire gives us and history replays identically), so scrolling a card
  /// out of view — or a re-sync re-writing the row — does not fold the card the
  /// user opened.
  Object get _storageId => 'tool-expanded:${tool.toolCallId}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    final stored = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _storageId);
    if (stored is bool) _expanded = stored;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _expanded, identifier: _storageId);
  }

  /// Plan/32 — one color drives the whole card so the outcome is unmistakable:
  /// running → blue, done → green, failed → red, denied/expired → grey.
  Color _statusColor(BuildContext context) {
    final colors = context.colors;
    return switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => colors.accent,
      ToolEventStatus.completed => colors.success,
      ToolEventStatus.failed => colors.error,
      ToolEventStatus.denied || ToolEventStatus.expired => colors.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context);
    // Dim only the inert states (denied/expired); keep done/failed at full
    // opacity so their green/red read clearly.
    final dimmed =
        tool.status == ToolEventStatus.denied ||
        tool.status == ToolEventStatus.expired;

    return Opacity(
      opacity: dimmed ? 0.65 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: color, width: 1),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.13),
              blurRadius: 20,
              spreadRadius: 1,
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, color),
            if (_expanded) ...[
              const SizedBox(height: 10),
              _buildCodeBlock(context),
              if (_toolOutput.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildOutput(context),
              ],
              const SizedBox(height: 8),
              _buildOutcome(color),
            ],
          ],
        ),
      ),
    );
  }

  /// How much tool output gets rendered. A `cat big-file` can return hundreds
  /// of KB: laying that out would stall the frame, and nobody reads it on a
  /// phone — the tail is one tap away from the tool row's copy affordances on
  /// desktop. The marker says how much was left out rather than pretending.
  static const int _maxOutputChars = 12000;

  /// Long output scrolls inside this box instead of stretching the transcript.
  static const double _outputMaxHeight = 240;

  /// What the tool returned: its output for a completed call, its error for a
  /// failed one (`tool_result` carries the text in `error` in that case). Empty
  /// while it is still running.
  String get _toolOutput {
    final result = tool.result;
    final text = switch (tool.status) {
      ToolEventStatus.failed || ToolEventStatus.denied =>
        tool.error ?? result?.toString() ?? '',
      _ => result?.toString() ?? '',
    };
    return text.trim();
  }

  /// The returned text — folded away with the rest of the details, because it
  /// is the longest part of a tool row by far.
  Widget _buildOutput(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final full = _toolOutput;
    final shown = full.length > _maxOutputChars
        ? full.substring(0, _maxOutputChars)
        : full;
    final hidden = full.length - shown.length;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _outputMaxHeight),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                shown,
                style: typo.mono.copyWith(color: colors.muted2),
              ),
              if (hidden > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '… $hidden more characters',
                    style: typo.monoSmall.copyWith(color: colors.muted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Color color) {
    final statusLabel = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => 'RUNNING',
      ToolEventStatus.completed => 'DONE',
      ToolEventStatus.failed => 'FAILED',
      ToolEventStatus.denied => 'DENIED',
      ToolEventStatus.expired => 'EXPIRED',
    };

    return GestureDetector(
      key: const Key('tool-header'),
      behavior: HitTestBehavior.opaque,
      // Also the scroll-safe way to reveal the details: the row is a full-width
      // tap target, and a plain tap during a scroll is not delivered here.
      onTap: _toggle,
      child: Row(
        children: [
          CustomPaint(
            size: const Size(14, 14),
            painter: _TerminalIconPainter(color: color),
          ),
          const SizedBox(width: 8),
          Text(
            tool.tool.toUpperCase(),
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 11.5,
              color: color,
              letterSpacing: 0.6,
            ),
          ),
          const Spacer(),
          Text(
            statusLabel,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 10,
              color: color,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            _expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
            size: 14,
            color: color,
          ),
        ],
      ),
    );
  }

  Widget _buildCodeBlock(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final content = _buildToolSummary(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r'$ ', style: typo.mono.copyWith(color: colors.muted)),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildToolSummary(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final display = _formatToolDisplay(tool.tool, tool.args);
    if (display == null) {
      return Text(_formatArgs(tool.tool, tool.args), style: typo.mono);
    }

    return Text.rich(
      TextSpan(
        style: typo.mono,
        children: [
          TextSpan(text: display.command),
          for (final line in display.lines) ...[
            const TextSpan(text: '\n'),
            TextSpan(
              text: line.text,
              style: TextStyle(color: line.color(colors)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutcome(Color color) {
    // Label only: the failure's text is the tool's returned output and lives in
    // the folded output block with the rest of the details.
    final text = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => '⏳ Running…',
      ToolEventStatus.completed => '✓ Done',
      ToolEventStatus.failed => '✗ Failed',
      ToolEventStatus.denied => '✗ Denied',
      ToolEventStatus.expired => '✗ Expired',
    };
    return Text(
      text,
      style: TextStyle(fontFamily: kMonoFamily, fontSize: 12, color: color),
    );
  }

  static String _formatArgs(String tool, dynamic args) {
    if (args == null) return '';
    final normalizedTool = tool.toLowerCase();
    if (args is Map) {
      return switch (normalizedTool) {
        'bash' => (args['command'] as String?) ?? '',
        'edit' || 'write' =>
          '$normalizedTool ${_stringArg(args, const ['file_path', 'path'])}',
        _ => args.entries.map((e) => '${e.key}=${e.value}').join(' '),
      };
    }
    return args.toString();
  }

  static _ToolDisplay? _formatToolDisplay(String tool, dynamic args) {
    if (args is! Map) return null;
    return switch (tool.toLowerCase()) {
      'edit' => _formatEditDisplay(args),
      _ => null,
    };
  }

  static _ToolDisplay? _formatEditDisplay(Map args) {
    final filePath = _stringArg(args, const ['file_path', 'path']);
    final lines = <_DiffLine>[];
    final hunks = args['hunks'];
    if (hunks is! Iterable) return null;

    for (final hunk in hunks) {
      if (hunk is! Map || hunk['lines'] is! Iterable) continue;
      if (lines.isNotEmpty) lines.add(_DiffLine.context('      ...'));
      for (final rawLine in hunk['lines'] as Iterable) {
        if (rawLine is! Map) continue;
        final text = _lineText(rawLine);
        switch (rawLine['kind']) {
          case 'context':
            lines.add(_DiffLine.context(text));
          case 'remove':
            lines.add(_DiffLine.removed(text));
          case 'add':
            lines.add(_DiffLine.added(text));
          case 'ellipsis':
            lines.add(_DiffLine.context('      ...'));
        }
      }
    }

    if (lines.isEmpty) return null;
    return _ToolDisplay(command: 'edit $filePath', lines: lines);
  }

  static String _lineText(Map rawLine) {
    final sign = switch (rawLine['kind']) {
      'remove' => '-',
      'add' => '+',
      _ => ' ',
    };
    final lineNumber = rawLine['oldLine'] ?? rawLine['newLine'];
    final number = lineNumber is int ? lineNumber.toString().padLeft(3) : '   ';
    return '$sign $number ${rawLine['text'] ?? ''}';
  }

  static String _stringArg(Map args, List<String> keys) {
    for (final key in keys) {
      final value = args[key];
      if (value is String) return value;
    }
    return '';
  }
}

class _ToolDisplay {
  final String command;
  final List<_DiffLine> lines;

  const _ToolDisplay({required this.command, required this.lines});
}

class _DiffLine {
  final String text;
  final Color Function(AppColors colors) color;

  const _DiffLine._(this.text, this.color);

  factory _DiffLine.removed(String text) =>
      _DiffLine._(text, (colors) => colors.error);

  factory _DiffLine.added(String text) =>
      _DiffLine._(text, (colors) => colors.success);

  factory _DiffLine.context(String text) =>
      _DiffLine._(text, (colors) => colors.text);
}

// Minimal terminal icon (rectangle + > and —)
class _TerminalIconPainter extends CustomPainter {
  final Color color;
  const _TerminalIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 1, size.width - 1, size.height - 2),
        const Radius.circular(1.6),
      ),
      paint,
    );
    final path = Path()
      ..moveTo(3, 4.5)
      ..lineTo(5.5, 7)
      ..lineTo(3, 9.5);
    canvas.drawPath(path, paint);
    canvas.drawLine(
      Offset(6.5, size.height / 2),
      Offset(size.width - 2, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TerminalIconPainter old) => old.color != color;
}
