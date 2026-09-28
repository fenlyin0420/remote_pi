
import 'package:app/data/attachments/attachment_store.dart';
import 'package:app/domain/contracts/media_saver.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Full-screen look at a file the Pi sent, opened by tapping its card.
///
/// An image gets pinch/double-tap zoom over a black backdrop (a screenshot has
/// to be READABLE — a 220 px thumbnail in a chat bubble is not); a text file
/// gets the whole content, scrollable and selectable, past the inline preview's
/// cap. Both carry the same save action, because "I can see it" and "I want to
/// keep it" are the same request.
class AttachmentViewer extends StatefulWidget {
  const AttachmentViewer({
    super.key,
    required this.message,
    required this.loadBytes,
    required this.onSave,
  });

  final AttachmentMsg message;

  /// Reads the locally cached bytes (null when there is nothing cached).
  final Future<Uint8List?> Function(String blobName) loadBytes;

  /// Copies the file into the phone's storage; returns where it went.
  final Future<String> Function(AttachmentMsg msg) onSave;

  static Future<void> open(
    BuildContext context, {
    required AttachmentMsg message,
    required Future<Uint8List?> Function(String blobName) loadBytes,
    required Future<String> Function(AttachmentMsg msg) onSave,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AttachmentViewer(
        message: message,
        loadBytes: loadBytes,
        onSave: onSave,
      ),
    ),
  );

  @override
  State<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends State<AttachmentViewer> {
  final TransformationController _transform = TransformationController();
  Uint8List? _bytes;
  bool _saving = false;
  bool _zoomed = false;
  String? _error;

  /// A failed save, shown in the app bar. Separate from [_error] on purpose:
  /// a save problem must not replace the content the user opened to see.
  String? _saveError;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// Double-tap toggles between "fit the screen" and "read the pixels" — the
  /// scale that makes a screenshot legible without a pinch gesture.
  void _toggleZoom() {
    setState(() {
      _zoomed = !_zoomed;
      _transform.value = _zoomed
          ? (Matrix4.identity()..scaleByDouble(2.5, 2.5, 1, 1))
          : Matrix4.identity();
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final blob = widget.message.blobName;
    if (blob == null) {
      setState(() => _error = 'This file has not been loaded on the phone yet.');
      return;
    }
    final bytes = await widget.loadBytes(blob);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      if (bytes == null) {
        _error = 'The local copy is gone — go back and load it again.';
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final where = await widget.onSave(widget.message);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to $where')),
      );
    } catch (error) {
      if (!mounted) return;
      // A save failure is reported IN the app bar (the snackbar is behind the
      // full-screen route), and must not wipe what the user came to look at.
      setState(() => _saveError = error is MediaSaveException
          ? error.message
          : 'Could not save the file');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.message.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 14,
                color: Colors.white,
              ),
            ),
            Text(
              _saveError ?? _subtitle(),
              key: const Key('viewer-subtitle'),
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 10,
                color: _saveError != null ? Colors.redAccent : Colors.white60,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('viewer-save'),
            tooltip: 'Save to phone',
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white70,
                      strokeWidth: 1.5,
                    ),
                  )
                : const Icon(LucideIcons.download),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            )
          : widget.message.isImage
          ? _image()
          : _text(context),
    );
  }

  String _subtitle() {
    final msg = widget.message;
    final parts = <String>[
      msg.mime,
      if (msg.resized && msg.originalSize != null)
        'downscaled from ${_humanSize(msg.originalSize!)}',
    ];
    return parts.join(' · ');
  }

  Widget _image() {
    final bytes = _bytes;
    if (bytes == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
      );
    }
    // InteractiveViewer gives pinch + pan for free; the double-tap toggle is
    // what makes a screenshot readable without a pinch gesture.
    return GestureDetector(
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 6,
        child: Center(
          child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }

  Widget _text(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
      );
    }
    final text = AttachmentStore.textPreview(bytes, maxChars: 200000) ?? '';
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 32),
        child: GptMarkdown(
          text.isEmpty ? '(no readable text)' : text,
          style: context.typo.mono.copyWith(color: Colors.white),
          highlightBuilder: (context, text, style) => Text(
            text,
            style: style.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

String _humanSize(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
