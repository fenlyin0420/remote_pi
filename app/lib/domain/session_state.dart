// Session domain model — chat message variants + streaming buffer.
// Lives in domain/ → no Flutter, no network, no storage.

// ---------------------------------------------------------------------------
// ChatMessage — sealed union of message variants in the conversation history
// ---------------------------------------------------------------------------

sealed class ChatMessage {
  final String id;
  const ChatMessage({required this.id});
}

/// Plan/24-fix-app-source-of-truth: every UserMsg is tagged with the
/// lifecycle stage of its rebroadcast. `pending` = sent over WS but Pi
/// hasn't echoed it back yet; `confirmed` = Pi rebroadcast it (or it
/// came from `session_history` / another device's echo); `failed` =
/// 15s elapsed without echo, user can retry.
///
/// Default is `confirmed` for back-compat — every persisted UserMsg
/// from before this fix was effectively confirmed (the Pi wasn't
/// rebroadcasting then, but the local cache treated it as
/// authoritative).
enum UserMsgStatus { pending, confirmed, failed }

/// Plan/30 — an image attached to a user message. Carries the JPEG bytes
/// base64-encoded plus its mime type, mirroring the SDK's `ImageContent`.
/// Bytes always travel inline (decision #8: history replays the image too),
/// so the bubble can render straight from [data] with no extra round-trip.
class MessageImage {
  /// Base64-encoded image bytes (no data-URI prefix).
  final String data;

  /// Mime type, e.g. `image/jpeg`.
  final String mime;

  const MessageImage({required this.data, required this.mime});

  @override
  bool operator ==(Object other) =>
      other is MessageImage && other.data == data && other.mime == mime;

  @override
  int get hashCode => Object.hash(data, mime);
}

/// A text file a user message was sent with.
///
/// Unlike an image, the content never comes back: the Pi writes the file next
/// to its own state dir and reports where, so the bubble only needs [path].
class MessageFile {
  /// File name as picked on the device.
  final String name;

  /// Absolute path on the Pi's machine, once it landed the file. Null while
  /// the message is still pending (or when the Pi could not save it).
  final String? path;

  const MessageFile({required this.name, this.path});

  @override
  bool operator ==(Object other) =>
      other is MessageFile && other.name == name && other.path == path;

  @override
  int get hashCode => Object.hash(name, path);
}

/// A text file on its way out: the bytes are read on the device and travel
/// inline once. Never persisted — the Pi's echo replaces it with the landed
/// [MessageFile] (name + path).
class OutgoingFile {
  final String name;
  final String text;

  const OutgoingFile({required this.name, required this.text});
}

/// Android-owned queued follow-up shown above the composer. Protocol-free
/// domain value; SyncService maps wire items into this shape.
class QueuedMsg {
  final String id;
  final String text;
  final bool editable;
  final DateTime createdAt;

  const QueuedMsg({
    required this.id,
    required this.text,
    required this.editable,
    required this.createdAt,
  });

  @override
  bool operator ==(Object other) =>
      other is QueuedMsg &&
      other.id == id &&
      other.text == text &&
      other.editable == editable &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, text, editable, createdAt);
}

class UserMsg extends ChatMessage {
  final String text;
  final UserMsgStatus status;
  final bool steering;

  /// Plan/30 — optional attached image (one max). `null` for text-only
  /// messages, which is every message before this feature.
  final MessageImage? image;

  /// Optional uploaded text file (one max, never alongside an image). Carries
  /// the name always and the Pi's path once it landed the file.
  final MessageFile? file;

  const UserMsg({
    required super.id,
    required this.text,
    this.status = UserMsgStatus.confirmed,
    this.steering = false,
    this.image,
    this.file,
  });

  UserMsg copyWith({UserMsgStatus? status, bool? steering}) => UserMsg(
    id: id,
    text: text,
    status: status ?? this.status,
    steering: steering ?? this.steering,
    image: image,
    file: file,
  );

  @override
  bool operator ==(Object other) =>
      other is UserMsg &&
      other.id == id &&
      other.text == text &&
      other.status == status &&
      other.steering == steering &&
      other.image == image &&
      other.file == file;

  @override
  int get hashCode => Object.hash(id, text, status, steering, image, file);
}

class AssistantMsg extends ChatMessage {
  final String text;
  const AssistantMsg({required super.id, required this.text});

  @override
  bool operator ==(Object other) =>
      other is AssistantMsg && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
}

/// A file the Pi handed to the phone (`send_to_phone`), rendered as a card in
/// the timeline where the tool ran.
///
/// [blobName] is the local copy of the bytes inside the app's attachment dir,
/// or null while the card has no content yet (a card rebuilt from
/// `session_history` starts empty and fills in on the first view). The bytes
/// are deliberately NOT part of this object: a 2 MB base64 string inside a
/// message record would be loaded into memory every time the room is read.
class AttachmentMsg extends ChatMessage {
  final String name;
  final String path;
  final String mime;
  final int size;

  /// Optional caption the agent wrote for the card.
  final String? note;

  /// The Pi downscaled the image to fit the relay envelope.
  final bool resized;
  final int? originalSize;

  /// File name of the locally cached bytes, or null when not fetched yet.
  final String? blobName;

  /// Set when the Pi refused to send the file (too large, binary, gone). The
  /// card renders the reason instead of a preview.
  final String? error;

  /// The tool call this image came out of, when a tool's own result carried it.
  /// The chat renders such a card INSIDE that tool's row (there is no card of
  /// its own); null for a `send_to_phone` hand-off.
  final String? toolCallId;

  const AttachmentMsg({
    required super.id,
    required this.name,
    required this.path,
    required this.mime,
    required this.size,
    this.note,
    this.resized = false,
    this.originalSize,
    this.blobName,
    this.error,
    this.toolCallId,
  });

  /// True when the mime is an image the card can render inline (SVG is text
  /// and gets the file treatment, like on the Pi side).
  bool get isImage => mime.startsWith('image/') && mime != 'image/svg+xml';

  /// The card has something to show.
  bool get hasContent => blobName != null;

  AttachmentMsg copyWith({
    String? blobName,
    String? error,
    bool clearError = false,
  }) => AttachmentMsg(
    id: id,
    name: name,
    path: path,
    mime: mime,
    size: size,
    note: note,
    resized: resized,
    originalSize: originalSize,
    // A later replay carries no bytes, so only overwrite when we HAVE some.
    blobName: blobName ?? this.blobName,
    error: clearError ? null : (error ?? this.error),
    toolCallId: toolCallId,
  );

  @override
  bool operator ==(Object other) =>
      other is AttachmentMsg &&
      other.id == id &&
      other.name == name &&
      other.path == path &&
      other.mime == mime &&
      other.size == size &&
      other.note == note &&
      other.resized == resized &&
      other.originalSize == originalSize &&
      other.blobName == blobName &&
      other.error == error &&
      other.toolCallId == toolCallId;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    path,
    mime,
    size,
    note,
    resized,
    originalSize,
    blobName,
    error,
  );
}

/// Model reasoning for one turn ("thinking"). Rendered as a collapsible block,
/// collapsed by default — it's context, not the answer. Persisted like any
/// other row (including the `session_history` replay) so it survives a
/// reconnect / app restart.
class ThinkingMsg extends ChatMessage {
  final String text;

  /// How long the model spent on this block, when known. Live blocks are timed
  /// by the app; replayed ones carry the Pi's measurement. Null when nobody
  /// timed it — the block then shows no timer.
  final Duration? duration;

  const ThinkingMsg({required super.id, required this.text, this.duration});

  @override
  bool operator ==(Object other) =>
      other is ThinkingMsg &&
      other.id == id &&
      other.text == text &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(id, text, duration);
}

class ToolEvent extends ChatMessage {
  final String toolCallId;
  final String tool;
  final dynamic args;
  final ToolEventStatus status;
  final dynamic result;
  final String? error;

  /// The tool's own diff of what it changed — `edit` reports one, every other
  /// tool leaves it null. Once it is here the card renders it in place of the
  /// args preview: this is what actually happened, and it is also the only diff
  /// that survives a re-sync (the preview is built by the daemon from the file
  /// before the edit ran, and history does not replay it).
  final String? diff;

  const ToolEvent({
    required super.id,
    required this.toolCallId,
    required this.tool,
    required this.args,
    this.status = ToolEventStatus.pending,
    this.result,
    this.error,
    this.diff,
  });

  ToolEvent copyWith({
    ToolEventStatus? status,
    dynamic result,
    String? error,
    String? diff,
  }) => ToolEvent(
    id: id,
    toolCallId: toolCallId,
    tool: tool,
    args: args,
    status: status ?? this.status,
    result: result ?? this.result,
    error: error ?? this.error,
    diff: diff ?? this.diff,
  );

  @override
  bool operator ==(Object other) =>
      other is ToolEvent &&
      other.id == id &&
      other.toolCallId == toolCallId &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, toolCallId, status);
}

/// Plan/32 — `denied` = the user/SDK declined the tool; `failed` = the tool
/// ran but errored (a distinct, red outcome). `expired` = approval timed out.
enum ToolEventStatus { pending, allowed, denied, expired, completed, failed }

/// Plan/32 — a context-compaction marker rendered as a system bubble
/// (distinct from user/assistant). [summary] is the Pi's recap of the
/// compacted thread; [tokensBefore] is the token count reclaimed (null when
/// the Pi didn't report it).
class CompactionMsg extends ChatMessage {
  final String summary;
  final int? tokensBefore;
  const CompactionMsg({
    required super.id,
    required this.summary,
    this.tokensBefore,
  });

  @override
  bool operator ==(Object other) =>
      other is CompactionMsg &&
      other.id == id &&
      other.summary == summary &&
      other.tokensBefore == tokensBefore;

  @override
  int get hashCode => Object.hash(id, summary, tokensBefore);
}

// ---------------------------------------------------------------------------
// StreamingMessage — accumulated deltas while the assistant is typing
// ---------------------------------------------------------------------------

class StreamingMessage {
  final String inReplyTo; // id of the UserMsg being answered
  final String buffer;

  /// True while the buffer holds model reasoning (a thinking block) rather
  /// than answer text. Thinking blocks and text blocks are sequential within a
  /// turn, so a single live slot suffices — the slot carries the kind.
  final bool thinking;

  /// When this live segment started arriving. Lets the UI tick an elapsed
  /// counter while a reasoning block streams (the row it folds into carries
  /// the final duration). Null for segments nobody times.
  final DateTime? startedAt;

  const StreamingMessage({
    required this.inReplyTo,
    this.buffer = '',
    this.thinking = false,
    this.startedAt,
  });

  StreamingMessage appendDelta(String delta) => StreamingMessage(
    inReplyTo: inReplyTo,
    buffer: buffer + delta,
    thinking: thinking,
    startedAt: startedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is StreamingMessage &&
      other.inReplyTo == inReplyTo &&
      other.buffer == buffer &&
      other.thinking == thinking;

  @override
  int get hashCode => Object.hash(inReplyTo, buffer, thinking);
}
