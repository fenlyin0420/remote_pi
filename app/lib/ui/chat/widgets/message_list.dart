import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:flutter/material.dart';

/// The chat transcript. Owns the one piece of state the transcript cannot
/// derive: where the user is reading.
///
/// The list is deliberately NOT `reverse: true`. A reversed list anchors the
/// viewport to the newest message for free — but it is laid out *from* the
/// bottom, so inserting a message (or just letting the streaming bubble grow)
/// pushes every other row up by that much, and a viewport pinned to the bottom
/// edge drifts toward the newest message while the user is reading history. The
/// compensation for that is unreliable, because a lazy reversed sliver only
/// *estimates* how much the content grew (measured: ~27px of reported growth for
/// a real ~33px row, i.e. 5px of visible drift per message).
///
/// A normal list has the opposite property: rows are laid out from the top, so
/// appending at the newest end cannot move the rows above it — anchoring while
/// reading history is exact, for free. The bottom is then followed explicitly:
/// the controller opens at the bottom and re-jumps there after layout, but only
/// while the user is at the bottom ([_followSlop]); once they scroll up, we stay
/// out of the way entirely.
class MessageList extends StatefulWidget {
  const MessageList({
    super.key,
    required this.messages,
    required this.streaming,
    required this.onDecide,
  });

  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final void Function(String, ApproveDecision) onDecide;

  @override
  State<MessageList> createState() => MessageListState();
}

@visibleForTesting
class MessageListState extends State<MessageList> {
  /// Distance from the bottom still counted as "at the bottom" — a finger's
  /// width of slop so the auto-follow doesn't stop on a stray pixel.
  static const double _followSlop = 48;

  @visibleForTesting
  final ScrollController controller = ScrollController();

  /// True while the viewport follows new content. False as soon as the user
  /// scrolls away from the bottom, true again when they come back.
  bool _following = true;

  /// The transcript stays invisible until the first layout has jumped to the
  /// newest message: the list is laid out from the top, so a long chat would
  /// otherwise paint its OLDEST rows for one frame on open.
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A message the USER just sent is theirs to watch: follow it even if they
    // had scrolled up. Incoming content never moves the viewport (see
    // [_followBottom]).
    final last = widget.messages.isEmpty ? null : widget.messages.last;
    final previous = oldWidget.messages.isEmpty
        ? null
        : oldWidget.messages.last;
    if (last is UserMsg &&
        last.status == UserMsgStatus.pending &&
        last.id != previous?.id) {
      _following = true;
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onScroll);
    controller.dispose();
    super.dispose();
  }

  double get _distanceFromBottom {
    final position = controller.position;
    return (position.maxScrollExtent - position.pixels).clamp(
      0.0,
      double.infinity,
    );
  }

  void _onScroll() {
    if (!controller.hasClients) return;
    _following = _distanceFromBottom <= _followSlop;
  }

  void _afterFrame(void Function() action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  /// Runs after every layout: place the viewport on the first one, then keep it
  /// on the newest content — but only while the user is already there.
  void _afterLayout() {
    if (!_ready) {
      if (controller.hasClients) {
        final position = controller.position;
        if (position.maxScrollExtent > 0) {
          controller.jumpTo(position.maxScrollExtent);
        }
      }
      setState(() => _ready = true);
      return;
    }
    if (!controller.hasClients) return;
    _followBottom();
  }

  /// Stick to the newest content. No-op while the user reads history.
  void _followBottom() {
    if (!_following) return;
    final position = controller.position;
    if (position.pixels < position.maxScrollExtent) {
      controller.jumpTo(position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final streaming = widget.streaming;

    // Extents are only final after layout, so following runs then. While the
    // user reads history [_afterLayout] is a no-op.
    _afterFrame(_afterLayout);

    return Opacity(
      opacity: _ready ? 1 : 0,
      child: ListView.separated(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
        itemCount: messages.length + (streaming != null ? 1 : 0),
        separatorBuilder: (context, idx) => const SizedBox(height: 14),
        itemBuilder: (_, i) {
          // Stable keys are REQUIRED here: when the streaming bubble
          // appears/disappears at the end every other item's index shifts by 1,
          // and without keys Flutter re-matches elements by position — briefly
          // painting the wrong message at a slot (the momentary C/B/A → B/C/A
          // reorder). Keying by message id makes it match by identity instead.
          if (streaming != null && i == messages.length) {
            return KeyedSubtree(
              key: const ValueKey('streaming'),
              child: StreamingBubble(streaming),
            );
          }
          final msg = messages[i];
          return KeyedSubtree(
            key: ValueKey(msg.id),
            child: switch (msg) {
              UserMsg() => UserBubble(msg),
              AssistantMsg() => AssistantBubble(msg),
              ThinkingMsg() => ThinkingBubble(msg),
              ToolEvent() => ToolRequestCard(
                tool: msg,
                onDecide: widget.onDecide,
              ),
              CompactionMsg() => CompactionBubble(msg),
            },
          );
        },
      ),
    );
  }
}
