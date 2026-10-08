import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/mesh/mesh_blob.dart';
import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({required String key, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _store[key];
  @override
  Future<void> write({required String key, required String? value, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }
  @override
  Future<void> delete({required String key, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _store.remove(key);
  @override
  Future<Map<String, String>> readAll({IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => Map.of(_store);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubAdapter implements HttpClientAdapter {
  final Map<String, _Reply> replies = {};
  RequestOptions? lastOptions;
  String? lastBody;
  int postCount = 0;
  int getCount = 0;
  void on(String method, String pathSuffix, _Reply reply) {
    replies['$method $pathSuffix'] = reply;
  }
  @override void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    lastOptions = options;
    if (options.method == 'POST') postCount++;
    if (options.method == 'GET') getCount++;
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      lastBody = utf8.decode(bytes);
    } else {
      lastBody = null;
    }
    final key = '${options.method} ${options.uri.path}';
    final reply = replies[key];
    if (reply == null) {
      throw StateError('No stub for $key — registered: ${replies.keys.toList()}');
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(utf8.encode(reply.body)),
      reply.status,
      headers: const {Headers.contentTypeHeader: ['application/json']},
    );
  }
}

class _Reply {
  final int status;
  final String body;
  const _Reply(this.status, this.body);
}

Future<({SimpleKeyPair keyPair, Uint8List ownerPk})> _newOwner() async {
  final ed = Ed25519();
  final kp = await ed.newKeyPair();
  final pub = await kp.extractPublicKey();
  return (keyPair: kp, ownerPk: Uint8List.fromList(pub.bytes));
}

/// Bridge backed by an in-memory plugin store, pre-seeded with the
/// supplied keypair so `currentOwnerPk` + `requireKeyPair` work without
/// touching the platform channel.
Future<OwnerIdentityBridge> _bootedBridge(
  PairingStorage storage,
  SimpleKeyPair keyPair,
  Uint8List ownerPk,
) async {
  final seed = await keyPair.extractPrivateKeyBytes();
  final id = OwnerIdentity(
    ownerPk: ownerPk,
    ownerSk: Uint8List.fromList(seed),
  );
  final store = InMemoryOwnerIdentityStore(initial: id);
  final bridge = OwnerIdentityBridge(store, storage);
  await bridge.boot();
  return bridge;
}

({Dio dio, _StubAdapter adapter}) _stubDio() {
  final adapter = _StubAdapter();
  final dio = Dio(BaseOptions(
    validateStatus: (_) => true,
    responseType: ResponseType.plain,
  ))
    ..httpClientAdapter = adapter;
  return (dio: dio, adapter: adapter);
}

void main() {
  group('MeshSyncService.pullOnDemand', () {
    test('404 → keeps cache, returns true', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);
      final s = _stubDio();
      s.adapter.on('GET', '/mesh/$hash', const _Reply(404, ''));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      final ok = await svc.pullOnDemand();
      expect(ok, isTrue);
      expect(svc.lastVersion, 0);
    });

    test('200 with verified envelope hydrates PairingStorage', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);

      final blob = MeshBlob(
        version: 3,
        issuedAt: 1700000000000,
        ownerPk: owner.ownerPk,
        members: const [
          MeshMember(
            remoteEpk: 'epk-a',
            relayUrl: 'wss://r',
            pairedAt: '2026-05-15T10:30:00Z',
            nickname: 'Work mac',
          ),
        ],
      );
      final env = await blob.signWith(owner.keyPair);
      final body = jsonEncode({
        'blob': base64.encode(env.blob),
        'sig': base64.encode(env.sig),
        'version': 3,
        'updated_at': 1700000000000,
      });
      final s = _stubDio();
      s.adapter.on('GET', '/mesh/$hash', _Reply(200, body));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      final ok = await svc.pullOnDemand();
      expect(ok, isTrue);
      expect(svc.lastVersion, 3);
      final peers = await storage.listPeers();
      expect(peers, hasLength(1));
      expect(peers.first.remoteEpk, 'epk-a');
      expect(peers.first.nickname, 'Work mac');
    });

    test('200 with bad signature is dropped (cache untouched)', () async {
      final owner = await _newOwner();
      final other = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);

      // Blob signed by the WRONG key — verify must fail.
      final blob = MeshBlob(
        version: 1,
        issuedAt: 1,
        ownerPk: owner.ownerPk,
      );
      final envFromOther = await blob.signWith(other.keyPair);
      final body = jsonEncode({
        'blob': base64.encode(envFromOther.blob),
        'sig': base64.encode(envFromOther.sig),
        'version': 1,
        'updated_at': 1,
      });
      final s = _stubDio();
      s.adapter.on('GET', '/mesh/$hash', _Reply(200, body));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      final ok = await svc.pullOnDemand();
      expect(ok, isFalse);
      expect(svc.lastVersion, 0);
    });

    test('200 verified blob removes peers absent from members', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      // Pre-existing peer that the relay no longer knows about.
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-removed',
        sessionName: 'old',
        relayUrl: 'wss://r',
        pairedAt: '2026-05-01T00:00:00Z',
      ));
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);

      final blob = MeshBlob(
        version: 1,
        issuedAt: 1,
        ownerPk: owner.ownerPk,
        members: const [
          MeshMember(
            remoteEpk: 'epk-kept',
            relayUrl: 'wss://r',
            pairedAt: '2026-05-15T10:30:00Z',
          ),
        ],
      );
      final env = await blob.signWith(owner.keyPair);
      final body = jsonEncode({
        'blob': base64.encode(env.blob),
        'sig': base64.encode(env.sig),
        'version': 1,
        'updated_at': 1,
      });
      final s = _stubDio();
      s.adapter.on('GET', '/mesh/$hash', _Reply(200, body));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      await svc.pullOnDemand();
      final peers = await storage.listPeers();
      expect(peers.map((p) => p.remoteEpk), ['epk-kept']);
    });
  });

  group('MeshSyncService.publish', () {
    test('200 → MeshPublishOk and lastVersion bumps', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);
      final s = _stubDio();
      s.adapter.on('POST', '/mesh/$hash', _Reply(200, jsonEncode({
        'version': 1,
        'updated_at': 1700000000000,
      })));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      final r = await svc.publish();
      expect(r, isA<MeshPublishOk>());
      expect(svc.lastVersion, 1);
    });

    test('409 conflict triggers one refetch + retry', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      // Need a peer in storage so the post-refetch publish doesn't hit
      // the empty-on-existing safety net (which is exactly the bug
      // fix that landed alongside this test — see the "publish race
      // fix" group below).
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-local',
        sessionName: 'local',
        relayUrl: 'wss://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);

      // Relay state: someone else published v5 already — same peer,
      // so the refetch+apply leaves the local cache populated.
      final newer = MeshBlob(
        version: 5,
        issuedAt: 1,
        ownerPk: owner.ownerPk,
        members: const [
          MeshMember(
            remoteEpk: 'epk-local',
            relayUrl: 'wss://r',
            pairedAt: '2026-05-15T10:30:00Z',
          ),
        ],
      );
      final newerEnv = await newer.signWith(owner.keyPair);
      final s = _stubDio();
      // First POST: 409. Second POST (after refetch bumps to v6): 200.
      var postReplies = [
        _Reply(409, ''),
        _Reply(200, jsonEncode({'version': 6, 'updated_at': 1})),
      ];
      s.adapter.replies['POST /mesh/$hash'] = postReplies.first;
      // GET in between returns v5.
      s.adapter.on('GET', '/mesh/$hash', _Reply(200, jsonEncode({
        'blob': base64.encode(newerEnv.blob),
        'sig': base64.encode(newerEnv.sig),
        'version': 5,
        'updated_at': 1,
      })));

      // Hook to swap POST reply after first call.
      final client = MeshClient(
        baseUrlProvider: () => 'https://r',
        dio: Dio(BaseOptions(
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
        ))
          ..httpClientAdapter = _SequencingAdapter(
            postPath: '/mesh/$hash',
            postSequence: postReplies,
            others: s.adapter.replies,
          ),
      );
      final svc = MeshSyncService(client, bridge, storage);

      final r = await svc.publish();
      expect(r, isA<MeshPublishOk>());
      expect((r as MeshPublishOk).version, 6);
      expect(svc.lastVersion, 6);
    });

    test('publish failure leaves lastVersion untouched', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);
      final s = _stubDio();
      s.adapter.on('POST', '/mesh/$hash', const _Reply(500, ''));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      final r = await svc.publish();
      expect(r, isA<MeshPublishFailure>());
      expect(svc.lastVersion, 0);
    });
  });

  group('MeshSyncService.resetVersionWatermark', () {
    test('drops lastVersion + lastUpdatedAt', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final s = _stubDio();
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      final hash = await MeshClient.ownerPkHash(owner.ownerPk);
      s.adapter.on('POST', '/mesh/$hash', _Reply(200, jsonEncode({
        'version': 4,
        'updated_at': 1700000000000,
      })));
      await svc.publish();
      expect(svc.lastVersion, 4);
      expect(svc.lastUpdatedAt, isNotNull);

      svc.resetVersionWatermark();
      expect(svc.lastVersion, 0);
      expect(svc.lastUpdatedAt, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Plan/24-fix-app-publish-race: pull-and-apply must NOT loop back into
  // publish, and publish must refuse to overwrite an existing membership
  // with an empty members list (which would trigger pi-remote
  // self-revoke for every paired Pi).
  // ---------------------------------------------------------------------------

  group('MeshSyncService — publish race fix', () {
    test('pullAndApply hydrates PairingStorage WITHOUT calling publish',
        () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      // Seed local cache with a peer the relay doesn't know about so
      // apply() has to mutate (delete + maybe save).
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-stale',
        sessionName: 'old',
        relayUrl: 'wss://r',
        pairedAt: '2026-04-01T00:00:00Z',
      ));
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);

      final blob = MeshBlob(
        version: 7,
        issuedAt: 1,
        ownerPk: owner.ownerPk,
        members: const [
          MeshMember(
            remoteEpk: 'epk-new',
            relayUrl: 'wss://r',
            pairedAt: '2026-05-15T10:30:00Z',
          ),
        ],
      );
      final env = await blob.signWith(owner.keyPair);
      final body = jsonEncode({
        'blob': base64.encode(env.blob),
        'sig': base64.encode(env.sig),
        'version': 7,
        'updated_at': 1,
      });
      final s = _stubDio();
      s.adapter.on('GET', '/mesh/$hash', _Reply(200, body));
      // Intentionally no POST stub registered — if the apply loop
      // accidentally triggers publish, _StubAdapter will throw.
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      // Wire the production hook on the storage so this test exercises
      // the real ciclo-pull-apply-savePeer-hook path.
      storage.attachPeerMutationHook(() {
        // ignore: unawaited_futures
        svc.publish();
      });

      await svc.pullOnDemand();

      // Apply rewrote the cache (epk-stale gone, epk-new in).
      final peers = await storage.listPeers();
      expect(peers.map((p) => p.remoteEpk), ['epk-new']);
      // And no POST was issued — proving the silent variants broke the
      // pull→apply→publish loop.
      expect(s.adapter.postCount, 0,
          reason: 'pull-and-apply must not call publish via the hook');
    });

    test('publish refuses empty-on-existing (safety net)', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);
      final s = _stubDio();
      // Pretend a previous version was already published.
      s.adapter.on('POST', '/mesh/$hash', _Reply(200, jsonEncode({
        'version': 1,
        'updated_at': 1,
      })));
      // Bootstrap _lastVersion to 1 by seeding a peer + publishing once.
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-seed',
        sessionName: 'seed',
        relayUrl: 'wss://r',
        pairedAt: '2026-05-01T00:00:00Z',
      ));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);
      final first = await svc.publish();
      expect(first, isA<MeshPublishOk>());
      expect(svc.lastVersion, 1);
      final postCountAfterSeed = s.adapter.postCount;

      // Race window: peer disappeared from storage (apply mid-flight,
      // wipeAll, etc) — publish() must refuse rather than overwrite v1
      // with members=[].
      await storage.deletePeerSilent('epk-seed');
      final result = await svc.publish();
      expect(result, isA<MeshPublishFailure>());
      expect((result as MeshPublishFailure).reason, contains('empty-on-existing'));
      expect(svc.lastVersion, 1, reason: 'watermark stays at 1');
      expect(s.adapter.postCount, postCountAfterSeed,
          reason: 'no extra POST was issued');
    });

    test(
      'publish(allowEmpty: true) bypasses the empty-on-existing safety '
      'net — drives the legitimate "revoke last peer" flow so the '
      'relay forgets the lone member instead of holding stale state '
      'that the next pullOnDemand would resurrect locally',
      () async {
        final owner = await _newOwner();
        final storage = PairingStorage(_FakeSecureStorage());
        final bridge =
            await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
        final hash = await MeshClient.ownerPkHash(owner.ownerPk);
        final s = _stubDio();
        s.adapter.on(
          'POST',
          '/mesh/$hash',
          _Reply(200, jsonEncode({'version': 1, 'updated_at': 1})),
        );
        await storage.savePeer(const PeerRecord(
          remoteEpk: 'epk-only',
          sessionName: 'only',
          relayUrl: 'wss://r',
          pairedAt: '2026-05-01T00:00:00Z',
        ));
        final client =
            MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
        final svc = MeshSyncService(client, bridge, storage);
        final first = await svc.publish();
        expect(first, isA<MeshPublishOk>());
        expect(svc.lastVersion, 1);

        // The legitimate last-peer revoke: storage is empty AND watermark
        // is non-zero, but the caller explicitly opted in.
        await storage.deletePeerSilent('epk-only');
        s.adapter.on(
          'POST',
          '/mesh/$hash',
          _Reply(200, jsonEncode({'version': 2, 'updated_at': 2})),
        );
        final result = await svc.publish(allowEmpty: true);
        expect(result, isA<MeshPublishOk>(),
            reason: 'allowEmpty:true must bypass the safety net');
        expect(svc.lastVersion, 2);
      },
    );

    test('publishing empty members at v=0 is allowed (edge case)', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);
      final s = _stubDio();
      s.adapter.on('POST', '/mesh/$hash', _Reply(200, jsonEncode({
        'version': 1,
        'updated_at': 1,
      })));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);
      // Storage is empty + lastVersion is 0 → publish proceeds (no
      // membership to clobber).
      final r = await svc.publish();
      expect(r, isA<MeshPublishOk>());
      expect(svc.lastVersion, 1);
    });

    test(
        'remote_epk is normalised to base64 standard in the published '
        'blob (url-safe input → standard output, idempotent on standard)',
        () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      // Seed a peer with the historical url-safe encoding (no padding,
      // `_` / `-` alphabet) — that's what PairingStorage receives from
      // QR / pair_ok today.
      const urlSafeEpk =
          'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
      const expectedStandard =
          'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
      await storage.savePeer(const PeerRecord(
        remoteEpk: urlSafeEpk,
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);

      // Capture the request body so we can inspect the blob bytes.
      final s = _stubDio();
      s.adapter.on('POST', '/mesh/$hash', _Reply(200, jsonEncode({
        'version': 1,
        'updated_at': 1,
      })));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      final r = await svc.publish();
      expect(r, isA<MeshPublishOk>());

      // Pull the blob out of the POST body, parse it, assert the
      // member's remote_epk is the standard form.
      final body = jsonDecode(s.adapter.lastBody!) as Map<String, Object?>;
      final blobBytes = base64.decode(body['blob']! as String);
      final blob = MeshBlob.fromCanonicalBytes(blobBytes);
      expect(blob.members, hasLength(1));
      expect(blob.members.single.remoteEpk, expectedStandard,
          reason: 'url-safe input must be re-encoded to standard');

      // Idempotence: a second publish (same peer, now stored
      // post-mesh) — re-emit with standard input, output is standard.
      await storage.savePeerSilent(PeerRecord(
        remoteEpk: expectedStandard,
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      // Wipe the prior key so listPeers returns ONLY the standard
      // form (the previous key was the url-safe one).
      await storage.deletePeerSilent(urlSafeEpk);
      s.adapter.on('POST', '/mesh/$hash', _Reply(200, jsonEncode({
        'version': 2,
        'updated_at': 2,
      })));
      await svc.publish();
      final body2 = jsonDecode(s.adapter.lastBody!) as Map<String, Object?>;
      final blob2 = MeshBlob.fromCanonicalBytes(
        base64.decode(body2['blob']! as String),
      );
      expect(blob2.members.single.remoteEpk, expectedStandard,
          reason: 'toStandardB64 must be idempotent');
    });

    test('explicit savePeer (local mutation) DOES fire the hook', () async {
      final owner = await _newOwner();
      final storage = PairingStorage(_FakeSecureStorage());
      final bridge = await _bootedBridge(storage, owner.keyPair, owner.ownerPk);
      final hash = await MeshClient.ownerPkHash(owner.ownerPk);
      final s = _stubDio();
      s.adapter.on('POST', '/mesh/$hash', _Reply(200, jsonEncode({
        'version': 1,
        'updated_at': 1,
      })));
      final client = MeshClient(baseUrlProvider: () => 'https://r', dio: s.dio);
      final svc = MeshSyncService(client, bridge, storage);

      var hookCalls = 0;
      storage.attachPeerMutationHook(() {
        hookCalls++;
        // ignore: unawaited_futures
        svc.publish();
      });

      // Simulate a real local mutation (e.g. PairingViewModel saving a
      // newly-paired peer). Non-silent variant → hook fires.
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-fresh',
        sessionName: 'fresh',
        relayUrl: 'wss://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));

      // Hook fired exactly once; publish was kicked off in the
      // background. Give it a microtask to land.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(hookCalls, 1);
      expect(s.adapter.postCount, greaterThanOrEqualTo(1));
    });
  });
}

/// HttpClientAdapter that returns POSTs in declared sequence, GETs by
/// path. Used to script the 409-then-200 conflict path.
class _SequencingAdapter implements HttpClientAdapter {
  final String postPath;
  final List<_Reply> postSequence;
  final Map<String, _Reply> others;
  int postCalls = 0;
  _SequencingAdapter({
    required this.postPath,
    required this.postSequence,
    required this.others,
  });
  @override void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async {
    if (stream != null) {
      await stream.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk);
        return acc;
      });
    }
    _Reply reply;
    if (options.method == 'POST' && options.uri.path == postPath) {
      reply = postSequence[postCalls < postSequence.length ? postCalls : postSequence.length - 1];
      postCalls++;
    } else {
      final key = '${options.method} ${options.uri.path}';
      reply = others[key] ?? (throw StateError('No stub for $key'));
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(utf8.encode(reply.body)),
      reply.status,
      headers: const {Headers.contentTypeHeader: ['application/json']},
    );
  }
}
