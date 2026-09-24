import 'dart:typed_data';

import 'package:app/data/pairing/identity_transfer_service.dart';
import 'package:app/domain/contracts/identity_transfer.dart';
import 'package:app/domain/entities/identity_bundle.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/settings/states/identity_backup_state.dart';
import 'package:app/ui/settings/viewmodels/identity_backup_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

import '../../support/fake_secure_storage.dart';

class _FakeTransfer implements IdentityTransfer {
  final List<String?> importQueue = [];
  String? exportResult = 'file.json';
  IdentityTransferException? exportError;
  IdentityTransferException? importError;
  String? exportedJson;

  @override
  Future<String?> export({
    required String json,
    required String fileName,
  }) async {
    if (exportError != null) throw exportError!;
    exportedJson = json;
    return exportResult;
  }

  @override
  Future<String?> import() async {
    if (importError != null) throw importError!;
    if (importQueue.isEmpty) return null;
    return importQueue.removeAt(0);
  }
}

OwnerIdentity _identity(int seed) => OwnerIdentity(
  ownerPk: Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256)),
  ownerSk: Uint8List.fromList(List.generate(32, (i) => (seed + 9 + i) % 256)),
);

PeerRecord _peer(String epk) => PeerRecord(
  remoteEpk: epk,
  sessionName: 's',
  relayUrl: 'http://r:1',
  pairedAt: '2026-09-24T00:00:00.000Z',
);

String _json(OwnerIdentity id, {List<PeerRecord> peers = const []}) =>
    IdentityBundle(
      identity: id,
      peers: peers,
      exportedAt: '2026-09-24T12:00:00.000Z',
    ).encode();

void main() {
  late _FakeTransfer transfer;

  Future<IdentityBackupViewModel> buildVm({OwnerIdentity? initial}) async {
    final storage = PairingStorage(FakeSecureStorage());
    final store = InMemoryOwnerIdentityStore(initial: initial ?? _identity(1));
    final bridge = OwnerIdentityBridge(store, storage);
    await bridge.boot();
    return IdentityBackupViewModel(
      IdentityTransferService(
        transfer: transfer,
        bridge: bridge,
        pairing: storage,
        identityStore: store,
      ),
    );
  }

  setUp(() {
    transfer = _FakeTransfer();
  });

  group('export', () {
    test('success → Exported state carrying the file name', () async {
      final vm = await buildVm();
      transfer.exportResult = 'my-backup.json';
      final name = await vm.export();

      expect(name, 'my-backup.json');
      expect(vm.state, isA<IdentityBackupExported>());
      expect((vm.state as IdentityBackupExported).fileName, 'my-backup.json');
      vm.dispose();
    });

    test('cancel → back to Idle, no error emitted', () async {
      final vm = await buildVm();
      transfer.exportResult = null;
      final errors = <String>[];
      vm.errors.listen(errors.add);

      expect(await vm.export(), isNull);
      await Future<void>.delayed(Duration.zero);

      expect(vm.state, isA<IdentityBackupIdle>());
      expect(errors, isEmpty, reason: 'cancelling is not a failure');
      vm.dispose();
    });

    test('platform failure → Idle + an error message', () async {
      final vm = await buildVm();
      transfer.exportError = const IdentityTransferException(
        'write_failed',
        'Could not write the backup file.',
      );
      final errors = <String>[];
      vm.errors.listen(errors.add);

      expect(await vm.export(), isNull);
      await Future<void>.delayed(Duration.zero);

      expect(vm.state, isA<IdentityBackupIdle>());
      expect(errors.single, contains('Could not write'));
      vm.dispose();
    });

    test('unsupported platform → hides the section', () async {
      final vm = await buildVm();
      expect(vm.supported, isTrue);
      transfer.exportError = const IdentityTransferException(
        'unsupported',
        'not available',
      );
      await vm.export();
      await Future<void>.delayed(Duration.zero);
      expect(vm.supported, isFalse);
      vm.dispose();
    });
  });

  group('prepareImport', () {
    test('parses and parks the bundle without applying it', () async {
      final vm = await buildVm();
      transfer.importQueue.add(_json(_identity(99), peers: [_peer('p')]));

      final bundle = await vm.prepareImport();

      expect(bundle, isNotNull);
      expect(vm.pendingBundle, isNotNull);
      // Still idle — the confirm dialog has not been answered.
      expect(vm.state, isA<IdentityBackupIdle>());
      vm.dispose();
    });

    test('cancel → null, nothing parked', () async {
      final vm = await buildVm();
      transfer.importQueue.add(null);
      expect(await vm.prepareImport(), isNull);
      expect(vm.pendingBundle, isNull);
      vm.dispose();
    });

    test('invalid file → error surfaced, nothing parked', () async {
      final vm = await buildVm();
      transfer.importQueue.add('{"magic":"wrong"}');
      final errors = <String>[];
      vm.errors.listen(errors.add);

      expect(await vm.prepareImport(), isNull);
      await Future<void>.delayed(Duration.zero);

      expect(vm.pendingBundle, isNull);
      expect(errors.single, contains('not a Remote Pi backup'));
      vm.dispose();
    });

    test('a rejected file cannot be confirmed later', () async {
      // Guards against a stale pending bundle surviving a failed pick: the
      // user must not be able to confirm an import they never saw described.
      final vm = await buildVm();
      transfer.importQueue.add(_json(_identity(99)));
      await vm.prepareImport();
      expect(vm.pendingBundle, isNotNull);

      transfer.importQueue.add('garbage');
      await vm.prepareImport();
      await Future<void>.delayed(Duration.zero);

      expect(vm.pendingBundle, isNull);
      expect(await vm.confirmImport(), isNull);
      vm.dispose();
    });
  });

  group('confirmImport', () {
    test('applies the parked bundle → Restored state', () async {
      final vm = await buildVm();
      transfer.importQueue.add(_json(_identity(99), peers: [_peer('p')]));
      await vm.prepareImport();

      final result = await vm.confirmImport();

      expect(result, isNotNull);
      expect(result!.keypairChanged, isTrue);
      expect(result.peerCount, 1);
      expect(vm.state, isA<IdentityBackupRestored>());
      expect((vm.state as IdentityBackupRestored).keypairChanged, isTrue);
      vm.dispose();
    });

    test('no-op when nothing is parked', () async {
      // The dialog can be confirmed after the bundle was already consumed.
      final vm = await buildVm();
      expect(await vm.confirmImport(), isNull);
      vm.dispose();
    });

    test('cannot be applied twice', () async {
      final vm = await buildVm();
      transfer.importQueue.add(_json(_identity(99)));
      await vm.prepareImport();

      expect(await vm.confirmImport(), isNotNull);
      expect(await vm.confirmImport(), isNull,
          reason: 'the bundle is consumed on first confirm');
      vm.dispose();
    });
  });

  group('cancelImport / reset', () {
    test('cancelImport drops the parked bundle', () async {
      final vm = await buildVm();
      transfer.importQueue.add(_json(_identity(99)));
      await vm.prepareImport();
      vm.cancelImport();
      expect(vm.pendingBundle, isNull);
      expect(await vm.confirmImport(), isNull);
      vm.dispose();
    });

    test('reset clears a terminal state back to Idle', () async {
      final vm = await buildVm();
      await vm.export();
      expect(vm.state, isA<IdentityBackupExported>());
      vm.reset();
      expect(vm.state, isA<IdentityBackupIdle>());
      vm.dispose();
    });
  });
}
