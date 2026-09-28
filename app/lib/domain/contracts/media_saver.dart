/// Puts a file the Pi sent into the device's shared storage.
///
/// The app's own cache is not a place a user can keep anything: the system may
/// wipe it, and no gallery or file manager shows it. Saving means the file has
/// to land where the user expects — an image in the gallery, anything else in
/// Downloads.
///
/// Contract in the domain; the platform side lives in `MainActivity.kt` behind
/// a `MethodChannel` (`.../media`) writing through MediaStore. MediaStore
/// rather than a system file picker because the app's `minSdk` is 34: the
/// insert needs no storage permission, and the user gets one tap instead of a
/// dialog per save.
abstract class MediaSaver {
  /// Copies the file at [path] into shared storage and returns where it went
  /// (e.g. `Pictures/Remote Pi/shot.png`).
  ///
  /// Throws [MediaSaveException] with a [MediaSaveException.code] the caller
  /// turns into a message.
  Future<String> save({
    required String path,
    required String mime,
    required String name,
  });
}

class MediaSaveException implements Exception {
  const MediaSaveException(this.code, this.message);

  /// `bad_args` | `bad_path` | `missing_file` | `save_failed` |
  /// `unsupported` (see `MainActivity.kt`).
  final String code;
  final String message;

  @override
  String toString() => 'MediaSaveException($code): $message';
}
