import 'dart:async';
import 'dart:io' show Platform;

import 'package:app/domain/contracts/message_notifier.dart';
import 'package:flutter/services.dart';

/// [MessageNotifier] over the platform channel in `MainActivity.kt`.
///
/// Sets its own method-call handler for the native → Dart `onNotificationTap`
/// wake-up. The tap payload deliberately arrives through [takePendingTap]
/// instead of that call: a tap can launch the app from cold, and pulling the
/// destination when the router is ready is the one ordering that works for both
/// cases.
class MethodChannelNotifier implements MessageNotifier {
  MethodChannelNotifier({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel(channelName),
      _supported = isAndroid ?? Platform.isAndroid {
    if (_supported) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onNotificationTap' && !_taps.isClosed) {
          _taps.add(null);
        }
        return null;
      });
    }
  }

  /// Must match `MainActivity.NOTIFICATIONS_CHANNEL`.
  static const String channelName = 'work.jacobmoura.remotepi/notifications';

  final MethodChannel _channel;
  final bool _supported;
  final _taps = StreamController<void>.broadcast();

  @override
  Stream<void> get taps => _taps.stream;

  @override
  Future<NotificationTap?> takePendingTap() async {
    if (!_supported) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>('pendingTap');
      if (raw is! Map) return null;
      final epk = raw['epk'];
      final room = raw['room'];
      if (epk is! String || room is! String) return null;
      return NotificationTap(epk: epk, roomId: room);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> show({
    required String epk,
    required String roomId,
    required String title,
    required String body,
    String device = '',
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('show', {
        'epk': epk,
        'room': roomId,
        'title': title,
        'body': body,
        'device': device,
      });
    } on PlatformException {
      // Posting failed (channel blocked, service restrictions). The transcript
      // already holds the message, so a missing banner is not data loss.
    } on MissingPluginException {
      // ditto
    }
  }

  @override
  Future<void> cancel({required String epk, required String roomId}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('cancel', {'epk': epk, 'room': roomId});
    } on PlatformException {
      // Nothing actionable.
    } on MissingPluginException {
      // ditto
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } on PlatformException {
      // Nothing actionable.
    } on MissingPluginException {
      // ditto
    }
  }
}
