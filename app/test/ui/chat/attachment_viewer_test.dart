// Closing the full-screen viewer must not raise the soft keyboard.
//
// The failure this pins down: the composer keeps its focus node from an
// earlier tap (the IME was hidden, the node was not), and popping a route
// hands focus back to whatever the underlying scope had — so every preview the
// user closed ended with a keyboard covering the chat. Dropping focus on both
// sides of the route is what makes "come back, keyboard stays down" the
// default.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/attachment_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _card = AttachmentMsg(
  id: 'att_tc-1',
  name: 'shot.png',
  path: '/home/p/shot.png',
  mime: 'image/png',
  size: 10,
  blobName: 'att_tc-1.bin',
);

void main() {
  testWidgets('leaving the viewer leaves the composer unfocused', (tester) async {
    final composer = FocusNode(debugLabel: 'composer');
    addTearDown(composer.dispose);
    final openButton = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Stands in for the chat composer: a focused text field is what
              // raises the soft keyboard.
              TextField(focusNode: composer, decoration: const InputDecoration()),
              Builder(
                builder: (context) => TextButton(
                  key: openButton,
                  onPressed: () => AttachmentViewer.open(
                    context,
                    message: _card,
                    loadBytes: (_) async => null,
                    onSave: (_) async => 'Pictures/Remote Pi/shot.png',
                  ),
                  child: const Text('open'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // The real situation: the user tapped the composer at some point, so the
    // field holds focus (the IME may be down; focus is not).
    composer.requestFocus();
    await tester.pump();
    expect(composer.hasFocus, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('viewer-save')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // Back in the chat: the viewer is gone AND the keyboard stays down.
    expect(find.byKey(const Key('viewer-save')), findsNothing);
    expect(composer.hasFocus, isFalse);
  });
}
