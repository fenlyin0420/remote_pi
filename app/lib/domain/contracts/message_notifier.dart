/// System notifications for agent activity that arrives while the user is
/// elsewhere.
///
/// Contract in the domain; the platform side lives in `AppNotifications.kt` +
/// the `work.jacobmoura.remotepi/notifications` channel in `MainActivity.kt`.
///
/// Scope is deliberately narrow: one notification per session ("the agent
/// finished a turn"), whose body is a short preview. Nothing here is a message
/// store — the transcript is already durable on the device, and a notification
/// is only a nudge to come back.
abstract class MessageNotifier {
  /// Fires when the user taps a notification. It carries no payload: the
  /// destination is pulled with [takePendingTap], so a tap that launches the
  /// app from cold and a tap that lands on a running app take one code path.
  Stream<void> get taps;

  /// Consumes the session of the tapped notification, or null when there is
  /// none pending.
  Future<NotificationTap?> takePendingTap();

  /// Posts (or replaces) the notification for one session. Repeated calls for
  /// the same `(epk, roomId)` collapse onto a single entry.
  Future<void> show({
    required String epk,
    required String roomId,
    required String title,
    required String body,
    String device,
  });

  /// Posts a sample "turn finished" notification.
  ///
  /// Exists so sound/vibration can be verified in seconds instead of waiting for
  /// the agent to finish something — and so "it didn't buzz" has an obvious
  /// first diagnostic step.
  Future<void> showTest();

  /// Dismisses the session's notification — used when the user opens the chat
  /// on their own, the same way a chat app clears its banner once read.
  Future<void> cancel({required String epk, required String roomId});

  /// Dismisses everything (notifications turned off).
  Future<void> cancelAll();
}

/// A tapped notification: which session to open.
class NotificationTap {
  const NotificationTap({required this.epk, required this.roomId});

  /// Peer (Pi) the notification came from — the epk the app indexes peers by.
  final String epk;

  /// Pi-side room the notification came from.
  final String roomId;
}
