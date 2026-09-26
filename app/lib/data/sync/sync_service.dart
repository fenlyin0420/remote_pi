// Plan/31 — SyncService: the SINGLE writer of the local SSOT.
//
// Consumes the channel (ConnectionManager status + PeerChannel
// serverMessages) and writes row-granular records to Hive (v2 boxes). The UI
// never touches this stream — it reads the DB via the read repositories.
//
// Streaming is the ONE exception to SSOT (#7): AgentChunk deltas are coalesced
// into an in-memory Stream<StreamingMessage?> and NEVER written to the DB; only
// the finalized message lands in the box on `agent_done`.
//
// Turn state (streaming buffers, whole-turn working flag, queued list) is
// PER-ROOM, not global: rooms of one peer share a single WS and the transport
// only routes the ACTIVE room's frames to the session writer (`serverMessages`).
// Non-active rooms keep streaming through `ConnectionManager.roomFrames`
// (every inbound envelope, tagged with its sender room) → `roomMessages`. This
// service folds those frames into each room's own in-memory turn state WITHOUT
// DB writes (a background room's finalized rows are recovered by the history
// re-sync when the user returns to it). That is what keeps a turn in flight
// when the user switches rooms and comes back: the buffer AND the
// reasoning-block start time survive in the room's own slot.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/sync/sync_events.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:flutter/foundation.dart';

/// Per-room in-memory turn state (the "live" half of a session, never
/// persisted): the two streaming segment buffers, the reasoning-block start
/// time, the coalesce timer, the whole-turn working flag and the room's queued
/// messages. Keyed by `(epk, room)` in [SyncService._turns] — one slot per
/// room so switching away from a streaming chat neither loses its content nor
/// resets its thinking counter.
class _RoomTurn {
  final String epk;
  final String room;

  _RoomTurn(this.epk, this.room);

  // Streaming — two block kinds share ONE live slot: reasoning
  // (`agent_thinking`) and answer text (`agent_chunk`). Content blocks are
  // sequential, so only one kind is ever open at a time; a delta of the other
  // kind closes the open one first.
  final StringBuffer chunkBuffer = StringBuffer();
  String chunkReplyTo = '';
  final StringBuffer thinkingBuffer = StringBuffer();
  String thinkingReplyTo = '';
  // When the live reasoning segment started — the row it folds into carries
  // the elapsed time, and the streaming block ticks it
  // (StreamingMessage.startedAt).
  DateTime? thinkingStartedAt;
  Timer? flushTimer;
  StreamingMessage? streaming;

  // Whether this room's agent is currently producing a reply. Spans the
  // WHOLE turn (send/echo → agent_done), not just the token-streaming window.
  bool working = false;
  bool sawRemoteWorking = false;
  // Id of the user message the in-flight reply is answering — the `cancel`
  // target while working. Null when idle.
  String? workingReplyTo;

  List<QueuedMsg> queuedMessages = const [];
}

class SyncService extends Service {
  final ConnectionManager _conn;
  final LocalBoxes _boxes;

  StreamSubscription<ConnectionStatus>? _connSub;
  StreamSubscription<ServerMessage>? _msgSub;
  StreamSubscription<RoomMessage>? _roomMsgSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;

  // Active session being written (follows ConnectionManager).
  String? _activeEpk;
  String _activeRoomId = 'main';

  // Per-room in-memory turn state — survives room switches; only the
  // UI-facing streams/gatters follow the ACTIVE room's slot.
  final Map<String, _RoomTurn> _turns = {};

  // In-memory dedupe + ordering for the active session's msgs box. Rebuilt on
  // [activate]. Key = `<role>:<id>` so a user msg and the assistant reply that
  // shares its id don't collide.
  final Map<String, int> _idToSeq = {};
  int _nextSeq = 0;
  bool _indexLoaded = false;

  // Serialise box mutations so concurrent async writes stay ordered.
  Future<void> _writeChain = Future<void>.value();

  final StreamController<StreamingMessage?> _streamingController =
      StreamController<StreamingMessage?>.broadcast();

  final StreamController<SessionEvent> _eventController =
      StreamController<SessionEvent>.broadcast();

  // Plan/57 — transient interactive extension prompts (ask_user via pi-ask).
  // Never persisted (live UI requests, not chat history); surfaced to the
  // ChatViewModel, which opens a full-screen modal.
  final StreamController<ExtensionUiRequest> _extensionUiController =
      StreamController<ExtensionUiRequest>.broadcast();

  final StreamController<List<QueuedMsg>> _queuedController =
      StreamController<List<QueuedMsg>>.broadcast();

  final StreamController<bool> _workingController =
      StreamController<bool>.broadcast();

  bool _pendingSyncRequest = false;
  Timer? _syncDebounce;

  // Plan/32 safety net — if the relay never echoes a sent message back, the
  // optimistic `pending:true` bubble would spin forever. After this window we
  // remove the bubble SILENTLY (no "failed" state, no spinner). The real fix
  // lives in the relay; this is the app-side backstop. Per-message (`id`)
  // timers are armed only when a send is actually attempted online, and
  // cancelled on echo, user-cancel, session switch, and dispose.
  final Duration pendingSendTimeout;
  final Map<String, Timer> _pendingSendTimers = {};

  SyncService(
    this._conn,
    this._boxes, {
    this.pendingSendTimeout = const Duration(seconds: 20),
  }) {
    _connSub = _conn.statusStream.listen(_onStatus);
    _roomsSub = _conn.roomsStream.listen((_) {
      _writeRuntime();
      _syncTurnStateFromRoomMeta();
    });
    _presenceSub = _conn.presenceStream.listen((_) => _writeRuntime());
    // Background ingestion: EVERY room's inbound frames (the active room's
    // frames arrive here too — the handler skips them; the writer path owns
    // those). Feeds the non-active rooms' turn state so a streaming room the
    // user is not viewing keeps accumulating.
    _roomMsgSub = _conn.roomMessages.listen(_onRoomMessage);
    _onStatus(_conn.status); // replay current
  }

  // ---------------------------------------------------------------------------
  // Public surface (commands + in-memory streams)
  // ---------------------------------------------------------------------------

  /// The ACTIVE room's live streaming slot (null when idle / unbound).
  StreamingMessage? get streaming => _activeTurn?.streaming;
  Stream<StreamingMessage?> get streamingStream => _streamingController.stream;
  Stream<SessionEvent> get events => _eventController.stream;

  /// Plan/57 — stream of interactive extension_ui_request prompts (ask_user
  /// via pi-ask). Transient: not written to the DB; the ChatViewModel renders
  /// a full-screen modal and replies via [respondExtensionUi].
  Stream<ExtensionUiRequest> get extensionUiRequestStream =>
      _extensionUiController.stream;
  List<QueuedMsg> get queuedMessages =>
      _activeTurn?.queuedMessages ?? const [];
  String? get queuedText =>
      queuedMessages.isEmpty ? null : queuedMessages.first.text;
  Stream<List<QueuedMsg>> get queuedStream => _queuedController.stream;

  /// True while the ACTIVE room's agent is producing a reply (whole turn).
  bool get isWorking => _activeTurn?.working ?? false;
  Stream<bool> get workingStream => _workingController.stream;

  /// `cancel` target for the in-flight reply (null when idle).
  String? get workingReplyTo => _activeTurn?.workingReplyTo;

  String? get activeEpk => _activeEpk;
  String get activeRoomId => _activeRoomId;

  /// The slot whose turn state the UI-facing getters/streams reflect.
  _RoomTurn? get _activeTurn {
    final epk = _activeEpk;
    if (epk == null) return null;
    return _turns[LocalBoxes.sessionKey(epk, _activeRoomId)];
  }

  _RoomTurn _turn(String epk, String room) => _turns.putIfAbsent(
    LocalBoxes.sessionKey(epk, room),
    () => _RoomTurn(epk, room),
  );

  bool _isActive(_RoomTurn t) =>
      t.epk == _activeEpk && t.room == _activeRoomId;

  /// Bind the writer to a (peer, room). Opens the box and rebuilds the
  /// dedupe/seq index from it. Called by the chat when it mounts / switches
  /// rooms; also adopted automatically on the first StatusOnline.
  Future<void> activate(String epk, String roomId) async {
    final room = roomId.isEmpty ? 'main' : roomId;
    if (_activeEpk == epk && _activeRoomId == room && _indexLoaded) return;
    // Session switch: drop the previous room's no-echo send backstops (its
    // pending rows re-arm when ITS box loads — see _loadIndex). Per-room turn
    // state deliberately SURVIVES: a room still mid-turn keeps accumulating
    // (working flag, streaming buffers, reasoning start time) in its own slot,
    // so returning to it restores the in-flight bubble and its thinking
    // counter instead of starting from zero.
    _cancelAllSendTimers();
    final prevTurn = _activeEpk != null
        ? _turns[LocalBoxes.sessionKey(_activeEpk!, _activeRoomId)]
        : null;
    _activeEpk = epk;
    _activeRoomId = room;
    // Re-aim the UI-facing streams at the NEW room's slot: when the previous
    // room was mid-turn (working pill / live bubble), publish the new room's
    // state — or the cleared sentinel — so listeners that don't re-seed on
    // their own (a still-mounted chat VM, a quick A→B→A hop) stop showing the
    // previous room's working state. A genuinely idle switch emits nothing.
    if (prevTurn != null &&
        (prevTurn.working || prevTurn.streaming != null)) {
      final nextTurn = _turns[LocalBoxes.sessionKey(epk, room)];
      if (!_streamingController.isClosed) {
        _streamingController.add(nextTurn?.streaming);
      }
      if (!_workingController.isClosed) {
        _workingController.add(nextTurn?.working ?? false);
      }
    }
    await _loadIndex();
    _writeRuntime();
  }

  Future<void> sendMessage(
    String text, {
    MessageImage? image,
    OutgoingFile? file,
    UserMessageStreamingBehavior? streamingBehavior,
  }) async {
    final epk = _activeEpk;
    final id = _newId();
    final now = DateTime.now();
    final isSteer = streamingBehavior == UserMessageStreamingBehavior.steer;
    // Optimistic pending row (#defaults: optimistic + dedupe by id).
    final t = epk != null ? _turn(epk, _activeRoomId) : null;
    if (epk != null) {
      await _upsert(
        MsgRole.user,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.user,
          text: text,
          image: image,
          // The Pi's path only arrives with the echo; the pending row shows
          // the name so the bubble reads correctly while it is in flight.
          file: file == null ? null : MessageFile(name: file.name),
          ts: now,
          pending: true,
          steering: isSteer,
        ),
      );
      if (!isSteer) {
        _setWorking(
          t!,
          true,
          preview: _preview(text, image, _filePreview(file)),
          replyTo: id,
        );
      }
      // Arm the no-echo backstop for this row. The timeout is keyed off the
      // row's `ts`, NOT online-ness: an offline "held pending" send is reaped
      // 20s after its ts too, and ANY pending row is re-armed on session load
      // (see _loadIndex). So a quick session-switch or an app restart still
      // reaps a stale bubble instead of letting it spin "sending…" forever.
      _armSendTimeout(id, now);
    }
    final ch = _conn.channel;
    if (ch == null) {
      debugPrint(
        '[msg-send] id=$id (offline → held pending, reaped in '
        '${pendingSendTimeout.inSeconds}s)',
      );
      return;
    }
    // Seed an EMPTY streaming buffer so the blinking cursor shows during the
    // "thinking" gap before the first agent_chunk (pre-31 behavior). In-memory
    // only (#7) — never written to the DB. agent_chunk appends; agent_done
    // clears it (even for a text-less, tool-only turn).
    // Steering messages should not create a new cursor, because they do not
    // start a fresh assistant turn.
    if (!isSteer && t != null) {
      _emitStreaming(t, StreamingMessage(inReplyTo: id));
    }
    debugPrint('[msg-send] id=$id text=${_preview(text, image, _filePreview(file))}');
    await ch.send(
      UserMessage(
        id: id,
        text: text,
        streamingBehavior: streamingBehavior,
        images: image == null
            ? null
            : [WireImage(data: image.data, mime: image.mime)],
        files: file == null
            ? null
            : [WireFile(name: file.name, text: file.text)],
      ),
    );
  }

  /// Arm (or re-arm) the silent no-echo backstop for a pending row, keyed by
  /// `id`. The window is the time REMAINING relative to the row's [ts], so a
  /// row loaded from disk already past [pendingSendTimeout] fires immediately
  /// (floored at zero). Idempotent — cancels any existing timer for `id`.
  void _armSendTimeout(String id, DateTime ts) {
    _pendingSendTimers.remove(id)?.cancel();
    final remaining = pendingSendTimeout - DateTime.now().difference(ts);
    _pendingSendTimers[id] = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () => _onSendTimeout(id),
    );
  }

  /// No echo arrived within [pendingSendTimeout]: drop the optimistic bubble
  /// silently and unwind only the turn state that belongs to THIS `id`.
  void _onSendTimeout(String id) {
    _pendingSendTimers.remove(id);
    // ignore: discarded_futures
    _removeById(id);
    final t = _activeTurn;
    // Clear the thinking cursor only if it's seeded for this message.
    if (t != null && t.streaming?.inReplyTo == id) _emitStreaming(t, null);
    // Clear working ONLY if this id owns it — never knock down a turn that a
    // different (echoed) message is already driving.
    if (t != null && t.workingReplyTo == id) _setWorking(t, false);
    debugPrint(
      '[msg-timeout] id=$id removed (no echo in '
      '${pendingSendTimeout.inSeconds}s)',
    );
  }

  void _cancelAllSendTimers() {
    for (final t in _pendingSendTimers.values) {
      t.cancel();
    }
    _pendingSendTimers.clear();
  }

  /// Test seam — number of armed no-echo timers (asserts no leak on reset).
  @visibleForTesting
  int get debugPendingSendTimerCount => _pendingSendTimers.length;

  Future<void> queueMessage(String text) async {
    final ch = _conn.channel;
    if (ch == null) return;
    final epk = _activeEpk;
    if (epk == null) return;
    final t = _turn(epk, _activeRoomId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final id = _newId();
    _setQueuedMessages(t, [
      ...t.queuedMessages,
      QueuedMsg(
        id: id,
        text: trimmed,
        editable: true,
        createdAt: DateTime.now(),
      ),
    ]);
    await ch.send(QueuedMessageSet(id: id, text: trimmed));
  }

  Future<void> setQueuedMessage(String text) => queueMessage(text);

  Future<void> clearQueuedMessage([String? targetId]) async {
    final epk = _activeEpk;
    if (epk == null) return;
    final t = _turn(epk, _activeRoomId);
    if (targetId == null) {
      _setQueuedMessages(t, const []);
    } else {
      _setQueuedMessages(t, [
        for (final item in t.queuedMessages)
          if (item.id != targetId) item,
      ]);
    }
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(QueuedMessageClear(id: _newId(), targetId: targetId));
  }

  Future<void> clearQueuedMessages() => clearQueuedMessage();

  Future<void> cancel(String targetId) async {
    // User-driven cancel of this message → disarm its no-echo backstop too.
    _pendingSendTimers.remove(targetId)?.cancel();
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(Cancel(id: _newId(), targetId: targetId));
  }

  /// Plan/57 — respond to an interactive extension_ui_request (ask_user).
  /// The ChatViewModel builds the [ExtensionUiResponse] (value/confirmed/
  /// cancelled + optional `ask` envelope); the SyncService just ships it.
  /// Returns false when there is no live channel or the send fails so the
  /// caller can surface a retryable failure immediately instead of waiting on
  /// the sheet's 25s backstop.
  Future<bool> respondExtensionUi(ExtensionUiResponse resp) async {
    final ch = _conn.channel;
    if (ch == null) return false;
    try {
      await ch.send(resp);
      return true;
    } catch (error) {
      debugPrint('[extension-ui] failed to send response: $error');
      return false;
    }
  }

  Future<void> approveTool(String toolCallId, ApproveDecision decision) async {
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(
      ApproveTool(id: _newId(), toolCallId: toolCallId, decision: decision),
    );
    await _upsert(MsgRole.tool, toolCallId, (seq, existing) {
      final base =
          existing?.tool ??
          ToolEventData(toolCallId: toolCallId, tool: 'unknown');
      return (existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
              ))
          .copyWith(
            tool: base.copyWith(
              status: decision == ApproveDecision.allow
                  ? ToolEventStatus.allowed
                  : ToolEventStatus.denied,
            ),
          );
    });
  }

  void requestSync() {
    final ch = _conn.channel;
    if (ch == null || _activeEpk == null) {
      _pendingSyncRequest = true;
      return;
    }
    _pendingSyncRequest = false;
    ch.send(SessionSync(id: _newId()));
  }

  /// Plan/28 — `session_new` acked: wipe the active session's rows + index.
  Future<void> clearActiveSession() async {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final t = _turn(epk, room);
    // Session wiped → any optimistic sends/streaming/working state are moot.
    _cancelAllSendTimers();
    _discardStreamingState(t);
    _setQueuedMessages(t, const []);
    _setWorking(t, false);
    await _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      await box.clear();
      _idToSeq.clear();
      _nextSeq = 0;
      _indexLoaded = true;
      final idx = _boxes.sessionsIndexBox();
      await idx.delete(LocalBoxes.sessionKey(epk, room));
    });
  }

  // ---------------------------------------------------------------------------
  // Channel → DB (active room) + per-room turn state
  // ---------------------------------------------------------------------------

  void _onStatus(ConnectionStatus s) {
    _msgSub?.cancel();
    _msgSub = null;
    if (s is StatusOnline) {
      // Plan/32f — bind this stream's writes to the PEER that owns the
      // channel RIGHT NOW. After a `switchTo`, a late frame from the OLD
      // peer's channel must not land in the NEW session's box: `_activeEpk`
      // has already moved (the chat calls `activate()` before `switchTo`), so
      // a straggler chat-1 frame would otherwise be written to chat-2's box
      // and bleed across until chat-2's history re-applied. We capture the
      // origin epk here and drop frames whose origin is no longer active.
      //
      // We gate on epk only — NOT room: rooms of the same peer share one
      // channel and `_onStatus` doesn't re-fire on a same-peer room switch
      // (the transport already demuxes by room), so a room gate would wrongly
      // drop everything after switching cwds on the same Mac.
      final originEpk = _conn.activePeer?.remoteEpk;
      _msgSub = s.channel.serverMessages.listen(
        (msg) => _onServerMessage(msg, originEpk),
        onError: (Object _, StackTrace _) {},
      );
      // ignore: discarded_futures
      _onlineActivated();
    }
    _writeRuntime();
  }

  /// Background path — every room's inbound frames (raw material that also
  /// feeds background notifications). Active-room frames are skipped here
  /// (the writer path owns them, DB writes included); non-active rooms only
  /// get their IN-MEMORY turn state updated, so a streaming room the user is
  /// not viewing keeps filling its own slot. Its finalized rows come back
  /// via the history re-sync when the user re-enters it.
  void _onRoomMessage(RoomMessage m) {
    if (m.epk == _activeEpk && m.roomId == _activeRoomId) return;
    final t = _turn(m.epk, m.roomId);
    switch (m.message) {
      case AgentChunk(:final inReplyTo, :final delta):
        _applyChunk(t, inReplyTo, delta);
      case AgentThinking(:final inReplyTo, :final delta):
        _applyThinking(t, inReplyTo, delta);
      case AgentDone(:final inReplyTo):
        _applyAgentDone(t, inReplyTo);
      case UserInput(
        :final id,
        :final text,
        :final image,
        :final file,
        :final streamingBehavior,
      ):
        if (t.queuedMessages.any((item) => item.id == id)) {
          _setQueuedMessages(t, [
            for (final item in t.queuedMessages)
              if (item.id != id) item,
          ]);
        }
        if (streamingBehavior == UserMessageStreamingBehavior.steer) {
          _setActivity(m.epk, m.roomId, SessionActivity.working, preview: text);
        } else {
          _setWorking(
            t,
            true,
            preview: _preview(text, _messageImage(image), _messageFile(file)),
            replyTo: id,
          );
          if (t.streaming?.inReplyTo != id) {
            _emitStreaming(t, StreamingMessage(inReplyTo: id));
          }
        }
      case Cancelled(:final targetId):
        _pendingSendTimers.remove(targetId)?.cancel();
        _applyCancelled(t, targetId);
      case ErrorMessage():
        _discardStreamingState(t);
        _setWorking(t, false);
      case QueuedMessageState(:final items):
        _setQueuedMessages(t, [
          for (final item in items)
            QueuedMsg(
              id: item.id,
              text: item.text,
              editable: item.editable,
              createdAt: item.createdAt,
            ),
        ]);
      default:
        // DB-backed frames (AgentMessage, Tool*, SessionHistory, …) for a
        // background room: not the writer's job; recovered by re-sync.
        break;
    }
  }

  Future<void> _onlineActivated() async {
    final peer = _conn.activePeer;
    if (peer != null && _activeEpk == null) {
      await activate(peer.remoteEpk, _conn.activeRoomId);
    }
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 200), requestSync);
    if (_pendingSyncRequest) requestSync();
  }

  void _onServerMessage(ServerMessage msg, [String? originEpk]) {
    // Plan/32f — drop frames from a peer whose channel is no longer the active
    // session (a stale connection still draining after `switchTo`). Without
    // this, a straggler write targets `_activeEpk` — which already points at
    // the NEW chat — and bleeds the old session's messages into the new box.
    // Only gate when BOTH origin and active are set and differ: pre-bind
    // (`_activeEpk == null`, cold boot before `activate`) must still flow, and
    // direct test calls without an origin aren't gated.
    if (originEpk != null && _activeEpk != null && originEpk != _activeEpk) {
      return;
    }
    // Turn-state slot for the active room (null pre-bind, before any
    // activate — DB writes are no-ops then too, so skipping turn state is
    // consistent).
    final epk = _activeEpk;
    final t = epk != null ? _turn(epk, _activeRoomId) : null;
    switch (msg) {
      case AgentChunk(:final inReplyTo, :final delta):
        if (t == null) return;
        _applyChunk(t, inReplyTo, delta);

      case AgentThinking(:final inReplyTo, :final delta):
        if (t == null) return;
        _applyThinking(t, inReplyTo, delta);

      case AgentDone(:final inReplyTo):
        if (t == null) return;
        _applyAgentDone(t, inReplyTo);

      case AgentMessage(:final inReplyTo, :final text):
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          inReplyTo,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: inReplyTo,
                seq: seq,
                role: MsgRole.assistant,
                text: text,
                ts: DateTime.now(),
              ),
        );

      case QueuedMessageState(:final items):
        if (t == null) return;
        _setQueuedMessages(t, [
          for (final item in items)
            QueuedMsg(
              id: item.id,
              text: item.text,
              editable: item.editable,
              createdAt: item.createdAt,
            ),
        ]);

      case SteerConsumed(:final id):
        _clearSteeringLabel(id);

      case UserInput(
        :final id,
        :final text,
        :final image,
        :final file,
        :final streamingBehavior,
      ):
        // Echo dedupes against the optimistic row (same id): confirm it
        // (pending=false) or insert as confirmed (foreign device).
        debugPrint('[msg-echo] id=$id');
        // Echo arrived → the send landed; disarm the no-echo backstop.
        _pendingSendTimers.remove(id)?.cancel();
        if (t != null && t.queuedMessages.any((item) => item.id == id)) {
          _setQueuedMessages(t, [
            for (final item in t.queuedMessages)
              if (item.id != id) item,
          ]);
        }
        // ignore: discarded_futures
        _upsert(
          MsgRole.user,
          id,
          (seq, existing) => existing != null
              // The echo is where the Pi reports the path it saved an upload
              // to, so merge it in rather than keeping the local name-only row.
              ? existing.copyWith(pending: false, file: _messageFile(file))
              : MessageRecord(
                  id: id,
                  seq: seq,
                  role: MsgRole.user,
                  text: text,
                  image: _messageImage(image),
                  file: _messageFile(file),
                  ts: DateTime.now(),
                ),
        );
        if (t == null) return;
        // Steering input should not start/replace the working turn bubble.
        if (streamingBehavior == UserMessageStreamingBehavior.steer) {
          _setActivity(epk!, _activeRoomId, SessionActivity.working, preview: text);
        } else {
          _setWorking(t, true, preview: text, replyTo: id);
          // Show the thinking cursor for this turn (foreign-device echo, or the
          // local echo when the send-seed was already cleared). Guarded so it
          // never wipes a buffer that's already accumulating for this id.
          if (t.streaming?.inReplyTo != id) {
            _emitStreaming(t, StreamingMessage(inReplyTo: id));
          }
        }

      case ToolRequest(:final toolCallId, :final tool, :final args):
        // Sequential ordering: close the open segment(s) as their own rows
        // BEFORE the tool, so "reasoning → narration → command → narration"
        // renders in order instead of all text landing after the commands.
        if (t != null) {
          _finalizeThinkingSegment(t);
          _finalizeTextSegment(t);
        }
        // ignore: discarded_futures
        _upsert(
          MsgRole.tool,
          toolCallId,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  tool: tool,
                  args: args,
                ),
              ),
        );

      case ToolResult(:final toolCallId, :final result, :final error, :final diff):
        // ignore: discarded_futures
        _upsert(MsgRole.tool, toolCallId, (seq, existing) {
          final base =
              existing?.tool ??
              ToolEventData(toolCallId: toolCallId, tool: 'unknown');
          return (existing ??
                  MessageRecord(
                    id: toolCallId,
                    seq: seq,
                    role: MsgRole.tool,
                    ts: DateTime.now(),
                  ))
              .copyWith(
                tool: base.copyWith(
                  status: error != null
                      ? ToolEventStatus.failed
                      : ToolEventStatus.completed,
                  result: result,
                  error: error,
                  diff: diff,
                ),
              );
        });

      case Cancelled(:final targetId):
        _pendingSendTimers.remove(targetId)?.cancel();
        if (t != null) _applyCancelled(t, targetId);

      case Bye(:final rawReason):
        if (!_eventController.isClosed) {
          _eventController.add(PeerWentOffline(rawReason));
        }
        if (t != null) {
          _clearSteeringLabels();
          _discardStreamingState(t);
          _setWorking(t, false);
        }
        final peer = _conn.activePeer;
        if (peer != null) {
          // ignore: discarded_futures
          _conn.switchTo(peer);
        }

      case SessionHistory():
        // ignore: discarded_futures
        _applyHistory(msg);

      case ErrorMessage(:final code, :final message):
        if (code.contains('unknown_peer')) {
          if (!_eventController.isClosed) {
            _eventController.add(const PairingRevoked());
          }
          break;
        }
        if (t != null) {
          _discardStreamingState(t);
          _setWorking(t, false);
        }
        _clearSteeringLabels();
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          _newId(),
          (seq, _) => MessageRecord(
            id: 'err_$seq',
            seq: seq,
            role: MsgRole.assistant,
            text: '⚠ $code: $message',
            ts: DateTime.now(),
          ),
        );

      case Compaction(:final summary, :final tokensBefore, :final ts):
        _writeCompaction(summary, tokensBefore, ts);

      case ExtensionUiRequest():
        // Plan/57 — transient interactive prompt (ask_user via pi-ask).
        // Surface to the UI; never persist (it's a live request, not history).
        _extensionUiController.add(msg);
        break;
      case Pong():
      case PairOk():
      case PairError():
      case ActionOk():
      case ActionError():
      case ModelsList():
      // Command channel: the `/` palette catalogue is consumed by the
      // ActionsRepository (it asked for it), the action replies with it, and a
      // `!` shell execution rides the normal tool stream as a `bash` card.
      // Nothing here belongs in the transcript.
      case CommandsList():
        break;
    }
  }

  /// Plan/32 — persist a compaction as a system row so it renders a system
  /// bubble in the chat and survives a re-sync. Keyed by `ts` when present so
  /// the live message and its history replay collapse to one row.
  void _writeCompaction(String summary, int? tokensBefore, int? ts) {
    final id = 'compaction_${ts ?? uuid7()}';
    final when = ts != null
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.now();
    // ignore: discarded_futures
    _upsert(
      MsgRole.compaction,
      id,
      (seq, existing) =>
          existing ??
          MessageRecord(
            id: id,
            seq: seq,
            role: MsgRole.compaction,
            text: summary,
            tokensBefore: tokensBefore,
            ts: when,
          ),
    );
  }

  Future<void> _applyHistory(SessionHistory h) async {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final rows = _convertHistory(h.events);
    final historyIds = {for (final r in rows) _key(r.role, r.id)};
    await _enqueue(() async {
      final box = await _boxes.msgsBox(epk, room);
      // Preserve local pending user rows the Pi hasn't echoed yet.
      final preserved = <MessageRecord>[];
      for (final v in box.values) {
        final r = MessageRecord.fromJson(_coerce(v));
        if (r.role == MsgRole.user &&
            r.pending &&
            !historyIds.contains(_key(r.role, r.id))) {
          preserved.add(r);
        }
      }
      // Desired ordered state: history (seq = index) then preserved pending.
      final desired = <MessageRecord>[
        for (var i = 0; i < rows.length; i++) rows[i].copyWith(seq: i),
        for (var j = 0; j < preserved.length; j++)
          preserved[j].copyWith(seq: rows.length + j),
      ];
      // Reconcile the box to `desired` with the MINIMUM number of writes.
      //
      // The old path did `box.clear()` + re-put every row. Hive emits a watch
      // event per deleted AND per put key, so the read repo re-emitted ~2N
      // times — tearing the whole list down to EMPTY and rebuilding it — on
      // EVERY SessionHistory the relay re-delivered (which it does on every
      // reconnect). That was the flicker/"embaralha e some". Diffing instead
      // means a re-sent identical history produces ZERO box writes → ZERO
      // emits → no rebuild; a changed history only rewrites the rows that
      // actually differ.
      for (final k in box.keys.toList()) {
        if ((k as num).toInt() >= desired.length) {
          await box.delete(k);
        }
      }
      for (var i = 0; i < desired.length; i++) {
        final newJson = desired[i].toJson();
        final curRaw = box.get(i);
        // Normalise the stored value through fromJson→toJson so the compare is
        // independent of however Hive ordered the persisted map.
        final curNorm = curRaw == null
            ? null
            : jsonEncode(MessageRecord.fromJson(_coerce(curRaw)).toJson());
        if (curNorm != jsonEncode(newJson)) {
          await box.put(i, newJson);
        }
      }
      if (_activeEpk == epk && _activeRoomId == room) {
        _idToSeq
          ..clear()
          ..addEntries([
            for (var i = 0; i < desired.length; i++)
              MapEntry(_key(desired[i].role, desired[i].id), i),
          ]);
        _nextSeq = desired.length;
        _indexLoaded = true;
      }
    });
    if (_activeEpk == epk && _activeRoomId == room) {
      final started = h.sessionStartedAt;
      _updateIndex(
        epk,
        room,
        (cur) => cur.copyWith(
          sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(started),
        ),
      );
    }
  }

  List<MessageRecord> _convertHistory(List<SessionHistoryEvent> events) {
    final out = <MessageRecord>[];
    var seq = 0;
    for (final e in events) {
      switch (e) {
        case UserInputEvt(:final id, :final text, :final image, :final file):
          out.add(
            MessageRecord(
              id: id,
              seq: seq++,
              role: MsgRole.user,
              text: text,
              image: _messageImage(image),
              file: _messageFile(file),
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
        case AgentMessageEvt(:final inReplyTo, :final text):
          out.add(
            MessageRecord(
              id: inReplyTo,
              seq: seq++,
              role: MsgRole.assistant,
              text: text,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
        case AgentThinkingEvt(:final text, :final durationMs):
          // Reasoning replayed ahead of the answer of the same message (content
          // order is preserved by the mapper). Id is stable per (ts, index) so
          // a re-sent identical history rewrites nothing.
          if (text.isNotEmpty) {
            out.add(
              MessageRecord(
                id: 'thinking_${e.ts}_$seq',
                seq: seq++,
                role: MsgRole.thinking,
                text: text,
                ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
                thinkingMs: durationMs,
              ),
            );
          }
        case ToolRequestEvt(:final toolCallId, :final tool, :final args):
          out.add(
            MessageRecord(
              id: toolCallId,
              seq: seq++,
              role: MsgRole.tool,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
              tool: ToolEventData(
                toolCallId: toolCallId,
                tool: tool,
                args: args,
              ),
            ),
          );
        case ToolResultEvt(:final toolCallId, :final result, :final error, :final diff):
          final idx = out.lastIndexWhere(
            (m) => m.role == MsgRole.tool && m.tool?.toolCallId == toolCallId,
          );
          final status = error != null
              ? ToolEventStatus.failed
              : ToolEventStatus.completed;
          if (idx >= 0) {
            out[idx] = out[idx].copyWith(
              tool: out[idx].tool!.copyWith(
                status: status,
                result: result,
                error: error,
                diff: diff,
              ),
            );
          } else {
            out.add(
              MessageRecord(
                id: toolCallId,
                seq: seq++,
                role: MsgRole.tool,
                ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  tool: 'unknown',
                  status: status,
                  result: result,
                  error: error,
                  diff: diff,
                ),
              ),
            );
          }
        case CompactionEvt(:final summary, :final tokensBefore):
          out.add(
            MessageRecord(
              id: 'compaction_${e.ts}',
              seq: seq++,
              role: MsgRole.compaction,
              text: summary,
              tokensBefore: tokensBefore,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Box write helpers (all serialised through _enqueue)
  // ---------------------------------------------------------------------------

  String _key(MsgRole role, String id) => '${role.name}:$id';

  Future<void> _loadIndex() {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      _idToSeq.clear();
      _nextSeq = 0;
      for (final k in box.keys) {
        final seq = (k as num).toInt();
        final r = MessageRecord.fromJson(_coerce(box.get(k)));
        _idToSeq[_key(r.role, r.id)] = seq;
        _nextSeq = math.max(_nextSeq, seq + 1);
        // Re-arm the no-echo backstop for any pending row this session owns, so
        // a bubble persisted across an app restart / quick session-switch is
        // reaped by its `ts` instead of spinning forever (already-stale → fires
        // immediately). Timers were cleared by the session switch before this
        // load.
        if (r.role == MsgRole.user && r.pending) _armSendTimeout(r.id, r.ts);
      }
      _indexLoaded = true;
    });
  }

  Future<void> _upsert(
    MsgRole role,
    String id,
    MessageRecord Function(int seq, MessageRecord? existing) build,
  ) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      final active = _activeEpk == epk && _activeRoomId == room;
      if (!active) return;
      final box = await _boxes.msgsBox(epk, room);
      final mapKey = _key(role, id);
      final existingSeq = _idToSeq[mapKey];
      if (existingSeq != null) {
        final existing = MessageRecord.fromJson(_coerce(box.get(existingSeq)));
        await box.put(existingSeq, build(existingSeq, existing).toJson());
      } else {
        final seq = _nextSeq++;
        await box.put(seq, build(seq, null).toJson());
        _idToSeq[mapKey] = seq;
      }
    });
  }

  Future<void> _removeById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final role in MsgRole.values) {
        final seq = _idToSeq.remove(_key(role, id));
        if (seq != null) await box.delete(seq);
      }
    });
  }

  void _clearSteeringLabel(String id) {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      final seq = _idToSeq[_key(MsgRole.user, id)];
      if (seq == null) return;
      final raw = box.get(seq);
      if (raw == null) return;
      final existing = MessageRecord.fromJson(_coerce(raw));
      if (existing.role != MsgRole.user || !existing.steering) return;
      await box.put(seq, existing.copyWith(steering: false).toJson());
    });
  }

  void _clearSteeringLabels() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw == null) continue;
        final existing = MessageRecord.fromJson(_coerce(raw));
        if (existing.role != MsgRole.user || !existing.steering) continue;
        await box.put(
          (key as num).toInt(),
          existing.copyWith(steering: false).toJson(),
        );
      }
    });
  }

  Future<void> _removePendingById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final role in MsgRole.values) {
        final key = _key(role, id);
        final seq = _idToSeq[key];
        if (seq == null) continue;
        final raw = box.get(seq);
        if (raw == null) {
          _idToSeq.remove(key);
          continue;
        }
        final existing = MessageRecord.fromJson(_coerce(raw));
        if (!existing.pending) continue;
        _idToSeq.remove(key);
        await box.delete(seq);
      }
    });
  }

  void _setActivity(String epk, String room, SessionActivity status, {String? preview}) {
    _updateIndex(
      epk,
      room,
      (cur) => cur.copyWith(
        status: status,
        lastMessageAt: preview != null ? DateTime.now() : null,
        lastMessagePreview: preview,
      ),
    );
  }

  void _setQueuedMessages(_RoomTurn t, List<QueuedMsg> items) {
    final next = List<QueuedMsg>.unmodifiable(items);
    if (t.queuedMessages == next) return;
    t.queuedMessages = next;
    if (_isActive(t) && !_queuedController.isClosed) _queuedController.add(next);
  }

  /// Single source of "a room is working". Drives that room's in-memory
  /// flag/stream (the chat pill, active room only), its durable session index
  /// (Home dot) and — for the connected room — the app-side room-meta
  /// correction the relay-based Home dot falls back on.
  void _syncTurnStateFromRoomMeta() {
    final epk = _activeEpk;
    if (epk == null) return;
    final t = _turns[LocalBoxes.sessionKey(epk, _activeRoomId)];
    final remoteWorking = _conn.isRoomWorking(epk, _activeRoomId);
    if (remoteWorking) {
      if (t != null) t.sawRemoteWorking = true;
      return;
    }
    if (t != null && t.sawRemoteWorking && t.working) {
      _discardStreamingState(t);
      _setWorking(t, false);
    }
    if (t != null) t.sawRemoteWorking = false;
  }

  void _setWorking(
    _RoomTurn t,
    bool on, {
    String? preview,
    String? replyTo,
  }) {
    _setActivity(
      t.epk,
      t.room,
      on ? SessionActivity.working : SessionActivity.idle,
      preview: preview,
    );
    // App-side correction is only valid for the CONNECTED room — non-active
    // rooms' Home dots stay the relay's domain (their relay meta broadcast is
    // the source of truth).
    if (_isActive(t)) {
      _conn.markRoomWorking(t.epk, t.room, on);
    }
    if (on) {
      if (replyTo != null) t.workingReplyTo = replyTo;
    } else {
      t.workingReplyTo = null;
      t.sawRemoteWorking = false;
    }
    if (t.working == on) return;
    t.working = on;
    if (_isActive(t) && !_workingController.isClosed) _workingController.add(on);
  }

  void _updateIndex(
    String epk,
    String room,
    SessionIndexRecord Function(SessionIndexRecord cur) build,
  ) {
    // ignore: discarded_futures
    _enqueue(() async {
      final idx = _boxes.sessionsIndexBox();
      final key = LocalBoxes.sessionKey(epk, room);
      final raw = idx.get(key);
      final cur = raw is Map
          ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
          : SessionIndexRecord(epk: epk, roomId: room);
      await idx.put(key, build(cur).toJson());
    });
  }

  void _writeRuntime() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final s = _conn.status;
    final conn = switch (s) {
      StatusOnline() => RuntimeConnection.online,
      StatusConnecting() => RuntimeConnection.connecting,
      StatusRetrying() => RuntimeConnection.retrying,
      StatusOffline() => RuntimeConnection.offline,
      StatusNoPeer() => RuntimeConnection.connecting,
    };
    final presence = (s is StatusOnline && _conn.isRoomLive(epk, room))
        ? RuntimePresence.alive
        : (s is StatusOnline ? RuntimePresence.stale : RuntimePresence.unknown);
    // ignore: discarded_futures
    _enqueue(() async {
      _boxes.runtimeBox().put(
        LocalBoxes.sessionKey(epk, room),
        RuntimeRecord(connection: conn, presence: presence).toJson(),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Per-room turn state (streaming in-memory only — #7)
  // ---------------------------------------------------------------------------

  void _applyChunk(_RoomTurn t, String inReplyTo, String delta) {
    // Answer text follows the reasoning block → the reasoning segment is
    // over; persist it as its own row before the text starts.
    _finalizeThinkingSegment(t);
    t.chunkBuffer.write(delta);
    t.chunkReplyTo = inReplyTo;
    t.flushTimer?.cancel();
    t.flushTimer = Timer(const Duration(milliseconds: 16), () => _flushStreaming(t));
    _setWorking(t, true, replyTo: inReplyTo);
  }

  void _applyThinking(_RoomTurn t, String inReplyTo, String delta) {
    // Mirror image: a reasoning block after text closes the text segment.
    _finalizeTextSegment(t);
    // First delta of this reasoning segment: stamp the start. Survives room
    // switches (per-room slot) so the thinking counter never resets to zero.
    t.thinkingStartedAt ??= DateTime.now();
    t.thinkingBuffer.write(delta);
    t.thinkingReplyTo = inReplyTo;
    t.flushTimer?.cancel();
    t.flushTimer = Timer(const Duration(milliseconds: 16), () => _flushStreaming(t));
    _setWorking(t, true, replyTo: inReplyTo);
  }

  void _applyAgentDone(_RoomTurn t, String inReplyTo) {
    // Finalize whatever accumulated since the last tool boundary
    // (reasoning first — it precedes text within a message).
    _finalizeThinkingSegment(t);
    final text = _finalizeTextSegment(t);
    if (_isActive(t)) _clearSteeringLabel(inReplyTo);
    _setWorking(t, false, preview: text.isEmpty ? null : text);
  }

  void _applyCancelled(_RoomTurn t, String targetId) {
    _discardStreamingState(t);
    if (_isActive(t)) {
      // Cancel is stop-generation, not delete-history. Only drop a local
      // optimistic row that never got confirmed by the Pi echo; preserve
      // confirmed user/tool rows as the audit trail of what happened.
      // ignore: discarded_futures
      _removePendingById(targetId);
      _clearSteeringLabels();
    }
    _setWorking(t, false);
  }

  /// Drain any coalesced delta sitting in the 16ms buffer into the live slot.
  /// Exactly one of the two buffers is normally non-empty.
  void _flushStreaming(_RoomTurn t) {
    if (t.thinkingBuffer.isNotEmpty) {
      final delta = t.thinkingBuffer.toString();
      t.thinkingBuffer.clear();
      final cur = t.streaming;
      _emitStreaming(
        t,
        (cur != null && cur.thinking && cur.inReplyTo == t.thinkingReplyTo)
            ? cur.appendDelta(delta)
            : StreamingMessage(
                inReplyTo: t.thinkingReplyTo,
                buffer: delta,
                thinking: true,
                startedAt: t.thinkingStartedAt,
              ),
      );
    }
    if (t.chunkBuffer.isEmpty) return;
    final delta = t.chunkBuffer.toString();
    t.chunkBuffer.clear();
    final cur = t.streaming;
    if (cur != null && !cur.thinking && cur.inReplyTo == t.chunkReplyTo) {
      _emitStreaming(t, cur.appendDelta(delta));
    } else {
      _emitStreaming(t, StreamingMessage(inReplyTo: t.chunkReplyTo, buffer: delta));
    }
  }

  /// Persist the accumulated streaming text as a standalone assistant row
  /// (unique id, in chronological seq order) and clear the live cursor.
  /// Called at every tool boundary AND on agent_done so text/tool/text
  /// renders sequentially. No-op when no text segment is open — so a
  /// tool-only, reasoning-only or empty turn never leaves a blank bubble.
  /// Background (non-active) rooms only clear their in-memory segment; their
  /// finalized rows come back via the history re-sync on re-entry.
  /// Returns the finalized text (empty if none).
  String _finalizeTextSegment(_RoomTurn t) {
    final live =
        t.chunkBuffer.isNotEmpty ||
        (t.streaming != null && !t.streaming!.thinking);
    if (!live) return '';
    // Drain any coalesced delta still sitting in the 16ms buffer.
    t.flushTimer?.cancel();
    t.flushTimer = null;
    if (t.chunkBuffer.isNotEmpty) {
      final delta = t.chunkBuffer.toString();
      t.chunkBuffer.clear();
      final cur = t.streaming;
      t.streaming = (cur != null && !cur.thinking && cur.inReplyTo == t.chunkReplyTo)
          ? cur.appendDelta(delta)
          : StreamingMessage(inReplyTo: t.chunkReplyTo, buffer: delta);
    }
    final text = t.streaming?.buffer ?? '';
    if (text.isNotEmpty && _isActive(t)) {
      final id = 'agent_${uuid7()}';
      // ignore: discarded_futures
      _upsert(
        MsgRole.assistant,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.assistant,
          text: text,
          ts: DateTime.now(),
        ),
      );
    }
    t.chunkReplyTo = '';
    _emitStreaming(t, null);
    return text;
  }

  /// Persist the accumulated reasoning as its own [MsgRole.thinking] row.
  /// Same lifecycle as [_finalizeTextSegment]: closed by text/tool/turn
  /// boundaries, no-op when no reasoning block is open. Returns the finalized
  /// reasoning text (empty if none).
  String _finalizeThinkingSegment(_RoomTurn t) {
    final live =
        t.thinkingBuffer.isNotEmpty || (t.streaming?.thinking ?? false);
    if (!live) return '';
    t.flushTimer?.cancel();
    t.flushTimer = null;
    if (t.thinkingBuffer.isNotEmpty) {
      final delta = t.thinkingBuffer.toString();
      t.thinkingBuffer.clear();
      final cur = t.streaming;
      t.streaming = (cur != null && cur.thinking && cur.inReplyTo == t.thinkingReplyTo)
          ? cur.appendDelta(delta)
          : StreamingMessage(
              inReplyTo: t.thinkingReplyTo,
              buffer: delta,
              thinking: true,
              startedAt: t.thinkingStartedAt,
            );
    }
    final text = t.streaming?.buffer ?? '';
    // The block is over: freeze how long it took. Measured here (not in the UI)
    // so the persisted row and the live counter are the same number.
    final startedAt = t.thinkingStartedAt;
    final elapsed =
        startedAt == null ? null : DateTime.now().difference(startedAt);
    if (text.isNotEmpty && _isActive(t)) {
      final id = 'thinking_${uuid7()}';
      // ignore: discarded_futures
      _upsert(
        MsgRole.thinking,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.thinking,
          text: text,
          ts: DateTime.now(),
          thinkingMs: elapsed?.inMilliseconds,
        ),
      );
    }
    t.thinkingReplyTo = '';
    t.thinkingStartedAt = null;
    _emitStreaming(t, null);
    return text;
  }

  void _discardStreamingState(_RoomTurn t) {
    t.flushTimer?.cancel();
    t.flushTimer = null;
    t.chunkBuffer.clear();
    t.chunkReplyTo = '';
    t.thinkingBuffer.clear();
    t.thinkingReplyTo = '';
    t.thinkingStartedAt = null;
    _emitStreaming(t, null);
  }

  /// Set the room's live slot. UI streams only observe the ACTIVE room's slot
  /// — a background room's slot updates silently until the user returns to
  /// it (the chat VM re-seeds from [streaming] on its activate).
  void _emitStreaming(_RoomTurn t, StreamingMessage? s) {
    t.streaming = s;
    if (_isActive(t) && !_streamingController.isClosed) {
      _streamingController.add(s);
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeChain.then((_) => op());
    _writeChain = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  static Map<String, dynamic> _coerce(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  /// Echo/history wire shape → the persisted+rendered shape (the content stays
  /// on the Pi; only the name and the landed path come back).
  static MessageFile? _messageFile(WireFile? file) =>
      file == null ? null : MessageFile(name: file.name, path: file.path);

  static MessageImage? _messageImage(WireImage? image) => image == null
      ? null
      : MessageImage(data: image.data, mime: image.mime);

  /// Send-path projection: the preview only needs the name (the content is
  /// not something we want to keep a second copy of in memory).
  static MessageFile? _filePreview(OutgoingFile? file) =>
      file == null ? null : MessageFile(name: file.name);

  static String _preview(String text, MessageImage? image, MessageFile? file) {
    if (text.isEmpty && image != null) return '📷 Image';
    if (text.isEmpty && file != null) return '📄 ${file.name}';
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  static String _newId() => 'cli_${uuid7()}';

  @override
  void dispose() {
    for (final t in _turns.values) {
      t.flushTimer?.cancel();
    }
    _syncDebounce?.cancel();
    _cancelAllSendTimers();
    _connSub?.cancel();
    _msgSub?.cancel();
    _roomMsgSub?.cancel();
    _roomsSub?.cancel();
    _presenceSub?.cancel();
    _streamingController.close();
    _eventController.close();
    _extensionUiController.close();
    _workingController.close();
    _queuedController.close();
  }
}
