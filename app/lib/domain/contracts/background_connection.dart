/// Keeps the app process alive while backgrounded so the relay WebSocket — and
/// therefore incoming activity — survives leaving the app.
///
/// Contract in the domain; the platform side lives in
/// `ConnectionKeeperService.kt` + the `work.jacobmoura.remotepi/background`
/// channel in `MainActivity.kt`.
///
/// Android requires a foreground service for this, and a foreground service
/// must show a notification, so there is no way to do it silently: the user
/// gets a persistent "connected" notice while the switch is on. That is the
/// price of a self-hosted relay (cloud push needs an app the user cannot
/// operate, and OEM push channels need vendor accounts).
///
/// Android-only. Everywhere else [isSupported] is false and every call is a
/// no-op, which keeps the settings UI honest and the iOS build compiling.
abstract class BackgroundConnection {
  /// Whether the platform can hold the connection at all (Android today).
  bool get isSupported;

  /// Starts the foreground keeper (idempotent).
  Future<void> start();

  /// Stops it — the connection then dies with the process, as before.
  Future<void> stop();

  /// Asks the platform whether the keeper is running *right now*. Never cached
  /// on the Dart side: the system can stop a service behind the app's back, and
  /// a stale "on" would leave the settings screen lying.
  Future<bool> isRunning();

  /// Whether the OS will actually display notifications: the Android 13+
  /// permission granted AND notifications not disabled for this app. False
  /// means the keeper still runs — the user just never sees anything.
  Future<bool> notificationsEnabled();

  /// Shows the runtime notification prompt. Resolves with whether notifications
  /// can be posted afterwards. A no-op returning true before Android 13.
  Future<bool> requestNotificationPermission();

  /// Opens the system screen for this app's notification settings — the only
  /// actionable path when the permission is granted but notifications are
  /// disabled app-wide.
  Future<void> openNotificationSettings();

  /// Whether the OS already exempts this app from battery optimization. Doze
  /// spares foreground services, but aggressive OEM battery managers do not.
  Future<bool> isIgnoringBatteryOptimizations();

  /// Asks for that exemption (system dialog), falling back to the settings list.
  Future<void> requestIgnoreBatteryOptimizations();
}
