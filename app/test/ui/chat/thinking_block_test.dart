// The thinking block is COLLAPSED BY DEFAULT — model reasoning must never push
// the answer off the (phone-sized) screen until the user asks for it. These
// tests pin that default, the in-place expand/collapse behaviour and the elapsed
// timer, for both shapes: a persisted row (`ThinkingBubble`) and the live
// streamed block.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  group('formatThinkingDuration', () {
    test('sub-second reads as <1s, then seconds, then minutes', () {
      expect(formatThinkingDuration(const Duration(milliseconds: 400)), '<1s');
      expect(formatThinkingDuration(const Duration(seconds: 1)), '1s');
      expect(formatThinkingDuration(const Duration(seconds: 59)), '59s');
      expect(formatThinkingDuration(const Duration(seconds: 60)), '1m');
      expect(formatThinkingDuration(const Duration(seconds: 125)), '2m 5s');
    });
  });

  testWidgets('a timed row says how long the model thought', (tester) async {
    await pump(
      tester,
      const ThinkingBubble(
        ThinkingMsg(
          id: 't1',
          text: 'weighed it up',
          duration: Duration(seconds: 12),
        ),
      ),
    );
    expect(find.text('Thought for 12s'), findsOneWidget);
    expect(find.text('weighed it up'), findsNothing, reason: 'still collapsed');
  });

  testWidgets('an untimed row (Pi could not time it) shows no number', (
    tester,
  ) async {
    await pump(
      tester,
      const ThinkingBubble(ThinkingMsg(id: 't1', text: 'from disk')),
    );
    expect(find.text('Thinking'), findsOneWidget);
  });

  testWidgets('the live header ticks the elapsed time', (tester) async {
    // Inject the clock: a widget test's `pump(Duration)` advances fake timers
    // but NOT the wall clock the ticker reads.
    var now = DateTime(2026, 1, 1, 12);
    await pump(
      tester,
      ThinkingBlock(
        text: 'partial',
        live: true,
        startedAt: now,
        now: () => now,
        cursor: const SizedBox(key: Key('cursor'), width: 4, height: 8),
      ),
    );
    expect(find.text('Thinking… <1s'), findsOneWidget);

    now = now.add(const Duration(seconds: 7));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Thinking… 7s'), findsOneWidget);

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Thinking… 8s'), findsOneWidget);
  });

  testWidgets('collapsed by default — reasoning is not rendered', (
    tester,
  ) async {
    await pump(tester, const ThinkingBlock(text: 'secret reasoning'));
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('secret reasoning'), findsNothing);
  });

  testWidgets('tapping the header expands, tapping again collapses', (
    tester,
  ) async {
    await pump(tester, const ThinkingBlock(text: 'secret reasoning'));

    await tester.tap(find.byKey(const Key('thinking-header')));
    await tester.pump();
    expect(find.text('secret reasoning'), findsOneWidget);

    await tester.tap(find.byKey(const Key('thinking-header')));
    await tester.pump();
    expect(find.text('secret reasoning'), findsNothing);
  });

  testWidgets('a replayed row (ThinkingBubble) is collapsed too', (
    tester,
  ) async {
    await pump(
      tester,
      const ThinkingBubble(ThinkingMsg(id: 't1', text: 'replayed reasoning')),
    );
    expect(find.text('replayed reasoning'), findsNothing);
    expect(find.text('Thinking'), findsOneWidget);
  });

  testWidgets('live block reads "Thinking…" and carries the cursor', (
    tester,
  ) async {
    await pump(
      tester,
      const ThinkingBlock(
        text: 'partial thought',
        live: true,
        cursor: SizedBox(key: Key('cursor'), width: 4, height: 8),
      ),
    );
    expect(find.text('Thinking…'), findsOneWidget);
    expect(find.byKey(const Key('cursor')), findsOneWidget);
    expect(find.text('partial thought'), findsNothing);
  });
}
