import 'dart:typed_data';

import 'package:app/protocol/protocol.dart';

/// Abstract channel — testable interface over [PlainPeerChannel].
abstract class IChannel {
  Stream<ServerMessage> get serverMessages;
  Future<void> send(ClientMessage msg);
  Future<void> close();
}

/// Optional capability mixed into a channel that also speaks raw relay
/// control frames (subscribe_presence, peer_online, etc — see plano 12).
/// ConnectionManager does an `is IControlLink` cast to drive presence;
/// channels that don't implement it simply skip the subsystem.
abstract class IControlLink {
  Stream<ControlInbound> get controlFrames;
  void sendControl(Map<String, dynamic> json);
}

/// One inbound frame tagged with the Pi-side room that produced it.
///
/// The relay stamps every delivered envelope with the **sender's** room id, so
/// a frame arriving on this device always says which Pi session it came from.
/// Frames addressed to a room the app is not currently driving are not part of
/// the open chat and must never reach the session writer — but they are the
/// raw material for background notifications, which is why they are surfaced
/// instead of dropped.
class RoomFrame {
  final String roomId;
  final Uint8List payload;

  const RoomFrame({required this.roomId, required this.payload});
}

/// A decoded inbound message plus the session it belongs to. Emitted by
/// [ConnectionManager.roomMessages] for every room.
///
/// Two consumers read inbound traffic, on purpose, from different streams and
/// with different jobs:
///
///  * the **session writer** ([IChannel.serverMessages], active room only) owns
///    the chat transcript — anything else in there would bleed into the open
///    chat;
///  * the **background notifier** ([ConnectionManager.roomMessages], every room)
///    only decides whether a banner is warranted.
///
/// They are not mirrors of each other and do not reconcile: neither derives
/// state the other depends on, so a message reaching both is deliberate, not
/// double handling.
class RoomMessage {
  final String epk;
  final String roomId;
  final ServerMessage message;

  /// When this device received the frame (local clock). The Pi's own ordering
  /// is the arrival order at the relay; this is only for the receiver's own
  /// bookkeeping, e.g. recognising a burst from one room.
  final DateTime receivedAt;

  const RoomMessage({
    required this.epk,
    required this.roomId,
    required this.message,
    required this.receivedAt,
  });
}

/// Optional capability: a channel whose inbound frames can be observed together
/// with their originating room, including rooms the app is not addressing.
///
/// ConnectionManager casts to it and falls back to "no background traffic" for
/// channels that don't implement it (test fakes, in-memory transports).
abstract class IRoomFrameLink {
  Stream<RoomFrame> get roomFrames;
}
