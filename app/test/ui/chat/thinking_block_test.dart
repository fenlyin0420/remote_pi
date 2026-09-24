// The thinking block is COLLAPSED BY DEFAULT — model reasoning must never push
// the answer off the (phone-sized) screen until the user asks for it. These
// tests pin that default plus the in-place expand/collapse behaviour, for both
// shapes: a persisted row (`ThinkingBubble`) and the live streamed block.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

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
