import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/ui/chat/widgets/image_frame.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/30 — static image thumbnail + optional caption inside the user
/// bubble (decision #7: no full-screen, no tap/zoom). Renders straight from
/// the inline base64 ([MessageImage.data]); the bytes are decoded once so
/// list scrolling doesn't re-decode every frame.
///
/// The box the picture goes into is reserved from its *header* before the
/// decode lands ([ImageFrame]): a bubble that grows from nothing to 220 px as
/// the decode lands shoves every row under it down, which is what made a fling
/// through a room with pictures stop dead.
class ImageBubble extends StatefulWidget {
  const ImageBubble({
    super.key,
    required this.image,
    this.caption = '',
    this.isFailed = false,
  });

  final MessageImage image;
  final String caption;
  final bool isFailed;

  /// Cap the thumbnail height; the width follows the bubble's 300px max.
  static const double maxHeight = 220;

  @override
  State<ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<ImageBubble> {
  late Uint8List _bytes;
  late ImageSize? _size;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(ImageBubble old) {
    super.didUpdateWidget(old);
    if (old.image.data != widget.image.data) _read();
  }

  void _read() {
    _bytes = _PayloadCache.decode(widget.image.data);
    // Header only: cheap enough to do on the spot, and it is what makes the
    // bubble's height final on its very first layout.
    _size = probeImageSize(_bytes);
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.caption.trim();
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.userBubble,
        borderRadius: BorderRadius.circular(12),
        border: widget.isFailed
            ? Border.all(color: colors.error, width: 1)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_bytes.isEmpty)
            _broken(context)
          else
            ImageFrame(
              size: _size,
              maxHeight: ImageBubble.maxHeight,
              builder: (context, cacheWidth) => Image.memory(
                _bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: cacheWidth,
              ),
            ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              child: Text(
                caption,
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
            ),
        ],
      ),
    );
  }

  Widget _broken(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 120,
      color: colors.codeBg,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_outlined, color: colors.muted, size: 28),
    );
  }
}

/// Decoded inline payloads, kept for the process.
///
/// Rows are discarded as soon as they scroll out of the viewport, so the same
/// picture is decoded again on the way back — and a fresh [Uint8List] also
/// throws away Flutter's own decode cache, whose key is the byte list's
/// *identity*, not its content. Handing the same list back for the same base64
/// keeps both the bytes and the bitmap cached, so scrolling past a picture the
/// second time costs nothing. Bounded by total size, oldest out.
class _PayloadCache {
  static const int maxBytes = 32 * 1024 * 1024;

  static final Map<String, Uint8List> _byData = {};
  static int _held = 0;

  static Uint8List decode(String data) {
    final hit = _byData[data];
    if (hit != null) return hit;
    Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      return Uint8List(0);
    }
    _byData[data] = bytes;
    _held += bytes.length;
    while (_held > maxBytes && _byData.length > 1) {
      final oldest = _byData.keys.first;
      _held -= _byData.remove(oldest)!.length;
    }
    return bytes;
  }
}
