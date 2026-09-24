/// Hands a downloaded APK to the system installer.
///
/// Contract in the domain; the platform side lives in
/// `MainActivity.kt` behind a `MethodChannel` (see
/// `data/update/method_channel_apk_installer.dart`). Android deliberately
/// offers no silent install to ordinary apps, so [install] always ends in a
/// system-owned confirmation screen — the app only prepares and launches it.
abstract class ApkInstaller {
  /// Directory the APK must be written to before [install] will accept it.
  ///
  /// Owned by the platform side: the native installer confines paths to its
  /// own cache/updates dir, so Dart must ask where to put the file instead of
  /// guessing. Also avoids a direct `path_provider` dependency.
  Future<String> updateDownloadsDir();

  /// Whether this app is currently allowed to install packages ("install
  /// unknown apps"). False until the user grants it for this app.
  Future<bool> canInstall();

  /// Launches the installer for the APK at [path]. The file must live in the
  /// app's own cache dir (the native side enforces this).
  ///
  /// Throws [ApkInstallException] when the install cannot be started — the
  /// caller turns [ApkInstallException.code] into an actionable message.
  Future<void> install(String path);

  /// Opens the system screen where the user can grant this app the
  /// unknown-sources permission. No-op on platforms without it.
  Future<void> openInstallSettings();
}

/// Failure from [ApkInstaller], carrying the native error code.
class ApkInstallException implements Exception {
  const ApkInstallException(this.code, this.message);

  /// Native error code: `no_permission`, `bad_path`, `missing_apk`,
  /// `install_failed` (see `MainActivity.kt`).
  final String code;
  final String message;

  @override
  String toString() => 'ApkInstallException($code): $message';
}
