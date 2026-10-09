import 'dart:math';

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
  return folderName(cwd);
}

/// The folder name a room in [cwd] would carry by default (the last
/// non-empty path segment) — the Pi's `defaultAgentName` equivalent.
String? folderName(String cwd) {
  final segments = cwd.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? null : segments.last;
}

/// The trailing `#N` index of [name] for base [base]: `1` when [name] is
/// exactly [base], the number when it is `base#N`, `0` otherwise. This is
/// the broker's collision-suffix convention (2nd same-name agent → `#2`).
int forkNumOf(String? name, String base) {
  if (name == null) return 0;
  if (name == base) return 1;
  final prefix = '$base#';
  if (name.startsWith(prefix)) {
    final n = int.tryParse(name.substring(prefix.length));
    if (n != null) return n;
  }
  return 0;
}

/// Strip a trailing `#N` from [name] (returns the input when there is
/// none), with [fallback] when nothing is left.
String _baseOf(String? name, String fallback) {
  if (name == null || name.isEmpty) return fallback;
  final stripped = name.replaceFirst(RegExp(r'#\d+$'), '');
  return stripped.isEmpty ? fallback : stripped;
}

/// The agent name for the next room of [cwd], in the broker's `#N`
/// convention: base name + `#(max + 1)` over [rooms] (every room in the
/// same cwd).
///
/// [sourceName] is the room being forked — its trailing `#N` is stripped,
/// so forking `foo#2` yields `foo#3`, not `foo#2#3`. When it is null the
/// base is the folder name (the plain "new room" case).
///
/// A room with no name holds the legacy (folder) room id, so it counts as
/// `#1` for the folder base. A fork always lands at least at `#2` (the
/// source room is `#1` even when it is absent from [rooms]); a plain new
/// room returns `null` — letting the Pi use the folder's default name and
/// the legacy room id — while the default id is still free.
String? nextForkName({
  String? sourceName,
  required String cwd,
  required List<RoomInfo> rooms,
}) {
  final folder = folderName(cwd) ?? 'agent';
  final base = _baseOf(sourceName, folder);
  final maxN = rooms
      .map((r) {
        final rname = r.name;
        var n = forkNumOf(rname, base);
        // An unnamed room in this cwd holds the legacy (folder) room id —
        // it counts as `#1` when the base is the folder name itself.
        if (n == 0 && base == folder && (rname == null || rname.isEmpty)) {
          n = 1;
        }
        return n;
      })
      .fold(0, (a, b) => max(a, b));
  if (sourceName == null || sourceName.isEmpty) {
    // Plain "new room": the default (folder) name is free unless some room
    // already holds that base — then step to the next `#N`.
    return maxN == 0 ? null : '$base#${maxN + 1}';
  }
  // A fork: the source room counts as `#1` even if [rooms] lost it (a
  // local tile deletion), so a fork is always at least `#2`.
  return '$base#${max(1, maxN) + 1}';
}
