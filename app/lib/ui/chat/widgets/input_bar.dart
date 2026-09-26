import 'dart:async';

import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/voice/widgets/recording_strip.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// InputBar — bottom message composer.
// - Disabled (grayed) when offline.
// - During streaming, empty composer shows Stop; typed text sends steering.
// - Plan/28 — quick actions (⚙) icon sits to the left of the attach
//   button and is visible only while the field is empty (so it never
//   competes with the send affordance).
// - Plan/29 — when [voice] is provided, the mic becomes hold-to-talk:
//   long-press starts recording (a WhatsApp-style RecordingStrip replaces
//   the row), slide left past the threshold cancels, release transcribes
//   and drops the text into the (empty) field for manual review/send. The
//   recognizer never auto-sends.

/// One-shot UI hint the composer asks the host page to surface (snackbar /
/// settings deep-link). Keeps InputBar free of `BuildContext`-bound effects.
enum VoiceHint {
  /// User tapped the mic instead of holding it.
  holdToTalk,

  /// Mic / speech permission was denied — guide to system Settings (#10).
  permissionDenied,
}

class InputBar extends StatefulWidget {
  final bool disabled; // offline or no peer
  final bool streaming; // show cancel instead of send
  final void Function(String text) onSend;
  final VoidCallback? onCancel;
  final VoidCallback? onOpenQuickActions;
  final VoidCallback? onStartAudio;

  /// Pi-side queued follow-ups. Empty means no queued messages.
  final List<QueuedMsg> queuedMessages;
  final void Function(String text)? onSetQueued;
  final void Function(String id)? onClearQueued;

  /// Plan/29 — voice-input ViewModel. When null the mic falls back to the
  /// legacy [onStartAudio] tap (and existing tests pump InputBar without it).
  final VoiceInputViewModel? voice;

  /// Plan/29 — surfaces a [VoiceHint] to the host page for a snackbar /
  /// settings deep-link.
  final void Function(VoiceHint hint)? onVoiceHint;

  /// Plan/30 — attachment ViewModel (preview state + model vision). Null in
  /// tests / when attachments aren't wired. Holds one image **or** one text
  /// file.
  final AttachmentViewModel? attachment;

  /// Plan/30 — open the Camera/Gallery sheet. Null disables the attach
  /// button (offline/streaming); vision/has-image gating is internal.
  final VoidCallback? onOpenAttach;

  /// Command channel — a `/slash` line was submitted. Null falls back to
  /// [onSend] (so a host that hasn't opted in behaves exactly as before).
  final void Function(String text)? onRunCommand;

  /// Command channel — a `!shell` line was submitted, with the `!` already
  /// stripped. [excludeFromContext] is true for the `!!` form, which mirrors
  /// the desktop: the output is shown, the model doesn't see it.
  final void Function(String command, {bool excludeFromContext})? onRunBash;

  /// Command channel — the `/` palette's catalogue. Empty renders no palette,
  /// so the composer looks unchanged until the Pi answers `commands_list`.
  final List<WireCommand> commands;

  /// Called once each time the `/` palette becomes visible, so the host can
  /// (re)fetch the catalogue lazily — the room may not have been live when the
  /// chat mounted.
  final VoidCallback? onCommandsRequested;

  const InputBar({
    super.key,
    required this.onSend,
    this.onCancel,
    this.onOpenQuickActions,
    this.onStartAudio,
    this.queuedMessages = const [],
    this.onSetQueued,
    this.onClearQueued,
    this.voice,
    this.onVoiceHint,
    this.attachment,
    this.onOpenAttach,
    this.onRunCommand,
    this.onRunBash,
    this.commands = const [],
    this.onCommandsRequested,
    this.disabled = false,
    this.streaming = false,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  /// How far left the press must slide to arm slide-to-cancel (logical px).
  static const double _cancelThreshold = 90;

  final _controller = TextEditingController();
  // Owns the field's focus so we can intercept hardware Enter on its OWN
  // node (the primary/leaf focus). An ancestor Focus runs too late: the
  // FocusManager dispatches leaf→root, so the field's multiline newline
  // handling would consume Enter before an ancestor ever sees it.
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onComposerKey);
  bool _empty = true;
  /// Whether the `/` palette is on screen (mirrors `_commandQuery != null`, kept
  /// as state so the visible/invisible transition drives one fetch).
  bool _paletteVisible = false;
  bool _cancelArmed = false;
  // True while the hold-to-talk gesture is active. Lets `_beginVoice` tell
  // whether the user is still holding once `startRecording` resolves — if not
  // (the permission prompt ended the hold), the recording is discarded.
  bool _holding = false;
  StreamSubscription<String>? _transcriptSub;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChange);
    _subscribeTranscripts();
  }

  @override
  void didUpdateWidget(InputBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.voice, widget.voice)) {
      _transcriptSub?.cancel();
      _subscribeTranscripts();
    }
  }

  void _subscribeTranscripts() {
    _transcriptSub = widget.voice?.transcripts.listen(_onTranscript);
  }

  void _onTranscript(String text) {
    if (!mounted || text.isEmpty) return; // empty → no-op (#12)
    // The field is empty by construction (mic only shows when empty), so we
    // replace rather than concatenate (#non-objetivo: no merge).
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  void _onTextChange() {
    final next = _controller.text.isEmpty;
    final paletteVisible = _commandQuery != null;
    final wasVisible = _paletteVisible;
    // While the palette is hidden nothing on screen depends on the text, so a
    // rebuild only matters when the composer becomes empty (or stops being).
    // While it IS visible every keystroke re-filters it, so rebuild then too.
    if (next == _empty && paletteVisible == wasVisible && !paletteVisible) return;
    setState(() {
      _empty = next;
      _paletteVisible = paletteVisible;
    });
    // Fetch lazily, on each appearance: the room may not have been live when
    // the chat mounted, and the repository answers a repeat call from cache.
    if (paletteVisible && !wasVisible) widget.onCommandsRequested?.call();
  }

  @override
  void dispose() {
    _transcriptSub?.cancel();
    _controller.removeListener(_onTextChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    // Plan/30 — an attached image or file makes an empty-caption send valid.
    final hasAttachment = widget.attachment?.hasAttachment ?? false;
    if (text.isEmpty && !hasAttachment) return;
    // Command channel — `/slash` and `!shell` are intercepted ONLY when the
    // composer carries no attachment: an attachment makes the text a caption,
    // and silently dropping a picked file to run a command would be worse than
    // sending the literal text.
    if (!hasAttachment && text.startsWith('!')) {
      final command = text.replaceFirst(RegExp(r'^!+'), '').trim();
      if (command.isEmpty) return;
      _controller.clear();
      final runBash = widget.onRunBash;
      if (runBash == null) {
        widget.onSend(text);
        return;
      }
      // `!!cmd` mirrors the desktop: shown, but kept out of the model's context.
      runBash(command, excludeFromContext: text.startsWith('!!'));
      return;
    }
    if (!hasAttachment && text.startsWith('/') && text.length > 1) {
      _controller.clear();
      (widget.onRunCommand ?? widget.onSend)(text);
      return;
    }
    _controller.clear();
    widget.onSend(text);
  }

  /// The unfinished `/name` being typed, or null when the palette should stay
  /// out of the way: once an argument follows the name the user knows what they
  /// are doing and the popup would only cover the composer.
  String? get _commandQuery {
    final text = _controller.text;
    if (!text.startsWith('/')) return null;
    if (text.contains(' ') || text.contains('\n')) return null;
    return text.substring(1);
  }

  /// Palette entries matching the typed prefix. Everything known is offered —
  /// including what this room can't run — because "that exists but is desktop
  /// only" is the answer the user needs, not silence.
  List<WireCommand> get _paletteMatches {
    final query = _commandQuery;
    if (query == null) return const [];
    final needle = query.toLowerCase();
    return [
      for (final command in widget.commands)
        if (needle.isEmpty || command.name.toLowerCase().startsWith(needle))
          command,
    ];
  }

  /// Runs a palette entry. Tapping is "do it": the entry's description is the
  /// confirmation, and a command needing arguments is typed instead (the Pi's
  /// own usage error explains what it wants).
  void _runPaletteEntry(WireCommand command) {
    _controller.clear();
    (widget.onRunCommand ?? widget.onSend)('/${command.name}');
  }

  void _editQueued(QueuedMsg item) {
    if (!item.editable) return;
    widget.onClearQueued?.call(item.id);
    _controller.text = item.text;
    _controller.selection = TextSelection.collapsed(offset: item.text.length);
    _focusNode.requestFocus();
  }

  /// Hardware-keyboard behaviour (iPad keyboard case, etc.): plain Enter
  /// SENDS, Shift+Enter inserts a newline. On a touch soft-keyboard the
  /// newline arrives via `performAction` (not a key event), so this never
  /// fires there — the field keeps growing and the user sends with the
  /// composer button, exactly as before.
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    // TEMP diag (input multiline Enter): if this line never prints when you
    // press Enter on the emulator, Android is routing it through the IME and
    // NOT as a hardware key event — remove once the behaviour is confirmed.
    debugPrint(
      '[input.enter] shift=${HardwareKeyboard.instance.isShiftPressed} '
      'disabled=${widget.disabled} streaming=${widget.streaming}',
    );
    // Don't intercept while disabled, or mid-IME-composition (a CJK
    // candidate is confirmed with Enter, not sent) — let the field/IME deal.
    if (widget.disabled || !_controller.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+Enter → newline. Inserted explicitly (and consumed) so the
      // behaviour is identical on every platform instead of depending on
      // the framework's default multiline key handling.
      _insertNewlineAtCursor();
      return KeyEventResult.handled;
    }
    _submit();
    return KeyEventResult.handled;
  }

  /// Replaces the current selection (or inserts at the caret) with a newline
  /// and leaves the caret right after it.
  void _insertNewlineAtCursor() {
    final value = _controller.value;
    final sel = value.selection;
    if (!sel.isValid) {
      final text = '${value.text}\n';
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      return;
    }
    final text = '${sel.textBefore(value.text)}\n${sel.textAfter(value.text)}';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  // --- voice gesture ---------------------------------------------------------

  void _onVoiceStart() {
    _holding = true;
    if (_cancelArmed) setState(() => _cancelArmed = false);
    unawaited(_beginVoice());
  }

  Future<void> _beginVoice() async {
    final voice = widget.voice;
    if (voice == null) return;
    await voice.startRecording();
    if (!mounted) return;
    // Bug fix: on first use the OS permission prompt steals the hold — the
    // finger lifts to tap "Allow", so the press ends BEFORE recording actually
    // begins (state isn't VoiceRecording yet, so the release no-ops). When
    // `startRecording` then resolves and starts, the composer was left stuck
    // "recording" with no finger down. If the gesture is already over by the
    // time we get here, discard that phantom recording.
    if (!_holding && voice.state is VoiceRecording) {
      await voice.cancel();
      if (!mounted) return;
    }
    final s = voice.state;
    if (s is VoiceUnavailable &&
        s.reason == VoiceUnavailableReason.permissionDenied) {
      widget.onVoiceHint?.call(VoiceHint.permissionDenied);
    }
  }

  void _onVoiceMove(LongPressMoveUpdateDetails details) {
    if (widget.voice?.state is! VoiceRecording) return;
    final armed = details.offsetFromOrigin.dx < -_cancelThreshold;
    if (armed != _cancelArmed) setState(() => _cancelArmed = armed);
  }

  void _onVoiceEnd() {
    _holding = false;
    final voice = widget.voice;
    final armed = _cancelArmed;
    if (_cancelArmed) setState(() => _cancelArmed = false);
    if (voice == null || voice.state is! VoiceRecording) return;
    if (armed) {
      unawaited(voice.cancel());
    } else {
      // Transcript arrives via voice.transcripts → _onTranscript, the same
      // path the 60s cap uses — release never populates the field directly.
      unawaited(voice.stopAndTranscribe());
    }
  }

  void _onVoiceTap() => widget.onVoiceHint?.call(VoiceHint.holdToTalk);

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      if (widget.voice != null) widget.voice!,
      if (widget.attachment != null) widget.attachment!,
    ];
    if (listenables.isEmpty) return _composer(context);
    // Rebuild on every voice/attachment emit (tick / level / availability /
    // pick) so the strip + preview animate even when no ancestor watches them.
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) => _composer(context),
    );
  }

  Widget _composer(BuildContext context) {
    final colors = context.colors;
    final voiceState = widget.voice?.state;
    final attachState = widget.attachment?.state;
    final canInteract = !widget.disabled;
    final hasQuickActions = widget.onOpenQuickActions != null;
    final recording = voiceState is VoiceRecording;
    final transcribing = voiceState is VoiceTranscribing;
    final showStrip = recording || transcribing;
    final voiceUnsupported =
        voiceState is VoiceUnavailable &&
        voiceState.reason == VoiceUnavailableReason.unsupported;

    // Plan/30 — attachment (one image or one text file).
    final attached = attachState is AttachmentAttached;
    final hasImage = attachState is AttachmentAttached && attachState.image != null;
    final attachedFile = attachState is AttachmentAttached ? attachState.file : null;
    final fileTruncated = attachedFile?.truncated ?? false;
    final hasContent = !_empty || attached;
    // Vision never gates the attach button itself: the sheet keeps the file
    // option live and greys out camera/gallery instead.
    final attachEnabled =
        widget.onOpenAttach != null &&
        canInteract &&
        !widget.streaming &&
        !showStrip &&
        !attached;

    // Stay reachable for the whole turn, including while the agent is
    // working. Nothing in the sheet is blocked by an in-flight turn —
    // compact / new session / model / thinking all queue on the relay, and
    // the per-room "Hide tool calls" switch is a purely local preference.
    // Hiding the entry point mid-turn used to strand exactly that switch:
    // the moment you wanted to hide the tool rows being streamed at you was
    // the moment the button vanished.
    final showQuickActions =
        _empty &&
        !attached &&
        canInteract &&
        !showStrip &&
        hasQuickActions;

    // During a working turn with typed content, the main action sends steering;
    // keep a compact Stop affordance beside it so cancellation remains reachable.
    final showInlineStop =
        widget.streaming &&
        hasContent &&
        canInteract &&
        !showStrip &&
        widget.onCancel != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasImage)
                _AttachmentPreview(
                  image: attachState.image!,
                  onRemove: widget.attachment!.removeAttachment,
                ),
              if (attachedFile != null)
                _FileAttachmentPreview(
                  file: attachedFile,
                  truncated: fileTruncated,
                  onRemove: widget.attachment!.removeAttachment,
                ),
              for (final item in widget.queuedMessages)
                _QueuedMessagePreview(
                  text: item.text,
                  editable: item.editable,
                  onTap: item.editable ? () => _editQueued(item) : null,
                  onClear: item.editable
                      ? () => widget.onClearQueued?.call(item.id)
                      : null,
                ),
              _CommandPalette(
                entries: _paletteMatches,
                onRun: _runPaletteEntry,
              ),
              Row(
                children: [
                  _QuickActionsButton(
                    show: showQuickActions,
                    onPressed: widget.onOpenQuickActions,
                  ),
                  _AttachButton(
                    enabled: attachEnabled,
                    onTap: widget.onOpenAttach,
                  ),
                  const SizedBox(width: 10),
                  // Text field (doubles as the image caption when one is set).
                  Expanded(
                    child: TextField(
                      // Intercept hardware Enter on the field's OWN focus
                      // node (the primary/leaf): plain Enter sends,
                      // Shift+Enter newlines — see _onComposerKey. Must be
                      // the leaf, not an ancestor Focus, or the multiline
                      // newline handling consumes Enter first.
                      focusNode: _focusNode,
                      controller: _controller,
                      enabled: canInteract,
                      // Grow with the content: starts at one line, expands up
                      // to 6 then scrolls internally. On a touch soft-keyboard
                      // Enter inserts a newline; sending is via the composer
                      // button (hardware Enter sends — see _onComposerKey).
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 13,
                        color: colors.text,
                      ),
                      cursorColor: colors.accent,
                      decoration: InputDecoration(
                        hintText: widget.disabled
                            ? 'Offline…'
                            : widget.streaming
                            ? 'Steer current response…'
                            : attached
                            ? 'Add a caption…'
                            : 'Send a message…',
                        hintStyle: TextStyle(
                          color: colors.muted,
                          fontFamily: kMonoFamily,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        filled: true,
                        fillColor: colors.inputFill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(color: colors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(color: colors.border),
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(
                            color: colors.border.withValues(alpha: 0.5),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(
                            color: colors.accent,
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _ComposerActionButton(
                    streaming: widget.streaming,
                    hasContent: hasContent,
                    disabled: widget.disabled,
                    onSendText: _submit,
                    onCancel: widget.onCancel,
                    onStartAudio: widget.onStartAudio,
                    voiceEnabled: widget.voice != null,
                    voiceUnsupported: voiceUnsupported,
                    onVoiceLongPressStart: _onVoiceStart,
                    onVoiceLongPressMoveUpdate: _onVoiceMove,
                    onVoiceLongPressEnd: _onVoiceEnd,
                    onVoiceTap: _onVoiceTap,
                  ),
                  if (showInlineStop) ...[
                    const SizedBox(width: 8),
                    _InlineStopButton(onTap: widget.onCancel!),
                  ],
                ],
              ),
            ],
          ),
          // Recording strip — overlays the row (decision #11) while the mic's
          // GestureDetector stays mounted underneath so the same long-press
          // keeps feeding move/end events across the swap. IgnorePointer so
          // the overlay never steals the in-flight gesture.
          if (showStrip)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: colors.bg,
                  child: Center(
                    child: recording
                        ? RecordingStrip(
                            level: voiceState.level,
                            elapsed: voiceState.elapsed,
                            maxDuration:
                                widget.voice?.maxDuration ??
                                const Duration(seconds: 60),
                            cancelArmed: _cancelArmed,
                          )
                        : const _TranscribingStrip(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows the message committed for auto-send after the current turn ends.
/// Tapping pulls it back into the composer for edit and cancels the pending
/// auto-send; X drops it.
class _QueuedMessagePreview extends StatelessWidget {
  const _QueuedMessagePreview({
    required this.text,
    required this.editable,
    this.onTap,
    this.onClear,
  });

  final String text;
  final bool editable;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('input-bar-queued-preview'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    LucideIcons.messageCircle,
                    size: 15,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        editable ? 'Queued. Tap to edit.' : 'Queued follow-up.',
                        style: TextStyle(
                          color: colors.accent,
                          fontFamily: kMonoFamily,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontFamily: kMonoFamily,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onClear != null) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      key: const Key('input-bar-clear-queued'),
                      tooltip: 'Clear queued message',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      splashRadius: 16,
                      onPressed: onClear,
                      icon: Icon(LucideIcons.x, color: colors.muted2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact Stop affordance shown beside Send while steering text is typed.
/// Command channel — the `/` palette. A scrollable list above the composer,
/// filtered by the name being typed. Entries this room cannot run stay visible
/// (greyed, with the reason) so "why doesn't /login work here?" is answered on
/// screen instead of by a failed round-trip.
class _CommandPalette extends StatelessWidget {
  /// Tall enough for ~4 rows; beyond that it scrolls, so the palette never
  /// pushes the composer off a phone screen.
  static const double maxHeight = 184;

  final List<WireCommand> entries;
  final void Function(WireCommand command) onRun;

  const _CommandPalette({required this.entries, required this.onRun});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
      constraints: const BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: entries.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 1,
          color: colors.border.withValues(alpha: 0.5),
        ),
        itemBuilder: (context, index) {
          final command = entries[index];
          final unavailable = _unavailableReason(command);
          final enabled = unavailable == null;
          final nameColor = enabled ? colors.text : colors.muted2;
          return InkWell(
            key: Key('command-palette-${command.name}'),
            onTap: enabled ? () => onRun(command) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '/${command.name}',
                    style: TextStyle(
                      color: nameColor,
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (command.description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      command.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.muted2,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                  if (!enabled) ...[
                    const SizedBox(height: 2),
                    Text(
                      unavailable,
                      style: TextStyle(
                        color: colors.muted2,
                        fontFamily: kMonoFamily,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Why an entry can't run from this room, or null when it can. Mirrors the
  /// Pi's own `scope`/`supported` classification — the app never guesses.
  static String? _unavailableReason(WireCommand command) {
    if (command.supported) return null;
    return switch (command.scope) {
      CommandScope.tui => 'Pi TUI only',
      CommandScope.daemon => 'needs a daemon room',
      _ => 'unavailable here',
    };
  }
}

class _InlineStopButton extends StatelessWidget {
  const _InlineStopButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      key: const Key('input-bar-inline-stop'),
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: colors.error.withValues(alpha: 0.55)),
        ),
        child: Icon(LucideIcons.square600, color: colors.error, size: 18),
      ),
    );
  }
}

/// Plan/30 — the attach (paperclip) button. Always visible; greyed + inert
/// when [enabled] is false (offline/streaming, a text-only model #9, or an
/// image is already attached).
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: const Key('input-bar-attach'),
        padding: EdgeInsets.zero,
        iconSize: 18,
        splashRadius: 18,
        tooltip: 'Attach image',
        icon: Icon(
          LucideIcons.paperclip,
          color: enabled
              ? context.colors.muted2
              : context.colors.muted.withValues(alpha: 0.35),
        ),
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

/// The composer file preview: name, size, and an "X" to discard before
/// sending. Sits in the same slot as the image thumbnail — one attachment per
/// message.
class _FileAttachmentPreview extends StatelessWidget {
  const _FileAttachmentPreview({
    required this.file,
    required this.truncated,
    required this.onRemove,
  });

  final PickedTextFile file;
  final bool truncated;
  final VoidCallback onRemove;

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      key: const Key('attach-file-preview'),
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.fileText, size: 16, color: colors.accent),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                file.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 12,
                  color: colors.text,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              truncated
                  ? '${_size(file.byteLength)} · cut at limit'
                  : _size(file.byteLength),
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 11,
                color: colors.muted,
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              key: const Key('attach-remove'),
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(LucideIcons.x, size: 14, color: colors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plan/30 — the composer image preview: a rounded thumbnail with an "X" to
/// discard before sending (decision #4).
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.image, required this.onRemove});

  final PickedImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('attach-preview'),
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: SizedBox(
        width: 84,
        height: 84,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                image.bytes,
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
            Positioned(
              top: -4,
              right: 8,
              child: GestureDetector(
                key: const Key('attach-remove'),
                onTap: onRemove,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    shape: BoxShape.circle,
                    border: Border.all(color: context.colors.border),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    LucideIcons.x,
                    size: 13,
                    color: context.colors.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranscribingStrip extends StatelessWidget {
  const _TranscribingStrip();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      key: const Key('transcribing-strip'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.accent,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'transcribing…',
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 12,
            color: colors.muted2,
          ),
        ),
      ],
    );
  }
}

class _QuickActionsButton extends StatefulWidget {
  const _QuickActionsButton({required this.show, required this.onPressed});

  final bool show;
  final VoidCallback? onPressed;

  @override
  State<_QuickActionsButton> createState() => _QuickActionsButtonState();
}

class _QuickActionsButtonState extends State<_QuickActionsButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeFactor;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: widget.show ? 1.0 : 0.0,
    );
    // Timeline (forward = appear): first grow [0.0–0.5], then fade in [0.5–1.0].
    // On reverse (disappear) the order flips → fade out first, then shrink.
    _sizeFactor = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeInOut),
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(covariant _QuickActionsButton old) {
    super.didUpdateWidget(old);
    if (widget.show == old.show) return;
    if (widget.show) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _sizeFactor,
      axis: Axis.horizontal,
      // -1.0 = start (centerLeft) — `alignment:` only exists on Flutter
      // ≥3.44 and breaks the 3.41 CI toolchain; drop the ignore once CI
      // moves to ≥3.44.
      // ignore: deprecated_member_use
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: _fade,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                key: const Key('input-bar-quick-actions'),
                padding: EdgeInsets.zero,
                iconSize: 18,
                splashRadius: 18,
                tooltip: 'Quick actions',
                icon: Icon(
                  LucideIcons.slidersHorizontal,
                  color: context.colors.muted,
                ),
                onPressed: widget.onPressed,
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

enum _ComposerMode { sendAudio, sendText, cancel }

class _ComposerActionButton extends StatelessWidget {
  const _ComposerActionButton({
    required this.streaming,
    required this.hasContent,
    required this.disabled,
    required this.onSendText,
    required this.onCancel,
    required this.onStartAudio,
    required this.voiceEnabled,
    required this.voiceUnsupported,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressMoveUpdate,
    required this.onVoiceLongPressEnd,
    required this.onVoiceTap,
  });

  final bool streaming;

  /// Text typed OR an image attached → the button is "send" (decision #6).
  final bool hasContent;
  final bool disabled;
  final VoidCallback onSendText;
  final VoidCallback? onCancel;
  final VoidCallback? onStartAudio;

  // Plan/29 voice wiring.
  final bool voiceEnabled;
  final bool voiceUnsupported;
  final VoidCallback onVoiceLongPressStart;
  final void Function(LongPressMoveUpdateDetails) onVoiceLongPressMoveUpdate;
  final VoidCallback onVoiceLongPressEnd;
  final VoidCallback onVoiceTap;

  _ComposerMode get _mode {
    if (streaming && !hasContent) return _ComposerMode.cancel;
    if (hasContent) return _ComposerMode.sendText;
    return _ComposerMode.sendAudio;
  }

  IconData get _icon {
    switch (_mode) {
      case _ComposerMode.cancel:
        return LucideIcons.square600;
      case _ComposerMode.sendText:
        return LucideIcons.send600;
      case _ComposerMode.sendAudio:
        return LucideIcons.mic600;
    }
  }

  VoidCallback? _resolveTap() {
    switch (_mode) {
      case _ComposerMode.cancel:
        return onCancel;
      case _ComposerMode.sendText:
        return disabled ? null : onSendText;
      case _ComposerMode.sendAudio:
        return disabled ? null : onStartAudio;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Decision #9 edge — no on-device recognition anywhere: hide the mic so
    // the empty field shows just the attach placeholder (dictate via keyboard).
    if (_mode == _ComposerMode.sendAudio && voiceUnsupported) {
      return const SizedBox.shrink();
    }

    // Hold-to-talk mic (decision #4): long-press records, slide cancels,
    // release transcribes. A plain tap surfaces the "hold to talk" hint.
    if (_mode == _ComposerMode.sendAudio && voiceEnabled) {
      return GestureDetector(
        onTap: disabled ? null : onVoiceTap,
        onLongPressStart: disabled ? null : (_) => onVoiceLongPressStart(),
        onLongPressMoveUpdate: disabled ? null : onVoiceLongPressMoveUpdate,
        onLongPressEnd: disabled ? null : (_) => onVoiceLongPressEnd(),
        child: _button(context),
      );
    }

    return GestureDetector(
      key: const Key('input-bar-action'),
      onTap: _resolveTap(),
      child: _button(context),
    );
  }

  Widget _button(BuildContext context) {
    final colors = context.colors;
    final visualEnabled = !disabled;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: visualEnabled
            ? colors.accent
            : colors.muted.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(19),
        boxShadow: visualEnabled
            ? [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.33),
                  blurRadius: 16,
                ),
              ]
            : null,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(scale: anim, child: child),
        ),
        child: Icon(
          _icon,
          key: ValueKey(_mode),
          color: visualEnabled ? colors.onAccent : colors.muted,
          size: 20,
        ),
      ),
    );
  }
}
