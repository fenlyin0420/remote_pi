// Plan/42 — the Chat AppBar's line 2 shows the room's model (from the
// RoomAnnounced room_meta), in place of the old device-name subtitle. The
// label renders as soon as the room carries a model.

import 'dart:async';
import 'dart:io';

import 'package:app/config/dependencies.dart' show injector;
import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/draft_store.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/routing/visible_session.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  Future<void> close() async => _ctrl.close();
}

/// One paired peer (epk `test-peer-epk`, room `main`) so the ChatViewModel
/// bootstraps, connects, and subscribes to control frames — the model label
/// must still come from the room announce, not the PeerRecord.
const kEpk = 'test-peer-epk';
class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [
    const PeerRecord(
      remoteEpk: kEpk,
      sessionName: 'PC',
      relayUrl: 'ws://relay',
      pairedAt: '2026-01-01T00:00:00Z',
      roomId: 'main',
    ),
  ];
  @override
  Future<PeerRecord?> loadPeer(String epk) async =>
      epk == kEpk
          ? const PeerRecord(
              remoteEpk: kEpk,
              sessionName: 'PC',
              relayUrl: 'ws://relay',
              pairedAt: '2026-01-01T00:00:00Z',
              roomId: 'main',
            )
          : null;
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _kv = {};
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _kv.remove(key);
    } else {
      _kv[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _kv[key];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeSpeech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakePicker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeFilePicker implements ITextFilePickerService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_v2_chatpage_');
    await LocalBoxes.initForTest(dir.path);
    // ChatPage reads the global injector for its per-room DraftStore.
    injector.addInstance<DraftStore>(DraftStore(LocalBoxes()));
  });
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets(
    'AppBar line 2 shows the model from the room announce (plan/42)',
    (tester) async {
      final fakeChannel = _FakeChannel();
      final conn = ConnectionManager(
        factory: (_, _) async => fakeChannel,
        storage: _FakeStorage(),
        emitDebounce: Duration.zero,
      );
      // The widget harness can't pump the async bootstrap/connect chain
      // (factory + loadPeer + ping timers), so drive it directly: bind the
      // peer and watch control frames, exactly like _connect would.
      await conn.switchTo(
        const PeerRecord(
          remoteEpk: kEpk,
          sessionName: 'PC',
          relayUrl: 'ws://relay',
          pairedAt: '2026-01-01T00:00:00Z',
          roomId: 'main',
        ),
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedRoom(epk: kEpk, roomId: 'main');
      final actions = ActionsRepository(conn);
      final vm = ChatViewModel(read, sync, conn, prefs, _FakeStorage(), VisibleSession());
      final voice = VoiceInputViewModel(_FakeSpeech());
      final attach = AttachmentViewModel(_FakePicker(), _FakeFilePicker(), actions);
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
            ],
            child: const ChatPage(
              initialTitle: 'My Project',
              initialOnline: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // The room announces itself with a model → line 2 shows it (the
      // announce carries the model from the Pi's room_meta).
      fakeChannel._control.add(
        RoomAnnounced(
          peer: 'test-peer-epk',
          roomId: 'main',
          startedAt: 0,
          model: 'mac-model',
        ),
      );
      // Let the announce frame + VM propagation settle (the debounced
      // rooms emit is a Timer even at emitDebounce: zero).
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      // Line 2 = model (from the room announce).
      expect(find.text('mac-model'), findsOneWidget);
      // Line 1 = room title (from initialTitle) — distinct from the device, so
      // we know the subtitle isn't just echoing the title fallback.
      expect(find.text('My Project'), findsOneWidget);

      // The info button renders immediately — even with no PeerRecord loaded
      // (activePeer == null here) — so it never pops in and shifts the AppBar.
      expect(find.byIcon(LucideIcons.info), findsOneWidget);

      // Status dot uses initialOnline before the runtime resolves → shows
      // "online" immediately instead of flashing offline/reconnecting.
      expect(find.text('online'), findsOneWidget);

      // Unmount + dispose in-body (the framework's pending-timer check runs
      // before addTearDown; conn's watchdog must be cancelled here).
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sync.dispose();
      conn.dispose();
    },
  );
}
