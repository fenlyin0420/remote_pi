// VisibleSession — the bit that keeps notifications quiet for the chat on
// screen. Its two ordering hazards are pinned here (backgrounded vs. leaving,
// and a replacement chat tearing down after the newcomer mounted).

import 'package:app/routing/visible_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the foreground + mounted + matching session counts as viewing',
      () {
    final visible = VisibleSession();

    expect(visible.isViewing('epk', 'room'), isFalse); // nothing mounted

    visible.enterChat('epk', 'room');
    expect(visible.isViewing('epk', 'room'), isTrue);
    expect(visible.isViewing('epk', 'other'), isFalse);
    expect(visible.isViewing('other', 'room'), isFalse);

    // Backgrounded: the chat is still mounted, but not in front of the user.
    visible.setForeground(false);
    expect(visible.isViewing('epk', 'room'), isFalse);

    visible.setForeground(true);
    expect(visible.isViewing('epk', 'room'), isTrue);
  });

  test('leaving a chat only clears the marker it still owns', () {
    final visible = VisibleSession();
    visible.enterChat('epk', 'room-b');

    // Stale teardown of the chat we replaced must not un-mark the new one.
    visible.leaveChat('epk', 'room-a');
    expect(visible.isViewing('epk', 'room-b'), isTrue);

    visible.leaveChat('epk', 'room-b');
    expect(visible.chat, isNull);
    expect(visible.isViewing('epk', 'room-b'), isFalse);
  });

  test('notifies listeners on real changes only', () {
    final visible = VisibleSession();
    var notifications = 0;
    visible.addListener(() => notifications++);

    visible.enterChat('epk', 'room');
    visible.enterChat('epk', 'room'); // no-op
    visible.setForeground(true); // already true
    visible.setForeground(false);

    expect(notifications, 2);
  });
}
