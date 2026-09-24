import 'dart:typed_data';

import 'package:app/data/pairing/identity_transfer_service.dart';
import 'package:app/domain/contracts/identity_transfer.dart';
import 'package:app/domain/entities/identity_bundle.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

import '../../support/fake_secure_storage.dart';

/// Hand-written fake: records the bytes handed to the platform and returns
/// whatever the test queues next. `null` models the user cancelling the picker.
class _FakeTransfer implements IdentityTransfer {
  final List<String> exportedJsons = [];
  final List<String> exportedNames = [];
  String? exportResult = 'remote-pi-identity.json';
  IdentityTransferException? exportError;

  /// Queue of responses for [import]; each call pops the first.
  final List<String?> importQueue = [];
  IdentityTransferException? importError;

  @override
  Future<String?> export({
    required String json,
    required String fileName,
  }) async {
    if (exportError != null) throw exportError!;
    exportedJsons.add(json);
    exportedNames.add(fileName);
    return exportResult;
  }

  @override
  Future<String?> import() async {
    if (importError != null) throw importError!;
    if (importQueue.isEmpty) return null;
    return importQueue.removeAt(0);
  }
}

OwnerIdentity _identity(int pkSeed) => OwnerIdentity(
  ownerPk: Uint8List.fromList(List.generate(32, (i) => (pkSeed + i) % 256)),
  ownerSk: Uint8List.fromList(List.generate(32, (i) => (pkSeed + 50 + i) % 256)),
);

PeerRecord _peer(String epk) => PeerRecord(
  remoteEpk: epk,
  sessionName: 'session-$epk',
  relayUrl: 'http://relay.test:3000',
  pairedAt: '2026-09-24T00:00:00.000Z',
  roomId: 'room-$epk',
);

String _bundleJson({
  required OwnerIdentity identity,
  List<PeerRecord> peers = const [],
  String exportedAt = '2026-09-24T12:00:00.000Z',
}) => IdentityBundle(
  identity: identity,
  peers: peers,
  exportedAt: exportedAt,
).encode();

void main() {
  late _FakeTransfer transfer;
  late PairingStorage storage;
  late InMemoryOwnerIdentityStore store;
  late OwnerIdentityBridge bridge;
  late IdentityTransferService service;

  /// Boots the bridge with [initial] so `currentIdentity` is populated, the
  /// same way the router does before Settings is reachable.
  Future<void> boot({
    OwnerIdentity? initial,
    bool seedStorage = true,
  }) async {
    storage = PairingStorage(FakeSecureStorage());
    store = InMemoryOwnerIdentityStore(initial: initial);
    bridge = OwnerIdentityBridge(store, storage);
    await bridge.boot();
    service = IdentityTransferService(
      transfer: transfer,
      bridge: bridge,
      pairing: storage,
      identityStore: store,
    );
  }

  setUp(() {
    transfer = _FakeTransfer();
  });

  group('export', () {
    test('writes the current identity and every peer', () async {
      await boot(initial: _identity(7));
      await storage.savePeer(_peer('peer-a'));
      await storage.savePeer(_peer('peer-b'));

      final name = await service.export();
      expect(name, 'remote-pi-identity.json');
      expect(transfer.exportedJsons, hasLength(1));

      final bundle = IdentityBundle.decode(transfer.exportedJsons.single);
      expect(bundle.identity.ownerPk, _identity(7).ownerPk);
      expect(bundle.identity.ownerSk, _identity(7).ownerSk);
      expect(
        bundle.peers.map((p) => p.remoteEpk).toSet(),
        {'peer-a', 'peer-b'},
      );
    });

    test('suggests a date-stamped filename', () async {
      await boot(initial: _identity(7));
      await service.export();
      expect(transfer.exportedNames.single, startsWith('remote-pi-identity-'));
      expect(transfer.exportedNames.single, endsWith('.json'));
    });

    test('the payload is the bundle, not the suggested filename', () async {
      // Guards a real shipped bug: the Android side stored the filename in the
      // slot meant for the JSON and wrote *that* to disk, producing a backup
      // file containing only its own name. Nothing here could catch the native
      // write, but the two arguments must at least stay distinct and the
      // payload must survive as parseable JSON.
      await boot(initial: _identity(7));
      await service.export();

      final payload = transfer.exportedJsons.single;
      final name = transfer.exportedNames.single;
      expect(payload, isNot(equals(name)));
      expect(payload, isNot(contains('.json')));
      // Still a real, parseable bundle rather than a stray string.
      expect(IdentityBundle.decode(payload).identity.ownerPk, _identity(7).ownerPk);
    });

    test('cancelling the picker returns null without an error', () async {
      await boot(initial: _identity(7));
      transfer.exportResult = null;
      expect(await service.export(), isNull);
    });

    test('exporting before boot throws rather than writing a partial file',
        () async {
      storage = PairingStorage(FakeSecureStorage());
      store = InMemoryOwnerIdentityStore();
      bridge = OwnerIdentityBridge(store, storage);
      service = IdentityTransferService(
        transfer: transfer,
        bridge: bridge,
        pairing: storage,
        identityStore: store,
      );
      expect(() => service.export(), throwsStateError);
      expect(transfer.exportedJsons, isEmpty);
    });
  });

  group('import — device swap', () {
    test('adopts the incoming keypair and peers', () async {
      await boot(initial: _identity(1));
      await storage.savePeer(_peer('old-peer'));

      transfer.importQueue.add(
        _bundleJson(identity: _identity(99), peers: [_peer('new-peer')]),
      );

      final result = (await service.import())!;
      expect(result.keypairChanged, isTrue);
      expect(result.peerCount, 1);

      // In-memory identity swapped...
      expect(bridge.currentIdentity!.ownerPk, _identity(99).ownerPk);
      // ...persisted to the platform store so the next boot loads it...
      expect((await store.load())!.ownerPk, _identity(99).ownerPk);
      // ...and the peer set now holds the imported peer, not the old one.
      final peers = await storage.listPeers();
      expect(peers.map((p) => p.remoteEpk), ['new-peer']);
    });

    test('the previous identity\'s peers are cleared, not merged', () async {
      // The critical ordering: peers from the old identity point at handles
      // the relay no longer accepts for the new key. Merging would leave the
      // user with unremovable ghost pairings.
      await boot(initial: _identity(1));
      await storage.savePeer(_peer('stale-1'));
      await storage.savePeer(_peer('stale-2'));

      transfer.importQueue.add(
        _bundleJson(identity: _identity(99), peers: [_peer('fresh')]),
      );
      await service.import();

      final peers = await storage.listPeers();
      expect(peers.map((p) => p.remoteEpk), ['fresh']);
    });

    test('restoring wipes stale rooms too (they are keyed by peer)', () async {
      await boot(initial: _identity(1));
      await storage.saveRooms('stale-1', [
        const PersistedRoom(roomId: 'r1', startedAt: 1),
      ]);

      transfer.importQueue.add(
        _bundleJson(identity: _identity(99), peers: [_peer('fresh')]),
      );
      await service.import();

      expect(await storage.loadRooms('stale-1'), isEmpty);
    });

    test('an empty peer list still swaps the keypair', () async {
      // Moving to a bare identity is legitimate — the user may restore only
      // the identity and re-pair later.
      await boot(initial: _identity(1));
      await storage.savePeer(_peer('old'));

      transfer.importQueue.add(_bundleJson(identity: _identity(99)));
      final result = (await service.import())!;

      expect(result.keypairChanged, isTrue);
      expect(result.peerCount, 0);
      expect(await storage.listPeers(), isEmpty);
      expect(bridge.currentIdentity!.ownerPk, _identity(99).ownerPk);
    });
  });

  group('import — same device', () {
    test('re-importing this device\'s own backup does not wipe peers',
        () async {
      // Same Owner pk → nothing about the identity changes, so the existing
      // peer cache is still valid and must survive.
      final id = _identity(42);
      await boot(initial: id);
      await storage.savePeer(_peer('keep-me'));

      transfer.importQueue.add(
        _bundleJson(identity: _identity(42), peers: [_peer('from-backup')]),
      );
      final result = (await service.import())!;

      expect(result.keypairChanged, isFalse);
      final peers = (await storage.listPeers())
          .map((p) => p.remoteEpk)
          .toSet();
      // The pre-existing peer is still there and the backup's peer was added.
      expect(peers, {'keep-me', 'from-backup'});
    });

    test('does not re-save the identity when the keypair is unchanged',
        () async {
      final id = _identity(42);
      await boot(initial: id);
      final before = await store.load();
      transfer.importQueue.add(_bundleJson(identity: _identity(42)));
      await service.import();
      // Same object identity → no redundant platform write.
      expect(identical(await store.load(), before), isTrue);
    });
  });

  group('import — failure handling', () {
    test('cancelling returns null and changes nothing', () async {
      await boot(initial: _identity(1));
      await storage.savePeer(_peer('untouched'));
      transfer.importQueue.add(null);

      expect(await service.import(), isNull);
      expect(bridge.currentIdentity!.ownerPk, _identity(1).ownerPk);
      expect((await storage.listPeers()).single.remoteEpk, 'untouched');
    });

    test('a bad file leaves the device exactly as it was', () async {
      // Parsing happens before any mutation, so a rejected file must not have
      // wiped peers or touched the identity.
      await boot(initial: _identity(1));
      await storage.savePeer(_peer('untouched'));

      transfer.importQueue.add('{"magic":"not-ours"}');
      await expectLater(
        service.import(),
        throwsA(isA<IdentityBundleFormatException>()),
      );

      expect(bridge.currentIdentity!.ownerPk, _identity(1).ownerPk);
      expect((await storage.listPeers()).single.remoteEpk, 'untouched');
    });

    test('a corrupt key is rejected before the store is written', () async {
      await boot(initial: _identity(1));
      transfer.importQueue.add(
        _bundleJson(identity: _identity(99)).replaceAll(
          '"owner_sk"',
          '"owner_sk_broken"',
        ),
      );
      await expectLater(
        service.import(),
        throwsA(isA<IdentityBundleFormatException>()),
      );
      expect((await store.load())!.ownerPk, _identity(1).ownerPk);
    });
  });

  group('peek / apply split', () {
    test('peek parses without mutating anything', () async {
      await boot(initial: _identity(1));
      transfer.importQueue.add(
        _bundleJson(identity: _identity(99), peers: [_peer('p')]),
      );

      final bundle = (await service.peek())!;
      expect(bundle.identity.ownerPk, _identity(99).ownerPk);
      // Nothing applied yet — confirm dialog has not been answered.
      expect(bridge.currentIdentity!.ownerPk, _identity(1).ownerPk);
      expect(await storage.listPeers(), isEmpty);
    });

    test('apply commits a previously peeked bundle', () async {
      await boot(initial: _identity(1));
      transfer.importQueue.add(
        _bundleJson(identity: _identity(99), peers: [_peer('p')]),
      );

      final bundle = (await service.peek())!;
      final result = await service.apply(bundle);

      expect(result.keypairChanged, isTrue);
      expect(bridge.currentIdentity!.ownerPk, _identity(99).ownerPk);
      expect((await storage.listPeers()).single.remoteEpk, 'p');
    });
  });

  group('describe', () {
    test('summarises date and peer count for the confirm dialog', () {
      final bundle = IdentityBundle(
        identity: _identity(1),
        peers: [_peer('a'), _peer('b')],
        exportedAt: '2026-09-24T12:00:00.000Z',
      );
      final text = IdentityTransferService.describe(bundle);
      expect(text, contains('2 paired Pis'));
      expect(text, contains('2026-09-24'));
    });

    test('singularises one peer', () {
      final bundle = IdentityBundle(
        identity: _identity(1),
        peers: [_peer('a')],
        exportedAt: '2026-09-24T12:00:00.000Z',
      );
      expect(IdentityTransferService.describe(bundle), contains('1 paired Pi.'));
    });

    test('handles a missing date without printing "null"', () {
      final bundle = IdentityBundle(
        identity: _identity(1),
        peers: const [],
        exportedAt: '',
      );
      expect(
        IdentityTransferService.describe(bundle),
        contains('unknown date'),
      );
    });
  });
}
