/// State of the Settings → "Background connection" section.
///
/// A plain value object rather than a sealed hierarchy: the section has no
/// flows, only a switch and three platform facts that must agree with reality.
/// Each is re-read from the OS instead of being inferred, so the screen can
/// never claim "notifications on" while the system has them blocked.
class BackgroundDeliveryState {
  const BackgroundDeliveryState({
    required this.enabled,
    required this.supported,
    required this.running,
    required this.notificationsEnabled,
    required this.batteryExempt,
    this.busy = false,
  });

  /// The user's switch ([Preferences.backgroundConnection]).
  final bool enabled;

  /// Whether this platform can hold a background connection at all.
  final bool supported;

  /// Whether the foreground keeper is running right now (asked of the OS).
  final bool running;

  /// Whether notifications can actually be posted.
  final bool notificationsEnabled;

  /// Whether the OS exempts this app from battery optimization.
  final bool batteryExempt;

  /// A permission prompt or settings hop is in flight.
  final bool busy;

  BackgroundDeliveryState copyWith({
    bool? enabled,
    bool? supported,
    bool? running,
    bool? notificationsEnabled,
    bool? batteryExempt,
    bool? busy,
  }) => BackgroundDeliveryState(
    enabled: enabled ?? this.enabled,
    supported: supported ?? this.supported,
    running: running ?? this.running,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    batteryExempt: batteryExempt ?? this.batteryExempt,
    busy: busy ?? this.busy,
  );

  @override
  bool operator ==(Object other) =>
      other is BackgroundDeliveryState &&
      other.enabled == enabled &&
      other.supported == supported &&
      other.running == running &&
      other.notificationsEnabled == notificationsEnabled &&
      other.batteryExempt == batteryExempt &&
      other.busy == busy;

  @override
  int get hashCode => Object.hash(
    enabled,
    supported,
    running,
    notificationsEnabled,
    batteryExempt,
    busy,
  );
}
