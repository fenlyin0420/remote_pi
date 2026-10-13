// LOCAL (fenlyin) — the per-row "time · model" caption: shown under every row
// that carries a timestamp when the per-room toggle is on, hidden when the
// toggle is off or the row has no timestamp (older sessions / Pi builds).
//
// The model part is ASSISTANT-ONLY: it identifies the model that generated
// the reply. User rows show the time only, and their caption is
// right-aligned under the (right-aligned) bubble.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _ts = DateTime(2026, 10, 13, 14, 5, 12);

Future<void> _pump(
  WidgetTester tester,
  List<ChatMessage> messages, {
  bool showMeta = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: MessageList(
            messages: messages,
            streaming: null,
            onDecide: (_, _) {},
            loadAttachmentBytes: (_) async => null,
            onLoadAttachment: (_, _) async {},
            onSaveAttachment: (_) async => 'x',
            showMeta: showMeta,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('an assistant row with ts + model shows "time · model"', (
    tester,
  ) async {
    await _pump(
      tester,
      [
        AssistantMsg(id: 'a1', text: 'ok', ts: _ts, model: 'Qwen3.8-27B'),
      ],
    );
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('2026-10-13 14:05:12 · Qwen3.8-27B'), findsOneWidget);
  });

  testWidgets('a user row shows the time only — never a model', (
    tester,
  ) async {
    await _pump(
      tester,
      [
        // Even a model-bearing user row (older Pi builds stamped one) must
        // render time-only.
        UserMsg(id: 'u1', text: 'hi', ts: _ts, model: 'Qwen3.8-27B'),
      ],
    );
    expect(find.text('hi'), findsOneWidget);
    expect(find.text('2026-10-13 14:05:12'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('a row with ts but no model shows the time only', (tester) async {
    await _pump(
      tester,
      [AssistantMsg(id: 'a1', text: 'ok', ts: _ts)],
    );
    expect(find.text('2026-10-13 14:05:12'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('showMeta=false hides the caption (the row stays)', (
    tester,
  ) async {
    await _pump(
      tester,
      [
        AssistantMsg(
          id: 'a1',
          text: 'ok',
          ts: _ts,
          model: 'Qwen3.8-27B',
        ),
      ],
      showMeta: false,
    );
    expect(find.text('ok'), findsOneWidget);
    expect(find.textContaining('2026-10-13'), findsNothing);
  });

  testWidgets('a row without ts gets no caption (older sessions)', (
    tester,
  ) async {
    await _pump(
      tester,
      [UserMsg(id: 'u1', text: 'hi')],
    );
    expect(find.text('hi'), findsOneWidget);
    expect(find.textContaining('2026-10-13'), findsNothing);
  });
}
