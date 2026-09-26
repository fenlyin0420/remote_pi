// The user bubble for an uploaded text file: name, where the Pi put it, and
// the caption — no image-style preview (the content never came back).

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/file_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(home: Scaffold(body: Center(child: child))),
);

void main() {
  testWidgets('shows the file name, the landed path and the caption', (
    tester,
  ) async {
    await _pump(
      tester,
      const FileBubble(
        file: MessageFile(
          name: 'report.csv',
          path: '/home/p/.pi/remote/uploads/main/report.csv',
        ),
        caption: 'what changed?',
      ),
    );

    expect(find.byKey(const Key('file-bubble-name')), findsOneWidget);
    expect(find.text('report.csv'), findsOneWidget);
    expect(find.byKey(const Key('file-bubble-path')), findsOneWidget);
    expect(
      find.text('/home/p/.pi/remote/uploads/main/report.csv'),
      findsOneWidget,
    );
    expect(find.text('what changed?'), findsOneWidget);
  });

  testWidgets('a pending upload (no path yet) shows the name only', (
    tester,
  ) async {
    await _pump(tester, const FileBubble(file: MessageFile(name: 'notes.md')));

    expect(find.text('notes.md'), findsOneWidget);
    expect(find.byKey(const Key('file-bubble-path')), findsNothing);
  });
}
