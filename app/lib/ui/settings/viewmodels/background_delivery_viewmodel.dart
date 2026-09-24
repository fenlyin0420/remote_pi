import 'package:app/data/background/background_delivery.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/contracts/background_connection.dart';
import 'package:app/domain/contracts/message_notifier.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/settings/states/background_delivery_state.dart';

/// Drives Settings → "Background connection".
///
/// Thin on purpose: the switch only writes the preference and then asks
/// [BackgroundDelivery] to apply it, so there is exactly one writer for
/// "should the foreground keeper be up" — the service, which also knows that
/// nothing should run with no paired peer. Everything else here reads the
/// platform's own answer, because the interesting failures (permission revoked
/// in system settings, OEM battery manager killing the service) happen outside
/// this app and would make any cached value a lie.
class BackgroundDeliveryViewModel extends ViewModel<BackgroundDeliveryState> {
  BackgroundDeliveryViewModel(
    Preferences prefs,
    BackgroundConnection background,
    BackgroundDelivery delivery,
    MessageNotifier notifier,
  ) : _prefs = prefs,
      _background = background,
      _delivery = delivery,
      _notifier = notifier,
      super(
        BackgroundDeliveryState(
          // Both of these are synchronous getters, so the section renders with
          // the right switch state and visibility on the first frame instead of
          // flickering past the async refresh.
          enabled: prefs.backgroundConnection,
          supported: background.isSupported,
          running: false,
          notificationsEnabled: false,
          batteryExempt: false,
        ),
      ) {
    // ignore: discarded_futures
    refresh();
  }

  final Preferences _prefs;
  final BackgroundConnection _background;
  final BackgroundDelivery _delivery;
  final MessageNotifier _notifier;

  /// Re-reads the platform state. Call on entry and after anything that can
  /// change it (toggling, returning from a system settings screen).
  Future<void> refresh() async {
    if (!_background.isSupported) {
      emit(
        BackgroundDeliveryState(
          enabled: _prefs.backgroundConnection,
          supported: false,
          running: false,
          notificationsEnabled: false,
          batteryExempt: false,
        ),
      );
      return;
    }
    final running = await _background.isRunning();
    final notifications = await _background.notificationsEnabled();
    final battery = await _background.isIgnoringBatteryOptimizations();
    final diagnostics = await _background.notificationDiagnostics();
    emit(
      BackgroundDeliveryState(
        enabled: _prefs.backgroundConnection,
        supported: true,
        running: running,
        notificationsEnabled: notifications,
        batteryExempt: battery,
        diagnostics: diagnostics,
      ),
    );
  }

  /// Turns background delivery on/off.
  ///
  /// On the way up, asks for the notification permission: the notification is
  /// the entire point of the feature, and this is the one moment the request has
  /// obvious context. Denying it is not fatal — the connection stays up and the
  /// section offers the system-settings route instead.
  Future<void> setEnabled(bool value) async {
    if (_prefs.backgroundConnection == value) return;
    emit(state.copyWith(enabled: value, busy: true));
    await _prefs.setBackgroundConnection(value);
    if (value) {
      await _background.requestNotificationPermission();
    }
    await _delivery.syncKeeper();
    emit(state.copyWith(busy: false));
    await refresh();
  }

  /// System notification settings — the only way forward when the permission is
  /// granted but notifications were switched off for the app.
  ///
  /// No `busy` flag: the jump is synchronous and the user comes back through
  /// `refresh` (the section rebuilds on return, and this VM re-reads the OS
  /// state on entry).
  Future<void> openNotificationSettings() =>
      _background.openNotificationSettings();

  /// Asks the OS to exempt this app from battery optimization.
  Future<void> requestBatteryExemption() async {
    emit(state.copyWith(busy: true));
    await _background.requestIgnoreBatteryOptimizations();
    emit(state.copyWith(busy: false));
    await refresh();
  }

  /// Posts a sample notification so the user can check sound + vibration, and
  /// so the answer to "it didn't buzz" starts with "did the test buzz?".
  Future<void> sendTestNotification() => _notifier.showTest();

  /// Re-applies "the keeper should be up" after the OS stopped it (OEM battery
  /// managers do this without telling anyone). Goes through the service so the
  /// peer-count rule still applies.
  Future<void> restartKeeper() async {
    emit(state.copyWith(busy: true));
    await _delivery.syncKeeper();
    emit(state.copyWith(busy: false));
    await refresh();
  }
}
