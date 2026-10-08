import 'package:app/data/attachments/attachment_store.dart';
import 'package:app/domain/contracts/media_saver.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/ui/chat/widgets/attachment_viewer.dart';
import 'package:app/ui/chat/widgets/image_frame.dart';
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
///   * image + blob   → the same box, held open while the bytes are read from
///     disk, so the row never changes height under a scrolling finger;
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
    required this.onSave,
    this.embedded = false,
  });

  final AttachmentMsg message;

  /// Render the content alone, without this card's own frame and file header:
  /// used when the picture belongs INSIDE another box — a tool row whose own
  /// result produced the image (the tool header already names it, and a box in
  /// a box reads as a second, unrelated file).
  final bool embedded;

  /// Reads the locally cached bytes (null when there is nothing cached).
  final Future<Uint8List?> Function(String blobName) loadBytes;

  /// Asks the Pi for the bytes. Called when the user taps a card that has none.
  final Future<void> Function(String attachmentId, String path) onLoad;

  /// Copies the file into the phone's own storage; returns where it went.
  final Future<String> Function(AttachmentMsg msg) onSave;

  /// Cap the thumbnail height; the card itself spans the list's content width.
  static const double maxImageHeight = 220;

  /// The inline slice. A nested scroll view inside the chat list is worse than
  /// useless (it fights the list's own scroll), so the card shows a screenful
  /// and the viewer takes over from there.
  static const int previewChars = 700;

  /// How much of a text file the inline card decodes before deciding to offer
  /// "show all" — cheap enough to do on every build of the card.
  static const int previewScanChars = 200000;

  @override
  State<AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<AttachmentCard> {
  Uint8List? _bytes;
  bool _loading = false;
  String? _loadedBlob;

  /// True while [_readBlob] is waiting on the disk for [_loadedBlob]. Keeps an
  /// image card's media area open (see [_image]) instead of collapsing to the
  /// "tap to load" row and growing again a frame later.
  bool _reading = false;

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
    _reading = true;
    final bytes = await widget.loadBytes(blob);
    // The header is all the layout needs, and remembering it here means the
    // box is exact on this card's *first* frame and on every later scroll past
    // it (the card's own state does not survive leaving the viewport).
    final size = bytes == null ? null : probeImageSize(bytes);
    ImageSizeCache.shared.remember(blob, size);
    if (!mounted) return;
    setState(() {
      _reading = false;
      _bytes = bytes;
    });
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

  /// Full-screen: a screenshot has to be readable, and a long text file has to
  /// be scrollable past the inline cap.
  Future<void> _open() => AttachmentViewer.open(
    context,
    message: widget.message,
    loadBytes: widget.loadBytes,
    onSave: widget.onSave,
  );

  /// Save straight from the card — the same action the viewer offers, so
  /// "keep this" never requires opening it first.
  Future<void> _save() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final where = await widget.onSave(widget.message);
      messenger?.showSnackBar(SnackBar(content: Text('Saved to $where')));
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            error is MediaSaveException
                ? error.message
                : 'Could not save the file',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final msg = widget.message;
    final content = <Widget>[
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
    ];
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: content,
      );
    }
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
        children: [_header(context), ...content],
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
          // Saving needs the local copy; without one there is nothing to write
          // to the gallery, so the tap goes to the Pi instead (the placeholder).
          if (msg.hasContent)
            IconButton(
              key: const Key('attachment-save'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(LucideIcons.download, size: 13, color: colors.muted),
              tooltip: 'Save to phone',
              onPressed: _save,
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
    final blob = widget.message.blobName;
    final size = blob == null ? null : ImageSizeCache.shared.sizeOf(blob);
    if (bytes == null) {
      // A cached blob whose bytes have not arrived yet: hold the media area
      // open with the box the picture is going to occupy. (This used to be a
      // ~44 px "tap to load" row that grew to 220 px a frame later, which is
      // what made the transcript jump under a scrolling finger.) A card with
      // no blob at all has nothing to hold open — it stays compact until the
      // user asks for the file.
      if (blob == null || !_reading) return _placeholder(context);
      return ImageFrame(
        size: size,
        maxHeight: AttachmentCard.maxImageHeight,
        builder: (context, _) => Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 1.4,
              color: context.colors.muted,
            ),
          ),
        ),
      );
    }
    return ImageFrame(
      size: size,
      maxHeight: AttachmentCard.maxImageHeight,
      builder: (context, cacheWidth) => GestureDetector(
        key: const Key('attachment-open'),
        onTap: _open,
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: cacheWidth,
          errorBuilder: (_, _, _) => _brokenImage(context),
        ),
      ),
    );
  }

  Widget _textPreview(BuildContext context) {
    final colors = context.colors;
    final full = AttachmentStore.textPreview(
      _bytes!,
      maxChars: AttachmentCard.previewScanChars,
    );
    if (full == null || full.trim().isEmpty) {
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
    final cut = full.length > AttachmentCard.previewChars;
    final text = cut
        ? full.substring(0, AttachmentCard.previewChars)
        : full;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GptMarkdown(
            text,
            style: context.typo.mono,
            // Prose/code highlighting would fight the mono card; the raw text
            // is what a file preview is for.
            highlightBuilder: (context, text, style) => Text(text, style: style),
            // A fenced block in a PREVIEW has to stay flat: the package's
            // default code card is Material-light (a white slab on a dark
            // chat) and scrolls horizontally, which fights the chat list.
            codeBuilder: (_, _, code, _) => Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: colors.codeBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: colors.border),
              ),
              child: Text(code.trimRight(), style: context.typo.mono),
            ),
          ),
          if (cut)
            GestureDetector(
              key: const Key('attachment-expand'),
              onTap: _open,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'show all',
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
