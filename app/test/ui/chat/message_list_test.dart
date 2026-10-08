// The transcript's scroll anchoring.
//
// `reverse: true` keeps the newest message at the bottom edge, which means the
// viewport follows new content for free — including when the user does NOT want
// it to. These tests pin the rule: incoming content never drags a user who is
// reading history, while a message they send themselves brings them back.
//
// They also pin the other half of "the list does not move": an image row's
// height is decided before its bytes land, so a decode finishing mid-scroll
// cannot push the content under the finger (see `image_frame.dart`).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/attachment_card.dart';
import 'package:app/ui/chat/widgets/message_list.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real 300×2400 PNG (a phone screenshot), inline-able because it is a 1-bit
/// palette file.
final _tallPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAASwAAAlgAQAAAAAaczeoAAAAcUlEQVR42u3BAQ0AAADCoPdP'
  'bQ8HFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPwYba8AAaU4yKwAAAAA'
  'SUVORK5CYII=',
);

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
  await _pumpWithStreaming(tester, messages, null);
}

Future<void> _pumpWithStreaming(
  WidgetTester tester,
  List<ChatMessage> messages,
  String? streamingText,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 200,
          child: MessageList(
            messages: messages,
            streaming: streamingText == null
                ? null
                : StreamingMessage(inReplyTo: 'u1', buffer: streamingText),
            onDecide: (_, _) {},
            loadAttachmentBytes: (_) async => null,
            onLoadAttachment: (_, _) async {},
            onSaveAttachment: (_) async => 'Downloads/Remote Pi/x',
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

  testWidgets('an image that finishes loading does not resize the transcript', (
    tester,
  ) async {
    // The whole point: the attachment's bytes arrive a frame or two after the
    // row is laid out, and the list must not notice. While the row grew from its
    // load placeholder to the thumbnail's height, every image the viewport
    // crossed pushed everything below it down — which is what stopped flings
    // dead and dragged a slow drag backwards.
    final gate = Completer<Uint8List?>();
    final list = GlobalKey<MessageListState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: MessageList(
              key: list,
              messages: [
                ..._rows(12),
                AttachmentMsg(
                  id: 'att1',
                  name: 'shot.png',
                  path: '/home/p/shot.png',
                  mime: 'image/png',
                  size: 4096,
                  blobName: 'att1.bin',
                ),
                AssistantMsg(id: 'a13', text: 'message 13'),
              ],
              streaming: null,
              onDecide: (_, _) {},
              loadAttachmentBytes: (_) => gate.future,
              onLoadAttachment: (_, _) async {},
              onSaveAttachment: (_) async => 'Downloads/Remote Pi/x',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final before = list.currentState!.controller.position;
    final extent = before.maxScrollExtent;
    expect(extent, greaterThan(0), reason: 'the transcript must be scrollable');
    final pixels = before.pixels;

    gate.complete(_tallPng);
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget, reason: 'the image did land');
    final after = list.currentState!.controller.position;
    expect(after.maxScrollExtent, extent);
    expect(after.pixels, pixels);
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

  testWidgets(
    'a plain slow drag up wins against the follow while a reply streams',
    (tester) async {
      await _pump(tester, _rows(30));
      expect(find.text('message 30'), findsOneWidget, reason: 'starts pinned');

      // A finger moving a few pixels per frame, with the streaming bubble
      // growing underneath it — the exact conditions under which the
      // post-frame follow used to jump back to the bottom (killing the drag)
      // on every frame, so only a violent flick could break away.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      for (var i = 1; i <= 12; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await _pumpWithStreaming(tester, _rows(30), 'streaming $i');
      }
      await gesture.up();
      // Not pumpAndSettle: the streaming bubble's cursor blinks forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text('message 30'),
        findsNothing,
        reason: 'the drag must have taken the viewport into history',
      );
      expect(_newestVisible(30), lessThan(30));
    },
  );

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

  // An image a TOOL produced (a screenshot, a diagram it read) is not a message
  // of its own: it belongs inside that tool's row, the place the TUI draws it.
  // The fallback matters too — an attachment whose tool row is not in this
  // slice of history must keep a card of its own rather than vanish.
  group('a tool image rides inside its tool row', () {
    const screenTool = ToolEvent(
      id: 'tc_shot',
      toolCallId: 'tc_shot',
      tool: 'computer_screen',
      args: {'region': {'x': 0, 'y': 0, 'w': 100, 'h': 100}},
      status: ToolEventStatus.completed,
      result: 'Virtual desktop screenshot (full screen 1920x1080).',
    );

    AttachmentMsg shot() => const AttachmentMsg(
      id: 'att_tc_shot',
      name: 'computer_screen-shot.png',
      path: '/p/shot.png',
      mime: 'image/png',
      size: 4096,
      toolCallId: 'tc_shot',
    );

    testWidgets('the tool row carries it and there is no second card', (
      tester,
    ) async {
      await _pump(tester, [screenTool, shot()]);

      final card = tester.widget<ToolRequestCard>(
        find.byType(ToolRequestCard),
      );
      expect(card.attachments.map((a) => a.id), ['att_tc_shot']);
      expect(
        find.descendant(
          of: find.byType(ToolRequestCard),
          matching: find.byType(AttachmentCard),
        ),
        findsOneWidget,
      );
    });

    // The list only builds what is on screen, so these two keep the tool row
    // last (and the case down to two rows) to have both in the tree.
    testWidgets('a card with no tool call keeps its own row', (tester) async {
      await _pump(tester, [
        // A `send_to_phone` hand-off: no tool call, and no tool card either.
        const AttachmentMsg(
          id: 'att_x',
          name: 'chart.png',
          path: '/p/chart.png',
          mime: 'image/png',
          size: 4096,
        ),
        screenTool,
      ]);

      expect(
        tester.widget<ToolRequestCard>(find.byType(ToolRequestCard)).attachments,
        isEmpty,
      );
      expect(find.byType(AttachmentCard), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ToolRequestCard),
          matching: find.byType(AttachmentCard),
        ),
        findsNothing,
      );
    });

    testWidgets('a card whose tool row is missing keeps its own row', (
      tester,
    ) async {
      await _pump(tester, [
        // A tool call that is not in this slice of history (trimmed away, or a
        // `file_get` answering for a card this replay never carried). Losing
        // the picture would be far worse than a card in the wrong place.
        const AttachmentMsg(
          id: 'att_tc_gone',
          name: 'old-shot.png',
          path: '/p/old.png',
          mime: 'image/png',
          size: 4096,
          toolCallId: 'tc_gone',
        ),
        screenTool,
      ]);

      expect(
        tester.widget<ToolRequestCard>(find.byType(ToolRequestCard)).attachments,
        isEmpty,
      );
      expect(find.byType(AttachmentCard), findsOneWidget);
    });
  });
}
