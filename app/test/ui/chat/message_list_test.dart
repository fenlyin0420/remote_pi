// The transcript's scroll anchoring.
//
// `reverse: true` keeps the newest message at the bottom edge, which means the
// viewport follows new content for free — including when the user does NOT want
// it to. These tests pin the rule: incoming content never drags a user who is
// reading history, while a message they send themselves brings them back.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<ChatMessage> _rows(int count) => [
  for (var i = 1; i <= count; i++) AssistantMsg(id: 'a$i', text: 'message $i'),
];

/// Index of the newest message currently on screen — the anchor the user is
/// reading at.
int _newestVisible(int count) {
  for (var i = count; i >= 1; i--) {
    if (find.text('message $i').evaluate().isNotEmpty) return i;
  }
  return 0;
}

Future<void> _pump(WidgetTester tester, List<ChatMessage> messages) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 200,
          child: MessageList(
            messages: messages,
            streaming: null,
            onDecide: (_, _) {},
          ),
        ),
      ),
    ),
  );
  // The list places itself on the newest message in a post-layout callback (it
  // is laid out from the top), so one more frame shows the result.
  await tester.pump();
}

void main() {
  testWidgets('opens at the newest message', (tester) async {
    await _pump(tester, _rows(30));
    expect(find.text('message 30'), findsOneWidget);
  });

  testWidgets('incoming content does not pull the viewport down', (
    tester,
  ) async {
    await _pump(tester, _rows(30));

    // A reversed list walks into history when dragged DOWN.
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();

    final anchor = _newestVisible(30);
    expect(
      anchor,
      lessThan(30),
      reason: 'the test needs to be reading history, not the newest message',
    );
    final before = tester.getRect(find.text('message $anchor'));

    // A message arrives while the user is up there.
    await _pump(tester, _rows(31));

    expect(
      tester.getRect(find.text('message $anchor')).top,
      closeTo(before.top, 0.5),
      reason: 'the row under the eye must not move',
    );
    expect(
      _newestVisible(31),
      anchor,
      reason: 'the viewport must not drift toward the newest message',
    );
  });

  testWidgets('a message the user sends brings them back to the newest', (
    tester,
  ) async {
    await _pump(tester, _rows(30));
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(find.text('message 30'), findsNothing, reason: 'reading history');

    await _pump(tester, [
      ..._rows(30),
      // The optimistic row SyncService writes on send.
      const UserMsg(
        id: 'u1',
        text: 'hello there',
        status: UserMsgStatus.pending,
      ),
    ]);
    // Not pumpAndSettle: the optimistic bubble's spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('hello there'), findsOneWidget);
    expect(find.text('message 30'), findsOneWidget);
  });
}
