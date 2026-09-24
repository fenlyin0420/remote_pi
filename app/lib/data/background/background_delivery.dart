import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/background_connection.dart';
import 'package:app/domain/contracts/message_notifier.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/domain/value_objects/session_label.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/visible_session.dart';

/// Turns "the agent finished a turn" into a system notification, and keeps the
/// process alive so those events can reach a backgrounded app at all.
///
/// Two responsibilities that only make sense together — a notification path
/// with no live connection notifies about nothing, and a kept-alive connection
/// with nothing to say is just a battery drain:
///
///  1. **Keeper lifecycle.** Starts/stops the platform foreground service from
///     the user's switch plus "is anything paired at all", re-evaluated whenever
///     peers or preferences change. Never trusts the switch alone.
///  2. **Triggers.** Consumes [ConnectionManager.roomMessages] — every room, not
///     just the one on screen — and posts one notification per finished turn,
///     suppressed when the user is already reading that chat.
///
/// Why notifications come from here and not from the session writer: the writer
/// is bound to the open chat, so it never sees the other workspaces. The
/// transport now surfaces foreign-room frames instead of dropping them, and this
/// is their only consumer.
class BackgroundDelivery extends Service {
  BackgroundDelivery({
    required ConnectionManager connection,
    required MessageNotifier notifier,
    required BackgroundConnection background,
    required PairingStorage storage,
    required Preferences preferences,
    required VisibleSession visibleSession,
  }) : _connection = connection,
       _notifier = notifier,
       _background = background,
       _storage = storage,
       _preferences = preferences,
       _visibleSession = visibleSession;

  final ConnectionManager _connection;
  final MessageNotifier _notifier;
  final BackgroundConnection _background;
  final PairingStorage _storage;
  final Preferences _preferences;
  final VisibleSession _visibleSession;

  /// Longest preview kept per room while a turn streams. Only the tail is ever
  /// shown, so a turn that emits megabytes of chunks must not grow forever.
  static const int _previewLimit = 1024;

  /// How much of the preview the banner shows.
  static const int _bodyLimit = 160;

  final _taps = StreamController<NotificationTap>.broadcast();
  StreamSubscription<RoomMessage>? _activitySub;
  StreamSubscription<void>? _tapSub;

  /// Streaming text per `epk|room`, used as the notification body. Cleared on
  /// every finished turn.
  final Map<String, StringBuffer> _previews = <String, StringBuffer>{};

  bool _started = false;
  bool _disposed = false;

  /// Whether the app is in front. The keeper only runs when it is **not**: in
  /// front, the app's own connection is alive and Android's mandatory notice on
  /// the foreground service is pure noise — it was the "Connected" notice the
  /// user saw on every launch. Backgrounded, the notice is the price of keeping
  /// the process alive at all, and it appears only then.
  bool _foreground = true;

  /// Whether the feature is armed: switch on, and something paired to reach.
  /// Cached from the last [syncKeeper] so Settings can describe the keeper
  /// accurately without re-reading storage itself.
  bool _armed = false;

  /// The notification prompt is asked at most once per app run. Android stops
  /// showing it after a couple of denials anyway; asking on every storage change
  /// would just be noise on the way to that.
  bool _askedForNotifications = false;

  /// Sessions the user tapped, for the router to open.
  Stream<NotificationTap> get taps => _taps.stream;

  /// See [_armed]. True means "there is something to keep alive".
  bool get armed => _armed;

  /// See [_foreground].
  bool get foreground => _foreground;

  /// Told by the app shell whenever the lifecycle changes. Idempotent.
  Future<void> setForeground(bool value) async {
    if (_foreground == value) return;
    _foreground = value;
    await syncKeeper();
  }

  /// Wires up the streams and applies the current switch state. Idempotent;
  /// call once from bootstrap so nothing is missed while the app boots.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _activitySub = _connection.roomMessages.listen(_onRoomMessage);
    _tapSub = _notifier.taps.listen((_) => drainPendingTap());
    // Peers added/removed and the switch itself both change whether there is
    // anything to keep alive.
    _storage.addListener(syncKeeper);
    _preferences.addListener(syncKeeper);
    // Opening a chat by hand should clear that room's banner, exactly like a
    // chat app clears it once read.
    _visibleSession.addListener(_onVisibleSessionChanged);
    await syncKeeper();
    // NOTE: a pending tap is deliberately NOT drained here. Bootstrap runs
    // before the router (and before anything listens to [taps]), so draining now
    // would consume a cold-start tap into a stream nobody is listening to yet.
    // The app shell drains it once it can act on it — see `main.dart`.
  }

  /// Pulls a tap the platform is holding (cold start) and forwards it to
  /// [taps]. Safe to call any time; a missing tap is a no-op.
  Future<void> drainPendingTap() async {
    if (_disposed) return;
    final tap = await _notifier.takePendingTap();
    if (tap == null || _disposed) return;
    if (!_taps.isClosed) _taps.add(tap);
  }

  @override
  void dispose() {
    _disposed = true;
    _activitySub?.cancel();
    _tapSub?.cancel();
    _visibleSession.removeListener(_onVisibleSessionChanged);
    _storage.removeListener(syncKeeper);
    _preferences.removeListener(syncKeeper);
    _taps.close();
    super.dispose();
  }

  void _onVisibleSessionChanged() {
    final chat = _visibleSession.chat;
    if (chat == null) return;
    // ignore: unawaited_futures
    _notifier.cancel(epk: chat.epk, roomId: chat.roomId);
  }

  // ---------------------------------------------------------------------------
  // Keeper lifecycle
  // ---------------------------------------------------------------------------

  /// Applies "should the keeper be up" to the platform.
  ///
  /// Public because the settings switch drives it directly: the switch writes
  /// the preference and asks for this to be applied in the same turn, rather
  /// than waiting for the notifier round-trip. The listeners above call it too,
  /// which makes the double invocation the normal case — the platform calls are
  /// idempotent precisely so that is safe.
  Future<void> syncKeeper() async {
    if (_disposed || !_background.isSupported) return;
    // Nothing paired → nothing to stay connected to. This is what keeps the
    // notice from appearing on a fresh install or after a revoke.
    final peers = await _storage.listPeers();
    if (_disposed) return;

    // Two separate questions, previously one. *Armed* is the user's intent: the
    // switch is on and there is a peer to reach. *Wanted* is whether the
    // platform should be running the keeper right now — which is only while the
    // app is out of sight, since that is the only situation the keeper improves.
    _armed = _preferences.backgroundConnection && peers.isNotEmpty;

    if (_armed && !_askedForNotifications) {
      // Ask for the notification permission when the feature is armed, not when
      // the keeper happens to start: this is the one moment the request has
      // obvious context, and it is always in front — Android cannot show this
      // dialog from the background, which is when the keeper starts now. A
      // prompt with no context is the one users deny by reflex, and without the
      // permission the keeper would run invisibly.
      _askedForNotifications = true;
      if (!await _background.notificationsEnabled()) {
        await _background.requestNotificationPermission();
      }
      if (_disposed) return;
    }

    if (_armed && !_foreground) {
      await _background.start();
    } else {
      await _background.stop();
      // Banners belong to a feature that was switched off or unpaired — not to
      // the app simply coming back to the front, which must leave the user's
      // unread notices alone.
      if (!_armed) await _notifier.cancelAll();
    }
  }

  // ---------------------------------------------------------------------------
  // Triggers
  // ---------------------------------------------------------------------------

  void _onRoomMessage(RoomMessage m) {
    final key = '${m.epk}|${m.roomId}';
    switch (m.message) {
      case AgentChunk(:final delta):
        _appendPreview(key, delta);
      case AgentDone():
        // The turn is over — this is the moment worth a banner (the Pi's
        // `agent_end`; `willRetry` retries are not observable here and surface
        // as another chunk burst instead of a finished turn).
        final preview = _takePreview(key);
        // ignore: unawaited_futures
        _notify(m.epk, m.roomId, preview);
      case AgentMessage(:final text):
        // Only produced by a history re-sync (live assistant text arrives as
        // chunks): keep it as the body so a later `agent_done` has something to
        // show even if the chunks were missed while offline.
        _setPreview(key, text);
      case ErrorMessage(:final message):
        // A provider failure leaves the app hanging with no reply — the one
        // other thing the user actually wants to be told about.
        _appendPreview(key, message);
        final preview = _takePreview(key);
        // ignore: unawaited_futures
        _notify(m.epk, m.roomId, preview);
      case _:
        // Tool traffic, echoes, sync payloads, presence: nothing to notify on.
        break;
    }
  }

  Future<void> _notify(String epk, String roomId, String preview) async {
    if (_disposed) return;
    // Already on this chat, in the foreground: the message is on screen.
    if (_visibleSession.isViewing(epk, roomId)) return;
    // Notifications switched off (the keeper is stopped too, but a stale switch
    // flip must not leak a banner).
    if (!_preferences.backgroundConnection) return;

    final peer = await _storage.loadPeer(epk);
    if (_disposed || peer == null) return;
    final room = _roomFor(epk, roomId);
    final title = roomLabel(room) ?? deviceLabel(peer);
    final body = preview.isEmpty ? 'Turn finished' : preview;
    await _notifier.show(
      epk: epk,
      roomId: roomId,
      title: title,
      body: body,
      device: deviceLabel(peer),
    );
  }

  RoomInfo? _roomFor(String epk, String roomId) {
    for (final room in _connection.roomsFor(epk)) {
      if (room.roomId == roomId) return room;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Preview buffer
  // ---------------------------------------------------------------------------

  void _appendPreview(String key, String delta) {
    final buffer = _previews.putIfAbsent(key, StringBuffer.new);
    buffer.write(delta);
    // Keep only the tail: the banner shows the end of the turn anyway, and an
    // unbounded buffer would grow with every streamed token.
    if (buffer.length > _previewLimit) {
      final tail = buffer.toString().substring(buffer.length - _previewLimit);
      buffer
        ..clear()
        ..write(tail);
    }
  }

  void _setPreview(String key, String text) {
    _previews[key] = StringBuffer(text);
  }

  String _takePreview(String key) {
    final buffer = _previews.remove(key);
    if (buffer == null) return '';
    return _condense(buffer.toString());
  }

  /// Collapses a streamed turn into one banner line: markdown headers, list
  /// bullets and blank lines are noise in a notification, and the last
  /// non-empty line is almost always the conclusion.
  static String _condense(String raw) {
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    final last = lines.last
        .replaceAll(RegExp(r'^[#>\-*+\d.\s]+'), '')
        .replaceAll(RegExp(r'[*_`]+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (last.isEmpty) return '';
    return last.length <= _bodyLimit
        ? last
        : '…${last.substring(last.length - _bodyLimit + 1)}';
  }
}
