import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

/// Human labels for a paired session.
///
/// One session is named in three places — the Home tile, the chat AppBar and
/// now background notifications — and they must agree, otherwise the banner
/// says something the user cannot find in the list. These are the two rules,
/// in one place.

/// The paired device: user-set nickname, then the name the Pi announced, then
/// a short slice of the key so there is always *something* to show.
String deviceLabel(PeerRecord peer) {
  final nickname = peer.nickname;
  if (nickname != null && nickname.isNotEmpty) return nickname;
  if (peer.sessionName.isNotEmpty) return peer.sessionName;
  return peer.remoteEpk.substring(0, 8);
}

/// The Pi-side room: its announced name (which already carries any local rename)
/// and, failing that, the last segment of the working directory. Null when the
/// room is unknown or unnamed — callers apply their own fallback, because only
/// they know whether "the device" or a placeholder is the right one.
String? roomLabel(RoomInfo? room) {
  if (room == null) return null;
  final name = room.name;
  if (name != null && name.isNotEmpty) return name;
  final cwd = room.cwd;
  if (cwd == null || cwd.isEmpty) return null;
  final segments = cwd.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? null : segments.last;
}
