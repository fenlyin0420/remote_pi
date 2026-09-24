import 'dart:async';

import 'package:app/config/dependencies.dart';
import 'package:app/data/background/background_delivery.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/session/session_targeting.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/message_notifier.dart';
import 'package:app/domain/value_objects/session_label.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show RoomInfo;
import 'package:app/routing/adaptive.dart';
import 'package:app/routing/app_router.dart';
import 'package:app/routing/visible_session.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Plan 31 — open the v2 SSOT boxes + WIPE the volatile runtime box BEFORE
  // anything subscribes (#3 / Risk 2).
  await LocalBoxes.init();
  await setupDependencies();
  // Eagerly construct the SSOT writer so it's consuming the channel from boot
  // (messages can arrive before the chat screen mounts).
  injector.get<SyncService>();
  // Background delivery likewise: the keeper must be running before the first
  // backgrounding, and a tap that launched the app must be drained as soon as
  // the router exists — not when the user happens to open a chat.
  // ignore: unawaited_futures
  injector.get<BackgroundDelivery>().start();
  runApp(const RemotePiApp());
}

class RemotePiApp extends StatefulWidget {
  const RemotePiApp({super.key});

  @override
  State<RemotePiApp> createState() => _RemotePiAppState();
}

class _RemotePiAppState extends State<RemotePiApp> with WidgetsBindingObserver {
  late final _router = buildRouter(
    injector.get<PairingStorage>(),
    injector.get<ConnectionManager>(),
    injector.get<Preferences>(),
    injector.get<OwnerIdentityBridge>(),
    injector.get<MeshSyncService>(),
  );

  late final BackgroundDelivery _delivery = injector.get<BackgroundDelivery>();
  StreamSubscription<NotificationTap>? _tapSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A tapped notification means "open that session". One listener covers both
    // the warm tap (platform wake-up) and the cold start, where the platform has
    // been holding the tap since before Dart existed — so drain it here, now
    // that something can act on it.
    _tapSub = _delivery.taps.listen(_openNotification);
    // ignore: unawaited_futures
    _delivery.drainPendingTap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapSub?.cancel();
    disposeDependencies();
    super.dispose();
  }

  /// Opens the session a notification pointed at — retarget first so the chat
  /// addresses the right room, then mark the selection (which is what the
  /// tablet's detail pane reacts to) and push the full-screen chat on phones.
  /// Same order as the Home tap, so the chat binds identically whichever way the
  /// user arrived.
  Future<void> _openNotification(NotificationTap tap) async {
    final storage = injector.get<PairingStorage>();
    final connection = injector.get<ConnectionManager>();
    await retargetSession(
      storage: storage,
      prefs: injector.get<Preferences>(),
      conn: connection,
      epk: tap.epk,
      roomId: tap.roomId,
    );
    if (!mounted) return;
    final peer = await storage.loadPeer(tap.epk);
    if (!mounted || peer == null) return;
    final title =
        roomLabel(_roomFor(connection, tap.roomId, tap.epk)) ??
        deviceLabel(peer);
    final device = deviceLabel(peer);
    final online = connection.isRoomLive(tap.epk, tap.roomId);
    injector
        .get<SessionSelection>()
        .select(tap.epk, tap.roomId, title, device, online);
    if (isWideWindow()) return;
    // Cold start: the tap can land while the router is still on /boot, and a
    // push from there is swallowed by the boot redirect. Wait it out (bounded —
    // boot is a local storage read, so this is normally zero iterations).
    for (var i = 0; i < 20 && _currentPath == '/boot'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
    }
    _router.push(
      '/chat',
      extra: {'title': title, 'device': device, 'online': online},
    );
  }

  String get _currentPath =>
      _router.routerDelegate.currentConfiguration.uri.path;

  static RoomInfo? _roomFor(
    ConnectionManager conn,
    String roomId,
    String epk,
  ) {
    for (final room in conn.roomsFor(epk)) {
      if (room.roomId == roomId) return room;
    }
    return null;
  }

  /// Plan 24 — keep the mesh poll timer aligned with the app's
  /// foreground lifecycle. Polling runs ONLY while resumed; in
  /// inactive/paused/hidden/detached we cancel so we don't drain the
  /// battery (and we'll resync via `pullOnDemand` on the next resume +
  /// boot path).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final meshSync = injector.get<MeshSyncService>();
    final resumed = state == AppLifecycleState.resumed;
    // Background delivery needs the same lifecycle signal twice over: "do not
    // notify about a chat the user is reading" only works if the app knows it
    // is in front, and the keeper itself only runs while it is NOT.
    injector.get<VisibleSession>().setForeground(resumed);
    // ignore: unawaited_futures
    _delivery.setForeground(resumed);
    switch (state) {
      case AppLifecycleState.resumed:
        meshSync.startPolling();
        // ignore: unawaited_futures
        meshSync.pullOnDemand();
        // A tap that landed while the Dart side was still booting is parked on
        // the platform side; draining here is what keeps it from being lost.
        // ignore: unawaited_futures
        _delivery.drainPendingTap();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        meshSync.stopPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Preferences>.value(
          value: injector.get<Preferences>(),
        ),
        ChangeNotifierProvider<SessionSelection>.value(
          value: injector.get<SessionSelection>(),
        ),
        // Shell layout state — lets the adaptive shell collapse the split
        // into a single centered pane on zero-state Home (no Pi / empty).
        ChangeNotifierProvider<ShellLayout>.value(
          value: injector.get<ShellLayout>(),
        ),
      ],
      // Theme is reactive: toggling the mode in Settings notifies
      // [Preferences] → this Consumer rebuilds → MaterialApp swaps theme.
      child: Consumer<Preferences>(
        builder: (context, prefs, _) => MaterialApp.router(
          title: 'Remote Pi',
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: prefs.themeMode,
          routerConfig: _router,
          debugShowCheckedModeBanner: false,
          // Issue #114 — user-chosen text size. Applied here rather than by
          // scaling `AppTypography`'s base sizes so the many per-widget
          // `copyWith(fontSize: …)` overrides scale too. `TextScaler.linear`
          // REPLACES the platform scaler, which is deliberate: Flutter can't
          // read iOS's per-app Text Size anyway (it only reads the global
          // accessibility setting), so honoring both would compound them.
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: prefs.fontScale.factor,
            maxScaleFactor: prefs.fontScale.factor,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
