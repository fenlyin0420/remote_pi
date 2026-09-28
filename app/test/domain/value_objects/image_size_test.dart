// Header-only image size reading — the value the transcript uses to reserve an
// image's box before its bytes are decoded.
//
// The fixtures are real encoder output (Pillow), so the parser is not just
// agreeing with offsets it wrote itself: PNG/JPEG/GIF/WebP/BMP each get their
// genuine header, plus bytes that are not an image at all.

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/value_objects/image_size.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String base64) => base64Decode(base64);

// 37×91
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAACUAAABbCAIAAAB71NvlAAAARElEQVR4nO3NAQkAMAgAsPsgBjOxsWwhCFuB'
    'RWe9RX8z8/l8Pp/P5/P5fD6fz+fz+Xw+n8/n8/l8Pp/P5/P5fD6f78g3FG4B9pYISwIAAAAASUVORK5CYII=';

// 61×23 — has APP0 + two quantisation tables ahead of the frame header.
const _jpeg =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIs'
    'IxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIy'
    'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAXAD0DASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAA'
    'AAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAk'
    'M2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKT'
    'lJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QA'
    'HwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdh'
    'cRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hp'
    'anN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk'
    '5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDl6KKKZ+jhRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB//Z';

// 13×47
const _gif =
    'R0lGODdhDQAvAIEAAMgeWgAAAAAAAAAAACwAAAAADQAvAAAIKgABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsa'
    'LFixgzatzIsaPHjyBDioQYEAA7';

// 55×89 — lossy, so the size lives in the VP8 frame tag.
const _webpLossy =
    'UklGRkwAAABXRUJQVlA4IEAAAAAQBACdASo3AFkAPm02mUmkIyKhIWgAgA2JaQAADLmtNmzZs2bNmzYwAAD+'
    '7ykH//2Dv//Qd//6Dv9OAAAAAAAA';

// 23×71 — lossless, whose size is 14+14 bits inside the VP8L chunk.
const _webpLossless =
    'UklGRiQAAABXRUJQVlA4TBcAAAAvFoARAAdQ5CpUq/8BICH8P69G9D+dAAA=';

// 29×11
const _bmp =
    'Qk3+AwAAAAAAADYAAAAoAAAAHQAAAAsAAAABABgAAAAAAMgDAADEDgAAxA4AAAAAAAAAAAAAWh7IWh7IWh7I'
    'Wh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7I'
    'Wh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7I'
    'Wh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IAFo'
    'eyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoey'
    'FoeyFoeyFoeyFoeyFoeyFoeyFoeyABaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHsha'
    'HshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHsgAWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7'
    'IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IAFoey'
    'FoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoey'
    'FoeyFoeyFoeyFoeyFoeyFoeyABaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaH'
    'shaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHshaHsgAWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IW'
    'h7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IWh7IAFoeyFo'
    'eyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFoeyFo'
    'eyFoeyFoeyFoeyFoeyFoeyAA=';

/// Hand-built: RIFF/WEBP + a VP8X chunk, the extended (alpha/animation) form
/// whose canvas size is stored as 24-bit width-1 / height-1.
Uint8List _webpExtended(int width, int height) {
  final header = <int>[
    0x52, 0x49, 0x46, 0x46, // RIFF
    0x16, 0x00, 0x00, 0x00, // chunk size (unused by the parser)
    0x57, 0x45, 0x42, 0x50, // WEBP
    0x56, 0x50, 0x38, 0x58, // 'VP8X'
    0x0A, 0x00, 0x00, 0x00, // chunk length
    0x00, 0x00, 0x00, 0x00, // flags + reserved
    (width - 1) & 0xFF, ((width - 1) >> 8) & 0xFF, ((width - 1) >> 16) & 0xFF,
    (height - 1) & 0xFF, ((height - 1) >> 8) & 0xFF, ((height - 1) >> 16) & 0xFF,
  ];
  return Uint8List.fromList(header);
}

/// Hand-built: `FF D8`, an APP1 segment to skip, then a progressive frame
/// header (`FF C2`), which is what a phone photo looks like before its scan.
Uint8List _jpegWithExif(int width, int height) {
  final exif = List<int>.filled(40, 0x00);
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, 0x00, 42, ...exif, // APP1, length 42
    0xFF, 0xC2, 0x00, 17, 0x08, // SOF2, length 17, precision 8
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    0x03, 0x01, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
  ]);
}

void main() {
  test('reads the size out of every format we ship', () {
    expect(probeImageSize(_bytes(_png)), const ImageSize(37, 91));
    expect(probeImageSize(_bytes(_jpeg)), const ImageSize(61, 23));
    expect(probeImageSize(_bytes(_gif)), const ImageSize(13, 47));
    expect(probeImageSize(_bytes(_webpLossy)), const ImageSize(55, 89));
    expect(probeImageSize(_bytes(_webpLossless)), const ImageSize(23, 71));
    expect(probeImageSize(_bytes(_bmp)), const ImageSize(29, 11));
  });

  test('walks past metadata segments to the JPEG frame header', () {
    expect(probeImageSize(_jpegWithExif(1600, 1200)), const ImageSize(1600, 1200));
  });

  test('reads the extended WebP canvas size', () {
    expect(probeImageSize(_webpExtended(4032, 3024)), const ImageSize(4032, 3024));
  });

  test('aspect ratio is width over height', () {
    expect(const ImageSize(1600, 900).aspectRatio, closeTo(1.7778, 0.0001));
    expect(const ImageSize(0, 0).aspectRatio, 0);
  });

  test('a format we do not parse says so instead of guessing', () {
    // A HEIC/AVIF-style header, plus junk, plus every format's magic cut short.
    expect(probeImageSize(Uint8List.fromList(List.filled(64, 0x00))), isNull);
    expect(probeImageSize(Uint8List.fromList(utf8.encode('not an image'))), isNull);
    expect(probeImageSize(_bytes(_png).sublist(0, 12)), isNull);
    expect(probeImageSize(_bytes(_jpeg).sublist(0, 8)), isNull);
    expect(probeImageSize(Uint8List(0)), isNull);
  });

  test('a PNG whose IHDR was replaced is not trusted', () {
    final broken = _bytes(_png);
    broken[13] = 0x58; // 'X' instead of 'H'
    expect(probeImageSize(broken), isNull);
  });

  test('a zero-sized header is treated as unreadable', () {
    final zero = _bytes(_png);
    zero.fillRange(16, 24, 0);
    expect(probeImageSize(zero), isNull);
  });

  test('a JPEG without a frame header before the scan says nothing', () {
    // SOI + SOS: a stream we cannot size, so the caller falls back.
    final scanOnly = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
    ]);
    expect(probeImageSize(scanOnly), isNull);
  });
}
