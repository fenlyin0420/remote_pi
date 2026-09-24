// BackgroundDelivery — the rules that decide which agent activity becomes a
// notification, and when the foreground keeper is up.
//
// Everything is faked: a real ConnectionManager (with a fake transport so
// inbound frames can be injected per room), a recording notifier, a recording
// platform keeper, and a fake Preferences/PairingStorage.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/background/background_delivery.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/domain/contracts/background_connection.dart';
import 'package:app/domain/contracts/message_notifier.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/visible_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_secure_storage.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

const _epk = 'epk_test';

PeerRecord _peer() => const PeerRecord(
  remoteEpk: _epk,
  sessionName: 'mac-mini',
  relayUrl: 'ws://localhost:8080',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _Storage extends PairingStorage {
  _Storage(this.peers, {Map<String, Map<String, String>>? roomsByEpk})
    : _roomsByEpk = roomsByEpk ?? const {};

  final List<PeerRecord> peers;

  /// Cached room metadata, keyed `epk -> roomId -> name`. This is the same
  /// disk cache the app restores on boot, which is what gives notifications
  /// their room titles.
  final Map<String, Map<String, String>> _roomsByEpk;

  @override
  Future<List<PeerRecord>> listPeers() async => peers;

  @override
  Future<PeerRecord?> loadPeer(String epk) async {
    for (final p in peers) {
      if (p.remoteEpk == epk) return p;
    }
    return null;
  }

  @override
  Future<void> savePeer(PeerRecord r) async {}

  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => [
    for (final e in (_roomsByEpk[epk] ?? const {}).entries)
      PersistedRoom(roomId: e.key, name: e.value, startedAt: 0),
  ];
}

/// Transport that can push inbound frames and, like the real WS transport,
/// surfaces each one on [roomFrames] (all rooms) while only the addressed room
/// reaches the pull queue the session writer reads.
class _RoomTransport implements PeerTransport, IRoomFrameLink {
  final _frames = StreamController<RoomFrame>.broadcast();
  final _inbound = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];

  @override
  Stream<RoomFrame> get roomFrames => _frames.stream;

  void emit(String room, ServerMessage msg) {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(_wire(msg))));
    _frames.add(RoomFrame(roomId: room, payload: payload));
    // Mimic the transport demux: only the addressed room is queued.
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(payload);
    } else {
      _inbound.add(payload);
    }
  }

  static Map<String, dynamic> _wire(ServerMessage msg) => switch (msg) {
    AgentChunk(:final inReplyTo, :final delta) => {
      'type': 'agent_chunk',
      'in_reply_to': inReplyTo,
      'delta': delta,
    },
    AgentDone(:final inReplyTo) => {
      'type': 'agent_done',
      'in_reply_to': inReplyTo,
    },
    ErrorMessage(:final code, :final message) => {
      'type': 'error',
      'code': code,
      'message': message,
    },
    _ => {'type': 'unknown'},
  };

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<Uint8List> receive() {
    if (_inbound.isNotEmpty) return Future.value(_inbound.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future;
  }

  @override
  Future<void> close() async {
    await _frames.close();
  }
}

class _Notifier implements MessageNotifier {
  final _taps = StreamController<void>.broadcast();
  final shown = <({String epk, String room, String title, String body})>[];
  final cancelled = <({String epk, String room})>[];
  int cancelAllCount = 0;
  NotificationTap? pending;

  @override
  Stream<void> get taps => _taps.stream;

  void wake() => _taps.add(null);

  @override
  Future<NotificationTap?> takePendingTap() async {
    final tap = pending;
    pending = null;
    return tap;
  }

  @override
  Future<void> show({
    required String epk,
    required String roomId,
    required String title,
    required String body,
    String device = '',
  }) async {
    shown.add((epk: epk, room: roomId, title: title, body: body));
  }

  @override
  Future<void> cancel({required String epk, required String roomId}) async {
    cancelled.add((epk: epk, room: roomId));
  }

  @override
  Future<void> cancelAll() async => cancelAllCount++;
}

class _Keeper implements BackgroundConnection {
  int starts = 0;
  int stops = 0;
  bool running = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> start() async {
    starts++;
    running = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<bool> notificationsEnabled() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async {}
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Harness {
  _Harness({List<PeerRecord>? peers, Map<String, String>? rooms})
    : storage = _Storage(
        peers ?? [_peer()],
        roomsByEpk: rooms == null ? null : {_epk: rooms},
      ),
      prefs = Preferences(FakeSecureStorage()) {
    transport = _RoomTransport();
    manager = ConnectionManager(
      factory: (peer, cancel) async =>
          PlainPeerChannel(transport: transport),
      storage: storage,
      emitDebounce: Duration.zero,
    );
    delivery = BackgroundDelivery(
      connection: manager,
      notifier: notifier,
      background: keeper,
      storage: storage,
      preferences: prefs,
      visibleSession: visible,
    );
  }

  final _Storage storage;
  final Preferences prefs;
  final _Notifier notifier = _Notifier();
  final _Keeper keeper = _Keeper();
  final VisibleSession visible = VisibleSession();
  late final _RoomTransport transport;
  late final ConnectionManager manager;
  late final BackgroundDelivery delivery;

  /// Boots the manager (which restores the cached rooms and connects through the
  /// fake transport) so the delivery service sees a live, room-aware channel.
  Future<void> connect() async {
    await manager.boot();
    await pump();
  }

  void dispose() {
    delivery.dispose();
    manager.dispose();
  }
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 1));

void main() {
  test('a finished turn in another room becomes a notification', () async {
    final h = _Harness(
      rooms: {'room-a': 'remote_pi', 'room-b': 'remote'},
    );
    await h.connect();
    await h.delivery.start();
    await pump();

    h.transport.emit('room-b', AgentChunk(inReplyTo: 't1', delta: 'Done: '));
    h.transport.emit('room-b', AgentChunk(inReplyTo: 't1', delta: 'shipped it'));
    h.transport.emit('room-b', AgentDone(inReplyTo: 't1'));
    await pump();

    expect(h.notifier.shown, hasLength(1));
    expect(h.notifier.shown.single.room, 'room-b');
    // The room's own label, not the device — this is what tells the user which
    // workspace finished.
    expect(h.notifier.shown.single.title, 'remote');
    expect(h.notifier.shown.single.body, 'Done: shipped it');
    h.dispose();
  });

  test('the turn body keeps only the last line, trimmed of markdown', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    await h.delivery.start();
    h.transport.emit('room-a', AgentChunk(inReplyTo: 't1', delta: '## Plan\n\n- first\n- ran the tests\n'));
    h.transport.emit('room-a', AgentDone(inReplyTo: 't1'));
    await pump();

    expect(h.notifier.shown.single.body, 'ran the tests');
    h.dispose();
  });

  test('a finished turn is silent while the user reads that chat', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    await h.delivery.start();
    h.visible.enterChat(_epk, 'room-a');
    h.visible.setForeground(true);

    h.transport.emit('room-a', AgentDone(inReplyTo: 't1'));
    await pump();
    expect(h.notifier.shown, isEmpty);

    // Backgrounded: the same chat is no longer "on screen".
    h.visible.setForeground(false);
    h.transport.emit('room-a', AgentDone(inReplyTo: 't1'));
    await pump();
    expect(h.notifier.shown, hasLength(1));
    h.dispose();
  });

  test('a chat on screen does not silence a DIFFERENT room', () async {
    final h = _Harness(rooms: {'room-b': 'remote'});
    await h.connect();
    await h.delivery.start();
    h.visible.enterChat(_epk, 'room-a');
    h.visible.setForeground(true);

    h.transport.emit('room-b', AgentDone(inReplyTo: 't2'));
    await pump();

    expect(h.notifier.shown.single.room, 'room-b');
    h.dispose();
  });

  test('opening a chat clears that room\'s banner', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    await h.delivery.start();
    h.visible.enterChat(_epk, 'room-a');
    await pump();

    expect(h.notifier.cancelled, contains((epk: _epk, room: 'room-a')));
    h.dispose();
  });

  test('a provider error notifies with its message', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    await h.delivery.start();
    h.transport.emit(
      'room-a',
      ErrorMessage(code: 'provider_error', message: 'rate limited'),
    );
    await pump();

    expect(h.notifier.shown.single.body, 'rate limited');
    h.dispose();
  });

  test('tool traffic and echoes are not notified', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    await h.delivery.start();
    h.transport.emit('room-a', UserInput(id: 'u1', text: 'hi'));
    h.transport.emit('room-a', ToolRequest(toolCallId: 'c1', tool: 'bash', args: {}));
    h.transport.emit('room-a', ToolResult(toolCallId: 'c1', result: 'ok'));
    h.transport.emit('room-a', ToolResult(toolCallId: 'c2', error: 'nope'));
    await pump();

    expect(h.notifier.shown, isEmpty);
    h.dispose();
  });

  test('keeper starts with a paired peer and stops when unpaired', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    await h.delivery.start();
    await pump();

    expect(h.keeper.starts, 1);
    expect(h.keeper.running, isTrue);

    // Revoke the last peer: nothing to stay connected to.
    h.storage.peers.clear();
    h.prefs.notifyListeners();
    await pump();

    expect(h.keeper.running, isFalse);
    expect(h.notifier.cancelAllCount, greaterThan(0));
    h.dispose();
  });

  test('turning the switch off stops the keeper and drops its banners', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    await h.delivery.start();
    await pump();

    await h.prefs.setBackgroundConnection(false);
    await pump();

    expect(h.keeper.running, isFalse);
    expect(h.notifier.cancelAllCount, greaterThan(0));
    h.dispose();
  });

  test('no paired peer means no keeper even with the switch on', () async {
    final h = _Harness(peers: []);
    await h.delivery.start();
    await pump();

    expect(h.keeper.starts, 0);
    h.dispose();
  });

  test('a parked tap is drained and forwarded', () async {
    final h = _Harness(rooms: {'room-a': 'remote_pi'});
    await h.connect();
    h.notifier.pending = const NotificationTap(epk: _epk, roomId: 'room-b');
    final tapped = <NotificationTap>[];
    final sub = h.delivery.taps.listen(tapped.add);

    // `start()` deliberately does NOT drain (bootstrap happens before anything
    // can act on a tap); the app shell drains once it is listening.
    await h.delivery.start();
    await pump();
    expect(tapped, isEmpty);

    await h.delivery.drainPendingTap();
    await pump();
    expect(tapped.single.roomId, 'room-b');

    // Warm tap: the platform only wakes us, the payload comes from the pull.
    h.notifier.pending = const NotificationTap(epk: _epk, roomId: 'room-c');
    h.notifier.wake();
    await pump();
    expect(tapped.last.roomId, 'room-c');

    await sub.cancel();
    h.dispose();
  });
}
