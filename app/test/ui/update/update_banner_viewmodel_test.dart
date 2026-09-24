import 'dart:io';

import 'package:app/domain/contracts/apk_installer.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Hand-written fakes (no mocktail in this repo) ──────────────────────────

class _FakeChecker implements UpdateChecker {
  _FakeChecker(this.result);
  UpdateInfo? result;
  int calls = 0;
  @override
  Future<UpdateInfo?> fetchLatest() async {
    calls++;
    return result;
  }
}

class _FakeDismissedStore implements DismissedUpdateStore {
  _FakeDismissedStore([this._version]);
  String? _version;
  final List<String> dismissedCalls = [];
  @override
  Future<String?> dismissedVersion() async => _version;
  @override
  Future<void> dismiss(String version) async {
    dismissedCalls.add(version);
    _version = version;
  }
}

/// Records what the app asked the platform installer to do.
class _FakeInstaller implements ApkInstaller {
  String dir = '/tmp/rp-updates';
  bool allowed = true;

  final List<String> installed = [];
  int canInstallCalls = 0;
  int settingsCalls = 0;

  /// When set, [install] throws this instead of recording.
  ApkInstallException? installError;

  @override
  Future<String> updateDownloadsDir() async => dir;

  @override
  Future<bool> canInstall() async {
    canInstallCalls++;
    return allowed;
  }

  @override
  Future<void> install(String path) async {
    if (installError != null) throw installError!;
    installed.add(path);
  }

  @override
  Future<void> openInstallSettings() async {
    settingsCalls++;
  }
}

UpdateInfo _info(
  String version, {
  List<UpdateArtifact>? artifacts,
}) =>
    UpdateInfo(
      version: version,
      date: '2026-06-12',
      notes: '',
      artifacts: artifacts ??
          const [
            UpdateArtifact(
              platform: 'android',
              arch: 'universal',
              format: 'apk',
              url: 'https://example.com/RemotePi.apk',
              sha256: '',
              size: 0,
            ),
          ],
    );

UpdateBannerViewModel _vm(
  _FakeChecker checker, {
  bool enabled = true,
  String current = '1.1.0',
  _FakeDismissedStore? store,
  _FakeInstaller? installer,
}) =>
    UpdateBannerViewModel(
      checker,
      store ?? _FakeDismissedStore(),
      installer ?? _FakeInstaller(),
      currentVersion: current,
      enabled: enabled,
    );

void main() {
  group('UpdateBannerViewModel.check — gating', () {
    test('newer + not dismissed → Visible', () async {
      final vm = _vm(_FakeChecker(_info('1.2.0')));
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());
      expect((vm.state as UpdateBannerVisible).info.version, '1.2.0');
    });

    test('disabled (iOS) → never fetches, stays Hidden', () async {
      final checker = _FakeChecker(_info('9.9.9'));
      final vm = _vm(checker, enabled: false);
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
      expect(checker.calls, 0, reason: 'iOS gate short-circuits before fetch');
    });

    test('manifest unavailable (null) → Hidden', () async {
      final vm = _vm(_FakeChecker(null));
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('equal version → Hidden', () async {
      final vm = _vm(_FakeChecker(_info('1.1.0')), current: '1.1.0');
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('lower version → Hidden', () async {
      final vm = _vm(_FakeChecker(_info('1.0.0')), current: '1.1.0');
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('already dismissed this version → Hidden', () async {
      final vm = _vm(
        _FakeChecker(_info('1.2.0')),
        store: _FakeDismissedStore('1.2.0'),
      );
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('dismissed an OLDER version → still Visible for the newer one', () async {
      final vm = _vm(
        _FakeChecker(_info('1.3.0')),
        store: _FakeDismissedStore('1.2.0'),
      );
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());
    });

    test('check is idempotent per instance (single fetch)', () async {
      final checker = _FakeChecker(_info('1.2.0'));
      final vm = _vm(checker);
      await vm.check();
      await vm.check();
      expect(checker.calls, 1);
    });

    test('force re-checks — the app that was open when the release landed', () async {
      // First check: nothing published yet.
      final checker = _FakeChecker(null);
      final vm = _vm(checker);
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());

      // The release goes out while the app is still open; returning to the
      // foreground must find it without a restart.
      checker.result = _info('1.2.0');
      await vm.check(force: true);
      expect(checker.calls, 2);
      expect(vm.state, isA<UpdateBannerVisible>());
    });

    test('a forced re-check that fails keeps the offer on screen', () async {
      final checker = _FakeChecker(_info('1.2.0'));
      final vm = _vm(checker);
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());

      // No network on resume: the user already saw that an update exists, so
      // dropping the card would be worse than leaving a stale offer standing.
      checker.result = null;
      await vm.check(force: true);
      expect(vm.state, isA<UpdateBannerVisible>());
    });
  });

  group('UpdateBannerViewModel.dismiss', () {
    test('hides the card and persists the version', () async {
      final store = _FakeDismissedStore();
      final vm = _vm(_FakeChecker(_info('1.2.0')), store: store);
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());

      await vm.dismiss();
      expect(vm.state, isA<UpdateBannerHidden>());
      expect(store.dismissedCalls, ['1.2.0']);
    });

    test('no-op when nothing is visible', () async {
      final store = _FakeDismissedStore();
      final vm = _vm(_FakeChecker(null), store: store);
      await vm.check();
      await vm.dismiss();
      expect(store.dismissedCalls, isEmpty);
    });
  });

  group('UpdateBannerViewModel.downloadAndInstall — failure handling', () {
    // The happy path downloads a real APK over HTTP and then launches the
    // system installer, so it is exercised on-device rather than here. These
    // cover the decisions the app makes around it: no artifact for this
    // platform, and a denied install permission.

    test('no apk artifact for the platform → error, card stays visible',
        () async {
      final installer = _FakeInstaller();
      final info = _info(
        '1.2.0',
        artifacts: const [
          UpdateArtifact(
            platform: 'macos',
            arch: 'universal',
            format: 'dmg',
            url: 'https://example.com/RemotePi.dmg',
            sha256: '',
            size: 0,
          ),
        ],
      );
      final vm = _vm(_FakeChecker(info), installer: installer);
      await vm.check();
      final errors = <String>[];
      vm.errors.listen(errors.add);

      await vm.downloadAndInstall();
      await Future<void>.delayed(Duration.zero);

      expect(vm.state, isA<UpdateBannerVisible>(),
          reason: 'failure must not lose the update offer');
      expect(installer.installed, isEmpty);
      expect(errors, hasLength(1));
      expect(errors.single, contains('no APK'));
    });

    test('permission denied → opens settings, no install, offer restored',
        () async {
      // Serves the APK from a loopback server so the real download path runs
      // (Dio → cache dir → permission gate).
      final bytes = List<int>.filled(64, 7);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..headers.contentLength = bytes.length
          ..add(bytes);
        req.response.close();
      });

      final dir = Directory.systemTemp.createTempSync('rp-update-test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final installer = _FakeInstaller()
        ..dir = dir.path
        ..allowed = false;
      final info = _info(
        '1.2.0',
        artifacts: [
          UpdateArtifact(
            platform: 'android',
            arch: 'universal',
            format: 'apk',
            url: 'http://127.0.0.1:${server.port}/RemotePi.apk',
            sha256: '',
            size: bytes.length,
          ),
        ],
      );
      final vm = _vm(_FakeChecker(info), installer: installer);
      await vm.check();
      final errors = <String>[];
      vm.errors.listen(errors.add);

      await vm.downloadAndInstall();
      await Future<void>.delayed(Duration.zero);

      expect(installer.canInstallCalls, 1);
      expect(installer.installed, isEmpty, reason: 'permission was denied');
      expect(installer.settingsCalls, 1,
          reason: 'user is sent to the unknown-sources toggle');
      expect(vm.state, isA<UpdateBannerVisible>(),
          reason: 'offer stays so one more tap installs');
      expect(errors.single, contains('install unknown apps'));
    });

    test('truncated download → rejected before the installer sees it',
        () async {
      // Advertises 4096 bytes but sends 64 — the size check must catch it and
      // never hand a corrupt APK to the system installer.
      final bytes = List<int>.filled(64, 7);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..add(bytes);
        req.response.close();
      });

      final dir = Directory.systemTemp.createTempSync('rp-update-test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final installer = _FakeInstaller()..dir = dir.path;
      final info = _info(
        '1.2.0',
        artifacts: [
          UpdateArtifact(
            platform: 'android',
            arch: 'universal',
            format: 'apk',
            url: 'http://127.0.0.1:${server.port}/RemotePi.apk',
            sha256: '',
            size: 4096,
          ),
        ],
      );
      final vm = _vm(_FakeChecker(info), installer: installer);
      await vm.check();

      await vm.downloadAndInstall();
      await Future<void>.delayed(Duration.zero);

      expect(installer.installed, isEmpty);
      expect(installer.canInstallCalls, 0,
          reason: 'the corrupt file must not reach the permission gate');
      expect(vm.state, isA<UpdateBannerVisible>());
    });
  });
}
