import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';

/// Points the app at a session: `(peer, room)`.
///
/// Opening a session in this app is not just navigation — it has three
/// side effects that must happen in this order, and skipping any of them leaves
/// the chat silently bound to the wrong place:
///
///  1. Persist the choice, room included (`/chat` reads it on mount).
///  2. Write the room onto the `PeerRecord`, otherwise the next cold start
///     falls back to room `main` and the Pi never sees the frame.
///  3. Retarget the live connection so outbound frames address that room.
///
/// Shared by the Home tap and by tapping a notification, so a session opened
/// from a banner is bound exactly like one opened by hand. A peer that is no
/// longer stored is a silent no-op — the caller cannot open what is gone.
Future<void> retargetSession({
  required PairingStorage storage,
  required Preferences prefs,
  required ConnectionManager conn,
  required String epk,
  String? roomId,
}) async {
  final peers = await storage.listPeers();
  final match = peers.where((p) => p.remoteEpk == epk).cast<PeerRecord?>();
  if (match.isEmpty) return;
  final peer = match.first!;
  final effectiveRoom = (roomId == null || roomId.isEmpty) ? 'main' : roomId;
  await prefs.setSelectedRoom(epk: epk, roomId: effectiveRoom);
  if (peer.roomId != effectiveRoom) {
    // ignore: unawaited_futures
    storage.savePeer(peer.copyWith(roomId: effectiveRoom));
  }
  // Safe to call even if the manager is mid-connect: the room is applied on the
  // next send and to any active StatusOnline channel.
  conn.switchRoom(effectiveRoom);
}
