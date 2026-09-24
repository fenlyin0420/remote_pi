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

  /// What the OS reports about this app's notifications right now.
  ///
  /// Every way a notification can end up silent lives outside the app — the
  /// channel's importance can be lowered, its sound or vibration pattern can be
  /// missing, the phone can be in silent mode, Do Not Disturb can be swallowing
  /// the alert — and all of them look identical from inside: "it never bangs".
  /// This is the readback that tells them apart.
  Future<NotificationDiagnostics> notificationDiagnostics();
}

/// The OS's own answer about this app's notification setup.
class NotificationDiagnostics {
  const NotificationDiagnostics({
    required this.appNotificationsEnabled,
    required this.channelId,
    required this.channelImportance,
    required this.channelHasSound,
    required this.channelVibration,
    required this.ringerMode,
    required this.interruptionFilter,
  });

  /// Notifications allowed for the app at all.
  final bool appNotificationsEnabled;

  /// Id of the channel message notifications actually use. Also a version check:
  /// a device still on the retired channel is visible here.
  final String channelId;

  /// 0 = blocked, 2 = low, 3 = default, 4 = high. Heads-up needs 4.
  final int channelImportance;

  final bool channelHasSound;

  /// Raw vibration pattern, empty when the channel has none (which is what "no
  /// buzz" looked like from the outside before).
  final String channelVibration;

  /// `normal` | `vibrate` | `silent` | `unknown` — silent mode kills the buzz
  /// unless the device is set to always vibrate.
  final String ringerMode;

  /// `all` | `priority` | `none` | `alarms` | `unknown`. Anything but `all` means
  /// Do Not Disturb is active, which suppresses the banner and the buzz.
  final String interruptionFilter;

  static NotificationDiagnostics fromMap(Map<Object?, Object?> raw) {
    T? read<T>(String key) => raw[key] is T ? raw[key] as T : null;
    return NotificationDiagnostics(
      appNotificationsEnabled: read<bool>('appNotificationsEnabled') ?? false,
      channelId: read<String>('channelId') ?? '',
      channelImportance: read<int>('channelImportance') ?? -1,
      channelHasSound: read<bool>('channelHasSound') ?? false,
      channelVibration: read<String>('channelVibration') ?? '',
      ringerMode: read<String>('ringerMode') ?? 'unknown',
      interruptionFilter: read<String>('interruptionFilter') ?? 'unknown',
    );
  }

  /// One-line summary for the settings screen — everything a support question
  /// would otherwise have to ask for.
  String get summary {
    final importance = switch (channelImportance) {
      0 => 'blocked',
      2 => 'low',
      3 => 'default',
      4 => 'high',
      _ => 'unknown',
    };
    return 'channel=$channelId importance=$importance '
        'sound=${channelHasSound ? 'yes' : 'no'} '
        'vibrate=${channelVibration.isEmpty ? 'no' : channelVibration} · '
        'ringer=$ringerMode · dnd=$interruptionFilter';
  }
}
