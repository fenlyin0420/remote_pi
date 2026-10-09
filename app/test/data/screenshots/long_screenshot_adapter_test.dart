// The bridge between the ROM's long-screenshot (scroll capture) and the chat
// transcript.
//
// The ROM drives a native control view and reads a cached scroll state
// (`setScrollState` reports); these tests pin the contract that makes the
// button work and stop at the right edge:
//
//  - while a chat route is on top and its list can still scroll, the report
//    says scrollable (that is what enables the system's long-screenshot
//    button);
//  - the system's scroll steps are mirrored onto the transcript, clamped at
//    its edges;
//  - the moment the route is covered or popped, or the list unmounts, the
//    report goes grey — the button must never light up for a screen that
//    cannot be scrolled.

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

  final reports = <Map<Object?, Object?>>[];
  final channel = MethodChannel(LongScreenshotAdapter.channelName);

  Map<Object?, Object?> lastReport() => reports.last;

  Future<void> pumpChat(WidgetTester tester, {int rows = 40}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: MessageList(
              key: UniqueKey(),
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
    reports.clear();
    // The singleton keeps its last-reported state across tests; every test
    // ends with the list disposed (which reports grey), so the next test
    // starts from a clean slate.
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void listen(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        if (call.method == 'setScrollState') {
          reports.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      },
    );
  }

  MessageListState listState(WidgetTester tester) =>
      tester.state<MessageListState>(find.byType(MessageList));

  testWidgets(
    'a visible chat with room below reports scrollable down',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      listState(tester).controller.jumpTo(100);
      await tester.pumpAndSettle();

      final last = lastReport();
      expect(last['active'], isTrue);
      expect(last['canUp'], isTrue);
      expect(last['canDown'], isTrue);
    },
  );

  testWidgets(
    'a chat pinned at the bottom reports scrollable up only',
    (tester) async {
      listen(tester);
      await pumpChat(tester); // auto-follows to the bottom

      final last = lastReport();
      expect(last['active'], isTrue);
      expect(last['canUp'], isTrue);
      expect(last['canDown'], isFalse);
    },
  );

  testWidgets(
    'system scroll steps are mirrored onto the transcript and clamped',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final state = listState(tester);
      state.controller.jumpTo(100);
      await tester.pumpAndSettle();

      // The ROM steps in physical pixels; the adapter converts at the
      // surface's pixel ratio (3.0 in the default test view).
      final dpr = tester.view.devicePixelRatio;
      await LongScreenshotAdapter.instance.handleScrollBy((50 * dpr).round());
      await tester.pumpAndSettle();
      expect(state.controller.position.pixels, closeTo(150, 0.5));

      await LongScreenshotAdapter.instance.handleScrollBy(100000);
      await tester.pumpAndSettle();
      // Clamped at the bottom edge — the ROM's next canScroll check then
      // reports false and stops the capture. The extent can drift a couple
      // of pixels across layouts, so pin the edge with a tolerance.
      final max = state.controller.position.maxScrollExtent;
      expect(state.controller.position.pixels, lessThanOrEqualTo(max + 0.01));
      expect(state.controller.position.pixels, closeTo(max, 5));

      final last = lastReport();
      expect(last['active'], isTrue);
      expect(last['canDown'], isFalse);
    },
  );

  testWidgets(
    'a route on top greys the report, uncovering re-enables it',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final context = tester.element(find.byType(MessageList));

      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('overlay')),
        ),
      );
      await tester.pumpAndSettle();
      expect(lastReport()['active'], isFalse);

      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(lastReport()['active'], isTrue);
    },
  );

  testWidgets(
    'scroll steps are ignored while the route is covered',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final state = listState(tester);
      state.controller.jumpTo(100);
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(MessageList));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('overlay')),
        ),
      );
      await tester.pumpAndSettle();

      await LongScreenshotAdapter.instance.handleScrollBy(50);
      await tester.pumpAndSettle();
      expect(state.controller.position.pixels, 100);
    },
  );

  testWidgets(
    'leaving the chat route greys the report',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final context = tester.element(find.byType(MessageList));

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('elsewhere')),
        ),
        (route) => false,
      );
      await tester.pumpAndSettle();

      final last = lastReport();
      expect(last['active'], isFalse);
      expect(last['canUp'], isFalse);
      expect(last['canDown'], isFalse);
    },
  );

  testWidgets(
    'unmounting the list greys the report',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      expect(lastReport()['active'], isTrue);

      // An empty room renders the placeholder instead of the list, so the
      // list state (and with it the tracking) goes away.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pumpAndSettle();

      final last = lastReport();
      expect(last['active'], isFalse);
      expect(last['canUp'], isFalse);
      expect(last['canDown'], isFalse);
    },
  );

  testWidgets(
    'an inbound platform scrollBy drives the list end to end',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final state = listState(tester);
      state.controller.jumpTo(100);
      await tester.pumpAndSettle();

      // Deliver the step exactly the way the ROM's control view sends it
      // (MethodCodec bytes over the channel) — this pins the channel name,
      // method name and the `dy` argument key the Kotlin side relies on.
      final codec = const StandardMethodCodec();
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        LongScreenshotAdapter.channelName,
        codec.encodeMethodCall(
          const MethodCall('scrollBy', <String, Object?>{'dy': 90}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();

      // 90 physical px at the test view's 3.0 pixel ratio = 30 logical px.
      expect(state.controller.position.pixels, closeTo(130, 0.5));
    },
  );

  testWidgets(
    'a clamped step at the edge still reports (resets the native valve)',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final state = listState(tester);

      // Park at the bottom, where any further down-step clamps to a no-op.
      final max = state.controller.position.maxScrollExtent;
      state.controller.jumpTo(max);
      await tester.pumpAndSettle();
      final before = reports.length;

      // The step moves nothing, but it must still reach the native side as a
      // report — that is what keeps the ROM's stale-cache valve from
      // tripping on a healthy Dart side parked at the edge.
      await LongScreenshotAdapter.instance.handleScrollBy(100000);
      await tester.pumpAndSettle();
      expect(reports.length, before + 1);
      expect(state.controller.position.pixels, lessThanOrEqualTo(max + 0.01));
    },
  );

  testWidgets(
    'unchanged state is not re-reported',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      final state = listState(tester);

      state.controller.jumpTo(10);
      await tester.pumpAndSettle();
      final afterMove = reports.length;
      expect(afterMove, 2); // attach + the move

      // A zero-step (the ROM's stop probe at the edge) must not chatter the
      // channel with an identical report.
      await LongScreenshotAdapter.instance.handleScrollBy(0);
      await tester.pumpAndSettle();
      expect(reports.length, afterMove);
    },
  );

  testWidgets(
    'a new list taking over does not get greyed by the old one\'s detach',
    (tester) async {
      listen(tester);
      await pumpChat(tester);
      expect(lastReport()['active'], isTrue);

      // Re-pumping installs a fresh MessageList with a new controller: the
      // takeover attaches first, then the old state disposes. Its detach
      // must be a no-op, not a grey-out of the new list.
      await pumpChat(tester);
      await tester.pumpAndSettle();

      expect(lastReport()['active'], isTrue);
    },
  );
}
