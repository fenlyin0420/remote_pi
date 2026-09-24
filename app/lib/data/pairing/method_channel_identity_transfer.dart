import 'package:app/domain/contracts/identity_transfer.dart';
import 'package:flutter/services.dart';

/// Production [IdentityTransfer] over the `.../identity` MethodChannel.
///
/// The native side runs the system file picker (Storage Access Framework on
/// Android). It resolves the call from `onActivityResult`, so the future may
/// stay pending for as long as the user has the picker open — callers must not
/// impose a short timeout on it.
///
/// Channel name must match `IDENTITY_CHANNEL` in `MainActivity.kt`.
class MethodChannelIdentityTransfer implements IdentityTransfer {
  static const _channel = MethodChannel('work.jacobmoura.remotepi/identity');

  @override
  Future<String?> export({
    required String json,
    required String fileName,
  }) async {
    try {
      return await _channel.invokeMethod<String>('exportIdentity', {
        'json': json,
        'fileName': fileName,
      });
    } on PlatformException catch (e) {
      throw _map(e);
    } on MissingPluginException {
      throw const IdentityTransferException(
        'unsupported',
        'Backup and restore are not available on this platform.',
      );
    }
  }

  @override
  Future<String?> import() async {
    try {
      return await _channel.invokeMethod<String>('importIdentity');
    } on PlatformException catch (e) {
      throw _map(e);
    } on MissingPluginException {
      throw const IdentityTransferException(
        'unsupported',
        'Backup and restore are not available on this platform.',
      );
    }
  }

  IdentityTransferException _map(PlatformException e) {
    final message = switch (e.code) {
      'busy' => 'A file picker is already open.',
      'picker_unavailable' =>
        'No file picker is available on this device.',
      'write_failed' => 'Could not write the backup file.',
      'read_failed' => 'Could not read the selected file.',
      'no_uri' => 'The file picker returned no file.',
      _ => e.message ?? 'The file could not be transferred.',
    };
    return IdentityTransferException(e.code, message);
  }
}
