import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/entities/identity_bundle.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

OwnerIdentity _identity({int pkSeed = 1, int skSeed = 2}) => OwnerIdentity(
  ownerPk: Uint8List.fromList(List.generate(32, (i) => (pkSeed + i) % 256)),
  ownerSk: Uint8List.fromList(List.generate(32, (i) => (skSeed + i) % 256)),
);

PeerRecord _peer(String epk, {String? nickname}) => PeerRecord(
  remoteEpk: epk,
  sessionName: 'session-$epk',
  relayUrl: 'http://relay.test:3000',
  pairedAt: '2026-09-24T00:00:00.000Z',
  nickname: nickname,
  roomId: 'room-$epk',
);

IdentityBundle _bundle({
  List<PeerRecord> peers = const [],
  String exportedAt = '2026-09-24T12:34:56.000Z',
}) => IdentityBundle(
  identity: _identity(),
  peers: peers,
  exportedAt: exportedAt,
);

void main() {
  group('IdentityBundle round trip', () {
    test('encode → decode preserves the keypair byte for byte', () {
      final original = _identity(pkSeed: 9, skSeed: 200);
      final decoded = IdentityBundle.decode(
        IdentityBundle(
          identity: original,
          peers: const [],
          exportedAt: '2026-09-24T12:34:56.000Z',
        ).encode(),
      );
      expect(decoded.identity.ownerPk, original.ownerPk);
      expect(decoded.identity.ownerSk, original.ownerSk);
    });

    test('encode → decode preserves peers including optional fields', () {
      final decoded = IdentityBundle.decode(
        _bundle(peers: [_peer('abc', nickname: 'My Pi'), _peer('def')]).encode(),
      );
      expect(decoded.peers, hasLength(2));
      expect(decoded.peers.first.remoteEpk, 'abc');
      expect(decoded.peers.first.nickname, 'My Pi');
      expect(decoded.peers.first.roomId, 'room-abc');
      // Absent nickname must stay absent, not become an empty string.
      expect(decoded.peers[1].nickname, isNull);
    });

    test('exportedAt survives the round trip (shown in the confirm dialog)', () {
      final decoded = IdentityBundle.decode(
        _bundle(exportedAt: '2026-01-02T03:04:05.000Z').encode(),
      );
      expect(decoded.exportedAt, '2026-01-02T03:04:05.000Z');
    });

    test('peer with a missing optional field is still readable', () {
      // PeerRecord.fromJson tolerates fields added after it was written.
      final raw = jsonEncode({
        'magic': IdentityBundle.magic,
        'format_version': 1,
        'exported_at': '2026-09-24T00:00:00.000Z',
        'owner_pk': base64Encode(List.filled(32, 1)),
        'owner_sk': base64Encode(List.filled(32, 2)),
        'peers': [
          {
            'remote_epk': 'legacy',
            'session_name': 's',
            'relay_url': 'http://r:1',
            'paired_at': '2025-01-01T00:00:00.000Z',
          },
        ],
      });
      final decoded = IdentityBundle.decode(raw);
      expect(decoded.peers.single.remoteEpk, 'legacy');
      expect(decoded.peers.single.nickname, isNull);
      expect(decoded.peers.single.roomId, isNull);
    });
  });

  group('IdentityBundle.decode — rejection', () {
    // A bad file must be recognisably bad. These messages go straight to the
    // user, so they are asserted rather than just the exception type.
    test('not JSON → "not a Remote Pi backup"', () {
      expect(
        () => IdentityBundle.decode('definitely not json'),
        throwsA(
          isA<IdentityBundleFormatException>()
              .having((e) => e.code, 'code', 'not_json')
              .having((e) => e.message, 'message', contains('not a Remote Pi')),
        ),
      );
    });

    test('JSON but not an object → rejected', () {
      expect(
        () => IdentityBundle.decode('[1,2,3]'),
        throwsA(
          isA<IdentityBundleFormatException>()
              .having((e) => e.code, 'code', 'not_json'),
        ),
      );
    });

    test('valid JSON without our magic → rejected', () {
      expect(
        () => IdentityBundle.decode('{"version": 1, "foo": "bar"}'),
        throwsA(
          isA<IdentityBundleFormatException>()
              .having((e) => e.code, 'code', 'wrong_file'),
        ),
      );
    });

    test('missing format_version → corrupt', () {
      final raw = jsonEncode({'magic': IdentityBundle.magic});
      expect(
        () => IdentityBundle.decode(raw),
        throwsA(
          isA<IdentityBundleFormatException>()
              .having((e) => e.code, 'code', 'corrupt'),
        ),
      );
    });

    test('newer format → tells the user to update, not "corrupt"', () {
      final raw = jsonEncode({
        'magic': IdentityBundle.magic,
        'format_version': 99,
        'owner_pk': base64Encode(List.filled(32, 1)),
        'owner_sk': base64Encode(List.filled(32, 2)),
      });
      expect(
        () => IdentityBundle.decode(raw),
        throwsA(
          isA<IdentityBundleFormatException>()
              .having((e) => e.code, 'code', 'too_new')
              .having((e) => e.message, 'message', contains('Update the app')),
        ),
      );
    });

    test('key material that is not base64 → corrupt', () {
      final raw = jsonEncode({
        'magic': IdentityBundle.magic,
        'format_version': 1,
        'owner_pk': '!!!not base64!!!',
        'owner_sk': base64Encode(List.filled(32, 2)),
      });
      expect(
        () => IdentityBundle.decode(raw),
        throwsA(
          isA<IdentityBundleFormatException>()
              .having((e) => e.code, 'code', 'corrupt'),
        ),
      );
    });

    test('truncated key (wrong length) → corrupt, not a crash', () {
      // This is the case a hand-edited or partially-written file hits.
      final raw = jsonEncode({
        'magic': IdentityBundle.magic,
        'format_version': 1,
        'owner_pk': base64Encode(List.filled(16, 1)),
        'owner_sk': base64Encode(List.filled(32, 2)),
      });
      expect(
        () => IdentityBundle.decode(raw),
        throwsA(
          isA<IdentityBundleFormatException>()
              .having((e) => e.code, 'code', 'corrupt')
              .having(
                (e) => e.message,
                'message',
                contains('wrong length'),
              ),
        ),
      );
    });

    test('a malformed peer is skipped, the keypair still imports', () {
      // Losing a peer is recoverable (re-pair); losing the keypair is not.
      // So a bad entry must not sink the whole restore.
      final raw = jsonEncode({
        'magic': IdentityBundle.magic,
        'format_version': 1,
        'exported_at': '2026-09-24T00:00:00.000Z',
        'owner_pk': base64Encode(List.filled(32, 1)),
        'owner_sk': base64Encode(List.filled(32, 2)),
        'peers': [
          {'remote_epk': 'good', 'session_name': 's', 'relay_url': 'http://r', 'paired_at': 't'},
          {'remote_epk': 12345}, // wrong types → fromJson throws
        ],
      });
      final decoded = IdentityBundle.decode(raw);
      expect(decoded.peers, hasLength(1));
      expect(decoded.peers.single.remoteEpk, 'good');
    });

    test('peers missing entirely → empty list, keypair still usable', () {
      final raw = jsonEncode({
        'magic': IdentityBundle.magic,
        'format_version': 1,
        'owner_pk': base64Encode(List.filled(32, 1)),
        'owner_sk': base64Encode(List.filled(32, 2)),
      });
      expect(IdentityBundle.decode(raw).peers, isEmpty);
    });
  });

  group('suggestedFileName', () {
    test('is date-stamped from exportedAt so exports do not collide', () {
      expect(
        _bundle(exportedAt: '2026-09-24T12:34:56.000Z').suggestedFileName(),
        'remote-pi-identity-20260924-1234.json',
      );
    });

    test('falls back to a usable name when exportedAt is unparseable', () {
      expect(
        _bundle(exportedAt: 'garbage').suggestedFileName(),
        'remote-pi-identity-backup.json',
      );
    });
  });
}
