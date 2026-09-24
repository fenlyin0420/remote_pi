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
/// [ConnectionManager.roomMessages] for every room — unlike [IChannel.serverMessages],
/// which carries only the active one.
class RoomMessage {
  final String epk;
  final String roomId;
  final ServerMessage message;

  const RoomMessage({
    required this.epk,
    required this.roomId,
    required this.message,
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
