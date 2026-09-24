import 'dart:io' show Platform;

import 'package:app/domain/contracts/background_connection.dart';
import 'package:flutter/services.dart';

/// [BackgroundConnection] over the platform channel in `MainActivity.kt`.
///
/// Thin by design: the platform owns every decision (that a foreground service
/// is required, how the permission prompt behaves, which settings screen to
/// open). This only marshals calls and degrades to a no-op when the channel is
/// missing — iOS builds, widget tests — so callers never have to ask which
/// platform they are on.
class MethodChannelBackgroundConnection implements BackgroundConnection {
  MethodChannelBackgroundConnection({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel(channelName),
      _supported = isAndroid ?? Platform.isAndroid;

  /// Must match `MainActivity.BACKGROUND_CHANNEL`.
  static const String channelName = 'work.jacobmoura.remotepi/background';

  final MethodChannel _channel;
  final bool _supported;

  @override
  bool get isSupported => _supported;

  @override
  Future<void> start() => _invoke('start');

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Future<bool> isRunning() => _invokeBool('isRunning');

  @override
  Future<bool> notificationsEnabled() => _invokeBool('notificationsEnabled');

  @override
  Future<bool> requestNotificationPermission() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> openNotificationSettings() => _invoke('openNotificationSettings');

  @override
  Future<bool> isIgnoringBatteryOptimizations() =>
      _invokeBool('isIgnoringBatteryOptimizations');

  @override
  Future<void> requestIgnoreBatteryOptimizations() =>
      _invoke('requestIgnoreBatteryOptimizations');

  Future<void> _invoke(String method) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // Best-effort: the UI re-reads the platform state instead of trusting
      // that a call landed, so a swallowed failure surfaces as "still off".
    } on MissingPluginException {
      // ditto
    }
  }

  Future<bool> _invokeBool(String method) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
