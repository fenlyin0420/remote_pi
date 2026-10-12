// Plan/32 — the compaction system bubble renders the label and the reclaimed
// token count (distinct from user/assistant bubbles).
//
// LOCAL (fenlyin): the recap summary is a COLLAPSIBLE block — collapsed by
// default (the header stands alone until the user taps it, the same pattern
// as ThinkingBlock); expansion is local state kept in the route's PageStorage.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  Future<void> pump(WidgetTester tester, CompactionMsg msg) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CompactionBubble(msg))),
    );
  }

  testWidgets('collapsed by default: header + tokens, no summary', (tester) async {
    await pump(
      tester,
      const CompactionMsg(
        id: 'c1',
        summary: 'Recapped the long thread',
        tokensBefore: 12000,
      ),
    );

    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.text('~12000 tokens'), findsOneWidget);
    // Collapsed: the recap is hidden until the user taps the header.
    expect(find.text('Recapped the long thread'), findsNothing);
    expect(find.byIcon(LucideIcons.chevronRight), findsOneWidget);
  });

  testWidgets('tapping the header expands the summary and flips the chevron', (
    tester,
  ) async {
    await pump(
      tester,
      const CompactionMsg(
        id: 'c1',
        summary: 'Recapped the long thread',
        tokensBefore: 12000,
      ),
    );
    await tester.tap(find.text('Context compacted'));
    await tester.pumpAndSettle();

    expect(find.text('Recapped the long thread'), findsOneWidget);
    expect(find.text('~12000 tokens'), findsOneWidget);
    expect(find.byIcon(LucideIcons.chevronDown), findsOneWidget);

    // Tapping again collapses it (and the state survives, being content-
    // addressed in PageStorage).
    await tester.tap(find.text('Context compacted'));
    await tester.pumpAndSettle();
    expect(find.text('Recapped the long thread'), findsNothing);
    expect(find.byIcon(LucideIcons.chevronRight), findsOneWidget);
  });

  testWidgets('omits the token line when tokensBefore is null', (tester) async {
    await pump(
      tester,
      const CompactionMsg(id: 'c2', summary: 'done'),
    );

    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.text('done'), findsNothing);
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('a summary-less row is not tappable (no chevron, no body)', (
    tester,
  ) async {
    await pump(tester, const CompactionMsg(id: 'c3', summary: ''));

    expect(find.text('Context compacted'), findsOneWidget);
    // The recap-less header has nothing to expand: no chevron (the leading
    // check icon is always there), and tapping changes nothing.
    expect(find.byIcon(LucideIcons.chevronRight), findsNothing);
    await tester.tap(find.text('Context compacted'));
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.chevronRight), findsNothing);
  });
}
