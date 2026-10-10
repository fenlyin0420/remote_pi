// The bridge between the ROM's long-screenshot (scroll capture) and the chat
// transcript.
//
// The ROM drives a native overlay with synthetic (non-finger) gestures and
// keeps it aligned with the transcript (`attach`/`detach`,
// `setScrollLength`, `setScrollPosition`); when the ROM's gestures move the
// overlay, the offset comes back (`onScrollChanged`) and the transcript is
// moved there. These tests pin that contract:
//
//  - while a chat route is on top the overlay is attached with the list's
//    current content length and position (that is what enables the system's
//    long-screenshot button);
//  - the ROM's overlay motion is mirrored onto the transcript, clamped at
//    its edges;
//  - the overlay's offset and range track the transcript's position and
//    content length as they change;
//  - the moment the route is covered or popped, or the list unmounts, the
//    overlay is taken away — the button must never light up for a screen
//    that cannot be scrolled.

import 'package:app/data/screenshots/long_screenshot_adapter.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<ChatMessage> _rows(int count) => [
  for (var i = 1; i <= count; i++) AssistantMsg(id: 'a$i', text: 'message $i'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <({String method, Map<Object?, Object?>? args})>[];
  final channel = MethodChannel(LongScreenshotAdapter.channelName);

  List<({String method, Map<Object?, Object?>? args})> byMethod(String method) =>
      calls.where((c) => c.method == method).toList();

  Future<void> pumpChat(
    WidgetTester tester, {
    int rows = 40,
    Key? key,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: MessageList(
              key: key ?? UniqueKey(),
              messages: _rows(rows),
              streaming: null,
              onDecide: (id, decision) {},
              loadAttachmentBytes: (_) async => null,
              onLoadAttachment: (id, path) async {},
              onSaveAttachment: (m) async => 'saved',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    calls.clear();
    // The singleton keeps its last-synced values across tests; every test
    // ends with the list disposed (which detaches the overlay), so the next
    // test starts from a clean slate.
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void listen(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        calls.add(
          (
            method: call.method,
            args: call.arguments as Map<Object?, Object?>?,
          ),
        );
        return null;
      },
    );
  }

  MessageListState listState(WidgetTester tester) =>
      tester.state<MessageListState>(find.byType(MessageList));

  testWidgets(
    'a visible chat attaches the overlay with the list state',
    (tester) async {
      listen(tester);
      await pumpChat(tester);

      final attached = byMethod('attach');
      expect(attached.length, 1);
      final args = attached.single.args!;
      expect(args['length'], isA<int>());
      expect(args['length']! as int, greaterThan(0));
      expect(args['position'], isA<int>());
      expect(args['position']! as int, isNonNegative);

      // The channel name is the Kotlin/Dart seam: pin it literally so a
      // one-sided rename cannot compile and pass.
      expect(
        LongScreenshotAdapter.channelName,
        'work.jacobmoura.remotepi/longscreenshot',
      );

      // The ongoing sync tracks the list's settled state (physical px):
      // the range is maxScrollExtent, the position the pixels.
      final position = listState(tester).controller.position;
      expect(
        byMethod('setScrollLength').last.args?['length'],
        (position.maxScrollExtent * position.devicePixelRatio).round(),
      );
      expect(
        byMethod('setScrollPosition').last.args?['position'],
        (position.pixels * position.devicePixelRatio).round(),
      );
    },
  );

  testWidgets(
    'overlay motion is mirrored onto the transcript and clamped',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final state = listState(tester);
      state.controller.jumpTo(100);
      await tester.pumpAndSettle();
      final posCallsBefore = byMethod('setScrollPosition').length;

      final codec = const StandardMethodCodec();
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        LongScreenshotAdapter.channelName,
        codec.encodeMethodCall(
          const MethodCall('onScrollChanged', <String, Object?>{'top': 600}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();

      // 600 physical px at the test view's 3.0 pixel ratio = 200 logical
      // px, delivered the same way the ROM's overlay sends it (MethodCodec
      // bytes over the channel) — this pins the channel name, method name
      // and the `top` argument key the Kotlin side relies on.
      expect(state.controller.position.pixels, closeTo(200, 0.5));
      // The overlay is at 600 by definition, so the mirror must not send
      // its offset back: no redundant round-trip. (The move from 100 to
      // 200 makes this assertion non-trivial: without the position
      // booking, the resulting scroll would resync 600 to the channel. A
      // range resync from a settling layout is fine and expected.)
      expect(byMethod('setScrollPosition').length, posCallsBefore);

      // A step beyond the bottom clamps at the edge.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        LongScreenshotAdapter.channelName,
        codec.encodeMethodCall(
          const MethodCall('onScrollChanged', <String, Object?>{'top': 999999}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      final max = state.controller.position.maxScrollExtent;
      expect(state.controller.position.pixels, lessThanOrEqualTo(max + 0.01));
      expect(state.controller.position.pixels, closeTo(max, 5));
    },
  );

  testWidgets(
    'user scrolling is synced to the overlay, deduped when unchanged',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final state = listState(tester);

      state.controller.jumpTo(30);
      await tester.pumpAndSettle();
      final afterMove = calls.length;
      expect(calls.last.method, 'setScrollPosition');

      // A mirror landing on the same physical px the overlay already
      // reported must not chatter the channel with an identical value.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        LongScreenshotAdapter.channelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onScrollChanged', <String, Object?>{'top': 90}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(calls.length, afterMove);
    },
  );

  testWidgets(
    'growing content updates the overlay range, even while the user reads',
    (tester) async {
      listen(tester);
      await pumpChat(tester, rows: 40, key: const Key('same-list'));
      final state = listState(tester);
      final before = state.controller.position.maxScrollExtent;

      // The user scrolls up to read history: the auto-follow disengages,
      // so a growing reply moves NO pixels — the per-layout resync is the
      // only thing that can update the overlay range.
      state.controller.jumpTo(0);
      await tester.pumpAndSettle();

      // A longer transcript arrives on the same list: the content grows
      // in place.
      await pumpChat(tester, rows: 60, key: const Key('same-list'));
      await tester.pumpAndSettle();
      final after = listState(tester).controller.position.maxScrollExtent;
      expect(after, greaterThan(before));
      // The list never moved (the user is reading): the pixels are still
      // at the top, yet the range reached the overlay.
      expect(state.controller.position.pixels, 0);
      expect(
        byMethod('setScrollLength').last.args?['length'],
        (after * state.controller.position.devicePixelRatio).round(),
      );
    },
  );

  testWidgets(
    'a covering route takes the overlay away, uncovering brings it back',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      expect(byMethod('attach'), hasLength(1));
      final context = tester.element(find.byType(MessageList));

      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('on top')),
        ),
      );
      await tester.pumpAndSettle();
      // The detach happens after the attach.
      expect(byMethod('detach'), hasLength(1));
      expect(
        calls.indexWhere((c) => c.method == 'detach'),
        greaterThan(calls.indexWhere((c) => c.method == 'attach')),
      );

      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      // Uncovering re-attaches.
      expect(byMethod('attach'), hasLength(2));
    },
  );

  testWidgets(
    'leaving the chat route takes the overlay away',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      expect(byMethod('attach'), hasLength(1));

      Navigator.of(tester.element(find.byType(MessageList))).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('elsewhere')),
        ),
        (route) => false,
      );
      await tester.pumpAndSettle();

      expect(byMethod('detach'), hasLength(1));
      expect(
        calls.last,
        isA<({String method, Map<Object?, Object?>? args})>().having(
          (c) => c.method,
          'method',
          'detach',
        ),
      );
    },
  );

  testWidgets(
    'unmounting the list takes the overlay away',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      expect(byMethod('attach'), hasLength(1));

      // A plain empty page replaces the chat, so the list state (and with
      // it the tracking) goes away.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pumpAndSettle();

      expect(byMethod('detach'), hasLength(1));
    },
  );

  testWidgets(
    'a new list taking over does not get detached by the old one',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      expect(byMethod('attach'), hasLength(1));

      // Re-pumping installs a fresh MessageList (UniqueKey) with a new
      // controller: the takeover keeps the existing overlay, resyncs it
      // with the new list's state, and the old state's dispose must be a
      // no-op, not a detach of the new list's overlay.
      await pumpChat(tester);
      await tester.pumpAndSettle();

      expect(byMethod('attach'), hasLength(1));
      expect(byMethod('detach'), isEmpty);
      // The resync fired for the new list (the bookkeeping was reset on
      // takeover).
      expect(byMethod('setScrollLength'), hasLength(greaterThanOrEqualTo(2)));
    },
  );
}
