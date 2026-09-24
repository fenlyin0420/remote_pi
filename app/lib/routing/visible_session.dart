import 'package:flutter/widgets.dart';

/// What the user is actually looking at right now.
///
/// Background notifications need exactly one bit from the UI layer: "is this
/// session already on screen?" — a banner for a chat the user is reading is
/// noise. [SessionSelection] cannot answer it: that value survives leaving the
/// chat (it drives the tablet's master-list highlight), so it stays set once
/// the user goes back to Home.
///
/// [ChatViewModel] reports the chat it binds on mount and clears it on dispose,
/// which tracks the real thing — the widget being on screen — and `main.dart`
/// feeds the resumed/backgrounded half from the app lifecycle.
class VisibleSession extends ChangeNotifier {
  bool _foreground = true;
  String? _epk;
  String? _roomId;

  /// True while the app is resumed, false once it is backgrounded.
  bool get isForeground => _foreground;

  /// The `(peer, room)` whose chat screen is mounted, or null when the user is
  /// not inside a chat.
  ({String epk, String roomId})? get chat {
    final epk = _epk;
    final roomId = _roomId;
    if (epk == null || roomId == null) return null;
    return (epk: epk, roomId: roomId);
  }

  void setForeground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    notifyListeners();
  }

  /// Marks [epk]/[roomId] as the chat on screen.
  void enterChat(String epk, String roomId) {
    if (_epk == epk && _roomId == roomId) return;
    _epk = epk;
    _roomId = roomId;
    notifyListeners();
  }

  /// Clears the marker — but only if it still belongs to this chat. Teardown
  /// order between two chats is not guaranteed (a pushed chat disposes after
  /// the replacement mounted), and the newcomer must not be un-marked by the
  /// screen it replaced.
  void leaveChat(String epk, String roomId) {
    if (_epk != epk || _roomId != roomId) return;
    _epk = null;
    _roomId = null;
    notifyListeners();
  }

  /// True when the user is looking at this exact session right now: the app is
  /// in the foreground AND this chat is the mounted one.
  bool isViewing(String epk, String roomId) =>
      _foreground && _epk == epk && _roomId == roomId;
}
