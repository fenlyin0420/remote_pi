import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/screenshots/long_screenshot_adapter.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/attachment_card.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
/// out of the way entirely — and float a "jump to latest" arrow over the bottom
/// of the list that brings them back in one tap.
class MessageList extends StatefulWidget {
  const MessageList({
    super.key,
    required this.messages,
    required this.streaming,
    required this.onDecide,
    required this.loadAttachmentBytes,
    required this.onLoadAttachment,
    required this.onSaveAttachment,
  });

  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final void Function(String, ApproveDecision) onDecide;

  /// Reads a cached attachment blob (null when the card has none yet).
  final Future<Uint8List?> Function(String blobName) loadAttachmentBytes;

  /// Asks the Pi for the bytes behind an attachment card that has none.
  final Future<void> Function(String attachmentId, String path) onLoadAttachment;

  /// Copies an attachment into the phone's own storage; returns where it went.
  final Future<String> Function(AttachmentMsg msg) onSaveAttachment;

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

  /// True while the user's finger owns the list. The auto-follow stays out of
  /// the way for the WHOLE gesture: [ScrollController.jumpTo] ends the drag
  /// activity, so a follow that fires mid-drag silently kills it.
  bool _userDragging = false;

  /// True while the viewport follows new content. False as soon as the user
  /// scrolls away from the bottom, true again when they come back.
  bool _following = true;

  /// Drives the floating "jump to latest" arrow: set true the moment the
  /// viewport is more than [_followSlop] away from the newest content. A
  /// notifier rather than a setState so the arrow can appear and disappear
  /// without rebuilding the transcript on every scroll event.
  final ValueNotifier<bool> _showJump = ValueNotifier<bool>(false);

  /// True while [jumpToBottom] is flying the viewport back down. The scroll
  /// listener stays out of the way for the whole flight: a mid-flight offset
  /// is far from the bottom, and re-reading it would disarm the follow and
  /// re-arm the arrow the tap just hid.
  bool _animatingToBottom = false;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The ROM's long-screenshot drives the transcript through the native
    // control view: track this list so the system knows where to scroll and
    // when to stop (see LongScreenshotAdapter).
    LongScreenshotAdapter.instance.attachForRoute(controller, context);
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
    LongScreenshotAdapter.instance.detach(controller);
    controller.removeListener(_onScroll);
    controller.dispose();
    _showJump.dispose();
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
    final distance = _distanceFromBottom;
    // The arrow's visibility is pure geometry, so it updates on every scroll —
    // including a live drag, where the follow state itself stays put.
    if (!_animatingToBottom) {
      _showJump.value = distance > _followSlop;
    }
    // A finger on the list owns the viewport: never re-arm the follow from a
    // mid-gesture offset. Otherwise the first few pixels of a slow drag — still
    // within [_followSlop] — re-enable it, and the post-frame jump yanks the
    // list back to the bottom, killing the drag. That is what made scrolling up
    // while a reply streams need a violent flick instead of a plain drag.
    if (_userDragging || _animatingToBottom) return;
    _following = distance <= _followSlop;
  }

  /// Follow yields the moment a finger starts moving the list, and resumes only
  /// once the gesture settles back at the bottom.
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      if (n.dragDetails != null) {
        _userDragging = true;
        _following = false;
      }
    } else if (n is ScrollEndNotification) {
      _userDragging = false;
      _onScroll();
    }
    return false;
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
    // The ROM long-screenshot overlay tracks this list's range and
    // position; content can grow while the pixels do not (streaming while
    // the user reads history), which only a per-layout check catches.
    LongScreenshotAdapter.instance.resync();
    if (!_animatingToBottom) {
      // Mid-flight a rebuild must not jumpTo: it ends the animation activity
      // and collapses the 320 ms flight into a snap — exactly what happens
      // when a reply streams while the arrow's flight is in the air.
      _followBottom();
      _showJump.value = _distanceFromBottom > _followSlop;
    }
  }

  /// Stick to the newest content. No-op while the user reads history.
  void _followBottom() {
    if (!_following) return;
    final position = controller.position;
    if (position.pixels < position.maxScrollExtent) {
      controller.jumpTo(position.maxScrollExtent);
    }
  }

  /// One tap: fly the viewport back to the newest content and re-arm the
  /// follow, so the reply that is already streaming lands right at the eye.
  void jumpToBottom() {
    if (!controller.hasClients || _animatingToBottom) return;
    final position = controller.position;
    _following = true;
    _animatingToBottom = true;
    _showJump.value = false;
    unawaited(
      position
          .animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted) return;
            _animatingToBottom = false;
            // Content may have grown during the flight: absorb it (the follow
            // is armed), then settle the arrow on the final offset.
            _followBottom();
            _onScroll();
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final streaming = widget.streaming;

    // An image a TOOL produced (a screenshot, a diagram it read) belongs inside
    // that tool's row — the same place the TUI draws it. So the attachment rows
    // are folded into their tool row and the timeline keeps one box per call.
    // An attachment whose tool row is not in this slice of history (trimmed,
    // or a `file_get` answering for a card the app has not replayed) keeps its
    // own card: never lose a picture because its row is missing.
    final toolCalls = <String>{
      for (final m in messages)
        if (m is ToolEvent) m.toolCallId,
    };
    final nestedByToolCall = <String, List<AttachmentMsg>>{};
    final rows = <ChatMessage>[];
    for (final m in messages) {
      final toolCallId = m is AttachmentMsg ? m.toolCallId : null;
      if (toolCallId != null && toolCalls.contains(toolCallId)) {
        (nestedByToolCall[toolCallId] ??= []).add(m as AttachmentMsg);
        continue;
      }
      rows.add(m);
    }

    // Extents are only final after layout, so following runs then. While the
    // user reads history [_afterLayout] is a no-op.
    _afterFrame(_afterLayout);

    return Opacity(
      opacity: _ready ? 1 : 0,
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ListView.separated(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
              itemCount: rows.length + (streaming != null ? 1 : 0),
              separatorBuilder: (context, idx) => const SizedBox(height: 14),
              itemBuilder: (_, i) {
                // Stable keys are REQUIRED here: when the streaming bubble
                // appears/disappears at the end every other item's index shifts by 1,
                // and without keys Flutter re-matches elements by position — briefly
                // painting the wrong message at a slot (the momentary C/B/A → B/C/A
                // reorder). Keying by message id makes it match by identity instead.
                if (streaming != null && i == rows.length) {
                  return KeyedSubtree(
                    key: const ValueKey('streaming'),
                    child: StreamingBubble(streaming),
                  );
                }
                final msg = rows[i];
                return KeyedSubtree(
                  key: ValueKey(msg.id),
                  child: switch (msg) {
                    UserMsg() => UserBubble(msg),
                    AssistantMsg() => AssistantBubble(msg),
                    ThinkingMsg() => ThinkingBubble(msg),
                    ToolEvent() => ToolRequestCard(
                      tool: msg,
                      onDecide: widget.onDecide,
                      attachments: nestedByToolCall[msg.toolCallId] ?? const [],
                      loadAttachmentBytes: widget.loadAttachmentBytes,
                      onLoadAttachment: widget.onLoadAttachment,
                      onSaveAttachment: widget.onSaveAttachment,
                    ),
                    CompactionMsg() => CompactionBubble(msg),
                    AttachmentMsg() => AttachmentCard(
                      message: msg,
                      loadBytes: widget.loadAttachmentBytes,
                      onLoad: widget.onLoadAttachment,
                      onSave: widget.onSaveAttachment,
                    ),
                  },
                );
              },
            ),
          ),
          // The "jump to latest" arrow. An overlay, never a layout row —
          // appearing or vanishing cannot reflow the messages — floating
          // over the bottom of the transcript, above the composer.
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: ValueListenableBuilder<bool>(
              valueListenable: _showJump,
              builder: (context, show, _) {
                if (!show) return const SizedBox.shrink();
                final colors = context.colors;
                return Center(
                  child: Tooltip(
                    message: 'Latest messages',
                    child: Material(
                      key: const ValueKey('jump-to-latest'),
                      color: colors.surface,
                      shape: const CircleBorder(),
                      elevation: 4,
                      shadowColor: Colors.black.withValues(alpha: 0.25),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: jumpToBottom,
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            LucideIcons.arrowDown,
                            size: 18,
                            color: colors.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
