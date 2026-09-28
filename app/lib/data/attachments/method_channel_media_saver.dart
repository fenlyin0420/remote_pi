import 'package:app/domain/contracts/media_saver.dart';
import 'package:flutter/services.dart';

/// Production [MediaSaver] over the `.../media` MethodChannel.
class MethodChannelMediaSaver implements MediaSaver {
  MethodChannelMediaSaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// Must match `MainActivity.MEDIA_CHANNEL`.
  static const String channelName = 'work.jacobmoura.remotepi/media';

  final MethodChannel _channel;

  @override
  Future<String> save({
    required String path,
    required String mime,
    required String name,
  }) async {
    try {
      final where = await _channel.invokeMethod<String>('save', {
        'path': path,
        'mime': mime,
        'name': name,
      });
      if (where == null || where.isEmpty) {
        throw const MediaSaveException(
          'save_failed',
          'The platform did not report where the file went',
        );
      }
      return where;
    } on PlatformException catch (e) {
      throw MediaSaveException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const MediaSaveException(
        'unsupported',
        'Saving files is not available on this platform',
      );
    }
  }
}
