import 'dart:typed_data';

/// The pixel size of an encoded image, read from its header alone.
///
/// The chat transcript needs an image's box *before* the bytes are decoded:
/// a row whose height only becomes known when the decode lands changes height
/// in the middle of a scroll, and every row below it moves with it (see
/// `ui/chat/widgets/image_frame.dart` for what that did to the user's finger).
/// Reading the header costs a handful of byte reads on data that is already in
/// memory — no decode, no allocation.
///
/// Unknown formats (HEIC, AVIF, a truncated download) return null; callers fall
/// back to a fixed maximum height instead of guessing wrong.
class ImageSize {
  const ImageSize(this.width, this.height);

  final int width;
  final int height;

  /// width / height, or 0 for a bogus header (callers treat it as unknown).
  double get aspectRatio => height <= 0 ? 0 : width / height;

  @override
  bool operator ==(Object other) =>
      other is ImageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'ImageSize(${width}x$height)';
}

/// Reads the pixel size out of [bytes]' header, or null when the format is not
/// one we parse (or the file is too short / corrupt to trust).
ImageSize? probeImageSize(Uint8List bytes) =>
    _png(bytes) ?? _gif(bytes) ?? _webp(bytes) ?? _bmp(bytes) ?? _jpeg(bytes);

ImageSize? _sane(int width, int height) =>
    width > 0 && height > 0 ? ImageSize(width, height) : null;

int _be16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

int _be32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _le16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

int _le24(Uint8List b, int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);

int _le32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

/// `\x89PNG\r\n\x1a\n` + an IHDR chunk, which is always first and always
/// carries the size at a fixed offset.
ImageSize? _png(Uint8List b) {
  if (b.length < 24) return null;
  const magic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < magic.length; i++) {
    if (b[i] != magic[i]) return null;
  }
  const ihdr = [0x49, 0x48, 0x44, 0x52];
  for (var i = 0; i < ihdr.length; i++) {
    if (b[12 + i] != ihdr[i]) return null;
  }
  return _sane(_be32(b, 16), _be32(b, 20));
}

/// `GIF87a` / `GIF89a` + the logical screen size at offsets 6 and 8.
ImageSize? _gif(Uint8List b) {
  if (b.length < 10) return null;
  if (b[0] != 0x47 || b[1] != 0x49 || b[2] != 0x46) return null;
  return _sane(_le16(b, 6), _le16(b, 8));
}

/// RIFF/WEBP, whose three chunk flavours each store the canvas size
/// differently (lossy VP8, lossless VP8L, extended VP8X).
ImageSize? _webp(Uint8List b) {
  if (b.length < 30) return null;
  if (b[0] != 0x52 || b[1] != 0x49 || b[2] != 0x46 || b[3] != 0x46) return null;
  if (b[8] != 0x57 || b[9] != 0x45 || b[10] != 0x42 || b[11] != 0x50) {
    return null;
  }
  switch (String.fromCharCodes(b, 12, 16)) {
    case 'VP8 ':
      // Frame tag (3) + the 0x9d012a sync code, then two 14-bit sizes with
      // 2 bits of scale on top — masking is what keeps the scale out.
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      return _sane(_le16(b, 26) & 0x3FFF, _le16(b, 28) & 0x3FFF);
    case 'VP8L':
      if (b[20] != 0x2F) return null;
      final bits = _le32(b, 21);
      return _sane((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8X':
      // 1 byte of flags + 3 reserved, then width-1 and height-1 as 24-bit LE.
      return _sane(_le24(b, 24) + 1, _le24(b, 27) + 1);
  }
  return null;
}

/// `BM` + a BITMAPINFOHEADER, whose height is signed (negative = top-down rows).
ImageSize? _bmp(Uint8List b) {
  if (b.length < 26) return null;
  if (b[0] != 0x42 || b[1] != 0x4D) return null;
  final width = _le32(b, 18).toSigned(32);
  final height = _le32(b, 22).toSigned(32);
  return _sane(width, height.abs());
}

/// Walks the JPEG segment chain to the frame header (SOF0/SOF1/SOF2/…), which
/// carries the size. Everything before it — EXIF, ICC, thumbnails — is skipped
/// by length, so a 4 MB photo costs a few dozen reads.
ImageSize? _jpeg(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 3 < b.length) {
    if (b[i] != 0xFF) {
      i++; // resync out of padding/garbage
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte before the real marker
      continue;
    }
    // Standalone markers carry no length.
    if (marker == 0x01 || marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return null; // scan data: no SOF seen
    final length = _be16(b, i + 2);
    if (length < 2) return null;
    final isFrameHeader =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 && // DHT
        marker != 0xC8 && // JPG extension
        marker != 0xCC; // DAC
    if (isFrameHeader) {
      if (i + 9 > b.length) return null;
      // [FF Cx][len:2][precision:1][height:2][width:2]
      return _sane(_be16(b, i + 7), _be16(b, i + 5));
    }
    i += 2 + length;
  }
  return null;
}
