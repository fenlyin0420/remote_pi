// Per-room composer drafts — the text typed in a room's input field but not
// sent yet. Keyed by the same `<epk>:<roomId>` session key as the local SSOT
// boxes, so a draft always lives with the (peer, room) pair it belongs to.
//
// Durable (a killed app must not lose an in-progress message) but cheap:
// the box is tiny (one short string per room) and reads are synchronous
// (`getSync`) so the chat page can hydrate the composer in its first frame.

import 'package:app/data/local/boxes.dart';

class DraftStore {
  final LocalBoxes _boxes;

  DraftStore(this._boxes);

  /// The stored draft for (peer, room), or null when none was left behind.
  /// Reads synchronously: the box is opened at bootstrap before `runApp`.
  String? read(String epk, String roomId) {
    final box = _boxes.draftsBox();
    final value = box.get(LocalBoxes.sessionKey(epk, roomId));
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Persists [text] as the draft for (peer, room). An empty (or
  /// whitespace-only) text deletes the record — a sent or deleted
  /// composer leaves nothing behind to re-hydrate.
  Future<void> save(String epk, String roomId, String text) async {
    final key = LocalBoxes.sessionKey(epk, roomId);
    final box = _boxes.draftsBox();
    if (text.trim().isEmpty) {
      if (box.containsKey(key)) await box.delete(key);
    } else {
      await box.put(key, text);
    }
  }
}
