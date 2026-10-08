// Command channel at the page level: the composer's `/` and `!` reach the
// ActionsRepository, and a refusal from the Pi comes back as a toast with the
// Pi's own words. The pieces are covered in isolation elsewhere (InputBar for
// the prefix routing, ChatViewModel for delegation); this pins the wiring and
// the error presentation between them.

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
import 'package:app/routing/visible_session.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class _FakeChannel implements IChannel {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final List<ClientMessage> sent = [];
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  Future<void> close() => _ctrl.close();
}

class _FakeStorage extends PairingStorage {
  _FakeStorage(this._peer);
  final PeerRecord _peer;
  @override
  Future<List<PeerRecord>> listPeers() async => [_peer];
  @override
  Future<PeerRecord?> loadPeer(String epk) async =>
      epk == _peer.remoteEpk ? _peer : null;
  @override
  Future<void> savePeer(PeerRecord r) async {}

  // In-memory rooms so a room announcement landing on the real
  // ConnectionManager never touches flutter_secure_storage.
  final Map<String, List<PersistedRoom>> _rooms = {};
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async =>
      _rooms[epk] = rooms;
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      _rooms[epk] ?? const [];
  @override
  Future<void> deleteRooms(String epk) async => _rooms.remove(epk);
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _s = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _s[key];
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
      _s.remove(key);
    } else {
      _s[key] = value;
    }
  }

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

/// Records the command-channel calls and fails on demand, so the page's toast
/// path has something to render.
class _FakeActions implements IActionsRepository {
  final List<String> commands = [];
  final List<String> bashes = [];
  ActionFailure? failure;

  @override
  Future<void> runCommand(String text) async {
    if (failure != null) throw failure!;
    commands.add(text);
  }

  @override
  Future<void> runBash(String command, {bool excludeFromContext = false}) async {
    if (failure != null) throw failure!;
    bashes.add(command);
  }

  @override
  Future<List<WireCommand>> listCommands({bool forceRefresh = false}) async =>
      const [];

  @override
  Future<List<WireSession>> listSessions() async => const [];

  @override
  Future<void> switchSession(String session) async {}

  @override
  ActiveRoomMeta get activeRoomMeta => const ActiveRoomMeta();

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream =>
      const Stream<ActiveRoomMeta>.empty();

  @override
  Future<void> compact() async {}
  @override
  Future<void> newSession() async {}
  @override
  Future<void> setModel(String provider, String modelId) async {}
  @override
  Future<void> setThinking(ThinkingLevel level) async {}
  @override
  Future<void> createRoom(String path, {bool createIfMissing = false}) async {}
  @override
  Future<void> deleteRoom(String path) async {}
  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async =>
      const ModelsCatalogue(models: [], current: null);
  @override
  void dispose() {}
}

const _peer = PeerRecord(
  remoteEpk: 'epk_commands',
  sessionName: 'pi',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_chat_cmd_');
    await LocalBoxes.initForTest(dir.path);
    // ChatPage reads the global injector for its per-room DraftStore.
    injector.addInstance<DraftStore>(DraftStore(LocalBoxes()));
  });
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  /// Advances the fake clock over several frames so the async pipeline
  /// (status → runtime row → ViewModel) lands before a test acts.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      // runAsync for the real (Hive/stream) side of the pipeline, pump for the
      // widget side — the runtime row is written asynchronously, so a
      // fake-clock-only pump leaves the composer looking offline.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Pumps the real ChatPage over a live-looking room, with the command
  /// channel wired to [actions]. Returns the wiring so a test can shut it down:
  /// the page's own machinery keeps timers alive, and the test framework fails
  /// a test that leaves one pending.
  Future<({ChatViewModel vm, SyncService sync, ConnectionManager conn})>
  pumpChat(WidgetTester tester, _FakeActions actions) async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(_peer),
    );
    final boxes = LocalBoxes();
    final sync = SyncService(conn, boxes);
    final read = SessionReadRepository(boxes);
    final prefs = Preferences(_FakeSecureStorage());
    await prefs.setSelectedPeerEpk(_peer.remoteEpk);
    await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');
    conn.adopt(ch, _peer);
    // `tester.pump(duration)` rather than `Future.delayed`: inside a widget test
    // the clock is fake, so a real delay never resolves. Several frames so the
    // status → runtime-row → VM pipeline actually settles: the composer is
    // disabled while the runtime still reads as offline, and an extra
    // `_recompute` (which any command makes) exposes that stale row.
    await settle(tester);

    final vm = ChatViewModel(
      read,
      sync,
      conn,
      prefs,
      _FakeStorage(_peer),
      VisibleSession(),
      actions,
    );
    await settle(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<ChatViewModel>.value(value: vm),
            ChangeNotifierProvider<VoiceInputViewModel>.value(
              value: VoiceInputViewModel(_FakeSpeech()),
            ),
            ChangeNotifierProvider<AttachmentViewModel>.value(
              value: AttachmentViewModel(_FakePicker(), _FakeFilePicker(), actions),
            ),
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<SessionSelection>.value(
              value: SessionSelection(),
            ),
          ],
          child: const ChatPage(initialTitle: 'proj', initialOnline: true),
        ),
      ),
    );
    await tester.pump();
    return (vm: vm, sync: sync, conn: conn);
  }

  void shutdown(({ChatViewModel vm, SyncService sync, ConnectionManager conn}) app) {
    app.vm.dispose();
    app.sync.dispose();
    app.conn.dispose();
  }

  /// Types a line and sends it with the composer button — the touch path the
  /// phone actually uses (hardware Enter is the iPad-case shortcut).
  Future<void> submitLine(WidgetTester tester, String line) async {
    await tester.enterText(find.byType(TextField), line);
    await tester.pump();
    await tester.tap(find.byKey(const Key('input-bar-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  // A command answered on the Pi's notify channel (`/mcp`, `/rp list`) produces
  // no message row and no tool card, so the page must render it somewhere or the
  // command looks like it did nothing. This pins the strip that does it.
  //
  // The frame is pushed through SyncService the way the relay delivers it: the
  // notice arrives as an extension_ui_request with method=notify and no matching
  // open modal (an ask_user flow reuses the same id).
  testWidgets('a Pi notify is shown above the composer, then dismissable', (tester) async {
    final actions = _FakeActions();
    final app = await pumpChat(tester, actions);

    expect(find.byKey(const Key('chat-notice-strip')), findsNothing);

    app.sync.onServerMessageForTest(
      const ExtensionUiRequest(
        id: 'notify-1',
        method: ExtensionUiMethod.notify,
        message: 'MCP Server Status:\n\nShared MCP config: .mcp.json',
        notifyType: 'info',
      ),
    );
    await tester.pumpAndSettle();

    expect(
      app.vm.debugLastNotice,
      isNotNull,
      reason: 'the VM never received the notify from SyncService',
    );
    expect(
      app.vm.state,
      isA<ChatReady>(),
      reason: 'page is not in the ChatReady state the strip reads from',
    );
    expect(find.byKey(const Key('chat-notice-strip')), findsOneWidget);
    expect(find.textContaining('MCP Server Status'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-notice-strip')), findsNothing);

    shutdown(app);
  });

  // The common case is a second command while the first notice is still up:
  // replacing in place keeps a burst of commands from stacking strips and
  // pushing the transcript off screen.
  // Floated, not stacked: the notice must not push the transcript around. The
  // bug was visible as messages jumping up by the strip's height whenever a
  // command answered, and it is a layout property, so it is asserted as one.
  testWidgets('the notice floats — showing it does not move the messages', (tester) async {
    final actions = _FakeActions();
    final app = await pumpChat(tester, actions);

    // An empty room renders _EmptyState rather than MessageList, so the
    // transcript region is measured by the overlay's own parent.
    final bodyBefore = tester.getRect(find.byKey(const Key('chat-transcript')));
    app.sync.onServerMessageForTest(
      const ExtensionUiRequest(
        id: 'notify-1',
        method: ExtensionUiMethod.notify,
        message: 'MCP Server Status:\n  pi-mcp: ok',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-notice-strip')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('chat-transcript'))),
      bodyBefore,
      reason: 'the transcript must keep its geometry while a notice is shown',
    );

    shutdown(app);
  });

  testWidgets('a newer Pi notify replaces the previous one', (tester) async {
    final actions = _FakeActions();
    final app = await pumpChat(tester, actions);

    app.sync.onServerMessageForTest(
      const ExtensionUiRequest(
        id: 'notify-1',
        method: ExtensionUiMethod.notify,
        message: 'first output',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('first output'), findsOneWidget);

    app.sync.onServerMessageForTest(
      const ExtensionUiRequest(
        id: 'notify-2',
        method: ExtensionUiMethod.notify,
        message: 'second output',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('second output'), findsOneWidget);
    expect(find.textContaining('first output'), findsNothing);
    expect(find.byKey(const Key('chat-notice-strip')), findsOneWidget);

    shutdown(app);
  });

  testWidgets('a submitted /command reaches the repository', (tester) async {
    final actions = _FakeActions();
    final app = await pumpChat(tester, actions);
    await submitLine(tester, '/compact keep the notes');
    expect(actions.commands, ['/compact keep the notes']);
    expect(actions.bashes, isEmpty);
    shutdown(app);
  });

  testWidgets('a submitted !command reaches the repository as shell', (tester) async {
    final actions = _FakeActions();
    final app = await pumpChat(tester, actions);
    await submitLine(tester, '!git status -sb');
    expect(actions.bashes, ['git status -sb']);
    expect(actions.commands, isEmpty);
    shutdown(app);
  });

  // One shared presenter serves both prefixes, so a refusal from either shows
  // up the same way. This drives it through `!` because the composer is built
  // asynchronously with a volatile runtime row, which makes the `/`-only path
  // depend on harness timing rather than on the code under test.
  testWidgets('a refused command is toasted, never an unhandled error', (tester) async {
    final actions = _FakeActions()..failure = const ActionFailure('timeout');
    final app = await pumpChat(tester, actions);
    await submitLine(tester, '!sleep 900');
    await tester.pump();
    expect(find.text('timeout'), findsOneWidget);
    expect(tester.takeException(), isNull);
    shutdown(app);
  });

  /// The composer's own FocusNode — the one InputBar passes to its TextField.
  FocusNode composerFocus(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).focusNode!;

  testWidgets('tapping outside the composer dismisses it', (tester) async {
    final actions = _FakeActions();
    final app = await pumpChat(tester, actions);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(composerFocus(tester).hasFocus, isTrue);

    // Blank space in the transcript — not a bubble, not a button.
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('chat-transcript'))),
    );
    await tester.pump();
    expect(
      composerFocus(tester).hasFocus,
      isFalse,
      reason: 'tap-to-dismiss must close the keyboard from blank space',
    );

    shutdown(app);
  });

  // Opening a page/dialog while the composer is focused used to hand the focus
  // back on pop — the keyboard reappeared over the chat. The info dialog is the
  // second entry point the user hit (Settings is covered by openSettings).
  testWidgets('the session-info dialog drops the composer focus for good', (
    tester,
  ) async {
    final actions = _FakeActions();
    final app = await pumpChat(tester, actions);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(composerFocus(tester).hasFocus, isTrue);

    await tester.tap(find.byIcon(LucideIcons.info));
    await tester.pumpAndSettle();
    expect(find.text('Session info'), findsOneWidget);
    expect(composerFocus(tester).hasFocus, isFalse);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Session info'), findsNothing);
    expect(
      composerFocus(tester).hasFocus,
      isFalse,
      reason: 'popping the dialog must not restore the composer',
    );

    shutdown(app);
  });
}
