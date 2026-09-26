// Plan/30 + tablet fix — the Camera / Photo Library / File attach sheet must
// close when the tablet's selected session changes out from under it, and must
// keep File reachable on a model that cannot take images.

import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/widgets/attach_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('attach sheet closes when the session changes', (tester) async {
    final selection = SessionSelection()..select('e1', 'r1', 'Chat 1');
    addTearDown(selection.dispose);

    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<SessionSelection>.value(
          value: selection,
          child: Builder(
            builder: (context) {
              pageContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );

    // ignore: unawaited_futures
    showAttachSheet(pageContext);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attach-camera')), findsOneWidget);
    expect(find.byKey(const Key('attach-gallery')), findsOneWidget);
    expect(find.byKey(const Key('attach-file')), findsOneWidget);

    // Switch session on the tablet master list → sheet must dismiss.
    selection.select('e2', 'r2', 'Chat 2');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attach-camera')), findsNothing);
  });

  testWidgets('a text-only model greys out the image sources, never File', (
    tester,
  ) async {
    final selection = SessionSelection()..select('e1', 'r1', 'Chat 1');
    addTearDown(selection.dispose);

    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<SessionSelection>.value(
          value: selection,
          child: Builder(
            builder: (context) {
              pageContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );

    // ignore: unawaited_futures
    showAttachSheet(pageContext, imageBlocked: true);
    await tester.pumpAndSettle();

    ListTile option(String key) => tester.widget<ListTile>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(ListTile),
      ),
    );
    expect(option('attach-camera').enabled, isFalse);
    expect(option('attach-gallery').enabled, isFalse);
    expect(option('attach-file').enabled, isTrue);
    expect(find.text('The current model does not accept images.'), findsOneWidget);
  });
}
