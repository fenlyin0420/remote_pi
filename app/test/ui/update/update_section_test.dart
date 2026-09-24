// Settings → About. The Home card is silent by design — it renders nothing when
// there is nothing to announce — so these cover the part that speaks: the
// installed version, the conclusion of the last check, and the manual ask.

import 'package:app/domain/contracts/apk_installer.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/settings/widgets/update_section.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Checker implements UpdateChecker {
  _Checker(this.result);
  UpdateInfo? result;
  int calls = 0;
  @override
  Future<UpdateInfo?> fetchLatest() async {
    calls++;
    return result;
  }
}

class _Store implements DismissedUpdateStore {
  _Store([this.version]);
  String? version;
  int clearCalls = 0;
  @override
  Future<String?> dismissedVersion() async => version;
  @override
  Future<void> dismiss(String v) async => version = v;
  @override
  Future<void> clear() async {
    clearCalls++;
    version = null;
  }
}

class _Installer implements ApkInstaller {
  @override
  Future<String> updateDownloadsDir() async => '/tmp/rp-updates';
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> install(String path) async {}
  @override
  Future<void> openInstallSettings() async {}
}

UpdateInfo _info(String version) => UpdateInfo(
  version: version,
  date: '',
  notes: '',
  artifacts: const [
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

void main() {
  Future<UpdateBannerViewModel> pump(
    WidgetTester tester, {
    UpdateInfo? latest,
    _Checker? checker,
    _Store? store,
    bool enabled = true,
  }) async {
    final vm = UpdateBannerViewModel(
      checker ?? _Checker(latest),
      store ?? _Store(),
      _Installer(),
      currentVersion: '1.1.0',
      enabled: enabled,
    );
    // The check first, so the widget's own mount-time check is a no-op and the
    // text under test is the one the section rendered.
    await vm.check();
    await tester.pumpWidget(
      ChangeNotifierProvider<UpdateBannerViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: UpdateSection())),
      ),
    );
    return vm;
  }

  String statusOf(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('update-status'))).data ?? '';

  group('UpdateSection', () {
    testWidgets('up to date → says so, and says where a release would appear', (
      tester,
    ) async {
      await pump(tester, latest: _info('1.1.0'));

      expect(find.byKey(const Key('update-version')), findsOneWidget);
      expect(find.text('v1.1.0'), findsOneWidget);
      expect(statusOf(tester), contains('Up to date'));
      // No card: nothing to install.
      expect(find.text('Update available'), findsNothing);
    });

    testWidgets('newer release → names it and shows the card', (tester) async {
      await pump(tester, latest: _info('1.2.0'));

      expect(statusOf(tester), contains('1.2.0'));
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('v1.2.0 · tap to install'), findsOneWidget);
    });

    testWidgets('unreachable manifest → says the check failed, no card', (
      tester,
    ) async {
      await pump(tester, latest: null);

      expect(statusOf(tester), contains('Could not reach'));
      expect(find.text('Update available'), findsNothing);
    });

    testWidgets('dismissed → offers to bring the notice back', (tester) async {
      final store = _Store('1.2.0');
      final vm = await pump(tester, latest: _info('1.2.0'), store: store);

      expect(find.text('Update available'), findsNothing);
      expect(find.text('Show update again'), findsOneWidget);
      expect(statusOf(tester), contains('you closed that notice'));

      await tester.tap(find.byKey(const Key('update-check')));
      await tester.pumpAndSettle();

      expect(store.clearCalls, 1);
      expect(vm.status, UpdateCheckStatus.available);
      expect(find.text('Update available'), findsOneWidget);
    });

    testWidgets('check button re-asks the server', (tester) async {
      final checker = _Checker(_info('1.1.0'));
      await pump(tester, checker: checker);
      expect(checker.calls, 1);

      await tester.tap(find.byKey(const Key('update-check')));
      await tester.pumpAndSettle();

      expect(checker.calls, 2, reason: 'the tap forced a fresh fetch');
      expect(statusOf(tester), contains('Up to date'));
    });

    testWidgets('iOS (unsupported) → renders nothing at all', (tester) async {
      await pump(tester, latest: _info('9.9.9'), enabled: false);

      expect(find.text('Version'), findsNothing);
      expect(find.byKey(const Key('update-check')), findsNothing);
    });
  });
}
