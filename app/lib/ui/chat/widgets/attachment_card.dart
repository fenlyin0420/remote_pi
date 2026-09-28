import 'package:app/data/attachments/attachment_store.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A file the Pi sent to the phone, rendered where the tool ran.
///
/// Left-aligned and full-width, like the assistant's own output (a tool card),
/// NOT the right-aligned user bubble: this is something the agent produced.
///
/// Three states, all in this one widget:
///   * image + bytes  → inline thumbnail (same 220 px ceiling as [ImageBubble]);
///   * text + bytes   → name/size header + a scrollable monospace preview;
///   * no bytes yet   → a "tap to load" affordance. A card rebuilt from
///     `session_history` arrives as metadata only, and re-pulling is the user's
///     tap — opening an old room must not download every file ever sent.
class AttachmentCard extends StatefulWidget {
  const AttachmentCard({
    super.key,
    required this.message,
    required this.loadBytes,
    required this.onLoad,
  });

  final AttachmentMsg message;

  /// Reads the locally cached bytes (null when there is nothing cached).
  final Future<Uint8List?> Function(String blobName) loadBytes;

  /// Asks the Pi for the bytes. Called when the user taps a card that has none.
  final Future<void> Function(String attachmentId, String path) onLoad;

  /// Cap the thumbnail height; the card itself spans the list's content width.
  static const double maxImageHeight = 220;

  /// How much of a text file the preview shows before it is cut.
  static const int previewChars = 4000;

  @override
  State<AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<AttachmentCard> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _expanded = false;
  String? _loadedBlob;

  @override
  void initState() {
    super.initState();
    _readBlob();
  }

  @override
  void didUpdateWidget(AttachmentCard old) {
    super.didUpdateWidget(old);
    if (old.message.blobName != widget.message.blobName) _readBlob();
  }

  Future<void> _readBlob() async {
    final blob = widget.message.blobName;
    if (blob == null || blob == _loadedBlob) return;
    _loadedBlob = blob;
    final bytes = await widget.loadBytes(blob);
    if (!mounted || bytes == null) return;
    setState(() => _bytes = bytes);
  }

  Future<void> _request() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await widget.onLoad(widget.message.id, widget.message.path);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final msg = widget.message;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(context),
          if (msg.error != null)
            _errorLine(context, msg.error!)
          else if (msg.isImage)
            _image(context)
          else if (_bytes != null)
            _textPreview(context)
          else
            _placeholder(context),
          if (msg.note != null && msg.note!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Text(
                msg.note!.trim(),
                style: context.typo.sansBody.copyWith(color: colors.muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final colors = context.colors;
    final msg = widget.message;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
      child: Row(
        children: [
          Icon(
            msg.isImage ? LucideIcons.image : LucideIcons.fileText,
            size: 14,
            color: colors.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  msg.name,
                  key: const Key('attachment-name'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 12,
                    color: colors.text,
                  ),
                ),
                Text(
                  _subtitle(msg),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 10,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('attachment-copy-path'),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: Icon(LucideIcons.copy, size: 13, color: colors.muted),
            tooltip: 'Copy path',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: msg.path));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(content: Text('Path copied')),
              );
            },
          ),
        ],
      ),
    );
  }

  /// `image/png · 180 KB` plus what the phone lost to the size cap, so a
  /// downscaled screenshot is never mistaken for the original export.
  String _subtitle(AttachmentMsg msg) {
    final parts = <String>[
      msg.mime,
      _humanSize(msg.size),
      if (msg.resized && msg.originalSize != null)
        'from ${_humanSize(msg.originalSize!)}',
    ];
    return parts.join(' · ');
  }

  Widget _image(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return _placeholder(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: AttachmentCard.maxImageHeight),
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _brokenImage(context),
      ),
    );
  }

  Widget _textPreview(BuildContext context) {
    final colors = context.colors;
    final text = AttachmentStore.textPreview(
      _bytes!,
      maxChars: AttachmentCard.previewChars,
    );
    if (text == null || text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Text(
          '(no readable text)',
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 11,
            color: colors.muted,
          ),
        ),
      );
    }
    final cut = text.length >= AttachmentCard.previewChars;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: GptMarkdown(
                text,
                style: context.typo.mono,
                // Prose/code highlighting would fight the mono card; the raw
                // text is what a file preview is for.
                highlightBuilder: (context, text, style) =>
                    Text(text, style: style),
              ),
            ),
          ),
          if (cut)
            GestureDetector(
              key: const Key('attachment-expand'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _expanded ? 'show less' : 'show all',
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 11,
                    color: colors.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      key: const Key('attachment-load'),
      onTap: _request,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(
          children: [
            if (_loading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  color: colors.muted,
                  strokeWidth: 1.2,
                ),
              )
            else
              Icon(LucideIcons.download, size: 14, color: colors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _loading ? 'loading…' : 'tap to load from the Pi',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 11,
                  color: colors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorLine(BuildContext context, String error) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.circleAlert, size: 13, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              key: const Key('attachment-error'),
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 11,
                color: colors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _brokenImage(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 110,
      color: colors.codeBg,
      alignment: Alignment.center,
      child: Icon(LucideIcons.imageOff, color: colors.muted, size: 24),
    );
  }
}

String _humanSize(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
