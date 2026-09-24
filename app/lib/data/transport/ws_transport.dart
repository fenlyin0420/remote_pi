// WebSocket-based PeerTransport.
//
// Flow per connection:
//   1. Connect to relay WS
//   2. Ed25519 challenge-response (hello → challenge → auth)
//   3. After auth, two parallel streams of inbound frames:
//        - envelope frames `{peer, ct}` → decoded to the peer queue
//        - control frames (top-level `type`, no `peer`) → control stream
//      Outbound `subscribe_presence` / `presence_check` go raw too.
//
// `peer` is standard base64 of the destination's Ed25519 pubkey (matches
// the relay registry, populated from the peer's hello). `ct` is base64 of
// the inner-envelope bytes (plain JSON post-rollback, see plano 06).

import 'dart:async';
import 'dart:convert';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../pairing/pair_request_flow.dart';

class WsTransportError implements Exception {
  final String message;
  const WsTransportError(this.message);

  @override
  String toString() => 'WsTransportError: $message';
}

/// Where one inbound envelope goes.
///
/// Extracted from the socket listener so the routing rule — the part that
/// decides whether the user's open chat sees a message — is testable without a
/// live socket.
///
/// [forSession] is true when the frame was sent by the room the app is
/// addressing: only those may reach the session writer, or a chat the user just
/// left would bleed into the one they are reading. Every frame is surfaced in
/// [frame] regardless, because background notifications watch all rooms.
///
/// A null [senderRoom] is a legacy Pi that does not stamp the room; it routes
/// unconditionally (there is nothing to compare against).
@visibleForTesting
({RoomFrame frame, bool forSession}) classifyInboundFrame({
  required String? senderRoom,
  required String activeRoom,
  required Uint8List payload,
}) => (
  frame: RoomFrame(roomId: senderRoom ?? activeRoom, payload: payload),
  forSession: senderRoom == null || senderRoom == activeRoom,
);

class WsTransport implements PeerTransport, IControlLink, IRoomFrameLink {
  final WebSocketChannel _ws;
  final _queue = _MsgQueue();
  final _controlController =
      StreamController<ControlInbound>.broadcast();
  final _roomFrameController = StreamController<RoomFrame>.broadcast();

  WsTransport._(this._ws);

  // Connect, authenticate with relay, and return a ready transport.
  static Future<WsTransport> connect({
    required String relayUrl,
    required String peerPubkey, // base64 standard or url — destination peer
    required SimpleKeyPair ed25519Key, // this device's Ed25519 long-term key
  }) async {
    // Plan-18 follow-up — set a WS-level pingInterval (RFC 6455
    // control frames). This keeps the TCP connection alive through
    // NAT / corporate proxies that aggressively close idle sockets,
    // and surfaces a dead WS as `onDone` / `onError` instead of
    // letting it silently linger until the next user action. The
    // protocol-level Ping/Pong handled by ConnectionManager covers
    // app↔Pi liveness; this one covers app↔relay TCP liveness.
    // Accept http(s) URLs in the user-facing form but always speak
    // ws(s) on the wire — IOWebSocketChannel rejects http schemes.
    final WebSocketChannel ws = IOWebSocketChannel.connect(
      Uri.parse(toWsRelayUrl(relayUrl)),
      pingInterval: const Duration(seconds: 20),
    );
    final transport = WsTransport._(ws);

    final challengeCompleter = Completer<Map<String, dynamic>>();
    bool authDone = false;

    final sub = ws.stream.listen(
      (raw) {
        // Volume probe: log every frame the relay pushes onto this
        // socket so we can spot firehose patterns (e.g. presence
        // churn, repeated room snapshots) by counting prefix
        // occurrences — body kept compact so the log stays grep-able
        // even when the relay is chatty.
        final rawStr = raw is String ? raw : raw.toString();
        if (!authDone) {
          debugPrint('[ws-in] bytes=${rawStr.length} stage=preauth');
          try {
            challengeCompleter.complete(
              jsonDecode(raw as String) as Map<String, dynamic>,
            );
          } catch (e) {
            if (!challengeCompleter.isCompleted) {
              challengeCompleter.completeError(e);
            }
          }
          return;
        }
        try {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          // Envelope: {peer, room?, ct} → enqueue payload bytes.
          if (frame.containsKey('peer') && frame.containsKey('ct')) {
            final bytes = _b64Decode(frame['ct'] as String);
            final senderRoom = frame['room'] as String?;
            final routed = classifyInboundFrame(
              senderRoom: senderRoom,
              activeRoom: transport._activeRoom,
              payload: bytes,
            );
            // Only the addressed room reaches the session writer. Frames from
            // any other room are not discarded anymore — they go to
            // `roomFrames`, which is what lets the app notify about a workspace
            // other than the one on screen (see BackgroundDelivery).
            if (routed.forSession) transport._queue.add(bytes);
            if (!transport._roomFrameController.isClosed) {
              transport._roomFrameController.add(routed.frame);
            }
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=envelope '
              'ct.bytes=${bytes.length} room=${routed.frame.roomId} '
              '${routed.forSession ? 'active' : 'foreign'}',
            );
            return;
          }
          // Control: top-level `type` only → presence stream.
          final ctrl = ControlInbound.tryFromJson(frame);
          if (ctrl != null && !transport._controlController.isClosed) {
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=control '
              'type=${frame['type']}',
            );
            transport._controlController.add(ctrl);
            return;
          }
          // Anything else: unknown shape — drop silently.
          debugPrint('[ws-in] bytes=${rawStr.length} kind=unknown DROPPED');
        } catch (e) {
          debugPrint(
            '[ws-in] bytes=${rawStr.length} kind=malformed DROPPED err=$e',
          );
        }
      },
      onError: (e) {
        if (!challengeCompleter.isCompleted) challengeCompleter.completeError(e);
        transport._queue.error(e);
      },
      onDone: () {
        if (!challengeCompleter.isCompleted) {
          challengeCompleter.completeError(const WsTransportError('WS closed during auth'));
        }
        transport._queue.close();
        if (!transport._controlController.isClosed) {
          transport._controlController.close();
        }
        if (!transport._roomFrameController.isClosed) {
          transport._roomFrameController.close();
        }
      },
    );

    try {
      // 1. Hello (standard base64 — matches relay registry format).
      // Plan 17: app is a client (no cwd) and always announces itself
      // on the canonical 'main' room. Pi-side hellos include their own
      // room_id (one per cwd) AND room_meta; that's not our concern here.
      final pub = await ed25519Key.extractPublicKey();
      ws.sink.add(jsonEncode({
        'type': 'hello',
        'pubkey': base64.encode(pub.bytes),
        'room_id': 'main',
      }));

      // 2. Challenge
      final ch = await challengeCompleter.future;
      if (ch['type'] != 'challenge') {
        throw WsTransportError('Expected challenge, got ${ch['type']}');
      }
      final nonce = _b64Decode(ch['nonce'] as String);

      // 3. Auth
      final sig = await Ed25519().sign(nonce, keyPair: ed25519Key);
      ws.sink.add(jsonEncode({
        'type': 'auth',
        'sig': base64.encode(sig.bytes),
      }));
      authDone = true;

      transport._peerPubkey = _normalizeToStandard(peerPubkey);
      transport._sub = sub;
      return transport;
    } catch (e) {
      await sub.cancel();
      await ws.sink.close();
      rethrow;
    }
  }

  String _peerPubkey = '';
  StreamSubscription? _sub;

  /// Active target room on the Pi side. Plan 17: set via
  /// `setActiveRoom`, defaults to 'main' when unset. The outer envelope
  /// embeds this so the Pi can route the inner message to the right
  /// per-cwd session.
  String _activeRoom = 'main';

  /// Override the destination room (Pi side). The app remains on the
  /// 'main' room itself (that's what we sent in `hello.room_id`).
  void setActiveRoom(String room) {
    if (room == _activeRoom) {
      return;
    }
    _activeRoom = room;
  }

  @override
  Future<void> send(Uint8List data) async {
    _ws.sink.add(jsonEncode({
      'peer': _peerPubkey,
      'room': _activeRoom,
      'ct': base64.encode(data),
    }));
  }

  @override
  Future<Uint8List> receive() => _queue.next();

  // ---- IControlLink --------------------------------------------------------

  @override
  Stream<ControlInbound> get controlFrames => _controlController.stream;

  @override
  void sendControl(Map<String, dynamic> json) {
    _ws.sink.add(jsonEncode(json));
  }

  // ---- IRoomFrameLink ------------------------------------------------------

  /// Every inbound envelope with the room that sent it, including rooms other
  /// than [setActiveRoom]'s. Closes with the socket.
  @override
  Stream<RoomFrame> get roomFrames => _roomFrameController.stream;

  // -------------------------------------------------------------------------

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _ws.sink.close();
    _queue.close();
    if (!_controlController.isClosed) await _controlController.close();
    if (!_roomFrameController.isClosed) await _roomFrameController.close();
  }
}

// ---------------------------------------------------------------------------

class _MsgQueue {
  final _buf = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];
  bool _closed = false;

  void add(Uint8List msg) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(msg);
    } else if (!_closed) {
      _buf.add(msg);
    }
  }

  void error(Object e) {
    for (final w in _waiters) {
      w.completeError(e);
    }
    _waiters.clear();
    _closed = true;
  }

  void close() {
    for (final w in _waiters) {
      w.completeError(const WsTransportError('transport closed'));
    }
    _waiters.clear();
    _closed = true;
  }

  Future<Uint8List> next() {
    if (_closed) return Future.error(const WsTransportError('transport closed'));
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future;
  }
}

// Decodes standard or url-safe base64 (pads defensively).
Uint8List _b64Decode(String s) {
  final pad = (4 - s.length % 4) % 4;
  final padded = s + '=' * pad;
  try {
    return base64.decode(padded);
  } on FormatException {
    return base64Url.decode(padded);
  }
}

// Relay registry uses standard base64 (from each peer's hello). QR/storage
// may carry url-safe encoding — re-encode to standard so the relay matches.
String _normalizeToStandard(String pubkey) {
  try {
    final pad = (4 - pubkey.length % 4) % 4;
    final bytes = base64Url.decode(pubkey + '=' * pad);
    return base64.encode(bytes);
  } catch (_) {
    return pubkey;
  }
}
