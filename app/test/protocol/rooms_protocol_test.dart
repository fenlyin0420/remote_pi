// Tests for the new room-related control frames (plan 17).

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ControlInbound — rooms (plan 17)', () {
    test('room_announced parses with name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'name': 'work',
        'cwd': '/Users/jacob/projects/app',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.peer, 'epk_A');
      expect(r.roomId, 'room-uuid-1');
      expect(r.name, 'work');
      expect(r.cwd, '/Users/jacob/projects/app');
      expect(r.startedAt, 1700000000000);
    });

    test('room_announced tolerates missing name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'main',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.name, isNull);
      expect(r.cwd, isNull);
    });

    test('room_ended parses', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_ended',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'since_ts': 1700000010000,
      });
      expect(c, isA<RoomEnded>());
      final r = c! as RoomEnded;
      expect(r.roomId, 'room-uuid-1');
      expect(r.sinceTs, 1700000010000);
    });

    test('rooms snapshot parses with nested RoomInfo list', () {
      final c = ControlInbound.tryFromJson({
        'type': 'rooms',
        'peer': 'epk_A',
        'rooms': [
          {
            'room_id': 'r1',
            'name': 'one',
            'cwd': '/one',
            'started_at': 1000,
          },
          {
            'room_id': 'r2',
            'started_at': 2000,
          },
        ],
      });
      expect(c, isA<RoomsSnapshot>());
      final r = c! as RoomsSnapshot;
      expect(r.peer, 'epk_A');
      expect(r.rooms, hasLength(2));
      expect(r.rooms[0].roomId, 'r1');
      expect(r.rooms[0].cwd, '/one');
      expect(r.rooms[1].name, isNull);
      expect(r.rooms[1].cwd, isNull);
    });

    test(
      'room_announced parses optional `model` (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_announced',
          'peer': 'epk_A',
          'room_id': 'r1',
          'started_at': 1700000000000,
          'model': 'claude-sonnet-4.5',
        });
        expect(c, isA<RoomAnnounced>());
        expect((c! as RoomAnnounced).model, 'claude-sonnet-4.5');
      },
    );

    test(
      'room_meta_updated parses with model (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
          'meta': {'model': 'gpt-4o'},
        });
        expect(c, isA<RoomMetaUpdated>());
        final r = c! as RoomMetaUpdated;
        expect(r.peer, 'epk_A');
        expect(r.roomId, 'r1');
        expect(r.model, 'gpt-4o');
      },
    );

    test(
      'room_meta_updated tolerates missing meta / model (clears value)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
        });
        expect(c, isA<RoomMetaUpdated>());
        expect((c! as RoomMetaUpdated).model, isNull);
      },
    );

    test('room_announced parses top-level first_message (Plan/46)', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'r1',
        'started_at': 1700000000000,
        'first_message': 'what should we build?',
      });
      expect(c, isA<RoomAnnounced>());
      expect((c! as RoomAnnounced).firstMessage, 'what should we build?');
    });

    test('room_announced parses nested meta.first_message (forward-compat)', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'r1',
        'started_at': 1700000000000,
        'meta': {'first_message': 'nested message'},
      });
      expect(c, isA<RoomAnnounced>());
      expect((c! as RoomAnnounced).firstMessage, 'nested message');
    });

    test('room_announced without first_message yields null', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'r1',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      expect((c! as RoomAnnounced).firstMessage, isNull);
    });

    test('room_announced prefers top-level over nested first_message', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'r1',
        'started_at': 1700000000000,
        'first_message': 'top wins',
        'meta': {'first_message': 'nested'},
      });
      expect(c, isA<RoomAnnounced>());
      expect((c! as RoomAnnounced).firstMessage, 'top wins');
    });

    test('room_meta_updated parses meta.first_message with hasFirstMessage true (Plan/46)', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'epk_A',
        'room_id': 'r1',
        'meta': {'first_message': 'new opening'},
      });
      expect(c, isA<RoomMetaUpdated>());
      final r = c! as RoomMetaUpdated;
      expect(r.firstMessage, 'new opening');
      expect(r.hasFirstMessage, isTrue);
    });

    test(
        'room_meta_updated without first_message yields hasFirstMessage false',
        () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'epk_A',
        'room_id': 'r1',
        'meta': {'model': 'gpt-4o'},
      });
      expect(c, isA<RoomMetaUpdated>());
      final r = c! as RoomMetaUpdated;
      expect(r.firstMessage, isNull);
      expect(r.hasFirstMessage, isFalse);
    });

    test('room_meta_updated with explicit null first_message has hasFirstMessage true', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'epk_A',
        'room_id': 'r1',
        'meta': {'first_message': null},
      });
      expect(c, isA<RoomMetaUpdated>());
      final r = c! as RoomMetaUpdated;
      expect(r.firstMessage, isNull);
      expect(r.hasFirstMessage, isTrue);
    });

    test('RoomInfo serializes + parses firstMessage round-trip', () {
      const r = RoomInfo(
        roomId: 'r1',
        startedAt: 100,
        name: 'work',
        cwd: '/x',
        firstMessage: 'what should we build?',
      );
      final back = RoomInfo.fromJson(r.toJson());
      expect(back, r);
      expect(back.firstMessage, 'what should we build?');
    });

    test('RoomInfo omits absent firstMessage from JSON', () {
      const r = RoomInfo(
        roomId: 'r1',
        startedAt: 100,
        name: 'work',
        cwd: '/x',
      );
      final json = r.toJson();
      expect(json.containsKey('first_message'), isFalse);
    });

    test('RoomInfo serializes + parses model round-trip', () {
      const r = RoomInfo(
        roomId: 'r1',
        startedAt: 100,
        name: 'work',
        cwd: '/x',
        model: 'claude-sonnet-4.5',
      );
      final back = RoomInfo.fromJson(r.toJson());
      expect(back, r);
      expect(back.model, 'claude-sonnet-4.5');
    });

    test('outbound subscribe_rooms helper has correct shape', () {
      expect(subscribeRoomsFrame(['a', 'b']), {
        'type': 'subscribe_rooms',
        'peers': ['a', 'b'],
      });
      expect(unsubscribeRoomsFrame(['a']), {
        'type': 'unsubscribe_rooms',
        'peers': ['a'],
      });
      expect(roomsCheckFrame(['a']), {
        'type': 'rooms_check',
        'peers': ['a'],
      });
    });
  });
}
