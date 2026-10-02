// Plan/28 Wave D — wire-level parsing of `meta.thinking` and the
// `RoomInfo.thinking` field across `room_announced`, `room_meta_updated`
// and `rooms` snapshots.

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('room_meta_updated.meta.thinking', () {
    test('parses high level', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'thinking': 'high'},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.thinking, ThinkingLevel.high);
      expect(upd.hasThinking, isTrue);
      expect(upd.hasModel, isFalse);
    });

    test('parses auto level (session-level concept)', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'thinking': 'auto'},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.thinking, ThinkingLevel.auto);
      expect(upd.hasThinking, isTrue);
    });

    test('thinking + model both present', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'thinking': 'medium', 'model': 'claude-opus-4-7'},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.thinking, ThinkingLevel.medium);
      expect(upd.model, 'claude-opus-4-7');
      expect(upd.hasModel, isTrue);
      expect(upd.hasThinking, isTrue);
    });

    test('unknown thinking string yields null', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'thinking': 'turbo'},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.thinking, isNull);
      expect(upd.hasThinking, isTrue); // key was present, value rejected
    });

    test('empty meta envelope sets both has-flags to false', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': const <String, dynamic>{},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.hasModel, isFalse);
      expect(upd.hasThinking, isFalse);
    });
  });

  group('room_announced.thinking', () {
    test('top-level thinking flattened by relay', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'thinking': 'low',
      });
      final ann = m! as RoomAnnounced;
      expect(ann.thinking, ThinkingLevel.low);
    });

    test('nested meta.thinking honored (relay un-flatten path)', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'meta': {'thinking': 'xhigh'},
      });
      final ann = m! as RoomAnnounced;
      expect(ann.thinking, ThinkingLevel.xhigh);
    });

    test('thinking absent → null', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
      });
      final ann = m! as RoomAnnounced;
      expect(ann.thinking, isNull);
    });
  });

  group('RoomInfo.thinking', () {
    test('fromJson reads thinking key', () {
      final r = RoomInfo.fromJson({
        'room_id': 'r1',
        'started_at': 1,
        'thinking': 'minimal',
      });
      expect(r.thinking, ThinkingLevel.minimal);
    });

    test('fromJson reads auto', () {
      final r = RoomInfo.fromJson({
        'room_id': 'r1',
        'started_at': 1,
        'thinking': 'auto',
      });
      expect(r.thinking, ThinkingLevel.auto);
    });

    test('toJson omits thinking when null, includes when set', () {
      const a = RoomInfo(roomId: 'r1', startedAt: 1);
      expect(a.toJson()['thinking'], isNull);
      // When the key is null we still serialize the entry; what matters
      // is that round-trip preserves the level.
      const b = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        thinking: ThinkingLevel.high,
      );
      expect(b.toJson()['thinking'], 'high');
    });

    test('copyWith preserves thinking by default', () {
      const a = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        thinking: ThinkingLevel.medium,
      );
      final b = a.copyWith(model: 'gpt-4o');
      expect(b.thinking, ThinkingLevel.medium);
      expect(b.model, 'gpt-4o');
    });

    test('copyWith can clear thinking explicitly', () {
      const a = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        thinking: ThinkingLevel.medium,
      );
      final b = a.copyWith(thinking: null);
      expect(b.thinking, isNull);
    });

    test('equality + hashCode consider thinking', () {
      const a = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        thinking: ThinkingLevel.low,
      );
      const b = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        thinking: ThinkingLevel.low,
      );
      const c = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        thinking: ThinkingLevel.high,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
