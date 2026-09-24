import 'package:app/domain/session_state.dart';

/// Plan/31 — one persisted chat message (row-granular SSOT). Stored in the
/// per-session `msgs:<epk>:<roomId>` box, keyed by [seq]. Maps to the domain
/// [ChatMessage] the UI widgets already render.
enum MsgRole { user, assistant, tool, compaction, thinking }

class MessageRecord {
  /// Protocol id — the dedupe key (optimistic send ↔ Pi echo share it).
  final String id;

  /// Monotonic order within the session (the box key).
  final int seq;
  final MsgRole role;
  final String text;

  /// Plan/30 — attached image (user messages only).
  final MessageImage? image;

  /// Tool request+result collapsed into one row (tool messages only).
  final ToolEventData? tool;
  final DateTime ts;

  /// Optimistic: sent locally, not yet echoed by the Pi.
  final bool pending;

  /// Local-only hint: this pending user row was sent while the Pi was busy.
  final bool steering;

  /// Plan/32 — tokens reclaimed by a compaction (compaction rows only).
  final int? tokensBefore;

  /// Thinking rows only — how long the model spent on that block, when it was
  /// timed (measured live by the app, or replayed from the Pi's history event).
  final int? thinkingMs;

  const MessageRecord({
    required this.id,
    required this.seq,
    required this.role,
    this.text = '',
    this.image,
    this.tool,
    required this.ts,
    this.pending = false,
    this.steering = false,
    this.tokensBefore,
    this.thinkingMs,
  });

  MessageRecord copyWith({
    int? seq,
    String? text,
    MessageImage? image,
    ToolEventData? tool,
    bool? pending,
    bool? steering,
  }) => MessageRecord(
    id: id,
    seq: seq ?? this.seq,
    role: role,
    text: text ?? this.text,
    image: image ?? this.image,
    tool: tool ?? this.tool,
    ts: ts,
    pending: pending ?? this.pending,
    steering: steering ?? this.steering,
    tokensBefore: tokensBefore,
    thinkingMs: thinkingMs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'seq': seq,
    'role': role.name,
    'text': text,
    if (image != null) 'image': {'data': image!.data, 'mime': image!.mime},
    if (tool != null) 'tool': tool!.toJson(),
    'ts': ts.millisecondsSinceEpoch,
    'pending': pending,
    if (steering) 'steering': true,
    if (tokensBefore != null) 'tokens_before': tokensBefore,
    if (thinkingMs != null) 'thinking_ms': thinkingMs,
  };

  factory MessageRecord.fromJson(Map<String, dynamic> j) {
    final imageRaw = j['image'];
    final toolRaw = j['tool'];
    return MessageRecord(
      id: j['id'] as String,
      seq: (j['seq'] as num).toInt(),
      role: MsgRole.values.firstWhere(
        (r) => r.name == j['role'],
        orElse: () => MsgRole.assistant,
      ),
      text: (j['text'] as String?) ?? '',
      image: imageRaw is Map
          ? MessageImage(
              data: imageRaw['data'] as String,
              mime: imageRaw['mime'] as String,
            )
          : null,
      tool: toolRaw is Map
          ? ToolEventData.fromJson(toolRaw.cast<String, dynamic>())
          : null,
      ts: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num).toInt()),
      pending: (j['pending'] as bool?) ?? false,
      steering: (j['steering'] as bool?) ?? false,
      tokensBefore: (j['tokens_before'] as num?)?.toInt(),
      thinkingMs: (j['thinking_ms'] as num?)?.toInt(),
    );
  }

  /// Project to the domain [ChatMessage] the chat widgets render.
  ChatMessage toChatMessage() {
    switch (role) {
      case MsgRole.user:
        return UserMsg(
          id: id,
          text: text,
          status: pending ? UserMsgStatus.pending : UserMsgStatus.confirmed,
          steering: steering,
          image: image,
        );
      case MsgRole.assistant:
        return AssistantMsg(id: id, text: text);
      case MsgRole.thinking:
        return ThinkingMsg(
          id: id,
          text: text,
          duration: thinkingMs == null
              ? null
              : Duration(milliseconds: thinkingMs!),
        );
      case MsgRole.tool:
        final t = tool;
        return ToolEvent(
          id: id,
          toolCallId: t?.toolCallId ?? id,
          tool: t?.tool ?? 'unknown',
          args: t?.args,
          status: t?.status ?? ToolEventStatus.pending,
          result: t?.result,
          error: t?.error,
          diff: t?.diff,
        );
      case MsgRole.compaction:
        return CompactionMsg(id: id, summary: text, tokensBefore: tokensBefore);
    }
  }
}

/// Tool request + result collapsed into a single persisted shape.
class ToolEventData {
  final String toolCallId;
  final String tool;
  final dynamic args;
  final ToolEventStatus status;
  final dynamic result;
  final String? error;

  /// The tool's own diff of what it changed (see [ToolEvent.diff]). Persisted
  /// so reopening the app keeps showing the same diff a live call showed.
  final String? diff;

  const ToolEventData({
    required this.toolCallId,
    required this.tool,
    this.args,
    this.status = ToolEventStatus.pending,
    this.result,
    this.error,
    this.diff,
  });

  ToolEventData copyWith({
    ToolEventStatus? status,
    dynamic result,
    String? error,
    String? diff,
  }) => ToolEventData(
    toolCallId: toolCallId,
    tool: tool,
    args: args,
    status: status ?? this.status,
    result: result ?? this.result,
    error: error ?? this.error,
    diff: diff ?? this.diff,
  );

  Map<String, dynamic> toJson() => {
    'tool_call_id': toolCallId,
    'tool': tool,
    'args': args,
    'status': status.name,
    'result': result,
    'error': error,
    'diff': diff,
  };

  factory ToolEventData.fromJson(Map<String, dynamic> j) => ToolEventData(
    toolCallId: j['tool_call_id'] as String,
    tool: (j['tool'] as String?) ?? 'unknown',
    args: j['args'],
    status: ToolEventStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => ToolEventStatus.completed,
    ),
    result: j['result'],
    error: j['error'] as String?,
    diff: j['diff'] as String?,
  );
}
