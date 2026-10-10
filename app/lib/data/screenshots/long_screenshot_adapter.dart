import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Makes the ROM's long-screenshot (scroll capture) work in this app.
///
/// How the ROM does it (verified against Xianyu's MIUI adaptation write-up
/// and the fit_system_screenshot plugin): the capture feature finds a
/// scrollable view in the focused window, then drives it with synthetic
/// pointer events of a non-finger tool type, stitching the frames it
/// captures along the way. A Flutter window has no scrollable views, so the
/// button stays grey. The native side (`LongScreenshotSupport.kt`) therefore
/// lays a transparent scrollable overlay on top of the Flutter surface —
/// added while this adapter tracks a transcript, removed otherwise — and the
/// two sides keep each other aligned through this channel:
///
///  - the overlay's scrollable RANGE mirrors the transcript's
///    maxScrollExtent (`setScrollLength`), so the ROM's loop ends exactly
///    where the transcript ends;
///  - the overlay's offset mirrors the transcript's position
///    (`setScrollPosition`), so a capture starts where the user is looking;
///  - when the ROM's synthetic gestures move the overlay, the offset comes
///    back (`onScrollChanged`) and the real transcript is moved there.
///
/// Only the chat transcript is tracked — it is the only list long enough to
/// be worth capturing. On every other screen the overlay is absent, so the
/// button correctly stays grey.
class LongScreenshotAdapter {
  LongScreenshotAdapter({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    // The native side reports the overlay's offset while the ROM's
    // synthetic gestures are scrolling it.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onScrollChanged') {
        await _handleOverlayScroll((call.arguments?['top'] ?? 0) as int);
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

  // The last values the native side was told; a value is resent only when
  // it actually changes, so an idle conversation does not chatter the
  // channel.
  int _lastLengthPx = -1;
  int _lastPositionPx = -1;

  // Whether the native overlay is in the window right now.
  bool _overlayAttached = false;

  /// Track the [controller] owned by the page at [context].
  ///
  /// Re-attaching to the same route with the same controller is a no-op
  /// apart from the sync (which only fires on a change). Attaching to a
  /// different route or controller releases the old one first.
  void attachForRoute(ScrollController controller, BuildContext context) {
    final route = ModalRoute.of<dynamic>(context);
    if (route == null) return;

    final tookOver = !identical(_controller, controller);
    final old = _controller;
    if (old != null) old.removeListener(_onScroll);
    if (tookOver) {
      _lastLengthPx = -1;
      _lastPositionPx = -1;
    }
    _controller = controller;
    controller.addListener(_onScroll);

    final sameRoute = identical(_route, route);
    if (!sameRoute) _route = route;

    if (_isOnTop) {
      if (!_overlayAttached) _scheduleAttach();
    } else if (_overlayAttached) {
      _detachOverlay();
    }
  }

  /// Stop tracking [controller] — the overlay goes away (report fully
  /// grey).
  ///
  /// A no-op when a different controller is tracked (the page went away and
  /// a newer one already took over).
  void detach(ScrollController controller) {
    if (!identical(_controller, controller)) return;
    _release();
  }

  /// Re-syncs the overlay with the tracked list's current state.
  ///
  /// [MessageListState] calls this after every layout: the content length
  /// can change while the list's pixels do not (a streaming reply growing
  /// while the user reads history), which the position listener alone
  /// never sees.
  void resync() {
    if (!_isOnTop) {
      // Belt-and-braces for a covering route: the dependency re-run of
      // [attachForRoute] handles the normal case; this catches the overlay
      // if it were ever left up on a covered route.
      if (_overlayAttached) _detachOverlay();
      return;
    }
    if (!_overlayAttached) return;
    _sync();
  }

  // -----------------------------------------------------------------------

  /// True while the tracked route is the top of its navigator's stack.
  bool get _isOnTop => _route?.isCurrent ?? false;

  /// The overlay can only be added once the scroll position exists, which
  /// is after the first frame — so defer the attach to the frame's end.
  /// [MessageListState] also attaches on its first scroll notification as
  /// a backstop.
  void _scheduleAttach() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final c = _controller;
      if (!_isOnTop || _overlayAttached || c == null || !c.hasClients) return;
      _attachOverlay();
    });
  }

  /// Adds the native overlay with the list's current state.
  void _attachOverlay() {
    final c = _controller;
    if (!_isOnTop || c == null || !c.hasClients) return;
    _sync();
    final position = c.position;
    final dpr = position.devicePixelRatio;
    final lengthPx = (position.maxScrollExtent * dpr).round();
    final positionPx = (position.pixels * dpr).round();
    unawaited(_channel
        .invokeMethod<void>(
          'attach',
          {'length': lengthPx, 'position': positionPx},
        )
        .catchError((Object _) {
          // The overlay never went up: clear the flag so a later trigger
          // (scroll notification, dependency re-run) retries the attach.
          _overlayAttached = false;
          return null;
        }));
    _overlayAttached = true;
  }

  /// Takes the native overlay away (the button goes grey).
  void _detachOverlay() {
    _overlayAttached = false;
    unawaited(_channel
        .invokeMethod<void>('detach')
        .catchError((Object _) {}));
  }

  /// Forgets the tracked controller and route and takes the overlay away.
  /// Idempotent.
  void _release() {
    final c = _controller;
    if (c != null) c.removeListener(_onScroll);
    _controller = null;
    _route = null;
    _lastLengthPx = -1;
    _lastPositionPx = -1;
    if (_overlayAttached) _detachOverlay();
  }

  /// Keeps the overlay aligned with the tracked list, resending only the
  /// values that changed.
  void _sync() {
    final c = _controller;
    if (!_isOnTop || c == null || !c.hasClients) return;
    final position = c.position;
    final dpr = position.devicePixelRatio;
    final lengthPx = (position.maxScrollExtent * dpr).round();
    final positionPx = (position.pixels * dpr).round();

    if (lengthPx != _lastLengthPx) {
      _lastLengthPx = lengthPx;
      unawaited(_channel
          .invokeMethod<void>('setScrollLength', {'length': lengthPx})
          .catchError((Object _) {}));
    }
    if (positionPx != _lastPositionPx) {
      _lastPositionPx = positionPx;
      unawaited(_channel
          .invokeMethod<void>('setScrollPosition', {'position': positionPx})
          .catchError((Object _) {}));
    }
  }

  void _onScroll() {
    if (!_isOnTop) return;
    if (!_overlayAttached) {
      // Backstop for the first position notification (the route's
      // dependencies run before the scroll position exists).
      final c = _controller;
      if (c != null && c.hasClients) _attachOverlay();
      return;
    }
    _sync();
  }

  /// Mirrors one overlay-offset change (physical pixels) onto the tracked
  /// list.
  Future<void> _handleOverlayScroll(int topPx) async {
    final c = _controller;
    if (!_isOnTop || c == null || !c.hasClients) return;
    final position = c.position;
    // The overlay is at topPx by definition — book it so the mirror
    // does not send it back in a redundant round-trip.
    _lastPositionPx = topPx;
    position.jumpTo(
      (topPx / position.devicePixelRatio)
          .clamp(0.0, position.maxScrollExtent),
    );
  }
}
