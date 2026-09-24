import 'package:app/domain/contracts/apk_installer.dart';
import 'package:flutter/services.dart';

/// [ApkInstaller] backed by the platform channel in `MainActivity.kt`.
///
/// Kept deliberately thin: all policy (path confinement, permission check)
/// lives on the native side, so this only marshals calls and translates
/// `PlatformException` into the typed [ApkInstallException].
class MethodChannelApkInstaller implements ApkInstaller {
  MethodChannelApkInstaller({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Must match `MainActivity.CHANNEL`.
  static const String channelName = 'work.jacobmoura.remotepi/update';

  final MethodChannel _channel;

  @override
  Future<String> updateDownloadsDir() async {
    try {
      final dir = await _channel.invokeMethod<String>('updateDownloadsDir');
      if (dir == null || dir.isEmpty) {
        throw const ApkInstallException(
          'unsupported',
          'The platform did not report an update directory',
        );
      }
      return dir;
    } on PlatformException catch (e) {
      throw ApkInstallException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const ApkInstallException(
        'unsupported',
        'Updates are not available on this platform',
      );
    }
  }

  @override
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException {
      // No platform implementation (e.g. tests, iOS) → treat as not allowed;
      // the caller then offers the settings shortcut, which is also a no-op.
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> install(String path) async {
    try {
      await _channel.invokeMethod<void>('install', {'path': path});
    } on PlatformException catch (e) {
      throw ApkInstallException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const ApkInstallException(
        'unsupported',
        'Updates are not available on this platform',
      );
    }
  }

  @override
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on PlatformException {
      // Nothing actionable; the UI already shows a generic hint.
    } on MissingPluginException {
      // ditto
    }
  }
}
