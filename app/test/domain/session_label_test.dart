// Session labels — one rule shared by the Home tile, the chat AppBar and
// notification banners, so a notification never names a session the user cannot
// find in the list.

import 'package:app/domain/value_objects/session_label.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _peer({String? nickname, String sessionName = 'mac-mini'}) =>
    PeerRecord(
      remoteEpk: 'abcdefghijklmnop',
      sessionName: sessionName,
      relayUrl: 'ws://localhost:8080',
      pairedAt: '2026-01-01T00:00:00Z',
      nickname: nickname,
    );

RoomInfo _room({String? name, String? cwd}) =>
    RoomInfo(roomId: 'room-a', name: name, cwd: cwd, startedAt: 0);

void main() {
  group('deviceLabel', () {
    test('prefers the user nickname', () {
      expect(deviceLabel(_peer(nickname: 'phone-mac')), 'phone-mac');
    });

    test('falls back to the announced session name', () {
      expect(deviceLabel(_peer()), 'mac-mini');
    });

    test('falls back to a key prefix when even that is empty', () {
      expect(deviceLabel(_peer(sessionName: '')), 'abcdefgh');
    });
  });

  group('roomLabel', () {
    test('prefers the room name (which already carries a local rename)', () {
      expect(roomLabel(_room(name: 'remote_pi')), 'remote_pi');
    });

    test('falls back to the last segment of the working directory', () {
      expect(
        roomLabel(_room(cwd: '/home/fenlyin/Documents/GitHub/remote_pi')),
        'remote_pi',
      );
      expect(roomLabel(_room(cwd: '/home/fenlyin/remote/')), 'remote');
    });

    test('null when there is nothing to name the room with', () {
      expect(roomLabel(null), isNull);
      expect(roomLabel(_room()), isNull);
      expect(roomLabel(_room(cwd: '/')), isNull);
    });
  });
}
