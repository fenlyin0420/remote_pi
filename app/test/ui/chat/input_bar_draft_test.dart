// Per-room composer draft persistence in the InputBar: hydration of a stored
// draft on mount (and when the room key resolves a few frames late), debounced
// save-on-keystroke, immediate clear, and the dispose flush.

import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '';

  Future<void> pumpBar(
    WidgetTester tester, {
    String initialDraft = '',
    void Function(String text)? onDraftChanged,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            initialDraft: initialDraft,
            onDraftChanged: onDraftChanged,
            onSend: (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('stored draft is hydrated into the field on mount', (tester) async {
    await pumpBar(tester, initialDraft: 'left unfinished');
    await tester.pumpAndSettle();
    expect(fieldText(tester), 'left unfinished');
  });

  testWidgets('typing reports the draft after the debounce window', (
    tester,
  ) async {
    final saved = <String>[];
    await pumpBar(tester, onDraftChanged: saved.add);
    await tester.enterText(find.byType(TextField), 'draft one');
    expect(saved, isEmpty, reason: 'still inside the debounce window');
    await tester.pump(const Duration(milliseconds: 450));
    expect(saved, ['draft one']);
  });

  testWidgets('clearing the field reports the clear immediately', (
    tester,
  ) async {
    final saved = <String>[];
    await pumpBar(
      tester,
      initialDraft: 'stale draft',
      onDraftChanged: saved.add,
    );
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(); // no pump(450ms) — the clear must not wait out the debounce
    expect(saved, [''], reason: 'a sent/cleared draft must not linger');
  });

  testWidgets('disposing the bar flushes a pending debounced write', (
    tester,
  ) async {
    final saved = <String>[];
    await pumpBar(tester, onDraftChanged: saved.add);
    await tester.enterText(find.byType(TextField), 'typed then left');
    await tester.pump(const Duration(milliseconds: 200)); // < debounce
    expect(saved, isEmpty);
    // Leave the room: the bar unmounts (route pop / room switch).
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(saved, ['typed then left']);
  });

  testWidgets('late room-key resolution re-hydrates an empty field', (
    tester,
  ) async {
    // Peer record not loaded yet → no key → empty draft…
    await pumpBar(tester);
    expect(fieldText(tester), '');
    // …then the key resolves and the stored draft arrives via a rebuild.
    await pumpBar(tester, initialDraft: 'the stored draft');
    await tester.pump();
    expect(fieldText(tester), 'the stored draft');
  });

  testWidgets('late hydration never clobbers text the user already typed', (
    tester,
  ) async {
    await pumpBar(tester);
    await tester.enterText(find.byType(TextField), 'fresh typing');
    await pumpBar(tester, initialDraft: 'the stored draft');
    await tester.pump();
    expect(fieldText(tester), 'fresh typing');
  });

  testWidgets('no persistence is wired when onDraftChanged is null', (
    tester,
  ) async {
    await pumpBar(tester, initialDraft: 'draft', onDraftChanged: null);
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    // No exception is the assertion: the persistence paths are inert.
    expect(find.byType(InputBar), findsNothing);
  });
}
