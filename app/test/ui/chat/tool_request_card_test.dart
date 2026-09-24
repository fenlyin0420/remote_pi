import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Open the card's folded details (the header is the fold control).
Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('tool-header')));
  await tester.pump();
}

const _failedTool = ToolEvent(
  id: 'tc1',
  toolCallId: 'tc1',
  tool: 'Bash',
  args: {'command': 'exit 1'},
  status: ToolEventStatus.failed,
  error: 'command failed: exit 1',
);

const _doneTool = ToolEvent(
  id: 'tc1',
  toolCallId: 'tc1',
  tool: 'Bash',
  args: {'command': 'ls'},
  status: ToolEventStatus.completed,
  result: 'file-a\nfile-b',
);

const _bashTool = ToolEvent(
  id: 'tc1',
  toolCallId: 'tc1',
  tool: 'Bash',
  args: {'command': 'ls -la'},
);

const _editToolWithHunk = ToolEvent(
  id: 'tc2',
  toolCallId: 'tc4',
  tool: 'edit',
  args: {
    'path': 'app/test/ui/chat/tool_request_card_test.dart',
    'hunks': [
      {
        'lines': [
          {'kind': 'context', 'oldLine': 16, 'newLine': 16, 'text': 'args: {'},
          {'kind': 'remove', 'oldLine': 17, 'text': "  tool: 'Edit',"},
          {'kind': 'add', 'newLine': 17, 'text': "  tool: 'edit',"},
          {'kind': 'context', 'oldLine': 18, 'newLine': 18, 'text': '},'},
        ],
      },
    ],
  },
);

void main() {
  group('ToolRequestCard (informational)', () {
    testWidgets('shows tool name and command', (tester) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.text('BASH'), findsOneWidget);
      await _expand(tester);
      expect(find.text('ls -la'), findsOneWidget);
    });

    testWidgets('details are folded by default — only the header shows', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _doneTool)));
      // The header carries the timeline: which tool, and how it ended.
      expect(find.text('BASH'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);
      // Everything long stays folded.
      expect(find.text('ls'), findsNothing, reason: 'command is folded');
      expect(find.text('file-a\nfile-b'), findsNothing, reason: 'output too');
      expect(find.text('✓ Done'), findsNothing, reason: 'status line too');
    });

    testWidgets('tapping the header reveals the command and re-folds it', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      await _expand(tester);
      expect(find.text('ls -la'), findsOneWidget);

      await _expand(tester);
      expect(find.text('ls -la'), findsNothing);
    });

    testWidgets('the returned output is folded away with the details', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _doneTool)));
      expect(find.textContaining('file-a'), findsNothing);

      await _expand(tester);
      expect(find.textContaining('file-a\nfile-b'), findsOneWidget);
    });

    testWidgets('a huge result is bounded, with what was left out declared', (
      tester,
    ) async {
      final huge = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'cat big'},
        status: ToolEventStatus.completed,
        result: 'x' * 20000,
      );
      await tester.pumpWidget(_wrap(ToolRequestCard(tool: huge)));
      await _expand(tester);

      final rendered = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect(rendered.length, 12000);
      expect(find.textContaining('8000 more characters'), findsOneWidget);
    });

    testWidgets('a failure folds its output too, keeping the FAILED header', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _failedTool)));
      expect(find.text('FAILED'), findsOneWidget);
      expect(find.textContaining('command failed: exit 1'), findsNothing);

      await _expand(tester);
      expect(find.textContaining('command failed: exit 1'), findsOneWidget);
    });

    testWidgets('an opened card stays open when the row is rebuilt', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(key: ValueKey('row-1'), tool: _bashTool)),
      );
      await _expand(tester);
      expect(find.text('ls -la'), findsOneWidget);

      // Same tool call, new identity: a scroll-away/back or a re-sync.
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(key: ValueKey('row-2'), tool: _bashTool)),
      );
      expect(
        find.text('ls -la'),
        findsOneWidget,
        reason: 'the user opened it — a rebuild must not fold it back',
      );
    });

    testWidgets('edit renders rich hunks with context lines', (tester) async {
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(tool: _editToolWithHunk)),
      );
      await _expand(tester);

      expect(
        find.textContaining('   16 args: {', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("-  17   tool: 'Edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("+  17   tool: 'edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('   18 },', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('pending state shows RUNNING and no Allow/Deny buttons', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      // No leftover approval countdown (the pre-auto-approval UI had "60s").
      expect(find.textContaining(RegExp(r'\d+s')), findsNothing);
    });

    testWidgets('completed state shows DONE', (tester) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _doneTool)));
      expect(find.text('DONE'), findsOneWidget);
      await _expand(tester);
      expect(find.textContaining('Done'), findsAny);
    });

    testWidgets('denied state shows DENIED label', (tester) async {
      const denied = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.denied,
        error: 'user denied',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: denied)));
      expect(find.text('DENIED'), findsOneWidget);
    });

    testWidgets('allowed state shows RUNNING (still in flight)', (
      tester,
    ) async {
      const allowed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.allowed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: allowed)));
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
    });

    // Plan/32 — the card is colored by status: running blue, done green,
    // failed red. We assert the outcome line's color (the same _statusColor
    // drives the border / icon / tool name).
    Color? outcomeColor(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    testWidgets('completed → green "✓ Done"', (tester) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _doneTool)));
      await _expand(tester);
      expect(outcomeColor(tester, '✓ Done'), AppColors.dark.success);
    });

    testWidgets('failed → red "✗ Failed" + the error in the folded output', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _failedTool)));
      expect(find.text('FAILED'), findsOneWidget);
      await _expand(tester);
      expect(outcomeColor(tester, '✗ Failed'), AppColors.dark.error);
      expect(find.textContaining('command failed: exit 1'), findsOneWidget);
    });

    testWidgets('running → blue "⏳ Running…"', (tester) async {
      // pending defaults
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      await _expand(tester);
      expect(outcomeColor(tester, '⏳ Running…'), AppColors.dark.accent);
    });
  });
}
