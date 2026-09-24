// The notification readback: parsing the platform's answer, and the one-line
// summary the settings screen shows. This is the tool that replaces "it doesn't
// buzz" / "what do your system settings say?" with a single look, so its
// decoding has to be literal.

import 'package:app/domain/contracts/background_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the platform map, including the pattern', () {
    final d = NotificationDiagnostics.fromMap(const {
      'appNotificationsEnabled': true,
      'channelId': 'messages_v2',
      'channelImportance': 4,
      'channelHasSound': true,
      'channelVibration': '0,250,200,250',
      'ringerMode': 'normal',
      'interruptionFilter': 'all',
    });

    expect(d.appNotificationsEnabled, isTrue);
    expect(d.channelId, 'messages_v2');
    expect(d.channelImportance, 4);
    expect(d.channelHasSound, isTrue);
    expect(d.channelVibration, '0,250,200,250');
    expect(d.summary, contains('importance=high'));
    expect(d.summary, contains('vibrate=0,250,200,250'));
    expect(d.summary, contains('ringer=normal'));
    expect(d.summary, contains('dnd=all'));
  });

  test('a silent setup reads back as silent, not as healthy', () {
    final d = NotificationDiagnostics.fromMap(const {
      'appNotificationsEnabled': true,
      'channelId': 'messages',
      'channelImportance': 3, // default: sound, but no heads-up
      'channelHasSound': true,
      'channelVibration': '', // the v1 bug: vibration enabled, nothing to play
      'ringerMode': 'silent',
      'interruptionFilter': 'priority',
    });

    expect(d.summary, contains('importance=default'));
    expect(d.summary, contains('vibrate=no'));
    expect(d.summary, contains('ringer=silent'));
    expect(d.summary, contains('dnd=priority'));
  });

  test('a blocked channel and missing fields are reported, not guessed', () {
    final blocked = NotificationDiagnostics.fromMap(const {
      'channelImportance': 0,
    });
    expect(blocked.channelImportance, 0);
    expect(blocked.summary, contains('importance=blocked'));
    expect(blocked.channelId, isEmpty);

    // Unknown keys/types must not throw — the platform is a different process.
    final junk = NotificationDiagnostics.fromMap(const {
      'channelImportance': 'four',
      'ringerMode': 7,
    });
    expect(junk.channelImportance, -1);
    expect(junk.summary, contains('importance=unknown'));
    expect(junk.ringerMode, 'unknown');
  });
}
