/// Backs up and restores this device's identity through a file the user
/// chooses, so a replacement phone can adopt an existing pairing without
/// rescanning the QR.
///
/// Both operations are user-mediated: the platform shows a system file picker
/// and the future resolves to `null` if the user backs out. Neither throws on
/// cancellation — cancellation is a normal outcome, not a failure.
abstract class IdentityTransfer {
  /// Writes [json] to a location the user picks. Returns the file's display
  /// name, or `null` if the user cancelled.
  ///
  /// Throws [IdentityTransferException] only when the transfer genuinely
  /// failed (no picker available, write error).
  Future<String?> export({required String json, required String fileName});

  /// Reads a file the user picks. Returns its text, or `null` if cancelled.
  ///
  /// Throws [IdentityTransferException] on read failure.
  Future<String?> import();
}

/// A platform failure during transfer. [code] is stable for tests; [message]
/// is user-facing.
class IdentityTransferException implements Exception {
  final String code;
  final String message;

  const IdentityTransferException(this.code, this.message);

  @override
  String toString() => 'IdentityTransferException($code): $message';
}
