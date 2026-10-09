import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Makes the ROM's long-screenshot (scroll capture) work in this app.
///
/// A ROM's long-screenshot works by finding a scrollable view in the focused
/// window and driving it with `scrollBy` until `canScrollVertically(1)`
/// turns false, stitching the frames it captures along the way. A Flutter
/// window holds one drawing surface and no scrollable views, so the button
/// stays grey. The native side (`LongScreenshotSupport.kt`) therefore lays a
/// transparent scrollable control view over the Flutter surface and mirrors
/// its traffic through this adapter:
///
///  - the system's scroll steps arrive as `scrollBy` calls and are mirrored
///    onto the chat transcript — the frames the ROM stitches show the real
///    conversation;
///  - the transcript's live scroll state is reported back as
///    `setScrollState`, which is what the ROM reads for both the button's
///    enable check and its per-step stop condition.
///
/// Only the chat transcript is tracked — it is the only list long enough to
/// be worth capturing. On every other screen the report says "not
/// scrollable", so the button correctly stays grey.
///
/// Route liveness is read live (`route.isCurrent`) at report time — the
/// router's navigators change under us (route swaps, sheets, dialogs)
/// without re-attaching here — so a report is kicked whenever something we
/// can see changes: the list scrolls, the ROM sends a step, or the tracked
/// route's state changes (`ModalRoute.of` makes the owning State a
/// dependent of it, so `didChangeDependencies` re-runs when the route is
/// covered or uncovered).
class LongScreenshotAdapter {
  LongScreenshotAdapter({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    // The ROM only ever sends scroll steps; the handler just forwards.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'scrollBy') {
        await handleScrollBy((call.arguments?['dy'] ?? 0) as int);
        return null;
      }
      return null;
    });
  }

  /// Must match `LongScreenshotSupport.CHANNEL`.
  static const String channelName = 'work.jacobmoura.remotepi/longscreenshot';

  /// The singleton [MessageListState] wires up.
  static final LongScreenshotAdapter instance = LongScreenshotAdapter();

  final MethodChannel _channel;

  ScrollController? _controller;
  ModalRoute<dynamic>? _route;

  // The last state that was reported; a report is sent only when something
  // actually changes, so an idle conversation does not chatter the channel.
  bool _lastActive = false;
  bool _lastCanUp = false;
  bool _lastCanDown = false;

  /// Track the [controller] owned by the page at [context].
  ///
  /// Re-attaching to the same route with the same controller is a no-op
  /// apart from the state report (which only fires on a change). Attaching
  /// to a different route releases the old one first.
  void attachForRoute(ScrollController controller, BuildContext context) {
    final route = ModalRoute.of<dynamic>(context);
    if (route == null) return;

    if (!identical(_controller, controller)) {
      final old = _controller;
      if (old != null) old.removeListener(_onScroll);
      _controller = controller;
      controller.addListener(_onScroll);
    }

    _route = route;
    _reportState();
  }

  /// Stop tracking [controller] — the report goes fully grey.
  ///
  /// A no-op when a different controller is tracked (the page went away and
  /// a newer one already took over).
  void detach(ScrollController controller) {
    if (!identical(_controller, controller)) return;
    _release();
  }

  /// Mirrors one system-driven scroll step (physical pixels) onto the
  /// tracked list.
  ///
  /// A no-op when there is nothing to scroll — but it still reports the
  /// resulting state, which resets the native side's stale-cache safety
  /// valve, and lets the ROM's stop condition see the true edge.
  Future<void> handleScrollBy(int dyPx) async {
    final c = _controller;
    if (_isOnTop && c != null && c.hasClients) {
      final position = c.position;
      final dy = dyPx / position.devicePixelRatio;
      c.jumpTo((position.pixels + dy).clamp(0.0, position.maxScrollExtent));
    }
    // A step that did not move anything (a clamp at the edge) still reports
    // its state — bypassing the dedupe, so the native side's stale-cache
    // valve is reset on every step the ROM actually sent.
    _reportState(force: dyPx != 0);
  }

  // -----------------------------------------------------------------------

  /// True while the tracked route is the top of its navigator's stack.
  bool get _isOnTop => _route?.isCurrent ?? false;

  void _onScroll() => _reportState();

  /// Forgets the tracked controller and route and reports fully grey.
  /// Idempotent.
  void _release() {
    final c = _controller;
    if (c != null) c.removeListener(_onScroll);
    _controller = null;
    _route = null;
    _reportState();
  }

  /// Reports the tracked list's live scroll state to the native side.
  ///
  /// `active` is true only while the tracked route is on top AND the list is
  /// mounted — that is the whole of "the focused window can be long-
  /// screenshotted", as the ROM sees it.
  ///
  /// A report goes out only when the state changed, unless [force] — the
  /// dedupe keeps an idle conversation from chattering the channel, but a
  /// forced report is how the native stale-cache valve learns Dart is still
  /// alive after clamped (no-op) steps.
  void _reportState({bool force = false}) {
    final c = _controller;
    final active = _isOnTop && c != null && c.hasClients;
    final canUp = active && c.position.pixels > 0;
    final canDown =
        active && c.position.pixels < c.position.maxScrollExtent;
    if (!force &&
        active == _lastActive &&
        canUp == _lastCanUp &&
        canDown == _lastCanDown) {
      return;
    }
    _lastActive = active;
    _lastCanUp = canUp;
    _lastCanDown = canDown;
    unawaited(_channel
        .invokeMethod<void>(
          'setScrollState',
          {'active': active, 'canUp': canUp, 'canDown': canDown},
        )
        .catchError((Object _) {}));
  }
}
